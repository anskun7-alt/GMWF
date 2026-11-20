import 'dart:async';
import 'dart:convert';
import 'system_metrics_native_stub.dart' if (dart.library.ffi) 'system_metrics_native_ffi.dart';
import 'dart:io' as io;
import 'package:flutter/foundation.dart';

/// A reading of this PC's real resource use. A value is only shown when it was actually
/// measured: [cpuKnown] / [ramKnown] / [diskKnown] are false when the OS query failed or the
/// platform is unsupported, and the UI must then show "n/a" rather than an invented number.
class SystemSnapshot {
  final bool cpuKnown;
  final bool ramKnown;
  final bool diskKnown;
  final double cpuPercent; // 0.0 - 1.0
  final double ramPercent; // 0.0 - 1.0
  final double usedRamGb;
  final double totalRamGb;
  final double diskPercent; // 0.0 - 1.0
  final double usedDiskGb;
  final double totalDiskGb;
  final String diskDrive;
  final double appProcessRamMb;
  final String cpuStatus;
  final DateTime timestamp;

  const SystemSnapshot({
    this.cpuKnown = false,
    this.ramKnown = false,
    this.diskKnown = false,
    this.cpuPercent = 0,
    this.ramPercent = 0,
    this.usedRamGb = 0,
    this.totalRamGb = 0,
    this.diskPercent = 0,
    this.usedDiskGb = 0,
    this.totalDiskGb = 0,
    this.diskDrive = '',
    this.appProcessRamMb = 0,
    this.cpuStatus = 'Measuring…',
    required this.timestamp,
  });
}

class SystemMetricsService {
  static final SystemMetricsService _instance = SystemMetricsService._internal();
  factory SystemMetricsService() => _instance;
  SystemMetricsService._internal();

  SystemSnapshot _currentSnapshot = SystemSnapshot(timestamp: DateTime.now());
  SystemSnapshot get currentSnapshot => _currentSnapshot;

  final StreamController<SystemSnapshot> _metricsController = StreamController<SystemSnapshot>.broadcast();
  Stream<SystemSnapshot> get metricsStream => _metricsController.stream;

  Timer? _timer;
  bool _isQuerying = false;
  DateTime? _lastDiskQuery;
  DateTime? _lastFallbackQuery;

  /// How often CPU and memory are sampled. On Windows each sample is three cheap kernel calls
  /// (GetSystemTimes / GlobalMemoryStatusEx), so CPU is the real average over this window.
  /// Before, a PowerShell process ran once every 30 minutes: the CPU figure was up to 30 min
  /// old, measured the load PowerShell itself caused, and often timed out ("n/a") on the
  /// clinic PCs.
  static const Duration sampleInterval = Duration(seconds: 5);
  static const Duration diskInterval = Duration(minutes: 5);

  /// Only used when the native Windows calls are unavailable.
  static const Duration fallbackInterval = Duration(minutes: 5);

  void startMonitoring({Duration interval = sampleInterval}) {
    _timer?.cancel();
    _queryMetrics();
    _timer = Timer.periodic(interval < sampleInterval ? sampleInterval : interval, (_) => _queryMetrics());
  }

