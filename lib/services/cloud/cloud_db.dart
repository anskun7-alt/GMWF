import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_firestore_platform_interface/cloud_firestore_platform_interface.dart'
    show FieldValuePlatform;
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../quota_service.dart';
import '../firebase_session_guard.dart';
import 'sync_log.dart';
import 'lan_firestore_gate.dart';

/// Upload transport for the sync queues (SyncService and the LAN server's ServerSyncManager).
///
/// It mirrors the small part of the Firestore API the upload code uses
/// (`collection().doc().set/update/delete`, `batch()`, `runTransaction`), so that code keeps
/// its exact paths, data and merge options. Writes go to Firestore's REST API and each one
/// waits for Firestore's real answer:
///
/// * accepted → the caller's `await` completes, exactly like a confirmed SDK write;
/// * refused for quota (RESOURCE_EXHAUSTED / HTTP 429) → uploads pause until the daily
///   reset and a `resource-exhausted` [FirebaseException] is thrown;
/// * refused for another reason → a [FirebaseException] with the same code the SDK uses.
///
/// Why not the SDK: on Windows a write the server does not answer (quota used up, stuck
/// stream) never completes and never fails, but stays in the SDK's own offline queue. Every
/// retry added another copy there, and all of them were sent when the quota reset — using up
/// the new day's quota too. REST has no hidden queue: a write either happened or it did not.
///
/// Reads (`get`, queries) still use the SDK. Setting `cloud_upload_transport` to `sdk` in the
/// `app_flags` box switches writes back to the SDK (kill switch).
class CloudDb {
  CloudDb._();
  static final CloudDb instance = CloudDb._();

  /// Error text of a dispensary write refused on a LAN desk (SyncService sets such items aside).
  static const String lanDeskRefusal = 'LAN desk: the LAN server uploads this';

  FirebaseFirestore get sdk => FirebaseFirestore.instance;

  Future<void> enableNetwork() => sdk.enableNetwork();
  Future<void> disableNetwork() => sdk.disableNetwork();

  CloudCollection collection(String path) => CloudCollection._(this, path);
  CloudDoc doc(String path) => CloudDoc._(this, path);

  /// Wraps a reference that came from an SDK query so writes to it use this transport.
  CloudDoc ref(DocumentReference ref) => CloudDoc._(this, ref.path);

  Query<Map<String, dynamic>> collectionGroup(String collectionId) => sdk.collectionGroup(collectionId);

  CloudBatch batch() => CloudBatch._(this);

  /// Runs [handler], then commits its writes atomically. Reads inside it go to the server
  /// but are not isolated (the upload code only reads before writing its own records).
  Future<T> runTransaction<T>(Future<T> Function(CloudTransaction transaction) handler,
      {Duration timeout = const Duration(seconds: 30), int maxAttempts = 5}) async {
    final tx = CloudTransaction._(this);
    final result = await handler(tx);
    if (tx._writes.isNotEmpty) await _send(tx._writes);
    return result;
  }

  // ── Call context ──────────────────────────────────────────────────────────

  static final Object _ctxKey = Object();

  /// Runs [body] with [context] applying to every write it makes.
  static Future<T> runWith<T>(CloudWriteContext context, Future<T> Function() body) =>
      runZoned(body, zoneValues: {_ctxKey: context});

  static CloudWriteContext get _ctx =>
      Zone.current[_ctxKey] as CloudWriteContext? ?? const CloudWriteContext();

  // ── Status (for the sync health display) ──────────────────────────────────

