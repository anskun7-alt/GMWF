// lib/pages/notification_screen.dart

import 'package:gmwf/utils/debounced_box_listenable.dart';
import 'package:flutter/material.dart';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:gmwf_ui/gmwf_ui.dart' show GEmptyIllustration, GEmptyIllustrationKind;
import 'package:gmwf/design/tokens/comfort_colors.dart';
import 'package:gmwf/design/components/app_toast.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:cloud_firestore/cloud_firestore.dart';

import '../services/local_storage_service.dart';
import '../services/cloud_messaging_service.dart';
import '../services/auto_update_service.dart';
import '../widgets/notification_bell_popover.dart';
import 'request.dart';

class NotificationScreen extends StatefulWidget {
  final String branchId;
  final String userId;
  final String role; // admin, supervisor, doctor, receptionist, dispenser, cashier, guardian, etc.
  final bool embedded;
  final void Function(Map<String, dynamic> requestData)? onOpenRequest;
  final VoidCallback? onViewAllRequests;

  const NotificationScreen({
    super.key,
    required this.branchId,
    required this.userId,
    required this.role,
    this.embedded = false,
    this.onOpenRequest,
    this.onViewAllRequests,
  });

  @override
  State<NotificationScreen> createState() => _NotificationScreenState();
}

class _NotificationScreenState extends State<NotificationScreen> {
  late final Future<void> _notificationsBoxReady = _initBoxes();
  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();

  String? _selectedReceiverId;
  String? _selectedReceiverRole;
  String _filterStatus = 'all'; // 'all' | 'unread'
  String _searchQuery = '';

  Future<void> _initBoxes() async {
    await LocalStorageService.openBoxSafe(LocalStorageService.notificationsBox);
    await NotificationBellHelper.ensureInitialized(branchId: widget.branchId);
  }

