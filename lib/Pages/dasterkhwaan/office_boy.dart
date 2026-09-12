// lib/pages/dasterkhwaan/office_boy.dart
//
// Redesign: Refined Luxury Fintech aesthetic
// Palette  : Deep forest green hero · mint accent · white surfaces
// Typography: Google Fonts – DM Serif Display (headings) + DM Sans (body)
//
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../widgets/gmwf_loading_view.dart';
import '../donations/donations_screen.dart';
import '../donations/donation_boxes_screen.dart';
import '../donations/donors_registry.dart';
import '../donations/donations_shared.dart';
import '../../services/donations_local_storage.dart';
import '../../services/donation_box_storage.dart';
import '../../models/donation_box_models.dart';
import '../../services/local_storage_service.dart';
import '../../services/camp_session_service.dart';
import '../../services/auth_service.dart';
import '../../utils/formatters.dart';
import '../settings_page.dart';
import '../../theme/app_theme.dart';
import '../../theme/role_theme_provider.dart';
import '../../realtime/realtime_manager.dart';
import '../../realtime/realtime_events.dart';
import '../../services/sync_service.dart';

// ─────────────────────────── Design Tokens ──────────────────────────────────

abstract class _DS {
  // Surfaces (Static Fallbacks)
  static const Color bg       = Color(0xFFF4F7F6);
  static const Color surface  = Color(0xFFFFFFFF);
  static const Color surface2 = Color(0xFFEDF2F1);
  static const Color border   = Color(0xFFE2ECEA);
  static const Color border2  = Color(0xFFC8D9D6);

  // Dynamic Theme Helpers for Dark Mode
  static Color getBg(bool isDark) => isDark ? const Color(0xFF0F172A) : const Color(0xFFF4F7F6);
  static Color getSurface(bool isDark) => isDark ? const Color(0xFF1E293B) : const Color(0xFFFFFFFF);
  static Color getSurface2(bool isDark) => isDark ? const Color(0xFF243044) : const Color(0xFFEDF2F1);
  static Color getBorder(bool isDark) => isDark ? const Color(0xFF334155) : const Color(0xFFE2ECEA);
  static Color getBorder2(bool isDark) => isDark ? const Color(0xFF475569) : const Color(0xFFC8D9D6);
  static Color getInk(bool isDark) => isDark ? const Color(0xFFF8FAFC) : const Color(0xFF0A0F0E);
  static Color getInk2(bool isDark) => isDark ? const Color(0xFFCBD5E1) : const Color(0xFF2D3B38);
  static Color getInk3(bool isDark) => isDark ? const Color(0xFF94A3B8) : const Color(0xFF6B8480);

  // Brand greens
  static const Color sage     = Color(0xFF1A3530);
  static const Color sage2    = Color(0xFF243D38);
  static const Color mint     = Color(0xFF00C9A7);
  static const Color mint2    = Color(0xFF00E8C1);
  static const Color mintBg   = Color(0xFFE6FDF8);

  // Semantic
  static const Color amber    = Color(0xFFD97706);
  static const Color amberBg  = Color(0xFFFFFBEB);
  static const Color green    = Color(0xFF1A9966);
  static const Color greenBg  = Color(0xFFEAF7F0);
  static const Color red      = Color(0xFFE04444);
  static const Color redBg    = Color(0xFFFEF0F0);
  static const Color purple   = Color(0xFF7C3AED);
  static const Color purpleBg = Color(0xFFF0EBFE);
  static const Color purpleDark = Color(0xFF2D1B69);

  // Text (Static Fallbacks)
  static const Color ink      = Color(0xFF0A0F0E);
  static const Color ink2     = Color(0xFF2D3B38);
  static const Color ink3     = Color(0xFF6B8480);

  // Radius
  static const double r12 = 12;
  static const double r14 = 14;
  static const double r16 = 16;
  static const double r22 = 22;
  static const double rPill = 100;
}

// ─────────────────────────── Text Styles ────────────────────────────────────

abstract class _TS {
  static TextStyle displayLg(Color c) => GoogleFonts.dmSerifDisplay(
      fontSize: 28, color: c, height: 1.1);

  static TextStyle displayMd(Color c) => GoogleFonts.dmSerifDisplay(
      fontSize: 22, color: c, height: 1.2);

  static TextStyle label({Color c = _DS.ink3, double size = 10}) =>
      GoogleFonts.dmSans(
          fontSize: size, fontWeight: FontWeight.w600,
          letterSpacing: 1.2, color: c);

  static TextStyle body({Color? c, double size = 14, FontWeight w = FontWeight.w400}) =>
      GoogleFonts.dmSans(fontSize: size, fontWeight: w, color: c ?? _DS.ink);

  static TextStyle num({Color? c, double size = 22}) =>
      GoogleFonts.dmSans(fontSize: size, fontWeight: FontWeight.w600, color: c ?? _DS.ink, height: 1.0);
}

// ─────────────────────────────────────────────────────────────────────────────
// ROOT WIDGET
// ─────────────────────────────────────────────────────────────────────────────

class DasterkhwaanOfficeBoy extends StatefulWidget {
  static const String routeName = '/dasterkhwaan-office-boy';
  final String? branchId;
  final String? userName;
  final String? role;

  const DasterkhwaanOfficeBoy({
    super.key,
    this.branchId,
    this.userName,
    this.role,
  });

  @override
  State<DasterkhwaanOfficeBoy> createState() => _DasterkhwaanOfficeBoyState();
}

