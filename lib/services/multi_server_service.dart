// lib/services/multi_server_service.dart

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'auto_update_service.dart';
import 'local_storage_service.dart';
import '../utils/network_utils.dart';
import '../config/constants.dart';

class ServerNodeInfo {
  final String serverId;
  final String serverName;
  final String branchId;
  final String ipAddress;
  final int port;
  final String role; // 'primary', 'secondary', 'standby'
  final bool isOnline;
  final int connectedClients;
  final int syncQueueSize;
  final DateTime lastHeartbeat;
  final String appVersion;

  ServerNodeInfo({
    required this.serverId,
    required this.serverName,
    required this.branchId,
    required this.ipAddress,
    required this.port,
    required this.role,
    required this.isOnline,
    required this.connectedClients,
    required this.syncQueueSize,
    required this.lastHeartbeat,
    required this.appVersion,
  });

  factory ServerNodeInfo.fromMap(Map<String, dynamic> map, String id) {
    return ServerNodeInfo(
      serverId: id,
      serverName: map['serverName'] ?? 'Branch Server',
      branchId: map['branchId'] ?? '',
      ipAddress: map['ipAddress'] ?? '127.0.0.1',
      port: map['port'] as int? ?? AppNetwork.websocketPort,
      role: map['role'] ?? 'secondary',
      isOnline: map['isOnline'] as bool? ?? false,
      connectedClients: map['connectedClients'] as int? ?? 0,
      syncQueueSize: map['syncQueueSize'] as int? ?? 0,
      lastHeartbeat: map['lastHeartbeat'] is Timestamp
          ? (map['lastHeartbeat'] as Timestamp).toDate()
          : DateTime.now(),
      appVersion: map['appVersion'] ?? AutoUpdateService.currentVersion,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'serverId': serverId,
      'serverName': serverName,
      'branchId': branchId,
      'ipAddress': ipAddress,
      'port': port,
      'role': role,
      'isOnline': isOnline,
      'connectedClients': connectedClients,
      'syncQueueSize': syncQueueSize,
      'lastHeartbeat': FieldValue.serverTimestamp(),
      'appVersion': appVersion,
    };
  }
}

class MultiServerService {
  static final MultiServerService _instance = MultiServerService._internal();
  factory MultiServerService() => _instance;
  MultiServerService._internal();

  Timer? _heartbeatTimer;
  String? _currentServerId;

