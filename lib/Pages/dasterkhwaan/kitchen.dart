// lib/pages/dasterkhwaan/kitchen.dart
//
// Main kitchen panel — initialises state, loads Firebase data, and
// builds the 4-tab scaffold.  All dialog/sheet logic lives in:
//   • widgets/cook_dialog.dart   — food logging (cook / received / saved)
//   • widgets/stock_dialogs.dart — inventory add / adjust

import 'package:gmwf/utils/debounced_box_listenable.dart';
import 'package:gmwf/design/components/decorative_image.dart' show GDecor;
import 'package:gmwf_ui/gmwf_ui.dart' show GEmptyIllustration, GEmptyIllustrationKind;
import 'dart:async';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:gmwf/design/tokens/comfort_colors.dart';
import '../../widgets/lazy_indexed_stack.dart';
import 'package:flutter/material.dart';
import 'package:gmwf/utils/base64_image_cache.dart';
import 'package:gmwf/design/components/app_toast.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../models/stock_item.dart';
import 'widgets/cook_dialog.dart';
import 'widgets/stock_dialogs.dart';
import '../../widgets/global_module_wrapper.dart';
import '../home/home_module_host.dart';
import '../../services/auth_service.dart';
import '../../services/local_storage_service.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../services/camp_session_service.dart';
import '../../realtime/realtime_manager.dart';
import '../../realtime/realtime_events.dart';
import '../../services/sync_service.dart';
import '../../services/pre_login_security_service.dart';
import '../../services/cloud/cloud_db.dart';
import '../../services/stock_floor.dart';
import '../settings_page.dart';
import 'food_log_screen.dart';
export 'widgets/cook_dialog.dart'
    show
        kPrimary,
        kAccent,
        kSuccess,
        kWarning,
        kInfo,
        kPurple,
        kTeal,
        kSurface,
        kCardBg,
        kTextDark,
        kTextMid,
        kTextLight;

// ─────────────────────────── Design Tokens ──────────────────────────────────

abstract class _DS {
  static const Color bg       = SoftPalette.gray100;
  static const Color surface  = SoftPalette.gray50;
  static const Color surface2 = SoftPalette.gray100;
  static const Color border   = SoftPalette.teal150t;
  static const Color border2  = SoftPalette.teal200m;

  static Color getBg(bool isDark) => isDark ? SoftPalette.slate900 : SoftPalette.gray100;
  static Color getSurface(bool isDark) => isDark ? SoftPalette.slate800 : SoftPalette.gray50;
  static Color getSurface2(bool isDark) => isDark ? SoftPalette.slate750 : SoftPalette.gray100;
  static Color getBorder(bool isDark) => isDark ? SoftPalette.slate700 : SoftPalette.teal150t;
  static Color getBorder2(bool isDark) => isDark ? SoftPalette.slate600 : SoftPalette.teal200m;
  static Color getInk(bool isDark) => isDark ? SoftPalette.gray50 : SoftPalette.gray900;
  static Color getInk2(bool isDark) => isDark ? SoftPalette.slate200 : SoftPalette.teal750m;
  static Color getInk3(bool isDark) => isDark ? SoftPalette.slate350 : SoftPalette.teal500m;

  static const Color sage     = SoftPalette.teal750m;
  static const Color mint     = SoftPalette.teal350;
  static const Color mintBg   = SoftPalette.teal50;

  static const Color amber    = SoftPalette.orange400;
  static const Color amberBg  = SoftPalette.yellow50m;
  static const Color green    = SoftPalette.emerald500;
  static const Color greenBg  = SoftPalette.emerald100m;
  static const Color red      = SoftPalette.red500;
  static const Color redBg    = SoftPalette.red100m;
  static const Color purple   = SoftPalette.violet550;
  static const Color purpleBg = SoftPalette.violet100;

  static const Color ink      = SoftPalette.gray900;
  static const Color ink2     = SoftPalette.teal750m;
  static const Color ink3     = SoftPalette.teal500m;

  static const double r12 = 12;
  static const double r14 = 14;
  static const double r16 = 16;
  static const double r22 = 22;
}

abstract class _TS {
  static TextStyle displayLg(Color c) => GoogleFonts.dmSerifDisplay(
      fontSize: 28, color: c, height: 1.1);

  static TextStyle displayMd(Color c) => GoogleFonts.dmSerifDisplay(
      fontSize: 22, color: c, height: 1.2);

  static TextStyle label({Color c = _DS.ink3, double size = 10}) =>
      GoogleFonts.inter(
          fontSize: size, fontWeight: FontWeight.w600,
          letterSpacing: 1.2, color: c);

  static TextStyle body({Color? c, double size = 14, FontWeight w = FontWeight.w400}) =>
      GoogleFonts.inter(fontSize: size, fontWeight: w, color: c ?? _DS.ink);

  static TextStyle num({Color? c, double size = 22}) =>
      GoogleFonts.inter(fontSize: size, fontWeight: FontWeight.w600, color: c ?? _DS.ink, height: 1.0);
}

final Map<String, ({String title, String shortTitle, String urdu, IconData icon, Color color, Color bg, List<Color> gradient})> _kitchenSessionMeta = {
  'breakfast': (
    title: 'Breakfast (ناشتہ)',
    shortTitle: 'Breakfast',
    urdu: 'ناشتہ کا دسترخوان',
    icon: Icons.wb_sunny_rounded,
    color: SoftPalette.orange400,
    bg: SoftPalette.yellow50m,
    gradient: const [SoftPalette.orange500, SoftPalette.orange400],
  ),
  'lunch': (
    title: 'Lunch (دوپہر)',
    shortTitle: 'Lunch',
    urdu: 'دوپہر کا دسترخوان',
    icon: Icons.sunny,
    color: SoftPalette.teal500,
    bg: SoftPalette.teal50,
    gradient: const [SoftPalette.teal550, SoftPalette.teal500],
  ),
  'dinner': (
    title: 'Dinner (رات)',
    shortTitle: 'Dinner',
    urdu: 'رات کا دسترخوان',
    icon: Icons.nightlight_round,
    color: SoftPalette.indigo550,
    bg: SoftPalette.slate100,
    gradient: const [SoftPalette.indigo700, SoftPalette.indigo550],
  ),
};

String _kitchenNormalizeSession(String? raw) {
  final s = (raw ?? 'lunch').toLowerCase().trim();
  if (s == 'breakfast' || s == 'morning') return 'breakfast';
  if (s == 'dinner' || s == 'evening' || s == 'night') return 'dinner';
  return 'lunch';
}

String _kitchenSessionUrdu(String session) {
  final s = _kitchenNormalizeSession(session);
  if (s == 'breakfast') return 'ناشتہ کا دسترخوان';
  if (s == 'dinner') return 'رات کا دسترخوان';
  return 'دوپہر کا دسترخوان';
}

class DasterkhwaanKitchen extends StatefulWidget {
  static const String routeName = '/dasterkhwaan-kitchen';
  final String? branchId;
  final String? username;
  final String? role;
  /// Which bottom-nav tab to start on: 0=Tokens 1=Cooking 2=Inventory 3=History
  final int initialTab;

  const DasterkhwaanKitchen({
    super.key,
    this.branchId,
    this.username,
    this.role,
    this.initialTab = 0,
  });

  @override
  State<DasterkhwaanKitchen> createState() => _DasterkhwaanKitchenState();
}