  static final ValueNotifier<DateTime?> lastSuccessAt = ValueNotifier<DateTime?>(null);
  static final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);
  static int skippedUnchanged = 0;

  // ── Transport selection ───────────────────────────────────────────────────

  static String? _restDisabledReason;

  bool get _useRest {
    if (kIsWeb) return false;
    if (Platform.isAndroid || Platform.isIOS) return false;
    if (_restDisabledReason != null) return false;
    try {
      if (Hive.isBoxOpen('app_flags') &&
          Hive.box('app_flags').get('cloud_upload_transport')?.toString() == 'sdk') {
        return false;
      }
    } catch (_) {}
    return true;
  }

  static bool _isDispensaryPath(String path) {
    final parts = path.toLowerCase().split('/').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return false;
    const nonDispModules = {
      'kitchen',
      'dasterkhwaan',
      'madrassa',
      'madrassa_students',
      'madrassa_daily_logs',
      'madrassa_logs',
      'school',
      'school_students',
      'donations',
      'employees',
      'attendance',
      'finance',
      'users',
    };
    if (parts.any((p) => nonDispModules.contains(p))) return false;
    if (parts.first == 'patients' ||
        parts.first == 'medicine_restrictions' ||
        parts.first == 'dispensary' ||
        parts.first == 'doctor_templates') {
      return true;
    }
    if (parts.length >= 3 && parts[0] == 'branches') {
      const branchDispCols = {
        'patients',
        'serials',
        'prescriptions',
        'inventory',
        'medicines',
        'stock',
        'camps',
        'doctor_templates',
        'medicine_restrictions',
        'dispensary',
      };
      return branchDispCols.contains(parts[2]);
    }
    return false;
  }

  static bool _isParentSession() {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final u = Hive.box('app_settings').get('user_data') ??
            Hive.box('app_settings').get('currentUser');
        if (u is Map) {
          final role = (u['role'] ?? u['userRole'] ?? '').toString().trim().toLowerCase();
          return role == 'parent' || role == 'guardian';
        }
      }
    } catch (_) {}
    return false;
  }

  static bool _isAllowedParentWritePath(String path) {
    final p = path.toLowerCase();
    return p.contains('madrassa') &&
        (p.contains('log') || p.contains('repl') || p.contains('feedback') || p.contains('homework'));
  }

  // ── Sending ───────────────────────────────────────────────────────────────

  /// Set after a short Firestore rate limit: writes wait until then (retried as transient).
  static DateTime? _rateLimitedUntil;

  Future<void> _send(List<_Write> writes, {bool fingerprint = false}) async {
    if (writes.isEmpty) return;
    final ctx = _ctx;
    final rl = _rateLimitedUntil;
    if (rl != null && DateTime.now().isBefore(rl) && !ctx.force) {
      throw FirebaseException(plugin: 'cloud_firestore', code: 'unavailable', message: 'rate limited — retrying shortly');
    }
    if (QuotaService.isPausedForDailyReset && !ctx.force) {
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: 'resource-exhausted',
        message: 'Daily write quota used up — waiting for the reset',
      );
    }
    // CNIC-only parent login scope guard: a parent session may only write to Madrassa
    // daily log / reply documents, never to unrelated collections or student enrollment records.
    if (_isParentSession() && writes.any((w) => !_isAllowedParentWritePath(w.path))) {
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: 'permission-denied',
        message: 'Parent session is restricted to Madrassa log replies only',
      );
    }

    // A dispensary desk on the LAN never writes dispensary records to Firestore itself: the LAN server uploads.
    // 'unavailable' is treated like being offline, so queued items wait rather than fail.
    // Standalone collections (madrassa_students, madrassa_daily_logs, school_students, donations, users, etc.) are never blocked.
    final hasDispensaryWrite = writes.any((w) => _isDispensaryPath(w.path));
    if (hasDispensaryWrite && (LanFirestoreGate.active || LanFirestoreGate.isLanDesk)) {
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: 'unavailable',
        message: lanDeskRefusal,
      );
    }

    if (!_useRest) {
      await _sendViaSdk(writes);
      _recordSuccess(writes, ctx);
      return;
    }

    final root = _documentsRoot;
    final encoded = [for (final w in writes) _RestEncoder(root).encode(w)];

    // Skip a write identical to the last one this PC delivered for that document
    // (startup sweeps and repeated saves re-send unchanged records). Writes that add to
    // a value (increments, array changes) are never skipped.
    String? fpPath, fpHash;
    if (fingerprint && writes.length == 1 && !ctx.force && _RestEncoder.isRepeatable(encoded.single)) {
      fpPath = writes.single.path;
      fpHash = _hash(encoded.single);
      if (await _Fingerprints.matches(fpPath, fpHash)) {
        skippedUnchanged++;
        return;
      }
    }

    try {
      await _commit(encoded);
    } on _UseSdkInstead {
      await _sendViaSdk(writes);
      _recordSuccess(writes, ctx);
      return;
    } on FirebaseException catch (fe) {
      if (fe.code == 'invalid-argument' || fe.code == 'unauthenticated' || fe.code == 'permission-denied') {
        await _sendViaSdk(writes);
        _recordSuccess(writes, ctx);
        return;
      }
      rethrow;
    } catch (e) {
      if (kIsWeb || e is UnsupportedError || e.toString().contains('Unsupported') || e.toString().contains('HttpClient')) {
        _restDisabledReason = 'REST not supported on this platform';
        await _sendViaSdk(writes);
        _recordSuccess(writes, ctx);
        return;
      }
      rethrow;
    }
    _recordSuccess(writes, ctx);
    if (fpPath != null && fpHash != null) {
      await _Fingerprints.put(fpPath, fpHash);
    } else {
      for (final w in writes) {
        await _Fingerprints.remove(w.path);
      }
    }
  }

  void _recordSuccess(List<_Write> writes, CloudWriteContext ctx) {
    QuotaService.recordWrites(writes.length, backlog: ctx.backlog);
    QuotaService.recordSuccess();
    lastSuccessAt.value = DateTime.now();
  }

  String get _projectId => sdk.app.options.projectId;
  String get _databaseId {
    try {
      return sdk.databaseId;
    } catch (_) {
      return '(default)';
    }
  }

  String get _documentsRoot => 'projects/$_projectId/databases/$_databaseId/documents';

  static HttpClient? _client;
  HttpClient get _http => _client ??= HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 30);

  Future<void> _commit(List<Map<String, dynamic>> writes) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final headers = await _authHeaders(forceRefresh: attempt > 0);
      final keyParam = headers.isEmpty ? '?key=${Uri.encodeQueryComponent(sdk.app.options.apiKey)}' : '';
      final uri = Uri.parse('https://firestore.googleapis.com/v1/$_documentsRoot:commit$keyParam');

      final req = await _http.postUrl(uri).timeout(const Duration(seconds: 20));
      headers.forEach(req.headers.set);
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode({'writes': writes})));
      final resp = await req.close().timeout(const Duration(seconds: 30));
      final body = await resp.transform(utf8.decoder).join().timeout(const Duration(seconds: 30));
      final status = resp.statusCode;
      if (status == 200) return;

      final err = _RestError.parse(status, body);
      if (status == 401 && attempt == 0 && headers.isNotEmpty) continue; // stale token: refresh once

      lastError.value = '${err.code}: ${err.message}';
      // Only a real daily-quota refusal pauses uploads until the next reset. A short rate limit
      // or contention ("too many requests", "too much contention") is also 429 /
      // RESOURCE_EXHAUSTED, and used to stop ALL uploads for hours; it is now retried shortly.
      final msgLower = err.message.toLowerCase();
      final isDailyQuota = msgLower.contains('quota');
      if ((status == 429 || err.code == 'resource-exhausted') && !isDailyQuota) {
        _rateLimitedUntil = DateTime.now().add(const Duration(seconds: 20));
        SyncLog.write('⏳ Firestore rate-limited this PC (HTTP $status: ${err.message}) — retrying shortly');
        throw FirebaseException(plugin: 'cloud_firestore', code: 'unavailable', message: 'rate limited: ${err.message}');
      }
      if (status == 429 || err.code == 'resource-exhausted') {
        QuotaService.pauseUntilDailyReset(reason: err.message);
        SyncLog.write('⛔ Firestore refused writes: daily quota used up (HTTP $status: ${err.message}). '
            'Uploads wait until ${QuotaService.nextDailyReset().toLocal()} '
            '(${QuotaService.dailyWriteCount} writes from this PC today)');
        throw FirebaseException(plugin: 'cloud_firestore', code: 'resource-exhausted', message: err.message);
      }
      if (err.isApiBlocked) {
        _restDisabledReason = err.message;
        SyncLog.write('⚠️ Firestore REST API not usable ($status ${err.message}) — using the SDK for uploads this session');
        throw const _UseSdkInstead();
      }
      throw FirebaseException(plugin: 'cloud_firestore', code: err.code, message: err.message);
    }
  }

  Future<Map<String, String>> _authHeaders({bool forceRefresh = false}) async {
    var user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      try {
        await FirebaseSessionGuard.ensureSession(reason: 'cloud_db_auth').timeout(const Duration(seconds: 6));
        user = FirebaseAuth.instance.currentUser;
      } catch (_) {}
      if (user == null) {
        try {
          await FirebaseAuth.instance.signInAnonymously().timeout(const Duration(seconds: 4));
          user = FirebaseAuth.instance.currentUser;
        } catch (_) {}
      }
    }
    if (user == null) return const {};
    final token = await user.getIdToken(forceRefresh).timeout(const Duration(seconds: 10));
    if (token == null || token.isEmpty) return const {};
    return {'authorization': 'Bearer $token'};
  }

  /// Kill-switch & mobile native path: the SDK writes, with a time limit so an unanswered
  /// write can never hang a whole upload pass.
  Future<void> _sendViaSdk(List<_Write> writes) async {
    if (FirebaseAuth.instance.currentUser == null) {
      try {
        await FirebaseSessionGuard.ensureSession(reason: 'cloud_db_auth').timeout(const Duration(seconds: 8));
      } catch (_) {}
    }
    if (writes.length == 1) {
      await _sdkOp(writes.single, null).timeout(const Duration(seconds: 20));
      return;
    }
    final b = sdk.batch();
    for (final w in writes) {
      await _sdkOp(w, b);
    }
    await b.commit().timeout(const Duration(seconds: 20));
  }

  Future<void> _sdkOp(_Write w, WriteBatch? b) async {
    final ref = sdk.doc(w.path);
    if (w.kind == _Kind.delete) {
      if (b != null) {
        b.delete(ref);
      } else {
        await ref.delete();
      }
      return;
    }
    if (w.kind == _Kind.update) {
      final data = Map<Object, Object?>.from(w.updateData!);
      if (b != null) {
        b.update(ref, data);
      } else {
        await ref.update(data);
      }
      return;
    }
    final options = switch (w.kind) {
      _Kind.merge => SetOptions(merge: true),
      _Kind.mergeFields => SetOptions(mergeFields: w.mergeFields!),
      _ => null,
    };
    if (b != null) {
      b.set(ref, w.data!, options);
    } else {
      await ref.set(w.data!, options);
    }
  }

  /// The REST `Write` JSON for a set/update/delete, for tests.
  @visibleForTesting
  static Map<String, dynamic> encodeForTest(String path,
      {Map<String, dynamic>? set, SetOptions? options, Map<Object, Object?>? update, bool delete = false}) {
    final w = delete
        ? _Write(path, _Kind.delete)
        : update != null
            ? _Write(path, _Kind.update, updateData: update)
            : _Write.fromSet(path, set!, options);
    return _RestEncoder('projects/p/databases/(default)/documents').encode(w);
  }

  @visibleForTesting
  static bool isRepeatableForTest(Map<String, dynamic> write) => _RestEncoder.isRepeatable(write);

  static String _hash(Map<String, dynamic> write) =>
      sha1.convert(utf8.encode(jsonEncode(write))).toString().substring(0, 20);

  static String autoId() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random.secure();
    return String.fromCharCodes(Iterable.generate(20, (_) => chars.codeUnitAt(r.nextInt(chars.length))));
  }

  static String _pathOf(Object ref) {
    if (ref is CloudDoc) return ref.path;
    if (ref is DocumentReference) return ref.path;
    throw ArgumentError('Not a document reference: ${ref.runtimeType}');
  }
}

