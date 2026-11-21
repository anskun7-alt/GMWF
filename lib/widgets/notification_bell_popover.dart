import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';

import '../design/design_system.dart';
import '../design/tokens/soft_palette.dart';
import '../pages/request.dart';
import '../services/cloud_messaging_service.dart';
import '../services/local_storage_service.dart';
import '../utils/debounced_box_listenable.dart';

/// Shared helper & anchored popover dialog for the top-bar Notification Bell icon.
/// Combines pending operational requests (`local_edit_requests`, `restockRequestsBox`)
/// and unread notification messages (`notificationsBox`), displays a reactive badge,
/// and opens a small popover connected directly below the bell icon.
class NotificationBellHelper {
  NotificationBellHelper._();

  static final List<StreamSubscription> _firestoreSubs = [];
  static String? _listeningBranchKey;
  static bool _initializing = false;

  /// Ensures the Hive boxes for requests and notifications are open and starts
  /// a lightweight Firestore listener for pending requests so the badge and
  /// popover stay live even before `RequestPage` is opened.
  static Future<void> ensureInitialized({required String branchId}) async {
    if (!Hive.isBoxOpen('local_edit_requests')) {
      await LocalStorageService.openBoxSafe('local_edit_requests');
    }
    if (!Hive.isBoxOpen(LocalStorageService.restockRequestsBox)) {
      await LocalStorageService.openBoxSafe(LocalStorageService.restockRequestsBox);
    }
    if (!Hive.isBoxOpen(LocalStorageService.notificationsBox)) {
      await LocalStorageService.openBoxSafe(LocalStorageService.notificationsBox);
    }

    final normBranch = branchId.trim().toLowerCase();
    if (_listeningBranchKey == normBranch || _initializing) return;
    _initializing = true;
    try {
      _cancelSubs();
      _listeningBranchKey = normBranch;
      final branches = _resolveTargetBranches(normBranch);
      for (final bId in branches) {
        for (final col in const ['edit_requests', 'dispense_edit_requests', 'restock_requests']) {
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
                  if (col == 'restock_requests' &&
                      Hive.isBoxOpen(LocalStorageService.restockRequestsBox)) {
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
                for (final f in const ['requestedAt', 'createdAt', 'reviewedAt', 'approvedAt']) {
                  if (d[f] is Timestamp) {
                    d[f] = (d[f] as Timestamp).toDate().toIso8601String();
                  }
                }
                final existing = box.get(doc.id) ??
                    (d['requestId'] != null ? box.get(d['requestId']) : null) ??
                    (Hive.isBoxOpen(LocalStorageService.restockRequestsBox)
                        ? (Hive.box(LocalStorageService.restockRequestsBox).get(doc.id) ??
                            (d['requestId'] != null
                                ? Hive.box(LocalStorageService.restockRequestsBox).get(d['requestId'])
                                : null))
                        : null);
                if (existing is Map) {
                  final remoteStatus = (d['status'] ?? 'pending').toString().toLowerCase().trim();
                  if (LocalStorageService.isDecidedRequestStatus(existing['status']) &&
                      !LocalStorageService.isDecidedRequestStatus(remoteStatus)) {
                    continue;
                  }
                }
                if (col == 'restock_requests' &&
                    Hive.isBoxOpen(LocalStorageService.restockRequestsBox)) {
                  Hive.box(LocalStorageService.restockRequestsBox).put(doc.id, d);
                }
                box.put(doc.id, d);
              }
            }, onError: (_) {});
            _firestoreSubs.add(sub);
          } catch (_) {}
        }
      }
    } finally {
      _initializing = false;
    }
  }

  static void _cancelSubs() {
    for (final s in _firestoreSubs) {
      s.cancel();
    }
    _firestoreSubs.clear();
  }

  static List<String> _resolveTargetBranches(String b) {
    if (b.isEmpty || b == 'all' || b == 'global') {
      final Set<String> all = {
        'karachi',
        'gujrat',
        'grt',
        'sialkot',
        'skt',
        'rawalpindi',
        'rwp',
        'main',
      };
      if (Hive.isBoxOpen(LocalStorageService.branchesBox)) {
        final box = Hive.box(LocalStorageService.branchesBox);
        for (final item in box.values) {
          if (item is Map && item['id'] != null) {
            final id = item['id'].toString().toLowerCase().trim();
            if (id.isNotEmpty && id != 'all' && id != 'global') {
              all.add(id);
            }
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

  static Listenable buildCombinedListenable() {
    final listenables = <Listenable>[
      if (Hive.isBoxOpen('local_edit_requests'))
        DebouncedBoxListenable.shared(Hive.box('local_edit_requests')),
      if (Hive.isBoxOpen(LocalStorageService.restockRequestsBox))
        DebouncedBoxListenable.shared(Hive.box(LocalStorageService.restockRequestsBox)),
      if (Hive.isBoxOpen(LocalStorageService.notificationsBox))
        DebouncedBoxListenable.shared(Hive.box(LocalStorageService.notificationsBox)),
    ];
    if (listenables.isEmpty) return ValueNotifier<int>(0);
    return listenables.length == 1 ? listenables.first : Listenable.merge(listenables);
  }

  static bool matchesBranch(String targetBranchRaw, String docBranchRaw) {
    final targetBranch = targetBranchRaw.trim().toLowerCase();
    if (targetBranch.isEmpty || targetBranch == 'all' || targetBranch == 'global') return true;
    final docBranch = docBranchRaw.trim().toLowerCase();
    if (docBranch.isEmpty) return true;
    if (docBranch == targetBranch) return true;
    if (targetBranch.contains('gujrat') &&
        (docBranch == 'grt' || docBranch == 'gjt' || docBranch.contains('gujrat'))) {
      return true;
    }
    if (targetBranch == 'grt' && (docBranch.contains('gujrat') || docBranch == 'gjt')) {
      return true;
    }
    if (targetBranch.contains('sialkot') &&
        (docBranch == 'skt' || docBranch.contains('sialkot'))) {
      return true;
    }
    if (targetBranch == 'skt' && docBranch.contains('sialkot')) return true;
    if (targetBranch.contains('rawalpindi') &&
        (docBranch == 'rwp' || docBranch.contains('rawalpindi'))) {
      return true;
    }
    if (targetBranch == 'rwp' && docBranch.contains('rawalpindi')) return true;
    return false;
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

  /// Returns all pending requests relevant to [branchId] and [role], sorted newest first.
  static List<Map<String, dynamic>> getPendingRequests({
    required String branchId,
    required String role,
  }) {
    final results = <Map<String, dynamic>>[];
    final seenIds = <String>{};
    final cleanRole = role.trim().toLowerCase();
    final isDoctorOnly = cleanRole.contains('doctor') &&
        !cleanRole.contains('supervisor') &&
        !cleanRole.contains('admin') &&
        !cleanRole.contains('manager') &&
        !cleanRole.contains('chairman') &&
        !cleanRole.contains('ceo');
    final doctorCanApproveStock =
        !isDoctorOnly || LocalStorageService.isDoctorInventoryApprovalAllowed(branchId);

    void scanBox(String boxName, String defaultCol) {
      if (!Hive.isBoxOpen(boxName)) return;
      final box = Hive.box(boxName);
      for (final entry in box.toMap().entries) {
        final raw = entry.value;
        if (raw is! Map) continue;
        final data = _deepConvertMap(raw);
        final status = (data['status']?.toString() ?? 'pending').toLowerCase().trim();
        if (status != 'pending') continue;

        final docBranch = (data['branchId'] ?? '').toString();
        if (!matchesBranch(branchId, docBranch)) continue;

        final id = (data['requestId'] ?? data['id'] ?? entry.key).toString().trim();
        if (id.isEmpty || !seenIds.add(id)) continue;

        final col = data['collection']?.toString() ??
            (data['type'] == 'dispense' ? 'dispense_edit_requests' : defaultCol);
        if (col == 'restock_requests' && data['type'] == null) {
          data['type'] = 'add_stock';
          data['requestType'] = 'add_stock';
        }
        final reqType = (data['requestType'] ?? data['type'] ?? 'request').toString().toLowerCase().trim();
        if (isDoctorOnly && !doctorCanApproveStock) {
          final isStockOnly = reqType == 'add_stock' ||
              reqType == 'edit_medicine' ||
              reqType == 'delete_medicine';
          if (isStockOnly) continue;
        }

        data['id'] = id;
        data['requestId'] = id;
        data['collection'] = col;
        results.add(data);
      }
    }

    scanBox('local_edit_requests', 'edit_requests');
    scanBox(LocalStorageService.restockRequestsBox, 'restock_requests');

    results.sort((a, b) {
      final dtA = parseTimestamp(a['requestedAt'] ?? a['createdAt']);
      final dtB = parseTimestamp(b['requestedAt'] ?? b['createdAt']);
      return dtB.compareTo(dtA);
    });
    return results;
  }

  /// Returns unread notifications from `notificationsBox` scoped to [userId], [role], and [branchId].
  static List<Map<String, dynamic>> getUnreadNotifications({
    required String branchId,
    required String userId,
    required String role,
  }) {
    if (!Hive.isBoxOpen(LocalStorageService.notificationsBox)) return const [];
    final currentRole = role.toLowerCase().trim();
    if (currentRole.contains('madrassa') ||
        currentRole.contains('guardian') ||
        currentRole.contains('parent') ||
        currentRole == 'teacher') {
      return const [];
    }

    final isSuperOrAdmin = currentRole == 'superadmin' ||
        currentRole == 'admin' ||
        currentRole == 'manager' ||
        currentRole == 'hq manager' ||
        currentRole == 'hq_manager' ||
        currentRole == 'hqmanager' ||
        currentRole == 'ceo' ||
        currentRole == 'chairman' ||
        currentRole == 'developer';

    final box = Hive.box(LocalStorageService.notificationsBox);
    final items = <Map<String, dynamic>>[];

    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw is! Map) continue;
      if (raw['seen'] == true) continue;
      final item = Map<String, dynamic>.from(raw);
      item['_key'] = key.toString();

      // 1. User ID check
      final receiverId =
          (item['targetUserId'] ?? item['receiverId'] ?? item['userId'] ?? '').toString().trim();
      if (receiverId.isNotEmpty && receiverId.toLowerCase() != 'all') {
        if (userId.isNotEmpty && userId.toLowerCase() != receiverId.toLowerCase()) {
          continue;
        }
      }

      // 2. Role check
      final targetRole =
          (item['targetRole'] ?? item['receiverRole'] ?? item['role'] ?? '').toString().trim().toLowerCase();
      if (targetRole.isNotEmpty && targetRole != 'all' && !isSuperOrAdmin) {
        if (targetRole != currentRole) {
          final roleMatches =
              (targetRole == 'finance' && (currentRole == 'cashier' || currentRole == 'accountant')) ||
                  (targetRole == 'doctor' && currentRole.contains('doctor')) ||
                  (targetRole == 'receptionist' && currentRole.contains('reception')) ||
                  (targetRole == 'supervisor' && currentRole.contains('supervisor'));
          if (!roleMatches) continue;
        }
      }

      // 3. Branch check
      final notifBranch = (item['branchId'] ?? item['branch_id'] ?? '').toString().trim().toLowerCase();
      if (notifBranch.isNotEmpty && notifBranch != 'all' && notifBranch != 'global') {
        if (branchId.isNotEmpty && branchId != 'all' && branchId != 'global' && !isSuperOrAdmin) {
          if (!matchesBranch(branchId, notifBranch)) continue;
        }
      }

      items.add(item);
    }

    items.sort((a, b) {
      final dtA = parseTimestamp(a['timestamp']);
      final dtB = parseTimestamp(b['timestamp']);
      return dtB.compareTo(dtA);
    });
    return items;
  }

  static DateTime parseTimestamp(dynamic raw) {
    if (raw == null) return DateTime(1970);
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    if (raw is String) return DateTime.tryParse(raw) ?? DateTime(1970);
    if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
    return DateTime(1970);
  }

  static String formatRelativeOrShortTime(dynamic raw) {
    final dt = parseTimestamp(raw);
    if (dt.year <= 1970) return '';
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24 && dt.day == now.day) return '${diff.inHours}h ago';
    return DateFormat('dd MMM, hh:mm a').format(dt.toLocal());
  }

  static IconData getRequestIcon(String type) => switch (type) {
        'patient_edit' => Icons.edit_note_rounded,
        'token_reversal' => Icons.undo_rounded,
        'add_stock' => Icons.add_box_rounded,
        'edit_medicine' => Icons.medication_liquid_rounded,
        'delete_medicine' => Icons.delete_sweep_rounded,
        'token_exception' => Icons.verified_user_rounded,
        'dispense' || 'change_prescription' => Icons.receipt_long_rounded,
        _ => Icons.rule_rounded,
      };

  static String getRequestTypeLabel(String type) => switch (type) {
        'patient_edit' => 'PATIENT EDIT',
        'token_reversal' => 'TOKEN REVERSAL',
        'add_stock' => 'MEDICINE STOCK',
        'edit_medicine' => 'EDIT MEDICINE',
        'delete_medicine' => 'DELETE MEDICINE',
        'token_exception' => 'TOKEN EXCEPTION',
        'dispense' => 'DISPENSE EDIT',
        'change_prescription' => 'PRESCRIPTION',
        _ => type.replaceAll('_', ' ').toUpperCase(),
      };

  static String getRequestTitle(Map<String, dynamic> data) {
    final type = (data['requestType'] ?? data['type'] ?? '').toString().toLowerCase().trim();
    final patientName = (data['patientName'] ??
            data['proposedData']?['name'] ??
            data['originalData']?['name'] ??
            '')
        .toString()
        .trim();
    final serial = (data['tokenSerial'] ?? data['serial'] ?? '').toString().trim();

    return switch (type) {
      'patient_edit' =>
        patientName.isNotEmpty ? 'Patient Edit: $patientName' : 'Patient Details Edit Request',
      'token_reversal' => serial.isNotEmpty
          ? 'Token Reversal: #$serial${patientName.isNotEmpty && patientName != '—' ? ' ($patientName)' : ''}'
          : (patientName.isNotEmpty ? 'Token Reversal: $patientName' : 'Token Reversal Request'),
      'add_stock' => _describeStockTitle('Medicine Stock Request', data),
      'edit_medicine' => _describeStockTitle('Edit Medicine', data),
      'delete_medicine' => _describeStockTitle('Delete Medicine', data),
      'token_exception' =>
        patientName.isNotEmpty ? 'Token Exception: $patientName' : 'Token Exception Request',
      'dispense' || 'change_prescription' =>
        patientName.isNotEmpty ? 'Prescription Edit: $patientName' : 'Prescription Change Request',
      _ => RequestUtils.getTitle(type, patientName.isEmpty ? '—' : patientName),
    };
  }

  static String _describeStockTitle(String prefix, Map<String, dynamic> data) {
    final items = (data['draftItems'] is List && (data['draftItems'] as List).isNotEmpty)
        ? data['draftItems'] as List
        : (data['items'] is List ? data['items'] as List : const []);
    if (items.isEmpty) return prefix;
    final first = items.first;
    final firstName = (first is Map ? (first['name'] ?? '') : '').toString().trim();
    if (items.length == 1 && firstName.isNotEmpty) {
      return '$prefix: $firstName';
    }
    if (firstName.isNotEmpty) {
      return '$prefix: $firstName +${items.length - 1} more';
    }
    return '$prefix (${items.length} items)';
  }

  static String getRequestSubtitle(Map<String, dynamic> data) {
    final type = (data['requestType'] ?? data['type'] ?? '').toString().toLowerCase().trim();
    final reason = (data['reason'] ?? data['restrictionReason'] ?? '').toString().trim();
    final parts = <String>[];

    if (type == 'patient_edit') {
      final orig = data['originalData'] is Map
          ? Map<String, dynamic>.from(data['originalData'] as Map)
          : <String, dynamic>{};
      final prop = data['proposedData'] is Map
          ? Map<String, dynamic>.from(data['proposedData'] as Map)
          : <String, dynamic>{};
      final changed = <String>[];
      final oldName = (orig['name'] ?? orig['patientName'] ?? '').toString().trim();
      final newName = (prop['name'] ?? prop['patientName'] ?? '').toString().trim();
      if (newName.isNotEmpty && oldName != newName) {
        changed.add('Name: ${oldName.isEmpty ? "—" : oldName} → $newName');
      }
      final oldBg = (orig['bloodGroup'] ?? '').toString().trim();
      final newBg = (prop['bloodGroup'] ?? '').toString().trim();
      if (newBg.isNotEmpty && oldBg != newBg) {
        changed.add('Blood: ${oldBg.isEmpty ? "N/A" : oldBg} → $newBg');
      }
      final oldDob = LocalStorageService.tryParseDob(orig['dob'] ?? orig['dateOfBirth']);
      final newDob = LocalStorageService.tryParseDob(prop['dob'] ?? prop['dateOfBirth']);
      final oldDobStr = oldDob != null ? DateFormat('dd-MM-yyyy').format(oldDob) : '';
      final newDobStr = newDob != null ? DateFormat('dd-MM-yyyy').format(newDob) : '';
      if (newDobStr.isNotEmpty && oldDobStr != newDobStr) {
        changed.add('DOB: $newDobStr');
      }
      final oldCnic = (orig['cnic'] ?? orig['guardianCnic'] ?? '').toString().trim();
      final newCnic = (prop['cnic'] ?? prop['guardianCnic'] ?? '').toString().trim();
      if (newCnic.isNotEmpty && oldCnic != newCnic) {
        changed.add('CNIC: $newCnic');
      }
      if (changed.isNotEmpty) {
        parts.add(changed.join(' · '));
      }
    } else if (type == 'add_stock' || type == 'edit_medicine' || type == 'delete_medicine') {
      final items = (data['draftItems'] is List && (data['draftItems'] as List).isNotEmpty)
          ? data['draftItems'] as List
          : (data['items'] is List ? data['items'] as List : const []);
      final medSummaries = <String>[];
      for (final item in items.take(3)) {
        if (item is Map) {
          final n = (item['name'] ?? '').toString().trim();
          final q = item['quantity'];
          if (n.isNotEmpty) {
            medSummaries.add(q != null ? '$n (Qty: $q)' : n);
          }
        }
      }
      if (medSummaries.isNotEmpty) {
        parts.add(medSummaries.join(', '));
      }
    } else if (type == 'token_reversal') {
      final qType = (data['queueType'] ?? '').toString().trim();
      if (qType.isNotEmpty) parts.add('Queue: ${qType.toUpperCase()}');
    }

    if (reason.isNotEmpty) {
      parts.add('Reason: $reason');
    }
    return parts.join('\n');
  }

  /// Shows the compact popover dialog connected directly below the Bell icon.
  static Future<void> showBellPopover({
    required BuildContext context,
    required GlobalKey bellKey,
    required String branchId,
    required String userId,
    required String role,
    required void Function(Map<String, dynamic> requestData) onSelectRequest,
    required VoidCallback onViewAllRequests,
    VoidCallback? onViewAllNotifications,
  }) async {
    await ensureInitialized(branchId: branchId);
    if (!context.mounted) return;

    final renderObj = bellKey.currentContext?.findRenderObject();
    Offset bellTopLeft = Offset(MediaQuery.of(context).size.width - 120, 56);
    Size bellSize = const Size(38, 38);
    if (renderObj is RenderBox && renderObj.hasSize) {
      bellTopLeft = renderObj.localToGlobal(Offset.zero);
      bellSize = renderObj.size;
    }

    final screenSize = MediaQuery.of(context).size;
    const double popoverWidth = 410.0;
    final double bellCenterX = bellTopLeft.dx + bellSize.width / 2;

    // Position the popover horizontally so it stays within screen bounds
    // while its top pointer arrow points directly at bellCenterX.
    double left = bellCenterX - popoverWidth + 44;
    if (left + popoverWidth > screenSize.width - 12) {
      left = screenSize.width - popoverWidth - 12;
    }
    if (left < 12) {
      left = 12;
    }
    final double arrowCenterX = (bellCenterX - left).clamp(24.0, popoverWidth - 24.0);
    final double top = (bellTopLeft.dy + bellSize.height + 4).clamp(48.0, screenSize.height - 260.0);

    await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close notifications',
      barrierColor: Colors.black.withValues(alpha: 0.14),
      transitionDuration: const Duration(milliseconds: 170),
      pageBuilder: (dialogCtx, anim, secondaryAnim) {
        return _BellPopoverDialog(
          left: left,
          top: top,
          width: popoverWidth,
          maxHeight: (screenSize.height - top - 20).clamp(280.0, 540.0),
          arrowCenterX: arrowCenterX,
          branchId: branchId,
          userId: userId,
          role: role,
          onSelectRequest: (req) {
            Navigator.of(dialogCtx).pop();
            final reqId = (req['requestId'] ?? req['id'] ?? '').toString().trim();
            if (reqId.isNotEmpty) {
              RequestPage.focusRequest(reqId);
            }
            onSelectRequest(req);
          },
          onViewAllRequests: () {
            Navigator.of(dialogCtx).pop();
            RequestPage.focusRequest(null);
            onViewAllRequests();
          },
          onViewAllNotifications: onViewAllNotifications == null
              ? null
              : () {
                  Navigator.of(dialogCtx).pop();
                  onViewAllNotifications();
                },
        );
      },
      transitionBuilder: (ctx, anim, _, child) {
        final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.95, end: 1.0).animate(curved),
            alignment: Alignment(
              ((bellCenterX / screenSize.width) * 2 - 1).clamp(-1.0, 1.0),
              ((top / screenSize.height) * 2 - 1).clamp(-1.0, 1.0),
            ),
            child: child,
          ),
        );
      },
    );
  }
}

