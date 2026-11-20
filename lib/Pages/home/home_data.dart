// lib/pages/home/home_data.dart
//
// One shared copy of the home snapshot, so the dashboard and the category
// overview pages show the same live numbers without loading twice.
// Same pipeline as before: local Hive figures first (instant), then the
// cloud-merged ones.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../widgets/home_snapshot_widgets.dart'
    show SnapshotDashboardData, buildLocalSnapshotDashboardData, fetchSnapshotDashboardData;

class HomeSnapshot extends ChangeNotifier {
  HomeSnapshot._();
  static final HomeSnapshot instance = HomeSnapshot._();

  SnapshotDashboardData? data;
  Object? error;
  bool refreshing = false;
  DateTime updatedAt = DateTime.now();
  String? _key;
  bool _cloudLoaded = false;

  static String keyOf(Map<String, dynamic> u) =>
      '${u['role'] ?? ''}|${u['branchId'] ?? ''}|${u['uid'] ?? u['id'] ?? ''}'.toLowerCase();

  void _set(SnapshotDashboardData d) {
    data = d;
    error = null;
    updatedAt = DateTime.now();
    notifyListeners();
  }

  /// Loads once per user; later calls are free. Safe to call from build paths.
  void ensure(Map<String, dynamic> userData) {
    final key = keyOf(userData);
    if (key == _key) return;
    _key = key;
    data = null;
    error = null;
    _cloudLoaded = false;
    buildLocalSnapshotDashboardData(userData).then((d) {
      if (_key == key && !_cloudLoaded) _set(d);
    }).catchError((Object e) {
      if (_key == key && data == null) {
        error = e;
        notifyListeners();
      }
    });
    Future.delayed(const Duration(milliseconds: 600), () => _cloud(userData, key));
  }

  Future<void> _cloud(Map<String, dynamic> userData, String key) async {
    try {
      final d = await fetchSnapshotDashboardData(userData);
      if (_key != key) return;
      _cloudLoaded = true;
      _set(d);
    } catch (_) {}
  }

  /// Cloud-merged refetch (Refresh button, pull to refresh).
  Future<void> refresh(Map<String, dynamic> userData) async {
    final key = keyOf(userData);
    _key = key;
    refreshing = true;
    notifyListeners();
    await _cloud(userData, key);
    refreshing = false;
    notifyListeners();
  }
}