/// Per-call options, set with [CloudDb.runWith].
class CloudWriteContext {
  /// Manual "Sync now": ignore a quota pause and re-send unchanged records.
  final bool force;

  /// The writes belong to a backlog item (count against the backlog share).
  final bool backlog;

  const CloudWriteContext({this.force = false, this.backlog = false});
}

class CloudCollection {
  CloudCollection._(this._db, this.path);
  final CloudDb _db;
  final String path;

  String get id => path.split('/').last;
  CollectionReference<Map<String, dynamic>> get sdkRef => _db.sdk.collection(path);

  CloudDoc doc([String? id]) => CloudDoc._(_db, '$path/${id ?? CloudDb.autoId()}');

  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) => sdkRef.get(options);

  Future<CloudDoc> add(Map<String, dynamic> data) async {
    final d = doc();
    await d.set(data);
    return d;
  }
}

class CloudDoc {
  CloudDoc._(this._db, this.path);
  final CloudDb _db;
  final String path;

  String get id => path.split('/').last;
  DocumentReference<Map<String, dynamic>> get sdkRef => _db.sdk.doc(path);

  CloudCollection collection(String collectionPath) => CloudCollection._(_db, '$path/$collectionPath');

  Future<DocumentSnapshot<Map<String, dynamic>>> get([GetOptions? options]) => sdkRef.get(options);

  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) =>
      _db._send([_Write.fromSet(path, data, options)], fingerprint: true);

  Future<void> update(Map<Object, Object?> data) =>
      _db._send([_Write(path, _Kind.update, updateData: data)], fingerprint: true);

  Future<void> delete() => _db._send([_Write(path, _Kind.delete)], fingerprint: true);
}

