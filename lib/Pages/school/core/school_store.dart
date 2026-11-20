// lib/pages/school/core/school_store.dart
//
// The single write/read path for School records (School ERP plan §3.1).
//
// Write: stamp lastModified + updatedBy → merge into the local Hive copy →
// enqueue the upload → return. The screen never waits for the network; the
// upload queue (SyncService) sends it when online. Before this, every School
// save except students awaited a REST write with a 20–30 s timeout, so offline
// dialogs froze, and grade saves froze once per student.
//
// Read: tolerant of branch aliases. Records written before School had one
// branch rule (or by the biometric service under the raw device branch, e.g.
// "grt") are still found when the screen asks for "gujrat".
//
// Hive key scheme is unchanged so existing data keeps working:
//   students  <branch>__std__<id>      teachers  <branch>__tch__<id>
//   day logs  <branch>__log__<date>    staff log <branch>__tchlog__<date>
//   others    <branch>__<id>

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../../services/local_storage_service.dart';
import '../../../services/sync_service.dart';
import 'school_branch_id.dart';
import 'school_ids.dart';
import 'school_merge.dart';

/// Where one kind of School record lives.
class SchoolCollection {
  /// Firestore collection under `branches/{branch}/`.
  final String name;

  /// Hive box name.
  final String box;

  /// Key infix after `<branch>__` (e.g. `std__`). Empty for plain `<branch>__<id>`.
  final String infix;

  /// Day documents (`{date, entries}`) merge per entry instead of per record.
  final bool isDayLog;

  /// Queue item type for collections with a dedicated uploader. Null = the
  /// generic collection writer.
  final String? queueType;

  const SchoolCollection({
    required this.name,
    required this.box,
    this.infix = '',
    this.isDayLog = false,
    this.queueType,
  });

  static const students = SchoolCollection(
    name: 'school_students',
    box: LocalStorageService.schoolStudentsBox,
    infix: 'std__',
    queueType: 'save_school_student',
  );
  static const teachers = SchoolCollection(
    name: 'school_teachers',
    box: LocalStorageService.schoolTeachersBox,
    infix: 'tch__',
  );
  static const books = SchoolCollection(name: 'school_books', box: LocalStorageService.schoolBooksBox);
  static const bookLoans = SchoolCollection(name: 'school_book_loans', box: LocalStorageService.schoolBookLoansBox);

  /// Library members: outsider records, plus per-student/teacher overrides
  /// (blocked, loan limit, notes). Shares the loans box under `mem__`.
  static const libraryMembers = SchoolCollection(
    name: 'school_library_members',
    box: LocalStorageService.schoolBookLoansBox,
    infix: 'mem__',
    queueType: 'save_school_library_member',
  );

  /// Library settings (one record, id `default`). Shares the loans box under `cfg__`.
  static const librarySettings = SchoolCollection(
    name: 'school_library_settings',
    box: LocalStorageService.schoolBookLoansBox,
    infix: 'cfg__',
    queueType: 'save_school_library_settings',
  );
  static const attendance = SchoolCollection(
    name: 'school_attendance',
    box: LocalStorageService.schoolLogsBox,
    infix: 'log__',
    isDayLog: true,
  );
  static const teacherAttendance = SchoolCollection(
    name: 'school_teacher_attendance',
    box: LocalStorageService.schoolLogsBox,
    infix: 'tchlog__',
    isDayLog: true,
  );
  /// School calendar (Phase 3): `settings`, holidays `hol-<yyyy-MM-dd>`, PTM
  /// `ptm-<yyyy-MM>`, month state `month-<yyyy-MM>`. Shares the logs box under `cal__`.
  static const calendar = SchoolCollection(
    name: 'school_calendar',
    box: LocalStorageService.schoolLogsBox,
    infix: 'cal__',
  );

  /// Bimonthly compulsory events (Phase 5: Bazm-e-Adab, speech gala, training,
  /// field trip — report-only, no fee effect). Shares the logs box under `evt__`.
  static const events = SchoolCollection(
    name: 'school_events',
    box: LocalStorageService.schoolLogsBox,
    infix: 'evt__',
  );
  static const grades = SchoolCollection(name: 'school_grades', box: LocalStorageService.schoolGradesBox);