class _DasterkhwaanKitchenState extends State<DasterkhwaanKitchen>
    with TickerProviderStateMixin {
  late int _currentNav;
  String _username = 'Kitchen Staff';
  String? _branchId;
  String? _role;

  final DateFormat _dateFmt    = DateFormat('yyyy-MM-dd');
  final DateFormat _displayFmt = DateFormat('dd MMM yyyy');
  String get today => _dateFmt.format(DateTime.now()); // not frozen at screen open: tokens after midnight went to yesterday

  List<StockItem> _allStockItems = [];
  bool _stockLoaded = false;

  late AnimationController _animCtrl;
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  final _qtyCtrl = TextEditingController(text: '1');
  final double _pricePerToken = 10.0;
  late String _selectedSession;
  bool _isGenerating = false;
  bool _isReversing = false;

  Map<String, dynamic> _stats = {
    'total': 0,
    'served': 0,
    'breakfastTotal': 0,
    'breakfastServed': 0,
    'lunchTotal': 0,
    'lunchServed': 0,
    'dinnerTotal': 0,
    'dinnerServed': 0,
  };

  // ── Default stock seeds ──────────────────────────────────────────────────
  static const List<Map<String, String>> _defaultStockItems = [
    {'name': 'Piyaz',        'unit': 'kg'},
    {'name': 'Tamatar',      'unit': 'kg'},
    {'name': 'Aloo',         'unit': 'kg'},
    {'name': 'Gobi',         'unit': 'kg'},
    {'name': 'Matar',        'unit': 'kg'},
    {'name': 'Palak',        'unit': 'kg'},
    {'name': 'Shaljam',      'unit': 'kg'},
    {'name': 'Band Gobi',    'unit': 'kg'},
    {'name': 'Phool Gobi',   'unit': 'kg'},
    {'name': 'Kheera',       'unit': 'kg'},
    {'name': 'Turai',        'unit': 'kg'},
    {'name': 'Karela',       'unit': 'kg'},
    {'name': 'Baingan',      'unit': 'kg'},
    {'name': 'Arvi',         'unit': 'kg'},
    {'name': 'Methi',        'unit': 'kg'},
    {'name': 'Sarson',       'unit': 'kg'},
    {'name': 'Gajar',        'unit': 'kg'},
    {'name': 'Mooli',        'unit': 'kg'},
    {'name': 'Shimla Mirch', 'unit': 'kg'},
    {'name': 'Bara Gosht',   'unit': 'kg'},
    {'name': 'Chota Gosht',  'unit': 'kg'},
    {'name': 'Murgh',        'unit': 'kg'},
    {'name': 'Keema',        'unit': 'kg'},
    {'name': 'Machli',       'unit': 'kg'},
    {'name': 'Anda',         'unit': 'piece'},
    {'name': 'Chawal',       'unit': 'kg'},
    {'name': 'Daal Masoor',  'unit': 'kg'},
    {'name': 'Daal Chana',   'unit': 'kg'},
    {'name': 'Daal Mash',    'unit': 'kg'},
    {'name': 'Daal Moong',   'unit': 'kg'},
    {'name': 'Maida',        'unit': 'kg'},
    {'name': 'Atta',         'unit': 'kg'},
    {'name': 'Suji',         'unit': 'kg'},
    {'name': 'Besan',        'unit': 'kg'},
    {'name': 'Ghee',         'unit': 'kg'},
    {'name': 'Oil',          'unit': 'liter'},
    {'name': 'Makhan',       'unit': 'kg'},
    {'name': 'Masala',       'unit': 'gram'},
    {'name': 'Namak',        'unit': 'kg'},
    {'name': 'Hari Mirch',   'unit': 'kg'},
    {'name': 'Lal Mirch',    'unit': 'gram'},
    {'name': 'Haldi',        'unit': 'gram'},
    {'name': 'Zeera',        'unit': 'gram'},
    {'name': 'Dhania',       'unit': 'gram'},
    {'name': 'Garam Masala', 'unit': 'gram'},
    {'name': 'Adrak',        'unit': 'kg'},
    {'name': 'Lehsan',       'unit': 'kg'},
    {'name': 'Pudina',       'unit': 'gram'},
    {'name': 'Limu',         'unit': 'piece'},
    {'name': 'Dahi',         'unit': 'kg'},
    {'name': 'Doodh',        'unit': 'liter'},
    {'name': 'Paneer',       'unit': 'kg'},
    {'name': 'Malai',        'unit': 'kg'},
    {'name': 'Khajoor',      'unit': 'kg'},
    {'name': 'Chini',        'unit': 'kg'},
    {'name': 'Chai Patti',   'unit': 'gram'},
    {'name': 'Paani',        'unit': 'liter'},
    {'name': 'Imli',         'unit': 'gram'},
    {'name': 'Sirka',        'unit': 'liter'},
    {'name': 'Soya Sauce',   'unit': 'liter'},
    {'name': 'Ketchup',      'unit': 'liter'},
    {'name': 'Bread',        'unit': 'piece'},
    {'name': 'Roti',         'unit': 'piece'},
  ];

  @override
  void initState() {
    super.initState();
    _currentNav = widget.initialTab.clamp(0, 2);
    _animCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 400))
      ..forward();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    // Same as office_boy: no endless pulse with reduced motion (every pulse frame repaints).
    if (!GDecor.reduceMotion) _pulseCtrl.repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.025).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
    _selectedSession = CampSessionService.resolveDasterkhwaanSession(null, widget.branchId);
    _role = widget.role;

    if (widget.branchId != null && widget.branchId!.isNotEmpty && widget.branchId != 'all') {
      _branchId = LocalStorageService.sanitizeBranchId(widget.branchId);
      _username = widget.username ?? 'Kitchen Staff';
      SyncService().start(_branchId!);
      _loadAllStockItems().then((_) => _applyPreviousDaySaved());
      _recalculateLocalStats();
    } else {
      _loadUserAndBranch();
    }
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    _pulseCtrl.dispose();
    _qtyCtrl.dispose();
    super.dispose();
  }

  // ── Firebase helpers ─────────────────────────────────────────────────────

  Future<void> _loadUserAndBranch() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // Check local Hive cache first (0 cloud reads)
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final u = box.get('user_data') ?? box.get('currentUser');
        if (u is Map) {
          final b = (u['branchId'] ?? u['branch'] ?? u['selectedBranchId'])?.toString();
          if (b != null && b.isNotEmpty && b != 'all') {
            SyncService().start(b);
            setState(() {
              _username = (u['username'] ?? u['name'] ?? user.email?.split('@').first ?? 'Kitchen Staff').toString();
              _branchId = LocalStorageService.sanitizeBranchId(b);
              _role ??= u['role']?.toString();
            });
            await _loadAllStockItems();
            await _applyPreviousDaySaved();
            _recalculateLocalStats();
            return;
          }
        }
        final cb = box.get('current_branch_id')?.toString();
        if (cb != null && cb.isNotEmpty && cb != 'all') {
          SyncService().start(cb);
          setState(() {
            _username = user.email?.split('@').first ?? 'Kitchen Staff';
            _branchId = LocalStorageService.sanitizeBranchId(cb);
          });
          await _loadAllStockItems();
          await _applyPreviousDaySaved();
          _recalculateLocalStats();
          unawaited(LocalStorageService.downloadDasterkhwaanTokens(cb));
          return;
        }
      }
    } catch (_) {}

    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get()
          .timeout(const Duration(seconds: 3));
      if (userDoc.exists && userDoc.data() != null) {
        final data = userDoc.data()!;
        final b = (data['branchId'] ?? data['branch'])?.toString();
        if (b != null && b.isNotEmpty && b != 'all') {
          SyncService().start(b);
          if (mounted) {
            setState(() {
              _username = data['username'] ??
                  user.email?.split('@').first ??
                  'Kitchen Staff';
              _branchId = LocalStorageService.sanitizeBranchId(b);
              _role ??= data['role'];
            });
          }
          await _loadAllStockItems();
          await _applyPreviousDaySaved();
          _recalculateLocalStats();
          unawaited(LocalStorageService.downloadDasterkhwaanTokens(b));
          return;
        }
      }
    } catch (_) {}

    try {
      final branches = await FirebaseFirestore.instance
          .collection('branches')
          .get()
          .timeout(const Duration(seconds: 4));
      for (final branch in branches.docs) {
        final doc = await branch.reference
            .collection('users')
            .doc(user.uid)
            .get()
            .timeout(const Duration(seconds: 2));
        if (doc.exists) {
          final data = doc.data()!;
          SyncService().start(branch.id);
          if (mounted) {
            setState(() {
              _username = data['username'] ??
                  user.email?.split('@').first ??
                  'Kitchen Staff';
              _branchId = LocalStorageService.sanitizeBranchId(branch.id);
              _role ??= data['role'];
            });
          }
          await _loadAllStockItems();
          await _applyPreviousDaySaved();
          _recalculateLocalStats();
          unawaited(LocalStorageService.downloadDasterkhwaanTokens(branch.id));
          return;
        }
      }
    } catch (_) {}
  }

  Future<void> _loadAllStockItems() async {
    if (_branchId == null) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('branches')
          .doc(_branchId)
          .collection('dasterkhwaan_stock')
          .orderBy('name')
          .get()
          .timeout(const Duration(seconds: 4));

      List<StockItem> items =
          snap.docs.map((e) => StockItem.fromMap(e.data(), e.id)).toList();

      // Stock cannot be below 0: set negative cloud values back to 0 (StockItem already
      // shows them as 0).
      final negativePaths = <String>[
        for (final d in snap.docs)
          if ((d.data()['quantity'] is num) && (d.data()['quantity'] as num) < 0)
            d.reference.path,
      ];
      if (negativePaths.isNotEmpty) unawaited(StockFloor.repairAll(negativePaths));

      if (items.isEmpty) {
        final batch = CloudDb.instance.batch();
        for (final item in _defaultStockItems) {
          batch.set(
            FirebaseFirestore.instance
                .collection('branches')
                .doc(_branchId)
                .collection('dasterkhwaan_stock')
                .doc(item['name']!),
            {
              'name':        item['name'],
              'quantity':    0.0,
              'unit':        item['unit'],
              'lastUpdated': FieldValue.serverTimestamp(),
            },
          );
        }
        await batch.commit().timeout(const Duration(seconds: 4));
        final newSnap = await FirebaseFirestore.instance
            .collection('branches')
            .doc(_branchId)
            .collection('dasterkhwaan_stock')
            .orderBy('name')
            .get()
            .timeout(const Duration(seconds: 4));
        items = newSnap.docs
            .map((e) => StockItem.fromMap(e.data(), e.id))
            .toList();
      }

      if (mounted) {
        setState(() {
          _allStockItems = items..sort((a, b) => a.name.compareTo(b.name));
          _stockLoaded   = true;
        });
      }
    } catch (e) {
      debugPrint('[Kitchen] Stock load warning: $e');
      if (mounted) {
        setState(() {
          _allStockItems = _defaultStockItems.map((item) => StockItem(
            id: item['name']!,
            name: item['name']!,
            quantity: 0.0,
            unit: item['unit']!,
            lastUpdated: Timestamp.now(),
          )).toList();
          _stockLoaded = true;
        });
      }
    }
  }

  Future<void> _applyPreviousDaySaved() async {
    if (_branchId == null) return;
    try {
      final yesterday = _dateFmt
          .format(DateTime.now().subtract(const Duration(days: 1)));
      final dayRef = FirebaseFirestore.instance
          .collection('branches')
          .doc(_branchId)
          .collection('dasterkhwaan')
          .doc(yesterday);

      final daySnap = await dayRef.get().timeout(const Duration(seconds: 4));
      if (!daySnap.exists) return;
    final dayData = daySnap.data()!;
    if (dayData['savedCarriedOver'] == true) return;

    final cookingSnap =
        await dayRef.collection('cooking_sessions').get();
    if (cookingSnap.docs.isEmpty) return;

    final batch = CloudDb.instance.batch();
    bool hasCarryOver = false;

    for (final doc in cookingSnap.docs) {
      final data    = doc.data();
      final savedKg = (data['savedKg'] as num? ?? 0).toDouble();
      if (savedKg <= 0) continue;
      hasCarryOver = true;
      final dish    = (data['dish'] as String? ?? 'Saved Food').trim();
      final stockRef = FirebaseFirestore.instance
          .collection('branches')
          .doc(_branchId)
          .collection('dasterkhwaan_stock')
          .doc('Saved: $dish');
      batch.set(
        stockRef,
        {
          'name':        'Saved: $dish',
          'quantity':    FieldValue.increment(savedKg),
          'unit':        'kg',
          'lastUpdated': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    }

    if (hasCarryOver) {
      batch.update(dayRef, {'savedCarriedOver': true});
      await batch.commit();
      await _loadAllStockItems();
    } else {
      await CloudDb.instance.ref(dayRef).update({'savedCarriedOver': true});
    }
  } catch (e) {
    debugPrint('[Kitchen] _applyPreviousDaySaved error: $e');
  }
}

  Future<void> _adjustStock(String itemName, double delta) async {
    final ref = FirebaseFirestore.instance
        .collection('branches')
        .doc(_branchId)
        .collection('dasterkhwaan_stock')
        .doc(itemName);
    await CloudDb.instance.ref(ref).update({
      'quantity':    FieldValue.increment(delta),
      'lastUpdated': FieldValue.serverTimestamp(),
    });
    // Stock cannot go below 0: floor the cloud value after a deduction.
    if (delta < 0) unawaited(StockFloor.repair(ref.path));
    final idx = _allStockItems.indexWhere((i) => i.name == itemName);
    if (idx != -1) {
      setState(() {
        final next = _allStockItems[idx].quantity + delta;
        _allStockItems[idx].quantity     = next < 0 ? 0.0 : next;
        _allStockItems[idx].lastUpdated  = Timestamp.now();
      });
    }
  }

  DocumentReference<Map<String, dynamic>> _dayDoc(String date) =>
      FirebaseFirestore.instance
          .collection('branches')
          .doc(_branchId!)
          .collection('dasterkhwaan')
          .doc(date);

  CollectionReference<Map<String, dynamic>> _tokensCol(String date) =>
      _dayDoc(date).collection('tokens');

  CollectionReference<Map<String, dynamic>> _cookingCol(String date) =>
      _dayDoc(date).collection('cooking_sessions');

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    AppToast.showSnackBar(
      context,
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? SoftPalette.red500 : SoftPalette.emerald500,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Future<void> _recalculateLocalStats() async {
    if (_branchId == null) return;
    int localTotal = 0;
    int localServed = 0;
    int localBreakfast = 0;
    int localBreakfastServed = 0;
    int localLunch = 0;
    int localLunchServed = 0;
    int localDinner = 0;
    int localDinnerServed = 0;

    try {
      if (Hive.isBoxOpen(LocalStorageService.dasterkhwaanTokensBox)) {
        final box = Hive.box(LocalStorageService.dasterkhwaanTokensBox);
        final seenNumbers = <int>{};
        for (final raw in box.values) {
          if (raw is Map) {
            final t = Map<String, dynamic>.from(raw);
            if (t['dateKey'] == today && t['branchId'] == _branchId) {
              final n = (t['number'] as num?)?.toInt() ?? 0;
              if (n > 0 && !seenNumbers.add(n)) continue;
              localTotal++;
              final isServed = t['served'] == true;
              if (isServed) localServed++;
              final s = _kitchenNormalizeSession(t['session'] as String?);
              if (s == 'breakfast') {
                localBreakfast++;
                if (isServed) localBreakfastServed++;
              } else if (s == 'dinner') {
                localDinner++;
                if (isServed) localDinnerServed++;
              } else {
                localLunch++;
                if (isServed) localLunchServed++;
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[Kitchen] Local stats recalculate error: $e');
    }

    final updated = {
      'total': localTotal,
      'served': localServed,
      'breakfastTotal': localBreakfast,
      'breakfastServed': localBreakfastServed,
      'lunchTotal': localLunch,
      'lunchServed': localLunchServed,
      'dinnerTotal': localDinner,
      'dinnerServed': localDinnerServed,
    };

    if (mounted) {
      setState(() => _stats = updated);
    } else {
      _stats = updated;
    }
  }

  Future<void> _generateTokens() async {
    if (_isGenerating) return;
    _isGenerating = true;
    try {
      final quantity = int.tryParse(_qtyCtrl.text.trim()) ?? 0;
      if (quantity <= 0) {
        _showSnack('Enter a valid quantity', isError: true);
        return;
      }
      _branchId = LocalStorageService.sanitizeBranchId(_branchId);
      if (_branchId == null || !LocalStorageService.isValidBranchId(_branchId)) {
        _showSnack('Branch not found!', isError: true);
        return;
      }
      HapticFeedback.mediumImpact();

      // 1. Calculate next sequential start number
      int startNum = 1;
      try {
        final box = await LocalStorageService.openBoxSafe(LocalStorageService.dasterkhwaanTokensBox);
        int maxNum = 0;
        for (final raw in box.values) {
          if (raw is Map) {
            final t = Map<String, dynamic>.from(raw);
            if (t['dateKey'] == today && t['branchId'] == _branchId) {
              final n = (t['number'] as num?)?.toInt() ?? 0;
              if (n > maxNum) maxNum = n;
            }
          }
        }
        startNum = maxNum + 1;
      } catch (_) {}

      final nowIso = DateTime.now().toIso8601String();
      final tokensList = <Map<String, dynamic>>[];
      final originDevice = await PreLoginSecurityService.getDeviceId();
      final devTag = SyncService.foodTokenDeviceTag(originDevice);

      for (int i = 0; i < quantity; i++) {
        final num = startNum + i;
        // Device tag in the id so two PCs never overwrite each other's token; 'number' unchanged.
        final tid = 'dst_${_branchId}_${today}_${num}_$devTag';
        tokensList.add({
          'id': tid,
          'localId': tid,
          'number': num,
          'time': nowIso,
          'served': false,
          'session': _selectedSession,
          'branchId': _branchId,
          'dateKey': today,
          'issuedBy': _username,
          'pricePerToken': _pricePerToken,
          'syncStatus': 'pending',
          'originDevice': originDevice,
        });
      }

      // ── STEP 1: Save Locally First (Hive) ──────────────────────────────
      try {
        final box = await LocalStorageService.openBoxSafe(LocalStorageService.dasterkhwaanTokensBox);
        for (final t in tokensList) {
          await box.put(t['id'], t);
        }
      } catch (e) {
        debugPrint('[Kitchen] Local token write error: $e');
      }

      final firstNum = tokensList.isNotEmpty ? tokensList.first['number'] : 1;
      final lastNum = tokensList.isNotEmpty ? tokensList.last['number'] : quantity;
      final batchId = 'dst_batch_${_branchId}_${today}_${firstNum}_${lastNum}_${DateTime.now().millisecondsSinceEpoch}';

      // ── STEP 2: Send to LAN Server (if connected) ──────────────────────
      final isLanConnected = RealtimeManager().isConnected;
      if (isLanConnected) {
        try {
          RealtimeManager().sendMessage(
            RealtimeEvents.payload(
              type: RealtimeEvents.saveOfficeBoyToken,
              data: {
                'branchId': _branchId,
                'dateKey': today,
                'session': _selectedSession,
                'quantity': quantity,
                'tokens': tokensList,
                'issuedBy': _username,
                'pricePerToken': _pricePerToken,
                'timestamp': nowIso,
                'batchId': batchId,
              },
            ),
          );
        } catch (e) {
          debugPrint('[Kitchen] Realtime LAN broadcast error: $e');
        }
      }

      // ── STEP 3: Upload through the cloud queue ─────────────────────────
      // Always queued and sent at once (urgent), like the Office Boy screen. The direct SDK
      // batch with a 6 s timeout could "time out" yet still be sent later by the SDK while the
      // queue sent the same batch, counting it twice.
      {
        try {
          if (_branchId != null && _branchId!.isNotEmpty) {
            SyncService().start(_branchId!);
          }
          await LocalStorageService.enqueueSync({
            'type': 'save_dasterkhwan_tokens',
            'entityId': batchId,
            'batchId': batchId,
            'branchId': _branchId,
            'dateKey': today,
            'data': {
              'branchId': _branchId,
              'dateKey': today,
              'session': _selectedSession,
              'quantity': quantity,
              'tokens': tokensList,
              'issuedBy': _username,
              'pricePerToken': _pricePerToken,
              'batchId': batchId,
            },
          });
          SyncService().triggerUpload(urgent: true);
        } catch (e) {
          debugPrint('[Kitchen] Sync enqueue error: $e');
        }
      }

      if (!mounted) return;
      _recalculateLocalStats();
      String sessionDisplayName = 'Meal';
      if (_selectedSession == 'breakfast') {
        sessionDisplayName = 'Breakfast (ناشتہ)';
      } else if (_selectedSession == 'lunch') {
        sessionDisplayName = 'Lunch (دوپہر)';
      } else if (_selectedSession == 'dinner') {
        sessionDisplayName = 'Dinner (رات)';
      }
      _showSnack('$quantity $sessionDisplayName Token${quantity > 1 ? 's' : ''} Issued · PKR ${(quantity * _pricePerToken).toStringAsFixed(0)}');
      _qtyCtrl.text = '1';
      setState(() {});
    } finally {
      _isGenerating = false;
    }
  }

  Future<void> _showReverseTokensDialog() async {
    if (_isReversing) return;
    _isReversing = true;
    try {
      if (_branchId == null) {
        _showSnack('Branch not found!', isError: true);
        return;
      }

      final List<Map<String, dynamic>> localUnserved = [];
      try {
        final box = await LocalStorageService.openBoxSafe(LocalStorageService.dasterkhwaanTokensBox);
        for (final raw in box.values) {
          if (raw is Map) {
            final t = Map<String, dynamic>.from(raw);
            if (t['dateKey'] == today && t['branchId'] == _branchId && t['served'] != true) {
              localUnserved.add(t);
            }
          }
        }
      } catch (_) {}

      try {
        final daySnap = await _tokensCol(today).get().timeout(const Duration(seconds: 2));
        for (final d in daySnap.docs) {
          final data = d.data();
          if (data['served'] == true) continue;
          final docId = data['localId'] ?? d.id;
          if (!localUnserved.any((x) => x['id'] == docId || x['localId'] == docId)) {
            localUnserved.add({
              'id': docId,
              'localId': docId,
              'number': data['number'] ?? 0,
              'session': data['session'] ?? 'lunch',
              'served': false,
              'branchId': _branchId,
              'dateKey': today,
            });
          }
        }
      } catch (_) {}

      localUnserved.sort((a, b) {
        final numA = (a['number'] as num?)?.toInt() ?? 0;
        final numB = (b['number'] as num?)?.toInt() ?? 0;
        return numB.compareTo(numA);
      });

      if (localUnserved.isEmpty) {
        _showSnack('No unserved tokens available to reverse today.', isError: true);
        return;
      }

      final reverseQtyCtrl = TextEditingController(text: '1');
      final confirmQty = await showDialog<int>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (dialogCtx, setS) {
            final isDark = Theme.of(dialogCtx).brightness == Brightness.dark;
            final qty = int.tryParse(reverseQtyCtrl.text) ?? 0;
            return AlertDialog(
              backgroundColor: _DS.getSurface(isDark),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_DS.r22)),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: isDark ? _DS.red.withValues(alpha: 0.18) : _DS.redBg,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.undo_rounded, color: _DS.red, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Text('Reverse Food Tokens',
                      style: GoogleFonts.dmSerifDisplay(
                          fontSize: 20, color: _DS.getInk(isDark))),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Unintentionally issued tokens can be voided. ${localUnserved.length} unserved token(s) available today.',
                    style: GoogleFonts.inter(
                        fontSize: 13, color: _DS.getInk3(isDark)),
                  ),
                  const SizedBox(height: 16),
                  Text('TOKENS TO REVERSE',
                      style: _TS.label(c: _DS.getInk3(isDark))),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [1, 2, 3, 5, 10].map((q) {
                      final sel = reverseQtyCtrl.text == q.toString();
                      return GestureDetector(
                        onTap: () => setS(() => reverseQtyCtrl.text = q.toString()),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: sel ? _DS.red : _DS.getSurface2(isDark),
                            borderRadius: BorderRadius.circular(_DS.r12),
                          ),
                          child: Text('$q',
                              style: GoogleFonts.inter(
                                  color: sel
                                      ? SoftPalette.gray50
                                      : _DS.getInk(isDark),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13)),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: reverseQtyCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (_) => setS(() {}),
                    style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: _DS.getInk(isDark)),
                    decoration: InputDecoration(
                      hintText: 'Custom quantity…',
                      hintStyle: GoogleFonts.inter(
                          fontSize: 13, color: _DS.getInk3(isDark)),
                      suffixText:
                          '= PKR ${(qty * _pricePerToken).toStringAsFixed(0)}',
                      suffixStyle: GoogleFonts.inter(
                          color: _DS.red,
                          fontWeight: FontWeight.bold,
                          fontSize: 12),
                      filled: true,
                      fillColor: _DS.getSurface2(isDark),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(_DS.r14),
                          borderSide: BorderSide.none),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text('Cancel',
                      style: GoogleFonts.inter(
                          color: _DS.getInk3(isDark),
                          fontWeight: FontWeight.w600)),
                ),
                ElevatedButton.icon(
                  onPressed: (qty <= 0 || qty > localUnserved.length)
                      ? null
                      : () => Navigator.pop(ctx, qty),
                  icon: const Icon(Icons.history_toggle_off_rounded, size: 18),
                  label: Text('Reverse $qty Token${qty != 1 ? "s" : ""}'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _DS.red,
                    foregroundColor: SoftPalette.gray50,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(_DS.r14)),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                  ),
                ),
              ],
            );
          },
        ),
      );

      if (confirmQty == null || confirmQty <= 0) return;

      final tokensToVoid = localUnserved.take(confirmQty).toList();
      final voidIds = tokensToVoid
          .map((t) => t['id']?.toString() ?? t['localId']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toList();
      final Map<String, int> sessionCounts = {};

      for (final t in tokensToVoid) {
        final s = _kitchenNormalizeSession(t['session'] as String?);
        sessionCounts[s] = (sessionCounts[s] ?? 0) + 1;
      }

      // ── STEP 1: Delete from Local Hive First ─────────────────────────
      try {
        final box = await LocalStorageService.openBoxSafe(LocalStorageService.dasterkhwaanTokensBox);
        for (final tid in voidIds) {
          await box.delete(tid);
        }
      } catch (_) {}

      // Short, unique id (joining every token id made keys longer than Hive's 255-char limit).
      final revBatchId = 'dst_rev_${_branchId}_${today}_${DateTime.now().millisecondsSinceEpoch}_${voidIds.length}';

      // ── STEP 2: Send over LAN (if connected) ────────────────────────
      final isLanConnected = RealtimeManager().isConnected;
      if (isLanConnected) {
        try {
          RealtimeManager().sendMessage(
            RealtimeEvents.payload(
              type: RealtimeEvents.saveOfficeBoyToken,
              data: {
                'action': 'reverse',
                'branchId': _branchId,
                'dateKey': today,
                'quantity': confirmQty,
                'tokenIds': voidIds,
                'sessionCounts': sessionCounts,
                'timestamp': DateTime.now().toIso8601String(),
                'batchId': revBatchId,
              },
            ),
          );
        } catch (_) {}
      }

      // ── STEP 3: Reverse in the cloud through the queue ──────────────────
      // Tokens still waiting in this PC's queue are taken out of it; only the rest get a cloud
      // reversal (same as the Office Boy screen).
      try {
        final withdrawn = await SyncService.withdrawQueuedFoodTokens(voidIds);
        final cloudIds = voidIds.where((id) => !withdrawn.contains(id)).toList();
        if (cloudIds.isNotEmpty) {
          final cloudSessionCounts = <String, int>{};
          for (final t in tokensToVoid) {
            final id = t['id']?.toString() ?? t['localId']?.toString() ?? '';
            if (!cloudIds.contains(id)) continue;
            final s = _kitchenNormalizeSession(t['session'] as String?);
            cloudSessionCounts[s] = (cloudSessionCounts[s] ?? 0) + 1;
          }
          await LocalStorageService.enqueueSync({
            'type': 'reverse_dasterkhwan_tokens',
            'entityId': revBatchId,
            'batchId': revBatchId,
            'branchId': _branchId,
            'dateKey': today,
            'data': {
              'branchId': _branchId,
              'dateKey': today,
              'quantity': cloudIds.length,
              'tokenIds': cloudIds,
              'sessionCounts': cloudSessionCounts,
              'batchId': revBatchId,
            },
          });
          SyncService().triggerUpload(urgent: true);
        }
      } catch (e) {
        debugPrint('[Kitchen] Sync reverse enqueue error: $e');
      }

      if (!mounted) return;
      _recalculateLocalStats();
      _showSnack('$confirmQty Token${confirmQty != 1 ? "s" : ""} Voided & Reversed');
      setState(() {});
    } finally {
      _isReversing = false;
    }
  }

  Future<void> _serveToken(String tokenId, int tokenNumber, {String session = 'lunch'}) async {
    final cleanSession = _kitchenNormalizeSession(session);
    HapticFeedback.mediumImpact();

    // 1. Update local Hive box immediately (zero UI lag, works offline)
    try {
      final box = await LocalStorageService.openBoxSafe(LocalStorageService.dasterkhwaanTokensBox);
      final localItem = box.get(tokenId);
      if (localItem is Map) {
        final updated = Map<String, dynamic>.from(localItem);
        updated['served'] = true;
        updated['servedTime'] = DateTime.now().toIso8601String();
        await box.put(tokenId, updated);
      }
    } catch (e) {
      debugPrint('[Kitchen] Local serve token write error: $e');
    }

    _recalculateLocalStats();

    // 2. Direct Cloud Write if online, fallback to sync queue if offline
    bool directServeSucceeded = false;
    try {
      if (_branchId != null && _branchId!.isNotEmpty && LocalStorageService.isValidBranchId(_branchId)) {
        final batch = FirebaseFirestore.instance.batch();
        batch.set(_tokensCol(today).doc(tokenId), {
          'served': true,
          'servedTime': FieldValue.serverTimestamp(),
          'servedBy': _username,
        }, SetOptions(merge: true));

        batch.set(_dayDoc(today), {
          'servedTokens': FieldValue.increment(1),
          'session_${cleanSession}_served': FieldValue.increment(1),
          'servedTokenIds': FieldValue.arrayUnion([tokenId]),
          'lastUpdated': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        await batch.commit().timeout(const Duration(seconds: 5));
        directServeSucceeded = true;
        debugPrint('[Kitchen] ✅ Direct Firestore serve write succeeded for token $tokenId');
      }
    } catch (e) {
      debugPrint('[Kitchen] Direct serve write failed/offline ($e) -> Falling back to sync queue');
    }

    if (!directServeSucceeded) {
      try {
        final ts = DateTime.now().toIso8601String();
        await LocalStorageService.enqueueSync({
          'type': 'serve_dasterkhwan_token',
          'entityId': 'serve_$tokenId',
          'branchId': _branchId,
          'dateKey': today,
          'data': {
            'branchId': _branchId,
            'dateKey': today,
            'tokenId': tokenId,
            'tokenNumber': tokenNumber,
            'session': cleanSession,
            'servedBy': _username,
            'timestamp': ts,
          },
        });
        SyncService().triggerUpload();
      } catch (e) {
        debugPrint('[Kitchen] Serve enqueue error: $e');
      }
    }

    // 3. Tell the LAN so other PCs show the token as served.
    final isLanConnected = RealtimeManager().isConnected;
    if (isLanConnected) {
      try {
        RealtimeManager().sendMessage(
          RealtimeEvents.payload(
            type: RealtimeEvents.saveKitchenServeLog,
            data: {
              'branchId': _branchId,
              'dateKey': today,
              'tokenId': tokenId,
              'tokenNumber': tokenNumber,
              'session': cleanSession,
              'servedBy': _username,
              'timestamp': DateTime.now().toIso8601String(),
            },
          ),
        );
      } catch (e) {
        debugPrint('[Kitchen] Realtime LAN broadcast error: $e');
      }
    }

    if (mounted) {
      AppToast.showSnackBar(context, SnackBar(
        content: Text('Token #$tokenNumber served ✓'),
        backgroundColor: SoftPalette.emerald500,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12)),
      ));
    }
  }

  Future<void> _deleteCookSession(
      String docId, Map<String, dynamic> data) async {
    final isReceived  = data['isReceivedFood'] as bool? ?? false;
    final isSavedFood = data['isSavedFood']    as bool? ?? false;
    final batch       = CloudDb.instance.batch();

    // Only restore stock for cooked-in-house sessions
    if (!isReceived && !isSavedFood) {
      final ingredients = List<Map<String, dynamic>>.from(
          (data['ingredients'] as List<dynamic>? ?? [])
              .map((e) => Map<String, dynamic>.from(e as Map)));
      for (final ing in ingredients) {
        batch.update(
          FirebaseFirestore.instance
              .collection('branches')
              .doc(_branchId)
              .collection('dasterkhwaan_stock')
              .doc(ing['name'] as String),
          {
            'quantity':    FieldValue.increment((ing['qty'] as num).toDouble()),
            'lastUpdated': FieldValue.serverTimestamp(),
          },
        );
      }
    }

    batch.delete(_cookingCol(today).doc(docId));
    if (!await commitKitchenBatch(context, batch)) return;
    await _loadAllStockItems();

    if (mounted) {
      AppToast.showSnackBar(context, SnackBar(
        content: Text(isSavedFood
            ? 'Saved food entry deleted'
            : isReceived
                ? 'Entry deleted'
                : 'Cooking session deleted — stock restored'),
        backgroundColor: kSuccess,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ));
    }
  }

  Future<void> _logout() async {
    try {
      await AuthService().signOut();
    } catch (e) {
      debugPrint('[DasterkhwaanKitchen] Sign out error: $e');
    }
    if (mounted) {
      Navigator.pushNamedAndRemoveUntil(context, '/login', (_) => false);
    }
  }

  void _openSettings() {
    final uData = LocalStorageService.getActiveUserData();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsPage(userData: Map<String, dynamic>.from(uData)),
      ),
    ).then((_) {
      final refreshed = LocalStorageService.getActiveUserData();
      if (refreshed['name'] != null || refreshed['username'] != null) {
        setState(() {
          _username = refreshed['name'] as String? ?? refreshed['username'] as String? ?? _username;
        });
      }
    });
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_branchId == null) {
      return Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [SoftPalette.slate900, SoftPalette.slate800, SoftPalette.slate900],
            ),
          ),
          child: Center(
            child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: SoftPalette.gray50.withValues(alpha: 0.05),
                  shape: BoxShape.circle,
                  border:
                      Border.all(color: SoftPalette.gray50.withValues(alpha: 0.1)),
                ),
                child: const CircularProgressIndicator(
                    color: kWarning, strokeWidth: 3),
              ),
              const SizedBox(height: 32),
              Text('Loading Kitchen Panel…',
                  style: TextStyle(
                      color: SoftPalette.gray50.withValues(alpha: 0.9),
                      fontSize: 18,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text('Preparing your workspace',
                  style: TextStyle(
                      color: SoftPalette.gray50.withValues(alpha: 0.5),
                      fontSize: 13)),
            ]),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: context.adapt(kSurface),
      body: LazyIndexedStack(
        index: _currentNav,
        children: [
          _KitchenIssueTokenTab(
            userName: _username,
            branchId: _branchId,
            today: today,
            displayFormat: _displayFmt,
            quantityController: _qtyCtrl,
            pricePerToken: _pricePerToken,
            selectedSession: _selectedSession,
            onSessionChanged: (s) => setState(() => _selectedSession = s),
            onGenerate: _generateTokens,
            onReverse: _showReverseTokensDialog,
            pulseAnim: _pulseAnim,
            todayStats: _stats,
            onLogout: _logout,
            onSettings: _openSettings,
            showLogout: !GlobalModuleWrapper.isWrapped(context),
            onSelectQty: (q) => setState(() => _qtyCtrl.text = q.toString()),
            onGoToServeQueue: () => setState(() => _currentNav = 1),
          ),
          _KitchenServeQueueTab(
            branchId: _branchId!,
            today: today,
            tokensCol: _tokensCol(today),
            serveToken: _serveToken,
            username: _username,
            onLogout: _logout,
            onSettings: _openSettings,
            onGoToIssueToken: () => setState(() => _currentNav = 0),
          ),
          _HistoryTab(
            branchId: _branchId!,
            dateFmt: _dateFmt,
            displayFmt: _displayFmt,
            username: _username,
            onLogout: _logout,
            onSettings: _openSettings,
          ),
        ],
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  Widget _buildBottomNav() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final items = [
      _NavItem(Icons.confirmation_number_rounded, 'Issue Token', SoftPalette.teal500),
      _NavItem(Icons.restaurant_rounded,          'Serve Queue', SoftPalette.emerald500),
      _NavItem(Icons.history_rounded,             'History',     SoftPalette.violet550),
    ];
    return Container(
      decoration: BoxDecoration(
        color: _DS.getSurface(isDark),
        border: Border(top: BorderSide(color: _DS.getBorder(isDark), width: 1)),
        boxShadow: [
          BoxShadow(
            color: SoftPalette.gray900.withValues(alpha: isDark ? 0.3 : 0.06),
            blurRadius: 16,
            offset: const Offset(0, -4),
          )
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: List.generate(items.length, (idx) {
              final item     = items[idx];
              final selected = _currentNav == idx;
              return GestureDetector(
                onTap: () {
                  setState(() => _currentNav = idx);
                  HapticFeedback.selectionClick();
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: selected
                        ? item.color.withValues(alpha: isDark ? 0.22 : 0.12)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(item.icon,
                          color: selected ? item.color : _DS.getInk3(isDark),
                          size: 22),
                      if (selected) ...[
                        const SizedBox(width: 8),
                        Text(
                          item.label,
                          style: GoogleFonts.inter(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            color: item.color,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final String label;
  final Color color;
  const _NavItem(this.icon, this.label, this.color);
}

class _SectionLabel extends StatelessWidget {
  final String text;
  final bool isDark;

  const _SectionLabel(this.text, {this.isDark = false});

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: GoogleFonts.inter(
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.2,
          color: isDark ? SoftPalette.slate350 : _DS.ink3,
        ),
      );
}

// ─── Reverse Button ──────────────────────────────────────────────────────────

class _ReverseButton extends StatelessWidget {
  final double pricePerToken;
  final VoidCallback onPressed;
  final bool isDark;

  const _ReverseButton({
    required this.pricePerToken,
    required this.onPressed,
    this.isDark = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: 50,
      decoration: BoxDecoration(
        color: isDark ? _DS.red.withValues(alpha: 0.15) : _DS.redBg,
        borderRadius: BorderRadius.circular(_DS.r22),
        border: Border.all(color: _DS.red.withValues(alpha: isDark ? 0.35 : 0.25), width: 1),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(_DS.r22),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.undo_rounded, size: 17, color: isDark ? SoftPalette.red350 : _DS.red),
                const SizedBox(width: 8),
                Text(
                  'Reverse / Void Issued Tokens',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: isDark ? SoftPalette.red350 : _DS.red,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// KITCHEN ISSUE TOKEN TAB
// ═══════════════════════════════════════════════════════════════════════════

class _KitchenIssueTokenTab extends StatefulWidget {
  final String userName;
  final String? branchId;
  final String today;
  final DateFormat displayFormat;
  final TextEditingController quantityController;
  final double pricePerToken;
  final String selectedSession;
  final ValueChanged<String> onSessionChanged;
  final VoidCallback onGenerate;
  final VoidCallback onReverse;
  final Animation<double> pulseAnim;
  final Map<String, dynamic> todayStats;
  final VoidCallback onLogout;
  final VoidCallback onSettings;
  final bool showLogout;
  final Function(int) onSelectQty;
  final VoidCallback onGoToServeQueue;

  const _KitchenIssueTokenTab({
    required this.userName,
    this.branchId,
    required this.today,
    required this.displayFormat,
    required this.quantityController,
    required this.pricePerToken,
    required this.selectedSession,
    required this.onSessionChanged,
    required this.onGenerate,
    required this.onReverse,
    required this.pulseAnim,
    required this.todayStats,
    required this.onLogout,
    required this.onSettings,
    required this.showLogout,
    required this.onSelectQty,
    required this.onGoToServeQueue,
  });

  @override
  State<_KitchenIssueTokenTab> createState() => _KitchenIssueTokenTabState();
}

class _KitchenIssueTokenTabState extends State<_KitchenIssueTokenTab> {
  String _feedFilter = 'all';
  late Future<Box> _tokensBoxFuture;

  @override
  void initState() {
    super.initState();
    _tokensBoxFuture = LocalStorageService.openBoxSafe(LocalStorageService.dasterkhwaanTokensBox);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final qty = int.tryParse(widget.quantityController.text) ?? 1;
    final currentKey = _kitchenNormalizeSession(widget.selectedSession);
    final meta = _kitchenSessionMeta[currentKey] ?? _kitchenSessionMeta['dinner']!;
    final sessionColor = meta.color;

    final total = widget.todayStats['total'] as int? ?? 0;
    final nextStart = total + 1;

    return Column(
      children: [
        // ── Top Header with Session Switcher & Analytics ──
        _buildHeader(context),

        // ── Scrollable Body ──
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 36),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 1. Tactile Meal Voucher Preview
                _buildVoucherPreview(
                  nextStart: nextStart,
                  qty: qty,
                  sessionKey: currentKey,
                  meta: meta,
                ),
                const SizedBox(height: 20),

                // 2. Quantity Selection
                _buildQuantitySection(context, qty),
                const SizedBox(height: 22),

                // 3. Grand Issue Button
                ScaleTransition(
                  scale: widget.pulseAnim,
                  child: Container(
                    width: double.infinity,
                    height: 62,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: meta.gradient,
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(_DS.r22),
                      boxShadow: [
                        BoxShadow(
                          color: sessionColor.withValues(alpha: 0.35),
                          blurRadius: 18,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(_DS.r22),
                        onTap: widget.onGenerate,
                        splashColor: SoftPalette.gray50.withValues(alpha: 0.15),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                width: 34,
                                height: 34,
                                decoration: BoxDecoration(
                                  color: SoftPalette.gray50.withValues(alpha: 0.18),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  meta.icon,
                                  size: 18,
                                  color: SoftPalette.gray50,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Issue $qty ${meta.shortTitle} Token${qty > 1 ? "s" : ""}',
                                      style: GoogleFonts.inter(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
                                        color: SoftPalette.gray50,
                                        letterSpacing: -0.2,
                                      ),
                                    ),
                                    Text(
                                      'PKR ${(qty * widget.pricePerToken).toStringAsFixed(0)} · ${_kitchenSessionUrdu(widget.selectedSession)}',
                                      style: GoogleFonts.inter(
                                        fontSize: 11,
                                        color: SoftPalette.gray50.withValues(alpha: 0.85),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const Icon(Icons.arrow_forward_rounded, color: SoftPalette.gray50, size: 20),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // 4. Reverse Tokens Button
                _ReverseButton(
                  pricePerToken: widget.pricePerToken,
                  onPressed: widget.onReverse,
                  isDark: isDark,
                ),
                const SizedBox(height: 14),

                // 5. Serve Queue Shortcut Banner
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: _DS.getSurface(isDark),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: _DS.mint.withValues(alpha: 0.35)),
                  ),
                  child: InkWell(
                    onTap: widget.onGoToServeQueue,
                    borderRadius: BorderRadius.circular(12),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: _DS.mint.withValues(alpha: isDark ? 0.2 : 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(Icons.restaurant_rounded, color: _DS.mint, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Ready to distribute food?',
                                style: GoogleFonts.inter(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: _DS.getInk(isDark),
                                ),
                              ),
                              Text(
                                'Open Serve Queue to mark meals as served',
                                style: GoogleFonts.inter(
                                  fontSize: 11,
                                  color: _DS.getInk3(isDark),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.arrow_forward_ios_rounded, color: _DS.mint, size: 14),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // 6. Live Feed of Today's Tokens
                _buildLiveTokensFeed(context),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── Header Component ───────────────────────────────────────────────────────
  Widget _buildHeader(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final conf = CampSessionService.getDasterkhwaanSessionConfig(widget.branchId);
    final availableSessions = ['breakfast', 'lunch', 'dinner']
        .where((s) => conf.containsKey(s) && (conf[s] is Map && (conf[s] as Map)['enabled'] == true))
        .toList();

    final sessionsToRender = availableSessions.isNotEmpty
        ? availableSessions
        : ['breakfast', 'lunch', 'dinner'];

    final total = widget.todayStats['total'] as int? ?? 0;
    final served = widget.todayStats['served'] as int? ?? 0;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? const [SoftPalette.teal800m, SoftPalette.teal750m, SoftPalette.teal800]
              : const [SoftPalette.teal800, SoftPalette.teal700m, SoftPalette.teal750m],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: -30,
            right: -20,
            child: Container(
              width: 140,
              height: 140,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _DS.mint.withValues(alpha: 0.08),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top Row: Logo, User, Title & Price Tag
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (Navigator.canPop(context) && !HomeModuleHost.isModuleRoot(context)) ...[
                      IconButton(
                        icon: const Icon(Icons.arrow_back_rounded, color: SoftPalette.gray50, size: 20),
                        onPressed: () => Navigator.maybePop(context),
                      ),
                      const SizedBox(width: 4),
                    ],
                    Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: SoftPalette.gray50.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(7),
                        child: Image.asset(
                          'assets/logo/gmwf-1.webp',
                          width: 38,
                          height: 38,
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.restaurant_rounded,
                            color: SoftPalette.gray50A70,
                            size: 24,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    _UserAvatar(userName: widget.userName, onTap: widget.onSettings),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  'Food Tokens',
                                  style: GoogleFonts.dmSerifDisplay(
                                    color: SoftPalette.gray50,
                                    fontSize: 21,
                                    letterSpacing: -0.3,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                  color: _DS.mint.withValues(alpha: 0.18),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Text(
                                  'طعام لنگر',
                                  style: TextStyle(
                                    color: _DS.mint,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Meal Distribution · ${widget.displayFormat.format(DateTime.now())}',
                            style: GoogleFonts.inter(
                              color: SoftPalette.gray50.withValues(alpha: 0.65),
                              fontSize: 11,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                      decoration: BoxDecoration(
                        color: SoftPalette.gray50.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: SoftPalette.gray50.withValues(alpha: 0.18)),
                      ),
                      child: Text(
                        'PKR ${widget.pricePerToken.toInt()} / token',
                        style: GoogleFonts.inter(
                          color: SoftPalette.cyan200,
                          fontWeight: FontWeight.w700,
                          fontSize: 11.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _settingsBtn(widget.onSettings),
                  ],
                ),
                const SizedBox(height: 14),

                // Dynamic Meal Sessions Segmented Switcher
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: SoftPalette.gray900.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: SoftPalette.gray50.withValues(alpha: 0.1)),
                  ),
                  child: Row(
                    children: sessionsToRender.map((sKey) {
                      final meta = _kitchenSessionMeta[sKey] ?? _kitchenSessionMeta['dinner']!;

                      return Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: _buildSessionTab(
                            id: sKey,
                            title: meta.shortTitle,
                            timingSubtitle: meta.urdu.replaceAll(' کا دسترخوان', ''),
                            icon: meta.icon,
                            activeGradient: meta.gradient,
                            activeShadow: meta.color,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 14),

                // Multi-Session Analytics Strip
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: SoftPalette.gray50.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: SoftPalette.gray50.withValues(alpha: 0.12),
                      width: 0.8,
                    ),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          for (int idx = 0; idx < sessionsToRender.length; idx++) ...[
                            if (idx > 0)
                              Container(
                                width: 1,
                                height: 36,
                                color: SoftPalette.gray50.withValues(alpha: 0.15),
                              ),
                            Expanded(
                              child: Builder(
                                builder: (_) {
                                  final sKey = sessionsToRender[idx];
                                  final sTotal = widget.todayStats['${sKey}Total'] ?? 0;
                                  final sServed = widget.todayStats['${sKey}Served'] ?? 0;
                                  final meta = _kitchenSessionMeta[sKey] ?? _kitchenSessionMeta['dinner']!;
                                  return _buildSessionStatColumn(
                                    title: meta.shortTitle,
                                    total: sTotal,
                                    served: sServed,
                                    accentColor: meta.color,
                                  );
                                },
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 8),
                      Divider(color: SoftPalette.gray50.withValues(alpha: 0.1), height: 1),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.receipt_long_rounded,
                                  size: 13, color: SoftPalette.cyan200),
                              const SizedBox(width: 5),
                              Text(
                                'Combined: $total Issued · ${total - served} Pending',
                                style: GoogleFonts.inter(
                                  fontSize: 11,
                                  color: SoftPalette.gray50.withValues(alpha: 0.75),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                          Text(
                            'PKR ${(total * widget.pricePerToken).toStringAsFixed(0)}',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: SoftPalette.emerald150,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionTab({
    required String id,
    required String title,
    String? timingSubtitle,
    required IconData icon,
    required List<Color> activeGradient,
    required Color activeShadow,
  }) {
    final active = _kitchenNormalizeSession(widget.selectedSession) == id.toLowerCase();
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        widget.onSessionChanged(id);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        decoration: BoxDecoration(
          gradient: active ? LinearGradient(colors: activeGradient) : null,
          color: active ? null : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: activeShadow.withValues(alpha: 0.4),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ]
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 14,
                  color: active ? SoftPalette.gray50 : SoftPalette.gray50.withValues(alpha: 0.6),
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    title,
                    style: GoogleFonts.inter(
                      fontSize: 11.5,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                      color: active ? SoftPalette.gray50 : SoftPalette.gray50.withValues(alpha: 0.7),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (timingSubtitle != null && timingSubtitle.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                timingSubtitle,
                style: GoogleFonts.inter(
                  fontSize: 9.5,
                  fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                  color: active ? SoftPalette.gray50.withValues(alpha: 0.9) : SoftPalette.gray50.withValues(alpha: 0.45),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSessionStatColumn({
    required String title,
    required int total,
    required int served,
    required Color accentColor,
  }) {
    final pending = total - served;
    return Column(
      children: [
        Text(
          title,
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: accentColor,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 3),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '$total',
              style: GoogleFonts.inter(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: SoftPalette.gray50,
              ),
            ),
            const SizedBox(width: 3),
            Text(
              'issued',
              style: GoogleFonts.inter(
                fontSize: 9.5,
                color: SoftPalette.gray50.withValues(alpha: 0.4),
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: SoftPalette.amber200.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '$pending wait',
                style: GoogleFonts.inter(
                  fontSize: 8.5,
                  fontWeight: FontWeight.w700,
                  color: SoftPalette.yellow200,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ── Tactile Meal Voucher Preview ──────────────────────────────────────────
  Widget _buildVoucherPreview({
    required int nextStart,
    required int qty,
    required String sessionKey,
    required ({String title, String shortTitle, String urdu, IconData icon, Color color, Color bg, List<Color> gradient}) meta,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final endNum = nextStart + qty - 1;
    final rangeText = qty == 1 ? 'Token #$nextStart' : 'Tokens #$nextStart → #$endNum';
    final totalPKR = (qty * widget.pricePerToken).toStringAsFixed(0);

    return Container(
      decoration: BoxDecoration(
        color: _DS.getSurface(isDark),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: meta.color.withValues(alpha: isDark ? 0.12 : 0.05),
            blurRadius: 14,
            offset: const Offset(0, 3),
          ),
        ],
        border: Border.all(color: _DS.getBorder(isDark), width: 1),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(
                        color: isDark ? meta.color.withValues(alpha: 0.18) : meta.bg,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Icon(meta.icon, size: 14, color: meta.color),
                    ),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'DASTERKHWAAN MEAL VOUCHER',
                          style: GoogleFonts.inter(
                            fontSize: 8.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.6,
                            color: _DS.getInk3(isDark),
                          ),
                        ),
                        Text(
                          '${meta.shortTitle} Session · ${_kitchenSessionUrdu(sessionKey)}',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: _DS.getInk(isDark),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: isDark ? meta.color.withValues(alpha: 0.15) : meta.bg,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: meta.color.withValues(alpha: 0.25)),
                  ),
                  child: Text(
                    meta.shortTitle.toUpperCase(),
                    style: GoogleFonts.inter(
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      color: meta.color,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
              ],
            ),
          ),

          Divider(color: _DS.getBorder(isDark), height: 1, thickness: 0.8),

          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'NEXT IN QUEUE',
                      style: GoogleFonts.inter(
                        fontSize: 8.5,
                        fontWeight: FontWeight.w700,
                        color: _DS.getInk3(isDark),
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      rangeText,
                      style: GoogleFonts.inter(
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                        color: _DS.getInk(isDark),
                        letterSpacing: -0.3,
                      ),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: isDark ? _DS.mint.withValues(alpha: 0.15) : _DS.mintBg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _DS.mint.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '$qty Meal${qty > 1 ? "s" : ""} · ',
                        style: GoogleFonts.inter(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: isDark ? _DS.mint : _DS.sage,
                        ),
                      ),
                      Text(
                        'PKR $totalPKR',
                        style: GoogleFonts.inter(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: isDark ? _DS.mint : _DS.sage,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Quantity Section ───────────────────────────────────────────────────────
  Widget _buildQuantitySection(BuildContext context, int currentQty) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _SectionLabel('Token Quantity', isDark: isDark),
            Text(
              '= PKR ${(currentQty * widget.pricePerToken).toStringAsFixed(0)}',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: _DS.mint,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),

        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: _DS.getSurface(isDark),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _DS.getBorder(isDark)),
            boxShadow: [
              BoxShadow(
                color: SoftPalette.gray900.withValues(alpha: isDark ? 0.2 : 0.02),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              GestureDetector(
                onTap: () {
                  if (currentQty > 1) {
                    HapticFeedback.selectionClick();
                    widget.onSelectQty(currentQty - 1);
                  }
                },
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: currentQty > 1 ? _DS.getSurface2(isDark) : _DS.getSurface2(isDark).withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.remove_rounded,
                    color: currentQty > 1 ? _DS.getInk2(isDark) : _DS.getInk3(isDark).withValues(alpha: 0.4),
                    size: 22,
                  ),
                ),
              ),
              Column(
                children: [
                  Text(
                    '$currentQty',
                    style: GoogleFonts.inter(
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      color: _DS.getInk(isDark),
                      letterSpacing: -1,
                    ),
                  ),
                  Text(
                    '${currentQty == 1 ? "1 Meal" : "$currentQty Meals"} · PKR ${(currentQty * widget.pricePerToken).toStringAsFixed(0)}',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: _DS.mint,
                    ),
                  ),
                ],
              ),
              GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  widget.onSelectQty(currentQty + 1);
                },
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: _DS.mint.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.add_rounded,
                    color: _DS.mint,
                    size: 22,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: Row(
            children: [1, 2, 3, 5, 10, 20, 50].map((preset) {
              final selected = currentQty == preset;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    widget.onSelectQty(preset);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: selected
                          ? (isDark ? _DS.mint : _DS.sage)
                          : _DS.getSurface(isDark),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: selected
                            ? (isDark ? _DS.mint : _DS.sage)
                            : _DS.getBorder(isDark),
                        width: selected ? 1.5 : 1,
                      ),
                      boxShadow: selected
                          ? [
                              BoxShadow(
                                color: (isDark ? _DS.mint : _DS.sage).withValues(alpha: 0.25),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              )
                            ]
                          : null,
                    ),
                    child: Text(
                      '$preset',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: selected ? (isDark ? SoftPalette.slate900 : SoftPalette.gray50) : _DS.getInk(isDark),
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 12),

        Container(
          decoration: BoxDecoration(
            color: _DS.getSurface(isDark),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _DS.getBorder(isDark)),
          ),
          child: TextField(
            controller: widget.quantityController,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (_) => setState(() {}),
            style: GoogleFonts.inter(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: _DS.getInk(isDark),
            ),
            decoration: InputDecoration(
              prefixIcon: Icon(Icons.dialpad_rounded, color: _DS.getInk3(isDark), size: 20),
              suffixText: '= PKR ${(currentQty * widget.pricePerToken).toStringAsFixed(0)}',
              suffixStyle: GoogleFonts.inter(
                color: _DS.mint,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
              hintText: 'Enter custom token quantity…',
              hintStyle: GoogleFonts.inter(fontSize: 13, color: _DS.getInk3(isDark)),
              filled: true,
              fillColor: _DS.getSurface(isDark),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            ),
          ),
        ),
      ],
    );
  }

  // ── Live Recent Tokens Feed ────────────────────────────────────────────────
  Widget _buildLiveTokensFeed(BuildContext context) {
    if (widget.branchId == null) return const SizedBox.shrink();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final conf = CampSessionService.getDasterkhwaanSessionConfig(widget.branchId);
    final availableSessions = ['breakfast', 'lunch', 'dinner']
        .where((s) => conf.containsKey(s) && (conf[s] is Map && (conf[s] as Map)['enabled'] == true))
        .toList();

    final sessionsToRender = availableSessions.isNotEmpty
        ? availableSessions
        : ['breakfast', 'lunch', 'dinner'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SectionLabel("Today's Issued Tokens", isDark: isDark),
                const SizedBox(height: 2),
                Text(
                  'Live feed of meal tickets for today',
                  style: GoogleFonts.inter(fontSize: 11, color: _DS.getInk3(isDark)),
                ),
              ],
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: [
                  _filterChip('all', 'All', isDark),
                  ...sessionsToRender.map((sKey) {
                    final meta = _kitchenSessionMeta[sKey] ?? _kitchenSessionMeta['dinner']!;
                    return Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: _filterChip(sKey, meta.shortTitle, isDark),
                    );
                  }),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        FutureBuilder<Box>(
          future: Hive.isBoxOpen(LocalStorageService.dasterkhwaanTokensBox)
              ? Future.value(Hive.box(LocalStorageService.dasterkhwaanTokensBox))
              : _tokensBoxFuture,
          builder: (context, boxSnap) {
            if (!boxSnap.hasData) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            }
            final box = boxSnap.data!;
            return ValueListenableBuilder(
              valueListenable: DebouncedBoxListenable.shared(box),
              builder: (ctx, Box box, _) {
                final List<Map<String, dynamic>> tokenList = [];
                final Set<int> seenTokenNumbers = {};
                // Filter on the raw record first; copy only today's tokens (the box holds every day and branch).
                for (final raw in box.values) {
                  if (raw is Map && raw['dateKey'] == widget.today && raw['branchId'] == widget.branchId) {
                    final t = Map<String, dynamic>.from(raw);
                    {
                      final tokenNum = (t['number'] as num?)?.toInt() ?? 0;
                      if (tokenNum > 0 && !seenTokenNumbers.add(tokenNum)) continue;
                      final rawSession = _kitchenNormalizeSession(t['session'] as String?);
                      DateTime? tTime;
                      if (t['time'] is String) {
                        tTime = DateTime.tryParse(t['time']);
                      } else if (t['timestamp'] is String) {
                        tTime = DateTime.tryParse(t['timestamp']);
                      }
                      tokenList.add({
                        'id': t['id'] ?? t['localId'] ?? '',
                        'number': (t['number'] as num?)?.toInt() ?? 0,
                        'served': t['served'] == true,
                        'session': rawSession,
                        'time': tTime,
                      });
                    }
                  }
                }

                var filtered = tokenList;
                if (_feedFilter != 'all') {
                  filtered = filtered.where((t) => t['session'] == _feedFilter).toList();
                }

                filtered.sort((a, b) => (b['number'] as int).compareTo(a['number'] as int));

                if (filtered.isEmpty) {
                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
                    decoration: BoxDecoration(
                      color: _DS.getSurface(isDark),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: _DS.getBorder(isDark)),
                    ),
                    child: Column(
                      children: [
                        Icon(Icons.confirmation_number_outlined,
                            size: 40, color: _DS.getInk3(isDark).withValues(alpha: 0.3)),
                        const SizedBox(height: 8),
                        Text(
                          'No tokens issued today yet',
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: _DS.getInk(isDark),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Select session and quantity above to issue tickets',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            color: _DS.getInk3(isDark),
                          ),
                        ),
                      ],
                    ),
                  );
                }

                final displayList = filtered.take(20).toList();

                return ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: displayList.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, idx) {
                    final item = displayList[idx];
                    final number = item['number'] as int;
                    final served = item['served'] as bool;
                    final session = item['session'] as String;
                    final time = item['time'] as DateTime?;
                    final meta = _kitchenSessionMeta[session] ?? _kitchenSessionMeta['dinner']!;

                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: _DS.getSurface(isDark),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: _DS.getBorder(isDark)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 44,
                            height: 40,
                            decoration: BoxDecoration(
                              color: isDark ? meta.color.withValues(alpha: 0.18) : meta.bg,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: meta.color.withValues(alpha: 0.3),
                              ),
                            ),
                            child: Center(
                              child: Text(
                                '#$number',
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                  color: meta.color,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      meta.icon,
                                      size: 13,
                                      color: meta.color,
                                    ),
                                    const SizedBox(width: 5),
                                    Expanded(
                                      child: Text(
                                        '${meta.shortTitle} Session',
                                        style: GoogleFonts.inter(
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w700,
                                          color: _DS.getInk(isDark),
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${time != null ? DateFormat('hh:mm a').format(time) : 'Today'} · ${_kitchenSessionUrdu(session)}',
                                  style: GoogleFonts.inter(
                                    fontSize: 10.5,
                                    color: _DS.getInk3(isDark),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: served
                                  ? (isDark ? _DS.green.withValues(alpha: 0.2) : _DS.greenBg)
                                  : (isDark ? _DS.amber.withValues(alpha: 0.2) : _DS.amberBg),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: served ? _DS.green.withValues(alpha: 0.3) : _DS.amber.withValues(alpha: 0.3),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  served ? Icons.check_circle_rounded : Icons.hourglass_top_rounded,
                                  size: 12,
                                  color: served ? _DS.green : _DS.amber,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  served ? 'Served' : 'Waiting',
                                  style: GoogleFonts.inter(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: served ? _DS.green : _DS.amber,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            );
          },
        ),
      ],
    );
  }

  Widget _filterChip(String filterKey, String label, bool isDark) {
    final sel = _feedFilter == filterKey;
    return GestureDetector(
      onTap: () => setState(() => _feedFilter = filterKey),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: sel ? (isDark ? _DS.mint : _DS.sage) : _DS.getSurface2(isDark),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: sel ? (isDark ? SoftPalette.slate900 : SoftPalette.gray50) : _DS.getInk3(isDark),
          ),
        ),
      ),
    );
  }
}


// ═══════════════════════════════════════════════════════════════════════════
// COOKING TAB
// ═══════════════════════════════════════════════════════════════════════════

class _KitchenServeQueueTab extends StatefulWidget {
  final String branchId, today, username;
  final CollectionReference<Map<String, dynamic>> tokensCol;
  final Function(String, int, {String session}) serveToken;
  final VoidCallback onLogout;
  final VoidCallback onSettings;
  final VoidCallback onGoToIssueToken;

  const _KitchenServeQueueTab({
    required this.branchId,
    required this.today,
    required this.tokensCol,
    required this.serveToken,
    required this.username,
    required this.onLogout,
    required this.onSettings,
    required this.onGoToIssueToken,
  });

  @override
  State<_KitchenServeQueueTab> createState() => _KitchenServeQueueTabState();
}

class _KitchenServeQueueTabState extends State<_KitchenServeQueueTab> {
  String _selectedSessionFilter = 'all';
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    final active = CampSessionService.resolveDasterkhwaanSession(null, widget.branchId);
    _selectedSessionFilter = _kitchenNormalizeSession(active);
    _ensureBox();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _ensureBox() async {
    if (!Hive.isBoxOpen(LocalStorageService.dasterkhwaanTokensBox)) {
      await LocalStorageService.openBoxSafe(LocalStorageService.dasterkhwaanTokensBox);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      children: [
        // ── Grand Kitchen Header with Live Analytics & Shortcut ──
        _buildHeader(context),

        // ── Controls Strip: Search & Session Filter Chips ──
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: _DS.getSurface(isDark),
            border: Border(bottom: BorderSide(color: _DS.getBorder(isDark), width: 1)),
          ),
          child: Column(
            children: [
              // Search Field
              Container(
                height: 42,
                decoration: BoxDecoration(
                  color: _DS.getSurface2(isDark),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _DS.getBorder(isDark)),
                ),
                child: TextField(
                  controller: _searchCtrl,
                  keyboardType: TextInputType.number,
                  onChanged: (val) => setState(() => _searchQuery = val.trim()),
                  style: GoogleFonts.inter(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: _DS.getInk(isDark),
                  ),
                  decoration: InputDecoration(
                    prefixIcon: Icon(Icons.search_rounded, size: 18, color: _DS.getInk3(isDark)),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear_rounded, size: 16),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() => _searchQuery = '');
                            },
                          )
                        : null,
                    hintText: 'Search token number (e.g. 15)...',
                    hintStyle: GoogleFonts.inter(fontSize: 12.5, color: _DS.getInk3(isDark)),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // ValueListenable for dynamic counts inside filter chips
              if (Hive.isBoxOpen(LocalStorageService.dasterkhwaanTokensBox))
                ValueListenableBuilder<Box>(
                  valueListenable: DebouncedBoxListenable.shared(Hive.box(LocalStorageService.dasterkhwaanTokensBox)),
                  builder: (_, box, __) {
                    int unservedCount = 0;
                    int bfCount = 0;
                    int lunchCount = 0;
                    int dinCount = 0;

                    // Counting only: read the records in place, no copy of the whole box.
                    for (final value in box.values) {
                      if (value is Map) {
                        final m = value;
                        final dateMatches = m['dateKey'] == widget.today || m['date'] == widget.today;
                        final branchMatches = m['branchId'] == null || m['branchId'] == widget.branchId;
                        if (dateMatches && branchMatches && m['served'] != true) {
                          unservedCount++;
                          final s = _kitchenNormalizeSession(m['session'] as String?);
                          if (s == 'breakfast') bfCount++;
                          else if (s == 'dinner') dinCount++;
                          else lunchCount++;
                        }
                      }
                    }

                    return Row(
                      children: [
                        _sessionFilterChip('all', 'All ($unservedCount)', null),
                        const SizedBox(width: 6),
                        _sessionFilterChip('breakfast', '🌅 Breakfast ($bfCount)', SoftPalette.orange400),
                        const SizedBox(width: 6),
                        _sessionFilterChip('lunch', '☀️ Lunch ($lunchCount)', SoftPalette.teal500),
                        const SizedBox(width: 6),
                        _sessionFilterChip('dinner', '🌙 Dinner ($dinCount)', SoftPalette.indigo550),
                      ],
                    );
                  },
                ),
            ],
          ),
        ),

        // ── Token Queue Body ──
        Expanded(
          child: !Hive.isBoxOpen(LocalStorageService.dasterkhwaanTokensBox)
              ? const Center(
                  child: CircularProgressIndicator(
                    color: SoftPalette.emerald500,
                    strokeWidth: 2,
                  ),
                )
              : ValueListenableBuilder<Box>(
                  valueListenable: DebouncedBoxListenable.shared(Hive.box(LocalStorageService.dasterkhwaanTokensBox)),
                  builder: (_, box, __) {
                    final allItems = <Map<String, dynamic>>[];
                    // Check today's date before copying a record (the box holds every day).
                    for (final key in box.keys) {
                      final raw = box.get(key);
                      if (raw is Map && (raw['dateKey'] == widget.today || raw['date'] == widget.today)) {
                        final m = Map<String, dynamic>.from(raw);
                        m['id'] ??= key.toString();
                        final dateMatches = m['dateKey'] == widget.today || m['date'] == widget.today;
                        final branchMatches = m['branchId'] == null || m['branchId'] == widget.branchId;
                        if (dateMatches && branchMatches) {
                          allItems.add(m);
                        }
                      }
                    }

                    final unserved = allItems.where((d) => d['served'] != true).toList();

                    final pending = unserved.where((d) {
                      final s = _kitchenNormalizeSession(d['session'] as String?);
                      if (_selectedSessionFilter != 'all' && s != _selectedSessionFilter) {
                        return false;
                      }
                      if (_searchQuery.isNotEmpty) {
                        final q = _searchQuery.replaceAll('#', '').trim();
                        final numStr = (d['number']?.toString() ?? '');
                        if (!numStr.contains(q)) return false;
                      }
                      return true;
                    }).toList()
                      ..sort((a, b) {
                        final aNum = (a['number'] as num?)?.toInt() ?? 0;
                        final bNum = (b['number'] as num?)?.toInt() ?? 0;
                        return aNum.compareTo(bNum);
                      });

                    if (pending.isEmpty) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 32),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const GEmptyIllustration(
                                GEmptyIllustrationKind.kitchen,
                                size: 152,
                                fallbackIcon: Icons.check_circle_outline_rounded,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                _selectedSessionFilter == 'all'
                                    ? 'All Tokens Served!'
                                    : 'No pending ${_kitchenSessionMeta[_selectedSessionFilter]?.shortTitle ?? _selectedSessionFilter} tokens',
                                style: GoogleFonts.inter(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  color: _DS.getInk(isDark),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'New tokens will appear instantly when generated.\nOr tap below to issue meal tokens.',
                                textAlign: TextAlign.center,
                                style: GoogleFonts.inter(
                                  fontSize: 12.5,
                                  color: _DS.getInk3(isDark),
                                  height: 1.4,
                                ),
                              ),
                              const SizedBox(height: 20),
                              ElevatedButton.icon(
                                onPressed: widget.onGoToIssueToken,
                                icon: const Icon(Icons.add_circle_outline_rounded, size: 18),
                                label: const Text('Issue Food Tokens'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: SoftPalette.teal500,
                                  foregroundColor: SoftPalette.gray50,
                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                  elevation: 0,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }

                    return ListView.builder(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 100),
                      itemCount: pending.length,
                      itemBuilder: (_, i) {
                        final e = pending[i];
                        final rawTime = e['time'] ?? e['timestamp'] ?? e['createdAt'];
                        final DateTime time;
                        if (rawTime is Timestamp) {
                          time = rawTime.toDate();
                        } else if (rawTime is String) {
                          time = DateTime.tryParse(rawTime) ?? DateTime.now();
                        } else if (rawTime is DateTime) {
                          time = rawTime;
                        } else {
                          time = DateTime.now();
                        }
                        final number  = (e['number'] as num?)?.toInt() ?? (i + 1);
                        final session = _kitchenNormalizeSession(e['session'] as String?);
                        final tokenId = e['id']?.toString() ?? e['localId']?.toString() ?? '';
                        final issuedBy = e['issuedBy'] as String?;

                        return _TokenCard(
                          number: number,
                          time: time,
                          session: session,
                          issuedBy: issuedBy,
                          onServe: () => widget.serveToken(tokenId, number, session: session),
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _sessionFilterChip(String id, String label, Color? activeColor) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isSelected = _selectedSessionFilter == id;
    final color = activeColor ?? SoftPalette.teal500;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _selectedSessionFilter = id),
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: isSelected ? color.withValues(alpha: isDark ? 0.22 : 0.12) : _DS.getSurface2(isDark),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected ? color : _DS.getBorder(isDark),
              width: isSelected ? 1.5 : 1,
            ),
          ),
          child: Center(
            child: Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                color: isSelected ? color : _DS.getInk3(isDark),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? const [SoftPalette.teal800m, SoftPalette.teal750m, SoftPalette.teal800]
              : const [SoftPalette.teal800, SoftPalette.teal700m, SoftPalette.teal750m],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        if (Navigator.canPop(context) && !HomeModuleHost.isModuleRoot(context)) ...[
                          IconButton(
                            icon: const Icon(Icons.arrow_back_rounded, color: SoftPalette.gray50, size: 20),
                            onPressed: () => Navigator.maybePop(context),
                          ),
                          const SizedBox(width: 4),
                        ],
                        Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: SoftPalette.gray50.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(7),
                            child: Image.asset(
                              'assets/logo/gmwf-1.webp',
                              width: 38,
                              height: 38,
                              fit: BoxFit.contain,
                              errorBuilder: (_, _, _) => const Icon(
                                Icons.restaurant_rounded,
                                color: SoftPalette.gray50A70,
                                size: 24,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        _UserAvatar(userName: widget.username, onTap: widget.onSettings),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    'Kitchen Serve Queue',
                                    style: GoogleFonts.dmSerifDisplay(
                                      color: SoftPalette.gray50,
                                      fontSize: 19,
                                      letterSpacing: -0.3,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: _DS.mint.withValues(alpha: 0.2),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Text(
                                      'طعام لنگر',
                                      style: TextStyle(
                                        color: _DS.mint,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${widget.username} · Serving Meals',
                                style: GoogleFonts.inter(
                                  color: SoftPalette.gray50.withValues(alpha: 0.65),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),

                  ElevatedButton.icon(
                    onPressed: widget.onGoToIssueToken,
                    icon: const Icon(Icons.add_rounded, size: 16),
                    label: const Text('Issue Token'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: SoftPalette.gray50.withValues(alpha: 0.2),
                      foregroundColor: SoftPalette.gray50,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(color: SoftPalette.gray50.withValues(alpha: 0.3)),
                      ),
                      textStyle: GoogleFonts.inter(fontSize: 11.5, fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(width: 6),

                  if (LocalStorageService.canKitchenLogFoodDetails(widget.branchId)) ...[
                    IconButton(
                      tooltip: 'Food Details & Logs',
                      icon: Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: SoftPalette.gray50.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.restaurant_menu_rounded, color: SoftPalette.gray50, size: 18),
                      ),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => DasterkhwaanFoodLogScreen(
                              branchId: widget.branchId,
                              userName: widget.username,
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(width: 4),
                  ],
                  _settingsBtn(widget.onSettings),
                ],
              ),
              const SizedBox(height: 14),

              // Live Realtime Stat Strip
              ValueListenableBuilder(
                valueListenable: DebouncedBoxListenable.shared(Hive.isBoxOpen(LocalStorageService.dasterkhwaanTokensBox)
                    ? Hive.box(LocalStorageService.dasterkhwaanTokensBox)
                    : Hive.box(LocalStorageService.usersBox)),
                builder: (_, Box box, __) {
                  final allTokensBox = Hive.isBoxOpen(LocalStorageService.dasterkhwaanTokensBox)
                      ? Hive.box(LocalStorageService.dasterkhwaanTokensBox)
                      : null;
                  final all = (allTokensBox?.values ?? [])
                      .whereType<Map>()
                      // Filter first, copy only the matches.
                      .where((m) =>
                          (m['dateKey'] == widget.today || m['date'] == widget.today) &&
                          (m['branchId'] == null || m['branchId'] == widget.branchId))
                      .map((m) => Map<String, dynamic>.from(m))
                      .toList();
                  final pending = all.where((d) => d['served'] != true).length;
                  final served  = all.length - pending;

                  final bfPending = all
                      .where((d) => d['served'] != true && _kitchenNormalizeSession(d['session'] as String?) == 'breakfast')
                      .length;
                  final lunchPending = all
                      .where((d) => d['served'] != true && _kitchenNormalizeSession(d['session'] as String?) == 'lunch')
                      .length;
                  final dinPending = all
                      .where((d) => d['served'] != true && _kitchenNormalizeSession(d['session'] as String?) == 'dinner')
                      .length;

                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: SoftPalette.gray50.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: SoftPalette.gray50.withValues(alpha: 0.18)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _statBadge(
                          Icons.hourglass_top_rounded,
                          'Waiting (🌅$bfPending · ☀️$lunchPending · 🌙$dinPending)',
                          '$pending',
                          SoftPalette.yellow200,
                        ),
                        Container(
                          width: 1,
                          height: 38,
                          color: SoftPalette.gray50.withValues(alpha: 0.2),
                        ),
                        _statBadge(
                          Icons.check_circle_rounded,
                          'Served Meals',
                          '$served',
                          SoftPalette.emerald200,
                        ),
                        Container(
                          width: 1,
                          height: 38,
                          color: SoftPalette.gray50.withValues(alpha: 0.2),
                        ),
                        _statBadge(
                          Icons.confirmation_number_rounded,
                          'Total Issued',
                          '${all.length}',
                          SoftPalette.gray50,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statBadge(IconData icon, String label, String value, Color color) =>
      Column(
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 14),
              const SizedBox(width: 4),
              Text(
                value,
                style: const TextStyle(
                  color: SoftPalette.gray50,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: TextStyle(
              color: SoftPalette.gray50.withValues(alpha: 0.75),
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
}

// ── Token Serve Card ─────────────────────────────────────────────────────────

class _TokenCard extends StatelessWidget {
  final int number;
  final DateTime time;
  final String session;
  final String? issuedBy;
  final VoidCallback onServe;

  const _TokenCard({
    required this.number,
    required this.time,
    this.session = 'lunch',
    this.issuedBy,
    required this.onServe,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final meta = _kitchenSessionMeta[_kitchenNormalizeSession(session)] ?? _kitchenSessionMeta['lunch']!;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: _DS.getSurface(isDark),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _DS.getBorder(isDark),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark ? Colors.black.withValues(alpha: 0.3) : SoftPalette.teal900.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Token Number Badge with Session Gradient
              Container(
                width: 78,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: meta.gradient,
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'TOKEN',
                      style: GoogleFonts.inter(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2,
                        color: Colors.white.withValues(alpha: 0.85),
                      ),
                    ),
                    const SizedBox(height: 2),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '#$number',
                        style: GoogleFonts.dmSerifDisplay(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          height: 1.0,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Token Details
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Session pill + Urdu tag
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: meta.color.withValues(alpha: isDark ? 0.2 : 0.1),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(meta.icon, size: 11, color: meta.color),
                                const SizedBox(width: 4),
                                Text(
                                  meta.shortTitle,
                                  style: GoogleFonts.inter(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: meta.color,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              meta.urdu,
                              style: TextStyle(
                                fontFamily: 'Jameel Noori Nastaleeq',
                                fontSize: 13,
                                color: _DS.getInk3(isDark),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      // Timestamp & Issued By
                      Row(
                        children: [
                          Icon(Icons.schedule_rounded, size: 12, color: _DS.getInk3(isDark)),
                          const SizedBox(width: 4),
                          Text(
                            DateFormat('hh:mm a').format(time),
                            style: GoogleFonts.inter(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: _DS.getInk2(isDark),
                            ),
                          ),
                          if (issuedBy != null && issuedBy!.isNotEmpty) ...[
                            Text(' · ', style: TextStyle(color: _DS.getInk3(isDark))),
                            Icon(Icons.person_outline_rounded, size: 12, color: _DS.getInk3(isDark)),
                            const SizedBox(width: 3),
                            Flexible(
                              child: Text(
                                issuedBy!,
                                style: GoogleFonts.inter(
                                  fontSize: 11,
                                  color: _DS.getInk3(isDark),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              // Grand Tactile Serve Button
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Center(
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () {
                        HapticFeedback.mediumImpact();
                        onServe();
                      },
                      borderRadius: BorderRadius.circular(12),
                      child: Ink(
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [SoftPalette.teal700, SoftPalette.teal550],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: SoftPalette.teal600.withValues(alpha: 0.35),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.check_circle_rounded, color: Colors.white, size: 16),
                            const SizedBox(width: 6),
                            Text(
                              'Serve',
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                                letterSpacing: 0.3,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}




// ═══════════════════════════════════════════════════════════════════════════
// HISTORY TAB
// ═══════════════════════════════════════════════════════════════════════════

class _HistoryTab extends StatefulWidget {
  final String branchId, username;
  final DateFormat dateFmt, displayFmt;
  final VoidCallback onLogout;
  final VoidCallback onSettings;

  const _HistoryTab({
    required this.branchId,
    required this.dateFmt,
    required this.displayFmt,
    required this.username,
    required this.onLogout,
    required this.onSettings,
  });

  @override
  State<_HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<_HistoryTab> {
  DateTime _selectedDate = DateTime.now();

  Future<Map<String, dynamic>> _fetchDayData(String dateKey) async {
    final dayDoc = await FirebaseFirestore.instance
        .collection('branches')
        .doc(widget.branchId)
        .collection('dasterkhwaan')
        .doc(dateKey)
        .get();
    final dayData    = dayDoc.data() ?? {};
    final tokensSnap = await FirebaseFirestore.instance
        .collection('branches')
        .doc(widget.branchId)
        .collection('dasterkhwaan')
        .doc(dateKey)
        .collection('tokens')
        .get();
    final cookingSnap = await FirebaseFirestore.instance
        .collection('branches')
        .doc(widget.branchId)
        .collection('dasterkhwaan')
        .doc(dateKey)
        .collection('cooking_sessions')
        .get();

    final totalTokens  = tokensSnap.docs.length;
    final servedTokens = tokensSnap.docs
        .where((d) => (d.data())['served'] == true)
        .length;
    final sessions = cookingSnap.docs.map((d) {
      final data = d.data();
      return {
        'dish':           data['dish'] ?? '—',
        'isReceivedFood': data['isReceivedFood'] as bool? ?? false,
        'isSavedFood':    data['isSavedFood']    as bool? ?? false,
        'source':         data['source'] ?? '',
        'usedKg':         (data['usedKg']   as num? ?? data['cookedKg'] as num? ?? 0).toDouble(),
        'savedKg':        (data['savedKg']  as num? ?? 0).toDouble(),
        'wastedKg':       (data['wastedKg'] as num? ?? 0).toDouble(),
        'notes':          data['notes'] ?? '',
        'ingredients':    data['ingredients'] ?? [],
      };
    }).toList();

    return {
      'menu':         dayData['menu'] ?? '',
      'totalTokens':  totalTokens,
      'servedTokens': servedTokens,
      'sessions':     sessions,
    };
  }

  @override
  Widget build(BuildContext context) {
    final dateKey     = widget.dateFmt.format(_selectedDate);
    final displayDate = widget.displayFmt.format(_selectedDate);
    final isToday     = dateKey == widget.dateFmt.format(DateTime.now());

    final isWrapped = GlobalModuleWrapper.isWrapped(context);

    return Column(children: [
      if (!isWrapped)
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
                colors: [SoftPalette.violet550, kPurple],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight),
          ),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                  Row(children: [
                    if (Navigator.canPop(context) && !HomeModuleHost.isModuleRoot(context)) ...[
                      IconButton(
                        icon: const Icon(Icons.arrow_back_rounded, color: SoftPalette.gray50, size: 20),
                        onPressed: () => Navigator.maybePop(context),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: SoftPalette.gray50.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.asset(
                          'assets/logo/gmwf-1.webp',
                          width: 54,
                          height: 54,
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.restaurant_rounded,
                            color: SoftPalette.gray50A70,
                            size: 28,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    _UserAvatar(userName: widget.username, onTap: widget.onSettings),
                    const SizedBox(width: 12),
                    Column(crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      const Text('Daily History',
                          style: TextStyle(
                              color: SoftPalette.gray50,
                              fontSize: 24,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.5)),
                      Text(widget.username,
                          style: const TextStyle(
                              color: SoftPalette.gray50,
                              fontSize: 18,
                              fontWeight: FontWeight.w700)),
                    ]),
                  ]),
                  _settingsBtn(widget.onSettings),
                ]),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: SoftPalette.gray50.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: SoftPalette.gray50.withValues(alpha: 0.2)),
                  ),
                  child: Row(children: [
                    _dateNavBtn(
                      Icons.chevron_left_rounded,
                      () => setState(() => _selectedDate =
                          _selectedDate.subtract(const Duration(days: 1))),
                    ),
                    Expanded(
                      child: GestureDetector(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _selectedDate,
                            firstDate: DateTime(2024),
                            lastDate: DateTime.now(),
                            builder: (ctx, child) => Theme(
                              data: ThemeData.light().copyWith(
                                  colorScheme: const ColorScheme.light(
                                      primary: kPurple)),
                              child: child!,
                            ),
                          );
                          if (picked != null) {
                            setState(() => _selectedDate = picked);
                          }
                        },
                        child: Container(
                          padding:
                              const EdgeInsets.symmetric(vertical: 10),
                          child: Row(
                              mainAxisAlignment:
                                  MainAxisAlignment.center,
                              children: [
                            const Icon(Icons.calendar_today_rounded,
                                color: SoftPalette.gray50, size: 16),
                            const SizedBox(width: 8),
                            Text(
                                isToday
                                    ? 'Today — $displayDate'
                                    : displayDate,
                                style: const TextStyle(
                                    color: SoftPalette.gray50,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 14)),
                          ]),
                        ),
                      ),
                    ),
                    _dateNavBtn(
                      Icons.chevron_right_rounded,
                      isToday
                          ? null
                          : () => setState(() => _selectedDate =
                              _selectedDate.add(const Duration(days: 1))),
                    ),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      // Date navigation bar — always visible (even when embedded in dashboard)
      if (isWrapped)
        Container(
          margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: kPurple.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: kPurple.withValues(alpha: 0.2)),
          ),
          child: Row(children: [
            _dateNavBtn(
              Icons.chevron_left_rounded,
              () => setState(() => _selectedDate =
                  _selectedDate.subtract(const Duration(days: 1))),
            ),
            Expanded(
              child: GestureDetector(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _selectedDate,
                    firstDate: DateTime(2024),
                    lastDate: DateTime.now(),
                    builder: (ctx, child) => Theme(
                      data: ThemeData.light().copyWith(
                          colorScheme: const ColorScheme.light(
                              primary: kPurple)),
                      child: child!,
                    ),
                  );
                  if (picked != null) {
                    setState(() => _selectedDate = picked);
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                    const Icon(Icons.calendar_today_rounded,
                        color: kPurple, size: 16),
                    const SizedBox(width: 8),
                    Text(
                        isToday
                            ? 'Today — $displayDate'
                            : displayDate,
                        style: const TextStyle(
                            color: kPurple,
                            fontWeight: FontWeight.w800,
                            fontSize: 14)),
                  ]),
                ),
              ),
            ),
            _dateNavBtn(
              Icons.chevron_right_rounded,
              isToday
                  ? null
                  : () => setState(() => _selectedDate =
                      _selectedDate.add(const Duration(days: 1))),
            ),
          ]),
        ),
      Expanded(
        child: FutureBuilder<Map<String, dynamic>>(
          key: ValueKey(dateKey),
          future: _fetchDayData(dateKey),
          builder: (_, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(
                  child: CircularProgressIndicator(
                      color: kPurple, strokeWidth: 2));
            }
            if (snap.hasError) {
              return Center(child: Text('Error: ${snap.error}'));
            }
            final d            = snap.data!;
            final menu         = d['menu'] as String;
            final totalTokens  = d['totalTokens'] as int;
            final servedTokens = d['servedTokens'] as int;
            final sessions =
                d['sessions'] as List<Map<String, dynamic>>;

            if (totalTokens == 0 &&
                sessions.isEmpty &&
                menu.isEmpty) {
              return Center(
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                const GEmptyIllustration(
                  GEmptyIllustrationKind.kitchen,
                  size: 148,
                  fallbackIcon: Icons.event_note_rounded,
                ),
                const SizedBox(height: 16),
                Text('No records for $displayDate',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: context.adapt(kTextLight))),
              ]));
            }

            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                _sectionCard(
                  icon: Icons.confirmation_number_rounded,
                  iconColor: kSuccess,
                  title: 'Token Summary',
                  child: Row(children: [
                    Expanded(child: _histStat('Total',
                        '$totalTokens',
                        Icons.confirmation_number_rounded,
                        kSuccess)),
                    Expanded(child: _histStat('Served',
                        '$servedTokens',
                        Icons.check_circle_rounded, kInfo)),
                    Expanded(child: _histStat('Pending',
                        '${totalTokens - servedTokens}',
                        Icons.hourglass_top_rounded, kWarning)),
                  ]),
                ),
                const SizedBox(height: 14),
                if (menu.isNotEmpty) ...[
                  _sectionCard(
                    icon: Icons.restaurant_menu_rounded,
                    iconColor: kWarning,
                    title: 'Menu',
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                          color: context.adapt(SoftPalette.yellow50m),
                          borderRadius: BorderRadius.circular(10)),
                      child: Text(menu,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: context.adapt(SoftPalette.orange600),
                              height: 1.5)),
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
                if (sessions.isNotEmpty) ...[
                  Text('FOOD LOG (${sessions.length})',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: context.adapt(kTextLight),
                          letterSpacing: 1.0)),
                  const SizedBox(height: 8),
                  ...sessions.map((s) => _HistCookCard(session: s)),
                ],
              ],
            );
          },
        ),
      ),
    ]);
  }

  Widget _dateNavBtn(IconData icon, VoidCallback? onTap) {
    final isWrapped = GlobalModuleWrapper.isWrapped(context);
    return GestureDetector(
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: onTap == null
                ? (isWrapped ? kPurple.withValues(alpha: 0.05) : SoftPalette.gray50.withValues(alpha: 0.05))
                : (isWrapped ? kPurple.withValues(alpha: 0.15) : SoftPalette.gray50.withValues(alpha: 0.15)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon,
              color: onTap == null
                  ? (isWrapped ? kPurple.withValues(alpha: 0.3) : SoftPalette.gray50.withValues(alpha: 0.3))
                  : (isWrapped ? kPurple : SoftPalette.gray50),
              size: 20),
        ),
      );
  }

  Widget _sectionCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    required Widget child,
  }) =>
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: context.adapt(SoftPalette.gray50),
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
                color: SoftPalette.gray900.withValues(alpha: 0.04),
                blurRadius: 12,
                offset: const Offset(0, 3))
          ],
        ),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          Row(children: [
            Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, color: iconColor, size: 18)),
            const SizedBox(width: 10),
            Text(title,
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: context.adapt(kTextDark))),
          ]),
          const SizedBox(height: 14),
          child,
        ]),
      );

  Widget _histStat(
          String label, String value, IconData icon, Color color) =>
      Column(children: [
        Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: color, size: 18)),
        const SizedBox(height: 6),
        Text(value,
            style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                color: color)),
        const SizedBox(height: 2),
        Text(label,
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: context.adapt(kTextLight))),
      ]);
}

class _HistCookCard extends StatelessWidget {
  final Map<String, dynamic> session;
  const _HistCookCard({required this.session});

  String _fmt(num? v) {
    final d = (v ?? 0).toDouble();
    return d == d.roundToDouble()
        ? d.toInt().toString()
        : d.toStringAsFixed(1);
  }

  bool get _isReceived  => session['isReceivedFood'] as bool? ?? false;
  bool get _isSavedFood => session['isSavedFood']    as bool? ?? false;

  Color get _typeColor {
    if (_isSavedFood) return kTeal;
    if (_isReceived)  return kPurple;
    return kWarning;
  }

  IconData get _typeIcon {
    if (_isSavedFood) return Icons.recycling_rounded;
    if (_isReceived)  return Icons.delivery_dining_rounded;
    return Icons.soup_kitchen_rounded;
  }

  String get _typeLabel {
    if (_isSavedFood) return 'Saved Food';
    if (_isReceived)  return 'Received';
    return 'Cooked';
  }

  @override
  Widget build(BuildContext context) {
    final ingredients = List<Map<String, dynamic>>.from(
        (session['ingredients'] as List<dynamic>? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map)));
    final source      = session['source'] as String? ?? '';
    final displayDish = _isSavedFood
        ? (session['dish'] as String).replaceFirst('Saved: ', '')
        : session['dish'] as String;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.adapt(SoftPalette.gray50),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _typeColor.withValues(alpha: 0.2)),
        boxShadow: [
          BoxShadow(
              color: _typeColor.withValues(alpha: 0.07),
              blurRadius: 10,
              offset: const Offset(0, 3))
        ],
      ),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
        Row(children: [
          Icon(_typeIcon, color: _typeColor, size: 18),
          const SizedBox(width: 8),
          Expanded(
              child: Text(displayDish,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: context.adapt(kTextDark)))),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: _typeColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              _typeLabel,
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: _typeColor),
            ),
          ),
        ]),
        if (_isSavedFood) ...[
          const SizedBox(height: 4),
          Row(children: [
            const Icon(Icons.recycling_rounded, size: 12, color: kTeal),
            const SizedBox(width: 4),
            const Text('Carry-over from previous day',
                style: TextStyle(
                    fontSize: 11,
                    color: kTeal,
                    fontWeight: FontWeight.w600)),
          ]),
        ] else if (_isReceived && source.isNotEmpty) ...[
          const SizedBox(height: 4),
          Row(children: [
            const Icon(Icons.store_rounded, size: 12, color: kPurple),
            const SizedBox(width: 4),
            Text(source,
                style: const TextStyle(
                    fontSize: 11,
                    color: kPurple,
                    fontWeight: FontWeight.w600)),
          ]),
        ],
        const SizedBox(height: 10),
        Row(children: [
          _chip('${_fmt(session['usedKg'] as num?)} kg',
              'Used', _typeColor),
          const SizedBox(width: 6),
          _chip('${_fmt(session['savedKg'] as num?)} kg',
              'Saved', kInfo),
          const SizedBox(width: 6),
          _chip('${_fmt(session['wastedKg'] as num?)} kg',
              'Wasted', kAccent),
        ]),
        if (!_isReceived && !_isSavedFood && ingredients.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: ingredients
                .map((ing) => Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                          color: context.adapt(kSurface),
                          borderRadius: BorderRadius.circular(6)),
                      child: Text(
                          '${ing['name']}: ${_fmt(ing['qty'] as num?)} ${ing['unit']}',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: context.adapt(kTextMid))),
                    ))
                .toList(),
          ),
        ],
        if ((session['notes'] as String? ?? '').isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(session['notes'] as String,
              style: TextStyle(
                  fontSize: 12, color: context.adapt(SoftPalette.slate550))),
        ],
      ]),
    );
  }

  Widget _chip(String value, String label, Color color) =>
      Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
              color: color.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8)),
          child: Column(children: [
            Text(value,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: color)),
            Text(label,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 9,
                    color: color.withValues(alpha: 0.7),
                    fontWeight: FontWeight.w600)),
          ]),
        ),
      );
}

// ═══════════════════════════════════════════════════════════════════════════
// SHARED HELPERS
// ═══════════════════════════════════════════════════════════════════════════

Widget _settingsBtn(VoidCallback onTap) => GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: SoftPalette.gray50.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: SoftPalette.gray50.withValues(alpha: 0.25), width: 0.5),
        ),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.settings_outlined, color: SoftPalette.gray50, size: 16),
          SizedBox(width: 5),
          Text('Settings',
              style: TextStyle(
                  color: SoftPalette.gray50,
                  fontWeight: FontWeight.w800,
                  fontSize: 13)),
        ]),
      ),
    );

class _UserAvatar extends StatelessWidget {
  final String userName;
  final VoidCallback onTap;
  const _UserAvatar({required this.userName, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final userData = LocalStorageService.getActiveUserData();
    final photoStr = (userData['profileImage'] ?? userData['photoUrl'] ?? userData['profilePictureUrl']) as String?;
    ImageProvider? imageProvider;
    if (photoStr != null && photoStr.isNotEmpty) {
      if (photoStr.startsWith('http://') || photoStr.startsWith('https://')) {
        imageProvider = NetworkImage(photoStr);
      } else {
        try {
          final cleanBase64 = photoStr.contains(',') ? photoStr.split(',').last : photoStr;
          imageProvider = Base64ImageCache.of(cleanBase64);
        } catch (_) {}
      }
    }

    final initial = userName.trim().isNotEmpty ? userName.trim()[0].toUpperCase() : 'K';

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: SoftPalette.gray50.withValues(alpha: 0.4), width: 2),
          boxShadow: [
            BoxShadow(
              color: SoftPalette.gray900.withValues(alpha: 0.15),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: ClipOval(
          child: imageProvider != null
              ? Image(image: imageProvider, fit: BoxFit.cover, errorBuilder: (_, _, _) => _fallback(initial))
              : _fallback(initial),
        ),
      ),
    );
  }

  Widget _fallback(String initial) => Container(
        color: SoftPalette.gray50.withValues(alpha: 0.20),
        alignment: Alignment.center,
        child: Text(
          initial,
          style: const TextStyle(
            color: SoftPalette.gray50,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
      );
}
