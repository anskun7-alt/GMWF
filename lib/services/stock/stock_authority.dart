// lib/services/stock/stock_authority.dart
//
// Who may run the destructive stock tools (wipe a pool, remove medicines). Checked in the
// service itself, not only by hiding buttons, so no screen can call them for a lower role.

import '../local_storage_service.dart';
import 'stock_sync.dart';

class StockAuthority {
  StockAuthority._();

  /// Single wipe password (user decision 2026-11-21). Kept in one place only.
  static const String _wipePassword = 'admin123';

  static bool verifyWipePassword(String entered) => entered.trim() == _wipePassword;

  /// Chairman / HQ Manager / executive / system admin. Module admins (School Admin,
  /// Madrassa Admin, …) are NOT higher authority.
  static bool isHigherAuthorityRole(String? rawRole) {
    final role = (rawRole ?? '').trim().toLowerCase();
    if (role.isEmpty) return false;
    if (role.contains('school') || role.contains('madrassa') || role.contains('library')) {
      return false;
    }
    return role == 'chairman' ||
        role == 'ceo' ||
        role == 'president' ||
        role == 'founder' ||
        role == 'director' ||
        role == 'hq manager' ||
        role == 'hq_manager' ||
        role == 'hqmanager' ||
        role == 'headquarters manager' ||
        role == 'admin' ||
        role == 'super admin' ||
        role == 'super_admin' ||
        role == 'superadmin' ||
        role == 'system admin' ||
        role == 'system_admin';
  }

  /// True when this PC may wipe or remove stock: a higher-authority user, or the LAN
  /// server PC itself (its wipe panel is password-gated and physically controlled).
  static bool currentUserCanManage() =>
      StockSync.isServer || isHigherAuthorityRole(LocalStorageService.getActiveUserRole());

  /// Throws [StateError] when the current user may not run destructive stock tools.
  static void requireManage(String action) {
    if (!currentUserCanManage()) {
      throw StateError('$action is only allowed for Chairman / HQ Manager (role: '
          '${LocalStorageService.getActiveUserRole()})');
    }
  }
}