/// Collects writes and sends them in one atomic commit, like `WriteBatch`.
class CloudBatch {
  CloudBatch._(this._db);
  final CloudDb _db;
  final List<_Write> _writes = [];

  void set(Object ref, Map<String, dynamic> data, [SetOptions? options]) =>
      _writes.add(_Write.fromSet(CloudDb._pathOf(ref), data, options));

  void update(Object ref, Map<Object, Object?> data) =>
      _writes.add(_Write(CloudDb._pathOf(ref), _Kind.update, updateData: data));

  void delete(Object ref) => _writes.add(_Write(CloudDb._pathOf(ref), _Kind.delete));

  Future<void> commit() => _db._send(List.of(_writes));
}

class CloudTransaction {
  CloudTransaction._(this._db);
  final CloudDb _db;
  final List<_Write> _writes = [];

  Future<DocumentSnapshot<Map<String, dynamic>>> get(Object ref) =>
      _db.sdk.doc(CloudDb._pathOf(ref)).get(const GetOptions(source: Source.server));

  CloudTransaction set(Object ref, Map<String, dynamic> data, [SetOptions? options]) {
    _writes.add(_Write.fromSet(CloudDb._pathOf(ref), data, options));
    return this;
  }

  CloudTransaction update(Object ref, Map<Object, Object?> data) {
    _writes.add(_Write(CloudDb._pathOf(ref), _Kind.update, updateData: data));
    return this;
  }

