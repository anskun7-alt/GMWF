import 'package:gmwf/utils/debounced_box_listenable.dart';
import 'package:gmwf/services/cloud/cloud_db.dart';
import 'package:gmwf/services/cloud/lan_firestore_gate.dart';
import 'package:gmwf/services/network_health_service.dart';
import 'dart:async';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';
import 'package:rxdart/rxdart.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../services/sync_service.dart';
import '../services/local_storage_service.dart';
import '../services/camp_session_service.dart';
import '../services/stock/expiry_service.dart';
import '../services/stock/stock_actions.dart';
import '../services/stock/stock_ledger.dart';
import '../services/stock/stock_log.dart';
import '../services/stock/stock_pool.dart';
import '../services/stock/stock_reader.dart';
import '../realtime/realtime_manager.dart';
import '../realtime/realtime_events.dart';
import '../utils/formatters.dart';
import '../widgets/global_module_wrapper.dart';
import '../design/design_system.dart';
import '../utils/branch_labels.dart';

class RequestUtils {
  /// HQ Manager, admins (incl. global/super), chairman and CEO: approve or deny anything.
  static bool isHigherAuthorityRole(String role) {
    final r = role.toLowerCase().trim();
    return r.contains('hq') ||
        r.contains('head office') ||
        r.contains('admin') ||
        r.contains('chairman') ||
        r.contains('ceo');
  }

  static IconData iconFor(String type) {
    final t = type.toLowerCase();
    if (t.contains('token_exception')) return Icons.event_busy_rounded;
    if (t.contains('reversal')) return Icons.undo_rounded;
    if (t.contains('patient')) return Icons.person_search_rounded;
    if (t.contains('delete')) return Icons.delete_outline_rounded;
    if (t.contains('edit')) return Icons.edit_note_rounded;
    if (t.contains('stock') || t.contains('restock') || t.contains('medicine') || t.contains('register')) {
      return Icons.inventory_2_outlined;
    }
    if (t.contains('prescription') || t.contains('dispense')) return Icons.medication_outlined;
    return Icons.assignment_outlined;
  }

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
  final String? initialRequestId;

  /// Reactive notifier so selecting a specific request from the top-bar Bell popover
  /// focuses and highlights that request even if [RequestPage] is already mounted.
  static final ValueNotifier<String?> focusedRequestIdNotifier = ValueNotifier<String?>(null);

  static void focusRequest(String? requestId) {
    focusedRequestIdNotifier.value = (requestId != null && requestId.trim().isNotEmpty)
        ? requestId.trim()
        : null;
  }

  const RequestPage({
    super.key,
    required this.branchId,
    this.isSupervisor = false,
    this.initialRequestId,
  });

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
    if (widget.initialRequestId != null && widget.initialRequestId!.trim().isNotEmpty) {
      RequestPage.focusRequest(widget.initialRequestId);
    }
    RequestPage.focusedRequestIdNotifier.addListener(_onFocusedRequestChanged);

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