  /// Registers and periodically updates this machine's server node record.
  Future<void> registerAndHeartbeat({
    required String branchId,
    required String serverRole, // 'primary', 'secondary', 'standby'
    required int connectedClientsCount,
    required int syncQueueSize,
  }) async {
    try {
      final ip = await getPrimaryLanIp() ?? '192.168.1.x';
      final hostName = Platform.localHostname.isNotEmpty ? Platform.localHostname : 'Branch-Server';
      final serverId = 'srv_${hostName.toLowerCase().replaceAll(RegExp(r'\s+'), '_')}';
      _currentServerId = serverId;

      final serverData = {
        'serverId': serverId,
        'serverName': '$hostName Server',
        'branchId': branchId,
        'ipAddress': ip,
        'port': AppNetwork.websocketPort,
        'role': serverRole,
        'isOnline': true,
        'connectedClients': connectedClientsCount,
        'syncQueueSize': syncQueueSize,
        'lastHeartbeat': FieldValue.serverTimestamp(),
        'appVersion': AutoUpdateService.currentVersion,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      // 1. Cache locally in Hive (Pure Local Mode - zero continuous Firestore quota usage)
      final hiveData = Map<String, dynamic>.from(serverData);
      hiveData['lastHeartbeat'] = DateTime.now().toIso8601String();
      hiveData['updatedAt'] = DateTime.now().toIso8601String();

      final box = await Hive.openBox('branch_servers');
      await box.put(serverId, hiveData);

      // 2. Also keep global branch active server record locally in Hive for client auto-discovery
      if (serverRole == 'primary' && Hive.isBoxOpen(LocalStorageService.branchesBox)) {
        final branchesBox = Hive.box(LocalStorageService.branchesBox);
        final branchKey = 'branch:$branchId';
        final existing = branchesBox.get(branchKey);
        final map = existing is Map ? Map<String, dynamic>.from(existing) : <String, dynamic>{'id': branchId};
        map['activeServerIp'] = ip;
        map['activeServerPort'] = AppNetwork.websocketPort;
        map['serverBranchId'] = branchId;
        await branchesBox.put(branchKey, map);
      }

      debugPrint('[MultiServerService] Local node heartbeat recorded for $serverId ($ip:$serverRole)');
    } catch (e) {
      debugPrint('[MultiServerService] Heartbeat recording error: $e');
    }
  }

  /// Starts periodic heartbeat updates (pure local Hive & LAN broadcast)
  void startHeartbeatLoop({
    required String branchId,
    required String Function() roleSupplier,
    required int Function() clientsSupplier,
    required int Function() queueSupplier,
  }) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      registerAndHeartbeat(
        branchId: branchId,
        serverRole: roleSupplier(),
        connectedClientsCount: clientsSupplier(),
        syncQueueSize: queueSupplier(),
      );
    });
  }

  /// Stops heartbeat loop and marks node as offline locally
  Future<void> stopHeartbeat(String branchId) async {
    _heartbeatTimer?.cancel();
    if (_currentServerId != null && branchId.isNotEmpty) {
      try {
        if (Hive.isBoxOpen('branch_servers')) {
          final box = Hive.box('branch_servers');
          final raw = box.get(_currentServerId);
          if (raw is Map) {
            final data = Map<String, dynamic>.from(raw);
            data['isOnline'] = false;
            data['lastHeartbeat'] = DateTime.now().toIso8601String();
            await box.put(_currentServerId, data);
          }
        }
      } catch (e) {
        debugPrint('[MultiServerService] Failed to mark server offline: $e');
      }
    }
  }

  /// Real-time stream of all servers for a specific branch or all branches from local Hive
  Stream<List<ServerNodeInfo>> getBranchServersStream(String branchId) async* {
    final box = await Hive.openBox('branch_servers');
    
    List<ServerNodeInfo> readCurrent() {
      final list = <ServerNodeInfo>[];
      for (final k in box.keys) {
        final val = box.get(k);
        if (val is Map) {
          final sId = k.toString();
          final item = Map<String, dynamic>.from(val);
          final bId = (item['branchId'] ?? '').toString().toLowerCase().trim();
          if (branchId.isEmpty || branchId == 'all' || branchId == 'global' || bId == branchId.toLowerCase().trim()) {
            list.add(ServerNodeInfo.fromMap(item, sId));
          }
        }
      }
      return list;
    }

    // Yield initial cached servers
    yield readCurrent();

    // Stream subsequent local updates
    await for (final _ in box.watch()) {
      yield readCurrent();
    }
  }

  /// Sets a specific server node as the Primary Server for the branch locally
  Future<void> promoteToPrimary(String branchId, String targetServerId, String targetIp) async {
    try {
      final box = await Hive.openBox('branch_servers');
      for (final k in box.keys) {
        final val = box.get(k);
        if (val is Map) {
          final data = Map<String, dynamic>.from(val);
          if (k.toString() == targetServerId) {
            data['role'] = 'primary';
            data['updatedAt'] = DateTime.now().toIso8601String();
          } else {
            data['role'] = 'secondary';
            data['updatedAt'] = DateTime.now().toIso8601String();
          }
          await box.put(k, data);
        }
      }

      // Update primary branch active IP pointer locally in Hive
      if (Hive.isBoxOpen(LocalStorageService.branchesBox)) {
        final branchesBox = Hive.box(LocalStorageService.branchesBox);
        final branchKey = 'branch:$branchId';
        final existing = branchesBox.get(branchKey);
        final map = existing is Map ? Map<String, dynamic>.from(existing) : <String, dynamic>{'id': branchId};
        map['activeServerIp'] = targetIp;
        await branchesBox.put(branchKey, map);
      }

      debugPrint('[MultiServerService] Promoted $targetServerId ($targetIp) to Primary Server locally');
    } catch (e) {
      debugPrint('[MultiServerService] Failed to promote primary server: $e');
    }
  }
}
