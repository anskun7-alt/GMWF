// lib/services/zkteco_network_service.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import '../models/biometric_device_config.dart';
import '../models/biometric_credential.dart';
import 'local_storage_service.dart';
import 'finance_local_storage.dart';
import 'camp_session_service.dart';
import 'sync_service.dart';
import '../realtime/realtime_events.dart';
import '../realtime/realtime_manager.dart';

class ZkTecoNetworkService {
  static const int defaultHttpPort = 8088;
  static const int defaultSocketPort = 4370;
  static const Uuid _uuid = Uuid();

  static HttpServer? _httpServer;
  static RawDatagramSocket? _udpSocket;
  static bool _isListening = false;
  static Timer? _activePollingTimer;
  static StreamSubscription? _firestorePunchesSub;

  // [FIX-3.2] Persistent Hive-backed & fast in-memory punch deduplication store with 24h TTL and 10000 max size
  static const int _dedupMaxSize = 10000;
  static const Duration _dedupTtl = Duration(hours: 24);
  static final Map<String, DateTime> _inMemoryDedup = {};
  static final Map<String, DateTime> _pinLastPunchTime = {};

  static bool isPunchDuplicate(String dedupKey, {String? pin, String? deviceIp, DateTime? timestamp}) {
    final now = DateTime.now();

    // 1. Fast in-memory exact match check
    if (_inMemoryDedup.containsKey(dedupKey)) {
      final cachedAt = _inMemoryDedup[dedupKey]!;
      if (now.difference(cachedAt) <= _dedupTtl) {
        return true;
      }
      _inMemoryDedup.remove(dedupKey);
    }

    // 2. Hardware multi-beep debounce: If the same PIN scans on the same device within 15 seconds
    if (pin != null && pin.isNotEmpty && deviceIp != null && deviceIp.isNotEmpty) {
      final pinKey = '${deviceIp}_$pin';
      final lastPunch = _pinLastPunchTime[pinKey];
      final punchTime = timestamp ?? now;
      if (lastPunch != null && punchTime.difference(lastPunch).inSeconds.abs() < 15) {
        debugPrint('[ZkTecoNetworkService] Debounced rapid multi-scan for PIN $pin on $deviceIp (< 15s)');
        return true;
      }
    }

    // 3. Persistent Hive check
    try {
      if (!Hive.isBoxOpen(LocalStorageService.zktecoPunchDedupBox)) {
        return false;
      }
      final box = Hive.box(LocalStorageService.zktecoPunchDedupBox);
      final raw = box.get(dedupKey);
      if (raw == null) return false;
      final recordedAt = DateTime.tryParse(raw.toString());
      if (recordedAt != null && now.difference(recordedAt) > _dedupTtl) {
        box.delete(dedupKey);
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  static void recordPunchDedupKey(String dedupKey, {String? pin, String? deviceIp, DateTime? timestamp}) {
    final now = DateTime.now();
    _inMemoryDedup[dedupKey] = now;
    if (_inMemoryDedup.length > _dedupMaxSize) {
      _inMemoryDedup.remove(_inMemoryDedup.keys.first);
    }

    if (pin != null && pin.isNotEmpty && deviceIp != null && deviceIp.isNotEmpty) {
      _pinLastPunchTime['${deviceIp}_$pin'] = timestamp ?? now;
      if (_pinLastPunchTime.length > 5000) {
        _pinLastPunchTime.remove(_pinLastPunchTime.keys.first);
      }
    }

    try {
      if (Hive.isBoxOpen(LocalStorageService.zktecoPunchDedupBox)) {
        final box = Hive.box(LocalStorageService.zktecoPunchDedupBox);
        box.put(dedupKey, now.toIso8601String());

        // Max-size purge if over 10000 entries
        if (box.length > _dedupMaxSize) {
          final overflow = box.length - _dedupMaxSize;
          final keysToRemove = box.keys.take(overflow).toList();
          for (final k in keysToRemove) {
            box.delete(k);
          }
        }
      }
    } catch (e) {
      debugPrint('[ZkTecoNetworkService] Dedup record notice: $e');
    }
  }

  /// Feature Flag: Per-device map controlling whether Flutter app actively polls hardware devices over UDP/TCP.
  /// Defaults to true for all devices.
  static Map<String, bool> enableDartPollingByDevice = {};

  /// Returns whether Dart active UDP polling is enabled for a given device IP.
  /// Any device IP not explicitly set to false defaults to true (polling enabled).
  static bool isDartPollingEnabledForDevice(String ipAddress) {
    return enableDartPollingByDevice[ipAddress] ?? true;
  }

  // Streams & Notifiers for UI update
  static final StreamController<Map<String, dynamic>> _punchStreamController =
      StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get punchStream => _punchStreamController.stream;

  static final ValueNotifier<bool> isServerRunningNotifier = ValueNotifier<bool>(false);
  static final ValueNotifier<int> totalPunchesReceivedNotifier = ValueNotifier<int>(0);

  static StreamSubscription? _remoteDevicesSub;
  static StreamSubscription? _remoteCredsSub;

  // ── Initialization & Start ──────────────────────────────────────────────────

  /// Starts the embedded HTTP Server (for ZKTeco ADMS Push) and UDP socket listener
  static Future<bool> startServer({int httpPort = defaultHttpPort}) async {
    if (kIsWeb) return false;
    if (_isListening) {
      if (_activePollingTimer == null || !_activePollingTimer!.isActive) {
        _startActivePolling();
      }
      return true;
    }

    try {
      // 1. Start HTTP Server for ZKTeco ADMS Web Push
      _httpServer = await HttpServer.bind(InternetAddress.anyIPv4, httpPort);
      isServerRunningNotifier.value = true;
      _isListening = true;
      debugPrint('[ZkTecoNetworkService] HTTP Listener started on port $httpPort');

      _httpServer!.listen((HttpRequest request) {
        _handleHttpRequest(request);
      }, onError: (e) {
        debugPrint('[ZkTecoNetworkService] HTTP Server error: $e');
      });

      // 2. Start UDP socket listener on port 4370 for legacy push/heartbeats
      try {
        _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, defaultSocketPort);
        _udpSocket!.listen((RawSocketEvent event) {
          if (event == RawSocketEvent.read) {
            Datagram? dg = _udpSocket!.receive();
            if (dg != null) {
              _handleUdpPacket(dg);
            }
          }
        });
        debugPrint('[ZkTecoNetworkService] UDP Socket Listener started on port $defaultSocketPort');
      } catch (e) {
        debugPrint('[ZkTecoNetworkService] UDP Socket bind warning (port may be in use): $e');
      }

      // 3. Start active UDP polling timer to pull attendance logs from ZKTeco devices
      _startActivePolling();

      // 4. Ensure unmapped punches box is open and ready
      try {
        if (!Hive.isBoxOpen(LocalStorageService.unmappedPunchesBox)) {
          await LocalStorageService.openBoxSafe(LocalStorageService.unmappedPunchesBox);
        }
      } catch (e) {
        debugPrint('[ZkTecoNetworkService] Unmapped box init notice: $e');
      }

      // 5. Initial Cloud sync of Biometric Devices & Credentials from Firestore.
      // Keep the live listeners branch-scoped to avoid global device streams and quota spikes.
      syncBiometricDevicesFromFirestore();
      syncBiometricCredentialsFromFirestore();

      // 6. Start listening to Cloud Firestore for biometric punches from Python services
      listenToFirestorePunches();

      // 7. Upload any pending/recorded attendance to Cloud Firestore
      syncAllRecordedAttendanceToFirestore();

      return true;
    } catch (e) {
      debugPrint('[ZkTecoNetworkService] Failed to start server: $e');
      isServerRunningNotifier.value = false;
      _isListening = false;
      return false;
    }
  }

  /// Stops the server listeners
  static Future<void> stopServer() async {
    _isListening = false;
    isServerRunningNotifier.value = false;
    _activePollingTimer?.cancel();
    _activePollingTimer = null;
    _firestorePunchesSub?.cancel();
    _firestorePunchesSub = null;
    await _httpServer?.close(force: true);
    _httpServer = null;
    _udpSocket?.close();
    _udpSocket = null;
    debugPrint('[ZkTecoNetworkService] Server stopped');
  }

  // ── HTTP ADMS PUSH Request Handler ────────────────────────────────────────

  static void _handleHttpRequest(HttpRequest request) async {
    final uri = request.uri;
    final path = uri.path;
    final clientIp = request.connectionInfo?.remoteAddress.address ?? '';
    final queryParams = uri.queryParameters;

    debugPrint('[ZkTecoNetworkService] Request from $clientIp: ${request.method} $path');

    // Register / Update device heartbeat
    final sn = queryParams['SN'] ?? queryParams['sn'] ?? 'UNKNOWN_DEVICE';
    _registerDeviceHeartbeat(sn, clientIp);

    if (request.method == 'GET') {
      // ADMS Handshake / Heartbeat request: ZKTeco devices request commands or handshake via GET /iclock/cdata or /iclock/getrequest
      request.response.headers.contentType = ContentType.text;

      if (path.contains('/iclock/cdata') || path.contains('/cdata') || queryParams.containsKey('SN') || queryParams.containsKey('sn')) {
        // Standard ADMS Handshake Response required by ZKTeco firmware to initiate log push
        final responseBody = 'GET OPTION FROM: $sn\r\n'
            'Stamp=9999\r\n'
            'OpStamp=9999\r\n'
            'PhotoStamp=9999\r\n'
            'ErrorDelay=30\r\n'
            'Delay=10\r\n'
            'TransTimes=00:00;14:00\r\n'
            'TransInterval=1\r\n'
            'TransFlag=1111000000\r\n'
            'PushProtVer=2.4.1\r\n';
        request.response.write(responseBody);
        await request.response.close();
        debugPrint('[ZkTecoNetworkService] Sent ADMS Handshake options to $clientIp ($sn)');
        return;
      }

      if (path.contains('/iclock/getrequest') || path.contains('/getrequest')) {
        // [PERF-FIX] Do NOT dispatch DATA QUERY ATTLOG on routine heartbeats.
        // Doing so forces the device to dump its entire historical memory (thousands of punches)
        // on every single poll, overwhelming the server and freezing clients.
        // ZKTeco devices push new punches naturally to /iclock/cdata as they happen.
        request.response.headers.contentType = ContentType.text;
        request.response.write('OK\n');
        await request.response.close();
        return;
      }
    } else if (request.method == 'POST') {
      // ADMS Log Data Push: ZKTeco sends attendance records via POST /iclock/cdata or /iclock/devicecmd
      try {
        final bodyText = await utf8.decoder.bind(request).join();
        debugPrint('[ZkTecoNetworkService] Raw PUSH Payload from $clientIp ($path):\n$bodyText');
        _parseAndProcessAdmsPayload(bodyText, clientIp, sn);

        request.response.headers.contentType = ContentType.text;
        request.response.write('OK\n');
        await request.response.close();
        return;
      } catch (e) {
        debugPrint('[ZkTecoNetworkService] Error parsing POST body: $e');
      }
    }

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.text;
    request.response.write('OK\n');
    await request.response.close();
  }


  static void _handleUdpPacket(Datagram dg) {
    try {
      final data = dg.data;
      final ip = dg.address.address;

      debugPrint('[ZkTecoNetworkService] UDP Packet (${data.length} bytes) from $ip');

      // 1. Check if packet is ZKTeco protocol binary packet (starts with magic 0x50, 0x50, 0x82, 0x7D)
      if (data.length >= 8 && data[0] == 0x50 && data[1] == 0x50 && data[2] == 0x82 && data[3] == 0x7D) {
        final body = data.sublist(4);
        _handleZkBinaryUdpPacket(body, ip, 'UDP_DEVICE', dg);
        return;
      }

      // 2. Plaintext ADMS / push format
      final text = utf8.decode(data, allowMalformed: true);
      debugPrint('[ZkTecoNetworkService] UDP Plaintext Packet from $ip: $text');
      _parseAndProcessAdmsPayload(text, ip, 'UDP_DEVICE');
    } catch (e) {
      debugPrint('[ZkTecoNetworkService] UDP error: $e');
    }
  }

  static void _handleZkBinaryUdpPacket(Uint8List body, String deviceIp, String deviceSn, Datagram dg) {
    if (body.length < 8) return;
    final cmd = body[0] | (body[1] << 8);
    final sessionId = body[4] | (body[5] << 8);
    final replyId = body[6] | (body[7] << 8);

    debugPrint('[ZkTecoNetworkService] ZK UDP Binary CMD: 0x${cmd.toRadixString(16)}, Session: $sessionId, Reply: $replyId');

    // Send ACK (CMD_ACK_OK = 0x07D0) back to device so device knows punch was received
    try {
      final ack = _buildZkPacket(command: 0x07D0, sessionId: sessionId, replyId: replyId);
      _udpSocket?.send(ack, dg.address, dg.port);
    } catch (e) {
      debugPrint('[ZkTecoNetworkService] ACK send error: $e');
    }

    // Payload starts after 8-byte header
    if (body.length > 8) {
      final payload = body.sublist(8);
      _parseZkAttendanceData(payload, deviceIp, deviceSn);
    }
  }

  // ── ADMS Data Payload Parser ──────────────────────────────────────────────

  /// Parses ZKTeco ADMS log entries in various formats:
  /// - Tab separated: `101\t2026-08-21 12:09:00\t0\t0\t0\t0`
  /// - Space separated: `101 2026-08-21 12:09:00 0 0`
  /// - Comma separated: `101,2026-08-21 12:09:00,0,0`
  /// - Key-value: `PIN=101\tTIME=2026-08-21 12:09:00`
  static void _parseAndProcessAdmsPayload(String payload, String clientIp, String deviceSn) {
    final lines = payload.split(RegExp(r'[\r\n]+'));
    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('table=') || line.startsWith('ATTLOG') || line.startsWith('OPERLOG')) continue;

      String pin = '';
      DateTime? timestamp;

      if (line.contains('\t')) {
        final parts = line.split('\t');
        if (parts.isNotEmpty) pin = parts[0].trim();
        if (parts.length > 1) timestamp = DateTime.tryParse(parts[1].trim());
      } else if (line.contains(',')) {
        final parts = line.split(',');
        if (parts.isNotEmpty) pin = parts[0].trim();
        if (parts.length > 1) timestamp = DateTime.tryParse(parts[1].trim());
      } else {
        // Space separated: e.g. "101 2026-08-21 12:09:00 0 0"
        final match = RegExp(r'^(\w+)\s+(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})').firstMatch(line);
        if (match != null) {
          pin = match.group(1) ?? '';
          timestamp = DateTime.tryParse(match.group(2) ?? '');
        } else {
          final parts = line.split(RegExp(r'\s+'));
          if (parts.isNotEmpty) pin = parts[0].trim();
          if (parts.length >= 3) {
            timestamp = DateTime.tryParse('${parts[1]} ${parts[2]}');
          }
        }
      }

      // Check key-value format (PIN=101\tTIME=...)
      if (line.contains('PIN=') || line.contains('USERID=') || line.contains('CardNo=')) {
        final pinMatch = RegExp(r'(?:PIN|USERID|CardNo)=(\w+)', caseSensitive: false).firstMatch(line);
        if (pinMatch != null) pin = pinMatch.group(1) ?? pin;
        final timeMatch = RegExp(r'(?:TIME|Date|Timestamp)=([\d\-\s:]+)', caseSensitive: false).firstMatch(line);
        if (timeMatch != null) timestamp = DateTime.tryParse(timeMatch.group(1) ?? '') ?? timestamp;
      }

      final cleanPin = pin.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '').trim();
      if (cleanPin.isNotEmpty && !cleanPin.startsWith('PP')) {
        timestamp ??= DateTime.now();

        // Ignore historical punches older than 3 days to avoid reprocessing stale memory dumps
        if (DateTime.now().difference(timestamp).inDays.abs() > 3) {
          continue;
        }

        final dedupKey = '${clientIp}_${cleanPin}_${timestamp.toIso8601String()}';
        if (isPunchDuplicate(dedupKey)) {
          continue;
        }
        recordPunchDedupKey(dedupKey);

        processIncomingPunch(
          pin: cleanPin,
          timestamp: timestamp,
          deviceIp: clientIp,
          deviceSn: deviceSn,
          source: 'zkteco',
        );
      }
    }
  }

  // ── Processing Incoming Punch & Module Routing ─────────────────────────────

  /// Processes punch from ZKTeco device or Mobile App
  static Future<void> processIncomingPunch({
    required String pin,
    required DateTime timestamp,
    required String deviceIp,
    String deviceSn = '',
    required String source,
    bool enqueueForSync = true,
    bool broadcastLan = true,
  }) async {
    final dedupKey = '${deviceIp}_${pin}_${timestamp.toIso8601String()}';
    if (!isPunchDuplicate(dedupKey)) {
      recordPunchDedupKey(dedupKey);
    }

    final bool isFromCloud = (source == 'firestore_sync' || source == 'firestore_listener');
    final bool shouldEnqueue = enqueueForSync && !isFromCloud;
    final bool shouldBroadcast = broadcastLan && !isFromCloud;

    totalPunchesReceivedNotifier.value++;

    // 1. Resolve physical building location and branch from device config
    final device = getDeviceByIpOrSn(deviceIp, deviceSn);
    final buildingLocation = device?.buildingLocation ?? 'Office';
    final deviceBranch = device?.branchId ?? '';

    // 2. Lookup Biometric Credential mapping
    final credential = getCredentialByPin(pin);

    // 3. Check for Cross-Branch mismatch
    final bool isCrossBranch = credential != null &&
        _isCrossBranchMismatch(credential.branchId, deviceBranch, credential.entityId);

    // 2. Audit: Calculate time drift between Biometric Device clock and Server PC clock
    final serverTime = DateTime.now();
    final deviceTime = timestamp;
    final int rawDifference = serverTime.difference(deviceTime).inSeconds;

    // Clock drift alerts only apply to live real-time hardware events (< 10m old).
    // Historical pulls from device memory or Firestore backfills are past events, NOT clock drift.
    final bool isLiveEvent = (source == 'zkteco_udp_realtime' || source == 'zkteco_hardware' || source == 'zkteco') &&
        rawDifference.abs() <= 600;

    final int timeDriftSeconds = isLiveEvent ? rawDifference : 0;
    final bool hasSignificantDrift = isLiveEvent && timeDriftSeconds.abs() > 180; // > 3 minutes drift on live punch

    String formatDrift(int sec, bool isLive) {
      if (!isLive) return 'Historical Sync';
      if (sec.abs() < 10) return 'In Sync (±0s)';
      final sign = sec >= 0 ? '+' : '-';
      final absSec = sec.abs();
      if (absSec < 60) return '$sign${absSec}s';
      final m = absSec ~/ 60;
      final s = absSec % 60;
      return '$sign${m}m ${s}s';
    }

    final punchRecord = {
      'id': _uuid.v4(),
      'pin': pin,
      'timestamp': timestamp.toIso8601String(),
      'deviceTimestamp': deviceTime.toIso8601String(),
      'serverTimestamp': serverTime.toIso8601String(),
      'timeDriftSeconds': timeDriftSeconds,
      'timeDriftFormatted': formatDrift(timeDriftSeconds, isLiveEvent),
      'hasTimeDriftAlert': hasSignificantDrift,
      'deviceIp': deviceIp,
      'deviceSn': deviceSn,
      'deviceName': device?.deviceName ?? 'ZKTeco Device ($deviceIp)',
      'buildingLocation': buildingLocation,
      'deviceBranchId': deviceBranch,
      'deviceBranchName': LocalStorageService.getBranchName(deviceBranch),
      'source': source,
      'isMapped': credential != null,
      'entityId': credential?.entityId,
      'entityName': credential?.entityName ?? 'Unknown User (PIN $pin)',
      'entityType': credential?.entityType ?? 'unmapped',
      'entityBranchId': credential?.branchId,
      'entityBranchName': credential != null ? LocalStorageService.getBranchName(credential.branchId) : '',
      'isCrossBranchPending': isCrossBranch,
    };

    debugPrint('[ZkTecoNetworkService] Processing Punch (Drift: ${punchRecord['timeDriftFormatted']}): $punchRecord');

    if (credential == null) {
      debugPrint('[ZkTecoNetworkService] Unassigned biometric key detected for PIN $pin at $buildingLocation ($deviceIp)');
      // Broadcast unassigned biometric key to UI & Server Log if recent (< 24h)
      if (isLiveEvent || rawDifference.abs() <= 86400) {
        _punchStreamController.add(punchRecord);
      }
      return;
    }

    if (isCrossBranch) {
      // Cross-branch punch detected -> Create Pending HQ Authorization Record
      final pendingRecord = {
        'id': _uuid.v4(),
        'punchId': punchRecord['id'],
        'pin': pin,
        'entityId': credential.entityId,
        'entityName': credential.entityName,
        'entityType': credential.entityType,
        'employeeBranchId': credential.branchId,
        'employeeBranchName': LocalStorageService.getBranchName(credential.branchId),
        'punchBranchId': deviceBranch,
        'punchBranchName': LocalStorageService.getBranchName(deviceBranch),
        'deviceIp': deviceIp,
        'deviceSn': deviceSn,
        'deviceName': device?.deviceName ?? 'ZKTeco Device ($deviceIp)',
        'buildingLocation': buildingLocation,
        'timestamp': timestamp.toIso8601String(),
        'status': 'pending', // 'pending' | 'approved' | 'rejected'
        'reviewedBy': null,
        'reviewedAt': null,
        'rejectReason': null,
        'source': source,
      };
      await _saveCrossBranchPendingPunch(pendingRecord);
      punchRecord['crossBranchInfo'] = pendingRecord;

      if (shouldBroadcast) {
        try {
          RealtimeManager().sendMessage({
            'event_type': 'cross_branch_punch_alert',
            'data': pendingRecord,
          });
        } catch (e) {
          debugPrint('[ZkTecoNetworkService] Realtime alert broadcast error: $e');
        }
      }
    } else {
      // Auto-route to specific entity attendance module
      await _routePunchToModule(
        credential,
        timestamp,
        buildingLocation,
        source,
        deviceBranch: deviceBranch,
        deviceSn: deviceSn,
        enqueueForSync: shouldEnqueue,
      );
    }

    // Broadcast live or recent (< 24h) mapped punches to UI & Live Server Log
    final bool isRecentOrLive = isLiveEvent || (rawDifference >= 0 && rawDifference <= 86400);
    if (isRecentOrLive) {
      _punchStreamController.add(punchRecord);
    }

    if (shouldBroadcast) {
      try {
        RealtimeManager().sendMessage({
          'event_type': RealtimeEvents.saveBiometricLog,
          'data': punchRecord,
        });
      } catch (e) {
        debugPrint('[ZkTecoNetworkService] Realtime broadcast notice: $e');
      }
    }
  }

  static Future<void> _routePunchToModule(
    BiometricCredential credential,
    DateTime timestamp,
    String location,
    String source, {
    String deviceBranch = '',
    String deviceSn = '',
    bool enqueueForSync = true,
  }) async {
    final type = credential.entityType.toLowerCase();
    final dateStr = DateFormat('yyyy-MM-dd').format(timestamp);
    final timeStr = DateFormat('hh:mm a').format(timestamp);

    debugPrint('[ZkTecoNetworkService] Routing punch for ${credential.entityName} ($type) to module...');

    if (type == 'teacher') {
      // Record in BOTH Office Employee Box AND School Teacher Log Box
      await _recordEmployeeAttendance(
        credential,
        timestamp,
        dateStr,
        timeStr,
        source,
        location,
        deviceBranch: deviceBranch,
        deviceSn: deviceSn,
        enqueueForSync: enqueueForSync,
      );
      await _recordSchoolTeacherAttendance(credential, dateStr, timeStr, source, enqueueForSync: enqueueForSync);
    } else if (type == 'madrassa_student' || type == 'madrassa') {
      // Record in Madrassa Student Log Box
      await _recordMadrassaStudentAttendance(credential, dateStr, timeStr, source, enqueueForSync: enqueueForSync);
    } else if (type == 'school_student' || type == 'school') {
      // Record in School Daily Attendance Box
      await _recordSchoolStudentAttendance(credential, dateStr, timeStr, source, enqueueForSync: enqueueForSync);
    } else {
      // Record in Office / Department / Dispensary Staff Employee Attendance Box
      await _recordEmployeeAttendance(
        credential,
        timestamp,
        dateStr,
        timeStr,
        source,
        location,
        deviceBranch: deviceBranch,
        deviceSn: deviceSn,
        enqueueForSync: enqueueForSync,
      );
    }
  }

  static Future<void> _recordEmployeeAttendance(
    BiometricCredential credential,
    DateTime punchTimestamp,
    String dateStr,
    String timeStr,
    String source,
    String location, {
    String deviceBranch = '',
    String deviceSn = '',
    bool enqueueForSync = true,
  }) async {
    try {
      if (!Hive.isBoxOpen(LocalStorageService.attendanceBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.attendanceBox);
      }
      final box = Hive.box(LocalStorageService.attendanceBox);
      
      final key = '${credential.entityId}_$dateStr';
      final existing = box.get(key);

      // Determine active shift / session for this punch (morning, evening, night)
      final shiftInfo = CampSessionService.resolveShiftAndDateKey(punchTimestamp);
      final sessionKey = shiftInfo.session.toLowerCase(); // 'morning', 'evening', 'night'
      
      // Resolve effective branch accurately:
      // CRITICAL: The physical device where the employee just punched (deviceBranch) takes top priority
      String effectiveBranch = '';
      if (deviceBranch.isNotEmpty && deviceBranch != 'all' && deviceBranch != 'main') {
        effectiveBranch = deviceBranch.toLowerCase().trim();
      } else if (credential.branchId.isNotEmpty && credential.branchId != 'all' && credential.branchId != 'main') {
        effectiveBranch = credential.branchId.toLowerCase().trim();
      } else if (Hive.isBoxOpen(LocalStorageService.employeesBox)) {
        final empRaw = Hive.box(LocalStorageService.employeesBox).get(credential.entityId);
        if (empRaw is Map && empRaw['branchId'] != null) {
          final b = empRaw['branchId'].toString().trim().toLowerCase();
          if (b.isNotEmpty && b != 'all' && b != 'main') effectiveBranch = b;
        }
      }
      if (effectiveBranch.isEmpty) {
        effectiveBranch = 'karachi';
      }

      String resolveBranchDisplayName(String bId) {
        final clean = bId.toLowerCase().replaceAll('branch_', '').trim();
        if (clean.contains('haji')) return 'Haji Camp';
        if (clean.contains('saddar')) return 'Saddar';
        final fromStorage = LocalStorageService.getBranchName(bId);
        return fromStorage.isNotEmpty ? fromStorage : (bId[0].toUpperCase() + bId.substring(1));
      }

      final branchDisplayName = resolveBranchDisplayName(effectiveBranch);

      if (existing != null) {
        final existingMap = Map<String, dynamic>.from(existing as Map);

        // RULE: If HQ Manager manually marked user as Absent/Leave and locked it, DO NOT ALLOW biometric override!
        final isLocked = existingMap['isLockedByAdmin'] == true || 
                         existingMap['isManagerLocked'] == true ||
                         existingMap['manualOverride'] == true;
        if (isLocked) {
          debugPrint('[ZkTecoNetworkService] Biometric scan BLOCKED for ${credential.entityName}: Locked by HQ Manager');
          return;
        }

        final lastPunchTimeStr = existingMap['lastPunchTime']?.toString();
        if (lastPunchTimeStr != null) {
          final lastPunchEventTime = DateTime.tryParse(lastPunchTimeStr);
          if (lastPunchEventTime != null &&
              punchTimestamp.difference(lastPunchEventTime).inMinutes.abs() < 5) {
            debugPrint('[ZkTecoNetworkService] Duplicate punch ignored (< 5 mins) for ${credential.entityName}');
            return;
          }
        }

        // Retrieve or initialize shifts map
        final Map<String, dynamic> shifts = existingMap['shifts'] is Map 
            ? Map<String, dynamic>.from(existingMap['shifts'] as Map) 
            : <String, dynamic>{};

        // Check if there is an unclosed shift at THIS physical facility/branch:
        String? openShiftKeyAtThisBranch;
        final cleanEff = effectiveBranch.replaceAll('branch_', '').trim();
        for (final entry in shifts.entries) {
          if (entry.value is Map) {
            final m = entry.value as Map;
            final bId = (m['branchId'] ?? '').toString().toLowerCase().replaceAll('branch_', '').trim();
            final hasIn = m['checkInTime'] != null;
            final hasOut = m['checkOutTime'] != null;
            if (hasIn && !hasOut && (bId == cleanEff || bId.isEmpty || cleanEff.isEmpty)) {
              openShiftKeyAtThisBranch = entry.key;
              break;
            }
          }
        }

        if (openShiftKeyAtThisBranch != null) {
          // Punch OUT: Close the unclosed shift at this facility/camp
          final shiftEntry = Map<String, dynamic>.from(shifts[openShiftKeyAtThisBranch] as Map);
          final inTsStr = shiftEntry['checkInTimestamp']?.toString();
          final inTs = inTsStr != null ? DateTime.tryParse(inTsStr) : null;
          if (inTs == null || punchTimestamp.isAfter(inTs)) {
            shiftEntry['checkOutTime'] = timeStr;
            shiftEntry['checkOutTimestamp'] = punchTimestamp.toIso8601String();
            shiftEntry['status'] = 'present';
            shiftEntry['departureTime'] = timeStr;
            shifts[openShiftKeyAtThisBranch] = shiftEntry;
          }
        } else {
          // Punch IN: Start a new shift/session at this facility/camp
          String shiftKey = sessionKey;
          if (shifts.containsKey(shiftKey)) {
            final existingShift = shifts[shiftKey];
            final existingBranch = existingShift is Map ? (existingShift['branchId'] ?? '').toString().toLowerCase().replaceAll('branch_', '').trim() : '';
            if (existingBranch != cleanEff) {
              shiftKey = '${sessionKey}_$cleanEff';
            }
          }

          final shiftEntry = {
            'branchId': effectiveBranch,
            'branchName': branchDisplayName,
            'location': location,
            'session': sessionKey,
            'status': 'present',
            'checkInTime': timeStr,
            'arrivalTime': timeStr,
            'checkInTimestamp': punchTimestamp.toIso8601String(),
            'checkOutTime': null,
            'departureTime': null,
            'checkOutTimestamp': null,
            'source': '$source ($location)',
          };
          shifts[shiftKey] = shiftEntry;
        }

        existingMap['shifts'] = shifts;

        // Compute overall day bounds across all shifts
        DateTime? earliestIn;
        DateTime? latestOut;
        String? earliestInStr;
        String? latestOutStr;

        for (final s in shifts.values) {
          if (s is Map) {
            final inTsStr = s['checkInTimestamp']?.toString();
            if (inTsStr != null) {
              final inTs = DateTime.tryParse(inTsStr);
              if (inTs != null && (earliestIn == null || inTs.isBefore(earliestIn))) {
                earliestIn = inTs;
                earliestInStr = s['checkInTime']?.toString();
              }
            }
            final outTsStr = s['checkOutTimestamp']?.toString();
            if (outTsStr != null) {
              final outTs = DateTime.tryParse(outTsStr);
              if (outTs != null && (latestOut == null || outTs.isAfter(latestOut))) {
                latestOut = outTs;
                latestOutStr = s['checkOutTime']?.toString();
              }
            }
          }
        }

        if (earliestInStr != null) {
          existingMap['checkInTime'] = earliestInStr;
          existingMap['arrivalTime'] = earliestInStr;
          existingMap['checkInTimestamp'] = earliestIn?.toIso8601String();
        }
        if (latestOutStr != null) {
          existingMap['checkOutTime'] = latestOutStr;
          existingMap['departureTime'] = latestOutStr;
          existingMap['checkOutTimestamp'] = latestOut?.toIso8601String();
        }

        existingMap['lastPunchTime'] = punchTimestamp.toIso8601String();
        existingMap['status'] = 'present';
        existingMap['synced'] = !enqueueForSync;
        // [BUG-FIX] Write pin/biometricPin so fallback matcher in getAttendanceForDate() works
        existingMap['pin'] = credential.biometricPin;
        existingMap['biometricPin'] = credential.biometricPin;
        await box.put(key, existingMap);

        if (enqueueForSync) {
          // Enqueue cloud sync
          await LocalStorageService.enqueueSync({
            'type': 'save_attendance_record',
            'branchId': effectiveBranch,
            'date': dateStr,
            'employeeId': credential.entityId,
            'entityId': 'att_${effectiveBranch}_${credential.entityId}_$dateStr',
            'data': existingMap,
          });
        }
      } else {
        // First scan of the day -> Check-In time for the respective shift
        final shiftEntry = {
          'branchId': effectiveBranch,
          'branchName': branchDisplayName,
          'location': location,
          'session': sessionKey,
          'status': 'present',
          'checkInTime': timeStr,
          'arrivalTime': timeStr,
          'checkInTimestamp': punchTimestamp.toIso8601String(),
          'checkOutTime': null,
          'departureTime': null,
          'checkOutTimestamp': null,
          'source': '$source ($location)',
        };

        final newRecord = {
          'id': _uuid.v4(),
          'employeeId': credential.entityId,
          'employeeName': credential.entityName,
          'branchId': effectiveBranch,
          'date': dateStr,
          'checkInTime': timeStr,
          'arrivalTime': timeStr,
          'checkInTimestamp': punchTimestamp.toIso8601String(),
          'checkOutTime': null,
          'departureTime': null,
          'checkOutTimestamp': null,
          'status': 'present',
          'attendanceType': 'Full Day',
          'shifts': {
            sessionKey: shiftEntry,
          },
          'source': '$source ($location)',
          'lastPunchTime': punchTimestamp.toIso8601String(),
          'synced': !enqueueForSync,
          // [BUG-FIX] Write pin/biometricPin so fallback matcher in getAttendanceForDate() works
          'pin': credential.biometricPin,
          'biometricPin': credential.biometricPin,
        };
        await box.put(key, newRecord);

        if (enqueueForSync) {
          // Enqueue cloud sync
          await LocalStorageService.enqueueSync({
            'type': 'save_attendance_record',
            'branchId': effectiveBranch,
            'date': dateStr,
            'employeeId': credential.entityId,
            'entityId': 'att_${effectiveBranch}_${credential.entityId}_$dateStr',
            'data': newRecord,
          });
        }
      }
      debugPrint('[ZkTecoNetworkService] Recorded Employee Attendance for ${credential.entityName} ($sessionKey shift)');
    } catch (e) {
      debugPrint('[ZkTecoNetworkService] Error recording employee attendance: $e');
    }
  }

  static Future<void> _recordSchoolTeacherAttendance(
    BiometricCredential credential,
    String dateStr,
    String timeStr,
    String source, {
    bool enqueueForSync = true,
  }) async {
    try {
      if (!Hive.isBoxOpen(LocalStorageService.schoolLogsBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.schoolLogsBox);
      }
      final box = Hive.box(LocalStorageService.schoolLogsBox);
      final branchId = credential.branchId.toLowerCase().trim();
      final logKey = '${branchId}__tchlog__$dateStr';
      final rawLog = box.get(logKey);
      final logMap = rawLog is Map ? Map<String, dynamic>.from(rawLog) : <String, dynamic>{
        'date': dateStr,
        'entries': <String, dynamic>{},
      };
      final entries = Map<String, dynamic>.from((logMap['entries'] as Map?) ?? {});
      final existingEntry = entries[credential.entityId] is Map 
          ? Map<String, dynamic>.from(entries[credential.entityId] as Map)
          : <String, dynamic>{};
      
      existingEntry['status'] = 'present';
      existingEntry['time'] = timeStr;
      existingEntry['source'] = source;
      existingEntry['updatedAt'] = DateTime.now().toIso8601String();
      entries[credential.entityId] = existingEntry;
      logMap['entries'] = entries;
      logMap['lastUpdated'] = DateTime.now().toIso8601String();

      await box.put(logKey, logMap);

      if (enqueueForSync) {
        // Enqueue cloud sync
        await LocalStorageService.enqueueSync({
          'type': 'save_school_teacher_log',
          'branchId': branchId,
          'date': dateStr,
          'entityId': 'tchlog_${branchId}_$dateStr',
          'data': logMap,
        });
      }

      debugPrint('[ZkTecoNetworkService] Recorded School Faculty Attendance in Teacher Log for ${credential.entityName}');
    } catch (e) {
      debugPrint('[ZkTecoNetworkService] Error recording School teacher attendance: $e');
    }
  }

  static Future<void> _recordMadrassaStudentAttendance(
    BiometricCredential credential,
    String dateStr,
    String timeStr,
    String source, {
    bool enqueueForSync = true,
  }) async {
    try {
      if (!Hive.isBoxOpen(LocalStorageService.madrassaLogsBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.madrassaLogsBox);
      }
      final box = Hive.box(LocalStorageService.madrassaLogsBox);

      // 1. Update flat record for backward compat
      final key = '${credential.entityId}_$dateStr';
      final existing = box.get(key);

      if (existing != null) {
        final existingMap = Map<String, dynamic>.from(existing as Map);
        if (existingMap['isLockedByAdmin'] == true || existingMap['isManagerLocked'] == true) {
          debugPrint('[ZkTecoNetworkService] Biometric scan BLOCKED for Madrassa Student ${credential.entityName}: Locked by HQ Manager');
          return;
        }
      }

      final record = {
        'id': _uuid.v4(),
        'studentId': credential.entityId,
        'studentName': credential.entityName,
        'branchId': credential.branchId,
        'date': dateStr,
        'time': timeStr,
        'attendance': 'present',
        'status': 'P', // Present
        'source': source,
        'updatedAt': DateTime.now().toIso8601String(),
      };
      await box.put(key, record);

      // 2. ALSO update the Madrassa daily log document: ${branchId}__log__$dateStr
      final branchId = credential.branchId.toLowerCase().trim();
      final logKey = '${branchId}__log__$dateStr';
      final rawLog = box.get(logKey);
      final logMap = rawLog is Map ? Map<String, dynamic>.from(rawLog) : <String, dynamic>{};
      
      final existingStudentLog = logMap[credential.entityId] is Map 
          ? Map<String, dynamic>.from(logMap[credential.entityId] as Map)
          : <String, dynamic>{};
      
      existingStudentLog['attendance'] = 'present';
      existingStudentLog['status'] = 'P';
      existingStudentLog['time'] = timeStr;
      existingStudentLog['source'] = source;
      existingStudentLog['lastEditedAt'] = DateTime.now().toIso8601String();
      existingStudentLog['lastEditedBy'] = 'Biometric Punch';

      logMap[credential.entityId] = existingStudentLog;
      await box.put(logKey, logMap);

      if (enqueueForSync) {
        // Enqueue cloud sync
        await LocalStorageService.enqueueSync({
          'type': 'save_madrassa_daily_log',
          'branchId': branchId,
          'date': dateStr,
          'entityId': 'madlog_${branchId}_$dateStr',
          'data': logMap,
        });
      }

      debugPrint('[ZkTecoNetworkService] Recorded Madrassa Student Attendance in Daily Log for ${credential.entityName}');
    } catch (e) {
      debugPrint('[ZkTecoNetworkService] Error recording Madrassa student attendance: $e');
    }
  }

  static Future<void> _recordSchoolStudentAttendance(
    BiometricCredential credential,
    String dateStr,
    String timeStr,
    String source, {
    bool enqueueForSync = true,
  }) async {
    try {
      if (!Hive.isBoxOpen(LocalStorageService.schoolLogsBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.schoolLogsBox);
      }
      final box = Hive.box(LocalStorageService.schoolLogsBox);

      // 1. Update flat record for direct lookup
      final key = '${credential.entityId}_$dateStr';
      final existing = box.get(key);

      if (existing != null) {
        final existingMap = Map<String, dynamic>.from(existing as Map);
        if (existingMap['isLockedByAdmin'] == true || existingMap['isManagerLocked'] == true) {
          debugPrint('[ZkTecoNetworkService] Biometric scan BLOCKED for School Student ${credential.entityName}: Locked by HQ Manager');
          return;
        }
      }

      final record = {
        'id': _uuid.v4(),
        'studentId': credential.entityId,
        'studentName': credential.entityName,
        'branchId': credential.branchId,
        'date': dateStr,
        'time': timeStr,
        'status': 'present',
        'source': source,
        'updatedAt': DateTime.now().toIso8601String(),
      };
      await box.put(key, record);

      // 2. ALSO update the daily log document: ${branchId}__log__$dateStr
      final branchId = credential.branchId.toLowerCase().trim();
      final logKey = '${branchId}__log__$dateStr';
      final rawLog = box.get(logKey);
      final logMap = rawLog is Map ? Map<String, dynamic>.from(rawLog) : <String, dynamic>{
        'date': dateStr,
        'entries': <String, dynamic>{},
      };
      final entries = Map<String, dynamic>.from((logMap['entries'] as Map?) ?? {});
      final existingStudentEntry = entries[credential.entityId] is Map 
          ? Map<String, dynamic>.from(entries[credential.entityId] as Map)
          : <String, dynamic>{};
      
      existingStudentEntry['status'] = 'present';
      existingStudentEntry['time'] = timeStr;
      existingStudentEntry['source'] = source;
      existingStudentEntry['updatedAt'] = DateTime.now().toIso8601String();
      entries[credential.entityId] = existingStudentEntry;
      logMap['entries'] = entries;
      logMap['lastUpdated'] = DateTime.now().toIso8601String();

      await box.put(logKey, logMap);

      if (enqueueForSync) {
        // Enqueue cloud sync
        await LocalStorageService.enqueueSync({
          'type': 'save_school_daily_log',
          'branchId': branchId,
          'date': dateStr,
          'entityId': 'schlog_${branchId}_$dateStr',
          'data': logMap,
        });
      }

      debugPrint('[ZkTecoNetworkService] Recorded School Student Attendance in Daily Log for ${credential.entityName}');
    } catch (e) {
      debugPrint('[ZkTecoNetworkService] Error recording School student attendance: $e');
    }
  }

  // ── Device Registration & Heartbeat Management ────────────────────────────

  static void _registerDeviceHeartbeat(String sn, String ip) async {
    try {
      if (isDeviceDeleted(sn) || isDeviceDeleted(ip)) return;

      if (!Hive.isBoxOpen(LocalStorageService.biometricDevicesBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.biometricDevicesBox);
      }
      final box = Hive.box(LocalStorageService.biometricDevicesBox);

      BiometricDeviceConfig? existingDevice;
      String? matchedKey;

      for (var key in box.keys) {
        final val = box.get(key);
        if (val != null) {
          final cfg = BiometricDeviceConfig.fromMap(Map<String, dynamic>.from(val as Map));
          if (isDeviceDeleted(cfg.deviceId) || isDeviceDeleted(cfg.deviceName)) continue;
          if (cfg.serialNumber == sn || cfg.ipAddress == ip) {
            existingDevice = cfg;
            matchedKey = key.toString();
            break;
          }
        }
      }

      if (existingDevice != null &&
          (isDeviceDeleted(existingDevice.deviceId) || isDeviceDeleted(existingDevice.deviceName))) {
        return;
      }

      final now = DateTime.now();
      final deviceKey = matchedKey ?? _uuid.v4();
      if (isDeviceDeleted(deviceKey)) return;

      final updated = (existingDevice ??
              BiometricDeviceConfig(
                deviceId: deviceKey,
                deviceName: 'ZKTeco Device ($sn)',
                buildingLocation: 'Office',
                ipAddress: ip,
                serialNumber: sn,
              ))
          .copyWith(
        status: 'Online',
        lastHeartbeat: now,
        ipAddress: ip,
        serialNumber: sn.isNotEmpty ? sn : existingDevice?.serialNumber,
      );

      await box.put(deviceKey, updated.toMap());
    } catch (e) {
      debugPrint('[ZkTecoNetworkService] Error registering device heartbeat: $e');
    }
  }

  static BiometricDeviceConfig? getDeviceByIpOrSn(String ip, String sn) {
    if (!Hive.isBoxOpen(LocalStorageService.biometricDevicesBox)) return null;
    final box = Hive.box(LocalStorageService.biometricDevicesBox);
    for (var val in box.values) {
      if (val != null) {
        final cfg = BiometricDeviceConfig.fromMap(Map<String, dynamic>.from(val as Map));
        if (isDeviceDeleted(cfg.deviceId) || isDeviceDeleted(cfg.deviceName)) continue;
        if (cfg.ipAddress == ip || (sn.isNotEmpty && cfg.serialNumber == sn)) {
          return cfg;
        }
      }
    }
    return null;
  }

  static List<BiometricDeviceConfig> getAllDevices() {
    if (!Hive.isBoxOpen(LocalStorageService.biometricDevicesBox)) return [];
    final box = Hive.box(LocalStorageService.biometricDevicesBox);
    final now = DateTime.now();
    final List<BiometricDeviceConfig> result = [];
    final keysToPrune = <dynamic>[];

    for (var entry in box.toMap().entries) {
      final key = entry.key;
      final v = entry.value;
      if (v is Map) {
        try {
          final cfg = BiometricDeviceConfig.fromMap(Map<String, dynamic>.from(v));
          if (isDeviceDeleted(cfg.deviceId) || isDeviceDeleted(cfg.deviceName) || isDeviceDeleted(key.toString())) {
            keysToPrune.add(key);
            continue;
          }
          final isRecentlyActive = cfg.lastHeartbeat != null &&
              now.difference(cfg.lastHeartbeat!).inSeconds < 120;
          result.add(cfg.copyWith(status: isRecentlyActive ? 'Online' : 'Offline'));
        } catch (_) {}
      }
    }

    for (final k in keysToPrune) {
      box.delete(k).ignore();
    }

    return result;
  }

  static Future<void> saveDeviceConfig(BiometricDeviceConfig config, {String? oldBranchId}) async {
    if (!Hive.isBoxOpen(LocalStorageService.biometricDevicesBox)) {
      await LocalStorageService.openBoxSafe(LocalStorageService.biometricDevicesBox);
    }
    final box = Hive.box(LocalStorageService.biometricDevicesBox);
    await box.put(config.deviceId, config.toMap());

    // Clear from tombstone if previously deleted
    await removeDeletedDeviceTombstone(config.deviceId);
    if (config.deviceName.isNotEmpty) {
      await removeDeletedDeviceTombstone(config.deviceName);
    }

    // Sync to Cloud Firestore across branches and globally
    try {
      final targetBranch = LocalStorageService.sanitizeBranchId(config.branchId, fallback: 'karachi');
      final data = config.toMap()..['updatedAt'] = FieldValue.serverTimestamp();

      await FirebaseFirestore.instance
          .collection('branches')
          .doc(targetBranch)
          .collection('biometric_devices')
          .doc(config.deviceId)
          .set(data, SetOptions(merge: true))
          .catchError((_) {});

      // If branch changed, delete from old branch so no duplicate resurrects
      if (oldBranchId != null && oldBranchId.isNotEmpty && oldBranchId != targetBranch) {
        FirebaseFirestore.instance
            .collection('branches')
            .doc(oldBranchId)
            .collection('biometric_devices')
            .doc(config.deviceId)
            .delete()
            .catchError((_) {});
      }

      debugPrint('[ZkTecoNetworkService] Saved device config to Firestore branch: $targetBranch/${config.deviceName}');
    } catch (e) {
      debugPrint('[ZkTecoNetworkService] Firestore device save notice: $e');
    }

    // Enqueue for durable cloud sync
    await LocalStorageService.enqueueSync({
      'type': 'save_biometric_device',
      'deviceId': config.deviceId,
      'branchId': config.branchId,
      'data': config.toMap(),
    });

    // Broadcast over LAN so other machines update immediately
    try {
      RealtimeManager().sendMessage(RealtimeEvents.payload(
        type: RealtimeEvents.saveBiometricDevice,
        branchId: config.branchId,
        data: {'deviceId': config.deviceId, 'data': config.toMap()},
      ));
    } catch (_) {}

    SyncService().triggerUpload();
  }

  // ── Deleted Device Tombstone Helpers ───────────────────────────────────────
  static Set<String> _getDeletedDeviceIds() {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final list = box.get('deleted_biometric_device_ids');
        if (list is List) {
          return list.map((e) => e.toString().trim().toLowerCase()).where((e) => e.isNotEmpty).toSet();
        }
      }
    } catch (_) {}
    return <String>{};
  }

  static Future<void> addDeletedDeviceTombstone(String identifier) async {
    try {
      final clean = identifier.trim().toLowerCase();
      if (clean.isEmpty) return;
      final box = await LocalStorageService.ensureBoxOpen('app_settings');
      final set = _getDeletedDeviceIds();
      set.add(clean);
      await box.put('deleted_biometric_device_ids', set.toList());
      await box.flush();
    } catch (_) {}
  }

  static Future<void> removeDeletedDeviceTombstone(String identifier) async {
    try {
      final clean = identifier.trim().toLowerCase();
      if (clean.isEmpty) return;
      final box = await LocalStorageService.ensureBoxOpen('app_settings');
      final set = _getDeletedDeviceIds();
      set.remove(clean);
      await box.put('deleted_biometric_device_ids', set.toList());
      await box.flush();
    } catch (_) {}
  }

  static bool isDeviceDeleted(String? identifier) {
    if (identifier == null) return false;
    final clean = identifier.trim().toLowerCase();
    if (clean.isEmpty) return false;
    return _getDeletedDeviceIds().contains(clean);
  }

  static Future<void> deleteDeviceConfig(String deviceId, {String? branchId, String? deviceName, String? ipAddress}) async {
    final cleanId = deviceId.trim();
    await addDeletedDeviceTombstone(cleanId);
    if (deviceName != null && deviceName.trim().isNotEmpty) {
      await addDeletedDeviceTombstone(deviceName.trim());
    }

    if (Hive.isBoxOpen(LocalStorageService.biometricDevicesBox)) {
      final box = Hive.box(LocalStorageService.biometricDevicesBox);
      final keysToDelete = <dynamic>[];
      for (final key in box.keys) {
        if (key.toString().toLowerCase() == cleanId.toLowerCase()) {
          keysToDelete.add(key);
          continue;
        }
        final val = box.get(key);
        if (val is Map) {
          final dId = (val['deviceId'] ?? '').toString().trim().toLowerCase();
          final dName = (val['deviceName'] ?? '').toString().trim().toLowerCase();
          final dIp = (val['ipAddress'] ?? '').toString().trim().toLowerCase();
          if (dId == cleanId.toLowerCase() ||
              (deviceName != null && dName == deviceName.trim().toLowerCase()) ||
              (ipAddress != null && dIp == ipAddress.trim().toLowerCase())) {
            keysToDelete.add(key);
          }
        }
      }
      for (final k in keysToDelete) {
        await box.delete(k);
      }
      await box.flush();
    }

    try {
      final targetBranch = LocalStorageService.sanitizeBranchId(branchId, fallback: 'karachi');
      final candBranches = <String>{targetBranch, 'karachi', 'saddar', 'haji_camp', 'main'};
      for (final cand in candBranches) {
        FirebaseFirestore.instance
            .collection('branches')
            .doc(cand)
            .collection('biometric_devices')
            .doc(cleanId)
            .delete()
            .catchError((_) {});
      }
      FirebaseFirestore.instance
          .collection('biometric_devices')
          .doc(cleanId)
          .delete()
          .catchError((_) {});

      // Delete any matching docs via collectionGroup
      FirebaseFirestore.instance
          .collectionGroup('biometric_devices')
          .get()
          .then((snap) {
            for (final doc in snap.docs) {
              final d = doc.data();
              final dId = (d['deviceId'] ?? doc.id).toString();
              final dName = (d['deviceName'] ?? '').toString();
              if (doc.id == cleanId || dId == cleanId ||
                  (deviceName != null && dName.toLowerCase() == deviceName.trim().toLowerCase())) {
                doc.reference.delete().ignore();
              }
            }
          })
          .catchError((_) {});

      debugPrint('[ZkTecoNetworkService] Deleted device config across candidate branches: $cleanId');
    } catch (e) {
      debugPrint('[ZkTecoNetworkService] Firestore device delete notice: $e');
    }

    // Enqueue for durable cloud sync
    await LocalStorageService.enqueueSync({
      'type': 'delete_biometric_device',
      'deviceId': cleanId,
      'branchId': branchId ?? 'karachi',
    });

    // Broadcast over LAN so other machines remove it immediately
    try {
      RealtimeManager().sendMessage(RealtimeEvents.payload(
        type: RealtimeEvents.deleteBiometricDevice,
        branchId: branchId ?? 'karachi',
        data: {'deviceId': cleanId},
      ));
    } catch (_) {}

    SyncService().triggerUpload();
  }

  /// Syncs all biometric devices from Cloud Firestore down to local Hive
  static Future<void> syncBiometricDevicesFromFirestore({String? branchId}) async {
    try {
      if (!Hive.isBoxOpen(LocalStorageService.biometricDevicesBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.biometricDevicesBox);
      }
      final box = Hive.box(LocalStorageService.biometricDevicesBox);

      final query = (branchId != null && branchId.isNotEmpty && branchId != 'all')
          ? FirebaseFirestore.instance.collection('branches').doc(branchId.toLowerCase().trim()).collection('biometric_devices')
          : FirebaseFirestore.instance.collectionGroup('biometric_devices');

      final snap = await query.get(const GetOptions(source: Source.serverAndCache));
      for (final doc in snap.docs) {
        final docId = doc.id;
        final data = doc.data();
        final devId = (data['deviceId'] ?? docId).toString();
        final devName = (data['deviceName'] ?? '').toString();
        if (isDeviceDeleted(docId) || isDeviceDeleted(devId) || isDeviceDeleted(devName)) {
          doc.reference.delete().ignore();
          box.delete(docId).ignore();
          box.delete(devId).ignore();
          continue;
        }
        final cfg = BiometricDeviceConfig.fromMap(Map<String, dynamic>.from(data));
        await box.put(devId, cfg.toMap());
      }
      debugPrint('[ZkTecoNetworkService] Synced ${snap.docs.length} biometric devices from Firestore');
    } catch (e) {
      debugPrint('[ZkTecoNetworkService] Error syncing biometric devices from Firestore: $e');
    }
  }

  /// Sync biometric devices from Firestore once on demand without realtime stream.
  static void listenToBiometricDevicesFromFirestore({String? branchId}) {
    _remoteDevicesSub?.cancel();
    _remoteDevicesSub = null;
    final normalized = (branchId ?? '').trim().toLowerCase();
    if (normalized.isNotEmpty && normalized != 'all' && normalized != 'global') {
      syncBiometricDevicesFromFirestore(branchId: normalized);
    }
  }

  /// Pings a ZKTeco device over LAN and waits for genuine network socket response
  static Future<bool> pingDevice(String ipAddress, {int port = 4370}) async {
    if (kIsWeb) return false;
    final effectivePort = (port == 8088 || port <= 0) ? 4370 : port;
    debugPrint('[ZkTecoNetworkService] Pinging device at $ipAddress:$effectivePort...');

    // 1. Try TCP handshake (ADMS Web Push 8088 / ZKTeco TCP 4370)
    try {
      final socket = await Socket.connect(ipAddress, effectivePort, timeout: const Duration(seconds: 2));
      socket.destroy();
      debugPrint('[ZkTecoNetworkService] TCP ping successful for $ipAddress:$effectivePort');
      await _updateDeviceOnlineStatus(ipAddress);
      return true;
    } catch (e) {
      debugPrint('[ZkTecoNetworkService] TCP connection to $ipAddress:$effectivePort failed: $e. Falling back to ZK UDP protocol handshake...');
    }

    // 2. Try ZKTeco UDP Datagram handshake with strict response wait
    try {
      final udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      
      // Send proper ZKTeco CMD_CONNECT packet with checksum
      final command = _buildZkPacket(command: 0x03E8, sessionId: 0, replyId: 0);

      udp.send(command, InternetAddress(ipAddress), effectivePort);

      Completer<bool> completer = Completer<bool>();
      Timer timer = Timer(const Duration(seconds: 2), () {
        if (!completer.isCompleted) {
          debugPrint('[ZkTecoNetworkService] UDP connect handshake timed out (2s) for $ipAddress:$effectivePort');
          udp.close();
          completer.complete(false);
        }
      });

      udp.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = udp.receive();
          if (dg != null && dg.data.isNotEmpty) {
            timer.cancel();
            udp.close();
            if (!completer.isCompleted) {
              debugPrint('[ZkTecoNetworkService] ZK UDP protocol handshake acknowledged by $ipAddress:$effectivePort');
              completer.complete(true);
            }
          }
        }
      }, onError: (e) {
        debugPrint('[ZkTecoNetworkService] UDP Socket error for $ipAddress:$effectivePort: $e');
      });

      final result = await completer.future;
      if (result) {
        await _updateDeviceOnlineStatus(ipAddress);
        return true;
      }
    } catch (e) {
      debugPrint('[ZkTecoNetworkService] Socket exception during UDP ping to $ipAddress:$effectivePort: $e');
    }

    // 3. Fallback to native OS ICMP Ping (checks if hardware is active on LAN)
    if (!kIsWeb && Platform.isWindows) {
      try {
        final pingResult = await Process.run('ping', ['-n', '1', '-w', '1200', ipAddress]);
        final out = pingResult.stdout.toString();
        if (pingResult.exitCode == 0 && (out.contains('Reply from') || out.contains('TTL=')) && !out.contains('Destination host unreachable')) {
          debugPrint('[ZkTecoNetworkService] ICMP Ping successful for $ipAddress (device is reachable on LAN)');
          await _updateDeviceOnlineStatus(ipAddress);
          return true;
        }
      } catch (e) {
        debugPrint('[ZkTecoNetworkService] ICMP Ping error for $ipAddress: $e');
      }
    }

    await _markDeviceOffline(ipAddress);
    return false;
  }

  static Future<void> _updateDeviceOnlineStatus(String ipAddress) async {
    final devices = getAllDevices();
    for (final dev in devices) {
      if (dev.ipAddress == ipAddress) {
        final updated = dev.copyWith(
          lastHeartbeat: DateTime.now(),
          status: 'Online',
        );
        await saveDeviceConfig(updated);
      }
    }
  }

  static Future<void> _markDeviceOffline(String ipAddress) async {
    final devices = getAllDevices();
    for (final dev in devices) {
      if (dev.ipAddress == ipAddress) {
        // If the device had a heartbeat via ADMS push in the last 90 seconds, do not override it to Offline.
        if (dev.lastHeartbeat != null &&
            DateTime.now().difference(dev.lastHeartbeat!).inSeconds < 90) {
          debugPrint('[ZkTecoNetworkService] Retaining ONLINE status for $ipAddress (ADMS push is active)');
          continue;
        }
        final updated = dev.copyWith(
          status: 'Offline',
        );
        await saveDeviceConfig(updated);
      }
    }
  }

  // ── Firestore Snapshot Listener ─────────────────────────────────────────────

  /// Fetches historical and recent biometric punches from Cloud Firestore (e.g. pushed by python daemon or other scanners)
  /// and processes them into local attendance records.
  static Future<int> syncBiometricPunchesFromFirestore({int daysBack = 30, DateTime? specificDate}) async {
    if (kIsWeb) return 0;
    try {
      debugPrint('[ZkTecoNetworkService] Fetching biometric punches from Cloud Firestore...');
      Query<Map<String, dynamic>> query = FirebaseFirestore.instance.collection('biometric_punches');

      if (specificDate != null) {
        final startOfDay = DateTime(specificDate.year, specificDate.month, specificDate.day).toIso8601String();
        final endOfDay = DateTime(specificDate.year, specificDate.month, specificDate.day, 23, 59, 59).toIso8601String();
        query = query
            .where('timestamp', isGreaterThanOrEqualTo: startOfDay)
            .where('timestamp', isLessThanOrEqualTo: endOfDay);
      } else {
        final cutoff = DateTime.now().subtract(Duration(days: daysBack)).toIso8601String();
        query = query.where('timestamp', isGreaterThanOrEqualTo: cutoff);
      }

      final snap = await query.limit(2000).get();
      debugPrint('[ZkTecoNetworkService] Found ${snap.docs.length} punches in Cloud Firestore');

      int processedCount = 0;
      // Sort chronologically ascending so check-in and check-out occur in order
      final docs = snap.docs.toList()
        ..sort((a, b) {
          final tA = a.data()['timestamp']?.toString() ?? '';
          final tB = b.data()['timestamp']?.toString() ?? '';
          return tA.compareTo(tB);
        });

      for (final doc in docs) {
        final data = doc.data();
        final pin = (data['pin'] ?? data['userId'] ?? data['biometricPin'])?.toString() ?? '';
        final timeStr = data['timestamp']?.toString() ?? '';
        final deviceIp = data['deviceIp']?.toString() ?? '192.168.1.100';
        final deviceSn = data['deviceSn']?.toString() ?? '';
        final source = data['source']?.toString() ?? 'firestore_sync';

        if (pin.isNotEmpty && timeStr.isNotEmpty) {
          final timestamp = DateTime.tryParse(timeStr) ?? DateTime.now();
          final dedupKey = '${deviceIp}_${pin}_$timeStr';
          if (!isPunchDuplicate(dedupKey)) {
            recordPunchDedupKey(dedupKey);
            await processIncomingPunch(
              pin: pin,
              timestamp: timestamp,
              deviceIp: deviceIp,
              deviceSn: deviceSn,
              source: source,
              enqueueForSync: false,
              broadcastLan: false,
            );
            processedCount++;
          }
        }
      }

      debugPrint('[ZkTecoNetworkService] Successfully processed $processedCount new biometric punches from Firestore');
      return processedCount;
    } catch (e) {
      debugPrint('[ZkTecoNetworkService] Error syncing biometric punches from Firestore: $e');
      return 0;
    }
  }

  /// One-time sync of Cloud Firestore biometric punches (zero continuous Firestore snapshots).
  static void listenToFirestorePunches() {
    _firestorePunchesSub?.cancel();
    try {
      // Historical one-time backfill for recent days without holding open snapshots
      syncBiometricPunchesFromFirestore(daysBack: 7);
    } catch (e) {
      debugPrint('[ZkTecoNetworkService] Firestore sync notice: $e');
    }
  }

  /// Synchronizes today's biometric punches, unmapped scans, and employee attendance from Cloud Firestore.
  /// Allows client machines, web dashboards, and dev PCs to immediately display server-collected punches.
  static Future<Map<String, dynamic>> syncTodayPunchesFromFirestore({String? branchId}) async {
    try {
      final now = DateTime.now();
      final todayStr = DateFormat('yyyy-MM-dd').format(now);
      final startOfDay = '${todayStr}T00:00:00';
      final endOfDay = '${todayStr}T23:59:59';

      debugPrint('[ZkTecoNetworkService] Syncing today\'s ($todayStr) punches and attendance from Firestore...');

      // 1. Download attendance records for today from all branches
      final branchList = <String>[];
      if (branchId != null && branchId.isNotEmpty && branchId != 'all' && branchId != 'global') {
        branchList.add(branchId.toLowerCase().trim());
      } else {
        try {
          final allBranches = FinanceLocalStorage.getAllBranches([]);
          for (final b in allBranches) {
            final id = b['id']?.toString().toLowerCase().trim();
            if (id != null && id.isNotEmpty && !branchList.contains(id)) {
              branchList.add(id);
            }
          }
        } catch (_) {}
      }
      if (!branchList.contains('karachi')) branchList.add('karachi');
      if (!branchList.contains('gujrat')) branchList.add('gujrat');
      if (!branchList.contains('main')) branchList.add('main');

      for (final b in branchList) {
        try {
          await FinanceLocalStorage.downloadAttendance(b, force: true, specificDateStr: todayStr);
        } catch (be) {
          debugPrint('[ZkTecoNetworkService] Branch $b attendance sync note: $be');
        }
      }

      // 2. Query root biometric_punches for today
      try {
        final snap = await FirebaseFirestore.instance
            .collection('biometric_punches')
            .where('timestamp', isGreaterThanOrEqualTo: startOfDay)
            .where('timestamp', isLessThanOrEqualTo: endOfDay)
            .get();

        for (final doc in snap.docs) {
          final data = doc.data();
          final pin = (data['pin'] ?? data['userId'] ?? data['biometricPin'])?.toString() ?? '';
          final timeStr = data['timestamp']?.toString() ?? '';
          final deviceIp = data['deviceIp']?.toString() ?? '192.168.1.100';
          final deviceSn = data['deviceSn']?.toString() ?? '';
          final source = data['source']?.toString() ?? 'firestore_sync';

          if (pin.isNotEmpty && timeStr.isNotEmpty) {
            final timestamp = DateTime.tryParse(timeStr) ?? now;
            final dedupKey = '${deviceIp}_${pin}_$timeStr';
            if (!isPunchDuplicate(dedupKey)) {
              recordPunchDedupKey(dedupKey);
              await processIncomingPunch(
                pin: pin,
                timestamp: timestamp,
                deviceIp: deviceIp,
                deviceSn: deviceSn,
                source: source,
              );
            }
          }
        }
      } catch (pe) {
        debugPrint('[ZkTecoNetworkService] Root biometric_punches query note: $pe');
      }

      // 3. Update today's punch diagnostic counters
      final diag = getTodayPunchDiagnostics(branchId);
      totalPunchesReceivedNotifier.value = diag['total'] ?? 0;

      debugPrint('[ZkTecoNetworkService] Firestore sync complete for today: $diag');
      return diag;
    } catch (e) {
      debugPrint('[ZkTecoNetworkService] Error in syncTodayPunchesFromFirestore: $e');
      return getTodayPunchDiagnostics(branchId);
    }
  }

  // ── Active ZKTeco Device Polling & Keep-Alive (Pull-Based) ─────────────────────────────

  /// Starts a periodic timer that actively connects to each online ZKTeco device
  /// and pulls new attendance log records using the ZK UDP protocol.
  static void _startActivePolling() {
    _activePollingTimer?.cancel();
    // Poll every 15 seconds
    _activePollingTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      syncAllDevices();
    });
    // Also do an immediate first poll
    syncAllDevices();
  }

  /// Manually or periodically triggers UDP hardware polling across all configured devices
  static Future<void> syncAllDevices() async {
    if (kIsWeb) return;
    final devices = getAllDevices();
    for (final device in devices) {
      if (device.ipAddress.isNotEmpty) {
        // [FIX-1.4] Skip Dart polling if polling ownership is assigned to external Python daemon
        if (device.pollingOwner == 'python') {
          debugPrint('[ZkTecoNetworkService] Active UDP polling skipped for ${device.ipAddress} (pollingOwner is python)');
          continue;
        }
        if (!isDartPollingEnabledForDevice(device.ipAddress)) {
          debugPrint('[ZkTecoNetworkService] Active UDP hardware polling disabled for ${device.ipAddress} (pilot site)');
          continue;
        }
        try {
          // Automatic Keep-Alive Ping: Keeps status Online continuously without manual checking!
          final isReachable = await pingDevice(device.ipAddress, port: device.port);
          if (isReachable) {
            await _pullAttendanceLogsFromDevice(device);
          }
        } catch (e) {
          debugPrint('[ZkTecoNetworkService] Poll error for ${device.ipAddress}: $e');
        }
      }
    }
  }

  /// Connects to a ZKTeco device via UDP and requests attendance logs.
  /// ZK Protocol flow: CMD_CONNECT → get session → CMD_ATTLOG_RRQ → read log data → CMD_FREE_DATA → CMD_EXIT
  static Future<void> _pullAttendanceLogsFromDevice(BiometricDeviceConfig device) async {
    final ip = device.ipAddress;
    final port = (device.port == 8088 || device.port <= 0) ? 4370 : device.port;
    _ZkUdpSession? session;

    try {
      session = await _ZkUdpSession.create();

      // ── Step 1: CMD_CONNECT (0x03E8) ──
      final connectPacket = _buildZkPacket(command: 0x03E8, sessionId: 0, replyId: 0);
      session.send(connectPacket, ip, port);

      final connectReply = await session.waitForReply(timeout: const Duration(seconds: 3));
      if (connectReply == null || connectReply.length < 8) {
        session.close();
        return; // Device didn't respond
      }

      // Parse session ID from connect reply (bytes 4-5, little-endian)
      final replyCommand = connectReply[0] | (connectReply[1] << 8);
      if (replyCommand != 0x07D0) {
        // 0x07D0 = CMD_ACK_OK
        debugPrint('[ZkTecoNetworkService] CMD_CONNECT rejected by $ip (reply: 0x${replyCommand.toRadixString(16)})');
        session.close();
        return;
      }

      final sessionId = connectReply[4] | (connectReply[5] << 8);
      int replyId = 1;

      // Update device online status
      await _updateDeviceOnlineStatus(ip);

      // ── Step 2: CMD_DISABLEDEVICE (0x003C) – prevent concurrent operations ──
      final disablePacket = _buildZkPacket(command: 0x003C, sessionId: sessionId, replyId: replyId++);
      session.send(disablePacket, ip, port);
      await session.waitForReply(timeout: const Duration(seconds: 2)); // ACK

      // ── Step 3: CMD_ATTLOG_RRQ (0x000D) – request attendance log records ──
      final attlogPacket = _buildZkPacket(command: 0x000D, sessionId: sessionId, replyId: replyId++);
      session.send(attlogPacket, ip, port);

      // Collect all data chunks (device may send multiple packets)
      final allData = BytesBuilder();
      bool receivedPrepare = false;

      // Wait for CMD_PREPARE_DATA (0x05DC) or CMD_DATA (0x05DD) or direct ACK
      while (true) {
        final chunk = await session.waitForReply(timeout: const Duration(seconds: 3));
        if (chunk == null) break;

        final cmd = chunk[0] | (chunk[1] << 8);

        if (cmd == 0x05DC) {
          // CMD_PREPARE_DATA – device is preparing to send data
          receivedPrepare = true;
          continue;
        } else if (cmd == 0x05DD) {
          // CMD_DATA – actual attendance data chunk
          if (chunk.length > 8) {
            allData.add(chunk.sublist(8));
          }
          continue;
        } else if (cmd == 0x07D0) {
          // CMD_ACK_OK – done sending
          break;
        } else {
          break;
        }
      }

      // ── Step 4: CMD_FREE_DATA (0x000C) – acknowledge receipt ──
      final freeDataPacket = _buildZkPacket(command: 0x000C, sessionId: sessionId, replyId: replyId++);
      session.send(freeDataPacket, ip, port);
      await session.waitForReply(timeout: const Duration(seconds: 1));

      // ── Step 5: CMD_ENABLEDEVICE (0x003D) – re-enable the device ──
      final enablePacket = _buildZkPacket(command: 0x003D, sessionId: sessionId, replyId: replyId++);
      session.send(enablePacket, ip, port);
      await session.waitForReply(timeout: const Duration(seconds: 1));

      // ── Step 6: CMD_EXIT (0x03E9) – disconnect session ──
      final exitPacket = _buildZkPacket(command: 0x03E9, sessionId: sessionId, replyId: replyId++);
      session.send(exitPacket, ip, port);

      session.close();
      session = null;

      // ── Parse attendance records ──
      if (allData.length > 0) {
        _parseZkAttendanceData(allData.toBytes(), ip, device.serialNumber);
      } else if (!receivedPrepare) {
        debugPrint('[ZkTecoNetworkService] No attendance data from $ip (may be empty or unsupported)');
      }
    } catch (e) {
      debugPrint('[ZkTecoNetworkService] Error polling device at $ip: $e');
    } finally {
      session?.close();
    }
  }

  /// Scans all local attendance records and pushes them directly to Cloud Firestore.
  static Future<int> syncAllRecordedAttendanceToFirestore() async {
    int syncedCount = 0;
    try {
      if (!Hive.isBoxOpen(LocalStorageService.attendanceBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.attendanceBox);
      }
      final box = Hive.box(LocalStorageService.attendanceBox);
      final db = FirebaseFirestore.instance;

      for (final key in box.keys) {
        final val = box.get(key);
        if (val is! Map) continue;
        final record = Map<String, dynamic>.from(val);

        final employeeId = (record['employeeId'] ?? record['id'] ?? '').toString().trim();
        final dateStr = (record['date'] ?? '').toString().trim();
        final branchId = (record['branchId'] ?? '').toString().trim().toLowerCase();
        final effectiveBranch = (branchId.isNotEmpty && branchId != 'all' && branchId != 'main')
            ? branchId
            : 'karachi';

        if (employeeId.isEmpty || dateStr.isEmpty) continue;
        if (record['synced'] == true && record['syncStatus'] == 'synced') continue;

        try {
          final fsData = Map<String, dynamic>.from(record)
            ..remove('syncStatus')
            ..['synced'] = true;

          await db
              .collection('branches')
              .doc(effectiveBranch)
              .collection('employee_attendance')
              .doc(dateStr)
              .set({'date': dateStr, 'branchId': effectiveBranch, 'lastUpdated': FieldValue.serverTimestamp()}, SetOptions(merge: true));

          await db
              .collection('branches')
              .doc(effectiveBranch)
              .collection('employee_attendance')
              .doc(dateStr)
              .collection('records')
              .doc(employeeId)
              .set(fsData, SetOptions(merge: true));

          record['synced'] = true;
          record['syncStatus'] = 'synced';
          await box.put(key, record);
          syncedCount++;
        } catch (e) {
          debugPrint('[ZkTecoNetworkService] Error pushing attendance record $key: $e');
        }
      }
      if (syncedCount > 0) {
        await box.flush();
        debugPrint('[ZkTecoNetworkService] Synced $syncedCount attendance records to Cloud Firestore.');
      }
    } catch (e) {
      debugPrint('[ZkTecoNetworkService] syncAllRecordedAttendanceToFirestore error: $e');
    }
    return syncedCount;
  }

  /// Builds a minimal ZKTeco UDP packet.
  /// ZK Protocol header: [0x50, 0x50, 0x82, 0x7D, CMD_LO, CMD_HI, 0x00, 0x00, SESSION_LO, SESSION_HI, REPLY_LO, REPLY_HI]
  static Uint8List _buildZkPacket({required int command, required int sessionId, required int replyId, List<int>? data}) {
    final dataBytes = data ?? [];

    final buf = ByteData(8 + dataBytes.length);

    // Command (2 bytes LE)
    buf.setUint16(0, command, Endian.little);
    // Checksum placeholder (2 bytes) – will be filled
    buf.setUint16(2, 0, Endian.little);
    // Session ID (2 bytes LE)
    buf.setUint16(4, sessionId, Endian.little);
    // Reply ID (2 bytes LE)
    buf.setUint16(6, replyId, Endian.little);

    // Data payload
    for (int i = 0; i < dataBytes.length; i++) {
      buf.setUint8(8 + i, dataBytes[i]);
    }

    final bytes = Uint8List.view(buf.buffer);

    // Calculate checksum over entire packet body
    int chksum = 0;
    for (int i = 0; i < bytes.length; i += 2) {
      if (i == 2) continue; // skip checksum field
      int word = bytes[i];
      if (i + 1 < bytes.length) word |= bytes[i + 1] << 8;
      chksum += word;
    }
    chksum = (chksum ^ 0xFFFF) + 1;
    chksum &= 0xFFFF;
    bytes[2] = chksum & 0xFF;
    bytes[3] = (chksum >> 8) & 0xFF;

    // Wrap with ZK transport header: magic (0x5050827D) + length
    final fullPacket = Uint8List(4 + bytes.length);
    fullPacket[0] = 0x50;
    fullPacket[1] = 0x50;
    fullPacket[2] = 0x82;
    fullPacket[3] = 0x7D;
    fullPacket.setRange(4, fullPacket.length, bytes);

    return fullPacket;
  }

  /// Parses binary ZKTeco attendance log data.
  /// Each record is typically 40 bytes (newer firmware), 24 bytes (legacy firmware), or variable-length text.
  static void _parseZkAttendanceData(Uint8List data, String deviceIp, String deviceSn) {
    if (data.isEmpty) return;

    // 1. Try text-based parsing first (some firmware returns tab/comma separated text)
    final textData = utf8.decode(data, allowMalformed: true);

    if (textData.contains('\t') || textData.contains('\n') || textData.contains(',')) {
      final lines = textData.split(RegExp(r'[\r\n]+'));
      for (var line in lines) {
        line = line.trim();
        if (line.isEmpty || line.startsWith('table=') || line.startsWith('ATTLOG')) continue;

        final parts = line.split(RegExp(r'[\t,]+'));
        if (parts.length >= 2) {
          final rawPin = parts[0].trim();
          final cleanPin = rawPin.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '').trim();
          final timeStr = parts[1].trim();
          final timestamp = DateTime.tryParse(timeStr) ?? DateTime.now();

          if (cleanPin.isNotEmpty && !cleanPin.startsWith('PP')) {
            final dedupKey = '${deviceIp}_${cleanPin}_$timeStr';
            if (!isPunchDuplicate(dedupKey)) {
              recordPunchDedupKey(dedupKey);
              processIncomingPunch(
                pin: cleanPin,
                timestamp: timestamp,
                deviceIp: deviceIp,
                deviceSn: deviceSn,
                source: 'zkteco_pull',
              );
            }
          }
        }
      }
      return;
    }

    // 2. Binary-format parsing (40-byte fixed-length records)
    const recordSize40 = 40;
    if (data.length >= recordSize40) {
      final recordCount = data.length ~/ recordSize40;
      debugPrint('[ZkTecoNetworkService] Parsing $recordCount binary attendance records (40-byte) from $deviceIp');

      for (int i = 0; i < recordCount; i++) {
        final offset = i * recordSize40;
        try {
          // Bytes 0-23: User ID string (null-terminated)
          final userIdBytes = data.sublist(offset, offset + 24);
          final nullIdx = userIdBytes.indexOf(0);
          final rawPin = utf8.decode(userIdBytes.sublist(0, nullIdx > 0 ? nullIdx : 24), allowMalformed: true).trim();
          final cleanPin = rawPin.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '').trim();

          // Bytes 24-27: Timestamp (encoded as seconds since 2000-01-01)
          if (offset + 27 < data.length) {
            final timeEncoded = data[offset + 24] |
                (data[offset + 25] << 8) |
                (data[offset + 26] << 16) |
                (data[offset + 27] << 24);

            final timestamp = _decodeZkTime(timeEncoded);

            if (cleanPin.isNotEmpty && !cleanPin.startsWith('PP')) {
              final dedupKey = '${deviceIp}_${cleanPin}_${timestamp.toIso8601String()}';
              if (!isPunchDuplicate(dedupKey)) {
                recordPunchDedupKey(dedupKey);
                processIncomingPunch(
                  pin: cleanPin,
                  timestamp: timestamp,
                  deviceIp: deviceIp,
                  deviceSn: deviceSn,
                  source: 'zkteco_pull',
                );
              }
            }
          }
        } catch (e) {
          debugPrint('[ZkTecoNetworkService] Error parsing 40-byte record $i: $e');
        }
      }
      return;
    }

    // 3. Legacy 24-byte fixed-length records (bytes 0-1: 16-bit integer PIN, bytes 2-5: timestamp)
    const recordSize24 = 24;
    if (data.length >= recordSize24) {
      final recordCount = data.length ~/ recordSize24;
      debugPrint('[ZkTecoNetworkService] Parsing $recordCount binary attendance records (24-byte) from $deviceIp');

      for (int i = 0; i < recordCount; i++) {
        final offset = i * recordSize24;
        try {
          final pinNum = data[offset] | (data[offset + 1] << 8);
          final timeEncoded = data[offset + 2] |
              (data[offset + 3] << 8) |
              (data[offset + 4] << 16) |
              (data[offset + 5] << 24);

          final timestamp = _decodeZkTime(timeEncoded);
          final cleanPin = pinNum > 0 && pinNum < 65535 ? pinNum.toString() : '';

          if (cleanPin.isNotEmpty && !cleanPin.startsWith('PP')) {
            final dedupKey = '${deviceIp}_${cleanPin}_${timestamp.toIso8601String()}';
            if (!isPunchDuplicate(dedupKey)) {
              recordPunchDedupKey(dedupKey);
              processIncomingPunch(
                pin: cleanPin,
                timestamp: timestamp,
                deviceIp: deviceIp,
                deviceSn: deviceSn,
                source: 'zkteco_pull',
              );
            }
          }
        } catch (e) {
          debugPrint('[ZkTecoNetworkService] Error parsing 24-byte record $i: $e');
        }
      }
      return;
    }

    // 4. Compact Realtime UDP Event Payload (8-23 bytes)
    if (data.length >= 8 && data.length < 24) {
      try {
        int pinNum = data[0] | (data[1] << 8);
        int timeOffset = 2;
        if (pinNum == 1 || pinNum == 0) {
          pinNum = data[2] | (data[3] << 8);
          timeOffset = 4;
        }

        DateTime timestamp = DateTime.now();
        if (data.length >= timeOffset + 4) {
          final timeEncoded = data[timeOffset] |
              (data[timeOffset + 1] << 8) |
              (data[timeOffset + 2] << 16) |
              (data[timeOffset + 3] << 24);
          if (timeEncoded > 0 && timeEncoded < 0x7FFFFFFF) {
            final decoded = _decodeZkTime(timeEncoded);
            if (decoded.year >= 2020 && decoded.year <= 2035) {
              timestamp = decoded;
            }
          }
        }

        final cleanPin = (pinNum > 0 && pinNum < 65535) ? pinNum.toString() : '';
        if (cleanPin.isNotEmpty && !cleanPin.startsWith('PP')) {
          final dedupKey = '${deviceIp}_${cleanPin}_${timestamp.toIso8601String()}';
          if (!isPunchDuplicate(dedupKey)) {
            recordPunchDedupKey(dedupKey);
            processIncomingPunch(
              pin: cleanPin,
              timestamp: timestamp,
              deviceIp: deviceIp,
              deviceSn: deviceSn,
              source: 'zkteco_udp_realtime',
            );
            return;
          }
        }
      } catch (e) {
        debugPrint('[ZkTecoNetworkService] Error parsing compact realtime event: $e');
      }
    }

    // 5. Fallback for single realtime plaintext event payload (explicit ASCII PIN)
    if (data.length >= 2) {
      final raw = utf8.decode(data, allowMalformed: true).trim();
      // Ensure the payload looks like a genuine text event (e.g. "PIN=101" or pure numeric string) rather than random binary control bytes
      if (raw.isNotEmpty && RegExp(r'^(PIN=\d+|\d{1,10})$').hasMatch(raw)) {
        final cleanPin = raw.replaceAll(RegExp(r'[^0-9]'), '').trim();
        if (!cleanPin.startsWith('PP') && cleanPin.isNotEmpty) {
          processIncomingPunch(
            pin: cleanPin,
            timestamp: DateTime.now(),
            deviceIp: deviceIp,
            deviceSn: deviceSn,
            source: 'zkteco_hardware',
          );
        }
      }
    }
  }

  /// Decodes ZKTeco encoded timestamp (seconds since 2000-01-01 00:00:00)
  static DateTime _decodeZkTime(int encoded) {
    final second = encoded % 60;
    encoded ~/= 60;
    final minute = encoded % 60;
    encoded ~/= 60;
    final hour = encoded % 24;
    encoded ~/= 24;
    final day = (encoded % 31) + 1;
    encoded ~/= 31;
    final month = (encoded % 12) + 1;
    encoded ~/= 12;
    final year = encoded + 2000;
    return DateTime(year, month, day, hour, minute, second);
  }

  // ── Credential & PIN Registry Management ────────────────────────────────────

  static BiometricCredential? getCredentialByPin(String pin) {
    final cleanPin = pin.trim();
    if (cleanPin.isEmpty) return null;

    // 1. Check biometricCredentialsBox
    if (Hive.isBoxOpen(LocalStorageService.biometricCredentialsBox)) {
      final box = Hive.box(LocalStorageService.biometricCredentialsBox);
      for (var val in box.values) {
        if (val is Map) {
          try {
            final cred = BiometricCredential.fromMap(val);
            final credPin = cred.biometricPin.trim();
            final isMatch = credPin == cleanPin || (int.tryParse(credPin) != null && int.tryParse(credPin) == int.tryParse(cleanPin));
            final isHistoryMatch = cred.pinHistory.any((hp) => hp.trim() == cleanPin || (int.tryParse(hp.trim()) != null && int.tryParse(hp.trim()) == int.tryParse(cleanPin)));

            if (cred.active && (isMatch || isHistoryMatch)) {
              return cred;
            }
          } catch (_) {}
        }
      }
    }

    // 2. Check employeesBox directly
    if (Hive.isBoxOpen(LocalStorageService.employeesBox)) {
      final box = Hive.box(LocalStorageService.employeesBox);
      for (var key in box.keys) {
        final raw = box.get(key);
        if (raw is Map) {
          final map = Map<String, dynamic>.from(raw);
          final empId = (map['localId'] ?? map['id'] ?? key).toString();
          final empPin = (map['biometricPin'] ?? map['pin'] ?? '').toString().trim();
          final empName = map['name']?.toString() ?? 'Employee';
          final branchId = map['branchId']?.toString() ?? '';

          if (empPin.isNotEmpty && (empPin == cleanPin || (int.tryParse(empPin) != null && int.tryParse(empPin) == int.tryParse(cleanPin)))) {
            final cred = BiometricCredential(
              id: empId,
              biometricPin: cleanPin,
              entityId: empId,
              entityName: empName,
              entityType: 'employee',
              branchId: branchId,
              enrolledAt: DateTime.now(),
            );
            registerBiometricCredential(cred);
            return cred;
          }
          // Also match if empId itself matches the PIN (e.g. employee ID "1" or "1111")
          if (empId == cleanPin || (int.tryParse(empId) != null && int.tryParse(empId) == int.tryParse(cleanPin))) {
            final cred = BiometricCredential(
              id: empId,
              biometricPin: cleanPin,
              entityId: empId,
              entityName: empName,
              entityType: 'employee',
              branchId: branchId,
              enrolledAt: DateTime.now(),
            );
            registerBiometricCredential(cred);
            return cred;
          }
        }
      }
    }

    // 3. Check schoolStudentsBox
    if (Hive.isBoxOpen(LocalStorageService.schoolStudentsBox)) {
      final box = Hive.box(LocalStorageService.schoolStudentsBox);
      for (var key in box.keys) {
        final raw = box.get(key);
        if (raw is Map) {
          final map = Map<String, dynamic>.from(raw);
          final stId = (map['id'] ?? key).toString();
          final stPin = (map['biometricPin'] ?? map['pin'] ?? '').toString().trim();
          final stName = map['name']?.toString() ?? 'School Student';
          final branchId = map['branchId']?.toString() ?? '';

          if ((stPin.isNotEmpty && (stPin == cleanPin || int.tryParse(stPin) == int.tryParse(cleanPin))) ||
              (stId == cleanPin || (int.tryParse(stId) != null && int.tryParse(stId) == int.tryParse(cleanPin)))) {
            final cred = BiometricCredential(
              id: stId,
              biometricPin: cleanPin,
              entityId: stId,
              entityName: stName,
              entityType: 'school_student',
              branchId: branchId,
              enrolledAt: DateTime.now(),
            );
            registerBiometricCredential(cred);
            return cred;
          }
        }
      }
    }

    // 4. Check madrassaStudentsBox
    if (Hive.isBoxOpen(LocalStorageService.madrassaStudentsBox)) {
      final box = Hive.box(LocalStorageService.madrassaStudentsBox);
      for (var key in box.keys) {
        final raw = box.get(key);
        if (raw is Map) {
          final map = Map<String, dynamic>.from(raw);
          final stId = (map['id'] ?? key).toString();
          final stPin = (map['biometricPin'] ?? map['pin'] ?? '').toString().trim();
          final stName = map['name']?.toString() ?? 'Madrassa Student';
          final branchId = map['branchId']?.toString() ?? '';

          if ((stPin.isNotEmpty && (stPin == cleanPin || int.tryParse(stPin) == int.tryParse(cleanPin))) ||
              (stId == cleanPin || (int.tryParse(stId) != null && int.tryParse(stId) == int.tryParse(cleanPin)))) {
            final cred = BiometricCredential(
              id: stId,
              biometricPin: cleanPin,
              entityId: stId,
              entityName: stName,
              entityType: 'madrassa_student',
              branchId: branchId,
              enrolledAt: DateTime.now(),
            );
            registerBiometricCredential(cred);
            return cred;
          }
        }
      }
    }

    // 5. Check usersBox directly (fallback for user accounts: doctor, dispenser, admin, etc.)
    if (Hive.isBoxOpen(LocalStorageService.usersBox)) {
      final box = Hive.box(LocalStorageService.usersBox);
      for (var key in box.keys) {
        final raw = box.get(key);
        if (raw is Map) {
          final map = Map<String, dynamic>.from(raw);
          final uId = (map['userId'] ?? map['id'] ?? key).toString();
          final uPin = (map['biometricPin'] ?? map['pin'] ?? '').toString().trim();
          final uName = map['name']?.toString() ?? map['username']?.toString() ?? 'Staff';
          final branchId = map['branchId']?.toString() ?? '';
          final role = map['role']?.toString() ?? 'Staff';

          if ((uPin.isNotEmpty && (uPin == cleanPin || (int.tryParse(uPin) != null && int.tryParse(uPin) == int.tryParse(cleanPin)))) ||
              (uId == cleanPin || (int.tryParse(uId) != null && int.tryParse(uId) == int.tryParse(cleanPin)))) {
            final cred = BiometricCredential(
              id: uId,
              biometricPin: cleanPin,
              entityId: uId,
              entityName: uName,
              entityType: role.toLowerCase().contains('teacher') ? 'teacher' : 'employee',
              branchId: branchId,
              enrolledAt: DateTime.now(),
            );
            registerBiometricCredential(cred);
            return cred;
          }
        }
      }
    }

    return null;
  }

  static BiometricCredential? getCredentialByEntityId(String entityId) {
    if (entityId.trim().isEmpty) return null;
    final cleanEntityId = entityId.trim();

    if (Hive.isBoxOpen(LocalStorageService.biometricCredentialsBox)) {
      final box = Hive.box(LocalStorageService.biometricCredentialsBox);
      for (var val in box.values) {
        if (val is Map) {
          try {
            final cred = BiometricCredential.fromMap(val);
            if (cred.entityId.trim() == cleanEntityId && cred.active) {
              return cred;
            }
          } catch (_) {}
        }
      }
    }

    // Check employeesBox fallback
    if (Hive.isBoxOpen(LocalStorageService.employeesBox)) {
      final box = Hive.box(LocalStorageService.employeesBox);
      for (var key in box.keys) {
        final raw = box.get(key);
        if (raw is Map) {
          final map = Map<String, dynamic>.from(raw);
          final empId = (map['localId'] ?? map['id'] ?? key).toString().trim();
          if (empId == cleanEntityId) {
            final pin = (map['biometricPin'] ?? map['pin'] ?? '').toString().trim();
            if (pin.isNotEmpty) {
              return BiometricCredential(
                id: empId,
                biometricPin: pin,
                entityId: empId,
                entityName: map['name']?.toString() ?? 'Employee',
                entityType: 'employee',
                branchId: map['branchId']?.toString() ?? '',
                enrolledAt: DateTime.now(),
              );
            }
          }
        }
      }
    }
    return null;
  }

  /// Explicitly maps a Biometric PIN to an entity and automatically re-routes any previous unmapped scans for that PIN
  static Future<int> mapPinToEntity({
    required String pin,
    required String entityId,
    required String entityName,
    required String entityType,
    required String branchId,
  }) async {
    final cleanPin = pin.trim();
    if (cleanPin.isEmpty) return 0;

    // 0. Remove this PIN from any conflicting employee/credential to guarantee 100% uniqueness
    await unassignPinFromOtherEntities(cleanPin, targetEntityId: entityId);

    // 1. Save / Update in biometricCredentialsBox
    final existing = getCredentialByEntityId(entityId);
    final history = List<String>.from(existing?.pinHistory ?? []);
    if (existing != null && existing.biometricPin.isNotEmpty && existing.biometricPin != cleanPin) {
      if (!history.contains(existing.biometricPin)) {
        history.add(existing.biometricPin);
      }
    }

    final cred = BiometricCredential(
      id: entityId,
      biometricPin: cleanPin,
      pinHistory: history,
      entityId: entityId,
      entityName: entityName,
      entityType: entityType,
      branchId: branchId,
      enrolledAt: DateTime.now(),
    );
    await registerBiometricCredential(cred);

    // 2. If employee, also update employeesBox and Firestore document
    if (entityType.toLowerCase() == 'employee' || entityType.toLowerCase() == 'teacher') {
      if (Hive.isBoxOpen(LocalStorageService.employeesBox)) {
        final empBox = Hive.box(LocalStorageService.employeesBox);
        for (var key in empBox.keys) {
          final raw = empBox.get(key);
          if (raw is Map) {
            final map = Map<String, dynamic>.from(raw);
            final eId = (map['localId'] ?? map['id'] ?? key).toString();
            if (eId == entityId) {
              map['biometricPin'] = cleanPin;
              map['pin'] = cleanPin;
              await empBox.put(key, map);
              break;
            }
          }
        }
      }

      // Persist to Cloud Firestore employee document
      try {
        final targetBranch = LocalStorageService.sanitizeBranchId(branchId, fallback: 'karachi');
        FirebaseFirestore.instance
            .collection('branches')
            .doc(targetBranch)
            .collection('employees')
            .doc(entityId)
            .set({'biometricPin': cleanPin, 'pin': cleanPin}, SetOptions(merge: true))
            .catchError((_) {});
      } catch (_) {}
    }

    // 3. Auto-route all unmapped punches for this PIN to this entity
    final remapped = await processPendingUnmappedPunches();
    debugPrint('[ZkTecoNetworkService] Mapped PIN $cleanPin to $entityName ($entityType). Remapped $remapped punches.');
    return remapped;
  }

  /// Removes a PIN assignment from any entity except the targetEntityId to prevent duplicate PIN conflicts
  static Future<void> unassignPinFromOtherEntities(String pin, {required String targetEntityId}) async {
    final cleanPin = pin.trim();
    if (cleanPin.isEmpty) return;

    if (Hive.isBoxOpen(LocalStorageService.biometricCredentialsBox)) {
      final credBox = Hive.box(LocalStorageService.biometricCredentialsBox);
      final keysToRemove = <dynamic>[];
      for (final key in credBox.keys) {
        final val = credBox.get(key);
        if (val is Map) {
          try {
            final cred = BiometricCredential.fromMap(val);
            if (cred.biometricPin.trim() == cleanPin && cred.entityId.trim() != targetEntityId.trim()) {
              keysToRemove.add(key);
            }
          } catch (_) {}
        }
      }
      for (final k in keysToRemove) {
        await credBox.delete(k);
      }
    }

    if (Hive.isBoxOpen(LocalStorageService.employeesBox)) {
      final empBox = Hive.box(LocalStorageService.employeesBox);
      for (final key in empBox.keys) {
        final raw = empBox.get(key);
        if (raw is Map) {
          final map = Map<String, dynamic>.from(raw);
          final eId = (map['localId'] ?? map['id'] ?? key).toString().trim();
          final empPin = (map['biometricPin'] ?? map['pin'] ?? '').toString().trim();
          if (empPin == cleanPin && eId != targetEntityId.trim()) {
            map.remove('biometricPin');
            map.remove('pin');
            await empBox.put(key, map);
          }
        }
      }
    }
  }

  static List<BiometricCredential> getAllCredentials() {
    if (!Hive.isBoxOpen(LocalStorageService.biometricCredentialsBox)) return [];
    final box = Hive.box(LocalStorageService.biometricCredentialsBox);
    final Map<String, BiometricCredential> byEntityId = {};
    final Set<String> seenPins = {};

    for (var v in box.values) {
      if (v is Map) {
        try {
          final cred = BiometricCredential.fromMap(v);
          final cleanEntityId = cred.entityId.trim();
          final cleanPin = cred.biometricPin.trim();

          if (cleanEntityId.isEmpty || !cred.active) continue;

          // If entityId or PIN is already seen, prioritize the latest enrolled credential
          if (!byEntityId.containsKey(cleanEntityId) && !seenPins.contains(cleanPin)) {
            byEntityId[cleanEntityId] = cred;
            if (cleanPin.isNotEmpty) seenPins.add(cleanPin);
          }
        } catch (_) {}
      }
    }
    return byEntityId.values.toList();
  }

  static Future<void> registerBiometricCredential(BiometricCredential credential) async {
    if (!Hive.isBoxOpen(LocalStorageService.biometricCredentialsBox)) {
      await LocalStorageService.openBoxSafe(LocalStorageService.biometricCredentialsBox);
    }
    final cleanEntityId = credential.entityId.trim();
    final cleanPin = credential.biometricPin.trim();
    if (cleanEntityId.isEmpty) return;

    await unassignPinFromOtherEntities(cleanPin, targetEntityId: cleanEntityId);
    final box = Hive.box(LocalStorageService.biometricCredentialsBox);

    // Delete any previous credentials for this same entityId or same pin to prevent duplicates
    final keysToDelete = <dynamic>[];
    for (final key in box.keys) {
      final val = box.get(key);
      if (val is Map) {
        try {
          final existing = BiometricCredential.fromMap(val);
          if (existing.entityId.trim() == cleanEntityId || (cleanPin.isNotEmpty && existing.biometricPin.trim() == cleanPin)) {
            keysToDelete.add(key);
          }
        } catch (_) {}
      }
    }
    for (final k in keysToDelete) {
      await box.delete(k);
    }

    // Save with clean entityId as the primary key
    await box.put(cleanEntityId, credential.toMap());

    // Sync to Cloud Firestore (Non-blocking background)
    unawaited(() async {
      try {
        final targetBranch = LocalStorageService.sanitizeBranchId(credential.branchId, fallback: 'karachi');
        final credData = credential.toMap()
          ..['updatedAt'] = FieldValue.serverTimestamp();

        await FirebaseFirestore.instance
            .collection('branches')
            .doc(targetBranch)
            .collection('biometric_credentials')
            .doc(cleanEntityId)
            .set(credData, SetOptions(merge: true))
            .timeout(const Duration(seconds: 5))
            .catchError((_) {});
      } catch (e) {
        debugPrint('[ZkTecoNetworkService] Credential Firestore sync notice: $e');
      }
    }());
  }

  static Future<void> deleteBiometricCredential(String entityId, {String? branchId}) async {
    final cleanEntityId = entityId.trim();
    if (cleanEntityId.isEmpty) return;

    if (Hive.isBoxOpen(LocalStorageService.biometricCredentialsBox)) {
      final box = Hive.box(LocalStorageService.biometricCredentialsBox);
      await box.delete(cleanEntityId);
      // Also delete any other keys mapped to this entityId
      final otherKeys = <dynamic>[];
      for (final k in box.keys) {
        final val = box.get(k);
        if (val is Map && (val['entityId']?.toString().trim() == cleanEntityId)) {
          otherKeys.add(k);
        }
      }
      for (final k in otherKeys) {
        await box.delete(k);
      }
    }

    // Unassign biometricPin and pin from employee profile in employeesBox
    if (Hive.isBoxOpen(LocalStorageService.employeesBox)) {
      final empBox = Hive.box(LocalStorageService.employeesBox);
      for (final key in empBox.keys) {
        final raw = empBox.get(key);
        if (raw is Map) {
          final id = (raw['localId'] ?? raw['id'] ?? key).toString().trim();
          if (id == cleanEntityId) {
            final updated = Map<String, dynamic>.from(raw);
            updated.remove('biometricPin');
            updated.remove('pin');
            await empBox.put(key, updated);
            break;
          }
        }
      }
    }

    // Also remove from madrassa students if entity is student
    if (Hive.isBoxOpen(LocalStorageService.madrassaStudentsBox)) {
      final mBox = Hive.box(LocalStorageService.madrassaStudentsBox);
      for (final key in mBox.keys) {
        final raw = mBox.get(key);
        if (raw is Map) {
          final id = (raw['id'] ?? key).toString().trim();
          if (id == cleanEntityId || key.toString().endsWith('__std__$cleanEntityId')) {
            final updated = Map<String, dynamic>.from(raw);
            updated.remove('biometricPin');
            updated.remove('pin');
            await mBox.put(key, updated);
            break;
          }
        }
      }
    }

    // Cloud Firestore delete (Non-blocking background)
    unawaited(() async {
      try {
        final targetBranch = LocalStorageService.sanitizeBranchId(branchId, fallback: 'karachi');
        await FirebaseFirestore.instance
            .collection('branches')
            .doc(targetBranch)
            .collection('biometric_credentials')
            .doc(cleanEntityId)
            .delete()
            .timeout(const Duration(seconds: 5))
            .catchError((_) {});
      } catch (e) {
        debugPrint('[ZkTecoNetworkService] Credential delete notice: $e');
      }
    }());
  }

  /// Removes only employee credentials for a branch (or globally), preserving Madrassa students.
  static Future<int> clearEmployeeBiometricCredentials({String? branchId}) {
    return clearAllBiometricCredentials(branchId: branchId, targetEntityType: 'employee');
  }

  /// Removes biometric credentials for a branch (or globally), clearing PINs so they can be manually assigned.
  /// If [targetEntityType] is 'employee', preserves Madrassa students.
  static Future<int> clearAllBiometricCredentials({String? branchId, String? targetEntityType}) async {
    int count = 0;
    if (!Hive.isBoxOpen(LocalStorageService.biometricCredentialsBox)) {
      await LocalStorageService.openBoxSafe(LocalStorageService.biometricCredentialsBox);
    }
    final credBox = Hive.box(LocalStorageService.biometricCredentialsBox);

    final cleanBranch = (branchId ?? '').toLowerCase().trim();
    final isAll = cleanBranch.isEmpty || cleanBranch == 'all' || cleanBranch == 'main' || cleanBranch == 'global';

    final keysToDelete = <dynamic>[];
    final unlinkedEntityIds = <String>{};

    for (final key in credBox.keys) {
      final val = credBox.get(key);
      if (val is Map) {
        final b = (val['branchId'] ?? '').toString().toLowerCase().trim();
        final entityId = (val['entityId'] ?? '').toString().trim();
        final eType = (val['entityType'] ?? '').toString().toLowerCase().trim();

        if (targetEntityType != null && targetEntityType.isNotEmpty) {
          if (targetEntityType == 'employee') {
            if (eType == 'madrassa_student' || eType == 'school_student' || eType == 'student') {
              continue; // PRESERVE Madrassa students!
            }
          } else if (eType != targetEntityType) {
            continue;
          }
        }

        if (isAll || b.isEmpty || b == cleanBranch || b.contains(cleanBranch) || cleanBranch.contains(b)) {
          keysToDelete.add(key);
          if (entityId.isNotEmpty) unlinkedEntityIds.add(entityId);
        }
      } else {
        if (isAll && targetEntityType == null) keysToDelete.add(key);
      }
    }

    for (final k in keysToDelete) {
      await credBox.delete(k);
      count++;
    }

    // Clear biometricPin and pin from employee profiles in employeesBox
    if (Hive.isBoxOpen(LocalStorageService.employeesBox)) {
      final empBox = Hive.box(LocalStorageService.employeesBox);
      for (final key in empBox.keys) {
        final raw = empBox.get(key);
        if (raw is Map) {
          final empId = (raw['localId'] ?? raw['id'] ?? key).toString().trim();
          final empBranch = (raw['branchId'] ?? '').toString().toLowerCase().trim();
          if (isAll || unlinkedEntityIds.contains(empId) || empBranch == cleanBranch || empBranch.contains(cleanBranch)) {
            if (raw['biometricPin'] != null || raw['pin'] != null) {
              final updated = Map<String, dynamic>.from(raw);
              updated.remove('biometricPin');
              updated.remove('pin');
              await empBox.put(key, updated);
            }
          }
        }
      }
    }

    // Cloud Firestore delete
    unawaited(() async {
      try {
        if (isAll) {
          final snap = await FirebaseFirestore.instance.collectionGroup('biometric_credentials').get();
          for (final doc in snap.docs) {
            await doc.reference.delete().catchError((_) {});
          }
        } else {
          final targetBranch = LocalStorageService.sanitizeBranchId(branchId, fallback: 'karachi');
          final snap = await FirebaseFirestore.instance
              .collection('branches')
              .doc(targetBranch)
              .collection('biometric_credentials')
              .get();
          for (final doc in snap.docs) {
            await doc.reference.delete().catchError((_) {});
          }
        }
      } catch (e) {
        debugPrint('[ZkTecoNetworkService] Firestore credentials clear notice: $e');
      }
    }());

    debugPrint('[ZkTecoNetworkService] Cleared $count credentials for branch: $branchId');
    return count;
  }

  /// Syncs all biometric credentials from Cloud Firestore down to local Hive
  static Future<void> syncBiometricCredentialsFromFirestore({String? branchId}) async {
    try {
      if (!Hive.isBoxOpen(LocalStorageService.biometricCredentialsBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.biometricCredentialsBox);
      }
      final box = Hive.box(LocalStorageService.biometricCredentialsBox);

      final query = (branchId != null && branchId.isNotEmpty && branchId != 'all')
          ? FirebaseFirestore.instance.collection('branches').doc(branchId.toLowerCase().trim()).collection('biometric_credentials')
          : FirebaseFirestore.instance.collectionGroup('biometric_credentials');

      final snap = await query.get(const GetOptions(source: Source.serverAndCache));
      for (final doc in snap.docs) {
        final data = doc.data();
        final cred = BiometricCredential.fromMap(Map<String, dynamic>.from(data));
        if (cred.entityId.isNotEmpty) {
          await box.put(cred.entityId.trim(), cred.toMap());
        }
      }
      debugPrint('[ZkTecoNetworkService] Synced ${snap.docs.length} biometric credentials from Firestore');
    } catch (e) {
      debugPrint('[ZkTecoNetworkService] Error syncing biometric credentials from Firestore: $e');
    }
  }

  /// Sync biometric credentials from Firestore once on demand without realtime stream.
  static void listenToBiometricCredentialsFromFirestore({String? branchId}) {
    _remoteCredsSub?.cancel();
    _remoteCredsSub = null;
    final normalized = (branchId ?? '').trim().toLowerCase();
    if (normalized.isNotEmpty && normalized != 'all' && normalized != 'global') {
      syncBiometricCredentialsFromFirestore(branchId: normalized);
    }
  }

  /// Checks if a PIN is already assigned to another entity (Employee, Student, or User).
  /// Returns the conflicting BiometricCredential if taken, or null if available.
  static BiometricCredential? findPinConflict(String pin, {String? excludeEntityId}) {
    final cleanPin = pin.trim();
    if (cleanPin.isEmpty) return null;

    final allCreds = getAllCredentials();
    for (final cred in allCreds) {
      if (cred.active && cred.biometricPin.trim() == cleanPin) {
        if (excludeEntityId != null && cred.entityId.trim() == excludeEntityId.trim()) {
          continue; // Same person updating their own profile
        }
        return cred;
      }
    }

    // Also check local employee records in Hive
    if (Hive.isBoxOpen(LocalStorageService.employeesBox)) {
      final empBox = Hive.box(LocalStorageService.employeesBox);
      for (final raw in empBox.values) {
        if (raw is! Map) continue;
        final emp = Map<String, dynamic>.from(raw);
        final empId = emp['localId']?.toString() ?? emp['id']?.toString() ?? '';
        if (excludeEntityId != null && empId.trim() == excludeEntityId.trim()) continue;
        final empPin = emp['biometricPin']?.toString().trim() ?? '';
        if (empPin.isNotEmpty && empPin == cleanPin && emp['isActive'] != false) {
          return BiometricCredential(
            id: empId,
            biometricPin: empPin,
            entityId: empId,
            entityName: emp['name']?.toString() ?? 'Employee',
            entityType: 'employee',
            branchId: emp['branchId']?.toString() ?? 'Unknown',
            enrolledAt: DateTime.now(),
            active: true,
          );
        }
      }
    }

    return null;
  }

  /// Assigns or updates a numeric PIN for a specific user (Employee/Student).
  static Future<String> assignPinToEntity({
    required String entityId,
    required String entityName,
    required String entityType,
    required String branchId,
    String? customPin,
  }) async {
    final existingCreds = getAllCredentials();
    final usedPins = existingCreds.where((c) => c.entityId != entityId).map((c) => c.biometricPin.trim()).toSet();

    String finalPin = customPin?.trim() ?? '';
    if (finalPin.isEmpty) {
      int nextPin = entityType.toLowerCase().contains('madrassa') ? 3001 : (entityType.toLowerCase().contains('school') ? 5001 : 101);
      while (usedPins.contains(nextPin.toString())) {
        nextPin++;
      }
      finalPin = nextPin.toString();
    }

    // Check if user already had a credential
    final existing = existingCreds.where((c) => c.entityId == entityId).firstOrNull;
    final history = List<String>.from(existing?.pinHistory ?? []);
    if (existing != null && existing.biometricPin.isNotEmpty && existing.biometricPin != finalPin) {
      if (!history.contains(existing.biometricPin)) {
        history.add(existing.biometricPin);
      }
    }

    final cred = BiometricCredential(
      id: existing?.id ?? _uuid.v4(),
      biometricPin: finalPin,
      pinHistory: history,
      entityId: entityId,
      entityName: entityName,
      entityType: entityType,
      branchId: branchId,
      enrolledAt: DateTime.now(),
      active: true,
    );

    await registerBiometricCredential(cred);
    unawaited(processPendingUnmappedPunches().catchError((e) {
      debugPrint('[ZkTecoNetworkService] Background unmapped punches notice: $e');
      return 0;
    }));
    return finalPin;
  }

  // ── Cross-Branch Punch Management ──────────────────────────────────────────

  static bool _isCrossBranchMismatch(String employeeBranchId, String deviceBranchId, [String? entityId]) {
    final cleanEmp = employeeBranchId.trim().toLowerCase().replaceAll('branch_', '');
    final cleanDev = deviceBranchId.trim().toLowerCase().replaceAll('branch_', '');
    if (cleanEmp.isEmpty || cleanDev.isEmpty) return false;
    if (cleanEmp == 'all' || cleanDev == 'all' || cleanEmp == 'global' || cleanDev == 'global') return false;

    final empCanonical = LocalStorageService.getBranchName(cleanEmp).toLowerCase();
    final devCanonical = LocalStorageService.getBranchName(cleanDev).toLowerCase();
    if (empCanonical == devCanonical || cleanEmp == cleanDev) return false;

    // Multi-camp Karachi branch family (Saddar, Haji Camp, Kapaya, Karachi)
    bool isKarachiFamily(String b) => b.contains('karachi') || b.contains('saddar') || b.contains('haji') || b.contains('kapaya');
    if (isKarachiFamily(cleanEmp) && isKarachiFamily(cleanDev)) {
      return false; // Authorized multi-camp / split-shift Karachi employee
    }

    // Check if employee profile has multiple assigned branches or multi-camp schedules
    if (entityId != null && entityId.isNotEmpty && Hive.isBoxOpen(LocalStorageService.employeesBox)) {
      try {
        final empRaw = Hive.box(LocalStorageService.employeesBox).get(entityId);
        if (empRaw is Map) {
          final empMap = Map<String, dynamic>.from(empRaw);
          for (final k in ['assignedBranches', 'allowedBranches', 'branches', 'branchIds']) {
            if (empMap[k] is List) {
              final list = (empMap[k] as List).map((e) => e.toString().toLowerCase().replaceAll('branch_', '').trim()).toList();
              if (list.contains(cleanDev) || list.contains(devCanonical) || list.contains('all')) {
                return false; // Authorized multi-branch staff
              }
            }
          }
          if (empMap['campSchedule'] is List) {
            for (final s in (empMap['campSchedule'] as List)) {
              if (s is Map) {
                final b = (s['branchId'] ?? s['branch'])?.toString().toLowerCase().replaceAll('branch_', '').trim();
                if (b == cleanDev || b == devCanonical) return false;
              }
            }
          }
        }
      } catch (_) {}
    }

    return true;
  }

  static Future<void> _saveCrossBranchPendingPunch(Map<String, dynamic> pendingRecord) async {
    try {
      if (!Hive.isBoxOpen(LocalStorageService.crossBranchPunchesBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.crossBranchPunchesBox);
      }
      final box = Hive.box(LocalStorageService.crossBranchPunchesBox);
      await box.put(pendingRecord['id'], pendingRecord);
    } catch (e) {
      debugPrint('[ZkTecoNetworkService] Error saving cross-branch pending punch: $e');
    }
  }

  /// Retrieves all pending cross-branch punches requiring HQ Manager decision.
  static List<Map<String, dynamic>> getPendingCrossBranchPunches({String? branchId, String? dateStr}) {
    if (!Hive.isBoxOpen(LocalStorageService.crossBranchPunchesBox)) return [];
    final box = Hive.box(LocalStorageService.crossBranchPunchesBox);
    final results = <Map<String, dynamic>>[];
    for (final v in box.values) {
      if (v is Map) {
        final map = Map<String, dynamic>.from(v);
        if (map['status'] == 'pending') {
          if (dateStr != null && dateStr.isNotEmpty) {
            final ts = map['timestamp']?.toString() ?? '';
            if (!ts.startsWith(dateStr)) continue;
          }
          if (branchId != null && branchId.isNotEmpty && branchId.toLowerCase() != 'all') {
            final empB = (map['employeeBranchId']?.toString() ?? '').toLowerCase();
            final punchB = (map['punchBranchId']?.toString() ?? '').toLowerCase();
            final curB = branchId.toLowerCase();
            if (empB != curB && punchB != curB &&
                LocalStorageService.getBranchName(empB).toLowerCase() != LocalStorageService.getBranchName(curB).toLowerCase()) {
              continue;
            }
          }
          results.add(map);
        }
      }
    }
    results.sort((a, b) => (b['timestamp']?.toString() ?? '').compareTo(a['timestamp']?.toString() ?? ''));
    return results;
  }

  /// Retrieves all cross-branch punches (pending, approved, rejected) for audit.
  static List<Map<String, dynamic>> getAllCrossBranchPunches() {
    if (!Hive.isBoxOpen(LocalStorageService.crossBranchPunchesBox)) return [];
    final box = Hive.box(LocalStorageService.crossBranchPunchesBox);
    final results = <Map<String, dynamic>>[];
    for (final v in box.values) {
      if (v is Map) {
        results.add(Map<String, dynamic>.from(v));
      }
    }
    results.sort((a, b) => (b['timestamp']?.toString() ?? '').compareTo(a['timestamp']?.toString() ?? ''));
    return results;
  }

  /// HQ Manager approves a cross-branch punch -> marks employee Present with authorization audit note.
  static Future<bool> approveCrossBranchPunch({
    required String pendingId,
    required String reviewerName,
  }) async {
    try {
      if (!Hive.isBoxOpen(LocalStorageService.crossBranchPunchesBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.crossBranchPunchesBox);
      }
      final box = Hive.box(LocalStorageService.crossBranchPunchesBox);
      final raw = box.get(pendingId);
      if (raw == null || raw is! Map) return false;

      final record = Map<String, dynamic>.from(raw);
      record['status'] = 'approved';
      record['reviewedBy'] = reviewerName;
      record['reviewedAt'] = DateTime.now().toIso8601String();
      await box.put(pendingId, record);
      await box.flush();

      // Retrieve credential to route
      final pin = record['pin']?.toString() ?? '';
      final cred = getCredentialByPin(pin) ?? getCredentialByEntityId(record['entityId']?.toString() ?? '');
      if (cred != null) {
        final timestamp = DateTime.tryParse(record['timestamp']?.toString() ?? '') ?? DateTime.now();
        final punchBranch = record['punchBranchName'] ?? 'Remote Branch';
        final locationNote = '${record['buildingLocation']} ($punchBranch - Approved by $reviewerName)';
        await _routePunchToModule(cred, timestamp, locationNote, record['source']?.toString() ?? 'zkteco');
      }

      try {
        RealtimeManager().sendMessage({
          'event_type': 'cross_branch_punch_status_update',
          'data': record,
        });
      } catch (_) {}

      debugPrint('[ZkTecoNetworkService] Cross-branch punch $pendingId APPROVED by $reviewerName');
      return true;
    } catch (e) {
      debugPrint('[ZkTecoNetworkService] Error approving cross-branch punch: $e');
      return false;
    }
  }

  /// HQ Manager rejects a cross-branch punch -> keeps/marks Absent.
  static Future<bool> rejectCrossBranchPunch({
    required String pendingId,
    required String reviewerName,
    String reason = 'Rejected by HQ Manager',
  }) async {
    try {
      if (!Hive.isBoxOpen(LocalStorageService.crossBranchPunchesBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.crossBranchPunchesBox);
      }
      final box = Hive.box(LocalStorageService.crossBranchPunchesBox);
      final raw = box.get(pendingId);
      if (raw == null || raw is! Map) return false;

      final record = Map<String, dynamic>.from(raw);
      record['status'] = 'rejected';
      record['reviewedBy'] = reviewerName;
      record['reviewedAt'] = DateTime.now().toIso8601String();
      record['rejectReason'] = reason;
      await box.put(pendingId, record);
      await box.flush();

      try {
        RealtimeManager().sendMessage({
          'event_type': 'cross_branch_punch_status_update',
          'data': record,
        });
      } catch (_) {}

      debugPrint('[ZkTecoNetworkService] Cross-branch punch $pendingId REJECTED by $reviewerName');
      return true;
    } catch (e) {
      debugPrint('[ZkTecoNetworkService] Error rejecting cross-branch punch: $e');
      return false;
    }
  }

  // ── Bulk Auto-Assign Biometric PINs to Existing Users ─────────────────────

  static bool _isAutoAssignRunning = false;

  /// Scans all existing Employees and Students in local storage and assigns
  /// unique clean numeric Biometric PINs (e.g. 101, 102...) to any unassigned profiles.
  /// 1. Uses mutex lock to guarantee zero race conditions on rapid/concurrent triggers.
  /// 2. Pre-scans ALL existing valid PINs across Staff, Madrassa Students, and School Students.
  /// 3. Preserves existing valid unique PINs without overwriting them.
  /// 4. Resolves duplicate PINs and assigns clean sequential PINs to unassigned entities.
  /// 5. Synchronizes assignments to Hive boxes and Cloud Firestore across all branches.
  static Future<int> bulkAutoAssignBiometricPins({String? branchId}) async {
    if (_isAutoAssignRunning) {
      debugPrint('[ZkTecoNetworkService] bulkAutoAssignBiometricPins already in progress, skipping concurrent run.');
      return 0;
    }
    _isAutoAssignRunning = true;

    try {
      if (!Hive.isBoxOpen(LocalStorageService.biometricCredentialsBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.biometricCredentialsBox);
      }
      if (!Hive.isBoxOpen(LocalStorageService.employeesBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.employeesBox);
      }
      if (!Hive.isBoxOpen(LocalStorageService.madrassaStudentsBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.madrassaStudentsBox);
      }
      if (!Hive.isBoxOpen(LocalStorageService.schoolStudentsBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.schoolStudentsBox);
      }

      int assignedCount = 0;
      int currentStaffPin = 101;
      int currentMadrassaPin = 3001;
      int currentSchoolPin = 5001;

      bool matchesBranch(String? entityBranch, String? targetBranch) {
        if (targetBranch == null || targetBranch.isEmpty || targetBranch == 'all' || targetBranch == 'global' || targetBranch == 'main') {
          return true;
        }
        if (entityBranch == null || entityBranch.isEmpty) return true;
        final b1 = entityBranch.toLowerCase().replaceAll('branch_', '').replaceAll('_', ' ').trim();
        final b2 = targetBranch.toLowerCase().replaceAll('branch_', '').replaceAll('_', ' ').trim();
        return b1 == b2 || b1.contains(b2) || b2.contains(b1);
      }

      // Step 1: Comprehensive pre-scan of ALL existing PINs across all entities
      // pinOwner: PIN -> entityId (first one to claim keeps it)
      final Map<String, String> pinOwner = {};
      // entityAssignedPin: entityId -> unique valid PIN
      final Map<String, String> entityAssignedPin = {};

      // 1a. Inspect existing BiometricCredential entries
      final credBox = Hive.box(LocalStorageService.biometricCredentialsBox);
      for (final v in credBox.values) {
        if (v is Map) {
          try {
            final cred = BiometricCredential.fromMap(v);
            final cleanEntityId = cred.entityId.trim();
            final cleanPin = cred.biometricPin.trim();
            if (cleanEntityId.isNotEmpty && cleanPin.isNotEmpty && cred.active) {
              if (!pinOwner.containsKey(cleanPin)) {
                pinOwner[cleanPin] = cleanEntityId;
                entityAssignedPin[cleanEntityId] = cleanPin;
              }
            }
          } catch (_) {}
        }
      }

      // 1b. Inspect existing employee records
      final empBox = Hive.box(LocalStorageService.employeesBox);
      for (final key in empBox.keys) {
        final raw = empBox.get(key);
        if (raw is Map) {
          final emp = Map<String, dynamic>.from(raw);
          final empId = (emp['localId'] ?? emp['id'] ?? key).toString().trim();
          final existingPin = (emp['biometricPin'] ?? emp['pin'] ?? '').toString().trim();
          if (empId.isNotEmpty && existingPin.isNotEmpty && emp['isActive'] != false) {
            if (!pinOwner.containsKey(existingPin)) {
              pinOwner[existingPin] = empId;
              entityAssignedPin[empId] = existingPin;
            }
          }
        }
      }

      // 1c. Inspect existing Madrassa students
      final mBox = Hive.box(LocalStorageService.madrassaStudentsBox);
      for (final key in mBox.keys) {
        final raw = mBox.get(key);
        if (raw is Map) {
          final st = Map<String, dynamic>.from(raw);
          final stId = (st['id'] ?? key).toString().trim();
          final existingPin = (st['biometricPin'] ?? st['pin'] ?? '').toString().trim();
          if (stId.isNotEmpty && existingPin.isNotEmpty) {
            if (!pinOwner.containsKey(existingPin)) {
              pinOwner[existingPin] = stId;
              entityAssignedPin[stId] = existingPin;
            }
          }
        }
      }

      // 1d. Inspect existing School students
      final sBox = Hive.box(LocalStorageService.schoolStudentsBox);
      for (final key in sBox.keys) {
        final raw = sBox.get(key);
        if (raw is Map) {
          final st = Map<String, dynamic>.from(raw);
          final stId = (st['id'] ?? key).toString().trim();
          final existingPin = (st['biometricPin'] ?? st['pin'] ?? '').toString().trim();
          if (stId.isNotEmpty && existingPin.isNotEmpty) {
            if (!pinOwner.containsKey(existingPin)) {
              pinOwner[existingPin] = stId;
              entityAssignedPin[stId] = existingPin;
            }
          }
        }
      }

      // Step 2: Process Employees
      for (final key in empBox.keys) {
        final raw = empBox.get(key);
        if (raw is Map) {
          final empMap = Map<String, dynamic>.from(raw);
          if (empMap['isActive'] == false || empMap['isDeleted'] == true) continue;

          final empId = (empMap['localId'] ?? empMap['id'] ?? key).toString().trim();
          final name = empMap['name']?.toString() ?? 'Employee';
          final empBranch = (empMap['branchId'] ?? '').toString().trim();

          if (!matchesBranch(empBranch, branchId)) {
            continue;
          }

          String assignedPin = entityAssignedPin[empId] ?? '';

          if (assignedPin.isEmpty) {
            while (pinOwner.containsKey(currentStaffPin.toString())) {
              currentStaffPin++;
            }
            assignedPin = currentStaffPin.toString();
            currentStaffPin++;
            pinOwner[assignedPin] = empId;
            entityAssignedPin[empId] = assignedPin;
            assignedCount++;
          }

          final targetBranch = empBranch.isNotEmpty ? empBranch.toLowerCase().trim() : ((branchId != null && branchId.isNotEmpty && branchId != 'all') ? branchId.toLowerCase().trim() : 'karachi');

          // Register BiometricCredential
          final cred = BiometricCredential(
            id: empId,
            biometricPin: assignedPin,
            entityId: empId,
            entityName: name,
            entityType: 'employee',
            branchId: targetBranch,
            enrolledAt: DateTime.now(),
          );
          await registerBiometricCredential(cred);

          // Update employee record in local storage & Cloud Firestore
          empMap['biometricPin'] = assignedPin;
          empMap['pin'] = assignedPin;
          await empBox.put(key, empMap);

          try {
            FirebaseFirestore.instance
                .collection('branches')
                .doc(targetBranch)
                .collection('employees')
                .doc(empId)
                .set({'biometricPin': assignedPin, 'pin': assignedPin}, SetOptions(merge: true))
                .catchError((_) {});
          } catch (_) {}
        }
      }

      // Step 3: Process Madrassa Students
      for (final key in mBox.keys) {
        final raw = mBox.get(key);
        if (raw is Map) {
          final map = Map<String, dynamic>.from(raw);
          final stId = (map['id'] ?? key).toString().trim();
          final name = map['name']?.toString() ?? 'Madrassa Student';
          final stBranch = (map['branchId'] ?? '').toString().trim();

          if (!matchesBranch(stBranch, branchId)) {
            continue;
          }

          String assignedPin = entityAssignedPin[stId] ?? '';
          if (assignedPin.isEmpty) {
            while (pinOwner.containsKey(currentMadrassaPin.toString())) {
              currentMadrassaPin++;
            }
            assignedPin = currentMadrassaPin.toString();
            currentMadrassaPin++;
            pinOwner[assignedPin] = stId;
            entityAssignedPin[stId] = assignedPin;
            assignedCount++;
          }

          final targetBranch = stBranch.isNotEmpty ? stBranch.toLowerCase().trim() : ((branchId != null && branchId.isNotEmpty && branchId != 'all') ? branchId.toLowerCase().trim() : 'karachi');

          final cred = BiometricCredential(
            id: stId,
            biometricPin: assignedPin,
            entityId: stId,
            entityName: name,
            entityType: 'madrassa_student',
            branchId: targetBranch,
            enrolledAt: DateTime.now(),
          );
          await registerBiometricCredential(cred);

          // Update student record in Hive & Cloud Firestore
          map['biometricPin'] = assignedPin;
          map['pin'] = assignedPin;
          await mBox.put(key, map);

          try {
            FirebaseFirestore.instance
                .collection('branches')
                .doc(targetBranch)
                .collection('madrassa_students')
                .doc(stId)
                .set({'biometricPin': assignedPin, 'pin': assignedPin}, SetOptions(merge: true))
                .catchError((_) {});
          } catch (_) {}
        }
      }

      // Step 4: Process School Students
      for (final key in sBox.keys) {
        final raw = sBox.get(key);
        if (raw is Map) {
          final map = Map<String, dynamic>.from(raw);
          final stId = (map['id'] ?? key).toString().trim();
          final name = map['name']?.toString() ?? 'School Student';
          final stBranch = (map['branchId'] ?? '').toString().trim();

          if (!matchesBranch(stBranch, branchId)) {
            continue;
          }

          String assignedPin = entityAssignedPin[stId] ?? '';
          if (assignedPin.isEmpty) {
            while (pinOwner.containsKey(currentSchoolPin.toString())) {
              currentSchoolPin++;
            }
            assignedPin = currentSchoolPin.toString();
            currentSchoolPin++;
            pinOwner[assignedPin] = stId;
            entityAssignedPin[stId] = assignedPin;
            assignedCount++;
          }

          final targetBranch = stBranch.isNotEmpty ? stBranch.toLowerCase().trim() : ((branchId != null && branchId.isNotEmpty && branchId != 'all') ? branchId.toLowerCase().trim() : 'karachi');

          final cred = BiometricCredential(
            id: stId,
            biometricPin: assignedPin,
            entityId: stId,
            entityName: name,
            entityType: 'school_student',
            branchId: targetBranch,
            enrolledAt: DateTime.now(),
          );
          await registerBiometricCredential(cred);

          // Update student record in Hive & Cloud Firestore
          map['biometricPin'] = assignedPin;
          map['pin'] = assignedPin;
          await sBox.put(key, map);

          try {
            FirebaseFirestore.instance
                .collection('branches')
                .doc(targetBranch)
                .collection('school_students')
                .doc(stId)
                .set({'biometricPin': assignedPin, 'pin': assignedPin}, SetOptions(merge: true))
                .catchError((_) {});
          } catch (_) {}
        }
      }

      await empBox.flush();
      await credBox.flush();
      await mBox.flush();
      await sBox.flush();

      // Auto-process unmapped punches now that new credentials are registered
      await processPendingUnmappedPunches();

      debugPrint('[ZkTecoNetworkService] Bulk auto-assigned $assignedCount unique biometric PINs successfully.');
      return assignedCount;
    } finally {
      _isAutoAssignRunning = false;
    }
  }

  /// Iterates through all unmapped punches and auto-routes any punch whose PIN has since been registered.
  static Future<int> processPendingUnmappedPunches() async {
    try {
      int remappedCount = 0;

      // 1. Process unmappedPunchesBox
      if (Hive.isBoxOpen(LocalStorageService.unmappedPunchesBox)) {
        final box = Hive.box(LocalStorageService.unmappedPunchesBox);
        final keys = List.from(box.keys);
        for (var k in keys) {
          final item = box.get(k);
          if (item is Map) {
            final map = Map<String, dynamic>.from(item);
            final pin = map['pin']?.toString() ?? '';
            final tsStr = map['timestamp']?.toString();
            final ts = tsStr != null ? (DateTime.tryParse(tsStr) ?? DateTime.now()) : DateTime.now();
            final cred = getCredentialByPin(pin);
            if (cred != null) {
              final src = map['source']?.toString() ?? 'zkteco';
              final loc = map['buildingLocation']?.toString() ?? 'Office';
              await _routePunchToModule(cred, ts, loc, src);
              await box.delete(k);
              remappedCount++;
            }
          }
        }
      }

      // 2. Process any legacy unmapped records in attendanceBox
      if (Hive.isBoxOpen(LocalStorageService.attendanceBox)) {
        final attBox = Hive.box(LocalStorageService.attendanceBox);
        final attKeys = List.from(attBox.keys);
        for (var k in attKeys) {
          final item = attBox.get(k);
          if (item is Map) {
            final map = Map<String, dynamic>.from(item);
            final isUnmapped = map['isMapped'] == false || map['entityType'] == 'unmapped' || map['employeeId'] == null || map['employeeId'] == '';
            if (isUnmapped) {
              final pin = map['pin']?.toString() ?? '';
              final tsStr = (map['timestamp'] ?? map['lastPunchTime'] ?? map['date'])?.toString();
              final ts = tsStr != null ? (DateTime.tryParse(tsStr) ?? DateTime.now()) : DateTime.now();
              final cred = getCredentialByPin(pin);
              if (cred != null) {
                final src = map['source']?.toString() ?? 'zkteco';
                final loc = map['buildingLocation']?.toString() ?? 'Office';
                await _routePunchToModule(cred, ts, loc, src);
                await attBox.delete(k);
                remappedCount++;
              }
            }
          }
        }
      }

      if (remappedCount > 0) {
        debugPrint('[ZkTecoNetworkService] Auto-remapped $remappedCount pending unmapped punches to users');
        await syncAllRecordedAttendanceToFirestore();
      }
      return remappedCount;
    } catch (e) {
      debugPrint('[ZkTecoNetworkService] Error processing unmapped punches: $e');
      return 0;
    }
  }

  /// Retrieves all unmapped punches currently pending assignment.
  static List<Map<String, dynamic>> getUnmappedPunches() {
    if (!Hive.isBoxOpen(LocalStorageService.unmappedPunchesBox)) return [];
    final box = Hive.box(LocalStorageService.unmappedPunchesBox);
    final results = <Map<String, dynamic>>[];
    for (var v in box.values) {
      if (v is Map) {
        results.add(Map<String, dynamic>.from(v));
      }
    }
    return results;
  }

  /// Loads today's punch records from all local boxes (Attendance, Cross-Branch, Unmapped)
  /// so the Live Logs UI displays all recent activity immediately upon opening.
  static List<Map<String, dynamic>> getRecentPunchesToday() {
    final list = <Map<String, dynamic>>[];
    final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());

    // 1. Cross-branch punches
    if (Hive.isBoxOpen(LocalStorageService.crossBranchPunchesBox)) {
      final box = Hive.box(LocalStorageService.crossBranchPunchesBox);
      for (final v in box.values) {
        if (v is Map) {
          final m = Map<String, dynamic>.from(v);
          final ts = m['timestamp']?.toString() ?? '';
          if (ts.startsWith(todayStr)) {
            list.add({
              'id': m['id'] ?? m['punchId'],
              'pin': m['pin'] ?? '---',
              'timestamp': ts,
              'deviceIp': m['deviceIp'] ?? '192.168.1.150',
              'deviceSn': m['deviceSn'] ?? '',
              'deviceName': m['deviceName'] ?? 'ZKTeco Scanner',
              'buildingLocation': m['buildingLocation'] ?? 'Office',
              'source': m['source'] ?? 'zkteco',
              'isMapped': true,
              'entityId': m['entityId'],
              'entityName': m['entityName'] ?? 'Employee',
              'entityType': m['entityType'] ?? 'employee',
              'entityBranchName': m['employeeBranchName'] ?? '',
              'deviceBranchName': m['punchBranchName'] ?? '',
              'isCrossBranchPending': m['status'] == 'pending',
              'crossBranchInfo': m,
            });
          }
        }
      }
    }

    // 2. Employee attendance punches from today
    if (Hive.isBoxOpen(LocalStorageService.attendanceBox)) {
      final box = Hive.box(LocalStorageService.attendanceBox);
      for (final v in box.values) {
        if (v is Map) {
          final m = Map<String, dynamic>.from(v);
          final date = m['date']?.toString() ?? '';
          if (date == todayStr) {
            final checkInTs = m['checkInTimestamp']?.toString() ?? m['lastPunchTime']?.toString() ?? '${todayStr}T08:30:00';
            final empName = m['employeeName']?.toString() ?? m['name']?.toString() ?? 'Employee';
            final empId = m['employeeId']?.toString() ?? '';
            final cred = getCredentialByEntityId(empId);

            list.add({
              'id': m['id'] ?? empId,
              'pin': cred?.biometricPin ?? m['pin'] ?? '---',
              'timestamp': checkInTs,
              'deviceIp': '192.168.1.150',
              'deviceName': 'ZKTeco Biometric Scanner',
              'buildingLocation': m['source']?.toString() ?? 'Office',
              'source': m['source']?.toString() ?? 'Biometric Scan',
              'isMapped': true,
              'entityId': empId,
              'entityName': empName,
              'entityType': 'employee',
              'entityBranchId': m['branchId']?.toString() ?? '',
              'entityBranchName': LocalStorageService.getBranchName(m['branchId']?.toString() ?? ''),
              'isCrossBranchPending': false,
              'statusMessage': 'Attendance recorded (${m['status'] ?? 'present'})',
            });
          }
        }
      }
    }

    list.sort((a, b) => (b['timestamp']?.toString() ?? '').compareTo(a['timestamp']?.toString() ?? ''));
    return list;
  }

  /// Calculates today's biometric diagnostics summary (Total Scans, Mapped to Staff, Unmapped)
  static Map<String, dynamic> getTodayPunchDiagnostics([String? branchId]) {
    final punches = getRecentPunchesToday();
    final cleanBranch = (branchId ?? '').toLowerCase().trim();
    
    final filtered = (cleanBranch.isEmpty || cleanBranch == 'all')
        ? punches
        : punches.where((p) {
            final eBranch = (p['entityBranchId'] ?? p['branchId'] ?? '').toString().toLowerCase();
            final dBranch = (p['deviceBranchId'] ?? '').toString().toLowerCase();
            return eBranch.contains(cleanBranch) || dBranch.contains(cleanBranch);
          }).toList();

    int total = filtered.length;
    int mapped = 0;
    int unmapped = 0;
    int crossBranch = 0;

    for (final p in filtered) {
      if (p['isMapped'] == true) {
        mapped++;
      } else {
        unmapped++;
      }
      if (p['isCrossBranchPending'] == true) {
        crossBranch++;
      }
    }

    return {
      'total': total,
      'mapped': mapped,
      'unmapped': unmapped,
      'crossBranch': crossBranch,
      'punches': filtered,
    };
  }

  /// Clears all local historical punches and local attendance records across all boxes
  static Future<void> clearAllLocalAttendanceAndPunches() async {
    try {
      if (Hive.isBoxOpen(LocalStorageService.attendanceBox)) {
        await Hive.box(LocalStorageService.attendanceBox).clear();
      }
      if (Hive.isBoxOpen(LocalStorageService.unmappedPunchesBox)) {
        await Hive.box(LocalStorageService.unmappedPunchesBox).clear();
      }
      if (Hive.isBoxOpen(LocalStorageService.crossBranchPunchesBox)) {
        await Hive.box(LocalStorageService.crossBranchPunchesBox).clear();
      }
      if (Hive.isBoxOpen(LocalStorageService.syncBox)) {
        final box = Hive.box(LocalStorageService.syncBox);
        final keysToDelete = <dynamic>[];
        for (final k in box.keys) {
          final val = box.get(k);
          if (val is Map && (val['type']?.toString().contains('attendance') == true || val['type']?.toString().contains('biometric') == true)) {
            keysToDelete.add(k);
          }
        }
        for (final k in keysToDelete) {
          await box.delete(k);
        }
      }
      if (Hive.isBoxOpen('server_sync_queue')) {
        final box = Hive.box('server_sync_queue');
        final keysToDelete = <dynamic>[];
        for (final k in box.keys) {
          final val = box.get(k);
          if (val is Map && (val['type']?.toString().contains('attendance') == true || val['type']?.toString().contains('biometric') == true)) {
            keysToDelete.add(k);
          }
        }
        for (final k in keysToDelete) {
          await box.delete(k);
        }
      }
      totalPunchesReceivedNotifier.value = 0;
      debugPrint('[ZkTecoNetworkService] 🧹 Successfully cleared all local attendance records, pending queues, and biometric cache.');
    } catch (e) {
      debugPrint('[ZkTecoNetworkService] clearAllLocalAttendanceAndPunches error: $e');
    }
  }
}

