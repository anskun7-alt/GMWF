import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gmwf/widgets/nexus_server_dashboard/nexus_colors.dart';
import 'package:gmwf/widgets/nexus_server_dashboard/nexus_metric_card.dart';
import 'package:gmwf/widgets/nexus_server_dashboard/nexus_performance_chart.dart';
import 'package:gmwf/widgets/nexus_server_dashboard/nexus_resource_cards.dart';
import 'package:gmwf/widgets/nexus_server_dashboard/nexus_devices_table.dart';
import 'package:gmwf/widgets/nexus_server_dashboard/nexus_activity_stream.dart';
import 'package:gmwf/widgets/nexus_server_dashboard/nexus_top_header.dart';
import 'package:gmwf/widgets/nexus_server_dashboard/nexus_sidebar.dart';
import 'package:gmwf/widgets/nexus_server_dashboard/nexus_views.dart';

void main() {
  testWidgets('NexusMetricCard renders values, icons, and trends', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NexusMetricCard(
            label: 'Connected Devices',
            value: '4',
            subtext: '4 online on LAN',
            icon: Icons.devices_rounded,
            iconColor: NexusColors.primary,
            iconBgColor: NexusColors.mutedBg,
            trendText: '+2 online',
            isTrendPositive: true,
          ),
        ),
      ),
    );

    expect(find.text('CONNECTED DEVICES'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    expect(find.text('+2 online'), findsOneWidget);
    expect(find.text('4 online on LAN'), findsOneWidget);
  });

  testWidgets('NexusSidebar renders all 3 navigation sections and active indicator', (tester) async {
    tester.view.physicalSize = const Size(1280, 960);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    int selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NexusSidebar(
            selectedIndex: selected,
            onSelectTab: (idx) => selected = idx,
            isRunning: true,
            serverIp: '192.168.1.40',
            port: 53281,
            connectedDevicesCount: 3,
            activeUsersCount: 2,
            pendingEventsCount: 0,
            cpuLoadPercent: 0.15,
            adminName: 'Shahmeer',
          ),
        ),
      ),
    );

    expect(find.text('GMWF SERVER'), findsOneWidget);
    expect(find.text('SERVER CONTROL CENTER'), findsOneWidget);
    expect(find.text('WORKSPACE'), findsOneWidget);
    expect(find.text('OBSERVABILITY'), findsOneWidget);
    expect(find.text('SYSTEM'), findsOneWidget);
    expect(find.text('Overview'), findsOneWidget);
    expect(find.text('Connected Devices'), findsOneWidget);
    expect(find.text('192.168.1.40:53281'), findsOneWidget);
    expect(find.text('ONLINE'), findsOneWidget);
  });

  testWidgets('NexusDevicesTable renders device rows with status badges', (tester) async {
    final devices = [
      NexusDeviceItem(
        id: '1',
        name: 'Sadia Amir',
        role: 'receptionist',
        ipAddress: '192.168.1.37',
        osName: 'Windows 11',
        appVersion: 'v1.6.4',
        lastActive: DateTime.now(),
      ),
      NexusDeviceItem(
        id: '2',
        name: 'Zabiullah',
        role: 'doctor',
        ipAddress: '192.168.1.41',
        osName: 'Windows 10',
        appVersion: 'v1.6.4',
        lastActive: DateTime.now().subtract(const Duration(minutes: 5)),
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: NexusDevicesTable(devices: devices),
          ),
        ),
      ),
    );

    expect(find.text('Connected Infrastructure Nodes'), findsOneWidget);
    expect(find.text('Sadia Amir'), findsOneWidget);
    expect(find.text('Zabiullah'), findsOneWidget);
    expect(find.text('192.168.1.37'), findsOneWidget);
    expect(find.text('192.168.1.41'), findsOneWidget);
    expect(find.text('RECEPTIONIST'), findsOneWidget);
    expect(find.text('DOCTOR'), findsOneWidget);
  });

  testWidgets('NexusActivityStream parses log severities correctly', (tester) async {
    final rawLogs = [
      '✅ Server started on 192.168.1.40:53281',
      '⚠️ Duplicate messageId=123 from socket — ACK & ignore',
      '❌ Could not park unsaved message: timeout',
      '📨 save_entry: Sadia Amir',
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: NexusActivityStream(rawLogs: rawLogs),
          ),
        ),
      ),
    );

    expect(find.text('Live System Activity'), findsOneWidget);
    expect(find.text('SYSTEM'), findsOneWidget);
    expect(find.text('WARN'), findsOneWidget);
    expect(find.text('ERROR'), findsOneWidget);
    expect(find.text('INFO'), findsOneWidget);
  });
}