  CloudTransaction delete(Object ref) {
    _writes.add(_Write(CloudDb._pathOf(ref), _Kind.delete));
    return this;
  }
}

// ── Internals ────────────────────────────────────────────────────────────────

enum _Kind { set, merge, mergeFields, update, delete }

class _Write {
  _Write(this.path, this.kind, {this.data, this.updateData, this.mergeFields});

  factory _Write.fromSet(String path, Map<String, dynamic> data, SetOptions? options) {
    if (options?.mergeFields != null) {
      return _Write(path, _Kind.mergeFields, data: data, mergeFields: options!.mergeFields);
    }
    return _Write(path, options?.merge == true ? _Kind.merge : _Kind.set, data: data);
  }

  final String path;
  final _Kind kind;
  final Map<String, dynamic>? data;
  final Map<Object, Object?>? updateData;
  final List<FieldPath>? mergeFields;
}

class _UseSdkInstead implements Exception {
  const _UseSdkInstead();
}

class _RestError {
  _RestError(this.code, this.message, this.isApiBlocked);
  final String code;
  final String message;
  final bool isApiBlocked;

  static const _codes = {
    'CANCELLED': 'cancelled',
    'UNKNOWN': 'unknown',
    'INVALID_ARGUMENT': 'invalid-argument',
    'DEADLINE_EXCEEDED': 'deadline-exceeded',
    'NOT_FOUND': 'not-found',
    'ALREADY_EXISTS': 'already-exists',
    'PERMISSION_DENIED': 'permission-denied',
    'RESOURCE_EXHAUSTED': 'resource-exhausted',
    'FAILED_PRECONDITION': 'failed-precondition',
    'ABORTED': 'aborted',
    'OUT_OF_RANGE': 'out-of-range',
    'UNIMPLEMENTED': 'unimplemented',
    'INTERNAL': 'internal',
    'UNAVAILABLE': 'unavailable',
    'DATA_LOSS': 'data-loss',
    'UNAUTHENTICATED': 'unauthenticated',
  };

