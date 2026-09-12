// lib/services/user_module_access_service.dart
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

class UserModuleAccessService {
  static final UserModuleAccessService _instance = UserModuleAccessService._internal();
  factory UserModuleAccessService() => _instance;
  UserModuleAccessService._internal();

  static const String boxName = 'local_user_module_access';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox(boxName);
    }
  }

  static Box get _box => Hive.box(boxName);

  /// Key format: `${userId}_${moduleId}`
  static String _key(String userId, String moduleId) => '${userId.trim()}_${moduleId.trim()}';

  /// Blocks or unblocks a specific module for a specific user.
  /// RULE: Only Chairman can perform this, and Chairman account can NEVER be blocked.
  static Future<void> setModuleAccessForUser({
    required String userId,
    required String moduleId,
    required bool isBlocked,
    required String performedBy,
    String targetRole = '',
  }) async {
    // Chairman account cannot be blocked under any circumstances
    if (targetRole.toLowerCase().trim() == 'chairman') {
      debugPrint('[UserModuleAccessService] REJECTED: Chairman account cannot be restricted.');
      return;
    }
    await init();
    final key = _key(userId, moduleId);
    if (isBlocked) {
      await _box.put(key, {
        'userId': userId,
        'moduleId': moduleId,
        'isBlocked': true,
        'blockedBy': performedBy,
        'updatedAt': DateTime.now().toIso8601String(),
      });
    } else {
      await _box.delete(key);
    }
    debugPrint('[UserModuleAccessService] User $userId module $moduleId set to isBlocked: $isBlocked by $performedBy');
  }

  /// Checks if a module is explicitly blocked for a user by Chairman.
  static bool isModuleBlockedForUser(String userId, String moduleId, {String userRole = ''}) {
    final cr = userRole.toLowerCase().trim();
    if (cr == 'chairman' || cr == 'ceo' || cr == 'hq manager' || cr == 'hq_manager' || cr == 'admin' || cr == 'global admin' || cr == 'director') {
      return false;
    }
    if (!Hive.isBoxOpen(boxName)) return false;
    final val = _box.get(_key(userId, moduleId));
    if (val is Map) {
      return val['isBlocked'] == true;
    }
    return false;
  }

  /// Primary access check used by Navigation, Dashboard, and Module Wrappers.
  /// 
  /// RULES:
  /// 1. CHAIRMAN & CEO ARE ALWAYS UNRESTRICTED.
  /// 2. If explicitly blocked for `userId`, returns `false`.
  /// 3. Global Admin / CEO / HQ Manager default access.
  /// 4. Fallbacks to default role permissions.
  static bool canUserAccessModule({
    required String userId,
    required String role,
    required String moduleId,
  }) {
    final cleanRole = role.toLowerCase().trim();

    // RULE 1: Chairman, CEO, Admin and Global Admin have full executive authority
    if (cleanRole == 'chairman' || cleanRole == 'ceo' || cleanRole == 'global admin' || cleanRole == 'admin') {
      return true;
    }

    // RULE 2: Explicit Chairman User-level Block check (leadership roles are exempted)
    if (userId.isNotEmpty && isModuleBlockedForUser(userId, moduleId, userRole: cleanRole)) {
      return false;
    }

    // RULE 2.5: HQ Manager specific exclusions (Server Control only - Food Tokens / Office Boy is fully permitted)
    if (cleanRole == 'hq manager' || cleanRole == 'hq_manager' || cleanRole == 'headquarters manager' || cleanRole == 'hqmanager' || cleanRole == 'hq') {
      final mod = moduleId.toLowerCase().trim();
      if (mod == 'server_sync' || mod == 'server') {
        return false;
      }
      // HQ Manager has full access to Food Tokens / Office Boy
      if (mod == 'office_boy' || mod == 'office boy' || mod == 'officeboy') {
        return true;
      }
    }

    // RULE 3: Global Admin / CEO / HQ Manager default access
    if (cleanRole == 'global admin' || cleanRole == 'admin' || cleanRole == 'ceo' || cleanRole == 'hq manager') {
      return true;
    }

    // RULE 4: Global Accounts module rules
    if (cleanRole == 'global accounts') {
      if (moduleId == 'office_finance' || moduleId == 'finance' || moduleId == 'payroll' || moduleId == 'donations') {
        return true;
      }
    }

    // Module-specific role defaults
    switch (moduleId) {
      case 'office_finance':
      case 'finance':
      case 'payroll':
      case 'employee_attendance':
      case 'employees':
      case 'cash_flow':
      case 'loans':
      case 'expenses':
      case 'finance_reports':
        return ['chairman', 'ceo', 'admin', 'global admin', 'hq manager', 'branch manager', 'global accounts'].contains(cleanRole);
      case 'dispensary':
      case 'med_ledger':
      case 'medicine_ledger':
        return ['chairman', 'ceo', 'admin', 'global admin', 'doctor', 'dispenser', 'receptionist', 'rec+dis', 'doc+rec', 'doc+dis', 'doc+rec+dis', 'branch manager', 'supervisor'].contains(cleanRole);
      case 'madrassa':
        return ['chairman', 'ceo', 'admin', 'global admin', 'madrassa admin', 'madrassa teacher', 'madrassa guardian', 'branch manager', 'supervisor'].contains(cleanRole);
      case 'school':
        return ['chairman', 'ceo', 'admin', 'global admin', 'principal', 'school admin', 'school teacher', 'branch manager'].contains(cleanRole);
      case 'office_boy':
      case 'dasterkhwaan':
      case 'dasterkhwaan_food_log':
      case 'kitchen':
        return ['chairman', 'ceo', 'admin', 'global admin', 'server', 'office boy', 'kitchen', 'branch manager', 'supervisor', 'hq manager', 'manager'].contains(cleanRole);
      case 'donations':
        return ['chairman', 'ceo', 'admin', 'global admin', 'donations', 'office boy', 'global accounts', 'branch manager', 'hq manager', 'manager'].contains(cleanRole);
      default:
        return true;
    }
  }

  /// Check if actor role can open and use Master Access Control Matrix (Chairman ONLY)
  static bool canAccessMasterControlMatrix(String role) {
    return role.toLowerCase().trim() == 'chairman';
  }

  /// Check if actor role can block, edit, demote, suspend, or remove a target user account.
  /// RULES:
  /// - Target is Chairman: CAN NEVER be edited, blocked, restricted, demoted, suspended, or removed by ANY user/role.
  /// - Only Chairman actor can manage other accounts. Non-Chairman actors return false.
  static bool canActorManageUserAccount({
    required String actorRole,
    required String targetRole,
  }) {
    final cleanTarget = targetRole.toLowerCase().trim();
    if (cleanTarget == 'chairman') {
      return false; // Chairman is 100% immutable to everyone
    }
    final cleanActor = actorRole.toLowerCase().trim();
    return cleanActor == 'chairman'; // Only Chairman can manage user accounts
  }

  /// System Modules List
  static const List<Map<String, String>> systemModules = [
    {'id': 'office_finance', 'name': 'Finance & Payroll ERP', 'category': 'Office'},
    {'id': 'dispensary', 'name': 'Dispensary & Patients', 'category': 'Medical'},
    {'id': 'medicine_ledger', 'name': 'Medicine Stock Ledger', 'category': 'Medical'},
    {'id': 'madrassa', 'name': 'Madrassa Education System', 'category': 'Education'},
    {'id': 'school', 'name': 'School Management System', 'category': 'Education'},
    {'id': 'dasterkhwaan', 'name': 'Dasterkhwaan Food Distribution', 'category': 'Welfare'},
    {'id': 'donations', 'name': 'Donations & Receipts', 'category': 'Welfare'},
  ];

  /// Role Default Access Map for Chairman Visual Audit
  static Map<String, List<String>> getRoleDefaultsMap() {
    return {
      '1. Chairman': ['100% Unrestricted & Immutable Access across all modules, branches, ledgers, and system settings'],
      '2. Global Admin': ['Finance & Payroll', 'Dispensary & Patients', 'Medicine Ledger', 'Madrassa System', 'School System', 'Dasterkhwaan', 'Donations', 'User Management', 'Executive Dashboard'],
      '3. CEO': ['Finance & Payroll', 'Dispensary & Patients', 'Medicine Ledger', 'Madrassa System', 'School System', 'Dasterkhwaan', 'Donations', 'Executive Dashboard'],
      '4. Global Accounts': ['Finance & Payroll', 'Donations', 'Financial Reports'],
      '5. HQ Manager': ['Multi-branch operational oversight', 'Finance', 'Dispensary', 'Madrassa', 'School', 'Dasterkhwaan', 'Donations'],
      '6. Branch Manager': ['Assigned Branch Only: Finance', 'Dispensary', 'Medicine Ledger', 'Madrassa', 'School', 'Dasterkhwaan', 'Donations'],
      '7. Supervisor': ['Assigned Branch Only: Dispensary', 'Medicine Ledger', 'Madrassa', 'Dasterkhwaan'],
      '8. Doctor / Dispenser': ['Dispensary & Patients', 'Medicine Stock Ledger', 'Prescriptions'],
      '9. Madrassa / School Admin': ['Education Module Admin', 'Attendance & Daily Logs'],
      '10. Donations / Office Boy': ['Welfare & Donation Operations', 'Food Tokens'],
    };
  }
}
