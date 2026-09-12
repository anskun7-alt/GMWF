import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:collection/collection.dart';
import '../../models/biometric_device_config.dart';
import '../../models/biometric_credential.dart';
import '../../services/zkteco_network_service.dart';
import '../../services/local_storage_service.dart';
import '../../services/finance_local_storage.dart';
import '../madrassa/utils/madrassa_local_storage.dart';
import '../../services/image_upload_service.dart';
import '../../utils/network_utils.dart';
import 'python_terminal_screen.dart';
import '../../services/user_theme_service.dart';
import '../../services/role_simulator_service.dart';

class BiometricDeviceManagerPage extends StatefulWidget {
  final String branchId;
  final VoidCallback? onBack;
  final String? currentUserRole;

  const BiometricDeviceManagerPage({
    super.key,
    this.branchId = 'main',
    this.onBack,
    this.currentUserRole,
  });

  @override
  State<BiometricDeviceManagerPage> createState() => _BiometricDeviceManagerPageState();
}

class _BiometricDeviceManagerPageState extends State<BiometricDeviceManagerPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  StreamSubscription? _punchSubscription;

  final List<Map<String, dynamic>> _livePunches = [];
  String _searchQuery = '';
  String _userPinsFilter = 'All'; // 'All', 'Enrolled', 'Not Enrolled'
  bool _isAutoAssigning = false;
  bool _isClearingPins = false;
  String _pcIpAddress = 'Detecting...';
  String _entityCategory = 'madrassa_student'; // Default to Madrassa students: 'madrassa_student', 'employee', 'all'

  bool get _canDeleteDevices {
    String role = '';
    if (RoleSimulatorService.isSimulating) {
      role = RoleSimulatorService.activeSimulationRole.value?.toLowerCase().trim() ?? '';
    }
    if (role.isEmpty && widget.currentUserRole != null && widget.currentUserRole!.isNotEmpty) {
      role = widget.currentUserRole!.toLowerCase().trim();
    }
    if (role.isEmpty) {
      role = LocalStorageService.getActiveUserRole().toLowerCase().trim();
    }
    if (role.isEmpty) {
      try {
        if (Hive.isBoxOpen('app_settings')) {
          role = (Hive.box('app_settings').get('role') ?? '').toString().toLowerCase().trim();
        }
      } catch (_) {}
    }

    if (role == 'server') return true;

    const allowed = [
      'hq manager',
      'hq_manager',
      'hqmanager',
      'hq',
      'headquarters manager',
      'admin',
      'global admin',
      'superadmin',
      'ceo',
      'chairman',
      'director',
    ];
    return allowed.any((a) => role == a || role.contains(a));
  }

  Future<void> _confirmDeleteDevice(BiometricDeviceConfig dev) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFFEE2E2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.delete_forever_rounded, color: Color(0xFFDC2626), size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Delete Biometric Device',
                style: GoogleFonts.outfit(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Are you sure you want to delete this device configuration?',
              style: GoogleFonts.inter(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.fingerprint_rounded, size: 16, color: Color(0xFF10B981)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          dev.deviceName,
                          style: GoogleFonts.outfit(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: isDark ? Colors.white : const Color(0xFF0F172A),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Location: ${dev.buildingLocation} (${dev.branchId.toUpperCase()})',
                    style: GoogleFonts.inter(fontSize: 12, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Network: ${dev.ipAddress}:${dev.port} • SN: ${dev.serialNumber.isEmpty ? "N/A" : dev.serialNumber}',
                    style: GoogleFonts.inter(fontSize: 12, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '⚠️ Clearance: HQ Manager & Admins. This permanently removes the device from local hardware storage and Cloud Firestore.',
              style: GoogleFonts.inter(
                fontSize: 11.5,
                color: isDark ? const Color(0xFFFCA5A5) : const Color(0xFFB91C1C),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B))),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.delete_forever_rounded, size: 16),
            label: const Text('Delete Device'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await ZkTecoNetworkService.deleteDeviceConfig(
          dev.deviceId,
          branchId: dev.branchId,
          deviceName: dev.deviceName,
          ipAddress: dev.ipAddress,
        );
        if (mounted) {
          setState(() {});
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text("🗑️ Biometric device '${dev.deviceName}' deleted permanently."),
                  ),
                ],
              ),
              backgroundColor: const Color(0xFF10B981),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to delete biometric device: $e'),
              backgroundColor: const Color(0xFFDC2626),
            ),
          );
        }
      }
    }
  }

  Future<void> _confirmDeleteCredential(BiometricCredential c) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFFEE2E2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.link_off_rounded, color: Color(0xFFDC2626), size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Remove Biometric PIN',
                style: GoogleFonts.outfit(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Remove and unlink PIN ${c.biometricPin} from ${c.entityName}?',
              style: GoogleFonts.inter(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'This will free PIN ${c.biometricPin} so it can be manually reassigned, and set ${c.entityName} to Not Enrolled.',
              style: GoogleFonts.inter(fontSize: 12, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B))),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.delete_outline_rounded, size: 16),
            label: const Text('Unlink PIN'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ZkTecoNetworkService.deleteBiometricCredential(c.entityId, branchId: c.branchId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Unlinked PIN ${c.biometricPin} from ${c.entityName}"),
            backgroundColor: const Color(0xFF10B981),
          ),
        );
        setState(() {});
      }
    }
  }

  Future<void> _confirmClearStaffPinsOnly() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.school_rounded, color: Color(0xFF2563EB), size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Keep Madrassa Students Only',
                style: GoogleFonts.outfit(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Clear all employee/staff PINs and only keep Madrassa students on this biometric list?',
              style: GoogleFonts.inter(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF0B2A21) : const Color(0xFFECFDF5),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFA7F3D0)),
              ),
              child: Text(
                '✅ All Madrassa student biometric credentials will be fully preserved. Only staff profiles will be unlinked so you can manually assign staff PINs.',
                style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF065F46)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B))),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.cleaning_services_rounded, size: 16),
            label: const Text('Clear Staff PINs Only'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      setState(() => _isClearingPins = true);
      final count = await ZkTecoNetworkService.clearEmployeeBiometricCredentials(branchId: widget.branchId);
      setState(() {
        _isClearingPins = false;
        _entityCategory = 'madrassa_student';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('🎓 Cleared $count staff PINs! Displaying Madrassa students only.'),
                ),
              ],
            ),
            backgroundColor: const Color(0xFF10B981),
          ),
        );
      }
    }
  }

  Future<void> _confirmClearAllPins() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFFEE2E2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.delete_sweep_rounded, color: Color(0xFFDC2626), size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Clear All Biometric PINs?',
                style: GoogleFonts.outfit(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Are you sure you want to remove all biometric PIN assignments for this branch (${widget.branchId.toUpperCase()})?',
              style: GoogleFonts.inter(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF2A1212) : const Color(0xFFFFF1F2),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFFECDD3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '⚠️ All bulk and auto-assigned PINs will be cleared from employee profiles.',
                    style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.bold, color: const Color(0xFFBE123C)),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'You will be able to manually link and assign each employee their custom PIN one-by-one.',
                    style: GoogleFonts.inter(fontSize: 11.5, color: isDark ? const Color(0xFFFDA4AF) : const Color(0xFF9F1239)),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B))),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.delete_sweep_rounded, size: 16),
            label: const Text('Clear All PINs'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      setState(() => _isClearingPins = true);
      final count = await ZkTecoNetworkService.clearAllBiometricCredentials(branchId: widget.branchId);
      setState(() => _isClearingPins = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('🧹 Removed $count biometric PINs! You can now manually assign custom PINs to each employee.'),
                ),
              ],
            ),
            backgroundColor: const Color(0xFF10B981),
          ),
        );
      }
    }
  }

  Widget _buildEntityAvatar(String entityId, String entityName, String entityType) {
    if (entityId.isEmpty ||
        entityId == 'null' ||
        entityName.toLowerCase().contains('unknown') ||
        entityName.toLowerCase().contains('test') ||
        entityType == 'unmapped') {
      return const CircleAvatar(
        radius: 20,
        backgroundColor: Color(0xFFF1F5F9),
        child: Icon(Icons.fingerprint_rounded, size: 20, color: Color(0xFF64748B)),
      );
    }

    String photoUrl = '';
    String gender = '';

    if (Hive.isBoxOpen(LocalStorageService.employeesBox)) {
      final emp = Hive.box(LocalStorageService.employeesBox).get(entityId);
      if (emp is Map) {
        if (emp['photoUrl'] != null && emp['photoUrl'].toString().isNotEmpty) {
          photoUrl = emp['photoUrl'].toString();
        } else if (emp['profilePictureUrl'] != null && emp['profilePictureUrl'].toString().isNotEmpty) {
          photoUrl = emp['profilePictureUrl'].toString();
        }
        if (emp['gender'] != null) gender = emp['gender'].toString().toLowerCase();
      }
    }
    if (photoUrl.isEmpty && Hive.isBoxOpen(LocalStorageService.schoolStudentsBox)) {
      final box = Hive.box(LocalStorageService.schoolStudentsBox);
      for (final k in box.keys) {
        if (k.toString().endsWith(entityId)) {
          final st = box.get(k);
          if (st is Map) {
            if (st['photoUrl'] != null && st['photoUrl'].toString().isNotEmpty) {
              photoUrl = st['photoUrl'].toString();
            }
            if (st['gender'] != null) gender = st['gender'].toString().toLowerCase();
            break;
          }
        }
      }
    }
    if (photoUrl.isEmpty && Hive.isBoxOpen(LocalStorageService.madrassaStudentsBox)) {
      final box = Hive.box(LocalStorageService.madrassaStudentsBox);
      for (final k in box.keys) {
        if (k.toString().endsWith(entityId)) {
          final st = box.get(k);
          if (st is Map) {
            if (st['photoUrl'] != null && st['photoUrl'].toString().isNotEmpty) {
              photoUrl = st['photoUrl'].toString();
            }
            if (st['gender'] != null) gender = st['gender'].toString().toLowerCase();
            break;
          }
        }
      }
    }

    final isFemale = gender == 'female';
    final isMale = gender == 'male';

    final bytes = ImageUploadService.decodeBase64ToBytes(photoUrl);
    if (bytes != null && bytes.isNotEmpty) {
      return CircleAvatar(
        radius: 20,
        backgroundColor: isFemale ? const Color(0xFFFCE7F3) : (isMale ? const Color(0xFFE0F2FE) : const Color(0xFF6366F1).withValues(alpha: 0.1)),
        backgroundImage: MemoryImage(bytes),
      );
    } else if (photoUrl.startsWith('http')) {
      return CircleAvatar(
        radius: 20,
        backgroundColor: isFemale ? const Color(0xFFFCE7F3) : (isMale ? const Color(0xFFE0F2FE) : const Color(0xFF6366F1).withValues(alpha: 0.1)),
        backgroundImage: NetworkImage(photoUrl),
      );
    }

    if (isFemale) {
      return const CircleAvatar(
        radius: 20,
        backgroundColor: Color(0xFFFCE7F3),
        child: Icon(Icons.face_3_rounded, size: 22, color: Color(0xFFDB2777)),
      );
    } else if (isMale) {
      return const CircleAvatar(
        radius: 20,
        backgroundColor: Color(0xFFE0F2FE),
        child: Icon(Icons.face_6_rounded, size: 22, color: Color(0xFF0284C7)),
      );
    }

    return CircleAvatar(
      radius: 20,
      backgroundColor: const Color(0xFF6366F1).withValues(alpha: 0.15),
      child: Text(
        entityName.isNotEmpty ? entityName[0].toUpperCase() : '?',
        style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF4338CA), fontSize: 13),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);

    // Fetch PC LAN IP
    _fetchPcIp();

    // Ensure ZKTeco network server is running
    ZkTecoNetworkService.startServer();

    // Automatically load all biometric devices & credentials from Cloud Firestore
    ZkTecoNetworkService.syncBiometricDevicesFromFirestore(branchId: widget.branchId);
    ZkTecoNetworkService.syncBiometricCredentialsFromFirestore(branchId: widget.branchId);
    ZkTecoNetworkService.listenToBiometricDevicesFromFirestore(branchId: widget.branchId);
    ZkTecoNetworkService.listenToBiometricCredentialsFromFirestore(branchId: widget.branchId);

    // Pre-populate with punches from today so user immediately sees previous scans
    _livePunches.addAll(ZkTecoNetworkService.getRecentPunchesToday());

    // Automatically sync today's punches & attendance from Cloud Firestore / Server PC
    ZkTecoNetworkService.syncTodayPunchesFromFirestore(branchId: widget.branchId).then((_) {
      if (mounted) {
        setState(() {
          _livePunches.clear();
          _livePunches.addAll(ZkTecoNetworkService.getRecentPunchesToday());
        });
      }
    });

    // Listen to realtime punch stream
    _punchSubscription = ZkTecoNetworkService.punchStream.listen((punch) {
      if (mounted) {
        setState(() {
          // Prevent duplicates
          _livePunches.removeWhere((p) => p['id'] == punch['id']);
          _livePunches.insert(0, punch);
          if (_livePunches.length > 100) _livePunches.removeLast();
        });
      }
    });
  }

  Future<void> _fetchPcIp() async {
    if (kIsWeb) {
      if (mounted) setState(() => _pcIpAddress = 'Cloud Sync Mode (Web)');
      return;
    }
    try {
      final ip = await getPrimaryLanIp();
      if (ip != null && ip.isNotEmpty) {
        if (mounted) setState(() => _pcIpAddress = ip);
        return;
      }
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final a = addr.address;
          if (!a.startsWith('127.') && !a.startsWith('169.254.')) {
            if (mounted) setState(() => _pcIpAddress = a);
            return;
          }
        }
      }
      if (mounted) setState(() => _pcIpAddress = '192.168.1.8');
    } catch (_) {
      if (mounted) setState(() => _pcIpAddress = '192.168.1.8');
    }
  }

  @override
  void dispose() {
    _punchSubscription?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Box>(
      valueListenable: UserThemeService.listenable(),
      builder: (context, _, __) {
        final isDark = UserThemeService.isDarkMode();
        final bgCanvas = isDark ? const Color(0xFF0B0F19) : const Color(0xFFF1F5F9);

        return PopScope(
          canPop: widget.onBack == null && Navigator.canPop(context),
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (widget.onBack != null) {
              widget.onBack!();
            }
          },
          child: Scaffold(
            backgroundColor: bgCanvas,
            appBar: AppBar(
              title: Text(
                'Biometric Attendance Settings & Devices',
                style: GoogleFonts.outfit(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 19),
              ),
              backgroundColor: const Color(0xFF0F172A), // Rich dark slate header
              elevation: 2,
              shadowColor: Colors.black26,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                onPressed: () {
                  if (widget.onBack != null) {
                    widget.onBack!();
                  } else if (Navigator.canPop(context)) {
                    Navigator.pop(context);
                  }
                },
              ),
            actions: [
              IconButton(
                icon: const Icon(Icons.delete_sweep_rounded, color: Color(0xFFF87171), size: 22),
                tooltip: 'Wipe Local Punches & Cache (Start Fresh)',
                onPressed: () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: const Color(0xFF0F172A),
                      title: const Text('Reset All Local Punches?', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      content: const Text(
                        'This will clear all historical local biometric punches and attendance records from local memory so you can start 100% anew.',
                        style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                        ElevatedButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFDC2626), foregroundColor: Colors.white),
                          child: const Text('Wipe & Reset'),
                        ),
                      ],
                    ),
                  );

                  if (confirmed == true) {
                    await ZkTecoNetworkService.clearAllLocalAttendanceAndPunches();
                    if (mounted) {
                      setState(() {});
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('🧹 All local punches and attendance cleared! Started fresh.'),
                          backgroundColor: Color(0xFF0F766E),
                        ),
                      );
                    }
                  }
                },
              ),
              IconButton(
                icon: const Icon(Icons.terminal_rounded, color: Color(0xFF38BDF8), size: 22),
                tooltip: 'Open Python Sync Terminal',
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const PythonTerminalScreen()),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.help_outline_rounded, color: Color(0xFF38BDF8), size: 22),
                tooltip: 'How to Setup Biometric Device',
                onPressed: _showSetupGuideDialog,
              ),
              const SizedBox(width: 8),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(48),
              child: Container(
                color: const Color(0xFF1E293B),
                child: TabBar(
                  controller: _tabController,
                  indicatorColor: const Color(0xFF10B981),
                  indicatorWeight: 4,
                  labelColor: Colors.white,
                  unselectedLabelColor: const Color(0xFF94A3B8), // High contrast unselected text
                  labelStyle: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 13),
                  unselectedLabelStyle: GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 13),
                  tabs: const [
                    Tab(icon: Icon(Icons.router_rounded, size: 18), text: 'ZKTeco Devices'),
                    Tab(icon: Icon(Icons.badge_rounded, size: 18), text: 'User Biometric PINs'),
                    Tab(icon: Icon(Icons.history_rounded, size: 18), text: 'Live Scans & Logs'),
                    Tab(icon: Icon(Icons.terminal_rounded, size: 18), text: 'Python Sync Terminal'),
                  ],
                ),
              ),
            ),
          ),
          body: Column(
            children: [
              _buildServerStatusBanner(isDark),
              _buildTodayDiagnosticsSummary(isDark),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _buildDevicesTab(isDark),
                    _buildUserPinsTab(isDark),
                    _buildLiveLogsTab(isDark),
                    const PythonTerminalView(),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
  }

  Widget _buildServerStatusBanner(bool isDark) {
    if (kIsWeb) {
      return Container(
        margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF12213A) : const Color(0xFFEFF6FF),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: isDark ? const Color(0xFF1E3A8A) : const Color(0xFFBFDBFE), width: 1.5),
          boxShadow: const [
            BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 2)),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: const BoxDecoration(
                color: Color(0xFF2563EB),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.cloud_sync_rounded, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Cloud Sync Active (Web View)',
                        style: GoogleFonts.outfit(
                          fontWeight: FontWeight.bold,
                          color: isDark ? const Color(0xFF93C5FD) : const Color(0xFF1E40AF),
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1D4ED8),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Web Browser Mode',
                          style: GoogleFonts.inter(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 11.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'ZKTeco hardware connects directly to your Windows Server PC on Port 8088. This Web App displays live device status & attendance synced from the Server.',
                    style: GoogleFonts.inter(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: isDark ? const Color(0xFFBFDBFE) : const Color(0xFF1E3A8A),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Tooltip(
              message: 'Hardware TCP/UDP Port listener runs on the Desktop/Server PC app',
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1E3A8A) : const Color(0xFFDBEAFE),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF93C5FD)),
                ),
                child: Text(
                  'Port Listener: Server PC',
                  style: GoogleFonts.inter(
                    color: isDark ? Colors.white : const Color(0xFF1E40AF),
                    fontWeight: FontWeight.bold,
                    fontSize: 11.5,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return ValueListenableBuilder<bool>(
      valueListenable: ZkTecoNetworkService.isServerRunningNotifier,
      builder: (context, isRunning, child) {
        return Container(
          margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isRunning
                ? (isDark ? const Color(0xFF0B2A21) : const Color(0xFFECFDF5))
                : (isDark ? const Color(0xFF2A1212) : const Color(0xFFFEF2F2)),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isRunning
                  ? (isDark ? const Color(0xFF10B981) : const Color(0xFFA7F3D0))
                  : (isDark ? const Color(0xFFEF4444) : const Color(0xFFFECACA)),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: (isRunning ? const Color(0xFF10B981) : Colors.red).withOpacity(0.06),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: isRunning ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isRunning ? Icons.wifi_tethering_rounded : Icons.wifi_tethering_off_rounded,
                  color: Colors.white,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          isRunning ? 'ZKTeco Server Active' : 'ZKTeco Server Stopped',
                          style: GoogleFonts.outfit(
                            fontWeight: FontWeight.bold,
                            color: isRunning
                                ? (isDark ? const Color(0xFF6EE7B7) : const Color(0xFF065F46))
                                : (isDark ? const Color(0xFFFCA5A5) : const Color(0xFF991B1B)),
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                          decoration: BoxDecoration(
                            color: isRunning ? const Color(0xFF047857) : const Color(0xFF991B1B),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            'PC IP: $_pcIpAddress',
                            style: GoogleFonts.inter(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isRunning
                          ? 'Set your ZKTeco machine Cloud Server IP to "$_pcIpAddress" and Port to "8088".'
                          : 'Click "Start Server" to listen for incoming fingerprint scans.',
                      style: GoogleFonts.inter(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: isRunning
                            ? (isDark ? const Color(0xFF6EE7B7) : const Color(0xFF047857))
                            : (isDark ? const Color(0xFFFCA5A5) : const Color(0xFFB91C1C)),
                      ),
                    ),
                  ],
                ),
              ),
              ValueListenableBuilder<int>(
                valueListenable: ZkTecoNetworkService.totalPunchesReceivedNotifier,
                builder: (context, count, _) {
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: isRunning ? const Color(0xFF059669) : Colors.grey[600],
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.touch_app_rounded, color: Colors.white, size: 16),
                        const SizedBox(width: 6),
                        Text(
                          '$count Scans',
                          style: GoogleFonts.inter(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                onPressed: () async {
                  if (isRunning) {
                    await ZkTecoNetworkService.stopServer();
                  } else {
                    await ZkTecoNetworkService.startServer();
                  }
                },
                icon: Icon(isRunning ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 18),
                label: Text(isRunning ? 'Stop' : 'Start'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isRunning ? const Color(0xFFDC2626) : const Color(0xFF10B981),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  elevation: 0,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTodayDiagnosticsSummary(bool isDark) {
    final diag = ZkTecoNetworkService.getTodayPunchDiagnostics(widget.branchId);
    final int total = diag['total'] ?? 0;
    final int mapped = diag['mapped'] ?? 0;
    final int unmapped = diag['unmapped'] ?? 0;
    final int crossBranch = diag['crossBranch'] ?? 0;

    final cardBg = isDark ? const Color(0xFF161F30) : Colors.white;
    final borderColor = isDark ? const Color(0xFF2A3547) : const Color(0xFFE2E8F0);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 1)),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildKpiMini('Total Punches Today', '$total', Icons.touch_app_rounded, const Color(0xFF2563EB), isDark),
                  const SizedBox(width: 18),
                  _buildKpiMini('Saved to Attendance', '$mapped', Icons.check_circle_rounded, const Color(0xFF059669), isDark),
                  const SizedBox(width: 18),
                  _buildKpiMini('Unmapped Scans', '$unmapped', Icons.warning_amber_rounded, unmapped > 0 ? const Color(0xFFDC2626) : const Color(0xFF64748B), isDark),
                  if (crossBranch > 0) ...[
                    const SizedBox(width: 18),
                    _buildKpiMini('Cross-Branch Pending', '$crossBranch', Icons.shuffle_rounded, const Color(0xFFD97706), isDark),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          TextButton.icon(
            onPressed: () async {
              await ZkTecoNetworkService.syncTodayPunchesFromFirestore(branchId: widget.branchId);
              if (mounted) {
                setState(() {
                  _livePunches.clear();
                  _livePunches.addAll(ZkTecoNetworkService.getRecentPunchesToday());
                });
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('✅ Synced today\'s biometric scans from server & cloud!'),
                    backgroundColor: Color(0xFF0F766E),
                    duration: Duration(seconds: 2),
                  ),
                );
              }
            },
            icon: const Icon(Icons.refresh_rounded, size: 15),
            label: const Text('Refresh Counts'),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF0F766E),
              textStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildKpiMini(String label, String value, IconData icon, Color color, bool isDark) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 16, color: color),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value,
              style: GoogleFonts.inter(fontWeight: FontWeight.w900, fontSize: 15, color: isDark ? Colors.white : const Color(0xFF0F172A)),
            ),
            Text(
              label,
              style: GoogleFonts.inter(fontSize: 10.5, fontWeight: FontWeight.w600, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
            ),
          ],
        ),
      ],
    );
  }

  // ── Tab 1: ZKTeco Network Devices ──────────────────────────────────────────

  Widget _buildDevicesTab(bool isDark) {
    final cardBg = isDark ? const Color(0xFF161F30) : Colors.white;
    final borderColor = isDark ? const Color(0xFF2A3547) : const Color(0xFFE2E8F0);
    final textPrimary = isDark ? Colors.white : const Color(0xFF0F172A);
    final textSecondary = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return ValueListenableBuilder<Box>(
      valueListenable: Hive.box(LocalStorageService.biometricDevicesBox).listenable(),
      builder: (context, box, child) {
        final devices = ZkTecoNetworkService.getAllDevices();

        return Padding(
          padding: const EdgeInsets.all(16),
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
                        'Building Biometric Devices',
                        style: GoogleFonts.outfit(fontSize: 18, fontWeight: FontWeight.bold, color: textPrimary),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Map ZKTeco Wi-Fi/Ethernet readers to physical building locations',
                        style: GoogleFonts.inter(fontSize: 13, color: textSecondary),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: _showSetupGuideDialog,
                        icon: const Icon(Icons.menu_book_rounded, size: 16, color: Color(0xFF0F766E)),
                        label: const Text('Setup Guide', style: TextStyle(color: Color(0xFF0F766E), fontWeight: FontWeight.bold)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Color(0xFF0F766E)),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed: () => _showAddEditDeviceDialog(),
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: const Text('Add Device'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2563EB),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          elevation: 0,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (devices.isEmpty)
                Expanded(
                  child: Center(
                    child: Card(
                      elevation: 0,
                      color: cardBg,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(color: borderColor),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.router_rounded, size: 48, color: Color(0xFF64748B)),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'No Biometric Devices Configured',
                              style: GoogleFonts.outfit(fontSize: 17, fontWeight: FontWeight.bold, color: textPrimary),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Click "Add Device" or power on a ZKTeco device connected to your LAN for auto-discovery.',
                              style: GoogleFonts.inter(fontSize: 13, color: textSecondary),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                )
              else
                Expanded(
                  child: ListView.builder(
                    itemCount: devices.length,
                    itemBuilder: (context, index) {
                      final dev = devices[index];
                      final isOnline = dev.status == 'Online';
                      final isStale = dev.lastHeartbeat == null || DateTime.now().difference(dev.lastHeartbeat!).inHours >= 2;
                      final lastHb = dev.lastHeartbeat != null
                          ? DateFormat('hh:mm:ss a').format(dev.lastHeartbeat!)
                          : 'Never';

                      // Location pill colors
                      Color locBg = isDark ? const Color(0xFF12213A) : const Color(0xFFEFF6FF);
                      Color locText = isDark ? const Color(0xFF93C5FD) : const Color(0xFF1D4ED8);
                      if (dev.buildingLocation.toLowerCase().contains('dispensary')) {
                        locBg = isDark ? const Color(0xFF0B2A21) : const Color(0xFFF0FDF4);
                        locText = isDark ? const Color(0xFF6EE7B7) : const Color(0xFF15803D);
                      } else if (dev.buildingLocation.toLowerCase().contains('madrassa')) {
                        locBg = isDark ? const Color(0xFF241A33) : const Color(0xFFF3E8FF);
                        locText = isDark ? const Color(0xFFD8B4FE) : const Color(0xFF6B21A8);
                      }

                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: cardBg,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: borderColor),
                          boxShadow: const [
                            BoxShadow(
                              color: Colors.black12,
                              blurRadius: 6,
                              offset: Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: isOnline
                                      ? (isDark ? const Color(0xFF0B2A21) : const Color(0xFFECFDF5))
                                      : (isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9)),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Icon(
                                  Icons.fingerprint_rounded,
                                  color: isOnline ? const Color(0xFF10B981) : const Color(0xFF94A3B8),
                                  size: 28,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          dev.deviceName,
                                          style: GoogleFonts.outfit(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 16,
                                            color: textPrimary,
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                                          decoration: BoxDecoration(
                                            color: locBg,
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                          child: Text(
                                            dev.buildingLocation,
                                            style: GoogleFonts.inter(
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                              color: locText,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 4,
                                      children: [
                                        _buildDetailBadge('IP', dev.ipAddress, isDark ? const Color(0xFFCBD5E1) : const Color(0xFF334155), isDark),
                                        _buildDetailBadge('Port', '${dev.port}', isDark ? const Color(0xFFCBD5E1) : const Color(0xFF334155), isDark),
                                        _buildDetailBadge('SN', dev.serialNumber.isEmpty ? 'N/A' : dev.serialNumber, isDark ? const Color(0xFFCBD5E1) : const Color(0xFF334155), isDark),
                                        _buildDetailBadge('Last Seen', lastHb, isOnline ? const Color(0xFF059669) : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)), isDark),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              if (isStale) ...[
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: isDark ? const Color(0xFF2E2306) : const Color(0xFFFFFBEB),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: const Color(0xFFFDE68A)),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.warning_amber_rounded, size: 14, color: Color(0xFFD97706)),
                                      const SizedBox(width: 4),
                                      Text(
                                        'No punches received recently',
                                        style: GoogleFonts.inter(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: isDark ? const Color(0xFFFCD34D) : const Color(0xFFB45309),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                              ],
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color: isOnline
                                      ? (isDark ? const Color(0xFF0B2A21) : const Color(0xFFD1FAE5))
                                      : (isDark ? const Color(0xFF2A1212) : const Color(0xFFFEE2E2)),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: isOnline ? const Color(0xFF059669) : const Color(0xFFDC2626),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      isOnline ? 'ONLINE' : 'OFFLINE',
                                      style: GoogleFonts.inter(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: isOnline
                                            ? (isDark ? const Color(0xFF6EE7B7) : const Color(0xFF047857))
                                            : (isDark ? const Color(0xFFFCA5A5) : const Color(0xFFB91C1C)),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton.icon(
                                onPressed: () async {
                                  if (kIsWeb) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('Raw IP ping is performed by the Windows Server PC app.'),
                                        backgroundColor: Color(0xFF2563EB),
                                      ),
                                    );
                                    return;
                                  }
                                  final success = await ZkTecoNetworkService.pingDevice(dev.ipAddress, port: dev.port);
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          success
                                              ? '🟢 Successfully reached ZKTeco device at ${dev.ipAddress}:${dev.port}!'
                                              : '🔴 Could not reach ${dev.ipAddress}:${dev.port}. Please check router connection.',
                                        ),
                                        backgroundColor: success ? const Color(0xFF10B981) : const Color(0xFFDC2626),
                                      ),
                                    );
                                  }
                                },
                                icon: const Icon(Icons.bolt_rounded, size: 16),
                                label: const Text('Test Ping'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                                  foregroundColor: isDark ? Colors.white : const Color(0xFF334155),
                                  elevation: 0,
                                  side: BorderSide(color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1)),
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                              ),
                              const SizedBox(width: 4),
                              IconButton(
                                icon: const Icon(Icons.edit_rounded, color: Color(0xFF2563EB)),
                                tooltip: 'Edit Device Settings',
                                onPressed: () => _showAddEditDeviceDialog(device: dev),
                              ),
                              if (_canDeleteDevices) ...[
                                const SizedBox(width: 2),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline_rounded, color: Color(0xFFDC2626)),
                                  tooltip: 'Delete Device (HQ Manager / Admin)',
                                  onPressed: () => _confirmDeleteDevice(dev),
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDetailBadge(String label, String value, Color textColor, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
      ),
      child: Text(
        '$label: $value',
        style: GoogleFonts.inter(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: textColor,
        ),
      ),
    );
  }

  // ── Tab 2: User Biometric PINs ─────────────────────────────────────────────

  Widget _buildUserPinsTab(bool isDark) {
    final cardBg = isDark ? const Color(0xFF161F30) : Colors.white;
    final borderColor = isDark ? const Color(0xFF2A3547) : const Color(0xFFE2E8F0);
    final textPrimary = isDark ? Colors.white : const Color(0xFF0F172A);
    final textSecondary = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return ValueListenableBuilder<Box>(
      valueListenable: Hive.box(LocalStorageService.biometricCredentialsBox).listenable(),
      builder: (context, box, child) {
        // 1. Enrolled Credentials (filter by branch if branch is specific)
        final allCredentials = ZkTecoNetworkService.getAllCredentials();
        final credentials = allCredentials.where((c) {
          if (widget.branchId.isEmpty || widget.branchId == 'main' || widget.branchId == 'all' || widget.branchId == 'global') return true;
          final credBranch = c.branchId.trim().toLowerCase();
          final myBranch = widget.branchId.trim().toLowerCase();
          if (credBranch.isEmpty) return true;
          final cleanCred = credBranch.replaceAll('branch_', '').replaceAll('_', ' ').trim();
          final cleanMy = myBranch.replaceAll('branch_', '').replaceAll('_', ' ').trim();
          return cleanCred == cleanMy || cleanCred.contains(cleanMy) || cleanMy.contains(cleanCred);
        }).toList();
        final enrolledEntityIds = credentials.map((c) => c.entityId.trim()).toSet();

        // 2. Madrassa Students (Active)
        final rawStudents = MadrassaLocalStorage.getAllStudentsCached(widget.branchId);
        final activeStudents = rawStudents.where((s) {
          final st = (s['status'] ?? 'active').toString().toLowerCase();
          return st != 'inactive' && st != 'withdrawn' && st != 'deleted';
        }).toList();

        final unenrolledStudents = activeStudents.where((s) {
          final sId = (s['id'] ?? s['localId'] ?? '').toString().trim();
          final pin = (s['biometricPin'] ?? s['pin'] ?? '').toString().trim();
          final isEnrolled = (sId.isNotEmpty && enrolledEntityIds.contains(sId)) ||
              (pin.isNotEmpty && credentials.any((c) => c.biometricPin == pin));
          return !isEnrolled;
        }).toList();

        // 3. Employees (Active & Non-Deleted)
        final allEmployees = FinanceLocalStorage.getEmployees(widget.branchId).where((e) {
          final eId = (e['localId'] ?? e['id'] ?? '').toString().trim();
          return e['isActive'] != false && !FinanceLocalStorage.isEmployeeDeleted(eId);
        }).toList();

        final unenrolledEmployees = allEmployees.where((e) {
          final localId = (e['localId'] ?? '').toString().trim();
          final id = (e['id'] ?? '').toString().trim();
          final pin = (e['biometricPin'] ?? e['pin'] ?? '').toString().trim();
          final isEnrolled = (localId.isNotEmpty && enrolledEntityIds.contains(localId)) ||
              (id.isNotEmpty && enrolledEntityIds.contains(id)) ||
              (pin.isNotEmpty && credentials.any((c) => c.biometricPin == pin));
          return !isEnrolled;
        }).toList();

        // Counts
        final madrassaCreds = credentials.where((c) => c.entityType == 'madrassa_student' || c.entityType == 'student').toList();
        final employeeCreds = credentials.where((c) => c.entityType != 'madrassa_student' && c.entityType != 'student').toList();

        final totalMadrassa = madrassaCreds.length + unenrolledStudents.length;
        final totalEmployees = employeeCreds.length + unenrolledEmployees.length;

        // Partition according to selected _entityCategory
        List<BiometricCredential> activeCategoryCreds;
        List<Map<String, dynamic>> activeCategoryUnenrolled;

        if (_entityCategory == 'madrassa_student') {
          activeCategoryCreds = madrassaCreds;
          activeCategoryUnenrolled = unenrolledStudents.map((s) => {...s, '_entityKind': 'madrassa_student'}).toList();
        } else if (_entityCategory == 'employee') {
          activeCategoryCreds = employeeCreds;
          activeCategoryUnenrolled = unenrolledEmployees.map((e) => {...e, '_entityKind': 'employee'}).toList();
        } else {
          activeCategoryCreds = credentials;
          activeCategoryUnenrolled = [
            ...unenrolledStudents.map((s) => {...s, '_entityKind': 'madrassa_student'}),
            ...unenrolledEmployees.map((e) => {...e, '_entityKind': 'employee'}),
          ];
        }

        final filteredCredentials = activeCategoryCreds.where((c) {
          if (_searchQuery.isEmpty) return true;
          final q = _searchQuery.toLowerCase();
          return c.entityName.toLowerCase().contains(q) ||
              c.biometricPin.toLowerCase().contains(q) ||
              c.entityType.toLowerCase().contains(q);
        }).toList();

        final filteredUnenrolled = activeCategoryUnenrolled.where((item) {
          if (_searchQuery.isEmpty) return true;
          final q = _searchQuery.toLowerCase();
          final name = (item['name'] ?? item['studentName'] ?? '').toString().toLowerCase();
          final sub = (item['rollNumber'] ?? item['rollNo'] ?? item['role'] ?? item['department'] ?? '').toString().toLowerCase();
          return name.contains(q) || sub.contains(q);
        }).toList();

        final totalEnrolled = activeCategoryCreds.length;
        final totalUnenrolled = activeCategoryUnenrolled.length;
        final totalAll = totalEnrolled + totalUnenrolled;

        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              // ── Top Category Segments ──────────────────────────────────────
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: borderColor),
                ),
                child: Row(
                  children: [
                    _buildCategorySegment(
                      label: '🎓 Madrassa Students',
                      count: totalMadrassa,
                      category: 'madrassa_student',
                      isDark: isDark,
                      activeColor: const Color(0xFF0F766E),
                    ),
                    const SizedBox(width: 6),
                    _buildCategorySegment(
                      label: '👔 Staff / Employees',
                      count: totalEmployees,
                      category: 'employee',
                      isDark: isDark,
                      activeColor: const Color(0xFF2563EB),
                    ),
                    const SizedBox(width: 6),
                    _buildCategorySegment(
                      label: '🌐 All Profiles',
                      count: totalMadrassa + totalEmployees,
                      category: 'all',
                      isDark: isDark,
                      activeColor: const Color(0xFF7C3AED),
                    ),
                  ],
                ),
              ),

              // ── Search & Actions Bar ──────────────────────────────────────
              Row(
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: cardBg,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: borderColor),
                        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
                      ),
                      child: TextField(
                        onChanged: (val) => setState(() => _searchQuery = val.trim()),
                        style: GoogleFonts.inter(fontSize: 14, color: textPrimary, fontWeight: FontWeight.w600),
                        decoration: InputDecoration(
                          hintText: _entityCategory == 'madrassa_student'
                              ? 'Search Madrassa Student Name, PIN, Roll #...'
                              : 'Search Name, Biometric PIN, or Role...',
                          hintStyle: GoogleFonts.inter(color: const Color(0xFF94A3B8), fontSize: 13),
                          prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF64748B)),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // Keep Madrassa Only Button (Quick action for user request)
                  OutlinedButton.icon(
                    onPressed: _isClearingPins ? null : _confirmClearStaffPinsOnly,
                    icon: const Icon(Icons.school_rounded, size: 16, color: Color(0xFF0F766E)),
                    label: const Text(
                      'Keep Madrassa Only',
                      style: TextStyle(color: Color(0xFF0F766E), fontWeight: FontWeight.bold),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0xFF99F6E4), width: 1.2),
                      backgroundColor: isDark ? const Color(0xFF062B28) : const Color(0xFFF0FDFA),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: _isAutoAssigning
                        ? null
                        : () async {
                            setState(() => _isAutoAssigning = true);
                            final count = await ZkTecoNetworkService.bulkAutoAssignBiometricPins(branchId: widget.branchId);
                            setState(() => _isAutoAssigning = false);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Auto-assigned Biometric PINs to $count profiles!'),
                                  backgroundColor: const Color(0xFF10B981),
                                ),
                              );
                            }
                          },
                    icon: _isAutoAssigning
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.auto_fix_high_rounded, size: 18),
                    label: const Text('Bulk Auto-Assign PINs'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF10B981),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 0,
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: () => _showAddCredentialDialog(
                      prefillType: _entityCategory == 'madrassa_student' ? 'madrassa_student' : 'employee',
                    ),
                    icon: const Icon(Icons.person_add_rounded, size: 18),
                    label: const Text('Link PIN'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4F46E5),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 0,
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _isClearingPins ? null : _confirmClearAllPins,
                    icon: _isClearingPins
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFDC2626)),
                          )
                        : const Icon(Icons.delete_sweep_rounded, size: 18, color: Color(0xFFDC2626)),
                    label: const Text('Clear All PINs', style: TextStyle(color: Color(0xFFDC2626), fontWeight: FontWeight.bold)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0xFFFECDD3)),
                      backgroundColor: isDark ? const Color(0xFF2A1212) : const Color(0xFFFFF1F2),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Filter Chips: All, Enrolled, Not Enrolled
              Row(
                children: [
                  _buildPinsFilterChip('All', totalAll, isDark),
                  const SizedBox(width: 8),
                  _buildPinsFilterChip('Enrolled', totalEnrolled, isDark, badgeColor: const Color(0xFF059669)),
                  const SizedBox(width: 8),
                  _buildPinsFilterChip('Not Enrolled', totalUnenrolled, isDark, badgeColor: const Color(0xFFD97706)),
                ],
              ),
              const SizedBox(height: 12),

              Expanded(
                child: Card(
                  elevation: 0,
                  color: cardBg,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(color: borderColor),
                  ),
                  child: Builder(
                    builder: (_) {
                      final showEnrolled = _userPinsFilter == 'All' || _userPinsFilter == 'Enrolled';
                      final showUnenrolled = _userPinsFilter == 'All' || _userPinsFilter == 'Not Enrolled';

                      final displayList = <Map<String, dynamic>>[];

                      if (showEnrolled) {
                        for (final c in filteredCredentials) {
                          displayList.add({'type': 'enrolled', 'data': c});
                        }
                      }

                      if (showUnenrolled) {
                        for (final u in filteredUnenrolled) {
                          displayList.add({'type': 'unenrolled', 'data': u});
                        }
                      }

                      if (displayList.isEmpty) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _entityCategory == 'madrassa_student' ? Icons.school_outlined : Icons.badge_outlined,
                                  size: 48,
                                  color: const Color(0xFF94A3B8),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  _entityCategory == 'madrassa_student'
                                      ? 'No Madrassa Students Matching Filter'
                                      : 'No Profiles Matching Filter',
                                  style: GoogleFonts.outfit(fontSize: 16, fontWeight: FontWeight.bold, color: textPrimary),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _entityCategory == 'madrassa_student'
                                      ? 'Use "Link PIN" to assign a biometric ID to a student, or switch category above.'
                                      : 'Click "Bulk Auto-Assign PINs" or "Link PIN" to add assignments.',
                                  style: GoogleFonts.inter(fontSize: 13, color: textSecondary),
                                ),
                              ],
                            ),
                          ),
                        );
                      }

                      return ListView.separated(
                        itemCount: displayList.length,
                        separatorBuilder: (ctx, i) => Divider(height: 1, color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9)),
                        itemBuilder: (ctx, i) {
                          final item = displayList[i];
                          if (item['type'] == 'enrolled') {
                            final c = item['data'] as BiometricCredential;
                            final isMadrassa = c.entityType == 'madrassa_student' || c.entityType == 'student';
                            final roleName = isMadrassa ? 'MADRASSA STUDENT' : c.entityType.replaceAll('_', ' ').toUpperCase();

                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              leading: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _buildEntityAvatar(c.entityId, c.entityName, c.entityType),
                                  const SizedBox(width: 10),
                                  Container(
                                    width: 65,
                                    height: 48,
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: isMadrassa
                                            ? const [Color(0xFF0F766E), Color(0xFF042F2E)]
                                            : const [Color(0xFF4F46E5), Color(0xFF3730A3)],
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                      ),
                                      borderRadius: BorderRadius.circular(10),
                                      boxShadow: const [
                                        BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 2)),
                                      ],
                                    ),
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          'PIN',
                                          style: GoogleFonts.inter(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 8.5,
                                            color: isMadrassa ? const Color(0xFF99F6E4) : const Color(0xFFC7D2FE),
                                            letterSpacing: 1,
                                          ),
                                        ),
                                        Text(
                                          c.biometricPin,
                                          style: GoogleFonts.outfit(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 15,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              title: Row(
                                children: [
                                  Text(
                                    c.entityName,
                                    style: GoogleFonts.outfit(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                      color: textPrimary,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: isMadrassa
                                          ? (isDark ? const Color(0xFF062B28) : const Color(0xFFF0FDFA))
                                          : (isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9)),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: isMadrassa
                                            ? (isDark ? const Color(0xFF0F766E) : const Color(0xFF99F6E4))
                                            : (isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1)),
                                      ),
                                    ),
                                    child: Text(
                                      roleName,
                                      style: GoogleFonts.inter(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: isMadrassa ? const Color(0xFF0F766E) : (isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569)),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: isDark ? const Color(0xFF0B2A21) : const Color(0xFFECFDF5),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: const Color(0xFFA7F3D0)),
                                    ),
                                    child: const Text(
                                      'ENROLLED',
                                      style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: Color(0xFF059669)),
                                    ),
                                  ),
                                ],
                              ),
                              subtitle: Text(
                                'ID: ${c.entityId} • Enrolled: ${DateFormat('yyyy-MM-dd').format(c.enrolledAt)}',
                                style: GoogleFonts.inter(fontSize: 12, color: textSecondary),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ElevatedButton.icon(
                                    onPressed: () => _showEnrollFingerprintGuide(c),
                                    icon: const Icon(Icons.fingerprint_rounded, size: 16),
                                    label: const Text('Enroll Fingerprint'),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: isDark ? const Color(0xFF0B2A21) : const Color(0xFFECFDF5),
                                      foregroundColor: isDark ? const Color(0xFF6EE7B7) : const Color(0xFF047857),
                                      elevation: 0,
                                      side: const BorderSide(color: Color(0xFFA7F3D0)),
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  IconButton(
                                    icon: const Icon(Icons.link_off_rounded, color: Color(0xFFDC2626), size: 20),
                                    tooltip: 'Remove / Unlink PIN',
                                    onPressed: () => _confirmDeleteCredential(c),
                                  ),
                                ],
                              ),
                            );
                          } else {
                            // Unenrolled Profile (Madrassa student or Employee)
                            final itemData = item['data'] as Map<String, dynamic>;
                            final isMadrassa = itemData['_entityKind'] == 'madrassa_student';
                            final entityId = (itemData['id'] ?? itemData['localId'])?.toString() ?? '';
                            final name = (itemData['name'] ?? itemData['studentName'] ?? (isMadrassa ? 'Student' : 'Employee')).toString();
                            final subInfo = isMadrassa
                                ? 'Roll: ${itemData['rollNumber'] ?? itemData['rollNo'] ?? 'N/A'} • Class: ${itemData['classId'] ?? itemData['grade'] ?? 'General'} • Madrassa'
                                : '${itemData['role'] ?? 'Staff'} • ${itemData['department'] ?? 'Office'}';

                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              leading: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _buildEntityAvatar(entityId, name, isMadrassa ? 'madrassa_student' : 'employee'),
                                  const SizedBox(width: 10),
                                  Container(
                                    width: 65,
                                    height: 48,
                                    decoration: BoxDecoration(
                                      color: isDark ? const Color(0xFF2E2306) : const Color(0xFFFFFBEB),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(color: const Color(0xFFFDE68A)),
                                    ),
                                    child: const Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.fingerprint_rounded, size: 18, color: Color(0xFFD97706)),
                                        SizedBox(height: 2),
                                        Text(
                                          'NO PIN',
                                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 9.5, color: Color(0xFF92400E)),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              title: Row(
                                children: [
                                  Text(
                                    name,
                                    style: GoogleFonts.outfit(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                      color: textPrimary,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: isDark ? const Color(0xFF2E2306) : const Color(0xFFFFFBEB),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: const Color(0xFFFDE68A)),
                                    ),
                                    child: Text(
                                      isMadrassa ? 'STUDENT' : 'NOT ENROLLED',
                                      style: const TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFF92400E),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              subtitle: Text(
                                subInfo,
                                style: GoogleFonts.inter(fontSize: 12, color: textSecondary),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: () => _showAddCredentialDialog(
                                      prefillId: entityId,
                                      prefillName: name,
                                      prefillType: isMadrassa ? 'madrassa_student' : 'employee',
                                      prefillBranch: itemData['branchId']?.toString() ?? widget.branchId,
                                    ),
                                    icon: const Icon(Icons.edit_note_rounded, size: 16, color: Color(0xFF2563EB)),
                                    label: const Text('Custom PIN', style: TextStyle(color: Color(0xFF2563EB), fontWeight: FontWeight.bold)),
                                    style: OutlinedButton.styleFrom(
                                      side: const BorderSide(color: Color(0xFF93C5FD)),
                                      backgroundColor: isDark ? const Color(0xFF172554) : const Color(0xFFEFF6FF),
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  ElevatedButton.icon(
                                    onPressed: () async {
                                      final assignedPin = await ZkTecoNetworkService.assignPinToEntity(
                                        entityId: entityId,
                                        entityName: name,
                                        entityType: isMadrassa ? 'madrassa_student' : 'employee',
                                        branchId: itemData['branchId']?.toString() ?? widget.branchId,
                                      );
                                      if (mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            content: Text('✅ Enrolled $name with PIN: $assignedPin'),
                                            backgroundColor: const Color(0xFF10B981),
                                          ),
                                        );
                                        setState(() {});
                                      }
                                    },
                                    icon: const Icon(Icons.add_rounded, size: 16),
                                    label: const Text('Auto PIN'),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF10B981),
                                      foregroundColor: Colors.white,
                                      elevation: 0,
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }
                        },
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCategorySegment({
    required String label,
    required int count,
    required String category,
    required bool isDark,
    required Color activeColor,
  }) {
    final isSelected = _entityCategory == category;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _entityCategory = category),
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 8),
          decoration: BoxDecoration(
            color: isSelected
                ? (isDark ? activeColor.withOpacity(0.25) : activeColor.withOpacity(0.12))
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected ? activeColor : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                style: GoogleFonts.outfit(
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                  fontSize: 13,
                  color: isSelected
                      ? (isDark ? Colors.white : activeColor)
                      : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isSelected ? activeColor : (isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: isSelected ? Colors.white : (isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPinsFilterChip(String label, int count, bool isDark, {Color? badgeColor}) {
    final isSelected = _userPinsFilter == label;
    final color = badgeColor ?? const Color(0xFF2563EB);

    return GestureDetector(
      onTap: () => setState(() => _userPinsFilter = label),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? color : (isDark ? const Color(0xFF161F30) : Colors.white),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: isSelected ? color : (isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1))),
          boxShadow: isSelected ? [BoxShadow(color: color.withOpacity(0.2), blurRadius: 4, offset: const Offset(0, 2))] : [],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: isSelected ? Colors.white : (isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569)),
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: isSelected ? Colors.white.withOpacity(0.25) : (isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9)),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  color: isSelected ? Colors.white : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Tab 3: Live Scans & Logs ───────────────────────────────────────────────

  Widget _buildLiveLogsTab(bool isDark) {
    final cardBg = isDark ? const Color(0xFF161F30) : Colors.white;
    final borderColor = isDark ? const Color(0xFF2A3547) : const Color(0xFFE2E8F0);
    final textPrimary = isDark ? Colors.white : const Color(0xFF0F172A);
    final textSecondary = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Live Incoming Scans & Cross-Branch Alerts',
                      style: GoogleFonts.outfit(fontSize: 18, fontWeight: FontWeight.bold, color: textPrimary),
                    ),
                    Text(
                      'Real-time stream of finger scans captured from ZKTeco devices across all buildings',
                      style: GoogleFonts.inter(fontSize: 13, color: textSecondary),
                    ),
                  ],
                ),
              ),
              ElevatedButton.icon(
                onPressed: _showSimulatePunchDialog,
                icon: const Icon(Icons.fingerprint_rounded, size: 16),
                label: const Text('Simulate Test Scan'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0F766E),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.refresh_rounded, color: Color(0xFF64748B)),
                tooltip: 'Reload punches from storage',
                onPressed: () {
                  setState(() {
                    _livePunches.clear();
                    _livePunches.addAll(ZkTecoNetworkService.getRecentPunchesToday());
                  });
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Reloaded recent punches from storage')),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Card(
              elevation: 0,
              color: cardBg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: borderColor),
              ),
              child: _livePunches.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.stream_rounded, size: 40, color: Color(0xFF64748B)),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Waiting for finger scans on ZKTeco devices...',
                            style: GoogleFonts.inter(color: textSecondary, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: _livePunches.length,
                      itemBuilder: (ctx, i) {
                        final p = _livePunches[i];
                        final isMapped = p['isMapped'] == true;
                        final isCrossBranchPending = p['isCrossBranchPending'] == true;
                        final crossBranchInfo = p['crossBranchInfo'] as Map<String, dynamic>?;
                        final pendingId = crossBranchInfo?['id']?.toString() ?? '';

                        return ListTile(
                          leading: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (!isMapped || (p['entityId']?.toString() ?? '').isEmpty)
                                const CircleAvatar(
                                  radius: 20,
                                  backgroundColor: Color(0xFFF1F5F9),
                                  child: Icon(Icons.fingerprint_rounded, size: 20, color: Color(0xFF64748B)),
                                )
                              else
                                _buildEntityAvatar(p['entityId']?.toString() ?? '', p['entityName']?.toString() ?? '', p['entityType']?.toString() ?? 'employee'),
                              const SizedBox(width: 8),
                              CircleAvatar(
                                radius: 14,
                                backgroundColor: isCrossBranchPending
                                    ? const Color(0xFFFEF3C7)
                                    : (isMapped ? const Color(0xFFECFDF5) : const Color(0xFFFEF2F2)),
                                child: Icon(
                                  isCrossBranchPending
                                      ? Icons.warning_amber_rounded
                                      : (isMapped ? Icons.check_circle_rounded : Icons.help_outline_rounded),
                                  color: isCrossBranchPending
                                      ? const Color(0xFFD97706)
                                      : (isMapped ? const Color(0xFF10B981) : const Color(0xFFEF4444)),
                                  size: 16,
                                ),
                              ),
                            ],
                          ),
                          title: Text(
                            '${p['entityName']} (PIN: ${p['pin']})',
                            style: GoogleFonts.inter(fontWeight: FontWeight.bold, color: textPrimary),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Location: ${p['buildingLocation']} | IP: ${p['deviceIp']} | Time: ${p['timestamp']}',
                                style: GoogleFonts.inter(fontSize: 12, color: textSecondary),
                              ),
                              if (isCrossBranchPending)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4.0),
                                  child: Text(
                                    '⚠️ Assigned to ${p['entityBranchName']} • Punched at ${p['deviceBranchName']} (${p['deviceName']})',
                                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFFB45309)),
                                  ),
                                ),
                            ],
                          ),
                          trailing: isCrossBranchPending
                              ? Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    ElevatedButton(
                                      onPressed: () async {
                                        if (pendingId.isNotEmpty) {
                                          await ZkTecoNetworkService.approveCrossBranchPunch(
                                            pendingId: pendingId,
                                            reviewerName: 'HQ Manager',
                                          );
                                          if (mounted) {
                                            setState(() {
                                              p['isCrossBranchPending'] = false;
                                            });
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(
                                                content: Text('✅ Approved ${p['entityName']} (Marked Present)'),
                                                backgroundColor: const Color(0xFF10B981),
                                              ),
                                            );
                                          }
                                        }
                                      },
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFF10B981),
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                        textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                                      ),
                                      child: const Text('Allow'),
                                    ),
                                    const SizedBox(width: 6),
                                    OutlinedButton(
                                      onPressed: () async {
                                        if (pendingId.isNotEmpty) {
                                          await ZkTecoNetworkService.rejectCrossBranchPunch(
                                            pendingId: pendingId,
                                            reviewerName: 'HQ Manager',
                                          );
                                          if (mounted) {
                                            setState(() {
                                              p['isCrossBranchPending'] = false;
                                            });
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(
                                                content: Text('❌ Rejected ${p['entityName']}'),
                                                backgroundColor: const Color(0xFFEF4444),
                                              ),
                                            );
                                          }
                                        }
                                      },
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: const Color(0xFFEF4444),
                                        side: const BorderSide(color: Color(0xFFEF4444)),
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                        textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                                      ),
                                      child: const Text('Reject'),
                                    ),
                                  ],
                                )
                              : (!isMapped
                                  ? ElevatedButton.icon(
                                      onPressed: () => _showAssignPinFromPunchDialog(p['pin']?.toString() ?? ''),
                                      icon: const Icon(Icons.person_add_alt_1_rounded, size: 14),
                                      label: const Text('Assign Staff'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFFDC2626),
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                        textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                      ),
                                    )
                                  : Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFD1FAE5),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(
                                        'Auto-Logged',
                                        style: GoogleFonts.inter(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: const Color(0xFF065F46),
                                        ),
                                      ),
                                    )),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  void _showAssignPinFromPunchDialog(String pin) {
    if (pin.isEmpty || pin == '---') return;

    final employees = FinanceLocalStorage.getEmployees(widget.branchId);
    String? selectedEmpId = employees.isNotEmpty ? (employees.first['localId'] ?? employees.first['id'])?.toString() : null;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              const Icon(Icons.fingerprint_rounded, color: Color(0xFF0F766E), size: 24),
              const SizedBox(width: 10),
              Text('Assign PIN $pin to Staff Member', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ],
          ),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'This punch was received from your ZKTeco device with PIN $pin. Choose which employee this PIN belongs to. Their attendance for today will be immediately updated!',
                  style: TextStyle(fontSize: 12.5, color: Colors.grey[700]),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  value: selectedEmpId,
                  decoration: InputDecoration(
                    labelText: 'Select Employee',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  ),
                  items: employees.map((emp) {
                    final eId = (emp['localId'] ?? emp['id']).toString();
                    final eName = emp['name']?.toString() ?? 'Employee';
                    final eDept = emp['department']?.toString() ?? 'Office';
                    return DropdownMenuItem<String>(
                      value: eId,
                      child: Text('$eName ($eDept)', overflow: TextOverflow.ellipsis),
                    );
                  }).toList(),
                  onChanged: (val) => setDlgState(() => selectedEmpId = val),
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
              onPressed: () async {
                if (selectedEmpId == null) return;
                Navigator.pop(ctx);

                final chosenEmp = employees.firstWhereOrNull((e) => (e['localId'] ?? e['id']).toString() == selectedEmpId);
                final empName = chosenEmp?['name']?.toString() ?? 'Employee';

                final assignedPin = await ZkTecoNetworkService.assignPinToEntity(
                  entityId: selectedEmpId!,
                  entityName: empName,
                  entityType: 'employee',
                  branchId: chosenEmp?['branchId']?.toString() ?? widget.branchId,
                  customPin: pin,
                );

                final remapped = await ZkTecoNetworkService.processPendingUnmappedPunches();

                if (mounted) {
                  setState(() {
                    _livePunches.clear();
                    _livePunches.addAll(ZkTecoNetworkService.getRecentPunchesToday());
                  });
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('✅ PIN $assignedPin assigned to $empName! Recorded $remapped attendance punch(es).'),
                      backgroundColor: const Color(0xFF059669),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.check_circle_rounded, size: 16),
              label: const Text('Assign & Update Attendance'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0F766E),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Dialogs ────────────────────────────────────────────────────────────────

  void _showAddEditDeviceDialog({BiometricDeviceConfig? device}) {
    final isEdit = device != null;
    final nameCtrl = TextEditingController(text: device?.deviceName ?? 'Office Entrance Scanner');
    final ipCtrl = TextEditingController(text: device?.ipAddress ?? '192.168.1.150');
    final portCtrl = TextEditingController(text: (device?.port ?? 4370).toString());
    String location = device?.buildingLocation ?? 'Office/Dasterkhwaan';
    String branchId = (device?.branchId.isNotEmpty == true) ? device!.branchId : widget.branchId;

    showDialog(
      context: context,
      builder: (ctx) {
        final allBranches = FinanceLocalStorage.getAllBranches([])
            .where((b) => (b['id']?.toString() ?? '') != 'all')
            .toList();

        final branchIds = allBranches.map((b) => b['id']?.toString() ?? '').toSet().toList();
        if (!branchIds.contains(branchId) && branchId.isNotEmpty) {
          branchIds.add(branchId);
        }
        if (branchIds.isEmpty) {
          branchIds.addAll(['main', 'gujrat', 'sialkot', 'karachi', 'rawalpindi']);
        }

        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Text(isEdit ? 'Edit ZKTeco Device' : 'Add ZKTeco Device'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(labelText: 'Device Name (e.g. Madrassa Gate Scanner)'),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: location,
                      decoration: const InputDecoration(labelText: 'Building Location'),
                      items: const [
                        DropdownMenuItem(value: 'Office/Dasterkhwaan', child: Text('Building 1: Office & HQ')),
                        DropdownMenuItem(value: 'Dispensary', child: Text('Building 2: Dispensary Medical Center')),
                        DropdownMenuItem(value: 'Madrassa', child: Text('Building 3: Madrassa & Hifz Department')),
                        DropdownMenuItem(value: 'School', child: Text('Building 4: GMWF Model School')),
                        DropdownMenuItem(value: 'Dasterkhwaan Kitchen', child: Text('Building 5: Dasterkhwaan Dining & Kitchen')),
                      ],
                      onChanged: (val) {
                        if (val != null) setDialogState(() => location = val);
                      },
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: branchId.isNotEmpty ? branchId : branchIds.first,
                      decoration: const InputDecoration(labelText: 'Assigned Physical Branch / Campus'),
                      items: branchIds.map((bId) {
                        final bName = LocalStorageService.getBranchName(bId);
                        return DropdownMenuItem(value: bId, child: Text('$bName ($bId)'));
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) setDialogState(() => branchId = val);
                      },
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: ipCtrl,
                      decoration: const InputDecoration(labelText: 'Static IP Address (e.g. 192.168.1.150)'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: portCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Hardware Port (Default 4370)',
                        helperText: 'Hardware UDP polling port is 4370. ADMS push receiver is 8088.',
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                if (isEdit && _canDeleteDevices)
                  TextButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _confirmDeleteDevice(device);
                    },
                    icon: const Icon(Icons.delete_forever_rounded, color: Color(0xFFDC2626), size: 18),
                    label: const Text(
                      'Delete Device',
                      style: TextStyle(color: Color(0xFFDC2626), fontWeight: FontWeight.bold),
                    ),
                  ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final newConfig = BiometricDeviceConfig(
                      deviceId: device?.deviceId ?? DateTime.now().millisecondsSinceEpoch.toString(),
                      deviceName: nameCtrl.text.trim(),
                      buildingLocation: location,
                      branchId: branchId,
                      ipAddress: ipCtrl.text.trim(),
                      port: int.tryParse(portCtrl.text.trim()) ?? 4370,
                      status: device?.status ?? 'Offline',
                      serialNumber: device?.serialNumber ?? '',
                      lastHeartbeat: device?.lastHeartbeat,
                    );
                    await ZkTecoNetworkService.saveDeviceConfig(newConfig, oldBranchId: device?.branchId);
                    if (mounted) {
                      Navigator.pop(ctx);
                      setState(() {});
                    }
                  },
                  child: const Text('Save Device'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showAddCredentialDialog({
    String? prefillId,
    String? prefillName,
    String? prefillType,
    String? prefillBranch,
  }) {
    final nameCtrl = TextEditingController(text: prefillName ?? '');
    final pinCtrl = TextEditingController();
    final idCtrl = TextEditingController(text: prefillId ?? '');
    String type = prefillType ?? 'employee';
    final targetBranch = prefillBranch ?? widget.branchId;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Link Biometric PIN to User'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: pinCtrl,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Biometric PIN * (e.g. 101, 102)',
                helperText: 'Enter the hardware device user PIN number',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Full Name'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: idCtrl,
              decoration: const InputDecoration(
                labelText: 'Entity / Student / Employee ID *',
                helperText: 'Required — must match the employee/student ID in the system',
              ),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: type,
              decoration: const InputDecoration(labelText: 'Entity Role'),
              items: const [
                DropdownMenuItem(value: 'employee', child: Text('Office / Dasterkhwaan Employee')),
                DropdownMenuItem(value: 'dispensary_staff', child: Text('Dispensary Staff')),
                DropdownMenuItem(value: 'madrassa_student', child: Text('Madrassa Student')),
                DropdownMenuItem(value: 'school_student', child: Text('School Student')),
              ],
              onChanged: (val) {
                if (val != null) type = val;
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (pinCtrl.text.trim().isEmpty || nameCtrl.text.trim().isEmpty || idCtrl.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('⚠️ PIN, Name, and Entity ID are all required to link a credential.'),
                    backgroundColor: Color(0xFFDC2626),
                  ),
                );
                return;
              }
              final cred = BiometricCredential(
                id: DateTime.now().millisecondsSinceEpoch.toString(),
                biometricPin: pinCtrl.text.trim(),
                entityId: idCtrl.text.trim(),
                entityName: nameCtrl.text.trim(),
                entityType: type,
                branchId: targetBranch,
                enrolledAt: DateTime.now(),
              );
              await ZkTecoNetworkService.registerBiometricCredential(cred);
              if (mounted) {
                Navigator.pop(ctx);
                setState(() {});
              }
            },
            child: const Text('Link PIN'),
          ),
        ],
      ),
    );
  }

  void _showEnrollFingerprintGuide(BiometricCredential c) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.fingerprint_rounded, color: Color(0xFF10B981), size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Enroll Fingerprint for ${c.entityName}',
                style: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFECFDF5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.badge_rounded, color: Color(0xFF059669)),
                  const SizedBox(width: 10),
                  Text(
                    'Assigned Biometric PIN: ${c.biometricPin}',
                    style: GoogleFonts.inter(fontWeight: FontWeight.bold, color: const Color(0xFF065F46)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'How to scan fingerprint on ZKTeco Device:',
              style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 8),
            Text('1. Go to ZKTeco scanner at entrance (Office / Dispensary / Madrassa).', style: GoogleFonts.inter(fontSize: 12)),
            const SizedBox(height: 4),
            Text('2. Press "M/OK" key -> Select "User Mgt" -> "New User" (or Edit User).', style: GoogleFonts.inter(fontSize: 12)),
            const SizedBox(height: 4),
            Text('3. Set User ID = "${c.biometricPin}".', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.blue[800])),
            const SizedBox(height: 4),
            Text('4. Select "Enroll FP" and scan finger 3 times until device beeps green.', style: GoogleFonts.inter(fontSize: 12)),
            const SizedBox(height: 12),
            Text('That\'s it! Once scanned, any future finger scan on that device will instantly auto-log attendance for ${c.entityName}.', style: GoogleFonts.inter(fontSize: 11, color: Colors.grey[700], fontStyle: FontStyle.italic)),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF10B981),
              foregroundColor: Colors.white,
            ),
            child: const Text('Got It!'),
          ),
        ],
      ),
    );
  }

  void _showSimulatePunchDialog() {
    final credentials = ZkTecoNetworkService.getAllCredentials();
    String selectedPin = credentials.isNotEmpty ? credentials.first.biometricPin : '101';
    final customPinCtrl = TextEditingController(text: selectedPin);

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              const Icon(Icons.fingerprint_rounded, color: Color(0xFF0F766E), size: 28),
              const SizedBox(width: 10),
              Text(
                'Simulate Biometric Scan',
                style: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 18),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Select an enrolled staff member or enter a PIN to simulate a real-time finger punch from the ZKTeco hardware:',
                  style: GoogleFonts.inter(fontSize: 12.5, color: const Color(0xFF64748B)),
                ),
                const SizedBox(height: 14),
                if (credentials.isNotEmpty) ...[
                  Text(
                    'Quick Pick Enrolled User:',
                    style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      border: Border.all(color: const Color(0xFFCBD5E1)),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: credentials.any((c) => c.biometricPin == selectedPin) ? selectedPin : null,
                        hint: const Text('Choose a person...'),
                        items: credentials.map((c) {
                          return DropdownMenuItem<String>(
                            value: c.biometricPin,
                            child: Text(
                              'PIN ${c.biometricPin} — ${c.entityName} (${c.entityType})',
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.inter(fontSize: 13),
                            ),
                          );
                        }).toList(),
                        onChanged: (val) {
                          if (val != null) {
                            setDlgState(() {
                              selectedPin = val;
                              customPinCtrl.text = val;
                            });
                          }
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
                TextField(
                  controller: customPinCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Biometric PIN / Badge #',
                    hintText: 'e.g. 101 or 999',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                  onChanged: (v) => selectedPin = v.trim(),
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
              onPressed: () async {
                final pin = customPinCtrl.text.trim();
                if (pin.isEmpty) return;
                Navigator.pop(ctx);

                await ZkTecoNetworkService.processIncomingPunch(
                  pin: pin,
                  timestamp: DateTime.now(),
                  deviceIp: _pcIpAddress.isNotEmpty ? _pcIpAddress : '192.168.1.150',
                  deviceSn: 'DEMO_DEVICE_SN',
                  source: 'manual_simulation',
                );

                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('✅ Simulated scan for PIN $pin! Check Live stream and Attendance tab.'),
                      backgroundColor: const Color(0xFF0F766E),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.touch_app_rounded, size: 16),
              label: const Text('Punch Now'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0F766E),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSetupGuideDialog() {
    final serverIpStr = _pcIpAddress.isNotEmpty && !_pcIpAddress.contains('Detecting') ? _pcIpAddress : '192.168.1.100';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF10B981), width: 1.2),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.menu_book_rounded,
                color: Color(0xFF34D399),
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Biometric Scanner Setup Guide',
                    style: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white),
                  ),
                  Text(
                    'Hardware & Network Configuration Steps',
                    style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF94A3B8)),
                  ),
                ],
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 540,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF070D18),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF1E293B)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline_rounded, color: Color(0xFF38BDF8), size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Follow these steps to connect your physical ZKTeco fingerprint / facial device to this server system.',
                          style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFFCBD5E1)),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'SETUP INSTRUCTIONS:',
                  style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.bold, color: const Color(0xFFF59E0B), letterSpacing: 0.5),
                ),
                const SizedBox(height: 10),
                _buildGuideStepRow(
                  '1',
                  'Configure Physical Biometric Device',
                  'In the ZKTeco device Menu ➔ Comm. ➔ Cloud Server / ADMS:\n• Enable Domain Name: OFF\n• Server Address / IP: $serverIpStr\n• Server Port: 8088 (or direct UDP 4370)',
                ),
                const SizedBox(height: 10),
                _buildGuideStepRow(
                  '2',
                  'Connect Device via Ethernet',
                  'Ensure the biometric machine is connected via Ethernet cable or Wi-Fi to the same local router as this PC.',
                ),
                const SizedBox(height: 10),
                _buildGuideStepRow(
                  '3',
                  'Register Device & Map PINs',
                  'Click "Add Device" on this screen to register the device location. Map staff numeric PINs in the "User Biometric PINs" tab.',
                ),
                const SizedBox(height: 10),
                _buildGuideStepRow(
                  '4',
                  'Perform Test Punch',
                  'Place a finger on the scanner. The Live Scans tab and Attendance screen will immediately record and sync the punch.',
                ),
              ],
            ),
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0284C7),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Got It, Thanks!'),
          ),
        ],
      ),
    );
  }

  Widget _buildGuideStepRow(String stepNumber, String title, String description) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF070D18),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFF0284C7).withOpacity(0.2),
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFF38BDF8), width: 1.2),
            ),
            child: Text(
              stepNumber,
              style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.bold, color: const Color(0xFF38BDF8)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: GoogleFonts.inter(fontSize: 11.5, color: const Color(0xFF94A3B8), height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}