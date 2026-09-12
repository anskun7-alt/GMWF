// lib/pages/notification_screen.dart

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:cloud_firestore/cloud_firestore.dart';

import '../services/local_storage_service.dart';
import '../services/cloud_messaging_service.dart';

class NotificationScreen extends StatefulWidget {
  final String branchId;
  final String userId;
  final String role; // admin, supervisor, doctor, receptionist, dispenser, cashier, guardian, etc.

  const NotificationScreen({
    super.key,
    required this.branchId,
    required this.userId,
    required this.role,
  });

  @override
  State<NotificationScreen> createState() => _NotificationScreenState();
}

class _NotificationScreenState extends State<NotificationScreen> {
  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();

  String? _selectedReceiverId;
  String? _selectedReceiverRole;
  String _filterStatus = 'all'; // 'all' | 'unread'
  String _searchQuery = '';

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
        ScaffoldMessenger.of(context).showSnackBar(
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
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
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
          ScaffoldMessenger.of(context).showSnackBar(
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
            Icon(Icons.send_rounded, color: Color(0xFF0D9488)),
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
              backgroundColor: const Color(0xFF0D9488),
              foregroundColor: Colors.white,
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
            Icon(Icons.campaign_rounded, color: Colors.amber),
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
                style: TextStyle(fontSize: 12, color: Colors.grey),
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
              backgroundColor: const Color(0xFF059669),
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              final title = holidayTitleCtrl.text.trim();
              final msg = holidayMsgCtrl.text.trim();
              final date = holidayDateCtrl.text.trim();
              if (msg.isEmpty) return;

              final messenger = ScaffoldMessenger.of(context);
              final nav = Navigator.of(ctx);

              await CloudMessagingService().broadcastHolidayAnnouncement(
                branchId: widget.branchId,
                title: title.isNotEmpty ? title : '🏖️ Madrassa Holiday Announcement',
                message: msg,
                holidayDate: date,
              );

              if (mounted) {
                nav.pop();
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text('🎉 Holiday Announcement broadcasted to all guardians!'),
                    backgroundColor: Color(0xFF059669),
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
                  Icon(Icons.notifications_active, color: Color(0xFF0D9488)),
                  SizedBox(width: 8),
                  Text(
                    'Test Notification Triggers',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFFEF3C7),
                  child: Icon(Icons.volunteer_activism, color: Color(0xFFD97706)),
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
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFE0F2FE),
                  child: Icon(Icons.system_update, color: Color(0xFF0284C7)),
                ),
                title: const Text('App Update Notification'),
                subtitle: const Text('Simulate version release notification (opens updater)'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await CloudMessagingService().dispatchAppUpdateAlert(
                    newVersion: '1.5.0',
                    releaseNotes: 'Performance improvements, real-time sync upgrades, and enhanced notifications.',
                  );
                },
              ),
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFDCFCE7),
                  child: Icon(Icons.payment, color: Color(0xFF16A34A)),
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

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withAlpha(20),
              ),
              child: Image.asset(
                kAppLogoAsset,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) => const Icon(Icons.notifications, size: 20),
              ),
            ),
            const SizedBox(width: 10),
            const Text('Notifications'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Test Notification System',
            icon: const Icon(Icons.notifications_active_outlined, color: Colors.amber),
            onPressed: _showTestNotificationPicker,
          ),
          if (widget.role == 'admin' || widget.role == 'supervisor' || widget.role == 'chairman')
            IconButton(
              tooltip: 'Broadcast Holiday Announcement',
              icon: const Icon(Icons.campaign_outlined, color: Colors.greenAccent),
              onPressed: _showHolidayBroadcastDialog,
            ),
          IconButton(
            tooltip: 'Mark all as read',
            icon: const Icon(Icons.done_all),
            onPressed: _markAllAsSeen,
          ),
          IconButton(
            tooltip: 'Clear history',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _clearAllNotifications,
          ),
        ],
      ),
      floatingActionButton: (widget.role == 'admin' || widget.role == 'supervisor' || widget.role == 'chairman')
          ? FloatingActionButton.extended(
              onPressed: _showSendDialog,
              icon: const Icon(Icons.send_rounded),
              label: const Text('Send Alert'),
              backgroundColor: const Color(0xFF0D9488),
              foregroundColor: Colors.white,
            )
          : null,
      body: FutureBuilder(
        future: LocalStorageService.openBoxSafe(LocalStorageService.notificationsBox),
        builder: (context, snapshot) {
          if (!Hive.isBoxOpen(LocalStorageService.notificationsBox)) {
            return const Center(child: CircularProgressIndicator());
          }

          final box = Hive.box(LocalStorageService.notificationsBox);

          return ValueListenableBuilder<Box>(
            valueListenable: box.listenable(),
            builder: (context, box, _) {
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

              // Sort latest first
              rawItems.sort((a, b) {
                final tsA = DateTime.tryParse(a['timestamp']?.toString() ?? '') ?? DateTime(1970);
                final tsB = DateTime.tryParse(b['timestamp']?.toString() ?? '') ?? DateTime(1970);
                return tsB.compareTo(tsA);
              });

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
                    color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
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
                              fillColor: isDark ? const Color(0xFF334155) : Colors.white,
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

                  // Notifications List
                  Expanded(
                    child: items.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.notifications_none_outlined, size: 64, color: Colors.grey.shade400),
                                const SizedBox(height: 12),
                                Text(
                                  _filterStatus == 'unread'
                                      ? 'No unread notifications'
                                      : 'No notifications yet',
                                  style: TextStyle(color: Colors.grey.shade600, fontSize: 16),
                                ),
                              ],
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.all(12),
                            itemCount: items.length,
                            separatorBuilder: (_, index) => const SizedBox(height: 8),
                            itemBuilder: (context, index) {
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
                                    color: Colors.red.shade400,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Icon(Icons.delete, color: Colors.white),
                                ),
                                onDismissed: (_) => _deleteNotification(id),
                                child: Card(
                                  elevation: seen ? 0 : 2,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    side: BorderSide(
                                      color: seen ? Colors.transparent : const Color(0xFF0D9488).withAlpha(120),
                                      width: 1.5,
                                    ),
                                  ),
                                  color: seen
                                      ? (isDark ? const Color(0xFF1E293B) : Colors.white)
                                      : (isDark ? const Color(0xFF064E3B).withAlpha(60) : const Color(0xFFF0FDF4)),
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
                                                      ? (isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0))
                                                      : const Color(0xFF0D9488),
                                                ),
                                                padding: const EdgeInsets.all(4),
                                                child: Image.asset(
                                                  kAppLogoAsset,
                                                  fit: BoxFit.contain,
                                                  errorBuilder: (context, error, stackTrace) => Icon(
                                                    _getNotificationIcon(item['type'] ?? item['category']),
                                                    size: 18,
                                                    color: seen ? Colors.grey : Colors.white,
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
                                                            color: Color(0xFF0D9488),
                                                            fontSize: 11,
                                                            fontWeight: FontWeight.bold,
                                                          ),
                                                        ),
                                                        const SizedBox(width: 6),
                                                        Container(
                                                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                                          decoration: BoxDecoration(
                                                            color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                                                            borderRadius: BorderRadius.circular(4),
                                                          ),
                                                          child: Text(
                                                            category,
                                                            style: TextStyle(
                                                              fontSize: 9,
                                                              fontWeight: FontWeight.w600,
                                                              color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569),
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
                                                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                                                      ),
                                                    ),
                                                    if (timeDisplay.isNotEmpty) ...[
                                                      const SizedBox(height: 2),
                                                      Text(
                                                        timeDisplay,
                                                        style: TextStyle(
                                                          fontSize: 11,
                                                          color: Colors.grey.shade500,
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
                                                    color: Color(0xFF0D9488),
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
                                                color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF334155),
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
                                                            color: Colors.green.withValues(alpha: 0.15),
                                                            borderRadius: BorderRadius.circular(8),
                                                            border: Border.all(color: Colors.green.withValues(alpha: 0.4)),
                                                          ),
                                                          child: const Row(
                                                            mainAxisSize: MainAxisSize.min,
                                                            children: [
                                                              Icon(Icons.check_circle_rounded, size: 14, color: Colors.green),
                                                              SizedBox(width: 4),
                                                              Text('Access Allowed', style: TextStyle(color: Colors.green, fontSize: 11, fontWeight: FontWeight.bold)),
                                                            ],
                                                          ),
                                                        ),
                                                      ] else ...[
                                                        ElevatedButton.icon(
                                                          style: ElevatedButton.styleFrom(
                                                            backgroundColor: const Color(0xFF10B981),
                                                            foregroundColor: Colors.white,
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
                                                      foregroundColor: const Color(0xFF0D9488),
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
              );
            },
          );
        },
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
            Icon(Icons.check_circle_rounded, color: Colors.green),
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
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ Access allowed and restored for $name'),
          backgroundColor: Colors.green,
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
