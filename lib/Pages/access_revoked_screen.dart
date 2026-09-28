// lib/pages/access_revoked_screen.dart
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';

import '../services/offline_auth_service.dart';
import '../services/local_storage_service.dart';
import 'login_page.dart';

class AccessRevokedScreen extends StatefulWidget {
  final Map<String, dynamic>? userData;
  final String? reason;

  const AccessRevokedScreen({
    super.key,
    this.userData,
    this.reason,
  });

  @override
  State<AccessRevokedScreen> createState() => _AccessRevokedScreenState();
}

class _AccessRevokedScreenState extends State<AccessRevokedScreen>
    with SingleTickerProviderStateMixin {
  bool _submittingRequest = false;
  bool _checkingStatus = false;
  bool _restoreRequestPending = false;
  bool _accessRestored = false;
  String? _requestedAt;
  String? _requestReason;
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    final reqStatus = (widget.userData?['restoreRequestStatus'] ?? '').toString().toLowerCase().trim();
    final isRequested = widget.userData?['restoreRequested'] == true || reqStatus == 'pending';
    _restoreRequestPending = isRequested;
    _requestedAt = widget.userData?['restoreRequestedAt']?.toString();
    _requestReason = widget.userData?['restoreRequestReason']?.toString();

    // Check if status in local box or firestore is already pending
    _checkInitialStatus();
  }

  Future<void> _checkInitialStatus() async {
    final uid = (widget.userData?['uid'] ?? widget.userData?['id'] ?? '').toString();
    if (uid.isEmpty) return;

    // 1. Check if already reverted or active in Firestore
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get()
          .timeout(const Duration(seconds: 4));
      if (doc.exists && doc.data() != null) {
        final d = doc.data()!;
        final status = (d['status'] ?? d['accountStatus'] ?? '').toString().toLowerCase().trim();
        final isActive = d['isActive'] == true;
        final isRevoked = d['isRevoked'] == true || d['accessRevoked'] == true;
        if ((status == 'active' || isActive) && !isRevoked) {
          final restoredUserData = Map<String, dynamic>.from(widget.userData ?? {})..addAll(d);
          restoredUserData['status'] = 'active';
          restoredUserData['accountStatus'] = 'active';
          restoredUserData['isActive'] = true;
          restoredUserData['isRevoked'] = false;
          restoredUserData['accessRevoked'] = false;
          await LocalStorageService.saveLocalUser(restoredUserData);
          if (mounted) {
            setState(() {
              _accessRestored = true;
              _restoreRequestPending = false;
            });
            _showSnack('🎉 Your access is active! Returning to login...', success: true);
            await Future.delayed(const Duration(seconds: 2));
            if (mounted) {
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const LoginPage()),
                (route) => false,
              );
            }
          }
          return;
        }
      }
    } catch (_) {}

    // 2. Check local pending request status
    try {
      if (Hive.isBoxOpen('local_users')) {
        final box = Hive.box('local_users');
        final raw = box.get(uid);
        if (raw is Map) {
          final s = (raw['restoreRequestStatus'] ?? '').toString().toLowerCase().trim();
          if (s == 'pending' || raw['restoreRequested'] == true) {
            if (mounted) {
              setState(() {
                _restoreRequestPending = true;
                _requestedAt = raw['restoreRequestedAt']?.toString();
                _requestReason = raw['restoreRequestReason']?.toString();
              });
            }
          }
        }
      }
    } catch (_) {}

    // 3. For corrupted/orphan status, immediately attempt background auto-repair
    final rawStatus = (widget.userData?['status'] ?? widget.reason ?? '').toString().toLowerCase();
    if (rawStatus == 'corrupted' || widget.userData?['isCorruptedOrOrphanAuth'] == true) {
      await _attemptAutoRepair(silent: true);
    }
  }

  Future<void> _attemptAutoRepair({bool silent = false}) async {
    if (!silent) setState(() => _checkingStatus = true);
    try {
      final uid = (widget.userData?['uid'] ?? widget.userData?['id'] ?? '').toString();
      final email = (widget.userData?['email'] ?? '').toString().toLowerCase().trim();
      final username = (widget.userData?['username'] ?? '').toString().toLowerCase().trim();

      Map<String, dynamic>? foundProfile;

      // 1. Check local Hive users
      if (Hive.isBoxOpen('local_users')) {
        final box = Hive.box('local_users');
        for (final val in box.values) {
          if (val is Map) {
            final m = Map<String, dynamic>.from(val);
            final uUid = (m['uid'] ?? m['id'] ?? '').toString();
            final uEmail = (m['email'] ?? '').toString().toLowerCase().trim();
            final uName = (m['username'] ?? m['name'] ?? '').toString().toLowerCase().trim();
            if ((uid.isNotEmpty && uUid == uid) ||
                (email.isNotEmpty && (uEmail == email || uEmail.startsWith('$username@'))) ||
                (username.isNotEmpty && (uName == username || uEmail.startsWith('$username@')))) {
              final r = (m['role'] ?? '').toString().toLowerCase().trim();
              if (r.isNotEmpty && r != 'unknown' && r != 'unassigned') {
                foundProfile = m;
                break;
              }
            }
          }
        }
      }

      // 2. Check local employees database
      if (foundProfile == null && Hive.isBoxOpen(LocalStorageService.employeesBox)) {
        final empBox = Hive.box(LocalStorageService.employeesBox);
        for (final val in empBox.values) {
          if (val is Map) {
            final e = Map<String, dynamic>.from(val);
            final eEmail = (e['email'] ?? '').toString().toLowerCase().trim();
            final eName = (e['name'] ?? e['fullName'] ?? '').toString().toLowerCase().trim();
            final eId = (e['id'] ?? e['employeeId'] ?? '').toString().toLowerCase().trim();
            if ((email.isNotEmpty && eEmail == email) ||
                (username.isNotEmpty && (eName == username || eId == username))) {
              foundProfile = {
                ...e,
                'uid': uid.isNotEmpty ? uid : (e['uid'] ?? eId),
                'role': e['designation'] ?? e['role'] ?? 'staff',
                'branchId': e['branchId'] ?? 'all',
              };
              break;
            }
          }
        }
      }

      // 3. Check Firestore /users collection directly
      if (foundProfile == null && (email.isNotEmpty || username.isNotEmpty)) {
        try {
          if (email.isNotEmpty) {
            final snap = await FirebaseFirestore.instance
                .collection('users')
                .where('email', isEqualTo: email)
                .limit(1)
                .get()
                .timeout(const Duration(seconds: 4));
            if (snap.docs.isNotEmpty) {
              foundProfile = snap.docs.first.data();
            }
          }
          if (foundProfile == null && username.isNotEmpty) {
            final snap = await FirebaseFirestore.instance
                .collection('users')
                .where('usernameLower', isEqualTo: username)
                .limit(1)
                .get()
                .timeout(const Duration(seconds: 4));
            if (snap.docs.isNotEmpty) {
              foundProfile = snap.docs.first.data();
            }
          }
        } catch (_) {}
      }

      if (foundProfile != null) {
        final healed = Map<String, dynamic>.from(widget.userData ?? {})..addAll(foundProfile);
        final effectiveUid = uid.isNotEmpty ? uid : (healed['uid'] ?? healed['id'] ?? '').toString();
        healed['uid'] = effectiveUid;
        healed['status'] = 'active';
        healed['accountStatus'] = 'active';
        healed['isActive'] = true;
        healed['isRevoked'] = false;
        healed['accessRevoked'] = false;
        healed['isCorruptedOrOrphanAuth'] = false;
        healed['isDeleted'] = false;

        await LocalStorageService.saveLocalUser(healed);
        if (effectiveUid.isNotEmpty) {
          try {
            await FirebaseFirestore.instance.collection('users').doc(effectiveUid).set(
              healed,
              SetOptions(merge: true),
            ).timeout(const Duration(seconds: 5));
          } catch (_) {}
        }

        if (mounted) {
          setState(() {
            _accessRestored = true;
            _restoreRequestPending = false;
            _checkingStatus = false;
          });
          _showSnack('🎉 Profile verified & restored! Returning to login...', success: true);
          await Future.delayed(const Duration(seconds: 2));
          if (mounted) {
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(builder: (_) => const LoginPage()),
              (route) => false,
            );
          }
          return;
        }
      }
    } catch (e) {
      debugPrint('[AccessRevokedScreen] Auto-repair attempt error: $e');
    }

    if (mounted && !silent) {
      setState(() => _checkingStatus = false);
      _showSnack('Could not automatically resolve your profile. Please submit a request to admin.');
    }
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  /// Resolve the best display name from userData, trying multiple fields.
  String _resolveDisplayName() {
    final d = widget.userData;
    if (d == null) return 'User';

    for (final key in ['name', 'username', 'userName', 'displayName', 'fullName', 'email']) {
      final val = d[key]?.toString().trim() ?? '';
      if (val.isNotEmpty &&
          val != 'User' &&
          val != 'Employee' &&
          val != '.' &&
          val != 'N/A' &&
          val.toLowerCase() != 'employee') {
        // For email, show just the part before @
        if (key == 'email' && val.contains('@')) return val.split('@').first;
        return val;
      }
    }
    return 'User';
  }

  Future<void> _handleLogout(BuildContext context) async {
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {}
    final userKey = (widget.userData?['uid'] ??
            widget.userData?['email'] ??
            widget.userData?['username'] ??
            '')
        .toString();
    if (userKey.isNotEmpty) {
      await OfflineAuthService.clearCredentialsForUser(userKey);
    } else {
      await OfflineAuthService.clearCachedUserData();
    }

    if (context.mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginPage()),
        (route) => false,
      );
    }
  }

  /// Submit request to HQ Manager to restore access.
  /// Does NOT restore directly — only HQ Manager can say "Allow".
  Future<void> _submitRestoreRequest() async {
    final uid = (widget.userData?['uid'] ?? widget.userData?['id'] ?? '').toString();
    final email = (widget.userData?['email'] ?? '').toString();
    final branch = (widget.userData?['branchId'] ?? 'HQ').toString();
    final name = _resolveDisplayName();

    if (uid.isEmpty && email.isEmpty) {
      _showSnack('Unable to identify your account. Please contact the HQ Manager directly.');
      return;
    }

    final reasonCtrl = TextEditingController();

    // Show request confirmation dialog with optional remarks for HQ Manager
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF38BDF8).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.mark_email_unread_rounded, color: Color(0xFF38BDF8), size: 22),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Request Access Back',
                style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Your request will be submitted to the HQ Manager. Your account will only be restored once the HQ Manager approves and clicks "Allow".',
              style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 16),
            const Text(
              'Reason / Note for HQ Manager (Optional)',
              style: TextStyle(color: Color(0xFFE2E8F0), fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: reasonCtrl,
              maxLines: 2,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'e.g. My account was revoked by mistake during shift...',
                hintStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
                filled: true,
                fillColor: const Color(0xFF0F172A),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFF334155)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFF334155)),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF64748B))),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.send_rounded, size: 16),
            label: const Text('Submit Request'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0284C7),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    final note = reasonCtrl.text.trim();
    setState(() => _submittingRequest = true);

    try {
      final nowIso = DateTime.now().toIso8601String();
      final requestData = <String, dynamic>{
        'restoreRequested': true,
        'restoreRequestStatus': 'pending',
        'restoreRequestedAt': nowIso,
        'restoreRequestReason': note.isNotEmpty ? note : 'User requested access restoration',
        'restoreRequestBranch': branch,
        'updatedAt': nowIso,
      };

      // 1. Save pending status locally
      for (final boxName in ['local_users', LocalStorageService.usersBox]) {
        try {
          if (Hive.isBoxOpen(boxName)) {
            final box = Hive.box(boxName);
            for (final key in [uid, email]) {
              if (key.isEmpty) continue;
              final raw = box.get(key);
              if (raw is Map) {
                final updated = Map<String, dynamic>.from(raw);
                updated.addAll(requestData);
                await box.put(key, updated);
              }
            }
            // Scan by uid
            for (final k in box.keys) {
              final val = box.get(k);
              if (val is Map) {
                final valUid = (val['uid'] ?? val['id'] ?? '').toString();
                if (valUid == uid && uid.isNotEmpty) {
                  final updated = Map<String, dynamic>.from(val);
                  updated.addAll(requestData);
                  await box.put(k, updated);
                }
              }
            }
            await box.flush();
          }
        } catch (_) {}
      }

      // 2. Save in app_settings cached user data
      try {
        if (Hive.isBoxOpen('app_settings')) {
          final box = Hive.box('app_settings');
          for (final settingsKey in ['user_data', 'currentUser']) {
            final raw = box.get(settingsKey);
            if (raw is Map) {
              final updated = Map<String, dynamic>.from(raw);
              updated.addAll(requestData);
              await box.put(settingsKey, updated);
            }
          }
          await box.flush();
        }
      } catch (_) {}

      // 3. Dispatch Notification locally and in Firestore for HQ Manager
      final notifId = 'restore_req_${uid.isNotEmpty ? uid : email.replaceAll('@', '_')}_${DateTime.now().millisecondsSinceEpoch}';
      final notifDoc = {
        'id': notifId,
        'title': '🔐 Access Restore Request: $name',
        'message': '$name ($branch) requested access restoration: "${note.isNotEmpty ? note : 'No remarks provided'}". Please review in User Management.',
        'category': 'access_restore_request',
        'type': 'access_restore_request',
        'targetRole': 'hq manager',
        'targetRoles': ['hq manager', 'admin', 'chairman', 'super admin', 'global admin'],
        'targetScreen': 'users',
        'branchId': branch,
        'targetUserId': uid,
        'userId': uid,
        'email': email,
        'requesterName': name,
        'reason': note,
        'seen': false,
        'timestamp': nowIso,
      };

      try {
        if (Hive.isBoxOpen(LocalStorageService.notificationsBox)) {
          final nBox = Hive.box(LocalStorageService.notificationsBox);
          await nBox.put(notifId, LocalStorageService.sanitize(notifDoc));
        }
      } catch (_) {}

      // 4. Update Firestore user document & create request notification
      if (uid.isNotEmpty) {
        try {
          await FirebaseFirestore.instance.collection('users').doc(uid).set({
            'restoreRequested': true,
            'restoreRequestStatus': 'pending',
            'restoreRequestedAt': FieldValue.serverTimestamp(),
            'restoreRequestReason': note,
          }, SetOptions(merge: true)).timeout(const Duration(seconds: 4));
        } catch (_) {}

        if (branch.isNotEmpty && branch != 'all' && branch != 'global') {
          try {
            await FirebaseFirestore.instance
                .collection('branches')
                .doc(branch)
                .collection('users')
                .doc(uid)
                .set({
              'restoreRequested': true,
              'restoreRequestStatus': 'pending',
              'restoreRequestedAt': FieldValue.serverTimestamp(),
              'restoreRequestReason': note,
            }, SetOptions(merge: true)).timeout(const Duration(seconds: 3));
          } catch (_) {}
        }

        if (branch.isNotEmpty && branch != 'all' && branch != 'global') {
          try {
            await FirebaseFirestore.instance
                .collection('branches')
                .doc(branch)
                .collection('notifications')
                .doc(notifId)
                .set(
                  LocalStorageService.sanitize(notifDoc),
                  SetOptions(merge: true),
                )
                .timeout(const Duration(seconds: 3));
          } catch (_) {}
        }
      }

      // 5. Enqueue offline sync
      try {
        await LocalStorageService.enqueueSync({
          'type': 'access_restore_request',
          'userId': uid,
          'email': email,
          'name': name,
          'branchId': branch,
          'reason': note,
          'requestedAt': nowIso,
        });
      } catch (_) {}

      if (mounted) {
        setState(() {
          _submittingRequest = false;
          _restoreRequestPending = true;
          _requestedAt = nowIso;
          _requestReason = note;
        });
        _showSnack('✅ Request submitted to HQ Manager. Awaiting approval.', success: true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _submittingRequest = false);
        _showSnack('Failed to submit request: $e. Please contact the HQ Manager.');
      }
    }
  }

  /// Check if HQ Manager has approved the restore request.
  Future<void> _checkRequestStatus() async {
    final uid = (widget.userData?['uid'] ?? widget.userData?['id'] ?? '').toString();
    if (uid.isEmpty) {
      _showSnack('Unable to check account status.');
      return;
    }

    setState(() => _checkingStatus = true);

    try {
      bool isNowActive = false;

      // 1. Check Firestore
      try {
        final doc = await FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .get()
            .timeout(const Duration(seconds: 4));
        if (doc.exists && doc.data() != null) {
          final data = doc.data()!;
          final status = (data['status'] ?? data['accountStatus'] ?? '').toString().toLowerCase().trim();
          final isActive = data['isActive'] == true;
          final isRevoked = data['isRevoked'] == true || data['accessRevoked'] == true;
          final reqStatus = (data['restoreRequestStatus'] ?? '').toString().toLowerCase().trim();

          if ((status == 'active' || isActive) && !isRevoked) {
            isNowActive = true;
          } else if (reqStatus == 'rejected' || reqStatus == 'denied') {
            if (mounted) {
              setState(() {
                _restoreRequestPending = false;
              });
              _showSnack('Your restore request was declined by the HQ Manager.');
              return;
            }
          }
        }
      } catch (_) {}

      // 2. Check local Hive
      if (!isNowActive && Hive.isBoxOpen('local_users')) {
        final box = Hive.box('local_users');
        final raw = box.get(uid);
        if (raw is Map) {
          final s = (raw['status'] ?? '').toString().toLowerCase().trim();
          final isRev = raw['isRevoked'] == true || raw['accessRevoked'] == true;
          if (s == 'active' && !isRev) {
            isNowActive = true;
          }
        }
      }

      if (mounted) {
        setState(() => _checkingStatus = false);
        if (isNowActive) {
          final restoredUserData = Map<String, dynamic>.from(widget.userData ?? {});
          restoredUserData['status'] = 'active';
          restoredUserData['accountStatus'] = 'active';
          restoredUserData['isActive'] = true;
          restoredUserData['isRevoked'] = false;
          restoredUserData['accessRevoked'] = false;
          restoredUserData['restoreRequested'] = false;
          restoredUserData['restoreRequestStatus'] = 'approved';
          await LocalStorageService.saveLocalUser(restoredUserData);

          setState(() => _accessRestored = true);
          _showSnack('🎉 Your access has been approved and restored! Logging in...', success: true);
          await Future.delayed(const Duration(seconds: 2));
          if (!mounted || !context.mounted) return;
          try {
            await FirebaseAuth.instance.signOut();
          } catch (_) {}
          if (!context.mounted) return;
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const LoginPage()),
            (route) => false,
          );
        } else {
          _showSnack('⏳ Request is still pending approval from the HQ Manager.');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _checkingStatus = false);
        _showSnack('Could not verify status. Please check your connection.');
      }
    }
  }

  void _showSnack(String msg, {bool success = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: success ? const Color(0xFF22C55E) : const Color(0xFFEF4444),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = _resolveDisplayName();
    final email = widget.userData?['email']?.toString() ??
        widget.userData?['username']?.toString() ??
        '';
    final branch = widget.userData?['branchId'] ?? 'HQ';
    final rawStatus = (widget.reason ?? widget.userData?['status'] ?? 'revoked').toString().toLowerCase().trim();
    final isDeleted = rawStatus == 'deleted' || widget.userData?['isDeleted'] == true;
    final isCorrupted = rawStatus == 'corrupted' || widget.userData?['isCorruptedOrOrphanAuth'] == true;
    final status = isDeleted ? 'DELETED' : (isCorrupted ? 'PROFILE MISSING' : rawStatus.toUpperCase());

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 480),
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: const Color(0xFF334155)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 32,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Animated Pulsing Lock Icon
                AnimatedBuilder(
                  animation: _pulseAnim,
                  builder: (_, child) => Transform.scale(
                    scale: _pulseAnim.value,
                    child: child,
                  ),
                  child: Container(
                    width: 90,
                    height: 90,
                    decoration: BoxDecoration(
                      color: const Color(0xFFEF4444).withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: const Color(0xFFEF4444).withValues(alpha: 0.3),
                          width: 2),
                    ),
                    child: Icon(
                      isCorrupted
                          ? Icons.warning_amber_rounded
                          : (isDeleted ? Icons.delete_forever_rounded : Icons.no_accounts_rounded),
                      color: const Color(0xFFEF4444),
                      size: 46,
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // Main Title
                Text(
                  isCorrupted
                      ? 'Account Profile Missing'
                      : (isDeleted ? 'Account Deleted' : 'Access Revoked'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),

                // Subtitle
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: isCorrupted || isDeleted
                        ? const Color(0xFFEF4444).withValues(alpha: 0.15)
                        : const Color(0xFF334155),
                    borderRadius: BorderRadius.circular(10),
                    border: isCorrupted || isDeleted
                        ? Border.all(color: const Color(0xFFEF4444).withValues(alpha: 0.3))
                        : null,
                  ),
                  child: Text(
                    isCorrupted
                        ? 'Authentication exists, but account data is not found or corrupted'
                        : (isDeleted
                            ? 'This account has been permanently deleted'
                            : 'Thank you for your services'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: isCorrupted || isDeleted ? const Color(0xFFFCA5A5) : Colors.grey.shade300,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      fontStyle: (isCorrupted || isDeleted) ? FontStyle.normal : FontStyle.italic,
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // Revocation Message or Pending Request Card
                if (_restoreRequestPending && !_accessRestored) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF59E0B).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.35)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF59E0B).withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(Icons.hourglass_top_rounded, color: Color(0xFFF59E0B), size: 20),
                            ),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Text(
                                'Restore Request Pending Approval',
                                style: TextStyle(
                                  color: Color(0xFFFBBF24),
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'Your restoration request has been forwarded to the HQ Manager. Your account will automatically be restored once the HQ Manager reviews and clicks "Allow".',
                          style: TextStyle(
                            color: Color(0xFFCBD5E1),
                            fontSize: 12.5,
                            height: 1.4,
                          ),
                        ),
                        if (_requestedAt != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Submitted: ${DateFormat('dd MMM yyyy, hh:mm a').format(DateTime.tryParse(_requestedAt!)?.toLocal() ?? DateTime.now())}',
                            style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                          ),
                        ],
                        if (_requestReason != null && _requestReason!.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            'Reason: "$_requestReason"',
                            style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontStyle: FontStyle.italic),
                          ),
                        ],
                      ],
                    ),
                  ),
                ] else ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFF334155)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline_rounded,
                            color: Color(0xFFEF4444), size: 22),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            isCorrupted
                                ? 'Your login credentials exist, but your account profile is missing or corrupted. Please contact your system administrator to restore or re-register your profile.'
                                : (isDeleted
                                    ? 'This account was deleted by an administrator. You can no longer access this application with these credentials. Please contact your system administrator.'
                                    : 'Your app access has been revoked. If you believe this is a mistake, request the HQ Manager to restore your account.'),
                            style: const TextStyle(
                              color: Color(0xFF94A3B8),
                              fontSize: 13,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 20),

                // User details summary box
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F172A).withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF334155)),
                  ),
                  child: Column(
                    children: [
                      _buildDetailRow('Account Name', name),
                      if (email.isNotEmpty) ...[
                        const Divider(color: Color(0xFF334155), height: 16),
                        _buildDetailRow('Email / Username', email),
                      ],
                      const Divider(color: Color(0xFF334155), height: 16),
                      _buildDetailRow('Branch', branch.toString()),
                      const Divider(color: Color(0xFF334155), height: 16),
                      _buildDetailRow('Account Status', status, isBadge: true),
                      if (_restoreRequestPending) ...[
                        const Divider(color: Color(0xFF334155), height: 16),
                        _buildDetailRow('Restore Request', 'PENDING HQ APPROVAL', isWarningBadge: true),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // ── ACTIONS: Restore Request / Check Status ──────────────────
                if (!_accessRestored) ...[
                  if (_restoreRequestPending) ...[
                    // Check Status Button (checks if HQ Manager has approved)
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _checkingStatus ? null : _checkRequestStatus,
                        icon: _checkingStatus
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.refresh_rounded, size: 20),
                        label: Text(
                          _checkingStatus
                              ? 'Checking Approval Status...'
                              : 'Check Status / Refresh',
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0284C7),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          elevation: 0,
                        ),
                      ),
                    ),
                  ] else ...[
                    if (isCorrupted) ...[
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _checkingStatus ? null : () => _attemptAutoRepair(silent: false),
                          icon: _checkingStatus
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                              : const Icon(Icons.auto_fix_high_rounded, size: 20),
                          label: Text(
                            _checkingStatus ? 'Checking & Repairing...' : 'Auto-Repair & Sync Account',
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF10B981),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            elevation: 0,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    // Submit Request to HQ Manager
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _submittingRequest ? null : _submitRestoreRequest,
                        icon: _submittingRequest
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.mark_email_unread_rounded, size: 20),
                        label: Text(
                          _submittingRequest
                              ? 'Submitting Request...'
                              : (isDeleted || isCorrupted
                                  ? 'Contact Admin / Submit Inquiry'
                                  : 'Think this is a mistake? Request Access Back'),
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isCorrupted ? const Color(0xFF334155) : const Color(0xFF22C55E),
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: const Color(0xFF22C55E).withValues(alpha: 0.5),
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          elevation: 0,
                        ),
                      ),
                    ),
                  ],
                ],
                if (_accessRestored)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF22C55E).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                          color:
                              const Color(0xFF22C55E).withValues(alpha: 0.3)),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.check_circle_rounded,
                            color: Color(0xFF22C55E), size: 22),
                        SizedBox(width: 10),
                        Text(
                          'Access Approved! Restarting...',
                          style: TextStyle(
                            color: Color(0xFF22C55E),
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 12),

                // Logout Button
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _handleLogout(context),
                    icon: const Icon(Icons.logout_rounded, size: 20),
                    label: const Text(
                      'Back to Login',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFEF4444),
                      side: const BorderSide(color: Color(0xFFEF4444)),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value, {bool isBadge = false, bool isWarningBadge = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(
              color: Color(0xFF64748B),
              fontSize: 12,
              fontWeight: FontWeight.w500),
        ),
        if (isWarningBadge)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xFFF59E0B).withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                  color: const Color(0xFFF59E0B).withValues(alpha: 0.5)),
            ),
            child: Text(
              value,
              style: const TextStyle(
                  color: Color(0xFFFCD34D),
                  fontSize: 11,
                  fontWeight: FontWeight.bold),
            ),
          )
        else if (isBadge)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xFFEF4444).withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                  color: const Color(0xFFEF4444).withValues(alpha: 0.4)),
            ),
            child: Text(
              value,
              style: const TextStyle(
                  color: Color(0xFFFCA5A5),
                  fontSize: 11,
                  fontWeight: FontWeight.bold),
            ),
          )
        else
          Flexible(
            child: Text(
              value,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600),
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }
}
