import 'package:gmwf/services/cloud/cloud_db.dart';
import 'package:gmwf/services/cloud/lan_firestore_gate.dart';
import 'package:gmwf/services/network_health_service.dart';
import 'dart:async';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';
import 'package:rxdart/rxdart.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../services/sync_service.dart';
import '../services/local_storage_service.dart';
import '../services/camp_session_service.dart';
import '../realtime/realtime_manager.dart';
import '../realtime/realtime_events.dart';
import '../utils/formatters.dart';
import '../widgets/global_module_wrapper.dart';
import '../design/design_system.dart';
import '../utils/branch_labels.dart';

class RequestUtils {
  static String getTitle(String type, String patient) {
    return switch (type) {
      'dispense'            => 'Patient: $patient',
      'add_stock'           => 'Stock Request',
      'change_prescription' => 'Prescription Change',
      'token_reversal'      => 'Token Reversal',
      'edit_medicine'       => 'Edit Medicine Request',
      'delete_medicine'     => 'Delete Medicine Request',
      'patient_edit'        => 'Patient Edit: $patient',
      'token_exception'     => 'Token Exception: $patient',
      _                     => 'Request',
    };
  }

  static Color getBadgeColor(String type, {bool isDark = false}) => switch (type) {
        'dispense'            => isDark ? SoftPalette.teal550.withValues(alpha: 0.35) : SoftPalette.teal200,
        'add_stock'           => isDark ? SoftPalette.teal550.withValues(alpha: 0.35) : SoftPalette.teal200,
        'change_prescription' => isDark ? SoftPalette.teal550.withValues(alpha: 0.35) : SoftPalette.teal200,
        'token_reversal'      => isDark ? SoftPalette.red600.withValues(alpha: 0.35) : SoftPalette.red200,
        'edit_medicine'       => isDark ? SoftPalette.teal550.withValues(alpha: 0.35) : SoftPalette.teal200,
        'delete_medicine'     => isDark ? SoftPalette.red600.withValues(alpha: 0.35) : SoftPalette.red200,
        'patient_edit'        => isDark ? SoftPalette.orange600.withValues(alpha: 0.35) : SoftPalette.yellow100,
        'token_exception'     => isDark ? SoftPalette.red600.withValues(alpha: 0.35) : SoftPalette.amber150,
        _                     => isDark ? SoftPalette.slate700 : SoftPalette.gray150,
      };

  static Color getTextColor(String type, {bool isDark = false}) => switch (type) {
        'dispense'            => isDark ? SoftPalette.teal200 : SoftPalette.teal600,
        'add_stock'           => isDark ? SoftPalette.teal200 : SoftPalette.teal600,
        'change_prescription' => isDark ? SoftPalette.teal200 : SoftPalette.teal600,
        'token_reversal'      => isDark ? SoftPalette.red300 : SoftPalette.red550,
        'edit_medicine'       => isDark ? SoftPalette.teal200 : SoftPalette.teal600,
        'delete_medicine'     => isDark ? SoftPalette.red300 : SoftPalette.red550,
        'patient_edit'        => isDark ? SoftPalette.yellow150 : SoftPalette.orange350,
        'token_exception'     => isDark ? SoftPalette.amber200 : SoftPalette.orange400,
        _                     => isDark ? SoftPalette.gray150 : SoftPalette.gray700,
      };

  static String resolveRequestCampName(Map<String, dynamic> data, [String defaultBranch = 'karachi']) {
    // 1. Check direct fields
    String? rawCamp = data['campName']?.toString() ??
        data['campLabel']?.toString() ??
        data['campId']?.toString() ??
        data['dispensaryId']?.toString() ??
        data['camp']?.toString();

    // 2. Check draftItems / items
    if (rawCamp == null || rawCamp.isEmpty || rawCamp == 'all') {
      final items = data['items'] ?? data['draftItems'];
      if (items is List && items.isNotEmpty && items.first is Map) {
        rawCamp = items.first['campId']?.toString() ??
            items.first['dispensaryId']?.toString() ??
            items.first['campName']?.toString();
      }
    }

    // 3. Check originalData
    if (rawCamp == null || rawCamp.isEmpty || rawCamp == 'all') {
      final orig = data['originalData'];
      if (orig is Map) {
        rawCamp = orig['campId']?.toString() ??
            orig['dispensaryId']?.toString() ??
            orig['campName']?.toString();
      }
    }

    // 4. Check docId e.g. "saddar--..." or "kapayya--..." or "haji-camp--..."
    if (rawCamp == null || rawCamp.isEmpty || rawCamp == 'all') {
      final docId = (data['docId'] ?? data['id'] ?? '').toString().toLowerCase();
      if (docId.contains('saddar') || docId.contains('sadd') || docId.contains('kapay')) {
        rawCamp = 'saddar';
      } else if (docId.contains('haji')) {
        rawCamp = 'haji_camp';
      }
    }

    // 5. Check serial e.g. "KHI-SADD-1234", "KHI-KAP-1234", "KHI-HAJI-1234"
    if (rawCamp == null || rawCamp.isEmpty || rawCamp == 'all') {
      final serial = (data['serial'] ?? data['tokenSerial'] ?? '').toString().toUpperCase();
      if (serial.contains('-SADD-') || serial.contains('-KAP-') || serial.contains('SADDAR') || serial.contains('KAPAYYA')) {
        rawCamp = 'saddar';
      } else if (serial.contains('-HAJI-') || serial.contains('HAJI')) {
        rawCamp = 'haji_camp';
      }
    }

    if (rawCamp != null && rawCamp.isNotEmpty && rawCamp != 'all') {
      if (rawCamp.toLowerCase().contains('kapay')) {
        rawCamp = 'saddar';
      }
      return CampSessionService.getCampLabel(rawCamp);
    }

    final branch = (data['branchId'] ?? defaultBranch).toString().toLowerCase();
    if (CampSessionService.hasCampsForBranch(branch)) {
      final active = CampSessionService.getActiveCamp();
      if (active != null && active.isNotEmpty && active != 'all') {
        return CampSessionService.getCampLabel(active);
      }
      return 'Saddar Camp';
    }
    return branch.toUpperCase();
  }

  static String generateDocId(
    String name,
    String type,
    String doseOrVariant,
    String expiry, {
    int? distilledWater,
    int? drops,
    String? campId,
  }) {
    String clean(String s) => s
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '-')
        .replaceAll(RegExp(r'[^a-z0-9-]'), '');
    final cleanExpiry = clean(expiry);
    final activeCamp = (campId != null && campId.isNotEmpty) ? campId : CampSessionService.getActiveCamp();
    final campPrefix = (activeCamp != null && activeCamp.isNotEmpty && activeCamp != 'all') ? '${clean(activeCamp)}--' : '';
    if (type == 'Nebulization' && distilledWater != null && drops != null) {
      return '$campPrefix${clean(name)}--${clean(type)}--water${distilledWater}ml-drops$drops--$cleanExpiry';
    }
    return '$campPrefix${clean(name)}--${clean(type)}--${clean(doseOrVariant)}--$cleanExpiry';
  }
}

List<Map<String, dynamic>> _safeItemList(dynamic raw) {
  if (raw == null) return [];
  if (raw is! List) return [];
  return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
}

int _safeInt(dynamic v) {
  if (v == null) return 0;
  if (v is int) return v;
  if (v is double) return v.toInt();
  if (v is String) {
    return int.tryParse(v) ?? (double.tryParse(v)?.toInt() ?? 0);
  }
  return 0;
}

class RequestPage extends StatefulWidget {
  final String branchId;
  final bool isSupervisor;
  const RequestPage({super.key, required this.branchId, this.isSupervisor = false});

  @override
  State<RequestPage> createState() => _RequestPageState();
}

/// The Firestore write stream on Windows desktop can hang forever. Local state + LAN broadcast
/// are the source of truth here and the sync queue pushes to the cloud later, so a cloud write
/// must never block an approval: wait briefly, then carry on.
Future<void> _bestEffort(Future<dynamic> f, [String label = 'cloud write']) async {
  // No internet (or a desk whose LAN server does the uploading): the write cannot finish, so
  // do not make the user wait for the timeout on every approval. Local save + LAN broadcast +
  // the sync queue already carry the change.
  if (LanFirestoreGate.isLanDesk || !NetworkHealthService().isStableOnline) {
    unawaited(f.timeout(const Duration(seconds: 3)).then<void>((_) {}, onError: (Object e) {
      debugPrint('[RequestPage] $label skipped (queued for sync): $e');
    }));
    return;
  }
  try {
    await f.timeout(const Duration(seconds: 3));
  } catch (e) {
    debugPrint('[RequestPage] $label skipped (queued for sync): $e');
  }
}

class _RequestPageState extends State<RequestPage>
    with TickerProviderStateMixin {
  late final TabController _tabCtrl;
  String? _currentUserRole;
  String? _username;
  StreamSubscription<Map<String, dynamic>>? _realtimeSub;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 3, vsync: this);

    // Fetch current user details
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      try {
        if (Hive.isBoxOpen('app_settings')) {
          final box = Hive.box('app_settings');
          final uData = box.get('user_data') ?? box.get('currentUser');
          if (uData is Map && uData['role'] != null) {
            _currentUserRole = uData['role'].toString().toLowerCase().trim();
            _username = uData['username']?.toString();
          }
        }
      } catch (_) {}

      final effBId = (widget.branchId.isNotEmpty && widget.branchId != 'all')
          ? widget.branchId
          : (LocalStorageService.getActiveBranchId() ?? 'karachi');

      FirebaseFirestore.instance
          .collection('branches')
          .doc(effBId)
          .collection('users')
          .doc(uid)
          .get()
          .then((snap) {
        if (mounted && snap.exists) {
          setState(() {
            _currentUserRole = snap.data()?['role']?.toString().toLowerCase();
            _username = snap.data()?['username']?.toString();
          });
        }
      });
    }

    _realtimeSub = RealtimeManager().messageStream.listen((event) {
      final type = event['event_type'] as String?;
      if (!mounted) return;
      if (type == 'request_created' ||
          type == 'token_exception_request' ||
          type == 'save_inventory_edit_request' ||
          type == 'save_token_reversal_request' ||
          type == 'request_approved' ||
          type == 'request_rejected' ||
          type == 'token_reversal_approved' ||
          type == 'token_reversal_rejected') {
        if (mounted) setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _realtimeSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isWrapped = GlobalModuleWrapper.isWrapped(context);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        automaticallyImplyLeading: !isWrapped,
        toolbarHeight: isWrapped ? 0 : kToolbarHeight,
        backgroundColor: isDark ? SoftPalette.slate900 : SoftPalette.teal600,
        foregroundColor: SoftPalette.gray50,
        elevation: 0,
        title: isWrapped ? null : const Text('Requests',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        bottom: TabBar(
          controller: _tabCtrl,
          indicatorColor: isDark ? SoftPalette.teal300 : SoftPalette.gray50,
          labelColor: isDark ? SoftPalette.teal300 : SoftPalette.gray50,
          unselectedLabelColor: SoftPalette.gray50A70,
          tabs: const [
            Tab(text: 'Pending', icon: Icon(Icons.pending_actions)),
            Tab(text: 'Approved', icon: Icon(Icons.check_circle)),
            Tab(text: 'Rejected', icon: Icon(Icons.cancel)),
          ],
        ),
      ),
      body: SafeArea(
        child: TabBarView(
          controller: _tabCtrl,
          children: [
            _StableRequestTab(
              branchId: widget.branchId, 
              status: 'pending', 
              isSupervisor: widget.isSupervisor,
              currentUserRole: _currentUserRole,
              username: _username,
            ),
            _StableRequestTab(
              branchId: widget.branchId, 
              status: 'approved', 
              isSupervisor: widget.isSupervisor,
              currentUserRole: _currentUserRole,
              username: _username,
            ),
            _StableRequestTab(
              branchId: widget.branchId, 
              status: 'rejected', 
              isSupervisor: widget.isSupervisor,
              currentUserRole: _currentUserRole,
              username: _username,
            ),
          ],
        ),
      ),
    );
  }
}

class _StableRequestTab extends StatefulWidget {
  final String branchId;
  final String status;
  final bool isSupervisor;
  final String? currentUserRole;
  final String? username;
  const _StableRequestTab({
    required this.branchId, 
    required this.status,
    this.isSupervisor = false,
    this.currentUserRole,
    this.username,
  });

  @override
  State<_StableRequestTab> createState() => _StableRequestTabState();
}

class LocalRequestDoc {
  final String id;
  final Map<String, dynamic> _data;
  final String parentCollection;

  LocalRequestDoc({
    required this.id,
    required Map<String, dynamic> data,
    this.parentCollection = 'edit_requests',
  }) : _data = data;

  Map<String, dynamic> data() => _data;
  LocalRef get reference => LocalRef(parentCollection);
}

class LocalRef {
  final LocalParent parent;
  LocalRef(String parentId) : parent = LocalParent(parentId);
}

class LocalParent {
  final String id;
  LocalParent(this.id);
}