class _BellPopoverDialog extends StatefulWidget {
  final double left;
  final double top;
  final double width;
  final double maxHeight;
  final double arrowCenterX;
  final String branchId;
  final String userId;
  final String role;
  final void Function(Map<String, dynamic> requestData) onSelectRequest;
  final VoidCallback onViewAllRequests;
  final VoidCallback? onViewAllNotifications;

  const _BellPopoverDialog({
    required this.left,
    required this.top,
    required this.width,
    required this.maxHeight,
    required this.arrowCenterX,
    required this.branchId,
    required this.userId,
    required this.role,
    required this.onSelectRequest,
    required this.onViewAllRequests,
    this.onViewAllNotifications,
  });

  @override
  State<_BellPopoverDialog> createState() => _BellPopoverDialogState();
}

class _BellPopoverDialogState extends State<_BellPopoverDialog> {
  String _tab = 'all'; // 'all' | 'requests' | 'messages'

  Future<void> _markNotificationSeen(String id, Map<String, dynamic> item) async {
    if (!Hive.isBoxOpen(LocalStorageService.notificationsBox)) return;
    try {
      final box = Hive.box(LocalStorageService.notificationsBox);
      final updated = Map<String, dynamic>.from(item)..['seen'] = true;
      await box.put(id, LocalStorageService.sanitize(updated));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? SoftPalette.slate800 : SoftPalette.gray50;
    final borderColor = isDark ? SoftPalette.slate700 : SoftPalette.teal200;
    final listenable = NotificationBellHelper.buildCombinedListenable();

    return Stack(
      children: [
        Positioned(
          left: widget.left,
          top: widget.top,
          width: widget.width,
          child: Material(
            color: Colors.transparent,
            child: ListenableBuilder(
              listenable: listenable,
              builder: (context, _) {
                final pendingRequests = NotificationBellHelper.getPendingRequests(
                  branchId: widget.branchId,
                  role: widget.role,
                );
                final unreadMessages = NotificationBellHelper.getUnreadNotifications(
                  branchId: widget.branchId,
                  userId: widget.userId,
                  role: widget.role,
                );
                final totalCount = pendingRequests.length + unreadMessages.length;

                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Speech-bubble pointer triangle connecting directly to the Bell icon
                    CustomPaint(
                      size: Size(widget.width, 10),
                      painter: _PopoverArrowPainter(
                        arrowCenterX: widget.arrowCenterX,
                        fillColor: isDark ? SoftPalette.slate900 : SoftPalette.teal600,
                        borderColor: borderColor,
                      ),
                    ),
                    Container(
                      constraints: BoxConstraints(maxHeight: widget.maxHeight - 10),
                      decoration: BoxDecoration(
                        color: cardBg,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: borderColor, width: 1.2),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.16),
                            blurRadius: 24,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // ── Connected Header & Summary Banner ──
                          Container(
                            padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: isDark
                                    ? [SoftPalette.slate900, SoftPalette.slate800]
                                    : [SoftPalette.teal600, SoftPalette.teal550],
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(7),
                                      decoration: BoxDecoration(
                                        color: SoftPalette.gray50.withValues(alpha: 0.16),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Icon(
                                        totalCount > 0
                                            ? Icons.notifications_active_rounded
                                            : Icons.notifications_none_rounded,
                                        color: SoftPalette.gray50,
                                        size: 18,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          const Text(
                                            'Notifications & Approvals',
                                            style: TextStyle(
                                              color: SoftPalette.gray50,
                                              fontSize: 14.5,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                          const SizedBox(height: 1),
                                          Text(
                                            totalCount == 0
                                                ? 'No new messages or pending requests'
                                                : _buildSummaryText(
                                                    pendingRequests.length,
                                                    unreadMessages.length,
                                                  ),
                                            style: TextStyle(
                                              color: SoftPalette.gray50.withValues(alpha: 0.88),
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (totalCount > 0)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 9,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: SoftPalette.orange400,
                                          borderRadius: BorderRadius.circular(999),
                                        ),
                                        child: Text(
                                          '$totalCount New',
                                          style: const TextStyle(
                                            color: SoftPalette.gray50,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                // Filter Chips
                                Row(
                                  children: [
                                    _buildFilterTab(
                                      label: 'All ($totalCount)',
                                      keyId: 'all',
                                      isDark: isDark,
                                    ),
                                    const SizedBox(width: 6),
                                    _buildFilterTab(
                                      label: 'Requests (${pendingRequests.length})',
                                      keyId: 'requests',
                                      isDark: isDark,
                                    ),
                                    const SizedBox(width: 6),
                                    _buildFilterTab(
                                      label: 'Messages (${unreadMessages.length})',
                                      keyId: 'messages',
                                      isDark: isDark,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),

                          // ── Scrollable List of Requests & Messages ──
                          Flexible(
                            child: _buildListContent(
                              context: context,
                              isDark: isDark,
                              pendingRequests: pendingRequests,
                              unreadMessages: unreadMessages,
                            ),
                          ),

                          // ── Footer Quick Actions ──
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: isDark ? SoftPalette.slate900 : SoftPalette.slate100,
                              border: Border(
                                top: BorderSide(
                                  color: isDark ? SoftPalette.slate700 : SoftPalette.slate200,
                                ),
                              ),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: TextButton.icon(
                                    onPressed: widget.onViewAllRequests,
                                    icon: Icon(
                                      Icons.rule_rounded,
                                      size: 16,
                                      color: isDark ? SoftPalette.teal300 : SoftPalette.teal600,
                                    ),
                                    label: Text(
                                      'Open All Requests',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: isDark ? SoftPalette.teal300 : SoftPalette.teal600,
                                      ),
                                    ),
                                  ),
                                ),
                                if (widget.onViewAllNotifications != null) ...[
                                  Container(
                                    width: 1,
                                    height: 18,
                                    color: isDark ? SoftPalette.slate700 : SoftPalette.slate300,
                                  ),
                                  Expanded(
                                    child: TextButton.icon(
                                      onPressed: widget.onViewAllNotifications,
                                      icon: Icon(
                                        Icons.notifications_outlined,
                                        size: 16,
                                        color: isDark ? SoftPalette.slate300 : SoftPalette.slate700,
                                      ),
                                      label: Text(
                                        'All Notifications',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: isDark ? SoftPalette.slate300 : SoftPalette.slate700,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  String _buildSummaryText(int reqCount, int msgCount) {
    final parts = <String>[];
    if (reqCount > 0) {
      parts.add('$reqCount pending request${reqCount == 1 ? '' : 's'}');
    }
    if (msgCount > 0) {
      parts.add('$msgCount unread message${msgCount == 1 ? '' : 's'}');
    }
    return 'You have ${parts.join(' & ')}';
  }

  Widget _buildFilterTab({
    required String label,
    required String keyId,
    required bool isDark,
  }) {
    final selected = _tab == keyId;
    return InkWell(
      onTap: () => setState(() => _tab = keyId),
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? SoftPalette.gray50
              : SoftPalette.gray50.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
            color: selected
                ? (isDark ? SoftPalette.slate900 : SoftPalette.teal700)
                : SoftPalette.gray50,
          ),
        ),
      ),
    );
  }

  Widget _buildListContent({
    required BuildContext context,
    required bool isDark,
    required List<Map<String, dynamic>> pendingRequests,
    required List<Map<String, dynamic>> unreadMessages,
  }) {
    final showRequests = _tab == 'all' || _tab == 'requests';
    final showMessages = _tab == 'all' || _tab == 'messages';

    final reqs = showRequests ? pendingRequests : const <Map<String, dynamic>>[];
    final msgs = showMessages ? unreadMessages : const <Map<String, dynamic>>[];

    if (reqs.isEmpty && msgs.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.check_circle_outline_rounded,
              size: 42,
              color: isDark ? SoftPalette.teal300 : SoftPalette.teal500,
            ),
            const SizedBox(height: 10),
            Text(
              'All Caught Up!',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Pending medicine requests, token reversals, patient edits, and alerts will appear here.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: isDark ? SoftPalette.slate350 : SoftPalette.slate600,
              ),
            ),
          ],
        ),
      );
    }

    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      children: [
        if (reqs.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 2, 6, 6),
            child: Row(
              children: [
                Icon(
                  Icons.pending_actions_rounded,
                  size: 14,
                  color: isDark ? SoftPalette.amber200 : SoftPalette.orange500,
                ),
                const SizedBox(width: 6),
                Text(
                  'PENDING REQUESTS & APPROVALS (${reqs.length})',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                    color: isDark ? SoftPalette.amber200 : SoftPalette.orange500,
                  ),
                ),
              ],
            ),
          ),
          for (final req in reqs) _buildRequestTile(context, req, isDark),
        ],
        if (msgs.isNotEmpty) ...[
          if (reqs.isNotEmpty) const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 2, 6, 6),
            child: Row(
              children: [
                Icon(
                  Icons.mark_as_unread_rounded,
                  size: 14,
                  color: isDark ? SoftPalette.teal300 : SoftPalette.teal600,
                ),
                const SizedBox(width: 6),
                Text(
                  'UNREAD MESSAGES (${msgs.length})',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                    color: isDark ? SoftPalette.teal300 : SoftPalette.teal600,
                  ),
                ),
              ],
            ),
          ),
          for (final msg in msgs) _buildMessageTile(context, msg, isDark),
        ],
      ],
    );
  }

  Widget _buildRequestTile(
    BuildContext context,
    Map<String, dynamic> data,
    bool isDark,
  ) {
    final type = (data['requestType'] ?? data['type'] ?? 'request').toString().toLowerCase().trim();
    final title = NotificationBellHelper.getRequestTitle(data);
    final subtitle = NotificationBellHelper.getRequestSubtitle(data);
    final requester = (data['requesterName'] ??
            data['requestedByName'] ??
            data['requestedBy'] ??
            'Staff')
        .toString()
        .trim();
    final campLabel = RequestUtils.resolveRequestCampName(data, widget.branchId);
    final timeStr = NotificationBellHelper.formatRelativeOrShortTime(
      data['requestedAt'] ?? data['createdAt'],
    );
    final badgeBg = RequestUtils.getBadgeColor(type, isDark: isDark);
    final badgeFg = RequestUtils.getTextColor(type, isDark: isDark);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isDark ? SoftPalette.slate900.withValues(alpha: 0.75) : SoftPalette.pureWhiteSoft,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
          color: isDark ? SoftPalette.slate700 : SoftPalette.teal100,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(13),
        onTap: () => widget.onSelectRequest(data),
        child: Padding(
          padding: const EdgeInsets.all(11),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: badgeBg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  NotificationBellHelper.getRequestIcon(type),
                  size: 19,
                  color: badgeFg,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: badgeBg,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            NotificationBellHelper.getRequestTypeLabel(type),
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w800,
                              color: badgeFg,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            campLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: isDark ? SoftPalette.sky350 : SoftPalette.teal600,
                            ),
                          ),
                        ),
                        if (timeStr.isNotEmpty) ...[
                          const Spacer(),
                          Text(
                            timeStr,
                            style: TextStyle(
                              fontSize: 10,
                              color: isDark ? SoftPalette.slate400 : SoftPalette.slate500,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.3,
                          color: isDark ? SoftPalette.slate200 : SoftPalette.slate700,
                        ),
                      ),
                    ],
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Icon(
                          Icons.person_outline_rounded,
                          size: 12,
                          color: isDark ? SoftPalette.slate400 : SoftPalette.slate500,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            'By $requester',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: isDark ? SoftPalette.slate400 : SoftPalette.slate550,
                            ),
                          ),
                        ),
                        Text(
                          'Tap to review →',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: isDark ? SoftPalette.teal300 : SoftPalette.teal600,
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
      ),
    );
  }