/// Helper class for reliable, multi-step ZKTeco UDP sessions without socket listener collisions
class _ZkUdpSession {
  final RawDatagramSocket socket;
  final StreamSubscription subscription;
  final StreamController<Uint8List> _controller;

  _ZkUdpSession._(this.socket, this.subscription, this._controller);

  static Future<_ZkUdpSession> create() async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final controller = StreamController<Uint8List>.broadcast();

    final sub = socket.listen((event) {
      if (event == RawSocketEvent.read) {
        final dg = socket.receive();
        if (dg != null && dg.data.isNotEmpty) {
          final raw = dg.data;
          // Strip 4-byte transport header if present
          if (raw.length > 4 && raw[0] == 0x50 && raw[1] == 0x50 && raw[2] == 0x82 && raw[3] == 0x7D) {
            controller.add(Uint8List.fromList(raw.sublist(4)));
          } else {
            controller.add(Uint8List.fromList(raw));
          }
        }
      }
    });

    return _ZkUdpSession._(socket, sub, controller);
  }

  void send(Uint8List data, String ip, int port) {
    try {
      socket.send(data, InternetAddress(ip), port);
    } catch (_) {}
  }

  Future<Uint8List?> waitForReply({Duration timeout = const Duration(seconds: 3)}) async {
    try {
      return await _controller.stream.first.timeout(timeout);
    } catch (_) {
      return null;
    }
  }

  void close() {
    subscription.cancel();
    _controller.close();
    socket.close();
  }
}