class _DasterkhwaanOfficeBoyState extends State<DasterkhwaanOfficeBoy>
    with TickerProviderStateMixin {
  int _currentNav = 0;
  String _userName = 'User';
  String? _branchId;

  late PageController _pageController;
  final _qtyCtrl = TextEditingController(text: '1');
  final double _pricePerToken = 10.0;
  late String _selectedSession;

  bool get _isOfficeBoy {
    final r = (widget.role ?? '').toLowerCase().trim();
    if (r.isEmpty) return true;
    final isExecutive = r.contains('admin') ||
        r.contains('chairman') ||
        r.contains('ceo') ||
        r.contains('manager') ||
        r.contains('supervisor') ||
        r.contains('principal');
    if (isExecutive && !r.contains('office boy') && !r.contains('officeboy')) {
      return false;
    }
    return true;
  }

  late AnimationController _fadeCtrl;
  late Animation<double> _fadeAnim;
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  final DateFormat _dateFmt    = DateFormat('yyyy-MM-dd');
  final DateFormat _displayFmt = DateFormat('EEE, dd MMM yyyy');
  late final String today      = _dateFmt.format(DateTime.now());

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _dayDocSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _tokensSub;

  Map<String, dynamic> _stats = {
    'total': 0,
    'served': 0,
    'breakfastTotal': 0,
    'breakfastServed': 0,
    'lunchTotal': 0,
    'lunchServed': 0,
    'dinnerTotal': 0,
    'dinnerServed': 0,
    'donations': 0,
    'donationAmount': 0.0,
  };

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _currentNav);

    _fadeCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600));
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _fadeCtrl.forward();

    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1600));
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.03).animate(
        CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
    _pulseCtrl.repeat(reverse: true);

    LocalStorageService.initForRoles([
      if (widget.role != null) widget.role!,
      'office_boy',
      'office boy',
      'dasterkhwaan',
      'welfare',
      'donation',
    ]);
    DonationsLocalStorage.init().then((_) {
      if (mounted) setState(() => _recalculateLocalStats());
    });
    DonationBoxStorage.init().then((_) {
      if (mounted) setState(() {});
    });
    LocalStorageService.openBoxSafe('dasterkhwaan_tokens').then((_) {
      if (mounted) {
        setState(() {
          _recalculateLocalStats();
        });
        _backfillUnsyncedTokens();
      }
    });

    if (widget.branchId != null) {
      _branchId = widget.branchId;
      _userName = widget.userName ?? 'Office Boy';
      _recalculateLocalStats();
      _setupRealtimeListeners();
    } else {
      _loadUserAndBranch();
    }
    _selectedSession = CampSessionService.resolveDasterkhwaanSession(null, _branchId);
  }

  void _goToTab(int index) {
    HapticFeedback.selectionClick();
    setState(() => _currentNav = index);
    if (_pageController.hasClients) {
      _pageController.animateToPage(
        index,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeInOut,
      );
    }
  }

  String get _effectiveUserName {
    final activeUser = LocalStorageService.getActiveUserData();
    final resolved = resolveUserDisplayName(activeUser, fallback: '');
    if (resolved.isNotEmpty && resolved != 'User' && resolved != 'Office Boy') {
      return resolved;
    }
    if (widget.userName != null &&
        widget.userName!.trim().isNotEmpty &&
        widget.userName != 'User' &&
        widget.userName != 'Office Boy') {
      return widget.userName!.trim();
    }
    if (_userName.isNotEmpty && _userName != 'User' && _userName != 'Office Boy') {
      return _userName;
    }
    final email = FirebaseAuth.instance.currentUser?.email;
    if (email != null && email.contains('@')) {
      final prefix = email.split('@').first;
      if (prefix.isNotEmpty) return prefix[0].toUpperCase() + prefix.substring(1);
    }
    return 'Office Boy';
  }

  String get _effectiveUserId {
    final activeUser = LocalStorageService.getActiveUserData();
    final uid = (activeUser['uid'] ?? activeUser['id'] ?? activeUser['userId'] ?? '').toString().trim();
    if (uid.isNotEmpty) return uid;
    final fbUid = FirebaseAuth.instance.currentUser?.uid;
    if (fbUid != null && fbUid.isNotEmpty) return fbUid;
    return '';
  }

  @override
  void dispose() {
    _dayDocSub?.cancel();
    _tokensSub?.cancel();
    _pageController.dispose();
    _fadeCtrl.dispose();
    _pulseCtrl.dispose();
    _qtyCtrl.dispose();
    super.dispose();
  }

  // ── Data ───────────────────────────────────────────────────────────────────

  Future<void> _loadUserAndBranch() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final branches =
          await FirebaseFirestore.instance.collection('branches').get();
      for (final branch in branches.docs) {
        final userDoc =
            await branch.reference.collection('users').doc(user.uid).get();
        if (userDoc.exists) {
          final data = userDoc.data()!;
          setState(() {
            _userName = resolveUserDisplayName(
              data,
              fallback: data['username'] ?? user.email?.split('@').first ?? 'Office Boy',
            );
            _branchId = branch.id;
            _selectedSession = CampSessionService.resolveDasterkhwaanSession(null, _branchId);
          });
          _recalculateLocalStats();
          _setupRealtimeListeners();
          return;
        }
      }
    } catch (e) {
      debugPrint('Error loading user/branch: $e');
    }
  }

  DocumentReference<Map<String, dynamic>> get _dayDoc {
    if (_branchId == null) throw Exception('Branch not found');
    return FirebaseFirestore.instance
        .collection('branches')
        .doc(_branchId)
        .collection('dasterkhwaan')
        .doc(today);
  }

  CollectionReference<Map<String, dynamic>> get _tokensCol {
    if (_branchId == null) throw Exception('Branch not found');
    return _dayDoc.collection('tokens');
  }

  Future<Box> _getTokensBox() async {
    return await LocalStorageService.openBoxSafe('dasterkhwaan_tokens');
  }

  void _recalculateLocalStats() {
    if (_branchId == null) return;
    int localTotal = 0;
    int localServed = 0;
    int localBreakfast = 0, localBreakfastServed = 0;
    int localLunch = 0, localLunchServed = 0;
    int localDinner = 0, localDinnerServed = 0;

    try {
      if (Hive.isBoxOpen('dasterkhwaan_tokens')) {
        final box = Hive.box('dasterkhwaan_tokens');
        for (final raw in box.values) {
          if (raw is Map) {
            final t = Map<String, dynamic>.from(raw);
            if (t['dateKey'] == today && t['branchId'] == _branchId) {
              localTotal++;
              final isServed = t['served'] == true;
              if (isServed) localServed++;

              final s = (t['session'] ?? 'lunch').toString().toLowerCase();
              if (s == 'breakfast') {
                localBreakfast++;
                if (isServed) localBreakfastServed++;
              } else if (s == 'dinner' || s == 'evening' || s == 'night') {
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
      debugPrint('[OfficeBoy] Local tokens calculation error: $e');
    }

    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final localDonations = DonationsLocalStorage.getAllDonations(_branchId!)
        .where((d) => d.date == today && ((uid.isNotEmpty && d.collectorId == uid) || (_effectiveUserName.isNotEmpty && d.recordedBy.toLowerCase().trim() == _effectiveUserName.toLowerCase().trim()) || (d.collectorId == null || d.collectorId!.isEmpty)));
    double donTotal = 0.0;
    int donCount = 0;
    for (var d in localDonations) {
      donTotal += d.amount;
      donCount++;
    }

    final updated = {
      'total': localTotal > (_stats['total'] as int? ?? 0) ? localTotal : _stats['total'],
      'served': localServed > (_stats['served'] as int? ?? 0) ? localServed : _stats['served'],
      'breakfastTotal': localBreakfast > (_stats['breakfastTotal'] as int? ?? 0) ? localBreakfast : _stats['breakfastTotal'],
      'breakfastServed': localBreakfastServed > (_stats['breakfastServed'] as int? ?? 0) ? localBreakfastServed : _stats['breakfastServed'],
      'lunchTotal': localLunch > (_stats['lunchTotal'] as int? ?? 0) ? localLunch : _stats['lunchTotal'],
      'lunchServed': localLunchServed > (_stats['lunchServed'] as int? ?? 0) ? localLunchServed : _stats['lunchServed'],
      'dinnerTotal': localDinner > (_stats['dinnerTotal'] as int? ?? 0) ? localDinner : _stats['dinnerTotal'],
      'dinnerServed': localDinnerServed > (_stats['dinnerServed'] as int? ?? 0) ? localDinnerServed : _stats['dinnerServed'],
      'donations': donCount > (_stats['donations'] as int? ?? 0) ? donCount : _stats['donations'],
      'donationAmount': donTotal > (_stats['donationAmount'] as double? ?? 0.0) ? donTotal : _stats['donationAmount'],
    };

    if (mounted) {
      setState(() => _stats = updated);
    } else {
      _stats = updated;
    }
  }

  void _setupRealtimeListeners() {
    _dayDocSub?.cancel();
    _tokensSub?.cancel();
    if (_branchId == null) return;
    _recalculateLocalStats();
  }

  Future<void> _generateTokens() async {
    final quantity = int.tryParse(_qtyCtrl.text.trim()) ?? 0;
    if (quantity <= 0) {
      _showSnack('Enter a valid quantity', isError: true);
      return;
    }
    if (_branchId == null) {
      _showSnack('Branch not found!', isError: true);
      return;
    }
    HapticFeedback.mediumImpact();

    // 1. Calculate next sequential start number
    int startNum = 1;
    try {
      final tokenBox = await _getTokensBox();
      int maxNum = 0;
      for (final raw in tokenBox.values) {
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

    for (int i = 0; i < quantity; i++) {
      final num = startNum + i;
      final tid = 'dst_${_branchId}_${today}_$num';
      tokensList.add({
        'id': tid,
        'localId': tid,
        'number': num,
        'time': nowIso,
        'served': false,
        'session': _selectedSession,
        'branchId': _branchId,
        'dateKey': today,
        'issuedBy': _effectiveUserName,
        'pricePerToken': _pricePerToken,
        'syncStatus': 'pending',
      });
    }

    // ── STEP 1: Save Locally First (Hive) ──────────────────────────────
    try {
      final tokenBox = await _getTokensBox();
      for (final t in tokensList) {
        await tokenBox.put(t['id'], t);
      }
    } catch (e) {
      debugPrint('[OfficeBoy] Local token write error: $e');
    }

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
              'issuedBy': _effectiveUserName,
              'pricePerToken': _pricePerToken,
              'timestamp': nowIso,
            },
          ),
        );
      } catch (e) {
        debugPrint('[OfficeBoy] Realtime LAN broadcast error: $e');
      }
    }

    // ── STEP 3: Always Enqueue for Cloud Sync ───────────────────────────
    try {
      await LocalStorageService.enqueueSync({
        'type': 'save_dasterkhwan_tokens',
        'branchId': _branchId,
        'dateKey': today,
        'data': {
          'branchId': _branchId,
          'dateKey': today,
          'session': _selectedSession,
          'quantity': quantity,
          'tokens': tokensList,
          'issuedBy': _effectiveUserName,
          'pricePerToken': _pricePerToken,
        },
      });
      SyncService().triggerUpload(force: true);
    } catch (e) {
      debugPrint('[OfficeBoy] Sync enqueue error: $e');
    }

    // ── STEP 4: Direct Firestore write in parallel for instant cloud sync ─────
    try {
      final tokensRef = _tokensCol;
      final dayRef = _dayDoc;
      final batch = FirebaseFirestore.instance.batch();

      for (final t in tokensList) {
        final docRef = tokensRef.doc(t['id']);
        batch.set(docRef, {
          'number': t['number'],
          'time': FieldValue.serverTimestamp(),
          'served': false,
          'session': t['session'],
          'issuedBy': t['issuedBy'],
          'localId': t['id'],
        }, SetOptions(merge: true));
      }
      batch.set(dayRef, {
        'totalTokens': FieldValue.increment(quantity),
        'session_${_selectedSession}_total': FieldValue.increment(quantity),
        'lastUpdated': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      batch.commit().then((_) async {
        final tokenBox = await _getTokensBox();
        for (final t in tokensList) {
          final existing = tokenBox.get(t['id']);
          if (existing is Map) {
            final updated = Map<String, dynamic>.from(existing)
              ..['syncStatus'] = 'synced'
              ..['synced'] = true;
            await tokenBox.put(t['id'], updated);
          }
        }
      }).catchError((err) {
        debugPrint('[OfficeBoy] Direct Firestore write deferred to sync queue: $err');
      });
    } catch (_) {}

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
    _showSnack(
        '$quantity $sessionDisplayName Token${quantity > 1 ? 's' : ''} Issued · PKR ${(quantity * _pricePerToken).toStringAsFixed(0)}');
    _qtyCtrl.text = '1';
    setState(() {});
  }

  Future<void> _showReverseTokensDialog() async {
    if (_branchId == null) {
      _showSnack('Branch not found!', isError: true);
      return;
    }

    // Load unserved tokens from local Hive first
    final List<Map<String, dynamic>> localUnserved = [];
    try {
      final tokenBox = await _getTokensBox();
      for (final raw in tokenBox.values) {
        if (raw is Map) {
          final t = Map<String, dynamic>.from(raw);
          if (t['dateKey'] == today && t['branchId'] == _branchId && t['served'] != true) {
            localUnserved.add(t);
          }
        }
      }
    } catch (_) {}

    // Also fetch cloud docs if reachable to get full list
    try {
      final unservedSnap = await _tokensCol.where('served', isEqualTo: false).get().timeout(const Duration(seconds: 2));
      for (final d in unservedSnap.docs) {
        final data = d.data();
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
          final qty = int.tryParse(reverseQtyCtrl.text) ?? 0;
          return AlertDialog(
            backgroundColor: _DS.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_DS.r22)),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: _DS.redBg, borderRadius: BorderRadius.circular(10)),
                  child: const Icon(Icons.undo_rounded, color: _DS.red, size: 22),
                ),
                const SizedBox(width: 12),
                Text('Reverse Food Tokens', style: GoogleFonts.dmSerifDisplay(fontSize: 20, color: _DS.ink)),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Unintentionally issued tokens can be voided. ${localUnserved.length} unserved token(s) available today.',
                  style: GoogleFonts.dmSans(fontSize: 13, color: _DS.ink3),
                ),
                const SizedBox(height: 16),
                Text('TOKENS TO REVERSE', style: _TS.label(c: _DS.ink3)),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [1, 2, 3, 5, 10].map((q) {
                    final sel = reverseQtyCtrl.text == q.toString();
                    return GestureDetector(
                      onTap: () => setS(() => reverseQtyCtrl.text = q.toString()),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: sel ? _DS.red : _DS.surface2,
                          borderRadius: BorderRadius.circular(_DS.r12),
                        ),
                        child: Text('$q', style: GoogleFonts.dmSans(color: sel ? Colors.white : _DS.ink, fontWeight: FontWeight.bold, fontSize: 13)),
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
                  style: GoogleFonts.dmSans(fontSize: 16, fontWeight: FontWeight.bold, color: _DS.ink),
                  decoration: InputDecoration(
                    hintText: 'Custom quantity…',
                    hintStyle: GoogleFonts.dmSans(fontSize: 13, color: _DS.ink3),
                    suffixText: '= PKR ${(qty * _pricePerToken).toStringAsFixed(0)}',
                    suffixStyle: GoogleFonts.dmSans(color: _DS.red, fontWeight: FontWeight.bold, fontSize: 12),
                    filled: true,
                    fillColor: _DS.surface2,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(_DS.r14), borderSide: BorderSide.none),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Cancel', style: GoogleFonts.dmSans(color: _DS.ink3, fontWeight: FontWeight.w600)),
              ),
              ElevatedButton.icon(
                onPressed: (qty <= 0 || qty > localUnserved.length)
                    ? null
                    : () => Navigator.pop(ctx, qty),
                icon: const Icon(Icons.history_toggle_off_rounded, size: 18),
                label: Text('Reverse $qty Token${qty != 1 ? "s" : ""}'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _DS.red,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_DS.r14)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              ),
            ],
          );
        },
      ),
    );

    if (confirmQty == null || confirmQty <= 0) return;

    try {
      final tokensToVoid = localUnserved.take(confirmQty).toList();
      final voidIds = tokensToVoid.map((t) => t['id']?.toString() ?? t['localId']?.toString() ?? '').where((id) => id.isNotEmpty).toList();
      final Map<String, int> sessionCounts = {};

      for (final t in tokensToVoid) {
        final s = (t['session'] ?? 'lunch').toString().toLowerCase();
        sessionCounts[s] = (sessionCounts[s] ?? 0) + 1;
      }

      // ── STEP 1: Delete from Local Hive First ─────────────────────────
      try {
        final tokenBox = await _getTokensBox();
        for (final tid in voidIds) {
          await tokenBox.delete(tid);
        }
      } catch (_) {}

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
              },
            ),
          );
        } catch (_) {}
      }

      // ── STEP 3: Always Enqueue for Cloud Sync ────────────────────────
      try {
        await LocalStorageService.enqueueSync({
          'type': 'reverse_dasterkhwan_tokens',
          'branchId': _branchId,
          'dateKey': today,
          'data': {
            'branchId': _branchId,
            'dateKey': today,
            'quantity': confirmQty,
            'tokenIds': voidIds,
            'sessionCounts': sessionCounts,
          },
        });
        SyncService().triggerUpload(force: true);
      } catch (_) {}

      // ── STEP 4: Direct Firestore deletion in parallel ─────────────────
      try {
        final batch = FirebaseFirestore.instance.batch();
        for (final id in voidIds) {
          batch.delete(_tokensCol.doc(id));
        }
        final Map<String, dynamic> dayUpdate = {
          'totalTokens': FieldValue.increment(-confirmQty),
          'lastUpdated': FieldValue.serverTimestamp(),
        };
        sessionCounts.forEach((s, cnt) {
          if (cnt > 0) {
            dayUpdate['session_${s}_total'] = FieldValue.increment(-cnt);
          }
        });
        batch.set(_dayDoc, dayUpdate, SetOptions(merge: true));
        batch.commit().catchError((_) {});
      } catch (_) {}

      if (!mounted) return;
      _recalculateLocalStats();
      _showSnack('Reversed $confirmQty Token${confirmQty > 1 ? "s" : ""} · PKR ${(confirmQty * _pricePerToken).toStringAsFixed(0)} voided', isError: false);
      setState(() {});
    } catch (e) {
      _showSnack('Error reversing tokens: $e', isError: true);
    }
  }

  void _showSnack(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        Container(
          width: 26, height: 26,
          decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15), shape: BoxShape.circle),
          child: Icon(
            isError ? Icons.close_rounded : Icons.check_rounded,
            color: Colors.white, size: 14,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(msg,
              style: GoogleFonts.dmSans(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  color: Colors.white)),
        ),
      ]),
      backgroundColor: isError ? _DS.red : _DS.sage,
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      duration: const Duration(seconds: 3),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_DS.r14)),
    ));
  }

  Future<void> _backfillUnsyncedTokens() async {
    try {
      if (_branchId == null || _branchId!.isEmpty) return;
      final box = await _getTokensBox();
      final unsynced = <Map<String, dynamic>>[];
      for (final raw in box.values) {
        if (raw is Map) {
          final t = Map<String, dynamic>.from(raw);
          final tBranch = (t['branchId']?.toString() ?? '').toLowerCase().trim();
          if (tBranch.isNotEmpty && tBranch != _branchId!.toLowerCase().trim()) continue;
          if (t['synced'] != true && t['syncStatus'] != 'synced') {
            unsynced.add(t);
          }
        }
      }
      if (unsynced.isNotEmpty) {
        debugPrint('[OfficeBoy] Found ${unsynced.length} unsynced tokens. Enqueuing to sync queue...');
        final byDate = <String, List<Map<String, dynamic>>>{};
        for (final t in unsynced) {
          final dk = (t['dateKey']?.toString() ?? today).trim();
          byDate.putIfAbsent(dk, () => []).add(t);
        }
        for (final entry in byDate.entries) {
          await LocalStorageService.enqueueSync({
            'type': 'save_dasterkhwan_tokens',
            'branchId': _branchId,
            'dateKey': entry.key,
            'data': {
              'branchId': _branchId,
              'dateKey': entry.key,
              'quantity': entry.value.length,
              'tokens': entry.value,
              'issuedBy': _effectiveUserName,
              'pricePerToken': _pricePerToken,
            },
          });
        }
        SyncService().triggerUpload(force: true);
      }
    } catch (e) {
      debugPrint('[OfficeBoy] Token backfill error: $e');
    }
  }

  Future<void> _refresh() async {
    _recalculateLocalStats();
    if (_branchId != null) {
      await _backfillUnsyncedTokens();
      SyncService().triggerUpload(force: true);
      try {
        await DonationsLocalStorage.downloadAllDonations(_branchId!);
        await DonationsLocalStorage.downloadDonors(_branchId!);
      } catch (_) {}
    }
    if (mounted) {
      setState(() {});
      _showSnack('Refreshed data & checked cloud sync', isError: false);
    }
  }

  Widget _buildPersistentHeader(BuildContext context) {
    final activeData = LocalStorageService.getActiveUserData();
    final branchName = activeData['branchName'] as String? ?? 'Gujrat';
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF161B22) : _DS.sage,
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 4,
            offset: Offset(0, 2),
          ),
        ],
        border: Border(
          bottom: BorderSide(
            color: isDark ? const Color(0xFF30363D) : Colors.transparent,
            width: 1,
          ),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.asset(
                  'assets/logo/gmwf-1.webp',
                  width: 36,
                  height: 36,
                  fit: BoxFit.contain,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          'GMWF Dasterkhwaan',
                          style: GoogleFonts.dmSans(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.3,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: _DS.mint.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: _DS.mint.withValues(alpha: 0.4), width: 0.5),
                        ),
                        child: Text(
                          branchName,
                          style: GoogleFonts.dmSans(
                            color: _DS.mint,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _effectiveUserName,
                    style: GoogleFonts.dmSans(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (MediaQuery.of(context).size.width >= 380) ...[
              _RefreshHeaderButton(onTap: _refresh),
              const SizedBox(width: 6),
            ],
            _SettingsButton(onTap: _openSettings),
            const SizedBox(width: 6),
            _LogoutButton(onTap: _logout),
          ],
        ),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final showDonations = _isOfficeBoy;
    final activeNav = showDonations ? _currentNav.clamp(0, 5) : _currentNav.clamp(0, 2);

    return ValueListenableBuilder(
      valueListenable: Hive.box('app_settings').listenable(keys: ['is_dark_mode', 'custom_accent_color']),
      builder: (context, Box box, child) {
        final isDark = box.get('is_dark_mode', defaultValue: false) == true;

        final views = [
          _HomeScreen(
            userName:        _effectiveUserName,
            role:            widget.role,
            branchId:        _branchId,
            today:           today,
            todayStats:      _stats,
            onGoTokens:      () => _goToTab(1),
            onGoDonation:    () => _goToTab(2),
            onGoDonors:      () => _goToTab(3),
            onGoBoxes:       () => _goToTab(4),
            onGoHistory:     () => _goToTab(showDonations ? 5 : 2),
            onLogout:        _logout,
            onSettings:      _openSettings,
            onRefresh:       _refresh,
            heroFade:        _fadeAnim,
            pricePerToken:   _pricePerToken,
            isOfficeBoy:     showDonations,
          ),
          _TokensScreen(
            userName:           _effectiveUserName,
            branchId:           _branchId,
            today:              today,
            displayFormat:      _displayFmt,
            quantityController: _qtyCtrl,
            pricePerToken:      _pricePerToken,
            selectedSession:    _selectedSession,
            onSessionChanged:   (s) => setState(() => _selectedSession = s),
            onGenerate:         _generateTokens,
            onReverse:          _showReverseTokensDialog,
            pulseAnim:          _pulseAnim,
            todayStats:         _stats,
            onLogout:           _logout,
            onSettings:         _openSettings,
            showLogout:         showDonations,
            onSelectQty: (qty) {
              _qtyCtrl.text = qty.toString();
              setState(() {});
            },
          ),
          if (showDonations) ...[
            // 2 – Donations
            _branchId == null
                ? const GmwfLoadingView()
                : DonationsScreen.embedded(
                    branchId: _branchId!,
                    username: _effectiveUserName,
                    userId:   _effectiveUserId,
                    role:     UserRole.officeBoy,
                  ),
            // 3 – Donors
            _branchId == null
                ? const GmwfLoadingView()
                : DonorRegistryWidget(
                    branchId:   _branchId!,
                    branchName: (LocalStorageService.getActiveUserData()['branchName'] as String?) ?? 'Gujrat',
                  ),
            // 4 – Donation Boxes
            _branchId == null
                ? const GmwfLoadingView()
                : DonationBoxesWidget(
                    branchId:   _branchId!,
                    branchName: 'Dasterkhwaan',
                    username:   _effectiveUserName,
                    role:       UserRole.officeBoy,
                  ),
          ],
          // 5 (or 2 for non-office-boy) – History (always last)
          _branchId == null
              ? const GmwfLoadingView()
              : _HistoryScreen(
                  branchId:      _branchId!,
                  dateFmt:       _dateFmt,
                  onLogout:      _logout,
                  onSettings:    _openSettings,
                  showLogout:    showDonations,
                  pricePerToken: _pricePerToken,
                  username:      _effectiveUserName,
                ),
        ];

        return RoleThemeScope(
          role: RoleTheme.supervisor,
          child: Theme(
            data: isDark
                ? ThemeData.dark().copyWith(
                    scaffoldBackgroundColor: const Color(0xFF0F172A),
                    cardColor: const Color(0xFF1E293B),
                    colorScheme: const ColorScheme.dark(
                      primary: _DS.mint,
                      surface: Color(0xFF1E293B),
                    ),
                  )
                : ThemeData.light().copyWith(
                    scaffoldBackgroundColor: const Color(0xFFF4F7F6),
                    cardColor: Colors.white,
                    colorScheme: const ColorScheme.light(
                      primary: _DS.sage,
                      surface: Colors.white,
                    ),
                  ),
            child: Scaffold(
              backgroundColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF4F7F6),
              body: Column(
                children: [
                  _buildPersistentHeader(context),
                  Expanded(
                    child: PageView(
                      controller: _pageController,
                      physics: const BouncingScrollPhysics(),
                      onPageChanged: (idx) => setState(() => _currentNav = idx),
                      children: views,
                    ),
                  ),
                ],
              ),
              bottomNavigationBar: _buildBottomNav(
                showDonations: showDonations,
                currentIndex: activeNav,
                isDark: isDark,
              ),
            ),
          ),
        );
      },
    );
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
          _userName = refreshed['name'] as String? ?? refreshed['username'] as String? ?? _userName;
        });
      }
    });
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign Out'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign Out', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await AuthService().signOut();
    } catch (e) {
      debugPrint('[DasterkhwaanOfficeBoy] Sign out error: $e');
    }
    if (mounted) {
      Navigator.pushNamedAndRemoveUntil(context, '/login', (_) => false);
    }
  }

  Widget _buildBottomNav({
    required bool showDonations,
    required int currentIndex,
    required bool isDark,
  }) {
    final labels = showDonations
        ? ['Home', 'Tokens', 'Donations', 'Donors', 'Boxes', 'History']
        : ['Home', 'Tokens', 'History'];
    final icons = showDonations
        ? [
            Icons.home_rounded,
            Icons.confirmation_number_rounded,
            Icons.volunteer_activism_rounded,
            Icons.people_alt_rounded,
            Icons.inventory_2_rounded,
            Icons.history_rounded,
          ]
        : [
            Icons.home_rounded,
            Icons.confirmation_number_rounded,
            Icons.history_rounded,
          ];

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF161B22) : Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.05),
            blurRadius: 14,
            offset: const Offset(0, -2),
          ),
        ],
        border: Border(
          top: BorderSide(
            color: isDark ? const Color(0xFF30363D) : _DS.border,
            width: 1,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: List.generate(labels.length, (idx) {
              final sel = currentIndex == idx;
              return GestureDetector(
                onTap: () => _goToTab(idx),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: sel
                        ? (isDark ? _DS.mint.withValues(alpha: 0.20) : _DS.sage)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(_DS.r14),
                    border: sel && isDark
                        ? Border.all(color: _DS.mint.withValues(alpha: 0.35), width: 0.8)
                        : null,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        icons[idx],
                        size: 18,
                        color: sel
                            ? (isDark ? _DS.mint : Colors.white)
                            : (isDark ? const Color(0xFF8B949E) : _DS.ink3),
                      ),
                      if (sel) ...[
                        const SizedBox(width: 4),
                        Text(
                          labels[idx],
                          style: GoogleFonts.dmSans(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: isDark ? _DS.mint : Colors.white,
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

class _HomeScreen extends StatelessWidget {
  final String userName;
  final String? role;
  final String? branchId;
  final String today;
  final Map<String, dynamic> todayStats;
  final VoidCallback onGoTokens, onGoHistory, onGoDonation, onLogout, onSettings;
  final Future<void> Function()? onRefresh;
  final VoidCallback? onGoBoxes, onGoDonors;
  final Animation<double> heroFade;
  final double pricePerToken;
  final bool isOfficeBoy;

  const _HomeScreen({
    required this.userName,
    this.role,
    required this.branchId,
    required this.today,
    required this.todayStats,
    required this.onGoTokens,
    required this.onGoHistory,
    required this.onGoDonation,
    this.onGoDonors,
    this.onGoBoxes,
    required this.onLogout,
    required this.onSettings,
    this.onRefresh,
    required this.heroFade,
    required this.pricePerToken,
    this.isOfficeBoy = true,
  });

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning,';
    if (h < 17) return 'Good afternoon,';
    return 'Good evening,';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activeData = LocalStorageService.getActiveUserData();
    final branchName = activeData['branchName'] as String? ?? 'Gujrat';

    final total  = todayStats['total'] as int? ?? 0;
    final served = todayStats['served'] as int? ?? 0;
    final pending = total - served;
    final revenue = total * pricePerToken;
    final donCount = todayStats['donations'] as int? ?? 0;
    final donAmount = (todayStats['donationAmount'] as num? ?? 0.0).toDouble();

    return FadeTransition(
      opacity: heroFade,
      child: RefreshIndicator(
        onRefresh: onRefresh ?? () async {},
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            // ── 1. Hero Header (Supervisor Theme & Layout) ───────────────────────
            SliverToBoxAdapter(
              child: _HeroHeader(
                greeting:   _greeting(),
                userName:   userName,
                branchName: branchName,
                onLogout:   onLogout,
                onSettings: onSettings,
                onRefresh:  onRefresh,
                badgeLabel: isOfficeBoy ? 'Office Boy' : (role ?? 'Staff'),
                showLogout: isOfficeBoy,
              ),
            ),

            // ── 2. Today's KPI Metric Cards ─────────────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Row(
                  children: [
                    _StatChip(
                      value: '$total',
                      label: 'Issued',
                      color: _DS.mint,
                      icon: Icons.confirmation_number_rounded,
                      isDark: isDark,
                    ),
                    const SizedBox(width: 8),
                    _StatChip(
                      value: '$pending',
                      label: 'Pending',
                      color: _DS.amber,
                      icon: Icons.hourglass_top_rounded,
                      isDark: isDark,
                    ),
                    const SizedBox(width: 8),
                    _StatChip(
                      value: '$served',
                      label: 'Served',
                      color: _DS.green,
                      icon: Icons.check_circle_rounded,
                      isDark: isDark,
                    ),
                  ],
                ),
              ),
            ),

            // ── 3. Revenue Band (Fintech Glass Scheme) ───────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: _RevenueBand(
                  revenue: revenue,
                  pricePerToken: pricePerToken,
                  isDark: isDark,
                ),
              ),
            ),

            // ── 4. Today's Donation Summary (Office Boy) ────────────────────────
            if (isOfficeBoy)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                sliver: SliverToBoxAdapter(
                  child: _DonationSummaryCard(
                    count: donCount,
                    amount: donAmount,
                    isDark: isDark,
                  ),
                ),
              ),

            // ── 5. Quick Actions (Supervisor Module Layout) ──────────────────────
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SectionLabel('Dasterkhwaan Modules', isDark: isDark),
                    const SizedBox(height: 10),
                    _ActionCardWide(
                      icon:      Icons.confirmation_number_rounded,
                      iconColor: _DS.mint,
                      iconBg:    _DS.mintBg,
                      title:     'Issue Meal Tokens',
                      subtitle:  'Select session & generate guest tokens',
                      urdu:      'کھانے کا ٹوکن جاری کریں',
                      onTap:     onGoTokens,
                      isDark:    isDark,
                    ),
                    if (isOfficeBoy) ...[
                      const SizedBox(height: 10),
                      _ActionCardWide(
                        icon:      Icons.volunteer_activism_rounded,
                        iconColor: _DS.amber,
                        iconBg:    _DS.amberBg,
                        title:     'Record Donation',
                        subtitle:  'Collect & log charitable contributions',
                        urdu:      'عطیہ جمع کریں',
                        onTap:     onGoDonation,
                        isDark:    isDark,
                      ),
                      const SizedBox(height: 10),
                      _ActionCardWide(
                        icon:      Icons.people_alt_rounded,
                        iconColor: const Color(0xFF2563EB),
                        iconBg:    const Color(0xFFEFF6FF),
                        title:     'Donors Registry',
                        subtitle:  'Search database & historic donors',
                        urdu:      'رجسٹرڈ ڈونرز کی فہرست',
                        onTap:     onGoDonors ?? () {},
                        isDark:    isDark,
                      ),
                      const SizedBox(height: 10),
                      _ActionCardWide(
                        icon:      Icons.inventory_2_rounded,
                        iconColor: const Color(0xFF0D9488),
                        iconBg:    const Color(0xFFCCFBF1),
                        title:     'Donation Boxes',
                        subtitle:  'Track & open charity collection boxes',
                        urdu:      'ڈبہ جات کا ریکارڈ',
                        onTap:     onGoBoxes ?? () {},
                        isDark:    isDark,
                      ),
                    ],
                    const SizedBox(height: 10),
                    _ActionCardWide(
                      icon:      Icons.history_rounded,
                      iconColor: _DS.purple,
                      iconBg:    _DS.purpleBg,
                      title:     'History & Analytics',
                      subtitle:  'Daily tokens, revenue & audit trail',
                      urdu:      'روزانہ اور ماہانہ ریکارڈ',
                      onTap:     onGoHistory,
                      isDark:    isDark,
                    ),
                  ],
                ),
              ),
            ),

            const SliverToBoxAdapter(child: SizedBox(height: 36)),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// HERO HEADER (SUPERVISOR STYLE SCHEME)
