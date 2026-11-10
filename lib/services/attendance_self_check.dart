// lib/services/attendance_self_check.dart
//
// Read-only health report for biometric attendance, written to gmwf_sync.log 3 minutes after
// start and then every hour. It changes nothing; it answers, from the log of any PC (e.g. the
// Haji Camp PC), why punches seen on that PC are or aren't in the cloud:
//   • what this PC is (LAN server / poller, LAN desk, standalone) and who is logged in;
//   • per day (last 14 days): day records, punches, how many are uploaded, how many waiting,
//     and how many are in the upload queue (and how many of those failed);
//   • per device: last poll, newest punch held from it, clock difference to this PC.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';

import '../realtime/lan_host_manager.dart';
import '../realtime/lan_server.dart';
import '../realtime/realtime_manager.dart';
import 'cloud/lan_firestore_gate.dart';
import 'cloud/sync_log.dart';
import 'local_storage_service.dart';
import 'offline_auth_service.dart';
import 'zkteco_network_service.dart';

class AttendanceSelfCheck {
  AttendanceSelfCheck._();

  static Timer? _first;
  static Timer? _hourly;
  static bool _running = false;

  static void start() {
    if (kIsWeb || _first != null) return;
    _first = Timer(const Duration(minutes: 3), () {
      unawaited(run());
      _hourly = Timer.periodic(const Duration(hours: 1), (_) => unawaited(run()));
    });
  }

  static void stop() {
    _first?.cancel();
    _hourly?.cancel();
    _first = null;
    _hourly = null;
  }

  /// Writes the report. Never throws; skips if a run is already going.
  static Future<void> run() async {
    if (_running) return;
    _running = true;
    try {
      if (!Hive.isBoxOpen(LocalStorageService.attendanceBox)) return; // nothing to report yet
      final box = Hive.box(LocalStorageService.attendanceBox);
      final flags = Hive.isBoxOpen('app_flags') ? Hive.box('app_flags') : null;
      final fmt = DateFormat('yyyy-MM-dd');
      final today = DateTime.now();
      final days = [for (var i = 0; i < 14; i++) fmt.format(today.subtract(Duration(days: i)))];
      final daySet = days.toSet();

      // ── This PC ──
      String mode;
      if (LanServer.isRunning || LanHostManager.isHostRunning) {
        mode = 'LAN server (polls the devices)';
      } else if (RealtimeManager().hasServerLink) {
        mode = LanFirestoreGate.isLanDesk ? 'LAN desk (dispensary role)' : 'LAN client';
      } else {
        mode = 'standalone';
      }
      String role = RealtimeManager().role ?? '';
      if (role.isEmpty) {
        try {
          role = (await OfflineAuthService.getCachedUserData())?['role']?.toString() ?? '';
        } catch (_) {}
      }

      // ── Local day records ──
      final records = <String, int>{}, punches = <String, int>{}, uploaded = <String, int>{}, waiting = <String, int>{};
      final newestByDevice = <String, DateTime>{};
      var scanned = 0;
      for (final key in box.keys.toList()) {
        if (++scanned % 300 == 0) await Future.delayed(Duration.zero);
        final raw = box.get(key);
        if (raw is! Map) continue;
        final date = (raw['date'] ?? raw['dateKey'] ?? '').toString();
        if (!daySet.contains(date)) continue;
        if (LocalStorageService.isAttendanceAliasKey(key, raw, box)) continue;
        records[date] = (records[date] ?? 0) + 1;
        final list = raw['punches'];
        final n = list is List ? list.length : 0;
        punches[date] = (punches[date] ?? 0) + n;
        if (LocalStorageService.isAttendanceUploaded(raw)) {
          uploaded[date] = (uploaded[date] ?? 0) + 1;
        } else {
          waiting[date] = (waiting[date] ?? 0) + 1;
        }
        if (list is List) {
          for (final p in list) {
            if (p is! Map) continue;
            final dev = (p['deviceSn'] ?? '').toString();
            final t = DateTime.tryParse(p['timestamp']?.toString() ?? '');
            if (dev.isEmpty || t == null) continue;
            final cur = newestByDevice[dev];
            if (cur == null || t.isAfter(cur)) newestByDevice[dev] = t;
          }
        }
      }

      // ── Upload queue ──
      final queued = <String, int>{}, failing = <String, int>{};
      var otherKeyStyle = 0;
      if (Hive.isBoxOpen(LocalStorageService.syncBox)) {
        final q = Hive.box(LocalStorageService.syncBox);
        for (final k in q.keys.toList()) {
          final v = q.get(k);
          if (v is! Map) continue;
          final t = v['type']?.toString() ?? '';
          if (t != 'save_attendance_record' && t != 'save_employee_attendance' && t != 'save_attendance') continue;
          final d = (v['date'] ?? (v['data'] is Map ? v['data']['date'] : null) ?? '').toString();
          final dd = daySet.contains(d) ? d : 'older';
          queued[dd] = (queued[dd] ?? 0) + 1;
          if (v['lastError'] != null) failing[dd] = (failing[dd] ?? 0) + 1;
          if (!k.toString().startsWith('sync_att_')) otherKeyStyle++;
        }
      }

      final lines = <String>[
        '🕒 Attendance self-check — this PC: $mode, role: ${role.isEmpty ? '?' : role}',
        for (final d in days)
          if ((records[d] ?? 0) > 0 || (queued[d] ?? 0) > 0)
            '   $d: ${records[d] ?? 0} people, ${punches[d] ?? 0} punches, '
                'uploaded ${uploaded[d] ?? 0}, waiting ${waiting[d] ?? 0}, '
                'in queue ${queued[d] ?? 0}${(failing[d] ?? 0) > 0 ? ' (${failing[d]} failing)' : ''}',
        if ((queued['older'] ?? 0) > 0)
          '   older days: ${queued['older']} in queue${(failing['older'] ?? 0) > 0 ? ' (${failing['older']} failing)' : ''}',
        if (otherKeyStyle > 0) '   ⚠️ $otherKeyStyle attendance queue item(s) under an old key style',
      ];

      // ── Devices ──
      for (final dev in ZkTecoNetworkService.getAllDevices()) {
        final ip = dev.ipAddress;
        final lastPoll = flags?.get('zk_last_poll_$ip')?.toString();
        final drift = flags?.get('zk_last_drift_$ip');
        final newest = newestByDevice[dev.serialNumber];
        String driftText = 'clock difference unknown (no live punch yet)';
        if (drift is num) {
          final s = drift.toInt();
          driftText = s.abs() < 120
              ? 'clock OK (${s}s)'
              : '⚠️ clock off by ${s.abs() >= 3600 ? '${(s.abs() / 3600).toStringAsFixed(1)} h' : '${(s.abs() / 60).round()} min'}'
                  ' (${s > 0 ? 'device behind' : 'device ahead'})';
        }
        lines.add('   device ${dev.deviceName} ($ip, ${dev.branchId}): '
            'last poll ${lastPoll ?? 'never on this PC'}, '
            'newest punch held ${newest != null ? DateFormat('yyyy-MM-dd HH:mm').format(newest) : 'none in 14 days'}, '
            '$driftText');
      }

      for (final l in lines) {
        SyncLog.write(l);
      }
    } catch (e) {
      debugPrint('[AttendanceSelfCheck] skipped: $e');
    } finally {
      _running = false;
    }
  }
}