  /// Exam marksheet / document attachments stored once per assessment (Phase 5),
  /// instead of duplicated onto every student's grade row. Shares grades box under `gatt__`.
  static const gradeAttachments = SchoolCollection(
    name: 'school_grade_attachments',
    box: LocalStorageService.schoolGradesBox,
    infix: 'gatt__',
  );
  static const fees = SchoolCollection(name: 'school_fees', box: LocalStorageService.schoolFeesBox);

  // ── Fee engine (Phase 4). All share the fees box under their own infix; the
  //    old per-month `school_fees` records above stay readable but unused.
  /// Fee settings per month (`<yyyy-MM>`); a month without one uses the latest earlier one.
  static const feeConfigs = SchoolCollection(name: 'school_fee_configs', box: LocalStorageService.schoolFeesBox, infix: 'fcfg__');

  /// Frozen fee sheets, written at month close (`<yyyy-MM>_<studentId>`).
  static const feeSheets = SchoolCollection(name: 'school_fee_sheets', box: LocalStorageService.schoolFeesBox, infix: 'fsht__');

  /// Payments and reversals. Append-only: never edited, never deleted.
  static const feePayments = SchoolCollection(name: 'school_fee_payments', box: LocalStorageService.schoolFeesBox, infix: 'fpay__');

  /// Adjustments (after close) and concessions.
  static const feeAdjustments = SchoolCollection(name: 'school_fee_adjustments', box: LocalStorageService.schoolFeesBox, infix: 'fadj__');
  static const homerooms = SchoolCollection(name: 'school_homerooms', box: LocalStorageService.schoolHomeroomBox);
  static const auditLogs = SchoolCollection(
    name: 'school_audit_logs',
    box: LocalStorageService.schoolAuditLogsBox,
    queueType: 'save_school_audit_log',
  );

  /// Every collection the School module syncs, in pull order.
  static const all = <SchoolCollection>[
    students,
    teachers,
    books,
    bookLoans,
    libraryMembers,
    librarySettings,
    attendance,
    teacherAttendance,
    calendar,
    events,
    grades,
    gradeAttachments,
    fees,
    feeConfigs,
    feeSheets,
    feePayments,
    feeAdjustments,
    homerooms,
    auditLogs,
  ];

  /// Infixes of collections that share a box with a plain (infix-less) one.
  static const List<String> _reservedInfixes = [
    'std__',
    'tch__',
    'log__',
    'tchlog__',
    'mem__',
    'cfg__',
    'cal__',
    'evt__',
    'gatt__',
    'fcfg__',
    'fsht__',
    'fpay__',
    'fadj__',
  ];

  String key(String branchId, String id) => '${SchoolBranchId.normalize(branchId)}__$infix$id';

  /// The record id inside [rawKey] if the key belongs to this collection and
  /// (unless [branchId] is "all") to that branch. Null otherwise.
  String? idOfKey(Object? rawKey, String branchId) {
    final k = rawKey?.toString() ?? '';
    final keyBranch = SchoolBranchId.branchOfKey(k);
    if (keyBranch == null) return null;
    if (!SchoolBranchId.isAll(branchId) &&
        SchoolBranchId.normalize(keyBranch) != SchoolBranchId.normalize(branchId)) {
      return null;
    }
    final rest = k.substring(keyBranch.length + 2);
    if (infix.isEmpty) {
      // Plain boxes may share the logs box scheme; skip keys that carry a
      // known infix of another collection.
      if (_reservedInfixes.any(rest.startsWith)) return null;
      return rest.isEmpty ? null : rest;
    }
    if (!rest.startsWith(infix)) return null;
    final id = rest.substring(infix.length);
    return id.isEmpty ? null : id;
  }
}

abstract final class SchoolStore {
  // ── Box access ────────────────────────────────────────────────────────────
  static Future<Box> openBox(String name) async =>
      Hive.isBoxOpen(name) ? Hive.box(name) : await LocalStorageService.openBoxSafe(name);