// ═══════════════════════════════════════════════════════════════════════════

class _HeroHeader extends StatelessWidget {
  final String greeting;
  final String userName;
  final String branchName;
  final VoidCallback? onLogout;
  final VoidCallback? onSettings;
  final Future<void> Function()? onRefresh;
  final String badgeLabel;
  final bool showLogout;

  const _HeroHeader({
    required this.greeting,
    required this.userName,
    this.branchName = 'Karachi',
    this.onLogout,
    this.onSettings,
    this.onRefresh,
    required this.badgeLabel,
    this.showLogout = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_DS.sage, _DS.sage2],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            // Ambient Decorative Glow
            Positioned(
              top: -40,
              right: -20,
              child: Container(
                width: 160,
                height: 160,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _DS.mint.withValues(alpha: 0.08),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _UserAvatar(userName: userName, onTap: onSettings ?? () {}),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              greeting,
                              style: GoogleFonts.dmSans(
                                color: Colors.white.withValues(alpha: 0.60),
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              userName,
                              style: GoogleFonts.dmSerifDisplay(
                                color: Colors.white,
                                fontSize: 24,
                                height: 1.15,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      // Role Pill
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(
                          color: _DS.mint.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(_DS.rPill),
                          border: Border.all(color: _DS.mint.withValues(alpha: 0.35), width: 0.8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: _DS.mint,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              badgeLabel.toUpperCase(),
                              style: GoogleFonts.dmSans(
                                color: _DS.mint,
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Branch Pill
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(_DS.rPill),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.20), width: 0.8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.storefront_rounded, color: Colors.white70, size: 12),
                            const SizedBox(width: 4),
                            Text(
                              branchName,
                              style: GoogleFonts.dmSans(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),
                      // Date
                      Text(
                        DateFormat('EEE, dd MMM yyyy').format(DateTime.now()),
                        style: GoogleFonts.dmSans(
                          color: Colors.white.withValues(alpha: 0.50),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
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
    );
  }
}

// ─── Refresh Button ────────────────────────────────────────────────────────
class _RefreshHeaderButton extends StatelessWidget {
  final VoidCallback onTap;
  const _RefreshHeaderButton({required this.onTap});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'Refresh',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(_DS.r12),
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(_DS.r12),
              border: Border.all(
                  color: Colors.white.withValues(alpha: 0.22), width: 0.5),
            ),
            child: const Center(
              child: Icon(Icons.refresh_rounded, color: Colors.white, size: 18),
            ),
          ),
        ),
      );
}

// ─── Settings Button ────────────────────────────────────────────────────────
class _SettingsButton extends StatelessWidget {
  final VoidCallback onTap;
  const _SettingsButton({required this.onTap});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'Settings',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(_DS.r12),
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(_DS.r12),
              border: Border.all(
                  color: Colors.white.withValues(alpha: 0.22), width: 0.5),
            ),
            child: const Center(
              child: Icon(Icons.settings_outlined, color: Colors.white, size: 18),
            ),
          ),
        ),
      );
}