  void _navigateToRequest(Map<String, dynamic> reqData) {
    final reqId = (reqData['requestId'] ?? reqData['id'])?.toString();
    RequestPage.focusRequest(reqId);
    if (widget.onOpenRequest != null) {
      widget.onOpenRequest!(reqData);
      return;
    }
    final reqBranch = (reqData['branchId'] ?? widget.branchId).toString();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RequestPage(
          branchId: reqBranch.isNotEmpty ? reqBranch : widget.branchId,
          isSupervisor: true,
          initialRequestId: reqId,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _messageController.dispose();
    _titleController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// Check whether an item is scoped to the current user, role, or branch
  bool _isItemForCurrentUser(Map<String, dynamic> item) {
    final currentRole = widget.role.toLowerCase().trim();

    // RULE: Madrassa-related users do NOT receive any notifications
    if (currentRole.contains('madrassa') ||
        currentRole.contains('guardian') ||
        currentRole.contains('parent') ||
        currentRole == 'teacher') {
      return false;
    }

    final isSuperOrAdmin = currentRole == 'superadmin' ||
        currentRole == 'admin' ||
        currentRole == 'manager' ||
        currentRole == 'hq manager' ||
        currentRole == 'hqmanager' ||
        currentRole == 'ceo' ||
        currentRole == 'chairman' ||
        currentRole == 'developer';

    // 1. User ID targeting
    final receiverId = (item['targetUserId'] ?? item['receiverId'] ?? item['userId'] ?? '').toString().trim();
    if (receiverId.isNotEmpty && receiverId.toLowerCase() != 'all') {
      if (widget.userId.isNotEmpty && widget.userId.toLowerCase() != receiverId.toLowerCase()) {
        return false;
      }
    }

    final targetUserIds = item['targetUserIds'] ?? item['receiverIds'];
    if (targetUserIds is List && targetUserIds.isNotEmpty) {
      if (widget.userId.isNotEmpty) {
        final matches = targetUserIds.any((u) => u.toString().toLowerCase() == widget.userId.toLowerCase());
        if (!matches) return false;
      }
    }

    // 2. Role targeting
    final targetRole = (item['targetRole'] ?? item['receiverRole'] ?? item['role'] ?? '').toString().trim().toLowerCase();
    if (targetRole.isNotEmpty && targetRole != 'all') {
      if (!isSuperOrAdmin) {
        if (targetRole != currentRole) {
          final roleMatches = (targetRole == 'guardian' && currentRole.contains('parent')) ||
              (targetRole == 'finance' && (currentRole == 'cashier' || currentRole == 'accountant')) ||
              (targetRole == 'cashier' && currentRole.contains('cashier')) ||
              (targetRole == 'doctor' && currentRole.contains('doctor')) ||
              (targetRole == 'receptionist' && currentRole.contains('reception')) ||
              (targetRole == 'teacher' && currentRole.contains('teacher'));
          if (!roleMatches) return false;
        }
      }
    }

    final targetRoles = item['targetRoles'];
    if (targetRoles is List && targetRoles.isNotEmpty) {
      if (!isSuperOrAdmin) {
        final matches = targetRoles.any((r) {
          final rClean = r.toString().toLowerCase().trim();
          return rClean == currentRole ||
              (rClean == 'finance' && (currentRole == 'cashier' || currentRole == 'accountant')) ||
              (rClean == 'guardian' && currentRole.contains('parent'));
        });
        if (!matches) return false;
      }
    }

    // 3. Branch targeting
    final notifBranch = (item['branchId'] ?? item['branch_id'] ?? '').toString().trim().toLowerCase();
    if (notifBranch.isNotEmpty && notifBranch != 'all' && notifBranch != 'global') {
      if (widget.branchId.isNotEmpty && widget.branchId != 'all' && widget.branchId != 'global') {
        if (!isSuperOrAdmin && widget.branchId.toLowerCase() != notifBranch) {
          return false;
        }
      }
    }

    return true;
  }

  /// Mark single notification as seen locally
  Future<void> _markAsSeen(String id, Map<String, dynamic> item) async {
    if (item['seen'] == true) return;
    try {
      final box = Hive.box(LocalStorageService.notificationsBox);
      final updated = Map<String, dynamic>.from(item);
      updated['seen'] = true;
      await box.put(id, LocalStorageService.sanitize(updated));
    } catch (e) {
      debugPrint('[Notifications] _markAsSeen error: $e');
    }
  }

  /// Mark all notifications as seen
  Future<void> _markAllAsSeen() async {
    try {
      final box = Hive.box(LocalStorageService.notificationsBox);
      for (final key in box.keys) {
        final raw = box.get(key);
        if (raw is Map && raw['seen'] != true) {
          final updated = Map<String, dynamic>.from(raw);
          updated['seen'] = true;
          await box.put(key, LocalStorageService.sanitize(updated));
        }
      }
      if (mounted) {
        AppToast.showSnackBar(context, 
          const SnackBar(content: Text('All notifications marked as read.')),
        );
      }
    } catch (e) {
      debugPrint('[Notifications] _markAllAsSeen error: $e');
    }
  }

  /// Delete single notification
  Future<void> _deleteNotification(String id) async {
    try {
      final box = Hive.box(LocalStorageService.notificationsBox);
      await box.delete(id);
    } catch (e) {
      debugPrint('[Notifications] _deleteNotification error: $e');
    }
  }

  /// Clear all notifications
  Future<void> _clearAllNotifications() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear All Notifications?'),
        content: const Text('This will remove notification history on this device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: SoftPalette.red400,
              foregroundColor: SoftPalette.gray50,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final box = Hive.box(LocalStorageService.notificationsBox);
        await box.clear();
        if (mounted) {
          AppToast.showSnackBar(context, 
            const SnackBar(content: Text('All notifications cleared.')),
          );
        }
      } catch (e) {
        debugPrint('[Notifications] _clearAllNotifications error: $e');
      }
    }
  }

  /// Send notification locally and enqueue for server sync
  Future<void> _sendNotification() async {
    final title = _titleController.text.trim();
    final message = _messageController.text.trim();
    if (message.isEmpty) return;

    final notifId = 'notif_${DateTime.now().millisecondsSinceEpoch}_${const Uuid().v4().substring(0, 6)}';
    final payload = {
      'id': notifId,
      'title': title.isNotEmpty ? title : 'Alert',
      'message': message,
      'category': _selectedReceiverRole != null && _selectedReceiverRole != 'all'
          ? '${_selectedReceiverRole!.toUpperCase()} ALERT'
          : 'GENERAL ALERT',
      'senderId': widget.userId,
      'senderRole': widget.role,
      'targetUserId': _selectedReceiverId ?? 'all',
      'targetRole': _selectedReceiverRole ?? 'all',
      'receiverId': _selectedReceiverId ?? 'all',
      'receiverRole': _selectedReceiverRole ?? 'all',
      'branchId': widget.branchId,
      'seen': false,
      'timestamp': DateTime.now().toIso8601String(),
      'status': 'sent',
    };

    // 1. Save locally to notifications box
    if (Hive.isBoxOpen(LocalStorageService.notificationsBox)) {
      final box = Hive.box(LocalStorageService.notificationsBox);
      await box.put(notifId, LocalStorageService.sanitize(payload));
    }

    // 2. Enqueue for background upload to server
    await LocalStorageService.enqueueSync({
      'type': 'send_notification',
      'branchId': widget.branchId,
      'localId': notifId,
      'data': payload,
    });

    _titleController.clear();
    _messageController.clear();
    _selectedReceiverId = null;
    _selectedReceiverRole = null;
    if (mounted) Navigator.pop(context);
  }

