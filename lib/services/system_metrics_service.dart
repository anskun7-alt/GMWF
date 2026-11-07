import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
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
        final native = _WinNative.instance;
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

// ── Native Windows readings (kernel32 via dart:ffi, no extra packages) ──────────────────────

typedef _GetSystemTimesC = ffi.Int32 Function(ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>);
typedef _GetSystemTimesD = int Function(ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>);
typedef _MemStatusC = ffi.Int32 Function(ffi.Pointer<ffi.Uint8>);
typedef _MemStatusD = int Function(ffi.Pointer<ffi.Uint8>);
typedef _DiskFreeC = ffi.Int32 Function(ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>);
typedef _DiskFreeD = int Function(ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>);
typedef _LocalAllocC = ffi.Pointer<ffi.Uint8> Function(ffi.Uint32, ffi.IntPtr);
typedef _LocalAllocD = ffi.Pointer<ffi.Uint8> Function(int, int);

class _WinNative {
  static _WinNative? _inst;
  static bool _tried = false;

  /// null when not on Windows or kernel32 could not be bound.
  static _WinNative? get instance {
    if (_tried) return _inst;
    _tried = true;
    if (!io.Platform.isWindows) return null;
    try {
      _inst = _WinNative._();
    } catch (e) {
      debugPrint('[SystemMetricsService] native metrics unavailable: $e');
      _inst = null;
    }
    return _inst;
  }

  late final _GetSystemTimesD _getSystemTimes;
  late final _MemStatusD _memStatus;
  late final _DiskFreeD _diskFree;

  /// One fixed scratch buffer (LPTR = zeroed) reused for every call, never freed.
  late final ffi.Pointer<ffi.Uint8> _buf;
  static const _offIdle = 0, _offKernel = 8, _offUser = 16;
  static const _offMem = 32; // MEMORYSTATUSEX, 64 bytes
  static const _offDisk = 96; // 3 x ULARGE_INTEGER
  static const _offPath = 128; // UTF-16 drive root, e.g. "C:\"
  static const _bufSize = 256;

  int? _prevIdle, _prevTotal;

  _WinNative._() {
    final k32 = ffi.DynamicLibrary.open('kernel32.dll');
    _getSystemTimes = k32.lookupFunction<_GetSystemTimesC, _GetSystemTimesD>('GetSystemTimes');
    _memStatus = k32.lookupFunction<_MemStatusC, _MemStatusD>('GlobalMemoryStatusEx');
    _diskFree = k32.lookupFunction<_DiskFreeC, _DiskFreeD>('GetDiskFreeSpaceExW');
    final localAlloc = k32.lookupFunction<_LocalAllocC, _LocalAllocD>('LocalAlloc');
    _buf = localAlloc(0x0040 /* LPTR */, _bufSize);
    if (_buf.address == 0) throw StateError('LocalAlloc failed');
  }

  ffi.Pointer<ffi.Uint8> _at(int off) => ffi.Pointer<ffi.Uint8>.fromAddress(_buf.address + off);
  int _u64(int off) => _at(off).cast<ffi.Uint64>().value;

  /// Share of time the CPUs were busy since the previous call (null on the first call).
  double? cpuBusyFraction() {
    if (_getSystemTimes(_at(_offIdle), _at(_offKernel), _at(_offUser)) == 0) return null;
    final idle = _u64(_offIdle);
    final total = _u64(_offKernel) + _u64(_offUser); // kernel time includes idle time
    final pIdle = _prevIdle, pTotal = _prevTotal;
    _prevIdle = idle;
    _prevTotal = total;
    if (pIdle == null || pTotal == null) return null;
    final dTotal = total - pTotal;
    final dIdle = idle - pIdle;
    if (dTotal <= 0) return null;
    return ((dTotal - dIdle) / dTotal).clamp(0.0, 1.0);
  }

  ({int totalBytes, int availBytes})? memory() {
    _at(_offMem).cast<ffi.Uint32>().value = 64; // dwLength
    if (_memStatus(_at(_offMem)) == 0) return null;
    return (totalBytes: _u64(_offMem + 8), availBytes: _u64(_offMem + 16));
  }

  ({int totalBytes, int freeBytes})? disk(String root) {
    final units = root.codeUnits;
    if ((units.length + 1) * 2 > _bufSize - _offPath) return null;
    final p = _at(_offPath).cast<ffi.Uint16>();
    for (var i = 0; i < units.length; i++) {
      ffi.Pointer<ffi.Uint16>.fromAddress(p.address + i * 2).value = units[i];
    }
    ffi.Pointer<ffi.Uint16>.fromAddress(p.address + units.length * 2).value = 0;
    if (_diskFree(_at(_offPath), _at(_offDisk), _at(_offDisk + 8), _at(_offDisk + 16)) == 0) return null;
    return (totalBytes: _u64(_offDisk + 8), freeBytes: _u64(_offDisk + 16));
  }
}