  Widget _buildMessageTile(
    BuildContext context,
    Map<String, dynamic> item,
    bool isDark,
  ) {
    final id = (item['_key'] ?? item['id'] ?? '').toString();
    final isUrdu = item['body_ur'] != null && item['body_ur'].toString().isNotEmpty;
    final title =
        ((isUrdu ? item['title_ur'] : item['title_en']) ?? item['title'] ?? 'Notification')
            .toString();
    final body =
        ((isUrdu ? item['body_ur'] : item['body_en']) ?? item['message'] ?? '').toString();
    final category = (item['category'] ?? item['type'] ?? 'ALERT').toString().toUpperCase();
    final timeStr = NotificationBellHelper.formatRelativeOrShortTime(item['timestamp']);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isDark ? SoftPalette.slate900.withValues(alpha: 0.75) : SoftPalette.pureWhiteSoft,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
          color: isDark ? SoftPalette.slate700 : SoftPalette.slate200,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(13),
        onTap: () async {
          await _markNotificationSeen(id, item);
          final targetScreen = (item['targetScreen'] ?? item['target_screen'] ?? '').toString();
          if (targetScreen.isNotEmpty) {
            if (context.mounted) Navigator.of(context).pop();
            CloudMessagingService().handleNotificationTap(item);
          } else if (widget.onViewAllNotifications != null) {
            widget.onViewAllNotifications!();
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(11),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: SoftPalette.teal500.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.notifications_active_outlined,
                  size: 18,
                  color: SoftPalette.teal500,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: isDark ? SoftPalette.slate700 : SoftPalette.slate150,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            category,
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: isDark ? SoftPalette.slate200 : SoftPalette.slate700,
                            ),
                          ),
                        ),
                        const Spacer(),
                        if (timeStr.isNotEmpty)
                          Text(
                            timeStr,
                            style: TextStyle(
                              fontSize: 10,
                              color: isDark ? SoftPalette.slate400 : SoftPalette.slate500,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                      ),
                    ),
                    if (body.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        body,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: isDark ? SoftPalette.slate300 : SoftPalette.slate600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PopoverArrowPainter extends CustomPainter {
  final double arrowCenterX;
  final Color fillColor;
  final Color borderColor;

  const _PopoverArrowPainter({
    required this.arrowCenterX,
    required this.fillColor,
    required this.borderColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(arrowCenterX - 9, size.height)
      ..lineTo(arrowCenterX, 1)
      ..lineTo(arrowCenterX + 9, size.height)
      ..close();

    final fillPaint = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, fillPaint);

    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final strokePath = Path()
      ..moveTo(arrowCenterX - 9, size.height)
      ..lineTo(arrowCenterX, 1)
      ..lineTo(arrowCenterX + 9, size.height);
    canvas.drawPath(strokePath, borderPaint);
  }

  @override
  bool shouldRepaint(covariant _PopoverArrowPainter oldDelegate) {
    return oldDelegate.arrowCenterX != arrowCenterX ||
        oldDelegate.fillColor != fillColor ||
        oldDelegate.borderColor != borderColor;
  }
}