class _StableRequestTabState extends State<_StableRequestTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final Map<String, String> _nameCache = {};
  final List<StreamSubscription> _firestoreSubs = [];

  /// Branch doc each request was read from (shared by the tabs). A decision is written there
  /// only; writing it to every branch alias created half-empty request docs in the others.
  static final Map<String, String> _cloudBranchOf = {};

  /// Requests whose decision this device already re-sent in this app session.
  static final Set<String> _reasserted = {};

  /// This device decided the request (or heard the decision) but the cloud says pending
  /// again: an older PC's unsent "pending" write reached Firestore after the decision (the
  /// SDK keeps unsent writes on disk and sends them when the daily quota resets). Send the
  /// decision again through the upload queue, once per session.
  void _reassertDecision(Map existing, String docId, String col, String bId) {
    if (!_reasserted.add('$col/$docId')) return;
    final decision = <String, dynamic>{
      for (final f in ['reviewedAt', 'reviewedBy', 'reviewedByName', 'doctorReason', 'rejectionReason', 'acknowledgedAt'])
        if (existing[f] != null) f: existing[f],
    };
    debugPrint('[RequestPage] $col/$docId reverted to pending in the cloud; re-sending ${existing['status']}');
    unawaited(LocalStorageService.enqueueSync({
      'type': 'update_request_status',
      'requestId': docId,
      'collection': col,
      'branchId': bId,
      'cloudBranch': bId,
      'status': existing['status'],
      'requestStatus': existing['status'], // enqueueSync overwrites 'status' with the queue state
      'data': decision,
    }).then((_) => SyncService().triggerUpload()).catchError((_) {}));
  }
  bool _isApprovingAll = false;
  bool _toastShownForPending = false;

  @override
  void initState() {
    super.initState();
    _initDataAndSync();
  }

  @override
  void didUpdateWidget(_StableRequestTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.branchId != widget.branchId) {
      _cancelSubscriptions();
      _initDataAndSync();
    }
  }

  @override
  void dispose() {
    _cancelSubscriptions();
    super.dispose();
  }

  void _cancelSubscriptions() {
    for (final s in _firestoreSubs) {
      s.cancel();
    }
    _firestoreSubs.clear();
  }

  Future<void> _initDataAndSync() async {
    await _ensureBoxes();
    unawaited(_syncFromFirestore());
    _listenToFirestore();
  }

  Future<void> _ensureBoxes() async {
    if (!Hive.isBoxOpen('local_edit_requests')) {
      await LocalStorageService.openBoxSafe('local_edit_requests');
    }
    if (!Hive.isBoxOpen(LocalStorageService.restockRequestsBox)) {
      await LocalStorageService.openBoxSafe(LocalStorageService.restockRequestsBox);
    }
    if (mounted) setState(() {});
  }

  List<String> _resolveTargetBranches() {
    final b = widget.branchId.toLowerCase().trim();
    if (b.isEmpty || b == 'all' || b == 'global') {
      final Set<String> all = {'karachi', 'gujrat', 'grt', 'sialkot', 'skt', 'rawalpindi', 'rwp', 'main'};
      if (Hive.isBoxOpen(LocalStorageService.branchesBox)) {
        final box = Hive.box(LocalStorageService.branchesBox);
        for (final item in box.values) {
          if (item is Map && item['id'] != null) {
            all.add(item['id'].toString().toLowerCase().trim());
          }
        }
      }
      return all.toList();
    }
    if (b.contains('gujrat') || b == 'grt' || b == 'gjt') return ['gujrat', 'grt'];
    if (b.contains('sialkot') || b == 'skt') return ['sialkot', 'skt'];
    if (b.contains('rawalpindi') || b == 'rwp') return ['rawalpindi', 'rwp'];
    return [b];
  }

  Future<void> _syncFromFirestore() async {
    try {
      final branches = _resolveTargetBranches();
      if (!Hive.isBoxOpen('local_edit_requests')) {
        await LocalStorageService.openBoxSafe('local_edit_requests');
      }
      final box = Hive.box('local_edit_requests');

      for (final bId in branches) {
        for (final col in ['edit_requests', 'dispense_edit_requests', 'restock_requests']) {
          try {
            final snap = await FirebaseFirestore.instance
                .collection('branches')
                .doc(bId)
                .collection(col)
                .get(const GetOptions(source: Source.serverAndCache))
                .timeout(const Duration(seconds: 8));

            for (final doc in snap.docs) {
              final d = Map<String, dynamic>.from(doc.data());
              d['id'] ??= doc.id;
              d['requestId'] ??= doc.id;
              d['branchId'] ??= bId;
              d['collection'] = col;
              if (col == 'restock_requests' && d['type'] == null) {
                d['type'] = 'add_stock';
                d['requestType'] = 'add_stock';
              }
              for (final f in ['requestedAt', 'createdAt', 'reviewedAt', 'approvedAt']) {
                if (d[f] is Timestamp) {
                  d[f] = (d[f] as Timestamp).toDate().toIso8601String();
                }
              }
              // [CRITICAL FIX] Protect locally approved/rejected requests from stale remote pending snapshot
              final existing = box.get(doc.id) ??
                  (d['requestId'] != null ? box.get(d['requestId']) : null) ??
                  (Hive.isBoxOpen(LocalStorageService.restockRequestsBox)
                      ? (Hive.box(LocalStorageService.restockRequestsBox).get(doc.id) ?? (d['requestId'] != null ? Hive.box(LocalStorageService.restockRequestsBox).get(d['requestId']) : null))
                      : null);
              _cloudBranchOf[doc.id] = bId;
              if (existing is Map) {
                final remoteStatus = (d['status'] ?? 'pending').toString().toLowerCase().trim();
                if (LocalStorageService.isDecidedRequestStatus(existing['status']) &&
                    !LocalStorageService.isDecidedRequestStatus(remoteStatus)) {
                  _reassertDecision(existing, doc.id, col, bId);
                  continue; // Never revert a local resolution to pending!
                }
              }
              if (col == 'restock_requests' && Hive.isBoxOpen(LocalStorageService.restockRequestsBox)) {
                await Hive.box(LocalStorageService.restockRequestsBox).put(doc.id, d);
              }
              await box.put(doc.id, d);
            }
          } catch (e) {
            debugPrint('[RequestPage] sync $col error for $bId: $e');
          }
        }
      }
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('[RequestPage] _syncFromFirestore failed: $e');
    }
  }

  void _listenToFirestore() {
    _cancelSubscriptions();
    final branches = _resolveTargetBranches();
    for (final bId in branches) {
      for (final col in ['edit_requests', 'dispense_edit_requests', 'restock_requests']) {
        try {
          final sub = FirebaseFirestore.instance
              .collection('branches')
              .doc(bId)
              .collection(col)
              .snapshots()
              .listen((snap) {
            if (!Hive.isBoxOpen('local_edit_requests')) return;
            final box = Hive.box('local_edit_requests');
            for (final doc in snap.docs) {
              final d = Map<String, dynamic>.from(doc.data());
              d['id'] ??= doc.id;
              d['requestId'] ??= doc.id;
              d['branchId'] ??= bId;
              d['collection'] = col;
              if (col == 'restock_requests' && d['type'] == null) {
                d['type'] = 'add_stock';
                d['requestType'] = 'add_stock';
              }
              for (final f in ['requestedAt', 'createdAt', 'reviewedAt', 'approvedAt']) {
                if (d[f] is Timestamp) {
                  d[f] = (d[f] as Timestamp).toDate().toIso8601String();
                }
              }
              // [CRITICAL FIX] Protect locally approved/rejected requests from stale remote pending snapshot
              final existing = box.get(doc.id) ??
                  (d['requestId'] != null ? box.get(d['requestId']) : null) ??
                  (Hive.isBoxOpen(LocalStorageService.restockRequestsBox)
                      ? (Hive.box(LocalStorageService.restockRequestsBox).get(doc.id) ?? (d['requestId'] != null ? Hive.box(LocalStorageService.restockRequestsBox).get(d['requestId']) : null))
                      : null);
              _cloudBranchOf[doc.id] = bId;
              if (existing is Map) {
                final remoteStatus = (d['status'] ?? 'pending').toString().toLowerCase().trim();
                if (LocalStorageService.isDecidedRequestStatus(existing['status']) &&
                    !LocalStorageService.isDecidedRequestStatus(remoteStatus)) {
                  _reassertDecision(existing, doc.id, col, bId);
                  continue; // Never revert a local resolution to pending!
                }
              }
              if (col == 'restock_requests' && Hive.isBoxOpen(LocalStorageService.restockRequestsBox)) {
                Hive.box(LocalStorageService.restockRequestsBox).put(doc.id, d);
              }
              box.put(doc.id, d);
            }
            if (mounted) setState(() {});
          }, onError: (e) {
            debugPrint('[RequestPage] snapshot error on $col for $bId: $e');
          });
          _firestoreSubs.add(sub);
        } catch (_) {}
      }
    }
  }

  String _resolveRequesterName(String docId, Map<String, dynamic> data) {
    if (_nameCache.containsKey(docId)) return _nameCache[docId]!;

    final cached = (data['requesterName']?.toString() ?? '').trim();
    if (cached.isNotEmpty) {
      _nameCache[docId] = cached;
      return cached;
    }

    final requesterId = (data['requestedBy']?.toString() ??
            data['requester']?.toString() ??
            '')
        .trim();
    if (requesterId.isEmpty) {
      _nameCache[docId] = 'Unknown';
      return 'Unknown';
    }

    return requesterId;
  }

  static Map<String, dynamic> _deepConvertMap(dynamic source) {
    if (source == null || source is! Map) return {};
    final result = <String, dynamic>{};
    for (final e in source.entries) {
      final key = e.key.toString();
      final val = e.value;
      if (val is Map) {
        result[key] = _deepConvertMap(val);
      } else if (val is List) {
        result[key] = val.map((item) => item is Map ? _deepConvertMap(item) : item).toList();
      } else {
        result[key] = val;
      }
    }
    return result;
  }

  int _safeInt(dynamic val) {
    if (val == null) return 0;
    if (val is int) return val;
    if (val is double) return val.toInt();
    if (val is String) return int.tryParse(val) ?? 0;
    return 0;
  }

  List<Map<String, dynamic>> _safeItemList(dynamic list) {
    if (list == null || list is! List) return [];
    return list.whereType<Map>().map((e) => _deepConvertMap(e)).toList();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (!Hive.isBoxOpen('local_edit_requests')) {
      return const Center(
          child: CircularProgressIndicator(color: SoftPalette.teal500));
    }

    final editBox = Hive.box('local_edit_requests');
    final restockBox = Hive.isBoxOpen(LocalStorageService.restockRequestsBox)
        ? Hive.box(LocalStorageService.restockRequestsBox)
        : null;

    return ValueListenableBuilder<Box>(
      valueListenable: editBox.listenable(),
      builder: (context, box, _) {
        final targetBranch = widget.branchId.toLowerCase().trim();
    bool isBranchMatch(Map<String, dynamic> data) {
      if (targetBranch.isEmpty || targetBranch == 'all' || targetBranch == 'global') return true;
      final docBranch = (data['branchId'] ?? '').toString().toLowerCase().trim();
      if (docBranch.isEmpty) return true; // keep unspecified so requests are not hidden
      if (docBranch == targetBranch) return true;
      if (targetBranch.contains('gujrat') && (docBranch == 'grt' || docBranch == 'gjt' || docBranch.contains('gujrat'))) return true;
      if (targetBranch == 'grt' && (docBranch.contains('gujrat') || docBranch == 'gjt')) return true;
      if (targetBranch.contains('sialkot') && (docBranch == 'skt' || docBranch.contains('sialkot'))) return true;
      if (targetBranch == 'skt' && (docBranch.contains('sialkot'))) return true;
      if (targetBranch.contains('rawalpindi') && (docBranch == 'rwp' || docBranch.contains('rawalpindi'))) return true;
      if (targetBranch == 'rwp' && (docBranch.contains('rawalpindi'))) return true;
      return false;
    }

    final allDocs = <LocalRequestDoc>[];
    final seenIds = <String>{};

    void processEntry(dynamic key, dynamic val, String defaultCol) {
      if (val is Map) {
        final data = _deepConvertMap(val);
        if (!isBranchMatch(data)) return;
        final status = (data['status']?.toString() ?? 'pending').toLowerCase();
        if (status == widget.status.toLowerCase()) {
          final id = data['requestId']?.toString() ?? data['id']?.toString() ?? key.toString();
          if (seenIds.add(id)) {
            final col = data['collection']?.toString() ?? (data['type'] == 'dispense' ? 'dispense_edit_requests' : defaultCol);
            if (col == 'restock_requests' && data['type'] == null) {
              data['type'] = 'add_stock';
              data['requestType'] = 'add_stock';
            }
            allDocs.add(LocalRequestDoc(id: id, data: data, parentCollection: col));
          }
        }
      }
    }

    for (final entry in editBox.toMap().entries) {
      processEntry(entry.key, entry.value, 'edit_requests');
    }
    if (restockBox != null) {
      for (final entry in restockBox.toMap().entries) {
        processEntry(entry.key, entry.value, 'restock_requests');
      }
    }

    allDocs.sort((a, b) {
      final aData = a.data();
      final bData = b.data();
      final rawA = aData['requestedAt'] ?? aData['createdAt'];
      final rawB = bData['requestedAt'] ?? bData['createdAt'];
      final DateTime dtA = rawA is Timestamp ? rawA.toDate() : (rawA is String ? (DateTime.tryParse(rawA) ?? DateTime(1970)) : DateTime(1970));
      final DateTime dtB = rawB is Timestamp ? rawB.toDate() : (rawB is String ? (DateTime.tryParse(rawB) ?? DateTime(1970)) : DateTime(1970));
      return dtB.compareTo(dtA);
    });

        final role = (widget.currentUserRole ?? '').toLowerCase().trim();
        final isBranchManager = role.contains('branch manager') ||
            role.contains('branch_manager') ||
            role == 'bm' ||
            role.contains('manager');
        final isSupervisorRole = widget.isSupervisor ||
            role.contains('supervisor') ||
            isBranchManager ||
            role.contains('admin') ||
            role.contains('chairman') ||
            role.contains('ceo');
        final isDoctor = role.contains('doctor');
        final canApproveAny = isSupervisorRole || isDoctor;

        final eligibleDocs = allDocs.where((doc) {
          final data = doc.data();
          final requestType = data['requestType']?.toString() ??
              data['type']?.toString() ??
              'unknown';
          if (isSupervisorRole && requestType != 'token_exception') return true;
          if (isDoctor && requestType == 'token_exception') return true;
          return false;
        }).toList();

        if (widget.status == 'pending' && eligibleDocs.isNotEmpty && !_toastShownForPending) {
          _toastShownForPending = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              AppToast.showSnackBar(context, 
                SnackBar(
                  behavior: SnackBarBehavior.floating,
                  backgroundColor: SoftPalette.teal550,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  content: Row(
                    children: [
                      const Icon(Icons.notifications_active_rounded, color: SoftPalette.teal300, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'You have ${eligibleDocs.length} pending request${eligibleDocs.length > 1 ? "s" : ""} awaiting your approval',
                          style: const TextStyle(color: SoftPalette.gray50, fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                  duration: const Duration(seconds: 4),
                ),
              );
            }
          });
        }

        if (allDocs.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  widget.status == 'pending'
                      ? Icons.pending_actions_outlined
                      : widget.status == 'approved'
                          ? Icons.check_circle_outline
                          : Icons.cancel_outlined,
                  size: 80,
                  color: SoftPalette.teal500,
                ),
                const SizedBox(height: 16),
                Text(
                  widget.status == 'pending'
                      ? 'No Pending Requests'
                      : widget.status == 'approved'
                          ? 'No Approved Requests'
                          : 'No Rejected Requests',
                  style: const TextStyle(
                      color: SoftPalette.teal500,
                      fontSize: 20,
                      fontWeight: FontWeight.bold),
                ),
              ],
            ),
          );
        }

        return RefreshIndicator(
          onRefresh: () async {
            _nameCache.clear();
            _toastShownForPending = false;
            await _syncFromFirestore();
            if (mounted) setState(() {});
          },
          color: SoftPalette.teal500,
          child: Column(
            children: [
              if (widget.status == 'pending' && canApproveAny) ...[
                Builder(builder: (context) {
                  final isDark = Theme.of(context).brightness == Brightness.dark;
                  final hasEligible = eligibleDocs.isNotEmpty;
                  return Container(
                    margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: isDark ? SoftPalette.teal700.withValues(alpha: 0.4) : SoftPalette.teal100m,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isDark ? SoftPalette.teal500 : SoftPalette.teal300,
                        width: 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.pending_actions_rounded,
                            color: isDark ? SoftPalette.teal300 : SoftPalette.teal600, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            hasEligible
                                ? '${eligibleDocs.length} Pending Request${eligibleDocs.length > 1 ? 's' : ''} to Approve'
                                : '${allDocs.length} Pending Request${allDocs.length > 1 ? 's' : ''} (Other Roles)',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: isDark ? SoftPalette.gray50 : SoftPalette.teal700,
                            ),
                          ),
                        ),
                        if (hasEligible)
                          ElevatedButton.icon(
                            icon: _isApprovingAll
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: SoftPalette.gray50),
                                  )
                                : const Icon(Icons.done_all_rounded, size: 16),
                            label: Text(
                              _isApprovingAll ? 'Approving…' : 'Approve All (${eligibleDocs.length})',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: isDark ? SoftPalette.teal550 : SoftPalette.teal550,
                              foregroundColor: SoftPalette.gray50,
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              elevation: 2,
                            ),
                            onPressed: _isApprovingAll ? null : () => _confirmApproveAll(context, allDocs),
                          ),
                      ],
                    ),
                  );
                }),
              ],
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: allDocs.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (context, i) =>
                      _buildRequestCard(context, allDocs[i]),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildRequestCard(
      BuildContext context, dynamic doc) {
    try {
      final isDark      = Theme.of(context).brightness == Brightness.dark;
      final rawData     = doc is LocalRequestDoc ? doc.data() : (doc.data() is Map ? doc.data() : <String, dynamic>{});
      final data        = _deepConvertMap(rawData);
      final requestType = data['requestType']?.toString() ??
          data['type']?.toString() ??
          'unknown';
      final collection  = doc.reference.parent.id;
      final patientName = data['patientName']?.toString() ?? '—';
      final rawTs       = data['requestedAt'] ?? data['createdAt'];
      final ts          = rawTs is Timestamp 
          ? rawTs 
          : (rawTs is DateTime 
              ? Timestamp.fromDate(rawTs) 
              : (rawTs is String && DateTime.tryParse(rawTs) != null 
                  ? Timestamp.fromDate(DateTime.parse(rawTs)) 
                  : null));
      final reason      = data['reason']?.toString() ?? '';
      final name        = _resolveRequesterName(doc.id, data);
      final approverName = data['reviewedByName'] ?? data['approvedByName'];
      final docReason   = data['doctorReason']?.toString() ?? '';

      String amountText = '';
      if (requestType == 'token_reversal') {
        final queueType =
            (data['queueType'] as String?)?.toLowerCase() ?? 'zakat';
        if (queueType.contains('non')) {
          amountText = 'Rs. 100';
        } else if (queueType.contains('gmwf')) {
          amountText = 'PKR 0';
        } else {
          amountText = 'Rs. 20';
        }
      }

      final role = (widget.currentUserRole ?? '').toLowerCase().trim();
      final isBranchManager = role.contains('branch manager') || role.contains('branch_manager') || role == 'bm' || role.contains('manager');
      final isSupervisorRole = widget.isSupervisor || role.contains('supervisor') || isBranchManager || role.contains('admin') || role.contains('chairman') || role.contains('ceo');
      final isDoctor = role.contains('doctor');

      final canApproveAsSupervisor = isSupervisorRole && requestType != 'token_exception';
      final canApproveAsDoctor = isDoctor && requestType == 'token_exception';

      final campLabel = RequestUtils.resolveRequestCampName(data, widget.branchId);

      return Card(
        color: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
        elevation: widget.status == 'pending' ? (isDark ? 3 : 5) : 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: isDark ? SoftPalette.slate700 : SoftPalette.teal100,
            width: 1,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                  child: Text(
                    RequestUtils.getTitle(requestType, patientName),
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: isDark ? SoftPalette.teal200 : SoftPalette.teal600,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: isDark ? SoftPalette.sky500.withValues(alpha: 0.25) : SoftPalette.slate100,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isDark ? SoftPalette.sky350.withValues(alpha: 0.4) : SoftPalette.slate150,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.holiday_village_rounded, size: 14, color: isDark ? SoftPalette.sky350 : SoftPalette.sky550),
                      const SizedBox(width: 5),
                      Text(
                        campLabel.toUpperCase(),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: isDark ? SoftPalette.sky350 : SoftPalette.sky550,
                          letterSpacing: 0.4,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: RequestUtils.getBadgeColor(requestType, isDark: isDark),
                    borderRadius: BorderRadius.circular(20),
                    border: isDark
                        ? Border.all(
                            color: RequestUtils.getTextColor(requestType, isDark: isDark).withValues(alpha: 0.4),
                            width: 1,
                          )
                        : null,
                  ),
                  child: Text(
                    requestType.replaceAll('_', ' ').toUpperCase(),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: RequestUtils.getTextColor(requestType, isDark: isDark),
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Icon(Icons.person_rounded, size: 16, color: isDark ? SoftPalette.teal300 : SoftPalette.teal600),
                const SizedBox(width: 8),
                Text(
                  'By: $name',
                  style: TextStyle(fontSize: 13.5, color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87),
                ),
              ]),
              const SizedBox(height: 4),
              Row(children: [
                Icon(Icons.location_on_rounded, size: 16, color: isDark ? SoftPalette.sky350 : SoftPalette.teal600),
                const SizedBox(width: 8),
                Expanded(
                  child: RichText(
                    text: TextSpan(
                      style: TextStyle(
                        fontSize: 13,
                        color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87,
                      ),
                      children: [
                        const TextSpan(text: 'Facility Camp: '),
                        TextSpan(
                          text: campLabel,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: isDark ? SoftPalette.sky350 : SoftPalette.teal700,
                          ),
                        ),
                        TextSpan(
                          text: ' (${(data['branchId'] ?? widget.branchId).toString().toUpperCase()})',
                          style: TextStyle(fontSize: 11.5, color: isDark ? SoftPalette.gray50A38 : SoftPalette.gray500),
                        ),
                      ],
                    ),
                  ),
                ),
              ]),
              if (ts != null) ...[
                const SizedBox(height: 4),
                Row(children: [
                  Icon(Icons.schedule_rounded, size: 14, color: isDark ? SoftPalette.gray50A38 : SoftPalette.gray900A38),
                  const SizedBox(width: 6),
                  Text(
                    'Requested: ${DateFormat('dd MMM yyyy, hh:mm a').format(ts.toDate())}',
                    style: TextStyle(fontSize: 12, color: isDark ? SoftPalette.gray50A54 : SoftPalette.gray900A54),
                  ),
                ]),
              ],
              if (widget.status == 'approved') ...[
                const SizedBox(height: 6),
                Row(children: [
                  Icon(Icons.verified_user_rounded, size: 14, color: isDark ? SoftPalette.emerald300 : SoftPalette.teal550),
                  const SizedBox(width: 6),
                  Text(
                    'Approved by: ${approverName ?? 'Doctor'}',
                    style: TextStyle(
                      fontSize: 12, 
                      color: isDark ? SoftPalette.emerald300 : SoftPalette.teal550, 
                      fontWeight: FontWeight.bold
                    ),
                  ),
                ]),
              ],
              if (widget.status == 'rejected') ...[
                const SizedBox(height: 6),
                Row(children: [
                  Icon(Icons.remove_circle_rounded, size: 14, color: isDark ? SoftPalette.red350 : SoftPalette.red500),
                  const SizedBox(width: 6),
                  Text(
                    'Rejected by: ${approverName ?? 'Doctor'}',
                    style: TextStyle(
                      fontSize: 12, 
                      color: isDark ? SoftPalette.red350 : SoftPalette.red500, 
                      fontWeight: FontWeight.bold
                    ),
                  ),
                ]),
              ],
              if (amountText.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  'Amount: $amountText',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.bold,
                    color: isDark ? SoftPalette.teal300 : SoftPalette.teal600,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              if (requestType == 'patient_edit')
                _buildPatientChanges(data, doc.id, collection)
              else if (requestType == 'edit_medicine')
                _buildMedicineEditChanges(data)
              else if (requestType == 'token_reversal')
                _buildTokenReversalView(data)
              else if (requestType == 'token_exception')
                _buildTokenExceptionView(data)
              else if (data['items'] != null || data['draftItems'] != null)
                _buildItemsView(data, doc.id, requestType),

              if (reason.isNotEmpty) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.slate150),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Requester Reason:',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                          color: isDark ? SoftPalette.gray50A60 : SoftPalette.gray900A54,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        reason,
                        style: TextStyle(
                          fontSize: 13,
                          color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (docReason.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: isDark ? SoftPalette.teal700.withValues(alpha: 0.3) : SoftPalette.teal100m,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: isDark ? SoftPalette.teal500 : SoftPalette.teal300),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Approval Reason:',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                          color: isDark ? SoftPalette.teal200 : SoftPalette.teal700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        docReason,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: isDark ? SoftPalette.gray50 : SoftPalette.teal600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 14),
              if (widget.status == 'pending')
                if (canApproveAsSupervisor || canApproveAsDoctor)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: SoftPalette.red400,
                          side: BorderSide(color: SoftPalette.red400),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        ),
                        onPressed: () => _updateStatus(context, doc.id,
                            'rejected', requestType, collection),
                        child: const Text('Reject', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isDark ? SoftPalette.teal550 : SoftPalette.teal550,
                          foregroundColor: SoftPalette.gray50,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                          elevation: 1,
                        ),
                        onPressed: () => _updateStatus(context, doc.id,
                            'approved', requestType, collection),
                        child: const Text('Approve', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ],
                  )
                else if (isSupervisorRole && requestType == 'token_exception')
                  _buildDoctorOnlyNotice()
                else
                  Align(
                    alignment: Alignment.centerRight,
                    child: Chip(
                      label: const Text('PENDING APPROVAL'),
                      backgroundColor: isDark ? SoftPalette.orange700.withValues(alpha: 0.4) : SoftPalette.amber300.withValues(alpha: 0.1),
                      labelStyle: TextStyle(
                          color: isDark ? SoftPalette.amber200 : SoftPalette.orange400,
                          fontWeight: FontWeight.bold,
                          fontSize: 10),
                    ),
                  )
              else
                Align(
                  alignment: Alignment.centerRight,
                  child: Chip(
                    label: Text(widget.status.toUpperCase()),
                    backgroundColor: widget.status == 'approved' 
                        ? (isDark ? SoftPalette.emerald700 : SoftPalette.teal500.withValues(alpha: 0.15))
                        : (isDark ? SoftPalette.red700 : SoftPalette.red400.withValues(alpha: 0.1)),
                    labelStyle: TextStyle(
                        color: widget.status == 'approved' 
                            ? (isDark ? SoftPalette.emerald200 : SoftPalette.teal600)
                            : (isDark ? SoftPalette.red300 : SoftPalette.red550),
                        fontWeight: FontWeight.bold),
                  ),
                ),
            ],
          ),
        ),
      );
    } catch (e, stack) {
      debugPrint('[RequestCard Error] ${doc.id}: $e\n$stack');
      return Card(
        color: context.adapt(SoftPalette.pink100m),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: SoftPalette.red300),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(Icons.error_outline_rounded, color: SoftPalette.red400, size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Could not display request (${doc.id})', style: const TextStyle(fontWeight: FontWeight.bold, color: SoftPalette.red400, fontSize: 13)),
                    const SizedBox(height: 2),
                    Text('$e', style: TextStyle(fontSize: 11, color: context.adapt(SoftPalette.red550))),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
  }

  Widget _buildItemsView(
      Map<String, dynamic> data, String requestId, String requestType) {
    final items = widget.status == 'pending'
        ? (_safeItemList(data['draftItems']).isNotEmpty
            ? _safeItemList(data['draftItems'])
            : _safeItemList(data['items']))
        : _safeItemList(data['items']);

    final isWide = !GBreakpoint.isMobile(context);
    return isWide
        ? _buildTable(items, requestId, requestType)
        : _buildCompactItems(items, requestId, requestType);
  }

  Widget _buildTable(List<Map<String, dynamic>> items, String requestId,
      String requestType) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final canEdit = widget.status == 'pending';
    return Container(
      decoration: BoxDecoration(
        color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.slate150),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowColor: WidgetStateProperty.all(isDark ? SoftPalette.slate800 : SoftPalette.teal100m),
          columns: const [
            DataColumn(label: Text('Formula', style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(label: Text('Type', style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(label: Text('Dose', style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(label: Text('Qty', style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(label: Text('Price', style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(label: Text('Expiry', style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(label: Text('Edit', style: TextStyle(fontWeight: FontWeight.bold))),
          ],
          rows: List<DataRow>.generate(items.length, (index) {
            final m = items[index];
            return DataRow(cells: [
              DataCell(Text(m['name']?.toString() ?? '', style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87))),
              DataCell(Row(children: [
                _typeIcon(m['type']),
                const SizedBox(width: 6),
                Text(m['type']?.toString() ?? '', style: TextStyle(color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87))
              ])),
              DataCell(Text(m['dose']?.toString() ?? '', style: TextStyle(color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87))),
              DataCell(Text('${m['quantity'] ?? 0}', style: TextStyle(color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87))),
              DataCell(Text('PKR ${m['price'] ?? 0}', style: TextStyle(color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87))),
              DataCell(Text(_formatDate(m['expiryDate']), style: TextStyle(color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87))),
              DataCell(
                canEdit
                    ? IconButton(
                        icon: Icon(Icons.edit_outlined, size: 18, color: isDark ? SoftPalette.teal300 : SoftPalette.teal600),
                        onPressed: () =>
                            _showEditItemDialog(requestId, index, m),
                      )
                    : const SizedBox.shrink(),
              ),
            ]);
          }),
        ),
      ),
    );
  }

  Widget _buildCompactItems(List<Map<String, dynamic>> items,
      String requestId, String requestType) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final canEdit = widget.status == 'pending';
    return Column(
      children: List<Widget>.generate(items.length, (index) {
        final m       = items[index];
        final name    = m['name']?.toString() ?? '';
        final type    = m['type']?.toString() ?? '';
        final dose    = (m['dose']?.toString().isNotEmpty == true)
            ? ' ${m['dose']}'
            : '';
        final qty    = m['quantity'] ?? 0;
        final price  = m['price'] ?? 0;
        final expiry = _formatDate(m['expiryDate']);
        return InkWell(
          onTap: canEdit
              ? () => _showEditItemDialog(requestId, index, m)
              : null,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 3),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.slate150),
            ),
            child: Row(children: [
              _typeIcon(type),
              const SizedBox(width: 8),
              Expanded(
                child: RichText(
                  text: TextSpan(
                    style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87),
                    children: [
                      TextSpan(
                          text: '$name ($type$dose) × $qty',
                          style: const TextStyle(
                              fontWeight: FontWeight.w600)),
                      TextSpan(
                          text: '\nPKR $price | $expiry',
                          style: TextStyle(
                              fontSize: 12, color: isDark ? SoftPalette.gray50A54 : SoftPalette.gray900A54)),
                    ],
                  ),
                ),
              ),
              canEdit
                  ? IconButton(
                      icon: Icon(Icons.edit_outlined,
                          size: 18, color: isDark ? SoftPalette.teal300 : SoftPalette.teal600),
                      onPressed: () =>
                          _showEditItemDialog(requestId, index, m),
                    )
                  : const SizedBox.shrink(),
            ]),
          ),
        );
      }),
    );
  }

  Widget _typeIcon(dynamic rawType) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final t    = rawType?.toString() ?? 'Others';
    final icon = switch (t) {
      'Tablet'      => FontAwesomeIcons.tablets,
      'Capsule'     => FontAwesomeIcons.capsules,
      'Syrup'       => FontAwesomeIcons.bottleDroplet,
      'Injection'   => FontAwesomeIcons.syringe,
      'Big Bottle'  => FontAwesomeIcons.prescriptionBottleAlt,
      'Nebulization' => FontAwesomeIcons.cloud,
      _             => FontAwesomeIcons.pills,
    };
    return Icon(icon, size: 16, color: isDark ? SoftPalette.teal300 : SoftPalette.teal600);
  }

  Widget _buildPatientChanges(
      Map<String, dynamic> data, String requestId, String collection) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final originalData = data['originalData'] is Map ? _deepConvertMap(data['originalData']) : <String, dynamic>{};
    final proposedRaw  = widget.status == 'pending'
        ? (data['draftData'] ?? data['proposedData'])
        : data['proposedData'];
    final proposedData = proposedRaw is Map ? _deepConvertMap(proposedRaw) : <String, dynamic>{};

    // Standard human labels for patient fields
    final fieldLabels = <String, String>{
      'name': 'Full Name',
      'patientName': 'Patient Name',
      'cnic': 'CNIC',
      'guardianCnic': 'Guardian CNIC',
      'isAdult': 'Patient Type',
      'dob': 'Date of Birth',
      'age': 'Age',
      'phone': 'Phone Number',
      'bloodGroup': 'Blood Group',
      'status': 'Status / Category',
      'gender': 'Gender',
      'address': 'Address',
      'city': 'City',
      'guardianName': 'Guardian Name',
      'relation': 'Relation',
    };

    // Build the ordered list of keys to display
    final standardKeys = [
      'name',
      'cnic',
      'guardianCnic',
      'isAdult',
      'dob',
      'age',
      'phone',
      'bloodGroup',
      'gender',
      'status',
      'address',
      'city',
      'guardianName',
      'relation',
    ];

    final ignoredKeys = {
      '_id', 'id', 'updatedAt', 'createdAt', 'branchId', 'createdBy',
      'createdByName', 'lastEditedAt', 'lastEditedBy', 'draftData',
      'proposedData', 'originalData', 'dispensaryId', 'campId', 'facility',
      'requestedAt', 'requestedBy', 'requestedByName', 'reviewedAt',
      'reviewedBy', 'reviewedByName', 'requestType', 'type', 'reason',
      'doctorReason', 'status_request', 'vitals',
    };

    final allKeysSet = <String>{};
    for (final k in standardKeys) {
      if (originalData.containsKey(k) || proposedData.containsKey(k)) {
        allKeysSet.add(k);
      }
    }
    // Also include other keys in proposedData or originalData
    for (final k in proposedData.keys) {
      if (!ignoredKeys.contains(k)) allKeysSet.add(k);
    }
    for (final k in originalData.keys) {
      if (!ignoredKeys.contains(k)) allKeysSet.add(k);
    }

    // Default fallback to core fields if nothing matched
    final fields = allKeysSet.isEmpty
        ? ['name', 'cnic', 'guardianCnic', 'isAdult', 'dob', 'age', 'phone', 'bloodGroup', 'gender', 'status']
        : allKeysSet.toList();

    String getValue(Map<String, dynamic> m, String key) {
      final v = m[key];
      if (v == null || v.toString().trim().isEmpty || v.toString().trim() == 'null') {
        return '—';
      }
      if (key == 'dob') {
        return _formatDate(v);
      }
      if (key == 'isAdult') {
        if (v == true || v.toString().toLowerCase() == 'true') return 'Adult';
        if (v == false || v.toString().toLowerCase() == 'false') return 'Child';
      }
      if (key == 'status' || key == 'queueType') {
        return BranchLabels.text(v.toString().trim(), widget.branchId);
      }
      return v.toString().trim();
    }

    String getLabel(String key) {
      if (fieldLabels.containsKey(key)) return fieldLabels[key]!;
      if (key.isEmpty) return key;
      // Convert camelCase to Title Case
      final result = key.replaceAllMapped(RegExp(r'([A-Z])'), (m) => ' ${m.group(1)}');
      return result[0].toUpperCase() + result.substring(1).trim();
    }

    final isWide = !GBreakpoint.isMobile(context);

    return Container(
      decoration: BoxDecoration(
        color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? SoftPalette.slate700 : SoftPalette.slate150,
          width: 1,
        ),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.compare_arrows_rounded,
                  size: 18, color: isDark ? SoftPalette.teal300 : SoftPalette.teal600),
              const SizedBox(width: 6),
              Text(
                'Patient Data Comparison',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13.5,
                  color: isDark ? SoftPalette.teal200 : SoftPalette.teal700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (isWide)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowHeight: 36,
                dataRowMinHeight: 32,
                dataRowMaxHeight: 48,
                headingRowColor: WidgetStateProperty.all(
                  isDark ? SoftPalette.slate800 : SoftPalette.teal100m,
                ),
                columns: [
                  DataColumn(
                    label: Text(
                      'Field',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12.5,
                        color: isDark ? SoftPalette.gray50 : SoftPalette.teal700,
                      ),
                    ),
                  ),
                  DataColumn(
                    label: Text(
                      'Original',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12.5,
                        color: isDark ? SoftPalette.gray50 : SoftPalette.teal700,
                      ),
                    ),
                  ),
                  DataColumn(
                    label: Text(
                      'Proposed',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12.5,
                        color: isDark ? SoftPalette.gray50 : SoftPalette.teal700,
                      ),
                    ),
                  ),
                ],
                rows: fields.map((f) {
                  final oldVal = getValue(originalData, f);
                  final newVal = getValue(proposedData, f);
                  final isChanged = oldVal != newVal && newVal != '—';

                  return DataRow(
                    cells: [
                      DataCell(Text(
                        getLabel(f),
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87,
                        ),
                      )),
                      DataCell(Text(
                        oldVal,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: isDark ? SoftPalette.gray50A60 : SoftPalette.gray900A87,
                          decoration: isChanged ? TextDecoration.lineThrough : null,
                          decorationColor: SoftPalette.red400,
                        ),
                      )),
                      DataCell(
                        isChanged
                            ? Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: isDark ? SoftPalette.sky550.withValues(alpha: 0.3) : SoftPalette.slate100,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: isDark ? SoftPalette.sky350 : SoftPalette.sky350,
                                    width: 1,
                                  ),
                                ),
                                child: Text(
                                  newVal,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.bold,
                                    color: isDark ? SoftPalette.sky300 : SoftPalette.blue600,
                                  ),
                                ),
                              )
                            : Text(
                                newVal,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: isDark ? SoftPalette.gray50A60 : SoftPalette.gray900A87,
                                ),
                              ),
                      ),
                    ],
                  );
                }).toList(),
              ),
            )
          else
            Column(
              children: fields.map((f) {
                final oldVal = getValue(originalData, f);
                final newVal = getValue(proposedData, f);
                final isChanged = oldVal != newVal && newVal != '—';

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 3,
                        child: Text(
                          '${getLabel(f)}:',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87,
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 3,
                        child: Text(
                          oldVal,
                          style: TextStyle(
                            fontSize: 12,
                            color: isChanged ? SoftPalette.red400 : (isDark ? SoftPalette.gray50A60 : SoftPalette.gray900A87),
                            decoration: isChanged ? TextDecoration.lineThrough : null,
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Icon(Icons.arrow_forward_rounded,
                            size: 14, color: isDark ? SoftPalette.teal300 : SoftPalette.teal500),
                      ),
                      Expanded(
                        flex: 4,
                        child: Text(
                          newVal,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: isChanged ? FontWeight.bold : FontWeight.normal,
                            color: isChanged
                                ? (isDark ? SoftPalette.sky300 : SoftPalette.blue600)
                                : (isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          if (widget.status == 'pending') ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: ElevatedButton.icon(
                onPressed: () => _showEditPatientDialog(
                    requestId, proposedData, originalData),
                icon: const Icon(Icons.edit_note_rounded, size: 16, color: SoftPalette.gray50),
                label: const Text('Edit Proposed', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isDark ? SoftPalette.teal550 : SoftPalette.teal550,
                  foregroundColor: SoftPalette.gray50,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  elevation: 1,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMedicineEditChanges(Map<String, dynamic> data) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final originalData = data['originalData'] is Map ? _deepConvertMap(data['originalData']) : <String, dynamic>{};
    final items = widget.status == 'pending'
        ? (_safeItemList(data['draftItems']).isNotEmpty
            ? _safeItemList(data['draftItems'])
            : _safeItemList(data['items']))
        : _safeItemList(data['items']);
    
    if (items.isEmpty) return const SizedBox.shrink();
    final proposedData = items[0];

    final fields = [
      {'key': 'name', 'label': 'Formula'},
      {'key': 'type', 'label': 'Type'},
      {'key': 'dose', 'label': 'Dose'},
      {'key': 'quantity', 'label': 'Qty'},
      {'key': 'price', 'label': 'Price'},
      {'key': 'expiryDate', 'label': 'Expiry'},
    ];

    String getValue(Map<String, dynamic> m, String key) {
      final v = m[key];
      if (key == 'price' && v != null && v.toString().isNotEmpty) {
        return 'PKR ${v.toString()}';
      }
      if (key == 'expiryDate') {
        return _formatDate(v);
      }
      return v?.toString() ?? '—';
    }

    final isWide = !GBreakpoint.isMobile(context);

    return Container(
      decoration: BoxDecoration(
        color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.slate150),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Medicine Comparison', 
            style: TextStyle(
              fontWeight: FontWeight.bold, 
              fontSize: 13.5, 
              color: isDark ? SoftPalette.teal200 : SoftPalette.teal700,
            )),
          const SizedBox(height: 8),
          if (isWide)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowHeight: 36,
                dataRowMinHeight: 32,
                dataRowMaxHeight: 48,
                headingRowColor: WidgetStateProperty.all(isDark ? SoftPalette.slate800 : SoftPalette.teal100m),
                columns: const [
                  DataColumn(label: Text('Field', style: TextStyle(fontWeight: FontWeight.bold))),
                  DataColumn(label: Text('Original', style: TextStyle(fontWeight: FontWeight.bold))),
                  DataColumn(label: Text('Proposed', style: TextStyle(fontWeight: FontWeight.bold))),
                ],
                rows: fields.map((f) {
                  final key = f['key']!;
                  final label = f['label']!;
                  final oldVal = getValue(originalData, key);
                  final newVal = getValue(proposedData, key);
                  final isChanged = oldVal != newVal && newVal != '—';
                  
                  return DataRow(cells: [
                    DataCell(Text(label, style: TextStyle(fontSize: 12.5, color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87))),
                    DataCell(Text(oldVal, style: TextStyle(
                      fontSize: 12.5,
                      color: isDark ? SoftPalette.gray50A60 : SoftPalette.gray900A87,
                      decoration: isChanged ? TextDecoration.lineThrough : null,
                      decorationColor: SoftPalette.red400,
                    ))),
                    DataCell(Text(newVal, style: TextStyle(
                      fontSize: 12.5,
                      color: isChanged ? (isDark ? SoftPalette.sky300 : SoftPalette.blue600) : (isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87),
                      fontWeight: isChanged ? FontWeight.bold : FontWeight.normal,
                    ))),
                  ]);
                }).toList(),
              ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: fields.map((f) {
                final key = f['key']!;
                final label = f['label']!;
                final oldVal = getValue(originalData, key);
                final newVal = getValue(proposedData, key);
                if (oldVal == newVal || newVal == '—') return const SizedBox.shrink();

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(flex: 3, child: Text('$label:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87))),
                      Expanded(flex: 3, child: Text(oldVal, style: const TextStyle(decoration: TextDecoration.lineThrough, color: SoftPalette.red400, fontSize: 12))),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Icon(Icons.arrow_forward_rounded, size: 12, color: isDark ? SoftPalette.teal300 : SoftPalette.teal500),
                      ),
                      Expanded(flex: 4, child: Text(newVal, style: TextStyle(fontWeight: FontWeight.bold, color: isDark ? SoftPalette.sky300 : SoftPalette.blue600, fontSize: 12))),
                    ],
                  ),
                );
              }).toList(),
            ),
        ],
      ),
    );
  }

  Widget _buildTokenReversalView(Map<String, dynamic> data) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tokenSerial = data['tokenSerial']?.toString() ??
        data['tokenId']?.toString() ??
        '—';
    final patientId = data['patientId']?.toString() ?? '—';
    final queueType = data['queueType']?.toString() ?? 'unknown';
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.slate150),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text("Token Details:",
            style: TextStyle(
                fontWeight: FontWeight.bold, color: isDark ? SoftPalette.teal200 : SoftPalette.teal600)),
        const SizedBox(height: 6),
        Text("Token Serial: $tokenSerial", style: TextStyle(color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87)),
        Text("Patient ID: $patientId", style: TextStyle(color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87)),
        Text("Queue: ${BranchLabels.text(queueType, data['branchId']?.toString() ?? widget.branchId)}", style: TextStyle(color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87)),
      ]),
    );
  }

  Widget _buildTokenExceptionView(Map<String, dynamic> data) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final restriction = data['restriction'] is Map ? _deepConvertMap(data['restriction']) : null;
    final patientId  = data['patientId']?.toString() ?? '—';
    final remDays    = restriction?['remainingDays'] ?? '—';
    final isLastDay  = restriction?['isLastDay'] == true;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? SoftPalette.orange700.withValues(alpha: 0.3) : SoftPalette.amber100m,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isDark ? SoftPalette.orange500 : SoftPalette.amber200),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.warning_amber_rounded, color: isDark ? SoftPalette.amber200 : SoftPalette.orange400, size: 20),
          const SizedBox(width: 8),
          Text("Restriction Details:", style: TextStyle(fontWeight: FontWeight.bold, color: isDark ? SoftPalette.amber150 : SoftPalette.orange400)),
        ]),
        const SizedBox(height: 8),
        Text("Patient ID: $patientId", style: TextStyle(color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87)),
        Text(isLastDay 
          ? "Status: Medicine expires TODAY"
          : "Status: Medicine expires in $remDays days",
          style: TextStyle(fontWeight: FontWeight.w600, color: isDark ? SoftPalette.amber200 : SoftPalette.orange400)),
      ]),
    );
  }

  Widget _buildDoctorOnlyNotice() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? SoftPalette.blue700.withValues(alpha: 0.3) : SoftPalette.slate100,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: isDark ? SoftPalette.blue500 : SoftPalette.sky300),
      ),
      child: Row(children: [
        Icon(Icons.info_outline, size: 16, color: isDark ? SoftPalette.blue300 : SoftPalette.blue550),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            "This request must be reviewed by a Doctor.",
            style: TextStyle(
              fontSize: 12, 
              color: isDark ? SoftPalette.blue300 : SoftPalette.blue550, 
              fontWeight: FontWeight.bold
            ),
          ),
        ),
      ]),
    );
  }

  String _formatDate(dynamic raw) {
    if (raw == null) return '—';
    if (raw is Timestamp) {
      return DateFormat('dd-MM-yyyy').format(raw.toDate());
    }
    if (raw is DateTime) {
      return DateFormat('dd-MM-yyyy').format(raw);
    }
    if (raw is String) {
      final str = raw.trim();
      if (str.isEmpty || str == 'null') return '—';
      // First attempt: ISO-8601 (e.g. 2023-06-12T00:00:00.000)
      final dt = DateTime.tryParse(str);
      if (dt != null) {
        return DateFormat('dd-MM-yyyy').format(dt);
      }
      final parsed = _tryParseDateString(str);
      if (parsed != null) return DateFormat('dd-MM-yyyy').format(parsed);
      return str;
    }
    return raw.toString();
  }

  DateTime? _tryParseDateString(String s) {
    final ddmmyyyy = RegExp(r'^(\d{2})[-\/](\d{2})[-\/](\d{4})$');
    final yyyymmdd = RegExp(r'^(\d{4})[-\/](\d{2})[-\/](\d{2})$');
    var m = ddmmyyyy.firstMatch(s);
    if (m != null) {
      return DateTime(int.parse(m.group(3)!), int.parse(m.group(2)!),
          int.parse(m.group(1)!));
    }
    m = yyyymmdd.firstMatch(s);
    if (m != null) {
      return DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!),
          int.parse(m.group(3)!));
    }
    return null;
  }

  Future<void> _showEditPatientDialog(String requestId,
      Map<String, dynamic> proposed, Map<String, dynamic> original) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    bool isChild = original['isAdult'] == false;
    final cnicCtrl = TextEditingController(
      text: isChild
          ? (original['guardianCnic']?.toString() ?? '')
          : (original['cnic']?.toString() ?? ''),
    );
    final nameCtrl = TextEditingController(
        text: proposed['name']?.toString() ??
            original['name']?.toString() ??
            '');
    final phoneCtrl = TextEditingController(
        text: proposed['phone']?.toString() ??
            original['phone']?.toString() ??
            '');
    final dobCtrl        = TextEditingController();
    final bloodGroupCtrl = TextEditingController(
        text: proposed['bloodGroup']?.toString() ??
            original['bloodGroup']?.toString() ??
            'N/A');
    String selectedStatus = proposed['status']?.toString() ??
        original['status']?.toString() ??
        'Zakat';
    String selectedGender = proposed['gender']?.toString() ??
        original['gender']?.toString() ??
        'Male';

    if (proposed['dob'] != null || original['dob'] != null) {
      final date = (proposed['dob'] as Timestamp?)?.toDate() ??
          (original['dob'] as Timestamp?)?.toDate();
      if (date != null) {
        dobCtrl.text = DateFormat('dd-MM-yyyy').format(date);
      } else {
        dobCtrl.text = _formatDate(proposed['dob'] ?? original['dob']);
        if (dobCtrl.text == '—') dobCtrl.text = '';
      }
    }

    final dialogBg = isDark ? SoftPalette.slate800 : SoftPalette.gray50;
    final fieldBg  = isDark ? SoftPalette.slate900 : SoftPalette.gray50;
    final borderSide = isDark ? const BorderSide(color: SoftPalette.slate700) : BorderSide(color: SoftPalette.teal300);

    await showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          backgroundColor: dialogBg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: isDark ? const BorderSide(color: SoftPalette.slate700) : BorderSide.none,
          ),
          title: Row(children: [
            Icon(Icons.edit_note_rounded, color: isDark ? SoftPalette.teal300 : SoftPalette.teal600),
            const SizedBox(width: 8),
            Text("Edit Proposed Changes",
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: isDark ? SoftPalette.teal200 : SoftPalette.teal700)),
          ]),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: fieldBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.teal200),
                ),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("Patient Type",
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87,
                          )),
                      Row(children: [
                        Expanded(
                            child: RadioListTile<bool>(
                                title: Text("Adult", style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87)),
                                value: false,
                                groupValue: isChild,
                                activeColor: isDark ? SoftPalette.teal300 : SoftPalette.teal550,
                                onChanged: (v) =>
                                    setState(() => isChild = v!))),
                        Expanded(
                            child: RadioListTile<bool>(
                                title: Text("Child", style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87)),
                                value: true,
                                groupValue: isChild,
                                activeColor: isDark ? SoftPalette.teal300 : SoftPalette.teal550,
                                onChanged: (v) =>
                                    setState(() => isChild = v!))),
                      ]),
                    ]),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: cnicCtrl,
                readOnly: true,
                style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87),
                decoration: InputDecoration(
                  labelText: isChild ? "Guardian CNIC" : "CNIC",
                  labelStyle: TextStyle(color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87),
                  prefixIcon:
                      Icon(Icons.badge, color: isDark ? SoftPalette.teal300 : SoftPalette.teal600),
                  filled: true,
                  fillColor: fieldBg,
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: borderSide),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: isDark ? SoftPalette.teal300 : SoftPalette.teal500)),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameCtrl,
                style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87),
                decoration: InputDecoration(
                  labelText: "Full Name",
                  labelStyle: TextStyle(color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87),
                  prefixIcon:
                      Icon(Icons.person, color: isDark ? SoftPalette.teal300 : SoftPalette.teal600),
                  filled: true,
                  fillColor: fieldBg,
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: borderSide),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: isDark ? SoftPalette.teal300 : SoftPalette.teal500)),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: phoneCtrl,
                style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87),
                decoration: InputDecoration(
                  labelText: "Phone (optional)",
                  labelStyle: TextStyle(color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87),
                  prefixIcon:
                      Icon(Icons.phone, color: isDark ? SoftPalette.teal300 : SoftPalette.teal600),
                  filled: true,
                  fillColor: fieldBg,
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: borderSide),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: isDark ? SoftPalette.teal300 : SoftPalette.teal500)),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: dobCtrl,
                style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87),
                decoration: InputDecoration(
                  labelText: "DOB (dd-MM-yyyy)",
                  labelStyle: TextStyle(color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87),
                  prefixIcon:
                      Icon(Icons.cake, color: isDark ? SoftPalette.teal300 : SoftPalette.teal600),
                  filled: true,
                  fillColor: fieldBg,
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: borderSide),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: isDark ? SoftPalette.teal300 : SoftPalette.teal500)),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: bloodGroupCtrl,
                style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87),
                decoration: InputDecoration(
                  labelText: "Blood Group",
                  labelStyle: TextStyle(color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87),
                  prefixIcon: Icon(Icons.bloodtype,
                      color: isDark ? SoftPalette.teal300 : SoftPalette.teal600),
                  filled: true,
                  fillColor: fieldBg,
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: borderSide),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: isDark ? SoftPalette.teal300 : SoftPalette.teal500)),
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: Text("Status",
                    style: TextStyle(fontWeight: FontWeight.bold, color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87)),
              ),
              Row(children: [
                Expanded(child: RadioListTile<String>(
                    title: Text(BranchLabels.zakat(widget.branchId), style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87, fontSize: 12)),
                    value: "Zakat",
                    groupValue: selectedStatus,
                    activeColor: isDark ? SoftPalette.teal300 : SoftPalette.teal550,
                    onChanged: (v) =>
                        setState(() => selectedStatus = v!))),
                Expanded(child: RadioListTile<String>(
                    title: Text(BranchLabels.nonZakat(widget.branchId), style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87, fontSize: 12)),
                    value: "Non-Zakat",
                    groupValue: selectedStatus,
                    activeColor: isDark ? SoftPalette.teal300 : SoftPalette.teal550,
                    onChanged: (v) =>
                        setState(() => selectedStatus = v!))),
                Expanded(child: RadioListTile<String>(
                    title: Text("GMWF", style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87, fontSize: 12)),
                    value: "GMWF",
                    groupValue: selectedStatus,
                    activeColor: isDark ? SoftPalette.teal300 : SoftPalette.teal550,
                    onChanged: (v) =>
                        setState(() => selectedStatus = v!))),
              ]),
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerLeft,
                child: Text("Gender",
                    style: TextStyle(fontWeight: FontWeight.bold, color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87)),
              ),
              Row(children: [
                Expanded(child: RadioListTile<String>(
                    title: Text("Male", style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87, fontSize: 12)),
                    value: "Male",
                    groupValue: selectedGender,
                    activeColor: isDark ? SoftPalette.teal300 : SoftPalette.teal550,
                    onChanged: (v) =>
                        setState(() => selectedGender = v!))),
                Expanded(child: RadioListTile<String>(
                    title: Text("Female", style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87, fontSize: 12)),
                    value: "Female",
                    groupValue: selectedGender,
                    activeColor: isDark ? SoftPalette.teal300 : SoftPalette.teal550,
                    onChanged: (v) =>
                        setState(() => selectedGender = v!))),
                Expanded(child: RadioListTile<String>(
                    title: Text("Other", style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87, fontSize: 12)),
                    value: "Other",
                    groupValue: selectedGender,
                    activeColor: isDark ? SoftPalette.teal300 : SoftPalette.teal550,
                    onChanged: (v) =>
                        setState(() => selectedGender = v!))),
              ]),
            ]),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text("Cancel",
                  style: TextStyle(color: isDark ? SoftPalette.gray50A70 : SoftPalette.teal600)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: isDark ? SoftPalette.teal550 : SoftPalette.teal550,
                foregroundColor: SoftPalette.gray50,
              ),
              onPressed: () async {
                DateTime? dob;
                if (dobCtrl.text.isNotEmpty) {
                  dob = parseDobDateTime(dobCtrl.text);
                }
                final newProposed = <String, dynamic>{
                  'name': nameCtrl.text.trim(),
                  'phone': phoneCtrl.text.trim().isNotEmpty
                      ? phoneCtrl.text.trim()
                      : null,
                  'status': selectedStatus,
                  'bloodGroup': bloodGroupCtrl.text.trim().isNotEmpty
                      ? bloodGroupCtrl.text.trim()
                      : 'N/A',
                  'gender': selectedGender,
                  'isAdult': !isChild,
                  if (dob != null) 'dob': Timestamp.fromDate(dob),
                  if (isChild)  'guardianCnic': cnicCtrl.text.trim(),
                  if (!isChild) 'cnic': cnicCtrl.text.trim(),
                };
                await FirebaseFirestore.instance
                    .collection('branches')
                    .doc(widget.branchId)
                    .collection('edit_requests')
                    .doc(requestId)
                    .update({'draftData': newProposed});
                Navigator.pop(ctx);
                AppToast.showSnackBar(context, 
                    const SnackBar(content: Text('Draft updated')));
              },
              child: const Text("Save Draft"),
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _showReasonPrompt(BuildContext context, String action) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: isDark ? const BorderSide(color: SoftPalette.slate700) : BorderSide.none,
        ),
        title: Text(
          '${action == 'approved' ? 'Approval' : 'Rejection'} Reason',
          style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87),
        ),
        content: TextField(
          controller: ctrl,
          style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87),
          decoration: InputDecoration(
            hintText: 'Enter reason for $action...',
            hintStyle: TextStyle(color: isDark ? SoftPalette.gray50A54 : SoftPalette.gray350),
            filled: true,
            fillColor: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: isDark ? SoftPalette.slate700 : SoftPalette.gray150),
            ),
          ),
          maxLines: 3,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray350)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: action == 'approved'
                  ? (isDark ? SoftPalette.teal550 : SoftPalette.teal500)
                  : SoftPalette.red400,
              foregroundColor: SoftPalette.gray50,
            ),
            onPressed: () {
              if (ctrl.text.trim().isEmpty) {
                AppToast.showSnackBar(context, 
                  const SnackBar(content: Text('Reason is required'))
                );
                return;
              }
              Navigator.pop(ctx, ctrl.text.trim());
            },
            child: Text(action.toUpperCase()),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmApproveAll(
      BuildContext context, List<dynamic> allDocs) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final role = (widget.currentUserRole ?? '').toLowerCase().trim();
    final isBranchManager = role.contains('branch manager') ||
        role.contains('branch_manager') ||
        role == 'bm' ||
        role.contains('manager');
    final isSupervisorRole = widget.isSupervisor ||
        role.contains('supervisor') ||
        isBranchManager ||
        role.contains('admin') ||
        role.contains('chairman') ||
        role.contains('ceo');
    final isDoctor = role.contains('doctor');

    // Filter documents the current user is eligible to approve
    final eligibleDocs = allDocs.where((doc) {
      final data = doc.data() as Map<String, dynamic>;
      final requestType = data['requestType']?.toString() ??
          data['type']?.toString() ??
          'unknown';
      if (isSupervisorRole && requestType != 'token_exception') return true;
      if (isDoctor && requestType == 'token_exception') return true;
      return false;
    }).toList();

    if (eligibleDocs.isEmpty) {
      AppToast.showSnackBar(context, 
        const SnackBar(
          content: Text('No requests eligible for your role to approve.'),
          backgroundColor: SoftPalette.amber300,
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: isDark ? const BorderSide(color: SoftPalette.slate700) : BorderSide.none,
        ),
        title: Row(
          children: [
            Icon(Icons.done_all_rounded, color: isDark ? SoftPalette.teal300 : SoftPalette.teal550, size: 26),
            const SizedBox(width: 10),
            Text(
              'Approve All Requests?',
              style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87),
            ),
          ],
        ),
        content: Text(
          'Are you sure you want to approve all ${eligibleDocs.length} pending request${eligibleDocs.length > 1 ? 's' : ''}?\n\n'
          'This will execute and update inventory, tokens, and records for all pending items at once.',
          style: TextStyle(color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: isDark ? SoftPalette.gray50A60 : SoftPalette.gray350)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: isDark ? SoftPalette.teal550 : SoftPalette.teal550,
              foregroundColor: SoftPalette.gray50,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Approve All (${eligibleDocs.length})'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isApprovingAll = true);

    int approvedCount = 0;
    int errorCount = 0;

    String? reviewerName = widget.username;
    final reviewerUid = FirebaseAuth.instance.currentUser?.uid;
    if (reviewerName == null && reviewerUid != null) {
      try {
        final userDoc = await FirebaseFirestore.instance
            .collection('branches')
            .doc(widget.branchId)
            .collection('users')
            .doc(reviewerUid)
            .get();
        reviewerName = userDoc.data()?['username']?.toString();
      } catch (_) {}
    }

    for (final doc in eligibleDocs) {
      try {
        final data = doc.data() as Map<String, dynamic>;
        final requestType = data['requestType']?.toString() ??
            data['type']?.toString() ??
            'unknown';
        final collection = doc.reference.parent.id;
        final docId = doc.id;

        await _processSingleDocApproval(
          docId: docId,
          data: data,
          requestType: requestType,
          collection: collection,
          reviewerUid: reviewerUid,
          reviewerName: reviewerName,
          docReason: 'Approved in bulk',
        );
        approvedCount++;
      } catch (e) {
        debugPrint('Error bulk approving ${doc.id}: $e');
        errorCount++;
      }
    }

    try {
      await SyncService().forceFullRefresh(widget.branchId);
    } catch (_) {}

    if (mounted) {
      setState(() => _isApprovingAll = false);
      AppToast.showSnackBar(context, 
        SnackBar(
          content: Text(
            errorCount == 0
                ? '✅ Successfully approved all $approvedCount requests!'
                : '✅ Approved $approvedCount requests ($errorCount failed).',
          ),
          backgroundColor: errorCount == 0 ? SoftPalette.teal550 : SoftPalette.amber300,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _processSingleDocApproval({
    required String docId,
    required Map<String, dynamic> data,
    required String requestType,
    required String collection,
    required String? reviewerUid,
    required String? reviewerName,
    String? docReason,
  }) async {
    // 1. Update local Hive request immediately
    if (Hive.isBoxOpen('local_edit_requests')) {
      final box = Hive.box('local_edit_requests');
      final current = box.get(docId) ?? data;
      if (current is Map) {
        final updated = Map<String, dynamic>.from(current)
          ..addAll({
            'status': 'approved',
            'reviewedAt': DateTime.now().toIso8601String(),
            'reviewedBy': reviewerUid,
            if (reviewerName != null) 'reviewedByName': reviewerName,
            if (docReason != null) 'doctorReason': docReason,
          });
        await box.put(docId, updated);
      }
    }
    if (Hive.isBoxOpen(LocalStorageService.restockRequestsBox)) {
      final box = Hive.box(LocalStorageService.restockRequestsBox);
      final current = box.get(docId);
      if (current is Map) {
        final updated = Map<String, dynamic>.from(current)
          ..addAll({
            'status': 'approved',
            'reviewedAt': DateTime.now().toIso8601String(),
            'reviewedBy': reviewerUid,
            if (reviewerName != null) 'reviewedByName': reviewerName,
            if (docReason != null) 'doctorReason': docReason,
          });
        await box.put(docId, updated);
      }
    }

    final targetBranch = (data['branchId']?.toString().isNotEmpty == true && data['branchId'] != 'all' && data['branchId'] != 'global')
        ? data['branchId'].toString()
        : ((widget.branchId.isNotEmpty && widget.branchId != 'all' && widget.branchId != 'global') ? widget.branchId : 'gujrat');

    // Only the branch doc the request lives in (writing to every alias made empty docs).
    final candidateBranches = {_cloudBranchOf[docId] ?? targetBranch};
    for (final bId in candidateBranches) {
      try {
        final ref = CloudDb.instance
            .collection('branches')
            .doc(bId)
            .collection(collection)
            .doc(docId);

        await _bestEffort(ref.set({
          'status':     'approved',
          'reviewedAt': FieldValue.serverTimestamp(),
          'reviewedBy': reviewerUid,
          if (reviewerName != null) 'reviewedByName': reviewerName,
          if (docReason != null) 'doctorReason': docReason,
        }, SetOptions(merge: true)));
      } catch (e) {
        debugPrint('[RequestPage] Firestore direct approval failed for $bId: $e');
      }
    }

    // Always enqueue in offline sync queue so it persists and is pushed to cloud
    await LocalStorageService.enqueueSync({
      'type': 'update_request_status',
      'requestId': docId,
      'id': docId,
      'status': 'approved',
      'requestStatus': 'approved', // enqueueSync overwrites 'status' with the queue state
      'collection': collection,
      'branchId': targetBranch,
      if (_cloudBranchOf[docId] != null) 'cloudBranch': _cloudBranchOf[docId],
      'reviewedAt': DateTime.now().toIso8601String(),
      'reviewedBy': reviewerUid,
      if (reviewerName != null) 'reviewedByName': reviewerName,
      if (docReason != null) 'doctorReason': docReason,
    });

    // Broadcast request_approved to server and all workstations
    try {
      RealtimeManager().sendMessage({
        'event_type': 'request_approved',
        'branchId': targetBranch,
        'requestId': docId,
        'id': docId,
        'docId': docId,
        'status': 'approved',
        'collection': collection,
        'reviewedAt': DateTime.now().toIso8601String(),
        'reviewedBy': reviewerUid,
        if (reviewerName != null) 'reviewedByName': reviewerName,
        if (docReason != null) 'doctorReason': docReason,
      });
    } catch (e) {
      debugPrint('[RequestPage] Failed to broadcast request_approved: $e');
    }

    final reqCampId = data['dispensaryId']?.toString() ??
        data['campId']?.toString() ??
        data['dispensaryTag']?.toString();

    if (requestType == 'patient_edit') {
      final patientId = data['patientId'] as String?;
      final toApplyRaw = data['draftData'] ?? data['proposedData'];
      final toApply   = toApplyRaw is Map ? _deepConvertMap(toApplyRaw) : null;

      if (toApply == null ||
          toApply.isEmpty ||
          patientId == null ||
          patientId.isEmpty) {
        return;
      }

      final patientsRef = FirebaseFirestore.instance
          .collection('branches')
          .doc(widget.branchId)
          .collection('patients');

      await _bestEffort(patientsRef.doc(patientId).update(toApply), 'patient update');

      try {
        if (Hive.isBoxOpen(LocalStorageService.patientsBox)) {
          final box = Hive.box(LocalStorageService.patientsBox);
          final existing = box.get('patient:$patientId') ?? box.get(patientId);
          if (existing is Map) {
            final updated = Map<String, dynamic>.from(existing)..addAll(toApply);
            LocalStorageService.saveLocalPatient(updated, isFromSync: true);
          } else {
            LocalStorageService.saveLocalPatient(toApply, isFromSync: true);
          }
        } else {
          LocalStorageService.saveLocalPatient(toApply, isFromSync: true);
        }
        await LocalStorageService.updateActiveEntriesForPatient(widget.branchId, patientId, toApply);
      } catch (e) {
        debugPrint('Hive patient update error: $e');
      }

      try {
        final sanitizedChanges = LocalStorageService.sanitize(toApply);
        RealtimeManager().sendMessage({
          'event_type': 'patient_edit_approved',
          'data': {
            'branchId': widget.branchId,
            'patientId': patientId,
            'changes': sanitizedChanges,
          },
        });
      } catch (e) {
        debugPrint('Failed to broadcast patient edit: $e');
      }
    }
    else if (requestType == 'token_reversal') {
      final tokenSerial = data['tokenSerial'] as String? ??
          data['tokenId']     as String?;
      if (tokenSerial == null || tokenSerial.isEmpty) return;

      final queueTypeRaw    =
          (data['queueType'] as String?)?.toLowerCase() ?? 'zakat';
      final queueCollection = queueTypeRaw.contains('non')
          ? 'non-zakat'
          : (queueTypeRaw.contains('gmwf') ||
                  queueTypeRaw.contains('gm wf'))
              ? 'gmwf'
              : 'zakat';

      final parts = tokenSerial.split('-');
      final dateKey = (parts.isNotEmpty && parts[0].toUpperCase() == 'X')
          ? (parts.length > 1 ? parts[1] : '')
          : (parts.isNotEmpty ? parts[0] : '');

      // Local delete + LAN broadcast FIRST so the token reverses instantly everywhere.
      await LocalStorageService.deleteLocalEntry(widget.branchId, tokenSerial);
      await LocalStorageService.enqueueSync({
        'type': 'token_reversal',
        'branchId': widget.branchId,
        'serial': tokenSerial,
        'dateKey': dateKey,
        'data': {
          'tokenSerial': tokenSerial,
          'queueType': queueCollection,
          'dateKey': dateKey,
        },
      });
      unawaited(_bestEffort(FirebaseFirestore.instance
          .collection('branches')
          .doc(widget.branchId)
          .collection('serials')
          .doc(dateKey)
          .collection(queueCollection)
          .doc(tokenSerial)
          .delete(), 'token delete'));

      try {
        RealtimeManager().sendMessage({
          'event_type': 'token_reversal_approved',
          'data': {
            'branchId':    widget.branchId,
            'tokenSerial': tokenSerial,
            'queueType':   queueCollection,
            'dateKey':     dateKey,
          },
        });
      } catch (e) {
        debugPrint('Failed to broadcast token reversal: $e');
      }

    }
    else if (requestType == 'add_stock') {
      final itemsToUse = _safeItemList(data['draftItems']).isNotEmpty
          ? _safeItemList(data['draftItems'])
          : _safeItemList(data['items']);

      if (itemsToUse.isNotEmpty) {
        await _handleAddStock(itemsToUse, campId: reqCampId);
      }
    }
    else if (requestType == 'edit_medicine') {
      final itemsToUse = _safeItemList(data['draftItems']).isNotEmpty
          ? _safeItemList(data['draftItems'])
          : _safeItemList(data['items']);
      if (itemsToUse.isNotEmpty) {
        await _handleEditMedicine(itemsToUse, reviewerUid ?? '', reviewerName, campId: reqCampId);
      }
    }
    else if (requestType == 'delete_medicine') {
      final itemsToUse = _safeItemList(data['draftItems']).isNotEmpty
          ? _safeItemList(data['draftItems'])
          : _safeItemList(data['items']);
      if (itemsToUse.isNotEmpty) {
        await _handleDeleteMedicine(itemsToUse, campId: reqCampId);
      }
    }
    else if (requestType == 'change_prescription') {
      final itemsToUse = _safeItemList(data['draftItems']).isNotEmpty
          ? _safeItemList(data['draftItems'])
          : _safeItemList(data['items']);
      if (itemsToUse.isNotEmpty) {
        await _handleChangePrescription(data, itemsToUse);
      }
    }
    else if (requestType == 'token_exception') {
      final patientId = data['patientId']?.toString();
      final medicineName = data['medicineName']?.toString();
      
      if (patientId != null) {
        final restrictionsRef = FirebaseFirestore.instance
            .collection('branches')
            .doc(widget.branchId)
            .collection('medicine_restrictions');
        
        unawaited(_bestEffort(restrictionsRef.doc(patientId).delete(), 'restriction delete'));

        await LocalStorageService.grantTokenException(
          widget.branchId,
          patientId,
          reason: docReason ?? 'Approved by Doctor/Supervisor',
          approvedBy: reviewerName ?? 'Doctor',
          requestId: docId,
        );

        RealtimeManager().sendMessage({
          ...RealtimeEvents.payload(
            type: RealtimeEvents.tokenExceptionApproved,
            branchId: widget.branchId,
            data: {
              'requestId': docId,
              'patientId': patientId,
              'reason': docReason ?? 'Approved by Doctor',
              'approvedBy': reviewerName ?? 'Doctor',
              'medicineName': medicineName,
            },
          ),
        });
      }
    }
    else if (requestType == 'register_medicine') {
      final itemsToUse = _safeItemList(data['draftItems']).isNotEmpty
          ? _safeItemList(data['draftItems'])
          : _safeItemList(data['items']);
      
      if (itemsToUse.isNotEmpty) {
        final inventory = FirebaseFirestore.instance
            .collection('branches')
            .doc(widget.branchId)
            .collection('inventory');
        
        for (final item in itemsToUse) {
          final name = item['name']?.toString() ?? '';
          final type = item['type'] ?? '';
          final dose = item['dose'] ?? '';
          final exp  = item['expiryDate'] ?? '';
          
          final id = RequestUtils.generateDocId(name, type, dose, exp, campId: reqCampId);
          
          final docData = <String, dynamic>{
            ...item,
            'addedAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
            'isVerified': true,
            'createdBy': data['requestedBy'],
            'createdByName': data['requesterName'],
            'approvedBy': reviewerUid,
            'approvedByName': reviewerName ?? 'Supervisor',
          };
          if (reqCampId != null && reqCampId.isNotEmpty) {
            docData['dispensaryId'] = reqCampId;
            docData['dispensaryTag'] = CampSessionService.getDispensaryKeyword(reqCampId);
          }
          
          unawaited(_bestEffort(inventory.doc(id).set(docData), 'register medicine'));

          // Save locally to Hive stockBox and broadcast immediately via LAN/WebSocket
          final localStockData = <String, dynamic>{
            ...item,
            'id': id,
            'branchId': widget.branchId,
            'isVerified': true,
            'addedAt': DateTime.now().toIso8601String(),
            'updatedAt': DateTime.now().toIso8601String(),
            if (reqCampId != null && reqCampId.isNotEmpty) 'dispensaryId': reqCampId,
            if (reqCampId != null && reqCampId.isNotEmpty) 'dispensaryTag': CampSessionService.getDispensaryKeyword(reqCampId),
          };
          LocalStorageService.saveLocalInventoryItem(localStockData);

          RealtimeManager().sendMessage({
            ...RealtimeEvents.payload(
              type: RealtimeEvents.saveStockItem,
              branchId: widget.branchId,
              data: localStockData,
            ),
          });
          
          unawaited(_bestEffort(FirebaseFirestore.instance
              .collection('branches')
              .doc(widget.branchId)
              .collection('inventory_log')
              .add({
            'action': 'medicine_registered',
            'medicineName': name,
            'medicineType': type,
            'dose': dose,
            'quantityAdded': _safeInt(item['quantity']),
            'price': item['price'],
            'expiryDate': exp,
            'performedBy': reviewerUid,
            'performedByName': reviewerName ?? 'Supervisor',
            'timestamp': FieldValue.serverTimestamp(),
            'docId': id,
            'approvedRequestId': docId,
            if (reqCampId != null) 'dispensaryId': reqCampId,
          }), 'inventory log'));
        }
      }
    }
  }

  Future<void> _updateStatus(
    BuildContext context,
    String docId,
    String newStatus,
    String requestType,
    String collection,
  ) async {
    // If it's a token exception, prompt for a reason first
    String? docReason;
    if (requestType == 'token_exception') {
      docReason = await _showReasonPrompt(context, newStatus);
      if (docReason == null) return; // User cancelled
    }

    // 1. Resolve local request data from Hive first
    Map<String, dynamic> data = {};
    if (Hive.isBoxOpen('local_edit_requests')) {
      final box = Hive.box('local_edit_requests');
      final raw = box.get(docId);
      if (raw is Map) data = Map<String, dynamic>.from(raw);
    }
    if (data.isEmpty && Hive.isBoxOpen(LocalStorageService.restockRequestsBox)) {
      final box = Hive.box(LocalStorageService.restockRequestsBox);
      final raw = box.get(docId);
      if (raw is Map) data = Map<String, dynamic>.from(raw);
    }

    final targetBranch = (data['branchId']?.toString().isNotEmpty == true && data['branchId'] != 'all' && data['branchId'] != 'global')
        ? data['branchId'].toString()
        : ((widget.branchId.isNotEmpty && widget.branchId != 'all' && widget.branchId != 'global') ? widget.branchId : 'gujrat');

    final ref = FirebaseFirestore.instance
        .collection('branches')
        .doc(targetBranch)
        .collection(collection)
        .doc(docId);

    try {
      String? reviewerName;
      final reviewerUid = FirebaseAuth.instance.currentUser?.uid;
      if (reviewerUid != null) {
        final userDoc = await FirebaseFirestore.instance
            .collection('branches')
            .doc(targetBranch)
            .collection('users')
            .doc(reviewerUid)
            .get();
        reviewerName = userDoc.data()?['username']?.toString();
      }

      if (data.isEmpty) {
        try {
          final snap = await ref.get().timeout(const Duration(seconds: 2));
          if (snap.exists && snap.data() != null) {
            data = snap.data() as Map<String, dynamic>;
          }
        } catch (_) {}
      }

      if (newStatus == 'approved') {
        await _processSingleDocApproval(
          docId: docId,
          data: data,
          requestType: requestType,
          collection: collection,
          reviewerUid: reviewerUid,
          reviewerName: reviewerName,
          docReason: docReason,
        );

        await SyncService().forceFullRefresh(targetBranch);
      } else {
        // Update local Hive box immediately
        if (Hive.isBoxOpen('local_edit_requests')) {
          final box = Hive.box('local_edit_requests');
          final updated = Map<String, dynamic>.from(data)
            ..addAll({
              'status':     newStatus,
              'reviewedAt': DateTime.now().toIso8601String(),
              'reviewedBy': reviewerUid,
              if (reviewerName != null) 'reviewedByName': reviewerName,
              if (docReason != null) 'doctorReason': docReason,
              if (docReason != null && newStatus == 'rejected') 'rejectionReason': docReason,
            });
          await box.put(docId, updated);
        }
        if (Hive.isBoxOpen(LocalStorageService.restockRequestsBox)) {
          final box = Hive.box(LocalStorageService.restockRequestsBox);
          final updated = Map<String, dynamic>.from(data)
            ..addAll({
              'status':     newStatus,
              'reviewedAt': DateTime.now().toIso8601String(),
              'reviewedBy': reviewerUid,
              if (reviewerName != null) 'reviewedByName': reviewerName,
              if (docReason != null) 'doctorReason': docReason,
              if (docReason != null && newStatus == 'rejected') 'rejectionReason': docReason,
            });
          await box.put(docId, updated);
        }

        // Only the branch doc the request lives in (writing to every alias made empty docs).
        final candidateBranches = {_cloudBranchOf[docId] ?? targetBranch};
        for (final bId in candidateBranches) {
          try {
            final targetRef = CloudDb.instance
                .collection('branches')
                .doc(bId)
                .collection(collection)
                .doc(docId);

            await _bestEffort(targetRef.set({
              'status':     newStatus,
              'reviewedAt': FieldValue.serverTimestamp(),
              'reviewedBy': reviewerUid,
              if (reviewerName != null) 'reviewedByName': reviewerName,
              if (docReason != null) 'doctorReason': docReason,
              if (docReason != null && newStatus == 'rejected') 'rejectionReason': docReason,
            }, SetOptions(merge: true)));
          } catch (e) {
            debugPrint('[RequestPage] Firestore direct rejection update failed for $bId: $e');
          }
        }

        // Always enqueue in offline sync queue so rejection is persisted
        await LocalStorageService.enqueueSync({
          'type': 'update_request_status',
          'requestId': docId,
          'id': docId,
          'status': newStatus,
          'requestStatus': newStatus, // enqueueSync overwrites 'status' with the queue state
          'collection': collection,
          'branchId': targetBranch,
          if (_cloudBranchOf[docId] != null) 'cloudBranch': _cloudBranchOf[docId],
          'reviewedAt': DateTime.now().toIso8601String(),
          'reviewedBy': reviewerUid,
          if (reviewerName != null) 'reviewedByName': reviewerName,
          if (docReason != null) 'doctorReason': docReason,
          if (docReason != null && newStatus == 'rejected') 'rejectionReason': docReason,
        });

        // Broadcast request_rejected to server and all workstations
        try {
          RealtimeManager().sendMessage({
            'event_type': 'request_rejected',
            'branchId': targetBranch,
            'requestId': docId,
            'id': docId,
            'docId': docId,
            'status': newStatus,
            'collection': collection,
            'reviewedAt': DateTime.now().toIso8601String(),
            'reviewedBy': reviewerUid,
            if (reviewerName != null) 'reviewedByName': reviewerName,
            if (docReason != null) 'doctorReason': docReason,
            if (docReason != null && newStatus == 'rejected') 'rejectionReason': docReason,
          });
        } catch (e) {
          debugPrint('[RequestPage] Failed to broadcast request_rejected: $e');
        }
      }

      // ✅ FIX: Use microtask so the Firestore stream has one event-loop turn
      // to re-emit the updated document before we force a rebuild. Without
      // this the card still briefly shows the old status after approval.
      if (mounted) {
        Future.microtask(() {
          if (mounted) setState(() {});
        });
      }

      AppToast.showSnackBar(context, SnackBar(
        content: Text("Request ${newStatus.toUpperCase()}"),
        backgroundColor: newStatus == 'approved'
            ? SoftPalette.teal550
            : SoftPalette.red400,
      ));
    } catch (e, stack) {
      debugPrint('❌ _updateStatus error: $e');
      debugPrint(stack.toString());
      AppToast.showSnackBar(context, 
          SnackBar(content: Text("Error: $e"), backgroundColor: SoftPalette.red400));
    }
  }

  Future<void> _handleAddStock(List<Map<String, dynamic>> items, {String? campId}) async {
    debugPrint('handleAddStock started with ${items.length} items (Target Camp: $campId)');

    if (items.isEmpty) {
      debugPrint('handleAddStock: items list is empty - returning');
      return;
    }

    final branchRef = FirebaseFirestore.instance
        .collection('branches')
        .doc(widget.branchId);
    // The collection dispensing deducts from (Karachi camps: inventory_haji / inventory_saddar);
    // approvals used to add to plain 'inventory', so for Karachi the two drifted apart.
    final inventory = branchRef.collection(
        CampSessionService.getCampInventoryPath(branchId: widget.branchId, campId: campId));
    final warehouse  = branchRef.collection('warehouse');
    final batch      = FirebaseFirestore.instance.batch();

    int operationCount = 0;

    for (final item in items) {
      final name = item['name']?.toString().trim();
      final type = item['type']?.toString().trim();

      if (name == null || name.isEmpty || type == null || type.isEmpty) {
        debugPrint('Skipping item: missing name or type');
        continue;
      }

      final formula        = (item['formula'] ?? '').toString().trim();
      final formulaLower   = formula.toLowerCase();
      final classification = item['classification']?.toString() ?? '';
      final dose           = item['dose']?.toString() ?? '';
      final distilledWater = (item['distilledWater'] as num?)?.toInt();
      final drops          = (item['drops']          as num?)?.toInt();

      final qty   = _safeInt(item['quantity']);
      final price = _safeInt(item['price']);
      final expiry = item['expiryDate']?.toString() ?? '';

      if (qty <= 0) {
        debugPrint('Skipping item "$name" - quantity <= 0');
        continue;
      }

      final nameLower    = name.toLowerCase();
      final variantForId = type == 'Nebulization'
          ? 'neb${distilledWater ?? 0}-${drops ?? 0}'
          : dose;

      final warehouseId = RequestUtils.generateDocId(
        name, type, variantForId, expiry,
        distilledWater: distilledWater, drops: drops, campId: campId,
      );

      final warehouseSnap = await warehouse.doc(warehouseId).get().timeout(const Duration(seconds: 5));

      final commonFields = <String, dynamic>{
        'name':           name,
        'name_lower':     nameLower,
        'formula':        formula,
        'formula_lower':  formulaLower,
        'classification': classification,
        'type':           type,
        'price':          price,
        'quantity':       qty,
        'expiryDate':     expiry,
        if (campId != null && campId.isNotEmpty) 'dispensaryId': campId,
        if (campId != null && campId.isNotEmpty) 'dispensaryTag': CampSessionService.getDispensaryKeyword(campId),
      };

      final Map<String, dynamic> fullWarehouseData = Map.from(commonFields);
      if (type == 'Nebulization') {
        fullWarehouseData['distilledWater'] = distilledWater ?? 0;
        fullWarehouseData['drops']          = drops ?? 0;
      } else {
        fullWarehouseData['dose'] = dose;
      }

      if (warehouseSnap.exists) {
        batch.update(warehouse.doc(warehouseId), {
          // Increment: "read, then write read+qty" lost any change made in between.
          'quantity':      FieldValue.increment(qty),
          'formula':       formula,
          'formula_lower': formulaLower,
        });
      } else {
        fullWarehouseData['addedAt'] = FieldValue.serverTimestamp();
        batch.set(warehouse.doc(warehouseId), fullWarehouseData);
      }

      Query invQuery = inventory
          .where('name_lower', isEqualTo: nameLower)
          .where('type',       isEqualTo: type);

      if (campId != null && campId.isNotEmpty && campId != 'all') {
        invQuery = invQuery.where('dispensaryId', isEqualTo: campId);
      }
      if (type != 'Nebulization' && dose.isNotEmpty) {
        invQuery = invQuery.where('dose', isEqualTo: dose);
      }
      if (expiry.isNotEmpty) {
        invQuery = invQuery.where('expiryDate', isEqualTo: expiry);
      }

      final existingQuery = await invQuery.limit(1).get().timeout(const Duration(seconds: 5));

      final Map<String, dynamic> fullInventoryData = Map.from(commonFields);
      if (type == 'Nebulization') {
        fullInventoryData['distilledWater'] = distilledWater ?? 0;
        fullInventoryData['drops']          = drops ?? 0;
      } else {
        fullInventoryData['dose'] = dose;
      }

      final isExistingMedicine = existingQuery.docs.isNotEmpty;
      if (isExistingMedicine) {
        final existingDoc = existingQuery.docs.first;
        // Details only. The quantity is NOT written here: it goes up as "+qty" through the
        // stock queue below (like the proforma restock), applied once per operation. Writing
        // "cloud quantity read a moment ago + qty" lost any dispense made in between, and the
        // LAN server then overwrote the cloud with its own figure.
        batch.update(existingDoc.reference, {
          'formula':        formula,
          'formula_lower':  formulaLower,
          'classification': classification,
          'price':          price,
        });
      } else {
        final inventoryId = RequestUtils.generateDocId(
          name, type, variantForId, expiry,
          distilledWater: distilledWater, drops: drops, campId: campId,
        );
        fullInventoryData['addedAt'] = FieldValue.serverTimestamp();
        batch.set(inventory.doc(inventoryId), fullInventoryData);
      }

      // Local-first: apply to Hive and tell every device on the LAN right away.
      final localId = existingQuery.docs.isNotEmpty
          ? existingQuery.docs.first.id
          : RequestUtils.generateDocId(
              name, type, variantForId, expiry,
              distilledWater: distilledWater, drops: drops, campId: campId,
            );
      final localExisting = LocalStorageService.getLocalInventoryItem(localId);
      final cloudQty = existingQuery.docs.isNotEmpty
          ? _safeInt((existingQuery.docs.first.data() as Map<String, dynamic>? ?? {})['quantity'])
          : 0;
      final baseQty = localExisting != null ? _safeInt(localExisting['quantity']) : cloudQty;
      final localItem = <String, dynamic>{
        ...fullInventoryData,
        if (localExisting != null) ...localExisting,
        'id': localId,
        'branchId': widget.branchId,
        'quantity': baseQty + qty,
        'price': price,
        'formula': formula,
        'classification': classification,
        'updatedAt': DateTime.now().toIso8601String(),
      };
      LocalStorageService.saveLocalInventoryItem(localItem);
      if (isExistingMedicine) {
        // Same as the proforma restock: other PCs and the LAN server apply "+qty" once
        // (_quantityDelta + _opId), and the cloud gets the increment through the stock queue
        // (a LAN desk hands it to the server; the server PC or a standalone PC uploads it).
        final opId = 'approve_${localId}_${DateTime.now().microsecondsSinceEpoch}';
        RealtimeManager().sendMessage({
          'event_type': RealtimeEvents.saveStockItem,
          'branchId': widget.branchId,
          'data': {...localItem, '_quantityDelta': qty, '_opId': opId},
        });
        await LocalStorageService.enqueueSync({
          'type': 'add_inventory_stock',
          'branchId': widget.branchId,
          'medicineId': localId,
          'quantity': qty,
          'campId': campId,
          'dispensaryId': campId,
          'txId': opId,
          'data': localItem,
        });
      } else {
        // A new medicine is created in the cloud with its full quantity by the batch below.
        RealtimeManager().sendMessage({
          'event_type': RealtimeEvents.saveStockItem,
          'branchId': widget.branchId,
          'data': localItem,
        });
      }

      operationCount++;
    }

    if (operationCount == 0) {
      debugPrint('No valid operations to commit');
      return;
    }

    debugPrint('Committing batch with $operationCount operations...');
    unawaited(_bestEffort(batch.commit(), 'add_stock commit'));
    debugPrint('add_stock applied locally; cloud commit queued');
  }

  Future<void> _handleEditMedicine(
      List<Map<String, dynamic>> items, String reviewerUid, String? reviewerName, {String? campId}) async {
    if (items.isEmpty) return;

    final inventory = FirebaseFirestore.instance
        .collection('branches')
        .doc(widget.branchId)
        .collection('inventory');
    final batch = FirebaseFirestore.instance.batch();

    for (final item in items) {
      final oldId = item['oldId']?.toString();
      if (oldId == null) continue;

      final name           = item['name']?.toString() ?? '';
      final type           = item['type']?.toString() ?? '';
      final formula        = (item['formula'] ?? item['name'] ?? '').toString().trim();
      final dose           = item['dose']?.toString() ?? '';
      final qty            = _safeInt(item['quantity']);
      final price          = _safeInt(item['price']);
      final expiry         = item['expiryDate']?.toString() ?? '';
      final classification = item['classification']?.toString() ?? '';
      final distilledWater = (item['distilledWater'] as num?)?.toInt();
      final drops          = (item['drops']          as num?)?.toInt();

      final effCamp = (campId != null && campId.isNotEmpty) ? campId : (item['campId'] ?? item['dispensaryId'])?.toString();

      final barcode = (item['barcode'] ?? item['code'] ?? '').toString().trim();
      final newData = <String, dynamic>{
        'name':           name,
        'name_lower':     name.toLowerCase(),
        'formula':        formula,
        'formula_lower':  formula.toLowerCase(),
        'type':           type,
        'dose':           type == 'Nebulization' ? '' : dose,
        'quantity':       qty,
        'price':          price,
        'expiryDate':     expiry,
        if (barcode.isNotEmpty) 'code': barcode,
        if (barcode.isNotEmpty) 'barcode': barcode,
        'classification': classification,
        'approvedBy':     reviewerUid,
        'approvedByName': reviewerName ?? 'Supervisor',
        'updatedAt':      FieldValue.serverTimestamp(),
        if (effCamp != null && effCamp.isNotEmpty) 'dispensaryId': effCamp,
        if (effCamp != null && effCamp.isNotEmpty) 'dispensaryTag': CampSessionService.getDispensaryKeyword(effCamp),
      };
      if (type == 'Nebulization') {
        newData['distilledWater'] = distilledWater ?? 0;
        newData['drops']          = drops ?? 0;
      }

      String cleanDocId(dynamic raw) {
        final s = (raw ?? '').toString().trim();
        return s.startsWith('stock:') ? s.substring(6) : s;
      }
      final cleanOldId = cleanDocId(oldId);

      final newId = RequestUtils.generateDocId(
        name, type, type == 'Nebulization' ? '' : dose, expiry,
        distilledWater: distilledWater, drops: drops, campId: effCamp,
      );

      if (cleanOldId.isNotEmpty && cleanOldId == newId) {
        batch.update(inventory.doc(cleanOldId), newData);
      } else {
        if (cleanOldId.isNotEmpty) {
          batch.delete(inventory.doc(cleanOldId));
          LocalStorageService.deleteLocalStockItem(cleanOldId);
          
          // Broadcast delete to LAN so others remove the old ghost record immediately
          RealtimeManager().sendMessage({
            'event_type': RealtimeEvents.deleteStockItem,
            'id': cleanOldId,
            'branchId': widget.branchId,
          });
        }

        newData['addedAt'] = FieldValue.serverTimestamp();
        batch.set(inventory.doc(newId), newData);
      }

      final finalMedId = (cleanOldId.isNotEmpty && cleanOldId == newId) ? cleanOldId : newId;
      final hiveData = Map<String, dynamic>.from(newData);
      hiveData['id'] = finalMedId;
      hiveData['branchId'] = widget.branchId;
      LocalStorageService.saveLocalInventoryItem(hiveData);

      RealtimeManager().sendMessage({
        'event_type': RealtimeEvents.saveStockItem,
        'branchId': widget.branchId,
        'data': hiveData,
      });

      // Add to log
      FirebaseFirestore.instance
          .collection('branches')
          .doc(widget.branchId)
          .collection('inventory_log')
          .add({
        'action': 'medicine_edited',
        'medicineName': name,
        'medicineType': type,
        'dose': dose,
        'oldId': oldId,
        'newId': newId,
        'performedBy': reviewerUid,
        'performedByName': reviewerName ?? 'Supervisor',
        'timestamp': FieldValue.serverTimestamp(),
        if (campId != null) 'dispensaryId': campId,
      });
    }
    unawaited(_bestEffort(batch.commit(), 'edit_medicine commit'));
  }

  Future<void> _handleDeleteMedicine(
      List<Map<String, dynamic>> items, {String? campId}) async {
    if (items.isEmpty) return;

    final inventory = FirebaseFirestore.instance
        .collection('branches')
        .doc(widget.branchId)
        .collection('inventory');
    final batch = FirebaseFirestore.instance.batch();

    for (final item in items) {
      final name = item['name']?.toString();
      final type = item['type']?.toString();
      if (name == null || type == null) continue;
      final dose           = item['dose']?.toString() ?? '';
      final expiry         = item['expiryDate']?.toString() ?? '';
      final distilledWater = (item['distilledWater'] as num?)?.toInt();
      final drops          = (item['drops']          as num?)?.toInt();

      final id = RequestUtils.generateDocId(
        name, type, dose, expiry,
        distilledWater: distilledWater, drops: drops, campId: campId,
      );
      batch.delete(inventory.doc(id));
      await LocalStorageService.deleteLocalStockItem(id);
      RealtimeManager().sendMessage({
        'event_type': RealtimeEvents.deleteStockItem,
        'id': id,
        'branchId': widget.branchId,
      });
    }
    unawaited(_bestEffort(batch.commit(), 'delete_medicine commit'));
  }

  Future<void> _handleChangePrescription(Map<String, dynamic> data,
      List<Map<String, dynamic>> items) async {
    final patientId = data['patientId']?.toString();
    if (patientId == null) return;

    await FirebaseFirestore.instance
        .collection('branches')
        .doc(widget.branchId)
        .collection('patients')
        .doc(patientId)
        .update({'prescription': items});
  }

  Future<void> _showEditItemDialog(
      String requestId, int itemIndex, Map<String, dynamic> item) async {
    final reqRef  = FirebaseFirestore.instance
        .collection('branches')
        .doc(widget.branchId)
        .collection('edit_requests')
        .doc(requestId);
    final reqSnap = await reqRef.get();
    final status  = reqSnap.data()?['status']?.toString() ?? '';
    if (status != 'pending') {
      AppToast.showSnackBar(context, const SnackBar(
          content: Text('Cannot edit — request is not pending'),
          backgroundColor: SoftPalette.amber300));
      return;
    }

    final nameCtrl  = TextEditingController(text: item['name']?.toString() ?? '');
    final qtyCtrl   = TextEditingController(
        text: (item['quantity'] ?? 0).toString());
    final priceCtrl = TextEditingController(
        text: (item['price'] ?? 0).toString());
    DateTime? pickedDate =
        _tryParseDateString(item['expiryDate']?.toString() ?? '');
    String expiryStr = pickedDate != null
        ? DateFormat('dd-MM-yyyy').format(pickedDate)
        : (item['expiryDate']?.toString() ?? '');

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dialogBg = isDark ? SoftPalette.slate800 : SoftPalette.gray50;
    final fieldBg  = isDark ? SoftPalette.slate900 : SoftPalette.gray50;
    final borderSide = isDark ? const BorderSide(color: SoftPalette.slate700) : BorderSide(color: SoftPalette.teal300);

    await showDialog(
      context: context,
      builder: (context) =>
          StatefulBuilder(builder: (context, setState) {
        Future<void> pickDate() async {
          final d = await showDatePicker(
            context: context,
            initialDate: pickedDate ?? DateTime.now(),
            firstDate: DateTime(2000),
            lastDate: DateTime(2100),
          );
          if (d != null) {
            setState(() {
              pickedDate  = d;
              expiryStr   = DateFormat('dd-MM-yyyy').format(d);
            });
          }
        }

        return AlertDialog(
          backgroundColor: dialogBg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: isDark ? const BorderSide(color: SoftPalette.slate700) : BorderSide.none,
          ),
          title: Text(
            'Edit Item',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: isDark ? SoftPalette.teal200 : SoftPalette.teal700,
            ),
          ),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: nameCtrl,
                style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87),
                decoration: InputDecoration(
                  labelText: 'Name',
                  labelStyle: TextStyle(color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87),
                  prefixIcon:
                      Icon(Icons.medication, color: isDark ? SoftPalette.teal300 : SoftPalette.teal600),
                  filled: true,
                  fillColor: fieldBg,
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: borderSide),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: isDark ? SoftPalette.teal300 : SoftPalette.teal500)),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: qtyCtrl,
                keyboardType: TextInputType.number,
                style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87),
                decoration: InputDecoration(
                  labelText: 'Quantity',
                  labelStyle: TextStyle(color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87),
                  prefixIcon:
                      Icon(Icons.inventory, color: isDark ? SoftPalette.teal300 : SoftPalette.teal600),
                  filled: true,
                  fillColor: fieldBg,
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: borderSide),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: isDark ? SoftPalette.teal300 : SoftPalette.teal500)),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: priceCtrl,
                keyboardType: TextInputType.number,
                style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87),
                decoration: InputDecoration(
                  labelText: 'Price (PKR)',
                  labelStyle: TextStyle(color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87),
                  prefixIcon: Icon(Icons.attach_money,
                      color: isDark ? SoftPalette.teal300 : SoftPalette.teal600),
                  filled: true,
                  fillColor: fieldBg,
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: borderSide),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: isDark ? SoftPalette.teal300 : SoftPalette.teal500)),
                ),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: TextField(
                    readOnly: true,
                    controller:
                        TextEditingController(text: expiryStr),
                    style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87),
                    decoration: InputDecoration(
                      labelText: 'Expiry',
                      labelStyle: TextStyle(color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87),
                      prefixIcon: Icon(Icons.calendar_month,
                          color: isDark ? SoftPalette.teal300 : SoftPalette.teal600),
                      filled: true,
                      fillColor: fieldBg,
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: borderSide),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: isDark ? SoftPalette.teal300 : SoftPalette.teal500)),
                    ),
                  ),
                ),
                IconButton(
                    onPressed: pickDate,
                    icon: Icon(Icons.calendar_today,
                        color: isDark ? SoftPalette.teal300 : SoftPalette.teal600)),
              ]),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text("Cancel",
                    style: TextStyle(color: isDark ? SoftPalette.gray50A70 : SoftPalette.teal600))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: isDark ? SoftPalette.teal550 : SoftPalette.teal550),
              onPressed: () async {
                final newName  = nameCtrl.text.trim();
                final newQty   = int.tryParse(qtyCtrl.text.trim()) ?? 0;
                final newPrice =
                    int.tryParse(priceCtrl.text.trim()) ?? 0;

                if (newName.isEmpty || newQty <= 0) {
                  AppToast.showSnackBar(context, 
                      const SnackBar(content: Text('Invalid input')));
                  return;
                }

                final updatedItem = Map<String, dynamic>.from(item);
                updatedItem['name']       = newName;
                updatedItem['quantity']   = newQty;
                updatedItem['price']      = newPrice;
                updatedItem['expiryDate'] = expiryStr;

                await _editItemInRequestAsDraft(
                    requestId, itemIndex, updatedItem);
                Navigator.pop(context);
                AppToast.showSnackBar(context, 
                    const SnackBar(
                        content: Text('Item updated in draft')));
              },
              child: const Text("Save",
                  style: TextStyle(color: SoftPalette.gray50)),
            ),
          ],
        );
      }),
    );
  }

  Future<void> _editItemInRequestAsDraft(
      String requestId, int itemIndex, Map<String, dynamic> newItem) async {
    final ref = FirebaseFirestore.instance
        .collection('branches')
        .doc(widget.branchId)
        .collection('edit_requests')
        .doc(requestId);

    final snap = await ref.get();
    if (!snap.exists) return;

    final data = snap.data() ?? {};
    if (data['status'] != 'pending') return;

    final originalItems = _safeItemList(data['items']);
    var draftItems      = _safeItemList(data['draftItems']).isNotEmpty
        ? _safeItemList(data['draftItems'])
        : originalItems
            .map((e) => Map<String, dynamic>.from(e))
            .toList();

    if (itemIndex >= 0 && itemIndex < draftItems.length) {
      draftItems[itemIndex] = newItem;
    }

    await ref.update({
      'draftItems':   draftItems,
      'lastEditedAt': FieldValue.serverTimestamp(),
      'lastEditedBy': FirebaseAuth.instance.currentUser?.uid,
    });
  }
}