  static _RestError parse(int status, String body) {
    var statusName = '';
    var message = body.length > 300 ? body.substring(0, 300) : body;
    try {
      final decoded = jsonDecode(body);
      final e = decoded is List && decoded.isNotEmpty ? decoded.first['error'] : decoded['error'];
      if (e is Map) {
        statusName = (e['status'] ?? '').toString();
        message = (e['message'] ?? message).toString();
      }
    } catch (_) {}
    final code = _codes[statusName] ??
        switch (status) {
          400 => 'invalid-argument',
          401 => 'unauthenticated',
          403 => 'permission-denied',
          404 => 'not-found',
          409 => 'aborted',
          429 => 'resource-exhausted',
          503 => 'unavailable',
          504 => 'deadline-exceeded',
          _ => 'internal',
        };
    // The API itself is unusable (disabled, key restricted) — as opposed to a security
    // rule refusing this write, which the SDK would refuse too.
    final m = message.toLowerCase();
    final apiBlocked = status == 403 &&
        (m.contains('has not been used') ||
            m.contains('is disabled') ||
            m.contains('are blocked') ||
            m.contains('api key not valid') ||
            m.contains('requests from this'));
    return _RestError(code, message, apiBlocked);
  }
}

enum _Mode { replace, merge, update }

/// Converts a write into the Firestore REST `Write` JSON, with the same semantics as the SDK.
class _RestEncoder {
  _RestEncoder(this._root);
  final String _root;

  final List<String> _mask = [];
  final List<Map<String, dynamic>> _transforms = [];

  Map<String, dynamic> encode(_Write w) {
    final name = '$_root/${w.path}';
    switch (w.kind) {
      case _Kind.delete:
        return {'delete': name};
      case _Kind.set:
        return _build(name, _walk(w.data!, const [], _Mode.replace), mask: false);
      case _Kind.merge:
        return _build(name, _walk(w.data!, const [], _Mode.merge), mask: true);
      case _Kind.mergeFields:
        final fields = <String, dynamic>{};
        for (final fp in w.mergeFields!) {
          final comps = fp.components;
          final value = _lookup(w.data!, comps);
          _put(fields, comps, value, _Mode.merge, addMask: true);
        }
        return _build(name, fields, mask: true);
      case _Kind.update:
        final fields = <String, dynamic>{};
        w.updateData!.forEach((key, value) {
          final comps = key is FieldPath ? key.components : key.toString().split('.');
          _put(fields, comps, value, _Mode.update, addMask: true);
        });
        return _build(name, fields, mask: true, mustExist: true);
    }
  }