  void stopMonitoring() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _queryMetrics() async {
    if (_isQuerying || kIsWeb) return;
    _isQuerying = true;
    try {
      double appRamMb = 0;
      try {
        appRamMb = io.ProcessInfo.currentRss / (1024 * 1024);
      } catch (_) {}

      final prev = _currentSnapshot;
      var cpuKnown = prev.cpuKnown, ramKnown = prev.ramKnown, diskKnown = prev.diskKnown;
      double cpu = prev.cpuPercent, ramPct = prev.ramPercent, usedRam = prev.usedRamGb,
          totalRam = prev.totalRamGb, diskPct = prev.diskPercent, usedDisk = prev.usedDiskGb,
          totalDisk = prev.totalDiskGb;
      var drive = prev.diskDrive.isNotEmpty
          ? prev.diskDrive
          : (io.Platform.resolvedExecutable.length >= 2 ? io.Platform.resolvedExecutable.substring(0, 2) : 'C:');

      if (io.Platform.isWindows) {
        final native = WinNative.instance;
        if (native != null) {
          // CPU: busy share of the time since the previous sample.
          final c = native.cpuBusyFraction();
          if (c != null) {
            cpu = c;
            cpuKnown = true;
          } else if (!cpuKnown) {
            cpuKnown = false; // first sample only sets the baseline
          }
          final mem = native.memory();
          if (mem != null) {
            totalRam = mem.totalBytes / (1024 * 1024 * 1024);
            usedRam = (mem.totalBytes - mem.availBytes) / (1024 * 1024 * 1024);
            ramPct = totalRam > 0 ? (usedRam / totalRam).clamp(0.0, 1.0) : 0;
            ramKnown = totalRam > 0;
          }
          final diskDue = _lastDiskQuery == null || DateTime.now().difference(_lastDiskQuery!) >= diskInterval;
          if (diskDue) {
            _lastDiskQuery = DateTime.now();
            final d = native.disk('$drive\\');
            if (d != null && d.totalBytes > 0) {
              totalDisk = d.totalBytes / (1024 * 1024 * 1024);
              usedDisk = (d.totalBytes - d.freeBytes) / (1024 * 1024 * 1024);
              diskPct = (usedDisk / totalDisk).clamp(0.0, 1.0);
              diskKnown = true;
            }
          }
        } else {
          final due = _lastFallbackQuery == null || DateTime.now().difference(_lastFallbackQuery!) >= fallbackInterval;
          if (due) {
            _lastFallbackQuery = DateTime.now();
            final r = await _powerShellFallback(drive);
            if (r != null) {
              if (r.cpu != null) { cpu = r.cpu!; cpuKnown = true; }
              if (r.totalRam != null) { totalRam = r.totalRam!; usedRam = r.usedRam!; ramPct = r.ramPct!; ramKnown = true; }
              if (r.totalDisk != null) { totalDisk = r.totalDisk!; usedDisk = r.usedDisk!; diskPct = r.diskPct!; diskKnown = true; }
            }
          }
        }
      }

      final cpuStatus = !cpuKnown
          ? 'Measuring…'
          : cpu > 0.8
              ? 'High'
              : cpu > 0.4
                  ? 'Moderate'
                  : 'Low';

      _currentSnapshot = SystemSnapshot(
        cpuKnown: cpuKnown,
        ramKnown: ramKnown,
        diskKnown: diskKnown,
        cpuPercent: cpu,
        ramPercent: ramPct,
        usedRamGb: double.parse(usedRam.toStringAsFixed(1)),
        totalRamGb: double.parse(totalRam.toStringAsFixed(1)),
        diskPercent: diskPct,
        usedDiskGb: double.parse(usedDisk.toStringAsFixed(1)),
        totalDiskGb: double.parse(totalDisk.toStringAsFixed(1)),
        diskDrive: drive,
        appProcessRamMb: double.parse(appRamMb.toStringAsFixed(1)),
        cpuStatus: cpuStatus,
        timestamp: DateTime.now(),
      );
      _metricsController.add(_currentSnapshot);
    } catch (e) {
      debugPrint('[SystemMetricsService] Error querying system metrics: $e');
    } finally {
      _isQuerying = false;
    }
  }

  /// Last resort if the kernel32 calls cannot be loaded (should not happen on Windows 7+).
  Future<({double? cpu, double? totalRam, double? usedRam, double? ramPct, double? totalDisk, double? usedDisk, double? diskPct})?>
      _powerShellFallback(String drive) async {
    const script = r'''
$ErrorActionPreference='Stop'
$cpu=(Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
$os=Get-CimInstance Win32_OperatingSystem
$d=Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='__DRIVE__'"
@{cpu=$cpu;totalKb=$os.TotalVisibleMemorySize;freeKb=$os.FreePhysicalMemory;dsize=$d.Size;dfree=$d.FreeSpace} | ConvertTo-Json -Compress
''';
    try {
      final result = await io.Process.run(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-Command', script.replaceAll('__DRIVE__', drive)],
      ).timeout(const Duration(seconds: 10));
      if (result.exitCode != 0) return null;
      final j = jsonDecode(result.stdout.toString().trim()) as Map<String, dynamic>;
      double? cpu, totalRam, usedRam, ramPct, totalDisk, usedDisk, diskPct;
      final c = j['cpu'];
      if (c is num) cpu = (c / 100).clamp(0.0, 1.0);
      final totalKb = j['totalKb'], freeKb = j['freeKb'];
      if (totalKb is num && freeKb is num && totalKb > 0) {
        totalRam = totalKb / (1024 * 1024);
        usedRam = (totalKb - freeKb) / (1024 * 1024);
        ramPct = (usedRam / totalRam).clamp(0.0, 1.0);
      }
      final dsize = j['dsize'], dfree = j['dfree'];
      if (dsize is num && dfree is num && dsize > 0) {
        totalDisk = dsize / (1024 * 1024 * 1024);
        usedDisk = (dsize - dfree) / (1024 * 1024 * 1024);
        diskPct = (usedDisk / totalDisk).clamp(0.0, 1.0);
      }
      return (cpu: cpu, totalRam: totalRam, usedRam: usedRam, ramPct: ramPct, totalDisk: totalDisk, usedDisk: usedDisk, diskPct: diskPct);
    } catch (e) {
      debugPrint('[SystemMetricsService] PowerShell fallback failed: $e');
      return null;
    }
  }
}

