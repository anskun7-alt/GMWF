// lib/services/network_health_service.dart

import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

enum NetworkQualityState { onlineStable, onlineUnstable, offline }

class NetworkHealthService {
  static final NetworkHealthService _instance = NetworkHealthService._internal();
  factory NetworkHealthService() => _instance;
  NetworkHealthService._internal();

  final _healthController = StreamController<NetworkQualityState>.broadcast();
  Stream<NetworkQualityState> get onHealthChanged => _healthController.stream;

  NetworkQualityState _currentState = NetworkQualityState.onlineStable;
  NetworkQualityState get currentState => _currentState;

  bool get isStableOnline => _currentState == NetworkQualityState.onlineStable;
  bool get isUnstableOrOffline => _currentState != NetworkQualityState.onlineStable;
  bool get isOffline => _currentState == NetworkQualityState.offline;

  Timer? _pingTimer;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  int _consecutiveStablePings = 0;
  bool _isChecking = false;

  void start() {
    _connSub?.cancel();
    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      final hasInterface = results.any((r) => r != ConnectivityResult.none);
      if (!hasInterface) {
        _updateState(NetworkQualityState.offline);
      } else {
        checkHealthNow();
      }
    });

    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 10), (_) => checkHealthNow());
    checkHealthNow();
  }

  void stop() {
    _pingTimer?.cancel();
    _connSub?.cancel();
  }

  Future<void> checkHealthNow() async {
    if (_isChecking) return;
    _isChecking = true;

    try {
      final results = await Connectivity().checkConnectivity();
      final hasInterface = results.any((r) => r != ConnectivityResult.none);

      final isDesktop = !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
      if (!hasInterface && !isDesktop) {
        _consecutiveStablePings = 0;
        _updateState(NetworkQualityState.offline);
        return;
      }

      final isPingOk = await _pingHighAvailabilityHost();

      if (isPingOk) {
        _consecutiveStablePings++;
        // Debounce: require 2 consecutive stable pings (~10s window) to promote to onlineStable
        if (_consecutiveStablePings >= 2 || _currentState == NetworkQualityState.onlineStable) {
          _updateState(NetworkQualityState.onlineStable);
        }
      } else {
        _consecutiveStablePings = 0;
        _updateState(NetworkQualityState.onlineUnstable);
      }
    } catch (e) {
      debugPrint('[NetworkHealthService] Health check exception: $e');
      _consecutiveStablePings = 0;
      _updateState(NetworkQualityState.onlineUnstable);
    } finally {
      _isChecking = false;
    }
  }

  Future<bool> _pingHighAvailabilityHost() async {
    try {
      if (kIsWeb) return true; // Web browsers handle HTTP timeouts natively

      final stopwatch = Stopwatch()..start();
      final result = await Socket.connect('8.8.8.8', 53, timeout: const Duration(milliseconds: 2500))
          .then((socket) {
            socket.destroy();
            return true;
          })
          .catchError((_) => false);

      stopwatch.stop();

      // If ping took more than 2200ms, mark as unstable due to high latency
      if (result && stopwatch.elapsedMilliseconds > 2200) {
        debugPrint('[NetworkHealthService] High latency detected: ${stopwatch.elapsedMilliseconds}ms');
        return false;
      }

      return result;
    } catch (_) {
      return false;
    }
  }

  void _updateState(NetworkQualityState newState) {
    if (_currentState != newState) {
      debugPrint('[NetworkHealthService] State transition: $_currentState ➔ $newState');
      _currentState = newState;
      if (!_healthController.isClosed) {
        _healthController.add(newState);
      }
    }
  }
}