  static Box? _boxIfOpen(String name) => Hive.isBoxOpen(name) ? Hive.box(name) : null;

  // ── Sanitising (Hive stores only plain values) ────────────────────────────
  static Map<String, dynamic> sanitize(Map input) {
    final out = <String, dynamic>{};
    input.forEach((k, v) => out[k.toString()] = _val(v));
    return out;
  }

  static dynamic _val(dynamic v) {
    if (v == null || v is String || v is int || v is double || v is bool) return v;
    if (v is DateTime) return v.toIso8601String();
    if (v is Timestamp) return v.toDate().toIso8601String();
    if (v is Map) return sanitize(v);
    if (v is List) return v.map(_val).toList();
    return v.toString();
  }

  // ── Reads ─────────────────────────────────────────────────────────────────

  /// All copies of one record across branch-alias keys.
  static List<Map<String, dynamic>> _copies(SchoolCollection c, String branchId, String id) {
    final box = _boxIfOpen(c.box);
    if (box == null) return const [];
    final out = <Map<String, dynamic>>[];
    for (final k in box.keys) {
      if (c.idOfKey(k, branchId) == id) {
        final v = box.get(k);
        if (v is Map) out.add(Map<String, dynamic>.from(v));
      }
    }
    return out;
  }

  /// One record (newest copy if it exists under several alias keys).
  static Map<String, dynamic>? get(SchoolCollection c, String branchId, String id) {
    final box = _boxIfOpen(c.box);
    if (box == null) return null;
    final direct = box.get(c.key(branchId, id));
    final copies = _copies(c, branchId, id);
    if (copies.isEmpty) return direct is Map ? Map<String, dynamic>.from(direct) : null;
    if (c.isDayLog) return SchoolMerge.combineDayLogs(copies);
    return _newest(copies);
  }

  /// Every record of [c] for [branchId] ("all" = every branch), with `id` set,
  /// one per id (newest copy wins).
  static List<Map<String, dynamic>> all(SchoolCollection c, String branchId) {
    final box = _boxIfOpen(c.box);
    if (box == null) return const [];
    final byId = <String, List<Map<String, dynamic>>>{};
    for (final k in box.keys) {
      final id = c.idOfKey(k, branchId);
      if (id == null) continue;
      final v = box.get(k);
      if (v is! Map) continue;
      // With "all", the same id in two real branches are two records.
      final group = SchoolBranchId.isAll(branchId)
          ? '${SchoolBranchId.normalize(SchoolBranchId.branchOfKey(k))}|$id'
          : id;
      (byId[group] ??= []).add(Map<String, dynamic>.from(v)..['id'] ??= id);
    }
    return byId.values.map((copies) {
      final rec = c.isDayLog ? SchoolMerge.combineDayLogs(copies)! : _newest(copies);
      return rec;
    }).toList();
  }

  static Stream<List<Map<String, dynamic>>> watchAll(SchoolCollection c, String branchId) async* {
    final box = await openBox(c.box);
    yield all(c, branchId);
    yield* box.watch().map((_) => all(c, branchId));
  }

  static Map<String, dynamic> _newest(List<Map<String, dynamic>> copies) {
    copies.sort((a, b) {
      final ta = SchoolMerge.recordTs(a) ?? DateTime(2000);
      final tb = SchoolMerge.recordTs(b) ?? DateTime(2000);
      return tb.compareTo(ta);
    });
    return copies.first;
  }

  // ── Writes ────────────────────────────────────────────────────────────────