  Map<String, dynamic> _build(String name, Map<String, dynamic> fields,
      {required bool mask, bool mustExist = false}) {
    final write = <String, dynamic>{
      'update': {'name': name, 'fields': fields},
    };
    if (mask) write['updateMask'] = {'fieldPaths': _mask};
    if (_transforms.isNotEmpty) write['updateTransforms'] = _transforms;
    if (mustExist) write['currentDocument'] = {'exists': true};
    return write;
  }

  /// A write that can be skipped when identical to the last one sent (no increments or
  /// array changes, which add to the stored value each time).
  static bool isRepeatable(Map<String, dynamic> write) {
    final t = write['updateTransforms'];
    if (t is! List) return true;
    return t.every((x) => x is Map && x.containsKey('setToServerValue'));
  }

  Map<String, dynamic> _walk(Map data, List<String> prefix, _Mode mode) {
    final fields = <String, dynamic>{};
    data.forEach((k, v) {
      final key = k.toString();
      final path = [...prefix, key];
      if (v is FieldValue) {
        _sentinel(v, path, mode);
        return;
      }
      if (v is Map && (mode == _Mode.replace || v.isNotEmpty)) {
        // merge: nested maps merge field by field (only their leaves change);
        // replace: the map is written whole, but sentinels inside still become transforms.
        final sub = _walk(v, path, mode);
        if (mode == _Mode.replace || sub.isNotEmpty) {
          fields[key] = {'mapValue': {'fields': sub}};
        }
        return;
      }
      fields[key] = _value(v);
      if (mode == _Mode.merge) _mask.add(_quote(path));
    });
    return fields;
  }

  void _put(Map<String, dynamic> fields, List<String> comps, Object? value, _Mode mode,
      {required bool addMask}) {
    if (value is FieldValue) {
      _sentinel(value, comps, mode);
      return;
    }
    final encoded = value is Map ? {'mapValue': {'fields': _walk(value, comps, _Mode.replace)}} : _value(value);
    var node = fields;
    for (var i = 0; i < comps.length - 1; i++) {
      final child = node.putIfAbsent(comps[i], () => {'mapValue': {'fields': <String, dynamic>{}}});
      node = (child['mapValue'] as Map)['fields'] as Map<String, dynamic>;
    }
    node[comps.last] = encoded;
    if (addMask) _mask.add(_quote(comps));
  }

  static Object? _lookup(Map data, List<String> comps) {
    Object? cur = data;
    for (final c in comps) {
      if (cur is Map && cur.containsKey(c)) {
        cur = cur[c];
      } else {
        throw ArgumentError('Field "${comps.join('.')}" is in mergeFields but missing from the data');
      }
    }
    return cur;
  }

  void _sentinel(FieldValue v, List<String> path, _Mode mode) {
    final delegate = FieldValuePlatform.getDelegate(v) as dynamic;
    final type = delegate.type.toString().split('.').last;
    final Object? arg = delegate.value;
    final q = _quote(path);
    switch (type) {
      case 'delete':
        if (mode != _Mode.replace) _mask.add(q);
      case 'serverTimestamp':
        _transforms.add({'fieldPath': q, 'setToServerValue': 'REQUEST_TIME'});
      case 'incrementInteger':
      case 'incrementDouble':
        _transforms.add({'fieldPath': q, 'increment': _value(arg)});
      case 'arrayUnion':
        _transforms.add({'fieldPath': q, 'appendMissingElements': {'values': [for (final e in arg as List) _value(e)]}});
      case 'arrayRemove':
        _transforms.add({'fieldPath': q, 'removeAllFromArray': {'values': [for (final e in arg as List) _value(e)]}});
      default:
        throw ArgumentError('Unsupported FieldValue $type at ${path.join('.')}');
    }
  }