// ─── Logout Button ──────────────────────────────────────────────────────────
class _LogoutButton extends StatelessWidget {
  final VoidCallback onTap;
  const _LogoutButton({required this.onTap});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'Logout',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(_DS.r12),
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(_DS.r12),
              border: Border.all(
                  color: Colors.red.withValues(alpha: 0.35), width: 0.5),
            ),
            child: const Center(
              child: Icon(Icons.logout_rounded, color: Color(0xFFFCA5A5), size: 18),
            ),
          ),
        ),
      );
}

// ─── User Avatar ─────────────────────────────────────────────────────────────
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
          imageProvider = MemoryImage(base64Decode(cleanBase64));
        } catch (_) {}
      }
    }

    final initial = userName.trim().isNotEmpty ? userName.trim()[0].toUpperCase() : 'U';

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 50,
        height: 50,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: 0.35), width: 2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 8,
              offset: const Offset(0, 3),
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
        color: Colors.white.withValues(alpha: 0.20),
        alignment: Alignment.center,
        child: Text(
          initial,
          style: GoogleFonts.dmSans(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 20,
          ),
        ),
      );
}

// ─── Stat Chip ───────────────────────────────────────────────────────────────

class _StatChip extends StatelessWidget {
  final String value, label;
  final Color color;
  final IconData icon;
  final bool isDark;