  void _showSendDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.send_rounded, color: SoftPalette.teal500),
            SizedBox(width: 8),
            Text('Send Targeted Notification'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _titleController,
                decoration: const InputDecoration(
                  labelText: 'Title (Optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _selectedReceiverRole,
                hint: const Text('Target Audience / Role'),
                items: const [
                  DropdownMenuItem(value: 'all', child: Text('All Users & Roles')),
                  DropdownMenuItem(value: 'cashier', child: Text('Cashiers / Finance')),
                  DropdownMenuItem(value: 'doctor', child: Text('Doctors')),
                  DropdownMenuItem(value: 'receptionist', child: Text('Receptionists')),
                  DropdownMenuItem(value: 'dispenser', child: Text('Dispensary Staff')),
                  DropdownMenuItem(value: 'supervisor', child: Text('Supervisors & Admins')),
                ],
                onChanged: (val) => setState(() => _selectedReceiverRole = val),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _messageController,
                decoration: const InputDecoration(
                  labelText: 'Notification Message *',
                  border: OutlineInputBorder(),
                ),
                maxLines: 3,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: _sendNotification,
            style: ElevatedButton.styleFrom(
              backgroundColor: SoftPalette.teal500,
              foregroundColor: SoftPalette.gray50,
            ),
            child: const Text('Send Alert'),
          ),
        ],
      ),
    );
  }

  void _showHolidayBroadcastDialog() {
    final holidayTitleCtrl = TextEditingController(text: '🏖️ Madrassa Holiday Announcement');
    final holidayMsgCtrl = TextEditingController(text: 'Dear Parents, please note that Madrassa will remain closed tomorrow due to an official holiday.');
    final holidayDateCtrl = TextEditingController(text: DateTime.now().add(const Duration(days: 1)).toIso8601String().split('T').first);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.campaign_rounded, color: SoftPalette.amber200),
            SizedBox(width: 8),
            Text('Broadcast Holiday Alert'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'This will broadcast an instant push notification to ALL guardians across the branch.',
                style: TextStyle(fontSize: 12, color: SoftPalette.gray350),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: holidayTitleCtrl,
                decoration: const InputDecoration(
                  labelText: 'Announcement Title',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: holidayDateCtrl,
                decoration: const InputDecoration(
                  labelText: 'Holiday Date (YYYY-MM-DD)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: holidayMsgCtrl,
                decoration: const InputDecoration(
                  labelText: 'Message for Parents',
                  border: OutlineInputBorder(),
                ),
                maxLines: 3,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.send_rounded, size: 18),
            label: const Text('Broadcast Now'),
            style: ElevatedButton.styleFrom(
              backgroundColor: SoftPalette.emerald500,
              foregroundColor: SoftPalette.gray50,
            ),
            onPressed: () async {
              final title = holidayTitleCtrl.text.trim();
              final msg = holidayMsgCtrl.text.trim();
              final date = holidayDateCtrl.text.trim();
              if (msg.isEmpty) return;

              final nav = Navigator.of(ctx);

              await CloudMessagingService().broadcastHolidayAnnouncement(
                branchId: widget.branchId,
                title: title.isNotEmpty ? title : '🏖️ Madrassa Holiday Announcement',
                message: msg,
                holidayDate: date,
              );

              if (mounted) {
                nav.pop();
                AppToast.fromSnackBar(
                  const SnackBar(
                    content: Text('🎉 Holiday Announcement broadcasted to all guardians!'),
                    backgroundColor: SoftPalette.emerald500,
                  ),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  void _showTestNotificationPicker() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.notifications_active, color: SoftPalette.teal500),
                  SizedBox(width: 8),
                  Text(
                    'Test Notification Triggers',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: context.adapt(SoftPalette.yellow100),
                  child: Icon(Icons.volunteer_activism, color: SoftPalette.orange400),
                ),
                title: const Text('Pending Donation Verification Alert'),
                subtitle: const Text('Simulate cashier/finance notification (routes to Donations)'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await CloudMessagingService().dispatchDonationVerificationAlert(
                    branchId: widget.branchId,
                    receiptNo: 'REC-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}',
                    donorName: 'Haji Muhammad Ali',
                    amount: 50000,
                    collectorName: 'Branch Cashier',
                  );
                },
              ),
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: context.adapt(SoftPalette.slate100),
                  child: Icon(Icons.system_update, color: SoftPalette.sky500),
                ),
                title: const Text('App Update Notification'),
                subtitle: const Text('Simulate version release notification (opens updater)'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await CloudMessagingService().dispatchAppUpdateAlert(
                    newVersion: AutoUpdateService.currentVersion,
                    releaseNotes: 'Performance improvements, real-time sync upgrades, and enhanced notifications.',
                  );
                },
              ),
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: context.adapt(SoftPalette.emerald100),
                  child: Icon(Icons.payment, color: SoftPalette.green400),
                ),
                title: const Text('Student Fee Payment Alert'),
                subtitle: const Text('Simulate fee receipt for guardian (routes to ledger)'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await CloudMessagingService().dispatchFeePaymentAlert(
                    branchId: widget.branchId,
                    studentId: 'STD-101',
                    studentName: 'Muhammad Hamza',
                    guardianUserId: widget.userId,
                    amount: 2500,
                    remainingBalance: 0,
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final c = context.comfort;

    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        backgroundColor: c.surface,
        foregroundColor: c.textPrimary,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        toolbarHeight: widget.embedded ? 48 : 56,
        title: widget.embedded
            ? Text(
                'Activity & Request Feed',
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                  color: c.textSecondary,
                ),
              )
            : Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: c.brandSoft,
                    ),
                    child: Image.asset(
                      kAppLogoAsset,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) =>
                          Icon(Icons.notifications, size: 18, color: c.brand),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Notifications',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: c.textPrimary,
                    ),
                  ),
                ],
              ),
        actions: [
          IconButton(
            tooltip: 'Test Notification System',
            icon: Icon(Icons.notifications_active_outlined, color: c.warning),
            onPressed: _showTestNotificationPicker,
          ),
          if (widget.role == 'admin' || widget.role == 'supervisor' || widget.role == 'chairman')
            IconButton(
              tooltip: 'Broadcast Holiday Announcement',
              icon: Icon(Icons.campaign_outlined, color: c.brand),
              onPressed: _showHolidayBroadcastDialog,
            ),
          IconButton(
            tooltip: 'Mark all as read',
            icon: Icon(Icons.done_all_rounded, color: c.textSecondary),
            onPressed: _markAllAsSeen,
          ),
          IconButton(
            tooltip: 'Clear history',
            icon: Icon(Icons.delete_sweep_outlined, color: c.textSecondary),
            onPressed: _clearAllNotifications,
          ),
        ],
      ),
      floatingActionButton: (widget.role == 'admin' || widget.role == 'supervisor' || widget.role == 'chairman')
          ? FloatingActionButton.extended(
              onPressed: _showSendDialog,
              icon: const Icon(Icons.send_rounded),
              label: const Text('Send Alert'),
              backgroundColor: SoftPalette.teal500,
              foregroundColor: SoftPalette.gray50,
            )
          : null,
      body: FutureBuilder(
        // Opened once; a future made in build re-ran on every rebuild.
        future: _notificationsBoxReady,
        builder: (context, snapshot) {
          if (!Hive.isBoxOpen(LocalStorageService.notificationsBox)) {
            return const Center(child: CircularProgressIndicator());
          }

          final box = Hive.box(LocalStorageService.notificationsBox);

          return ListenableBuilder(
            listenable: NotificationBellHelper.buildCombinedListenable(),
            builder: (context, _) {
              final rawItems = <Map<String, dynamic>>[];
              for (final key in box.keys) {
                final raw = box.get(key);
                if (raw is Map) {
                  final map = Map<String, dynamic>.from(raw);
                  map['_key'] = key.toString();
                  if (_isItemForCurrentUser(map)) {
                    rawItems.add(map);
                  }
                }
              }

              // Sort latest first (each timestamp parsed once, not twice per comparison).
              final stamps = <Map<String, dynamic>, DateTime>{
                for (final m in rawItems) m: DateTime.tryParse(m['timestamp']?.toString() ?? '') ?? DateTime(1970),
              };
              rawItems.sort((a, b) => stamps[b]!.compareTo(stamps[a]!));

              // Also fetch pending requests (Medicine Stock, Token Reversal, Patient Edit, etc.)
              final pendingRequests = NotificationBellHelper.getPendingRequests(
                branchId: widget.branchId,
                role: widget.role,
              ).where((req) {
                if (_searchQuery.isNotEmpty) {
                  final t = NotificationBellHelper.getRequestTitle(req).toLowerCase();
                  final s = NotificationBellHelper.getRequestSubtitle(req).toLowerCase();
                  if (!t.contains(_searchQuery) && !s.contains(_searchQuery)) {
                    return false;
                  }
                }
                return true;
              }).toList();

              // Filter by status & search
              final items = rawItems.where((item) {
                if (_filterStatus == 'unread' && item['seen'] == true) {
                  return false;
                }
                if (_searchQuery.isNotEmpty) {
                  final title = (item['title'] ?? item['title_en'] ?? item['title_ur'] ?? '').toString().toLowerCase();
                  final message = (item['message'] ?? item['body_en'] ?? item['body_ur'] ?? '').toString().toLowerCase();
                  if (!title.contains(_searchQuery) && !message.contains(_searchQuery)) {
                    return false;
                  }
                }
                return true;
              }).toList();

              return Column(
                children: [
                  // Filter and Search Header
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    color: isDark ? SoftPalette.slate800 : SoftPalette.slate100,
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _searchController,
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: 'Search notifications...',
                              prefixIcon: const Icon(Icons.search, size: 20),
                              suffixIcon: _searchQuery.isNotEmpty
                                  ? IconButton(
                                      icon: const Icon(Icons.clear, size: 18),
                                      onPressed: () {
                                        _searchController.clear();
                                        setState(() => _searchQuery = '');
                                      },
                                    )
                                  : null,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide.none,
                              ),
                              filled: true,
                              fillColor: isDark ? SoftPalette.slate700 : SoftPalette.gray50,
                            ),
                            onChanged: (val) => setState(() => _searchQuery = val.trim().toLowerCase()),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: const Text('All'),
                          selected: _filterStatus == 'all',
                          onSelected: (_) => setState(() => _filterStatus = 'all'),
                        ),
                        const SizedBox(width: 4),
                        ChoiceChip(
                          label: const Text('Unread'),
                          selected: _filterStatus == 'unread',
                          onSelected: (_) => setState(() => _filterStatus = 'unread'),
                        ),
                      ],
                    ),
                  ),

                  // Notifications & Pending Requests List
                  Expanded(
                    child: (items.isEmpty && pendingRequests.isEmpty)
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const GEmptyIllustration(
                                    GEmptyIllustrationKind.notifications,
                                    size: 156,
                                    fallbackIcon: Icons.notifications_none_outlined,
                                  ),
                                  const SizedBox(height: 14),
                                  Text(
                                    _filterStatus == 'unread'
                                        ? 'No unread notifications or pending requests'
                                        : 'No notifications yet',
                                    style: TextStyle(
                                      color: context.adapt(SoftPalette.gray500),
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    _filterStatus == 'unread'
                                        ? 'You are all caught up on alerts and updates.'
                                        : 'New alerts, approvals, and announcements will appear here.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: context.adapt(SoftPalette.gray400),
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : ListView(
                            padding: const EdgeInsets.all(12),
                            children: [
                              if (pendingRequests.isNotEmpty) ...[
                                Container(
                                  margin: const EdgeInsets.only(bottom: 10),
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                  decoration: BoxDecoration(
                                    color: isDark
                                        ? SoftPalette.teal700.withValues(alpha: 0.35)
                                        : SoftPalette.teal100m,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: isDark ? SoftPalette.teal500 : SoftPalette.teal300,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.pending_actions_rounded,
                                        size: 20,
                                        color: isDark ? SoftPalette.amber200 : SoftPalette.teal700,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          'Pending Requests & Approvals (${pendingRequests.length})',
                                          style: TextStyle(
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.w800,
                                            color: isDark ? SoftPalette.gray50 : SoftPalette.teal700,
                                          ),
                                        ),
                                      ),
                                      TextButton.icon(
                                        onPressed: () {
                                          RequestPage.focusRequest(null);
                                          if (widget.onViewAllRequests != null) {
                                            widget.onViewAllRequests!();
                                          } else {
                                            Navigator.of(context).push(
                                              MaterialPageRoute(
                                                builder: (_) => RequestPage(
                                                  branchId: widget.branchId,
                                                  isSupervisor: true,
                                                ),
                                              ),
                                            );
                                          }
                                        },
                                        icon: const Icon(Icons.open_in_new_rounded, size: 15),
                                        label: const Text(
                                          'View All',
                                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                for (final req in pendingRequests)
                                  _buildPendingRequestNotificationCard(context, req, isDark),
                                if (items.isNotEmpty) const SizedBox(height: 12),
                              ],
                              for (int index = 0; index < items.length; index++)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Builder(
                                    builder: (context) {
                                      final item = items[index];
                                      final id = item['_key'] ?? item['id']?.toString() ?? '$index';
                                      final seen = item['seen'] == true;
                                      final isUrdu = item['body_ur'] != null && item['body_ur'].toString().isNotEmpty;

                                      final title = (isUrdu ? item['title_ur'] : item['title_en']) ?? item['title'] ?? 'Notification';
                                      final body = (isUrdu ? item['body_ur'] : item['body_en']) ?? item['message'] ?? '';
                                      final category = (item['category'] ?? item['type'] ?? 'Notification').toString().toUpperCase();
                                      final tsStr = item['timestamp']?.toString();
                                      final dt = tsStr != null ? DateTime.tryParse(tsStr) : null;
                                      final timeDisplay = dt != null ? DateFormat('dd MMM yyyy, hh:mm a').format(dt.toLocal()) : '';
                                      final targetScreen = item['targetScreen'] ?? item['target_screen'] ?? '';

                              return Dismissible(
                                key: Key(id),
                                direction: DismissDirection.endToStart,
                                background: Container(
                                  alignment: Alignment.centerRight,
                                  padding: const EdgeInsets.symmetric(horizontal: 20),
                                  decoration: BoxDecoration(
                                    color: SoftPalette.red400,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Icon(Icons.delete, color: SoftPalette.gray50),
                                ),
                                onDismissed: (_) => _deleteNotification(id),
                                child: Card(
                                  elevation: seen ? 0 : 2,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    side: BorderSide(
                                      color: seen ? Colors.transparent : SoftPalette.teal500.withAlpha(120),
                                      width: 1.5,
                                    ),
                                  ),
                                  color: seen
                                      ? (isDark ? SoftPalette.slate800 : SoftPalette.gray50)
                                      : (isDark ? SoftPalette.emerald700.withAlpha(60) : SoftPalette.emerald50m),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(12),
                                    onTap: () {
                                      _markAsSeen(id, item);
                                      if (targetScreen.toString().isNotEmpty) {
                                        CloudMessagingService().handleNotificationTap(item);
                                      }
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              // App Logo Icon
                                              Container(
                                                width: 36,
                                                height: 36,
                                                decoration: BoxDecoration(
                                                  shape: BoxShape.circle,
                                                  color: seen
                                                      ? (isDark ? SoftPalette.slate700 : SoftPalette.slate150)
                                                      : SoftPalette.teal500,
                                                ),
                                                padding: const EdgeInsets.all(4),
                                                child: Image.asset(
                                                  kAppLogoAsset,
                                                  fit: BoxFit.contain,
                                                  errorBuilder: (context, error, stackTrace) => Icon(
                                                    _getNotificationIcon(item['type'] ?? item['category']),
                                                    size: 18,
                                                    color: seen ? SoftPalette.gray350 : SoftPalette.gray50,
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
                                                        const Text(
                                                          kAppTitle,
                                                          style: TextStyle(
                                                            color: SoftPalette.teal500,
                                                            fontSize: 11,
                                                            fontWeight: FontWeight.bold,
                                                          ),
                                                        ),
                                                        const SizedBox(width: 6),
                                                        Container(
                                                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                                          decoration: BoxDecoration(
                                                            color: isDark ? SoftPalette.slate700 : SoftPalette.slate150,
                                                            borderRadius: BorderRadius.circular(4),
                                                          ),
                                                          child: Text(
                                                            category,
                                                            style: TextStyle(
                                                              fontSize: 9,
                                                              fontWeight: FontWeight.w600,
                                                              color: isDark ? SoftPalette.slate200 : SoftPalette.slate600,
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                    const SizedBox(height: 2),
                                                    Text(
                                                      title.toString(),
                                                      style: TextStyle(
                                                        fontWeight: seen ? FontWeight.w600 : FontWeight.bold,
                                                        fontSize: 14.5,
                                                        color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                                                      ),
                                                    ),
                                                    if (timeDisplay.isNotEmpty) ...[
                                                      const SizedBox(height: 2),
                                                      Text(
                                                        timeDisplay,
                                                        style: TextStyle(
                                                          fontSize: 11,
                                                          color: SoftPalette.gray350,
                                                        ),
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                              ),
                                              if (!seen)
                                                Container(
                                                  width: 10,
                                                  height: 10,
                                                  margin: const EdgeInsets.only(top: 4, left: 4),
                                                  decoration: const BoxDecoration(
                                                    color: SoftPalette.teal500,
                                                    shape: BoxShape.circle,
                                                  ),
                                                ),
                                            ],
                                          ),
                                          const SizedBox(height: 8),
                                          Directionality(
                                            textDirection: isUrdu ? TextDirection.rtl : TextDirection.ltr,
                                            child: Text(
                                              body.toString(),
                                              style: TextStyle(
                                                fontSize: 13,
                                                color: isDark ? SoftPalette.slate200 : SoftPalette.slate700,
                                              ),
                                            ),
                                          ),
                                          // Action button for access restore request or open details
                                          Builder(
                                            builder: (ctx) {
                                              final isRestoreReq = (item['type'] ?? item['category'] ?? '').toString().toLowerCase().contains('access_restore') ||
                                                  (item['title'] ?? '').toString().contains('Access Restore Request');
                                              final isHandled = item['handled'] == true;
                                              final currentRole = widget.role.toLowerCase().trim();
                                              final canAllow = currentRole == 'hq manager' ||
                                                  currentRole == 'admin' ||
                                                  currentRole == 'chairman' ||
                                                  currentRole == 'supervisor' ||
                                                  currentRole == 'superadmin';

                                              if (isRestoreReq && canAllow) {
                                                return Padding(
                                                  padding: const EdgeInsets.only(top: 8),
                                                  child: Row(
                                                    mainAxisAlignment: MainAxisAlignment.end,
                                                    children: [
                                                      if (isHandled) ...[
                                                        Container(
                                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                                          decoration: BoxDecoration(
                                                            color: SoftPalette.green400.withValues(alpha: 0.15),
                                                            borderRadius: BorderRadius.circular(8),
                                                            border: Border.all(color: SoftPalette.green400.withValues(alpha: 0.4)),
                                                          ),
                                                          child: const Row(
                                                            mainAxisSize: MainAxisSize.min,
                                                            children: [
                                                              Icon(Icons.check_circle_rounded, size: 14, color: SoftPalette.green400),
                                                              SizedBox(width: 4),
                                                              Text('Access Allowed', style: TextStyle(color: SoftPalette.green400, fontSize: 11, fontWeight: FontWeight.bold)),
                                                            ],
                                                          ),
                                                        ),
                                                      ] else ...[
                                                        ElevatedButton.icon(
                                                          style: ElevatedButton.styleFrom(
                                                            backgroundColor: SoftPalette.emerald350,
                                                            foregroundColor: SoftPalette.gray50,
                                                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                                            elevation: 0,
                                                          ),
                                                          icon: const Icon(Icons.lock_open_rounded, size: 16),
                                                          label: const Text('Allow Access', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                                          onPressed: () => _handleAllowAccessFromNotification(id, item),
                                                        ),
                                                      ],
                                                    ],
                                                  ),
                                                );
                                              }

                                              if (targetScreen.toString().isNotEmpty) {
                                                return Align(
                                                  alignment: Alignment.centerRight,
                                                  child: TextButton.icon(
                                                    style: TextButton.styleFrom(
                                                      visualDensity: VisualDensity.compact,
                                                      foregroundColor: SoftPalette.teal500,
                                                    ),
                                                    icon: const Icon(Icons.arrow_forward_rounded, size: 16),
                                                    label: const Text('Open Details'),
                                                    onPressed: () {
                                                      _markAsSeen(id, item);
                                                      CloudMessagingService().handleNotificationTap(item);
                                                    },
                                                  ),
                                                );
                                              }
                                              return const SizedBox.shrink();
                                            },
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                                    },
                                  ),
                                ),
                            ],
                          ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildPendingRequestNotificationCard(
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

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isDark ? SoftPalette.teal500.withAlpha(140) : SoftPalette.teal300,
          width: 1.4,
        ),
      ),
      color: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _navigateToRequest(data),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: badgeBg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  NotificationBellHelper.getRequestIcon(type),
                  size: 20,
                  color: badgeFg,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: badgeBg,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            NotificationBellHelper.getRequestTypeLabel(type),
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: badgeFg,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          campLabel,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: isDark ? SoftPalette.sky350 : SoftPalette.teal600,
                          ),
                        ),
                        const Spacer(),
                        if (timeStr.isNotEmpty)
                          Text(
                            timeStr,
                            style: const TextStyle(
                              fontSize: 11,
                              color: SoftPalette.gray350,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14.5,
                        color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: isDark ? SoftPalette.slate200 : SoftPalette.slate700,
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Text(
                          'Requested by $requester',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: isDark ? SoftPalette.slate400 : SoftPalette.slate550,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          'Open Request →',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
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

  /// Handle "Allow Access" directly from Notification Card
  Future<void> _handleAllowAccessFromNotification(String notifId, Map<String, dynamic> item) async {
    final uid = (item['userId'] ?? item['targetUserId'] ?? item['meta']?['userId'] ?? '').toString();
    final name = (item['requesterName'] ?? item['name'] ?? item['meta']?['name'] ?? 'User').toString();
    final branch = (item['branchId'] ?? item['meta']?['branchId'] ?? widget.branchId).toString();
    final email = (item['email'] ?? item['meta']?['email'] ?? '').toString();

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.check_circle_rounded, color: SoftPalette.green400),
            SizedBox(width: 8),
            Text('Allow App Access'),
          ],
        ),
        content: Text('Confirm and restore app access for $name?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.lock_open_rounded, size: 16),
            label: const Text('Allow & Restore'),
            style: ElevatedButton.styleFrom(
              backgroundColor: SoftPalette.green400,
              foregroundColor: SoftPalette.gray50,
            ),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final nowIso = DateTime.now().toIso8601String();
    final updates = <String, dynamic>{
      'status': 'active',
      'accountStatus': 'active',
      'isActive': true,
      'isRevoked': false,
      'accessRevoked': false,
      'restoreRequested': false,
      'restoreRequestStatus': 'approved',
      'restoredAt': nowIso,
      'restoredBy': widget.role,
      'revocationReason': null,
      'revokedAt': null,
      'updatedAt': nowIso,
    };

    // 1. Update in local Hive
    if (Hive.isBoxOpen('local_users')) {
      final box = Hive.box('local_users');
      for (final key in [uid, email]) {
        if (key.isEmpty) continue;
        final raw = box.get(key);
        if (raw is Map) {
          final u = Map<String, dynamic>.from(raw)..addAll(updates);
          await box.put(key, u);
        }
      }
      for (final k in box.keys) {
        final val = box.get(k);
        if (val is Map && (val['uid'] == uid || val['id'] == uid)) {
          final u = Map<String, dynamic>.from(val)..addAll(updates);
          await box.put(k, u);
        }
      }
      await box.flush();
    }

    // 2. Update Firestore
    if (uid.isNotEmpty) {
      try {
        await FirebaseFirestore.instance.collection('users').doc(uid).set({
          ...updates,
          'restoredAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true)).timeout(const Duration(seconds: 4));

        if (branch.isNotEmpty && branch != 'all' && branch != 'global') {
          await FirebaseFirestore.instance.collection('branches').doc(branch).collection('users').doc(uid).set({
            ...updates,
            'restoredAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true)).timeout(const Duration(seconds: 3));
        }
      } catch (_) {}
    }

    // 3. Mark notification as handled
    try {
      if (Hive.isBoxOpen(LocalStorageService.notificationsBox)) {
        final nBox = Hive.box(LocalStorageService.notificationsBox);
        final updatedNotif = Map<String, dynamic>.from(item)
          ..['handled'] = true
          ..['seen'] = true;
        await nBox.put(notifId, LocalStorageService.sanitize(updatedNotif));
      }
    } catch (_) {}

    // 4. Send confirmation notification back to user
    try {
      final clientNotifId = 'restored_${uid}_${DateTime.now().millisecondsSinceEpoch}';
      final notif = {
        'id': clientNotifId,
        'title': '🎉 Access Restored',
        'message': 'Your app access has been approved and restored by the HQ Manager. You can now log in normally.',
        'category': 'Account Alert',
        'type': 'access_restored',
        'targetUserId': uid,
        'branchId': branch,
        'timestamp': nowIso,
        'seen': false,
      };
      if (Hive.isBoxOpen(LocalStorageService.notificationsBox)) {
        await Hive.box(LocalStorageService.notificationsBox).put(clientNotifId, notif);
      }
    } catch (_) {}

    if (mounted) {
      setState(() {});
      AppToast.showSnackBar(context, 
        SnackBar(
          content: Text('✅ Access allowed and restored for $name'),
          backgroundColor: SoftPalette.green400,
        ),
      );
    }
  }

  IconData _getNotificationIcon(dynamic type) {
    final t = type?.toString().toLowerCase() ?? '';
    if (t.contains('restore') || t.contains('access') || t.contains('revoke')) return Icons.lock_open_rounded;
    if (t.contains('donation')) return Icons.volunteer_activism_outlined;
    if (t.contains('update')) return Icons.system_update_alt_rounded;
    if (t.contains('fee') || t.contains('salary') || t.contains('finance')) return Icons.account_balance_wallet_outlined;
    if (t.contains('madrassa') || t.contains('student')) return Icons.menu_book_outlined;
    if (t.contains('token') || t.contains('doctor')) return Icons.medical_services_outlined;
    if (t.contains('patient') || t.contains('reception')) return Icons.person_outline;
    if (t.contains('inventory')) return Icons.inventory_2_outlined;
    return Icons.notifications_outlined;
  }
}
