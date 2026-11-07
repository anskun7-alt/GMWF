import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gmwf/services/system_metrics_service.dart';

/// The server dashboard's CPU / RAM / disk figures come from native Windows calls
/// (GetSystemTimes, GlobalMemoryStatusEx, GetDiskFreeSpaceExW), sampled every 5 s.
void main() {
  test('Windows: CPU, RAM and disk are really measured', () async {
    final svc = SystemMetricsService();
    final samples = <SystemSnapshot>[];
    final sub = svc.metricsStream.listen(samples.add);
    svc.startMonitoring();
    await Future.delayed(const Duration(seconds: 11));
    svc.stopMonitoring();
    await sub.cancel();

    final last = svc.currentSnapshot;
    // ignore: avoid_print
    print('samples=${samples.length} cpu=${(last.cpuPercent * 100).toStringAsFixed(1)}% '
        'ram=${last.usedRamGb}/${last.totalRamGb} GB disk ${last.diskDrive} '
        '${last.usedDiskGb}/${last.totalDiskGb} GB status=${last.cpuStatus}');

    expect(samples.length, greaterThanOrEqualTo(2));
    expect(last.cpuKnown, isTrue, reason: 'second sample gives a real CPU delta');
    expect(last.cpuPercent, inInclusiveRange(0.0, 1.0));
    expect(last.ramKnown, isTrue);
    expect(last.totalRamGb, greaterThan(0.5));
    expect(last.diskKnown, isTrue);
    expect(last.totalDiskGb, greaterThan(1));
  }, skip: !Platform.isWindows ? 'Windows only' : false, timeout: const Timeout(Duration(seconds: 40)));
}