  const _StatChip({
    required this.value,
    required this.label,
    required this.color,
    required this.icon,
    this.isDark = false,
  });

  @override
  Widget build(BuildContext context) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E293B) : Colors.white,
            borderRadius: BorderRadius.circular(_DS.r16),
            border: Border.all(
              color: isDark ? const Color(0xFF334155) : _DS.border,
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.03),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: isDark ? 0.20 : 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(icon, color: color, size: 14),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    value,
                    style: GoogleFonts.dmSans(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: color,
                      height: 1.0,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                label.toUpperCase(),
                style: GoogleFonts.dmSans(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  color: isDark ? const Color(0xFF94A3B8) : _DS.ink3,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      );
}

class _DonationSummaryCard extends StatelessWidget {
  final int count;
  final double amount;
  final bool isDark;

  const _DonationSummaryCard({
    required this.count,
    required this.amount,
    this.isDark = false,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E293B) : Colors.white,
          borderRadius: BorderRadius.circular(_DS.r22),
          border: Border.all(
            color: isDark ? const Color(0xFF334155) : _DS.border,
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.03),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: _DS.amber.withValues(alpha: isDark ? 0.20 : 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.volunteer_activism_rounded, color: _DS.amber, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Today's Donations",
                    style: GoogleFonts.dmSans(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: isDark ? Colors.white : _DS.ink,
                    ),
                  ),
                  Text(
                    '$count contributions recorded',
                    style: GoogleFonts.dmSans(
                      fontSize: 11,
                      color: isDark ? const Color(0xFF94A3B8) : _DS.ink3,
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  'PKR ${amount.toStringAsFixed(0)}',
                  style: GoogleFonts.dmSerifDisplay(
                    fontSize: 19,
                    color: _DS.amber,
                  ),
                ),
                Text(
                  'TOTAL COLLECTED',
                  style: GoogleFonts.dmSans(
                    fontSize: 8,
                    fontWeight: FontWeight.w800,
                    color: _DS.amber.withValues(alpha: 0.8),
                    letterSpacing: 0.4,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
}

// ─── Revenue Band ─────────────────────────────────────────────────────────────

class _RevenueBand extends StatelessWidget {
  final double revenue, pricePerToken;
  final bool isDark;

  const _RevenueBand({
    required this.revenue,
    required this.pricePerToken,
    this.isDark = false,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: isDark
                ? const [Color(0xFF132A24), Color(0xFF1E3D35)]
                : const [_DS.sage, _DS.sage2],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(_DS.r22),
          border: isDark
              ? Border.all(color: _DS.mint.withValues(alpha: 0.25), width: 1)
              : null,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Stack(
          children: [
            Positioned(
              top: -24,
              right: -16,
              child: Container(
                width: 90,
                height: 90,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _DS.mint.withValues(alpha: 0.08),
                ),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Today's Food Revenue",
                      style: GoogleFonts.dmSans(
                        color: Colors.white.withValues(alpha: 0.65),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'PKR ${revenue.toStringAsFixed(0)}',
                      style: GoogleFonts.dmSerifDisplay(
                        color: Colors.white,
                        fontSize: 24,
                      ),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: _DS.mint.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(_DS.rPill),
                    border: Border.all(
                      color: _DS.mint.withValues(alpha: 0.35),
                      width: 0.8,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.toll_rounded, color: _DS.mint, size: 13),
                      const SizedBox(width: 5),
                      Text(
                        'PKR ${pricePerToken.toInt()} / token',
                        style: GoogleFonts.dmSans(
                          color: _DS.mint,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      );
}

// ─── Section Label ────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  final bool isDark;

  const _SectionLabel(this.text, {this.isDark = false});

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: GoogleFonts.dmSans(
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.2,
          color: isDark ? const Color(0xFF94A3B8) : _DS.ink3,
        ),
      );
}

// ─── Action Card Wide ─────────────────────────────────────────────────────────

class _ActionCardWide extends StatelessWidget {
  final IconData icon;
  final Color iconColor, iconBg;
  final String title, subtitle, urdu;
  final VoidCallback onTap;
  final bool isDark;

  const _ActionCardWide({
    required this.icon,
    required this.iconColor,
    required this.iconBg,
    required this.title,
    required this.subtitle,
    required this.urdu,
    required this.onTap,
    this.isDark = false,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E293B) : Colors.white,
            borderRadius: BorderRadius.circular(_DS.r22),
            border: Border.all(
              color: isDark ? const Color(0xFF334155) : _DS.border,
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.03),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: isDark ? iconColor.withValues(alpha: 0.18) : iconBg,
                  borderRadius: BorderRadius.circular(_DS.r14),
                ),
                child: Icon(icon, color: iconColor, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: GoogleFonts.dmSans(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: isDark ? Colors.white : _DS.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: GoogleFonts.dmSans(
                        fontSize: 11,
                        color: isDark ? const Color(0xFF94A3B8) : _DS.ink3,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    urdu,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: isDark ? const Color(0xFF64748B) : _DS.ink3,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 16,
                    color: isDark ? const Color(0xFF64748B) : _DS.ink3,
                  ),
                ],
              ),
            ],
          ),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// SCREEN 1: ISSUE FOOD TOKENS
// ─────────────────────────────────────────────────────────────────────────────

class _TokensScreen extends StatefulWidget {
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

  const _TokensScreen({
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
  });

  @override
  State<_TokensScreen> createState() => _TokensScreenState();
}

class _TokensScreenState extends State<_TokensScreen> {
  String _feedFilter = 'all';
  late Future<Box> _tokensBoxFuture;

  @override
  void initState() {
    super.initState();
    _tokensBoxFuture = LocalStorageService.openBoxSafe('dasterkhwaan_tokens');
  }

  Map<String, ({String title, String shortTitle, String urdu, IconData icon, Color color, Color bg, List<Color> gradient})> get _sessionMeta => {
    'breakfast': (
      title: 'Breakfast (ناشتہ)',
      shortTitle: 'Breakfast',
      urdu: 'ناشتہ کا دسترخوان',
      icon: Icons.wb_sunny_rounded,
      color: const Color(0xFFD97706),
      bg: const Color(0xFFFFFBEB),
      gradient: const [Color(0xFFB45309), Color(0xFFD97706)],
    ),
    'lunch': (
      title: 'Lunch (دوپہر)',
      shortTitle: 'Lunch',
      urdu: 'دوپہر کا دسترخوان',
      icon: Icons.sunny,
      color: const Color(0xFF0D9488),
      bg: const Color(0xFFE6FDF8),
      gradient: const [Color(0xFF0F766E), Color(0xFF0D9488)],
    ),
    'dinner': (
      title: 'Dinner (رات)',
      shortTitle: 'Dinner',
      urdu: 'رات کا دسترخوان',
      icon: Icons.nightlight_round,
      color: const Color(0xFF4F46E5),
      bg: const Color(0xFFEEF2FF),
      gradient: const [Color(0xFF3730A3), Color(0xFF4F46E5)],
    ),
  };

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final qty = int.tryParse(widget.quantityController.text) ?? 1;
    final currentKey = widget.selectedSession.toLowerCase();
    final meta = _sessionMeta[currentKey] ?? _sessionMeta['dinner']!;
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
                const SizedBox(height: 22),

                // 2. Quantity Selection
                _buildQuantitySection(context, qty),
                const SizedBox(height: 24),

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
                        splashColor: Colors.white.withValues(alpha: 0.15),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                width: 34,
                                height: 34,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.18),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  meta.icon,
                                  size: 18,
                                  color: Colors.white,
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
                                      style: GoogleFonts.dmSans(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.white,
                                        letterSpacing: -0.2,
                                      ),
                                    ),
                                    Text(
                                      'PKR ${(qty * widget.pricePerToken).toStringAsFixed(0)} · ${_sessionUrdu(widget.selectedSession)}',
                                      style: GoogleFonts.dmSans(
                                        fontSize: 11,
                                        color: Colors.white.withValues(alpha: 0.85),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 20),
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
                const SizedBox(height: 28),

                // 5. Live Feed of Today's Tokens
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
              ? const [Color(0xFF0F2620), Color(0xFF1E3D35), Color(0xFF162E27)]
              : const [Color(0xFF143029), Color(0xFF1E433A), Color(0xFF1A3830)],
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
                // Title + Price Tag
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
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
                                      color: Colors.white,
                                      fontSize: 22,
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
                              style: GoogleFonts.dmSans(
                                color: Colors.white.withValues(alpha: 0.55),
                                fontSize: 11.5,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
                        ),
                        child: Text(
                          'PKR ${widget.pricePerToken.toInt()} / token',
                          style: GoogleFonts.dmSans(
                            color: const Color(0xFF80DEEA),
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Dynamic Meal Sessions Segmented Switcher
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                    ),
                    child: Row(
                      children: sessionsToRender.map((sKey) {
                        final sConf = conf[sKey] as Map? ?? {};
                        final openT = sConf['openTime']?.toString() ?? '';
                        final closeT = sConf['closeTime']?.toString() ?? '';
                        final timingStr = (openT.isNotEmpty && closeT.isNotEmpty)
                            ? '$openT - $closeT'
                            : (sKey == 'breakfast'
                                ? '07:00 AM - 11:30 AM'
                                : (sKey == 'lunch' ? '12:00 PM - 04:30 PM' : '05:00 PM - 11:59 PM'));

                        final meta = _sessionMeta[sKey] ?? _sessionMeta['dinner']!;

                        return Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: _buildSessionTab(
                              id: sKey,
                              title: meta.title,
                              timingSubtitle: timingStr,
                              icon: meta.icon,
                              activeGradient: meta.gradient,
                              activeShadow: meta.color,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Multi-Session Analytics Strip
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.07),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.12),
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
                                  color: Colors.white.withValues(alpha: 0.15),
                                ),
                              Expanded(
                                child: Builder(
                                  builder: (_) {
                                    final sKey = sessionsToRender[idx];
                                    final sTotal = widget.todayStats['${sKey}Total'] ?? 0;
                                    final sServed = widget.todayStats['${sKey}Served'] ?? 0;
                                    final meta = _sessionMeta[sKey] ?? _sessionMeta['dinner']!;
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
                        Divider(color: Colors.white.withValues(alpha: 0.1), height: 1),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.receipt_long_rounded,
                                    size: 13, color: Color(0xFF80DEEA)),
                                const SizedBox(width: 5),
                                Text(
                                  'Combined: $total Issued · ${total - served} Pending',
                                  style: GoogleFonts.dmSans(
                                    fontSize: 11,
                                    color: Colors.white.withValues(alpha: 0.75),
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                            Text(
                              'PKR ${(total * widget.pricePerToken).toStringAsFixed(0)}',
                              style: GoogleFonts.dmSans(
                                fontSize: 12,
                                color: const Color(0xFFA7F3D0),
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
    final active = widget.selectedSession.toLowerCase() == id.toLowerCase();
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
                  color: active ? Colors.white : Colors.white.withValues(alpha: 0.6),
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    title,
                    style: GoogleFonts.dmSans(
                      fontSize: 11.5,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                      color: active ? Colors.white : Colors.white.withValues(alpha: 0.7),
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
                style: GoogleFonts.dmSans(
                  fontSize: 9.5,
                  fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                  color: active ? Colors.white.withValues(alpha: 0.9) : Colors.white.withValues(alpha: 0.45),
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
          style: GoogleFonts.dmSans(
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
              style: GoogleFonts.dmSans(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 3),
            Text(
              'issued',
              style: GoogleFonts.dmSans(
                fontSize: 9.5,
                color: Colors.white.withValues(alpha: 0.4),
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '$pending wait',
                style: GoogleFonts.dmSans(
                  fontSize: 8.5,
                  fontWeight: FontWeight.w700,
                  color: Colors.amberAccent,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ── Tactile Meal Voucher Preview ───────────────────────────────────────────
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
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: meta.color.withValues(alpha: isDark ? 0.15 : 0.08),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
        border: Border.all(color: _DS.getBorder(isDark), width: 1),
      ),
      child: Column(
        children: [
          // Top portion of voucher
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: isDark ? meta.color.withValues(alpha: 0.15) : meta.bg,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            meta.icon,
                            size: 16,
                            color: meta.color,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'GULAB MEHMOOD WELFARE',
                              style: GoogleFonts.dmSans(
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.8,
                                color: _DS.getInk3(isDark),
                              ),
                            ),
                            Text(
                              'Dasterkhwaan Meal Voucher',
                              style: GoogleFonts.dmSans(
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
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: isDark ? meta.color.withValues(alpha: 0.15) : meta.bg,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: meta.color.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: meta.color,
                            ),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            '${meta.shortTitle.toUpperCase()} SESSION',
                            style: GoogleFonts.dmSans(
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              color: meta.color,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'NEXT IN QUEUE',
                          style: GoogleFonts.dmSans(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: _DS.getInk3(isDark),
                            letterSpacing: 0.6,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          rangeText,
                          style: GoogleFonts.dmSans(
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                            color: _DS.getInk(isDark),
                            letterSpacing: -0.5,
                          ),
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: _DS.getSurface2(isDark),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '$qty Meal${qty > 1 ? "s" : ""}',
                        style: GoogleFonts.dmSans(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: _DS.getInk2(isDark),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Perforated divider with circular punch cutouts
          _buildPerforatedDivider(context),

          // Bottom stub of voucher
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.confirmation_num_outlined, size: 16, color: _DS.getInk3(isDark)),
                    const SizedBox(width: 6),
                    Text(
                      '$qty × PKR ${widget.pricePerToken.toInt()} = ',
                      style: GoogleFonts.dmSans(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _DS.getInk3(isDark),
                      ),
                    ),
                    Text(
                      'PKR $totalPKR',
                      style: GoogleFonts.dmSans(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: meta.color,
                      ),
                    ),
                  ],
                ),
                // Barcode simulation lines
                Row(
                  children: [1, 3, 2, 4, 1, 3, 2, 1, 3].map((w) {
                    return Container(
                      margin: const EdgeInsets.only(left: 2),
                      width: w.toDouble(),
                      height: 18,
                      color: _DS.getBorder2(isDark),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPerforatedDivider(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      height: 20,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Dashed line
          Positioned(
            left: 16,
            right: 16,
            child: CustomPaint(
              size: const Size(double.infinity, 1),
              painter: _DashedLinePainter(color: _DS.getBorder2(isDark)),
            ),
          ),
          // Left cutout
          Positioned(
            left: -10,
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: _DS.getBg(isDark),
                shape: BoxShape.circle,
                border: Border.all(color: _DS.getBorder(isDark), width: 1),
              ),
            ),
          ),
          // Right cutout
          Positioned(
            right: -10,
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: _DS.getBg(isDark),
                shape: BoxShape.circle,
                border: Border.all(color: _DS.getBorder(isDark), width: 1),
              ),
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
              style: GoogleFonts.dmSans(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: _DS.mint,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Tactile Stepper Box
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: _DS.getSurface(isDark),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _DS.getBorder(isDark)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.02),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Minus button
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

              // Value display with meal counter
              Column(
                children: [
                  Text(
                    '$currentQty',
                    style: GoogleFonts.dmSans(
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      color: _DS.getInk(isDark),
                      letterSpacing: -1,
                    ),
                  ),
                  Text(
                    '${currentQty == 1 ? "1 Meal" : "$currentQty Meals"} · PKR ${(currentQty * widget.pricePerToken).toStringAsFixed(0)}',
                    style: GoogleFonts.dmSans(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: _DS.mint,
                    ),
                  ),
                ],
              ),

              // Plus button
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
        const SizedBox(height: 14),

        // Quick Presets Pills
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
                      style: GoogleFonts.dmSans(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: selected ? (isDark ? const Color(0xFF0F172A) : Colors.white) : _DS.getInk(isDark),
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 14),

        // Custom Quantity Input Box
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
            style: GoogleFonts.dmSans(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: _DS.getInk(isDark),
            ),
            decoration: InputDecoration(
              prefixIcon: Icon(Icons.dialpad_rounded, color: _DS.getInk3(isDark), size: 20),
              suffixText: '= PKR ${(currentQty * widget.pricePerToken).toStringAsFixed(0)}',
              suffixStyle: GoogleFonts.dmSans(
                color: _DS.mint,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
              hintText: 'Enter custom token quantity…',
              hintStyle: GoogleFonts.dmSans(fontSize: 13, color: _DS.getInk3(isDark)),
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
                  style: GoogleFonts.dmSans(fontSize: 11, color: _DS.getInk3(isDark)),
                ),
              ],
            ),
            // Filter Pills
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: [
                  _filterChip('all', 'All', isDark),
                  ...sessionsToRender.map((sKey) {
                    final meta = _sessionMeta[sKey] ?? _sessionMeta['dinner']!;
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
          future: Hive.isBoxOpen('dasterkhwaan_tokens') ? Future.value(Hive.box('dasterkhwaan_tokens')) : _tokensBoxFuture,
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
              valueListenable: box.listenable(),
              builder: (ctx, Box box, _) {
                final List<Map<String, dynamic>> tokenList = [];
                for (final raw in box.values) {
                  if (raw is Map) {
                    final t = Map<String, dynamic>.from(raw);
                    if (t['dateKey'] == widget.today && t['branchId'] == widget.branchId) {
                      String rawSession = (t['session'] as String? ?? 'lunch').toLowerCase();
                      if (rawSession == 'evening' || rawSession == 'night') {
                        rawSession = 'dinner';
                      } else if (rawSession == 'morning') {
                        rawSession = 'lunch';
                      }
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
                          style: GoogleFonts.dmSans(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: _DS.getInk(isDark),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Select session and quantity above to issue tickets',
                          style: GoogleFonts.dmSans(
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
                    final meta = _sessionMeta[session] ?? _sessionMeta['dinner']!;

                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: _DS.getSurface(isDark),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: _DS.getBorder(isDark)),
                      ),
                      child: Row(
                        children: [
                          // Token Number Pill
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
                                style: GoogleFonts.dmSans(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                  color: meta.color,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),

                          // Session and time
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      meta.icon,
                                      size: 12,
                                      color: meta.color,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      '${meta.shortTitle} Session (${_sessionUrdu(session)})',
                                      style: GoogleFonts.dmSans(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: _DS.getInk(isDark),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  time != null
                                      ? DateFormat('hh:mm a').format(time)
                                      : 'Today',
                                  style: GoogleFonts.dmSans(
                                    fontSize: 11,
                                    color: _DS.getInk3(isDark),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          // Served / Waiting status badge
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
                                  style: GoogleFonts.dmSans(
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
          style: GoogleFonts.dmSans(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: sel ? (isDark ? const Color(0xFF0F172A) : Colors.white) : _DS.getInk3(isDark),
          ),
        ),
      ),
    );
  }

  String _sessionUrdu(String session) {
    final s = session.toLowerCase();
    if (s == 'breakfast') return 'ناشتہ کا دسترخوان';
    if (s == 'lunch' || s == 'morning') return 'دوپہر کا دسترخوان';
    return 'رات کا دسترخوان';
  }
}

// ─── Perforated Dashed Line Painter ──────────────────────────────────────────

class _DashedLinePainter extends CustomPainter {
  final Color color;
  _DashedLinePainter({this.color = const Color(0xFFCBD5E1)});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    double startX = 0;
    const dashWidth = 5.0;
    const dashSpace = 4.0;
    while (startX < size.width) {
      canvas.drawLine(Offset(startX, 0), Offset(startX + dashWidth, 0), paint);
      startX += dashWidth + dashSpace;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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
                Icon(Icons.undo_rounded, size: 17, color: isDark ? const Color(0xFFF87171) : _DS.red),
                const SizedBox(width: 8),
                Text(
                  'Reverse / Void Issued Tokens',
                  style: GoogleFonts.dmSans(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: isDark ? const Color(0xFFF87171) : _DS.red,
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
// HISTORY SCREEN
// ═══════════════════════════════════════════════════════════════════════════

class _HistoryScreen extends StatefulWidget {
  final String branchId;
  final DateFormat dateFmt;
  final VoidCallback onLogout;
  final VoidCallback onSettings;
  final double pricePerToken;
  final bool showLogout;
  final String username;

  const _HistoryScreen({
    required this.branchId,
    required this.dateFmt,
    required this.onLogout,
    required this.onSettings,
    required this.pricePerToken,
    this.showLogout = true,
    this.username = '',
  });

  @override
  State<_HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<_HistoryScreen> {
  DateTime _selectedDate = DateTime.now();
  bool _isMonthView = false;

  Future<Map<String, dynamic>> _fetchHistoryData() async {
    await DonationsLocalStorage.init();
    await DonationBoxStorage.init();
    final box = await LocalStorageService.openBoxSafe('dasterkhwaan_tokens');
    final activeUser = LocalStorageService.getActiveUserData();
    final uid = (activeUser['uid'] ?? activeUser['id'] ?? activeUser['userId'] ?? FirebaseAuth.instance.currentUser?.uid ?? '').toString().trim();
    final dateKey = widget.dateFmt.format(_selectedDate);
    final monthKey = '${_selectedDate.year}-${_selectedDate.month.toString().padLeft(2, '0')}';
    final myUsername = widget.username.toLowerCase().trim();

    int totalTokens = 0;
    int servedTokens = 0;
    final List<Map<String, dynamic>> tokenList = [];
    final List<Map<String, dynamic>> donationList = [];
    final Set<String> seenTokenIds = {};
    final Set<String> seenDonationIds = {};

    // 1. Read tokens from Local Hive Box first (Instant offline access)
    try {
      for (final raw in box.values) {
        if (raw is Map) {
          final t = Map<String, dynamic>.from(raw);
          final tDate = t['dateKey']?.toString() ?? '';
          final tBranch = t['branchId']?.toString() ?? '';
          final matchesBranch = tBranch.isEmpty || tBranch == widget.branchId;
          final matchesDate = _isMonthView ? tDate.startsWith(monthKey) : tDate == dateKey;

          if (matchesBranch && matchesDate) {
            final tId = t['id']?.toString() ?? '${tDate}_${t['number']}';
            if (seenTokenIds.add(tId)) {
              totalTokens++;
              final isServed = t['served'] == true;
              if (isServed) servedTokens++;

              if (!_isMonthView) {
                DateTime? tTime;
                if (t['time'] is DateTime) {
                  tTime = t['time'];
                } else if (t['time'] is String) {
                  tTime = DateTime.tryParse(t['time']);
                }
                DateTime? sTime;
                if (t['servedTime'] is DateTime) {
                  sTime = t['servedTime'];
                } else if (t['servedTime'] is String) {
                  sTime = DateTime.tryParse(t['servedTime']);
                }

                tokenList.add({
                  'number': (t['number'] as num?)?.toInt() ?? 0,
                  'served': isServed,
                  'time': tTime,
                  'servedTime': sTime,
                });
              }
            }
          }
        }
      }
      tokenList.sort((a, b) => ((a['number'] as int?) ?? 0).compareTo((b['number'] as int?) ?? 0));
    } catch (e) {
      debugPrint('[OfficeBoyHistory] Local token read error: $e');
    }

    // 2. Read local donations from Hive for this office boy
    try {
      final allLocalDonations = DonationsLocalStorage.getAllDonations(widget.branchId);
      final localList = allLocalDonations.where((d) {
        final matchesDate = _isMonthView ? d.date.startsWith(monthKey) : d.date == dateKey;
        if (!matchesDate) return false;
        final dCollector = (d.collectorId ?? '').trim();
        final dRecorded = d.recordedBy.toLowerCase().trim();
        final matchesUser = (uid.isNotEmpty && dCollector == uid) ||
            (myUsername.isNotEmpty && dRecorded == myUsername) ||
            dCollector.isEmpty;
        return matchesUser;
      }).toList();

      for (var d in localList) {
        if (seenDonationIds.add(d.localId)) {
          donationList.add({
            'donorName':  d.donorName,
            'amount':     d.amount > 0 ? d.amount : (d.probableAmount ?? 0.0),
            'type':       d.categoryId,
            'status':     d.status,
            'syncStatus': d.syncStatus,
            'localId':    d.localId,
            'time':       DateTime.tryParse(d.timestamp ?? ''),
          });
        }
      }
    } catch (e) {
      debugPrint('[OfficeBoyHistory] Local donation read error: $e');
    }

    // 3. Optional Non-blocking Cloud Sync Merge (with short timeout)
    try {
      if (!_isMonthView) {
        final tokensSnap = await FirebaseFirestore.instance
            .collection('branches').doc(widget.branchId)
            .collection('dasterkhwaan').doc(dateKey)
            .collection('tokens')
            .get()
            .timeout(const Duration(seconds: 3));

        for (final doc in tokensSnap.docs) {
          final data = doc.data();
          final tId = doc.id;
          if (seenTokenIds.add(tId)) {
            totalTokens++;
            final isServed = data['served'] == true;
            if (isServed) servedTokens++;

            tokenList.add({
              'number':     (data['number'] as num?)?.toInt() ?? 0,
              'served':     isServed,
              'time':       (data['time'] as Timestamp?)?.toDate(),
              'servedTime': (data['servedTime'] as Timestamp?)?.toDate(),
            });
          }
        }
        tokenList.sort((a, b) => ((a['number'] as int?) ?? 0).compareTo((b['number'] as int?) ?? 0));

        try {
          final donationsSnap = await FirebaseFirestore.instance
              .collection('branches')
              .doc(widget.branchId)
              .collection('donations')
              .where('branchId', isEqualTo: widget.branchId)
              .where('date', isEqualTo: dateKey)
              .get()
              .timeout(const Duration(seconds: 3));

          for (var d in donationsSnap.docs) {
            final data = d.data();
            final dCollector = (data['collectorId'] ?? '').toString().trim();
            final dRecorded = (data['recordedBy'] ?? '').toString().toLowerCase().trim();
            final matchesUser = (uid.isNotEmpty && dCollector == uid) ||
                (myUsername.isNotEmpty && dRecorded == myUsername) ||
                dCollector.isEmpty;
            if (!matchesUser) continue;

            final lid = data['localId'] as String? ?? d.id;
            if (seenDonationIds.add(lid)) {
              donationList.add({
                ...data,
                'donorName':  data['donorName']  ?? 'Walk-in Donor',
                'amount':     (data['amount']    as num? ?? 0.0).toDouble(),
                'type':       data['categoryId'] ?? 'GMWF',
                'status':     data['status']     ?? 'pending',
                'time':       (data['time']      as Timestamp?)?.toDate(),
              });
            }
          }
        } catch (_) {}
      } else {
        try {
          final donationsSnap = await FirebaseFirestore.instance
              .collection('branches')
              .doc(widget.branchId)
              .collection('donations')
              .where('branchId', isEqualTo: widget.branchId)
              .get()
              .timeout(const Duration(seconds: 3));

          for (var d in donationsSnap.docs) {
            final data = d.data();
            final dtStr = data['date']?.toString() ?? '';
            if (dtStr.startsWith(monthKey)) {
              final dCollector = (data['collectorId'] ?? '').toString().trim();
              final dRecorded = (data['recordedBy'] ?? '').toString().toLowerCase().trim();
              final matchesUser = (uid.isNotEmpty && dCollector == uid) ||
                  (myUsername.isNotEmpty && dRecorded == myUsername) ||
                  dCollector.isEmpty;
              if (!matchesUser) continue;

              final lid = data['localId'] as String? ?? d.id;
              if (seenDonationIds.add(lid)) {
                donationList.add({
                  ...data,
                  'donorName':  data['donorName']  ?? 'Walk-in Donor',
                  'amount':     (data['amount']    as num? ?? 0.0).toDouble(),
                  'type':       data['categoryId'] ?? 'GMWF',
                  'status':     data['status']     ?? 'pending',
                  'time':       (data['time']      as Timestamp?)?.toDate(),
                });
              }
            }
          }
        } catch (_) {}
      }
    } catch (_) {}

    final totalRevenue = totalTokens * widget.pricePerToken;
    final totalDonations = donationList.fold<double>(
        0.0, (acc, d) => acc + (d['amount'] as num? ?? 0).toDouble());

    // ── Physical Box Openings ──
    final allOpenings = DonationBoxStorage.getOpenings(widget.branchId);
    final boxOpenings = allOpenings.where((op) {
      final opDate = DateTime.tryParse(op.openDate);
      if (opDate == null) return false;
      if (_isMonthView) {
        return opDate.year == _selectedDate.year && opDate.month == _selectedDate.month;
      } else {
        return widget.dateFmt.format(opDate) == dateKey;
      }
    }).toList();
    final totalBoxAmount = boxOpenings.fold<double>(0.0, (acc, op) => acc + op.amount);

    return {
      'totalTokens':    totalTokens,
      'servedTokens':   servedTokens,
      'totalRevenue':   totalRevenue,
      'tokenList':      tokenList,
      'donationList':   donationList,
      'totalDonations': totalDonations,
      'boxOpenings':    boxOpenings,
      'totalBoxAmount': totalBoxAmount,
    };
  }

  @override
  Widget build(BuildContext context) {
    final todayStr   = widget.dateFmt.format(DateTime.now());
    final dateKey    = widget.dateFmt.format(_selectedDate);
    final monthLabel = DateFormat('MMMM yyyy').format(_selectedDate);
    final isToday    = dateKey == todayStr;
    final displayDate = DateFormat('dd MMM yyyy').format(_selectedDate);

    return Column(children: [
      // ── Header ──────────────────────────────────────────────────
      Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF2D1B69), Color(0xFF4C1D95)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _isMonthView ? 'Monthly History' : 'Daily History',
                          style: GoogleFonts.dmSerifDisplay(
                              color: Colors.white, fontSize: 22),
                        ),
                        Text(
                          _isMonthView ? 'Cumulative tokens, boxes & donations' : 'Tokens, boxes & donations by date',
                          style: GoogleFonts.dmSans(
                              color: Colors.white.withValues(alpha: 0.50),
                              fontSize: 11),
                        ),
                      ],
                    ),
                    // Segmented View Toggle
                    Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          GestureDetector(
                            onTap: () => setState(() => _isMonthView = false),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: !_isMonthView ? Colors.white : Colors.transparent,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Text(
                                'Day',
                                style: GoogleFonts.dmSans(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: !_isMonthView ? _DS.purple : Colors.white70,
                                ),
                              ),
                            ),
                          ),
                          GestureDetector(
                            onTap: () => setState(() => _isMonthView = true),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: _isMonthView ? Colors.white : Colors.transparent,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Text(
                                'Month',
                                style: GoogleFonts.dmSans(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: _isMonthView ? _DS.purple : Colors.white70,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                // Date navigator
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(_DS.r14),
                    border: Border.all(
                        color: Colors.white.withValues(alpha: 0.15),
                        width: 0.5),
                  ),
                  child: Row(children: [
                    _DateNavBtn(
                      icon: Icons.chevron_left_rounded,
                      onTap: () => setState(() {
                        if (_isMonthView) {
                          _selectedDate = DateTime(_selectedDate.year, _selectedDate.month - 1, 1);
                        } else {
                          _selectedDate = _selectedDate.subtract(const Duration(days: 1));
                        }
                      }),
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
                                colorScheme: const ColorScheme.light(primary: _DS.purple),
                                textButtonTheme: TextButtonThemeData(
                                  style: TextButton.styleFrom(foregroundColor: _DS.purple),
                                ),
                              ),
                              child: child!,
                            ),
                          );
                          if (picked != null) {
                            setState(() => _selectedDate = picked);
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.calendar_today_rounded,
                                  color: Colors.white, size: 13),
                              const SizedBox(width: 7),
                              Text(
                                _isMonthView
                                    ? monthLabel
                                    : (isToday ? 'Today · $displayDate' : displayDate),
                                style: GoogleFonts.dmSans(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    _DateNavBtn(
                      icon: Icons.chevron_right_rounded,
                      onTap: (_isMonthView
                              ? (_selectedDate.year == DateTime.now().year && _selectedDate.month == DateTime.now().month)
                              : isToday)
                          ? null
                          : () => setState(() {
                              if (_isMonthView) {
                                _selectedDate = DateTime(_selectedDate.year, _selectedDate.month + 1, 1);
                              } else {
                                _selectedDate = _selectedDate.add(const Duration(days: 1));
                              }
                            }),
                      disabled: _isMonthView
                          ? (_selectedDate.year == DateTime.now().year && _selectedDate.month == DateTime.now().month)
                          : isToday,
                    ),
                  ]),
                ),
              ],
            ),
          ),
        ),
      ),

      // ── Body ──────────────────────────────────────────────────────────
      Expanded(
        child: FutureBuilder<Map<String, dynamic>>(
          key: ValueKey('${_isMonthView ? "m" : "d"}_${_selectedDate.toIso8601String()}'),
          future: _fetchHistoryData(),
          builder: (_, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(
                  child: CircularProgressIndicator(
                      color: _DS.purple, strokeWidth: 2));
            }
            if (snap.hasError) {
              return Center(
                  child: Text('Error: ${snap.error}',
                      style: _TS.body(c: _DS.ink3)));
            }
            final d              = snap.data!;
            final totalTokens   = d['totalTokens']    as int;
            final servedTokens  = d['servedTokens']   as int;
            final totalRevenue  = d['totalRevenue']   as double;
            final tokenList     = d['tokenList'] as List<Map<String, dynamic>>;
            final donationList  = d['donationList'] as List<Map<String, dynamic>>;
            final totalDonations = d['totalDonations'] as double;
            final boxOpenings   = d['boxOpenings'] as List<BoxOpening>;
            final totalBoxAmount = d['totalBoxAmount'] as double;

            if (totalTokens == 0 && donationList.isEmpty && boxOpenings.isEmpty) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.event_note_rounded,
                        size: 64,
                        color: _DS.purple.withValues(alpha: 0.15)),
                    const SizedBox(height: 12),
                    Text(
                      _isMonthView
                          ? 'No records for $monthLabel'
                          : 'No records for $displayDate',
                      style: GoogleFonts.dmSans(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: _DS.ink3),
                    ),
                  ],
                ),
              );
            }

            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
              children: [
                // Token summary
                _HistSectionCard(
                  icon:  Icons.confirmation_number_rounded,
                  color: _DS.mint,
                  title: _isMonthView ? 'Monthly Tokens Summary' : 'Token Summary',
                  child: Column(children: [
                    Row(children: [
                      _HistStatTile('Issued', '$totalTokens', _DS.mint),
                      const SizedBox(width: 8),
                      _HistStatTile('Served', '$servedTokens', _DS.green),
                    ]),
                    const SizedBox(height: 8),
                    Row(children: [
                      _HistStatTile('Pending', '${totalTokens - servedTokens}', _DS.amber),
                      const SizedBox(width: 8),
                      _HistStatTile('Revenue', 'PKR ${totalRevenue.toStringAsFixed(0)}', _DS.purple, smallVal: true),
                    ]),
                    const SizedBox(height: 14),
                    // Progress
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Serving progress',
                            style: GoogleFonts.dmSans(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: _DS.ink3)),
                        Text(
                          totalTokens > 0
                              ? '${((servedTokens / totalTokens) * 100).toStringAsFixed(0)}%'
                              : '0%',
                          style: GoogleFonts.dmSans(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: _DS.mint),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: totalTokens > 0 ? servedTokens / totalTokens : 0,
                        minHeight: 6,
                        backgroundColor: _DS.mint.withValues(alpha: 0.1),
                        valueColor: const AlwaysStoppedAnimation(_DS.mint),
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 12),

                // Physical Box Openings Section
                _HistSectionCard(
                  icon: Icons.inventory_2_rounded,
                  color: const Color(0xFF0D9488),
                  title: 'Donation Boxes (${boxOpenings.length})',
                  child: boxOpenings.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Text(
                            'No donation boxes opened on this date.',
                            style: GoogleFonts.dmSans(color: _DS.ink3, fontSize: 13),
                          ),
                        )
                      : Column(
                          children: [
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFFCCFBF1),
                                borderRadius: BorderRadius.circular(_DS.r12),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'Total Box Collections',
                                    style: GoogleFonts.dmSans(
                                        fontWeight: FontWeight.w600,
                                        color: const Color(0xFF0F766E),
                                        fontSize: 13),
                                  ),
                                  Text(
                                    'PKR ${totalBoxAmount.toStringAsFixed(0)}',
                                    style: GoogleFonts.dmSerifDisplay(
                                        color: const Color(0xFF0F766E),
                                        fontSize: 18),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 10),
                            ...boxOpenings.map((op) {
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 36,
                                      height: 36,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFE6FFFA),
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(color: const Color(0xFF99F6E4)),
                                      ),
                                      child: const Center(
                                        child: Icon(Icons.inventory_2_rounded, size: 16, color: Color(0xFF0D9488)),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'Box #${op.boxNumber}',
                                            style: GoogleFonts.dmSans(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w700,
                                                color: _DS.ink),
                                          ),
                                          Text(
                                            'Collected by ${op.collectedBy}',
                                            style: GoogleFonts.dmSans(
                                                fontSize: 11,
                                                color: _DS.ink3),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Text(
                                      'PKR ${op.amount.toStringAsFixed(0)}',
                                      style: GoogleFonts.dmSans(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        color: const Color(0xFF0D9488),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }),
                          ],
                        ),
                ),
                const SizedBox(height: 12),

                // Tokens List (Daily only)
                if (!_isMonthView && tokenList.isNotEmpty)
                  _HistSectionCard(
                    icon:  Icons.list_alt_rounded,
                    color: _DS.ink3,
                    title: 'Tokens (${tokenList.length})',
                    child: Column(
                      children: tokenList.take(30).map((t) {
                        final served = t['served'] as bool;
                        final time   = t['time']   as DateTime?;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(children: [
                            Container(
                              width: 34, height: 34,
                              decoration: BoxDecoration(
                                color: served ? _DS.greenBg : _DS.amberBg,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Center(
                                child: Text('#${t['number']}',
                                    style: GoogleFonts.dmSans(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: served ? _DS.green : _DS.amber)),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                time != null
                                    ? 'Issued at ${DateFormat('hh:mm a').format(time)}'
                                    : 'Issued',
                                style: GoogleFonts.dmSans(
                                    fontSize: 12,
                                    color: _DS.ink3),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: served ? _DS.greenBg : _DS.amberBg,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                served ? 'Served' : 'Pending',
                                style: GoogleFonts.dmSans(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: served ? _DS.green : _DS.amber),
                              ),
                            ),
                          ]),
                        );
                      }).toList(),
                    ),
                  ),
                if (!_isMonthView && tokenList.isNotEmpty)
                  const SizedBox(height: 12),

                // Donations
                _HistSectionCard(
                  icon:  Icons.volunteer_activism_rounded,
                  color: _DS.purple,
                  title: 'Donations (${donationList.length})',
                  child: donationList.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            'No donations recorded for this period.',
                            style: GoogleFonts.dmSans(
                                color: _DS.ink3, fontSize: 13),
                          ),
                        )
                      : Column(children: [
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: _DS.purpleBg,
                              borderRadius: BorderRadius.circular(_DS.r12),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Total Donations',
                                    style: GoogleFonts.dmSans(
                                        fontWeight: FontWeight.w600,
                                        color: _DS.purple,
                                        fontSize: 13)),
                                Text(
                                  'PKR ${totalDonations.toStringAsFixed(0)}',
                                  style: GoogleFonts.dmSerifDisplay(
                                      color: _DS.purple,
                                      fontSize: 18),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                          ...donationList.map((don) {
                            final status = don['status']?.toString() ?? 'pending';
                            final isApproved = status == 'approved';
                            final isRejected = status == 'rejected';
                            final statusBg = isApproved
                                ? _DS.greenBg
                                : isRejected
                                    ? _DS.redBg
                                    : _DS.amberBg;
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(children: [
                                Container(
                                  width: 34, height: 34,
                                  decoration: const BoxDecoration(
                                    color: _DS.purpleBg,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Center(
                                    child: Text(
                                      (don['donorName']?.toString() ?? 'D')
                                          .substring(0, 1)
                                          .toUpperCase(),
                                      style: GoogleFonts.dmSans(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: _DS.purple),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        don['donorName']?.toString() ?? 'Walk-in Donor',
                                        style: GoogleFonts.dmSans(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                            color: _DS.ink),
                                      ),
                                      Text(
                                        '${don['type'] ?? 'General'} · PKR ${(don['amount'] as num? ?? 0).toDouble().toStringAsFixed(0)}',
                                        style: GoogleFonts.dmSans(
                                            fontSize: 11,
                                            color: _DS.ink3),
                                      ),
                                    ],
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: statusBg,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    status,
                                    style: GoogleFonts.dmSans(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ]),
                            );
                          }),
                        ]),
                ),
              ],
            );
          },
        ),
      ),
    ]);
  }
}

// ─── Date Nav Button ──────────────────────────────────────────────────────────

class _DateNavBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final bool disabled;

  const _DateNavBtn({
    required this.icon,
    this.onTap,
    this.disabled = false,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: disabled ? null : onTap,
        child: Container(
          width: 38, height: 38, margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: disabled
                ? Colors.transparent
                : Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(_DS.r12),
          ),
          child: Icon(icon,
              color: disabled
                  ? Colors.white.withValues(alpha: 0.25)
                  : Colors.white,
              size: 20),
        ),
      );
}

// ─── History Section Card ─────────────────────────────────────────────────────

class _HistSectionCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final Widget child;

  const _HistSectionCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _DS.getSurface(isDark),
        borderRadius: BorderRadius.circular(_DS.r22),
        border: Border.all(color: _DS.getBorder(isDark), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 34, height: 34,
              decoration: BoxDecoration(
                color: color.withValues(alpha: isDark ? 0.18 : 0.10),
                borderRadius: BorderRadius.circular(_DS.r12),
              ),
              child: Icon(icon, color: color, size: 16),
            ),
            const SizedBox(width: 10),
            Text(title,
                style: GoogleFonts.dmSans(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: _DS.getInk(isDark))),
          ]),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

// ─── Hist Stat Tile ────────────────────────────────────────────────────────────

class _HistStatTile extends StatelessWidget {
  final String label, value;
  final Color color;
  final bool smallVal;

  const _HistStatTile(this.label, this.value, this.color,
      {this.smallVal = false});

  @override
  Widget build(BuildContext context) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(
              vertical: 12, horizontal: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(_DS.r12),
          ),
          child: Column(children: [
            Text(value,
                style: GoogleFonts.dmSans(
                    fontSize: smallVal ? 15 : 20,
                    fontWeight: FontWeight.w600,
                    color: color,
                    height: 1.0)),
            const SizedBox(height: 4),
            Text(label.toUpperCase(),
                style: GoogleFonts.dmSans(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: color.withValues(alpha: 0.65),
                    letterSpacing: 0.4)),
          ]),
        ),
      );
}