  /// Saves a School record: merges [data] over the existing local copy (like
  /// Firestore `set(merge: true)`), stamps it, stores it under the canonical
  /// key, removes stale alias-key copies, and queues the upload.
  ///
  /// Returns the stored record. Never waits for the network.
  static Future<Map<String, dynamic>> put(
    SchoolCollection c, {
    required String branchId,
    required String id,
    required Map<String, dynamic> data,
    String? updatedBy,
    bool merge = true,
    DateTime? now,
  }) async {
    final branch = SchoolBranchId.normalize(branchId);
    if (branch == SchoolBranchId.all) {
      throw StateError('School records must be saved to a branch, not "all". Pick a branch first.');
    }
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'School record id must not be empty');
    }
    final box = await openBox(c.box);
    final at = (now ?? DateTime.now()).toIso8601String();

    final existing = merge ? get(c, branch, id) : null;
    final record = <String, dynamic>{
      ...?existing,
      ...sanitize(data),
      'id': id,
      'branchId': branch,
      'lastModified': at,
      'syncStatus': 'pending',
      'pendingSync': true,
      if (updatedBy != null && updatedBy.isNotEmpty) 'updatedBy': updatedBy,
    };

    final key = c.key(branch, id);
    await box.put(key, record);
    // Day logs keep alias copies (the biometric service writes there); reads merge them.
    if (!c.isDayLog) {
      for (final k in box.keys.toList()) {
        if (k != key && c.idOfKey(k, branch) == id) await box.delete(k);
      }
    }

    await _enqueue(c, branch, id, record, key);
    return record;
  }

  static Future<void> _enqueue(
    SchoolCollection c,
    String branch,
    String id,
    Map<String, dynamic> record,
    String localKey,
  ) async {
    try {
      await LocalStorageService.enqueueSync({
        'action': 'set',
        if (c.queueType != null) 'type': c.queueType,
        'branchId': branch,
        'collection': 'branches/$branch/${c.name}',
        'docId': id,
        if (c == SchoolCollection.students) 'studentId': id,
        'data': record,
        'localBox': c.box,
        'localKey': localKey,
      });
      unawaited(SyncService().triggerUpload(urgent: true));
    } catch (e) {
      // The record is safe in Hive; the backfill sweep re-queues pending School records.
      debugPrint('[SchoolStore] enqueue failed for ${c.name}/$id: $e');
    }
  }

  /// Stores a record that came FROM the cloud (no stamping, no upload).
  static Future<void> putFromCloud(SchoolCollection c, String branchId, String id, Map<String, dynamic> record) async {
    final box = await openBox(c.box);
    await box.put(c.key(branchId, id), sanitize(record));
  }

  // ── Audit ─────────────────────────────────────────────────────────────────

  /// Appends an audit entry. [before]/[after] hold only the fields that changed.
  static Future<void> audit({
    required String branchId,
    required String action,
    required String user,
    required String details,
    String? entity,
    String? entityId,
    Map<String, dynamic>? before,
    Map<String, dynamic>? after,
  }) async {
    final branch = SchoolBranchId.normalize(branchId);
    if (branch == SchoolBranchId.all) return; // nothing to attach it to
    final id = SchoolIds.auditId();
    try {
      await put(
        SchoolCollection.auditLogs,
        branchId: branch,
        id: id,
        merge: false,
        updatedBy: user,
        data: {
          'action': action,
          'user': user,
          'details': details,
          'timestamp': DateTime.now().toIso8601String(),
          if (entity != null) 'entity': entity,
          if (entityId != null) 'entityId': entityId,
          if (before != null && before.isNotEmpty) 'before': before,
          if (after != null && after.isNotEmpty) 'after': after,
        },
      );
    } catch (e) {
      debugPrint('[SchoolStore] audit failed ($action): $e');
    }
  }

  /// Fields of [after] that differ from [before], as `(before, after)` maps.
  /// Media/base64 blobs are summarised so audit entries stay small.
  static (Map<String, dynamic>, Map<String, dynamic>) diff(
    Map<String, dynamic>? before,
    Map<String, dynamic> after, {
    Set<String> ignore = const {'lastModified', 'syncStatus', 'pendingSync', 'synced', 'lastSyncedAt', 'updatedBy', 'updatedAt'},
  }) {
    final b = <String, dynamic>{};
    final a = <String, dynamic>{};
    String show(dynamic v) {
      final s = v?.toString() ?? '';
      return s.length > 200 ? '<${s.length} chars>' : s;
    }

    for (final k in {...?before?.keys, ...after.keys}) {
      if (ignore.contains(k)) continue;
      final ov = before?[k];
      final nv = after[k];
      if (ov?.toString() != nv?.toString()) {
        b[k] = show(ov);
        a[k] = show(nv);
      }
    }
    return (b, a);
  }
}