  Map<String, dynamic> _value(Object? v) {
    if (v == null) return {'nullValue': null};
    if (v is bool) return {'booleanValue': v};
    if (v is int) return {'integerValue': v.toString()};
    if (v is double) {
      if (v.isNaN) return {'doubleValue': 'NaN'};
      if (v.isInfinite) return {'doubleValue': v > 0 ? 'Infinity' : '-Infinity'};
      return {'doubleValue': v};
    }
    if (v is String) return {'stringValue': v};
    if (v is Timestamp) return {'timestampValue': _timestamp(v)};
    if (v is DateTime) return {'timestampValue': _timestamp(Timestamp.fromDate(v))};
    if (v is GeoPoint) return {'geoPointValue': {'latitude': v.latitude, 'longitude': v.longitude}};
    if (v is Blob) return {'bytesValue': base64Encode(v.bytes)};
    if (v is Uint8List) return {'bytesValue': base64Encode(v)};
    if (v is DocumentReference) return {'referenceValue': '$_root/${v.path}'};
    if (v is CloudDoc) return {'referenceValue': '$_root/${v.path}'};
    if (v is FieldValue) throw ArgumentError('FieldValue cannot be used inside an array');
    if (v is Iterable) return {'arrayValue': {'values': [for (final e in v) _value(e)]}};
    if (v is Map) {
      return {
        'mapValue': {'fields': {for (final e in v.entries) e.key.toString(): _value(e.value)}}
      };
    }
    throw ArgumentError('Unsupported value type ${v.runtimeType}');
  }

  static String _timestamp(Timestamp t) {
    final dt = DateTime.fromMillisecondsSinceEpoch(t.seconds * 1000, isUtc: true);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year.toString().padLeft(4, '0')}-${two(dt.month)}-${two(dt.day)}'
        'T${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}.${t.nanoseconds.toString().padLeft(9, '0')}Z';
  }

  static final RegExp _simpleSegment = RegExp(r'^[a-zA-Z_][a-zA-Z_0-9]*$');

  static String _quote(List<String> path) => path
      .map((s) => _simpleSegment.hasMatch(s) ? s : '`${s.replaceAll(r'\', r'\\').replaceAll('`', r'\`')}`')
      .join('.');
}

/// What this PC last delivered per document, to skip re-sending unchanged records.
class _Fingerprints {
  static const String _boxName = 'cloud_fingerprints';
  static const int _keepDays = 30;
  static Future<Box>? _opening;

  static int get _today => DateTime.now().millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;

  static Future<Box?> _box() async {
    try {
      if (Hive.isBoxOpen(_boxName)) return Hive.box(_boxName);
      final box = await (_opening ??= Hive.openBox(_boxName));
      unawaited(_prune(box));
      return box;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> matches(String path, String hash) async {
    final box = await _box();
    final v = box?.get(path)?.toString();
    if (v == null) return false;
    final sep = v.indexOf('|');
    if (sep < 0 || v.substring(0, sep) != hash) return false;
    final day = int.tryParse(v.substring(sep + 1)) ?? 0;
    return _today - day <= _keepDays;
  }

  static Future<void> put(String path, String hash) async {
    final box = await _box();
    await box?.put(path, '$hash|$_today');
  }

  static Future<void> remove(String path) async {
    final box = await _box();
    if (box != null && box.containsKey(path)) await box.delete(path);
  }

  static Future<void> _prune(Box box) async {
    final cutoff = _today - _keepDays;
    final stale = <dynamic>[];
    var n = 0;
    for (final k in box.keys) {
      final v = box.get(k)?.toString() ?? '';
      final day = int.tryParse(v.substring(v.indexOf('|') + 1)) ?? 0;
      if (day < cutoff) stale.add(k);
      if (++n % 500 == 0) await Future<void>.delayed(Duration.zero);
    }
    if (stale.isNotEmpty) await box.deleteAll(stale);
  }
}
