import 'dart:async';
import 'dart:convert';
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
  DateTime? _lastMachineQuery;

  /// The whole-machine reading (CPU / RAM / disk) starts powershell.exe with 3 CIM queries,
  /// which costs 1–2 s of a full core and a 60–80 MB RAM spike on the i3 clinic PCs — and on
  /// the server PC that is the same machine that has to answer token requests at once. So it
  /// now runs once at start and then only every [machineInterval] (30 min); between those,
  /// only this app's own memory is refreshed (free, no process started) every [interval].
  static const Duration machineInterval = Duration(minutes: 30);

  void startMonitoring({Duration interval = const Duration(minutes: 1)}) {
    _timer?.cancel();
    _queryMetrics();
    _timer = Timer.periodic(interval, (_) => _queryMetrics());
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

      // Between machine queries keep the last machine reading and only refresh app memory.
      final prev = _currentSnapshot;
      var cpuKnown = prev.cpuKnown, ramKnown = prev.ramKnown, diskKnown = prev.diskKnown;
      double cpu = prev.cpuPercent, ramPct = prev.ramPercent, usedRam = prev.usedRamGb,
          totalRam = prev.totalRamGb, diskPct = prev.diskPercent, usedDisk = prev.usedDiskGb,
          totalDisk = prev.totalDiskGb;
      var drive = prev.diskDrive;
      final machineDue = _lastMachineQuery == null ||
          DateTime.now().difference(_lastMachineQuery!) >= machineInterval;

      if (io.Platform.isWindows && machineDue) {
        _lastMachineQuery = DateTime.now();
        cpuKnown = false;
        ramKnown = false;
        diskKnown = false;
        // One short PowerShell query (async, off the UI thread) every 30 s. Measures the whole
        // machine: CPU load, physical memory, and the drive the app is installed on.
        drive = io.Platform.resolvedExecutable.isNotEmpty ? io.Platform.resolvedExecutable.substring(0, 2) : 'C:';
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
          ).timeout(const Duration(seconds: 15));
          if (result.exitCode == 0) {
            final j = jsonDecode(result.stdout.toString().trim()) as Map<String, dynamic>;
            final c = j['cpu'];
            if (c is num) {
              cpu = (c / 100).clamp(0.0, 1.0);
              cpuKnown = true;
            }
            final totalKb = j['totalKb'], freeKb = j['freeKb'];
            if (totalKb is num && freeKb is num && totalKb > 0) {
              totalRam = totalKb / (1024 * 1024);
              usedRam = (totalKb - freeKb) / (1024 * 1024);
              ramPct = (usedRam / totalRam).clamp(0.0, 1.0);
              ramKnown = true;
            }
            final dsize = j['dsize'], dfree = j['dfree'];
            if (dsize is num && dfree is num && dsize > 0) {
              totalDisk = dsize / (1024 * 1024 * 1024);
              usedDisk = (dsize - dfree) / (1024 * 1024 * 1024);
              diskPct = (usedDisk / totalDisk).clamp(0.0, 1.0);
              diskKnown = true;
            }
          } else {
            debugPrint('[SystemMetricsService] PowerShell exit ${result.exitCode}: ${result.stderr}');
          }
        } catch (e) {
          debugPrint('[SystemMetricsService] Windows metrics query failed: $e');
        }
      }

      final cpuStatus = !cpuKnown
          ? 'Not available'
          : cpu > 0.8
              ? 'High load'
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
}