  void _onFocusedRequestChanged() {
    if (!mounted) return;
    final focused = RequestPage.focusedRequestIdNotifier.value;
    if (focused != null && focused.isNotEmpty && _tabCtrl.index != 0) {
      _tabCtrl.animateTo(0);
    }
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant RequestPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialRequestId != oldWidget.initialRequestId &&
        widget.initialRequestId != null &&
        widget.initialRequestId!.trim().isNotEmpty) {
      RequestPage.focusRequest(widget.initialRequestId);
      if (_tabCtrl.index != 0) {
        _tabCtrl.animateTo(0);
      }
    }
  }

  @override
  void dispose() {
    RequestPage.focusedRequestIdNotifier.removeListener(_onFocusedRequestChanged);
    _tabCtrl.dispose();
    _realtimeSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isWrapped = GlobalModuleWrapper.isWrapped(context);
    final c = context.comfort;

    PreferredSizeWidget buildTabsBar() {
      return PreferredSize(
        preferredSize: const Size.fromHeight(48),
        child: Container(
          decoration: BoxDecoration(
            color: c.surface,
            border: Border(
              bottom: BorderSide(color: c.border, width: 1),
            ),
          ),
          child: TabBar(
            controller: _tabCtrl,
            indicatorColor: c.brand,
            indicatorWeight: 3,
            indicatorSize: TabBarIndicatorSize.label,
            labelColor: c.brand,
            unselectedLabelColor: c.textSecondary,
            dividerColor: Colors.transparent,
            labelStyle: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.1,
            ),
            unselectedLabelStyle: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
            tabs: const [
              Tab(
                height: 46,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.pending_actions_rounded, size: 18),
                    SizedBox(width: 8),
                    Text('Pending'),
                  ],
                ),
              ),
              Tab(
                height: 46,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle_outline_rounded, size: 18),
                    SizedBox(width: 8),
                    Text('Approved'),
                  ],
                ),
              ),
              Tab(
                height: 46,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cancel_outlined, size: 18),
                    SizedBox(width: 8),
                    Text('Rejected'),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: c.background,
      appBar: isWrapped
          ? buildTabsBar()
          : AppBar(
              automaticallyImplyLeading: false,
              toolbarHeight: 58,
              backgroundColor: c.surface,
              foregroundColor: c.textPrimary,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              titleSpacing: 12,
              leadingWidth: 52,
              leading: Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Center(
                  child: Tooltip(
                    message: 'Back',
                    child: Material(
                      color: c.surfaceSunken,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(color: c.border),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => Navigator.of(context).maybePop(),
                        child: SizedBox(
                          width: 36,
                          height: 36,
                          child: Icon(
                            Icons.arrow_back_rounded,
                            size: 19,
                            color: c.textPrimary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              title: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: c.brandSoft,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: c.brand.withValues(alpha: 0.25)),
                    ),
                    child: Icon(
                      Icons.rule_rounded,
                      size: 18,
                      color: c.brand,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Requests & Approvals',
                          style: TextStyle(
                            fontSize: 16.5,
                            fontWeight: FontWeight.w800,
                            color: c.textPrimary,
                            letterSpacing: -0.2,
                          ),
                        ),
                        Text(
                          'Review pending medicine, token reversal, and patient edit requests',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w500,
                            color: isDark ? SoftPalette.slate400 : c.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              bottom: buildTabsBar(),
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
                .limit(100)
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
              .limit(100)
              .snapshots()
              .listen((snap) {
            if (!Hive.isBoxOpen('local_edit_requests')) return;
            final box = Hive.box('local_edit_requests');
            for (final change in snap.docChanges) {
              final doc = change.doc;
              if (change.type == DocumentChangeType.removed) {
                box.delete(doc.id);
                if (col == 'restock_requests' && Hive.isBoxOpen(LocalStorageService.restockRequestsBox)) {
                  Hive.box(LocalStorageService.restockRequestsBox).delete(doc.id);
                }
                continue;
              }
              final d = Map<String, dynamic>.from(doc.data() ?? {});
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

    // A user id (e.g. "n3R9Scw…") is not readable: look the person up on this PC.
    for (final k in const ['requestedByName', 'createdByName', 'userName', 'username', 'doctorName']) {
      final v = (data[k]?.toString() ?? '').trim();
      if (v.isNotEmpty) {
        _nameCache[docId] = v;
        return v;
      }
    }
    try {
      final u = LocalStorageService.getLocalUserByUid(requesterId) ?? LocalStorageService.findLocalUser(requesterId);
      final n = (u?['username'] ?? u?['name'] ?? u?['displayName'] ?? u?['fullName'])?.toString().trim() ?? '';
      if (n.isNotEmpty) {
        _nameCache[docId] = n;
        return n;
      }
    } catch (_) {}
    final looksLikeId = requesterId.length >= 20 && !requesterId.contains(' ');
    return looksLikeId ? 'Staff (${requesterId.substring(0, 6)}…)' : requesterId;
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

    final tabListenable = Listenable.merge([
      DebouncedBoxListenable.shared(editBox),
      if (restockBox != null) DebouncedBoxListenable.shared(restockBox),
      RequestPage.focusedRequestIdNotifier,
    ]);

    return ListenableBuilder(
      listenable: tabListenable,
      builder: (context, _) {
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

    final focusedId = RequestPage.focusedRequestIdNotifier.value;
    bool isFocusedDoc(LocalRequestDoc d) {
      if (focusedId == null || focusedId.isEmpty) return false;
      final map = d.data();
      return d.id == focusedId ||
          map['requestId']?.toString() == focusedId ||
          map['id']?.toString() == focusedId;
    }

    allDocs.sort((a, b) {
      if (widget.status == 'pending') {
        final aFocus = isFocusedDoc(a);
        final bFocus = isFocusedDoc(b);
        if (aFocus && !bFocus) return -1;
        if (!aFocus && bFocus) return 1;
      }
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
        final isHigherAuthority = RequestUtils.isHigherAuthorityRole(role);
        final canApproveAny = isSupervisorRole || isDoctor || isHigherAuthority;

        final eligibleDocs = allDocs.where((doc) {
          final data = doc.data();
          final requestType = data['requestType']?.toString() ??
              data['type']?.toString() ??
              'unknown';
          if (isHigherAuthority) return true;
          if (isSupervisorRole && requestType != 'token_exception') return true;
          if (isDoctor &&
              (requestType == 'token_exception' ||
                  requestType == 'patient_edit' ||
                  requestType == 'token_reversal')) {
            return true;
          }
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
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  GEmptyIllustration(
                    GEmptyIllustrationKind.requests,
                    size: 164,
                    fallbackIcon: widget.status == 'pending'
                        ? Icons.pending_actions_outlined
                        : widget.status == 'approved'
                            ? Icons.check_circle_outline
                            : Icons.cancel_outlined,
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
                  const SizedBox(height: 6),
                  Text(
                    widget.status == 'pending'
                        ? 'All caught up — new requests awaiting review will appear here.'
                        : widget.status == 'approved'
                            ? 'Approved requests will be listed here.'
                            : 'Rejected requests will be archived here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: context.comfort.textSecondary,
                      fontSize: 13.5,
                    ),
                  ),
                ],
              ),
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
      // HQ Manager, admins, chairman, CEO: may approve or deny EVERY request, token
      // exceptions included (those used to be doctor-only, so HQ only saw "Pending approval").
      final isHigherAuthority = RequestUtils.isHigherAuthorityRole(role);

      final canApproveAsSupervisor =
          isSupervisorRole && (requestType != 'token_exception' || isHigherAuthority);
      final canApproveAsDoctor = isDoctor &&
          (requestType == 'token_exception' ||
              requestType == 'patient_edit' ||
              requestType == 'token_reversal');

      final campLabel = RequestUtils.resolveRequestCampName(data, widget.branchId);
      final activeFocusId = RequestPage.focusedRequestIdNotifier.value;
      final isFocusedCard = widget.status == 'pending' &&
          activeFocusId != null &&
          activeFocusId.isNotEmpty &&
          (doc.id == activeFocusId ||
              data['requestId']?.toString() == activeFocusId ||
              data['id']?.toString() == activeFocusId);

      // ── Redesigned request card (2026-11-21): accent stripe by type, one clear title
      // line, one compact info line, the details, then large Approve / Reject buttons.
      final c = context.comfort;
      final accent = RequestUtils.getTextColor(requestType, isDark: isDark);
      final typeLabel = requestType
          .split('_')
          .where((w) => w.isNotEmpty)
          .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
          .join(' ');
      final branchLabel = (data['branchId'] ?? widget.branchId).toString();
      final when = ts?.toDate();
      String ago() {
        if (when == null) return '';
        final d = DateTime.now().difference(when);
        if (d.inMinutes < 1) return 'just now';
        if (d.inMinutes < 60) return '${d.inMinutes} min ago';
        if (d.inHours < 24) return '${d.inHours} h ago';
        if (d.inDays < 31) return '${d.inDays} day${d.inDays == 1 ? '' : 's'} ago';
        return DateFormat('dd MMM yyyy').format(when);
      }

      Widget metaItem(IconData icon, String text, {bool strong = false}) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: c.textMuted),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  text,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: strong ? FontWeight.w700 : FontWeight.w500,
                    color: strong ? c.textPrimary : c.textSecondary,
                  ),
                ),
              ),
            ],
          );

      return Container(
        decoration: BoxDecoration(
          color: isFocusedCard ? Color.alphaBlend(c.brand.withValues(alpha: 0.06), c.surface) : c.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isFocusedCard ? c.brand : c.border,
            width: isFocusedCard ? 2 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.05),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 5, color: accent),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (isFocusedCard) ...[
                        Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: c.brand.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.notifications_active_rounded, size: 14, color: c.brandStrong),
                              const SizedBox(width: 6),
                              Text(
                                'Opened from notifications',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: c.brandStrong),
                              ),
                              const SizedBox(width: 6),
                              InkWell(
                                onTap: () => RequestPage.focusRequest(null),
                                child: Icon(Icons.close_rounded, size: 15, color: c.brandStrong),
                              ),
                            ],
                          ),
                        ),
                      ],
                      // Title row: type icon, title + type, time.
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(RequestUtils.iconFor(requestType), size: 22, color: accent),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  RequestUtils.getTitle(requestType, patientName),
                                  style: TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w800,
                                    color: c.textPrimary,
                                    height: 1.2,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  typeLabel,
                                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: accent),
                                ),
                              ],
                            ),
                          ),
                          if (when != null)
                            Tooltip(
                              message: DateFormat('dd MMM yyyy, hh:mm a').format(when),
                              child: Padding(
                                padding: const EdgeInsets.only(left: 8, top: 2),
                                child: Text(
                                  ago(),
                                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.textMuted),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      // One compact info line.
                      Wrap(
                        spacing: 18,
                        runSpacing: 6,
                        children: [
                          metaItem(Icons.person_outline_rounded, name, strong: true),
                          metaItem(Icons.location_on_outlined,
                              '$campLabel${campLabel.toLowerCase() == branchLabel.toLowerCase() ? '' : ' · ${branchLabel[0].toUpperCase()}${branchLabel.substring(1)}'}'),
                          if (when != null)
                            metaItem(Icons.schedule_rounded, DateFormat('dd MMM, hh:mm a').format(when)),
                          if (amountText.isNotEmpty) metaItem(Icons.payments_outlined, amountText, strong: true),
                          if (widget.status == 'approved')
                            metaItem(Icons.verified_rounded, 'Approved by ${approverName ?? '—'}', strong: true),
                          if (widget.status == 'rejected')
                            metaItem(Icons.block_rounded, 'Rejected by ${approverName ?? '—'}', strong: true),
                        ],
                      ),
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
                      Divider(height: 1, color: c.border),
                      const SizedBox(height: 12),
                      if (widget.status == 'pending' && (canApproveAsSupervisor || canApproveAsDoctor))
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Your decision is needed',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.textSecondary),
                              ),
                            ),
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: c.danger,
                                side: BorderSide(color: c.danger.withValues(alpha: 0.6)),
                                minimumSize: const Size(110, 44),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              onPressed: () => _updateStatus(context, doc.id, 'rejected', requestType, collection),
                              icon: const Icon(Icons.close_rounded, size: 18),
                              label: const Text('Reject', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                            ),
                            const SizedBox(width: 10),
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: c.brand,
                                foregroundColor: c.onBrand,
                                elevation: 0,
                                minimumSize: const Size(130, 44),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              onPressed: () => _updateStatus(context, doc.id, 'approved', requestType, collection),
                              icon: const Icon(Icons.check_rounded, size: 18),
                              label: const Text('Approve', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                            ),
                          ],
                        )
                      else if (widget.status == 'pending' && isSupervisorRole && requestType == 'token_exception')
                        _buildDoctorOnlyNotice()
                      else
                        Row(
                          children: [
                            Icon(
                              widget.status == 'approved'
                                  ? Icons.check_circle_rounded
                                  : (widget.status == 'rejected' ? Icons.cancel_rounded : Icons.hourglass_top_rounded),
                              size: 18,
                              color: widget.status == 'approved'
                                  ? c.brand
                                  : (widget.status == 'rejected' ? c.danger : c.warning),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              widget.status == 'approved'
                                  ? 'Approved'
                                  : (widget.status == 'rejected' ? 'Rejected' : 'Waiting for another role to decide'),
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                                color: widget.status == 'approved'
                                    ? c.brandStrong
                                    : (widget.status == 'rejected' ? c.danger : c.warning),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
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
        // Plain wording: the patient still has medicine from an earlier visit, so a new token
        // needs approval. 0 days left means the earlier course ends today.
        Text("Patient ID: $patientId", style: TextStyle(color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87)),
        const SizedBox(height: 2),
        Text(
          (isLastDay || remDays.toString() == '0')
              ? "Earlier medicine ends today — patient is asking for a new token before it runs out"
              : "Earlier medicine still lasts $remDays more day${remDays.toString() == '1' ? '' : 's'} — patient is asking for a new token early",
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
    const validBloodGroups = ['N/A', 'A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'];
    final rawBgInit = (proposed['bloodGroup']?.toString() ??
            original['bloodGroup']?.toString() ??
            'N/A')
        .trim()
        .toUpperCase();
    String selectedBloodGroup = validBloodGroups.contains(rawBgInit) ? rawBgInit : 'N/A';
    String selectedStatus = proposed['status']?.toString() ??
        original['status']?.toString() ??
        'Zakat';
    String selectedGender = proposed['gender']?.toString() ??
        original['gender']?.toString() ??
        'Male';

    final rawPropDob = proposed['dob'] ?? proposed['dateOfBirth'] ?? original['dob'] ?? original['dateOfBirth'];
    if (rawPropDob != null) {
      final parsed = LocalStorageService.tryParseDob(rawPropDob);
      if (parsed != null) {
        dobCtrl.text = DateFormat('dd-MM-yyyy').format(parsed);
      } else {
        dobCtrl.text = _formatDate(rawPropDob);
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
                keyboardType: TextInputType.phone,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(11),
                ],
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
                keyboardType: TextInputType.datetime,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9-]')),
                  LengthLimitingTextInputFormatter(10),
                  DobInputFormatter(),
                ],
                style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87),
                decoration: InputDecoration(
                  labelText: "Date of Birth (dd-MM-yyyy)",
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
              DropdownButtonFormField<String>(
                initialValue: validBloodGroups.contains(selectedBloodGroup) ? selectedBloodGroup : 'N/A',
                isExpanded: true,
                dropdownColor: dialogBg,
                style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87),
                decoration: InputDecoration(
                  labelText: "Blood Group",
                  labelStyle: TextStyle(color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87),
                  prefixIcon: Icon(Icons.bloodtype_outlined,
                      color: isDark ? SoftPalette.teal300 : SoftPalette.teal600),
                  filled: true,
                  fillColor: fieldBg,
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: borderSide),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: isDark ? SoftPalette.teal300 : SoftPalette.teal500)),
                ),
                items: validBloodGroups
                    .map((bg) => DropdownMenuItem<String>(
                          value: bg,
                          child: Text(bg, style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87)),
                        ))
                    .toList(),
                onChanged: (v) {
                  if (v != null) setState(() => selectedBloodGroup = v);
                },
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
                if (dobCtrl.text.trim().isNotEmpty) {
                  dob = LocalStorageService.tryParseDob(dobCtrl.text.trim()) ??
                      parseDobDateTime(dobCtrl.text.trim());
                }
                final trimmedName = nameCtrl.text.trim();
                final isoDob = dob?.toIso8601String();
                final calcAge = isoDob != null ? LocalStorageService.calculateAgeFromDob(isoDob) : null;
                final newProposed = <String, dynamic>{
                  'name': trimmedName,
                  'patientName': trimmedName,
                  'fullName': trimmedName,
                  'phone': phoneCtrl.text.trim().isNotEmpty
                      ? phoneCtrl.text.trim()
                      : null,
                  'status': selectedStatus,
                  'bloodGroup': selectedBloodGroup.isNotEmpty
                      ? selectedBloodGroup
                      : 'N/A',
                  'gender': selectedGender,
                  'patientGender': selectedGender,
                  'isAdult': !isChild,
                  if (isoDob != null) 'dob': isoDob,
                  if (isoDob != null) 'dateOfBirth': isoDob,
                  if (calcAge != null && calcAge >= 0) 'age': calcAge,
                  if (calcAge != null && calcAge >= 0) 'patientAge': calcAge,
                  if (isChild)  'guardianCnic': cnicCtrl.text.trim(),
                  if (!isChild) 'cnic': cnicCtrl.text.trim(),
                  if (!isChild) 'patientCnic': cnicCtrl.text.trim(),
                };
                try {
                  if (Hive.isBoxOpen('local_edit_requests')) {
                    final box = Hive.box('local_edit_requests');
                    final existingReq = box.get(requestId);
                    if (existingReq is Map) {
                      final updReq = Map<String, dynamic>.from(existingReq);
                      updReq['draftData'] = newProposed;
                      await box.put(requestId, updReq);
                    }
                  }
                } catch (_) {}
                if (!LanFirestoreGate.isLanDesk) {
                  try {
                    await FirebaseFirestore.instance
                        .collection('branches')
                        .doc(widget.branchId)
                        .collection('edit_requests')
                        .doc(requestId)
                        .update({'draftData': newProposed});
                  } catch (_) {}
                }
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
      if (RequestUtils.isHigherAuthorityRole(role)) return true;
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

        // Decided meanwhile (another PC, or earlier in this list): skip, never re-run.
        String localStatus = (data['status'] ?? 'pending').toString().toLowerCase();
        for (final boxName in ['local_edit_requests', LocalStorageService.restockRequestsBox]) {
          if (!Hive.isBoxOpen(boxName)) continue;
          final raw = Hive.box(boxName).get(docId);
          if (raw is Map) {
            localStatus = (raw['status'] ?? localStatus).toString().toLowerCase();
            break;
          }
        }
        if (localStatus == 'approved' || localStatus == 'rejected') continue;
        if (requestType == 'token_reversal' && _reversalBlockedReason(data) != null) {
          errorCount++;
          continue;
        }

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

  /// Why a token reversal may not be approved now, or null. Only a token still waiting for
  /// the doctor can be reversed: a late approval used to delete a prescribed or dispensed
  /// token on every PC (stock not returned, prescription left in the cloud).
  String? _reversalBlockedReason(Map<String, dynamic> data) {
    final serial = (data['tokenSerial'] ?? data['tokenId'])?.toString() ?? '';
    if (serial.isEmpty) return null;
    final branch = (data['branchId']?.toString().isNotEmpty == true) ? data['branchId'].toString() : widget.branchId;
    final entry = LocalStorageService.getLocalEntry(branch, serial);
    if (entry == null) return null;
    final ds = (entry['dispenseStatus'] ?? '').toString().toLowerCase();
    final st = (entry['status'] ?? '').toString().toLowerCase();
    if (ds == 'dispensed' || st == 'dispensed') {
      return 'Token $serial has already been dispensed, so it cannot be reversed.';
    }
    final rx = entry['prescription'];
    final hasOwnRx = rx is Map && rx.isNotEmpty && LocalStorageService.prescriptionFitsToken(rx, entry);
    if (hasOwnRx || st == 'prescribed') {
      return 'The doctor has already prescribed for token $serial, so it cannot be reversed.';
    }
    return null;
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

    // A desk linked to the LAN does not upload: the LAN server uploads the decision once from
    // the request_approved message below (kept in the outbox until the server confirms).
    // Direct write + queue + server made up to three cloud writes per approval.
    final uploadsHere = !LanFirestoreGate.isLanDesk;

    // Only the branch doc the request lives in (writing to every alias made empty docs).
    final candidateBranches = {_cloudBranchOf[docId] ?? targetBranch};
    for (final bId in uploadsHere ? candidateBranches : const <String>{}) {
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

    // Offline sync queue so it persists and is pushed to cloud (not on a LAN desk, see above)
    if (uploadsHere) await LocalStorageService.enqueueSync({
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

      // The request's own branch (this page can be open for "all" branches).
      final rb = data['branchId']?.toString().trim() ?? '';
      final peBranch = (rb.isNotEmpty && rb != 'all' && rb != 'global') ? rb : widget.branchId;
      final patientsRef = FirebaseFirestore.instance
          .collection('branches')
          .doc(peBranch)
          .collection('patients');

      String migratedKey = patientId;
      Map<String, dynamic> appliedPatient = {
        ...toApply,
        'branchId': peBranch,
        'reason': data['reason']?.toString() ?? docReason ?? 'Patient Edit Request Approved',
        if (reviewerName != null) 'approvedBy': reviewerName,
      };
      try {
        migratedKey = await LocalStorageService.updatePatientWithCnicMigration(
          oldPatientId: patientId,
          updatedPatient: appliedPatient,
          isFromSync: LanFirestoreGate.isLanDesk,
        );
        appliedPatient = LocalStorageService.getLocalPatient(migratedKey) ?? appliedPatient;
      } catch (e) {
        debugPrint('Hive patient update error: $e');
      }

      // On a LAN desk the server applies and uploads it (from the message below).
      if (!LanFirestoreGate.isLanDesk) {
        final cloudPayload = LocalStorageService.sanitize(appliedPatient);
        await _bestEffort(
          patientsRef.doc(migratedKey).set(cloudPayload, SetOptions(merge: true)),
          'patient update',
        );
        if (migratedKey != patientId) {
          await _bestEffort(patientsRef.doc(patientId).delete(), 'old patient key cleanup');
        }
      }

      try {
        final sanitizedChanges = LocalStorageService.sanitize(appliedPatient);
        RealtimeManager().sendMessage({
          'event_type': 'patient_edit_approved',
          'branchId': peBranch,
          'data': {
            'branchId': peBranch,
            'patientId': patientId,
            'newPatientId': migratedKey,
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

      // The day only (no session letter), and the token's own camp document: the cloud stores
      // tokens under serials/{date}_{camp} in camp branches. Deleting serials/{201126M} hit no
      // document, so the server downloaded the reversed token back as "waiting".
      final dateKey = CampSessionService.getDateKeyFromSerial(tokenSerial);
      final tokenEntry = LocalStorageService.getLocalEntry(widget.branchId, tokenSerial);
      final campDocKey = CampSessionService.getCampDateDocId(
        branchId: widget.branchId,
        dateKey: dateKey,
        campId: (tokenEntry?['campId'] ?? tokenEntry?['dispensaryId'] ?? data['campId'] ?? data['dispensaryId'])?.toString(),
        dispensaryTag: (tokenEntry?['dispensaryTag'] ?? data['dispensaryTag'])?.toString(),
        serial: tokenSerial,
      );

      // Local delete + LAN broadcast FIRST so the token reverses instantly everywhere.
      await LocalStorageService.markSerialReversed(widget.branchId, tokenSerial);
      await LocalStorageService.deleteLocalEntry(widget.branchId, tokenSerial);
      await LocalStorageService.enqueueSync({
        'type': 'token_reversal',
        'branchId': widget.branchId,
        'serial': tokenSerial,
        'dateKey': dateKey,
        'data': {
          'tokenSerial': tokenSerial,
          'serial': tokenSerial,
          'queueType': queueCollection,
          'dateKey': dateKey,
          'campDocKey': campDocKey,
        },
      });
      unawaited(_bestEffort(FirebaseFirestore.instance
          .collection('branches')
          .doc(widget.branchId)
          .collection('serials')
          .doc(campDocKey)
          .collection(queueCollection)
          .doc(tokenSerial)
          .delete(), 'token delete'));

      try {
        RealtimeManager().sendMessage({
          'event_type': 'token_reversal_approved',
          'data': {
            'branchId':    widget.branchId,
            'tokenSerial': tokenSerial,
            'serial':      tokenSerial,
            'queueType':   queueCollection,
            'dateKey':     dateKey,
            'campDocKey':  campDocKey,
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
        await _handleAddStock(itemsToUse, campId: reqCampId, requestId: docId);
      }
    }
    else if (requestType == 'edit_medicine') {
      final itemsToUse = _safeItemList(data['draftItems']).isNotEmpty
          ? _safeItemList(data['draftItems'])
          : _safeItemList(data['items']);
      if (itemsToUse.isNotEmpty) {
        final orig = data['originalData'];
        await _handleEditMedicine(itemsToUse, reviewerUid ?? '', reviewerName,
            campId: reqCampId,
            requestId: docId,
            originalQty: orig is Map ? orig['quantity'] : null);
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
    else if (requestType == ExpiryService.requestType) {
      // Expired-batch removal / expiry fix asked by a dispenser (Med Inventory › Expiry).
      await ExpiryService.applyRequestItems({...data, 'requestId': docId},
          approvedBy: reviewerName ?? LocalStorageService.getActiveUsername());
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
        // Through the stock book: details go everywhere (this PC, LAN, cloud) and the first
        // stock is one movement whose id comes from this request, so approving it twice (or
        // on two PCs) adds the stock once. It used to write the full quantity straight into
        // the branch-wide 'inventory' collection, even for a branch with camps.
        final regPool = StockPool.of(widget.branchId, reqCampId,
            fallbackCamp: CampSessionService.getActiveCamp(widget.branchId));

        for (final item in itemsToUse) {
          final name = item['name']?.toString() ?? '';
          final type = item['type'] ?? '';
          final dose = item['dose'] ?? '';
          final exp  = item['expiryDate'] ?? '';

          final id = RequestUtils.generateDocId(name, type, dose, exp, campId: reqCampId);

          if (regPool != null) {
            final details = <String, dynamic>{
              ...item,
              'isVerified': true,
              'createdBy': data['requestedBy'],
              'createdByName': data['requesterName'],
              'approvedBy': reviewerUid,
              'approvedByName': reviewerName ?? 'Supervisor',
              'addedAt': DateTime.now().toIso8601String(),
            }..remove('quantity');
            await StockActions.addBatch(
              regPool,
              id,
              details,
              initialQty: _safeInt(item['quantity']).toDouble(),
              ref: 'registered (request $docId)',
              opKey: 'req-$docId-$id',
            );
          }

          // Local + LAN + cloud (once, by id) — was a direct cloud write that a LAN desk
          // never sent and that no other PC could see.
          unawaited(StockLog.record({
            'id': 'log_req_${docId}_$id',
            'action': 'medicine_registered',
            'medicineName': name,
            'medicineType': type,
            'dose': dose,
            'quantityAdded': _safeInt(item['quantity']),
            'price': item['price'],
            'expiryDate': exp,
            'performedBy': reviewerUid,
            'performedByName': reviewerName ?? 'Supervisor',
            'medicineId': id,
            'pool': regPool?.key ?? '',
            'approvedRequestId': docId,
            'branchId': widget.branchId,
            if (reqCampId != null) 'dispensaryId': reqCampId,
          }));
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

    // Already decided (on another PC, or from a list captured before that decision): a second
    // approve/reject used to overwrite it and run the stock changes again.
    final currentStatus = (data['status'] ?? 'pending').toString().toLowerCase().trim();
    if (currentStatus == 'approved' || currentStatus == 'rejected') {
      if (mounted) {
        final by = (data['approvedByName'] ?? data['reviewedByName'] ?? data['approvedBy'] ?? data['reviewedBy'] ?? '').toString();
        AppToast.showSnackBar(context, SnackBar(
          content: Text('This request was already $currentStatus${by.isNotEmpty ? ' by $by' : ''}.'),
          duration: const Duration(seconds: 3),
        ));
      }
      return;
    }
    if (newStatus == 'approved' && requestType == 'token_reversal') {
      final blocked = _reversalBlockedReason(data.isNotEmpty ? data : {});
      if (blocked != null) {
        if (mounted) {
          AppToast.showSnackBar(context, SnackBar(content: Text(blocked), duration: const Duration(seconds: 5)));
        }
        return;
      }
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

      // Inventory requests: the decision itself goes in the inventory log (one entry per
      // request, so deciding on two PCs never logs twice).
      final rt = requestType.toLowerCase();
      if (rt.contains('medicine') || rt.contains('stock') || rt.contains('inventory') || rt.contains('restock')) {
        final first = _safeItemList(data['draftItems']).isNotEmpty
            ? _safeItemList(data['draftItems']).first
            : (_safeItemList(data['items']).isNotEmpty ? _safeItemList(data['items']).first : const <String, dynamic>{});
        unawaited(StockLog.record({
          'id': 'log_decision_$docId',
          'action': newStatus == 'approved' ? 'request_approved' : 'request_rejected',
          'requestId': docId,
          'requestType': requestType,
          'medicineName': first['name'] ?? (data['originalData'] is Map ? data['originalData']['name'] : null) ?? '',
          'medicineType': first['type'] ?? '',
          'dose': first['dose'] ?? '',
          'requestedByName': data['requestedByName'] ?? data['requesterName'] ?? '',
          'reason': data['reason'] ?? '',
          if (docReason != null) 'decisionReason': docReason,
          'performedBy': reviewerUid,
          'performedByName': reviewerName ?? LocalStorageService.getActiveUsername(),
          'branchId': targetBranch,
        }));
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

        // A LAN desk does not upload: the server does, once, from request_rejected.
        final uploadsHere = !LanFirestoreGate.isLanDesk;
        // Only the branch doc the request lives in (writing to every alias made empty docs).
        final candidateBranches = {_cloudBranchOf[docId] ?? targetBranch};
        for (final bId in uploadsHere ? candidateBranches : const <String>{}) {
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

        // Offline sync queue so the rejection is persisted (not on a LAN desk, see above)
        if (uploadsHere) await LocalStorageService.enqueueSync({
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

  Future<void> _handleAddStock(List<Map<String, dynamic>> items, {String? campId, String? requestId}) async {
    debugPrint('handleAddStock started with ${items.length} items (Target Camp: $campId)');

    if (items.isEmpty) {
      debugPrint('handleAddStock: items list is empty - returning');
      return;
    }

    final branchRef = FirebaseFirestore.instance
        .collection('branches')
        .doc(widget.branchId);
    // Dispensary stock goes through the stock book below (the camp's own pool); only the
    // warehouse record is written here.
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

      final barcode = (item['barcode'] ?? item['rollNo'] ?? '').toString().trim();
      final itemCode = (item['code'] ?? item['itemCode'] ?? '').toString().trim();
      final packBarcode = (item['packBarcode'] ?? '').toString().trim();

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
        if (barcode.isNotEmpty) 'barcode': barcode,
        if (barcode.isNotEmpty) 'rollNo': barcode,
        if (itemCode.isNotEmpty) 'code': itemCode,
        if (itemCode.isNotEmpty) 'itemCode': itemCode,
        if (packBarcode.isNotEmpty) 'packBarcode': packBarcode,
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

      // Stock book: the batch in this camp's pool gets "+qty" as ONE movement whose id comes
      // from the request, so approving it twice (or on two PCs) adds the stock once. The
      // record itself only gets details; a quantity is never written as a figure. (This used
      // to write into the branch-wide 'inventory' collection even for a branch with camps.)
      final addPool = StockPool.of(widget.branchId, campId,
          fallbackCamp: CampSessionService.getActiveCamp(widget.branchId));
      if (addPool == null) {
        debugPrint('Skipping item "$name" - no camp/pool for this branch');
        continue;
      }
      final details = Map<String, dynamic>.from(commonFields)..remove('quantity');
      if (type == 'Nebulization') {
        details['distilledWater'] = distilledWater ?? 0;
        details['drops']          = drops ?? 0;
      } else {
        details['dose'] = dose;
      }
      final newBatchId = RequestUtils.generateDocId(
        name, type, variantForId, expiry,
        distilledWater: distilledWater, drops: drops, campId: campId,
      );
      // An existing batch of the same medicine, strength and expiry in this pool, if any.
      var targetId = newBatchId;
      for (final b in StockLedger.items(pool: addPool.key)) {
        final sameName = (b['name'] ?? '').toString().toLowerCase().trim() == nameLower.trim();
        final sameType = (b['type'] ?? '').toString() == type;
        final sameDose = type == 'Nebulization' || dose.isEmpty || (b['dose'] ?? '').toString() == dose;
        final sameExpiry = expiry.isEmpty || (b['expiryDate'] ?? '').toString() == expiry;
        if (sameName && sameType && sameDose && sameExpiry) {
          targetId = (b['medicineId'] ?? b['id']).toString();
          break;
        }
      }
      await StockActions.restock(
        addPool,
        targetId,
        qty.toDouble(),
        details: details,
        ref: 'approved request',
        opKey: 'req-${requestId ?? DateTime.now().microsecondsSinceEpoch}-$targetId',
      );

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
      List<Map<String, dynamic>> items, String reviewerUid, String? reviewerName,
      {String? campId, String? requestId, Object? originalQty}) async {
    if (items.isEmpty) return;

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

      final barcode = (item['barcode'] ?? item['rollNo'] ?? '').toString().trim();
      final itemCode = (item['code'] ?? item['itemCode'] ?? '').toString().trim();
      final packBarcode = (item['packBarcode'] ?? '').toString().trim();
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
        if (itemCode.isNotEmpty) 'code': itemCode,
        if (itemCode.isNotEmpty) 'itemCode': itemCode,
        if (barcode.isNotEmpty) 'barcode': barcode,
        if (barcode.isNotEmpty) 'rollNo': barcode,
        if (packBarcode.isNotEmpty) 'packBarcode': packBarcode,
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

      // Stock book: details are saved without quantity; a changed quantity is recorded as the
      // difference from what this PC shows (so dispenses made meanwhile on other PCs are kept).
      // A changed id (name/strength/expiry edited) hides the old batch and opens the new one
      // with the approved quantity, once per request.
      final editPool = StockPool.of(widget.branchId, effCamp,
          fallbackCamp: CampSessionService.getActiveCamp(widget.branchId));
      if (editPool == null) continue;
      final details = Map<String, dynamic>.from(newData)
        ..remove('quantity')
        ..remove('updatedAt');
      // Only the change the requester typed (new − figure shown when they asked), once per
      // request. Setting the absolute figure undid every dispense made while the request
      // waited: asked at 100 (price only), 30 dispensed, approved → shelf back to 100.
      final o = originalQty is num
          ? originalQty.toDouble()
          : double.tryParse(originalQty?.toString() ?? '');
      final requestedChange = o == null ? null : qty.toDouble() - o;
      if (cleanOldId.isNotEmpty && cleanOldId == newId) {
        await StockActions.saveDetails(editPool, newId, details);
        if (requestedChange != null) {
          await StockActions.countDifference(editPool, newId, requestedChange,
              name: name, reason: 'edit approved', opKey: 'edit-${requestId ?? '$cleanOldId-$newId'}');
        } else {
          // Old requests without the original figure: as before.
          await StockActions.setCounted(editPool, newId, qty.toDouble(), reason: 'edit approved');
        }
      } else {
        // The old batch's stock as it is now (dispenses since the request kept), plus the change.
        double carry = qty.toDouble();
        if (requestedChange != null && cleanOldId.isNotEmpty) {
          final oldItem = StockLedger.item(editPool.key, cleanOldId);
          final now = oldItem == null ? 0.0 : StockReader.qty(oldItem);
          carry = now + requestedChange;
          if (carry < 0) carry = 0;
        }
        if (cleanOldId.isNotEmpty) await StockActions.deleteBatch(editPool, cleanOldId);
        await StockActions.addBatch(editPool, newId, details,
            initialQty: carry, ref: 'edit approved',
            opKey: 'edit-${requestId ?? ''}-$cleanOldId-$newId');
      }

      // Add to log (local + LAN + cloud once by id)
      unawaited(StockLog.record({
        'id': 'log_edit_${requestId ?? DateTime.now().millisecondsSinceEpoch}_$newId',
        'action': 'medicine_edited',
        'medicineName': name,
        'medicineType': type,
        'dose': dose,
        'oldId': oldId,
        'newId': newId,
        'medicineId': newId,
        'pool': editPool.key,
        'approvedRequestId': requestId,
        'performedBy': reviewerUid,
        'performedByName': reviewerName ?? 'Supervisor',
        'branchId': widget.branchId,
        if (campId != null) 'dispensaryId': campId,
      }));
    }
  }

  Future<void> _handleDeleteMedicine(
      List<Map<String, dynamic>> items, {String? campId}) async {
    if (items.isEmpty) return;

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
      // Hidden everywhere (this PC, LAN, cloud) through the stock book; history is kept.
      final delPool = StockPool.of(widget.branchId, campId,
          fallbackCamp: CampSessionService.getActiveCamp(widget.branchId));
      if (delPool != null) {
        await StockActions.deleteBatch(delPool, id);
        unawaited(StockLog.record({
          'id': 'log_del_${delPool.key.replaceAll('/', '_')}_$id',
          'action': 'remove_medicine',
          'medicineName': name,
          'medicineType': type,
          'dose': dose,
          'expiryDate': expiry,
          'medicineId': id,
          'pool': delPool.key,
          'reason': (item['reason'] ?? 'approved delete request').toString(),
          'branchId': widget.branchId,
          if (campId != null) 'dispensaryId': campId,
        }));
      }
    }
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
