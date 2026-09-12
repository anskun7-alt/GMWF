// lib/models/module_registry.dart
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../services/permission_service.dart';
import '../pages/dispensary/receptionist/receptionist_screen.dart';
import '../pages/dispensary/doctor/doctor_screen.dart';
import '../pages/dispensary/dispensar/dispensar_screen.dart';
import '../pages/dispensary/dispensar/inventory.dart';
import '../pages/dispensary/dispensar/universal_proforma_sheet.dart';
import '../pages/dispensary/dispensar/medicine_ledger.dart';
import '../pages/donations/donations_screen.dart';
import '../pages/donations/donations_shared.dart';
import '../pages/branches.dart';

import '../pages/server.dart';
import '../pages/download_screen.dart';
import '../pages/office/finance_page.dart';
import '../pages/office/branches_management.dart';
import '../pages/Dasterkhwaan/office_boy.dart';
import '../pages/Dasterkhwaan/kitchen.dart';
import '../pages/Dasterkhwaan/stock.dart';
import '../pages/dasterkhwaan/food_log_screen.dart';
import '../pages/branches_register.dart';
import '../pages/register.dart';
import '../pages/dispensary/patient_detail_screen.dart';
import '../pages/dispensary/receptionist/patient_register.dart';
import '../pages/overview.dart';
import '../pages/request.dart';
import '../pages/madrassa/madrassa_dashboard.dart';
import '../pages/madrassa/madrassa_guardian_screen.dart';
import '../pages/school/school_dashboard.dart';
import '../pages/welfare/ramadan_welfare_screen.dart';
import '../pages/users.dart';

enum ModuleCategory {
  office,
  dispensary,
  dasterkhwaan,
  madrassa,
  school,
}

class AppModule {
  final String id;
  final String title;
  final String description;
  final IconData icon;
  final AppPermission? requiredPermission;
  final Widget Function(BuildContext context, Map<String, dynamic> userData) builder;
  final bool isBranchDependent; // Whether the module requires a specific branch context
  final bool supportsGlobalWrapper; // Whether to use the unified GlobalModuleWrapper
  final ModuleCategory category;
  /// When true, this module is hidden from pure-executive dashboards
  /// (CEO, Admin, Chairman, HQ Manager, Manager, Global Admin).
  /// These are operational-role modules that executives have no need to open.
  final bool hideFromExecutives;
  final bool isFeatured;

  AppModule({
    required this.id,
    required this.title,
    required this.description,
    required this.icon,
    this.requiredPermission,
    required this.builder,
    this.isBranchDependent = false,
    this.supportsGlobalWrapper = true,
    this.category = ModuleCategory.office,
    this.hideFromExecutives = false,
    this.isFeatured = false,
  });

  AppModule copyWith({
    String? id,
    String? title,
    String? description,
    IconData? icon,
    AppPermission? requiredPermission,
    Widget Function(BuildContext context, Map<String, dynamic> userData)? builder,
    bool? isBranchDependent,
    bool? supportsGlobalWrapper,
    ModuleCategory? category,
    bool? hideFromExecutives,
    bool? isFeatured,
  }) {
    return AppModule(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      icon: icon ?? this.icon,
      requiredPermission: requiredPermission ?? this.requiredPermission,
      builder: builder ?? this.builder,
      isBranchDependent: isBranchDependent ?? this.isBranchDependent,
      supportsGlobalWrapper: supportsGlobalWrapper ?? this.supportsGlobalWrapper,
      category: category ?? this.category,
      hideFromExecutives: hideFromExecutives ?? this.hideFromExecutives,
      isFeatured: isFeatured ?? this.isFeatured,
    );
  }
}

class ModuleRegistry {
  static final List<AppModule> allModules = [
    // ── OFFICE MODULES (Exact Hierarchy Sequence) ──
    // 1. Finance Overview
    AppModule(
      id: 'finance',
      title: 'Finance Overview',
      description: 'Comprehensive financial health, ledger summaries, cash flow & budget tracking',
      icon: Icons.monetization_on_outlined,
      requiredPermission: AppPermission.manageFinance,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      isFeatured: true,
      builder: (context, data) => CashFlowPage(
        branchId: data['branchId'] ?? 'all',
        isAdmin: true,
      ),
      category: ModuleCategory.office,
    ),

    // 2. Donations
    AppModule(
      id: 'donations',
      title: 'Donations',
      description: 'Track and manage charitable contributions',
      icon: Icons.volunteer_activism_outlined,
      requiredPermission: AppPermission.viewDonations,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      builder: (context, data) => DonationsScreen.embedded(
        branchId: data['branchId'] ?? 'all',
        username: data['name'] ?? 'User',
        userId:   data['uid'] ?? '',
        role:     UserRoleX.fromString(data['role'] ?? 'staff'),
      ),
      category: ModuleCategory.office,
      isFeatured: true,
    ),

    // 3. Branches Management
    AppModule(
      id: 'branches_management',
      title: 'Branches Management',
      description: 'Register, edit sub-facilities, and manage all organization branches',
      icon: Icons.domain_rounded,
      requiredPermission: AppPermission.viewBranchSpecificStats,
      isFeatured: true,
      builder: (context, data) {
        return BranchesManagementPage(
          currentUserRole: data['role']?.toString(),
          userBranchId: data['branchId']?.toString(),
        );
      },
      category: ModuleCategory.office,
    ),

    // 4. User Management
    AppModule(
      id: 'users',
      title: 'User Management',
      description: 'Manage system users, roles, permissions, and online status',
      icon: Icons.people_alt_rounded,
      requiredPermission: AppPermission.manageUsers,
      isFeatured: false,
      builder: (context, data) {
        final role = (data['role'] as String? ?? '').toLowerCase().trim();
        final userBranch = (data['branchId'] as String? ?? '').toLowerCase().trim();
        final isGlobalExec = ['chairman', 'ceo', 'admin', 'administrator', 'super admin', 'global admin', 'hq manager', 'president', 'founder'].contains(role) && (userBranch == 'all' || userBranch == 'global' || userBranch.isEmpty);
        final isScoped = !isGlobalExec;
        return UsersScreen(
          branchId: isScoped ? userBranch : 'all',
          currentUserRole: data['role']?.toString(),
        );
      },
      category: ModuleCategory.office,
    ),

    // 5. Employee Management (Unified Directory & Attendance)
    AppModule(
      id: 'employees',
      title: 'Employee Management',
      description: 'Staff directory, profile management, onboarding, calendar attendance & sync',
      icon: Icons.badge_outlined,
      requiredPermission: AppPermission.manageFinance,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      isFeatured: true,
      builder: (context, data) => EmployeeManagementPage(
        branchId: data['branchId'] ?? 'all',
        isAdmin: true,
      ),
      category: ModuleCategory.office,
    ),

    // 7. Register Staff
    AppModule(
      id: 'register_user',
      title: 'Register Staff',
      description: 'Onboard new staff, assign branch, role, salary, and facilities',
      icon: Icons.person_add_alt_1_rounded,
      requiredPermission: AppPermission.manageUsers,
      isFeatured: true,
      builder: (context, data) {
        return const Register();
      },
      category: ModuleCategory.office,
    ),

    // 9. Ramadan Rations & Libaas
    AppModule(
      id: 'ramadan_welfare',
      title: 'Ramadan Rations & Libaas',
      description: 'Welfare data entry, CNIC scanner & dynamic winner lucky draw',
      icon: Icons.card_giftcard_rounded,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      isFeatured: false,
      builder: (context, data) => RamadanWelfareScreen(
        branchId: data['branchId'] ?? 'sialkot',
      ),
      category: ModuleCategory.office,
    ),

    // 10. Downloads
    AppModule(
      id: 'reports',
      title: 'Downloads',
      description: 'Generate and export operational data',
      icon: Icons.cloud_download_rounded,
      requiredPermission: AppPermission.downloadData,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      builder: (context, data) {
        final role = (data['role'] as String? ?? '').toLowerCase();
        final isScoped = role == 'branch manager' || role == 'supervisor';
        return DownloadScreen(
          lockedBranchId: isScoped ? (data['branchId'] as String?) : null,
        );
      },
      category: ModuleCategory.office,
    ),

    // 11. Branch Registration (Chairman Only)
    AppModule(
      id: 'register_branch',
      title: 'Register New Branch',
      description: 'Setup and configure new organizational branches (Chairman Only)',
      icon: Icons.add_business_rounded,
      requiredPermission: AppPermission.manageBranches,
      isBranchDependent: false,
      supportsGlobalWrapper: true,
      builder: (context, data) => const BranchesRegister(),
      category: ModuleCategory.office,
    ),

    // 12. Cash Flow & Treasury
    AppModule(
      id: 'cash_flow',
      title: 'Cash Flow & Treasury',
      description: 'Live double-entry general ledger summary, cash flow, audit logs & system history',
      icon: Icons.account_balance_wallet_outlined,
      requiredPermission: AppPermission.manageFinance,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      isFeatured: true,
      builder: (context, data) => CashFlowPage(
        branchId: data['branchId'] ?? 'all',
        isAdmin: true,
      ),
      category: ModuleCategory.office,
    ),

    // 13. Payroll
    AppModule(
      id: 'payroll',
      title: 'Payroll',
      description: 'Monthly payroll, salary breakdown, pay slips & disbursements',
      icon: Icons.payments_outlined,
      requiredPermission: AppPermission.manageFinance,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      isFeatured: true,
      builder: (context, data) => PayrollPage(
        branchId: data['branchId'] ?? 'all',
        isAdmin: true,
      ),
      category: ModuleCategory.office,
    ),

    // 14. Loans & Advances
    AppModule(
      id: 'loans',
      title: 'Loans & Advances',
      description: 'Employee salary advances, loans, installment plans & balances',
      icon: Icons.credit_card_outlined,
      requiredPermission: AppPermission.manageFinance,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      builder: (context, data) => LoansPage(
        branchId: data['branchId'] ?? 'all',
        isAdmin: true,
      ),
      category: ModuleCategory.office,
    ),

    // 15. Expenses
    AppModule(
      id: 'expenses',
      title: 'Expenses',
      description: 'Organizational operational expense vouchers & category tracking',
      icon: Icons.receipt_long_outlined,
      requiredPermission: AppPermission.manageFinance,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      builder: (context, data) => ExpensesPage(
        branchId: data['branchId'] ?? 'all',
        isAdmin: true,
      ),
      category: ModuleCategory.office,
    ),

    // 16. Finance Reports & Reconcile
    AppModule(
      id: 'finance_reports',
      title: 'Finance Reports & Reconcile',
      description: 'General ledger reports, bank reconciliations & custom exports',
      icon: Icons.assessment_outlined,
      requiredPermission: AppPermission.manageFinance,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      builder: (context, data) => FinanceReportsPage(
        branchId: data['branchId'] ?? 'all',
        isAdmin: true,
      ),
      category: ModuleCategory.office,
    ),

    // 17. Server Control
    AppModule(
      id: 'server_sync',
      title: 'Server Control',
      description: 'System-wide data synchronization and monitoring',
      icon: Icons.dns_rounded,
      requiredPermission: AppPermission.viewExecutiveDashboard,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      builder: (context, data) => ServerDashboardWithSync(
        branchId: data['branchId'] ?? 'unknown',
      ),
      category: ModuleCategory.office,
    ),

    // ── DISPENSARY / MEDICAL MODULES ──
    AppModule(
      id: 'branches',
      title: 'Branches Summary',
      description: 'Manage and monitor all branch activities',
      icon: Icons.account_balance_outlined,
      requiredPermission: AppPermission.viewBranchSpecificStats,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      builder: (context, data) {
        final role = (data['role'] as String? ?? '').toLowerCase().trim();
        final userBranch = (data['branchId'] as String? ?? '').toLowerCase().trim();
        final isGlobalExec = ['chairman', 'ceo', 'admin', 'administrator', 'super admin', 'global admin', 'hq manager', 'president', 'founder'].contains(role) && (userBranch == 'all' || userBranch == 'global' || userBranch.isEmpty);
        final isScoped = !isGlobalExec;
        return Branches(
          branchId: isScoped ? userBranch : null,
          isManager: isScoped,
        );
      },
      category: ModuleCategory.dispensary,
      isFeatured: true,
    ),
    AppModule(
      id: 'patients_registration',
      title: 'Reception',
      description: 'Patient onboarding and token issuance',
      icon: Icons.person_add_rounded,
      requiredPermission: AppPermission.registerPatients,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      hideFromExecutives: true,
      builder: (context, data) => ReceptionistScreen(
        branchId: data['branchId'] ?? 'unknown',
        receptionistId: data['uid'] ?? 'unknown',
        receptionistName: data['name'] ?? 'User',
        isEmbedded: true,
      ),
      category: ModuleCategory.dispensary,
    ),
    AppModule(
      id: 'doctor_consultation',
      title: 'Doctor',
      description: 'Clinical consultations and prescriptions',
      icon: Icons.medical_services_outlined,
      requiredPermission: AppPermission.prescribeMedicine,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      hideFromExecutives: true,
      builder: (context, data) => DoctorScreen(
        branchId: data['branchId'] ?? 'unknown',
        doctorId: data['uid'] ?? 'unknown',
        doctorName: data['name'] ?? 'User',
        isEmbedded: true,
      ),
      category: ModuleCategory.dispensary,
    ),
    AppModule(
      id: 'pharmacy',
      title: 'Dispensary',
      description: 'Medicine inventory and dispensing records',
      icon: Icons.medication_outlined,
      requiredPermission: AppPermission.dispenseMedicine,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      hideFromExecutives: true,
      builder: (context, data) => DispensarScreen(
        branchId: data['branchId'] ?? 'unknown',
        isEmbedded: true,
      ),
      category: ModuleCategory.dispensary,
    ),
    AppModule(
      id: 'inventory',
      title: 'Med Inventory',
      description: 'Manage clinical stock and medicine adjustments',
      icon: Icons.medication_liquid_rounded,
      requiredPermission: AppPermission.manageInventory,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      isFeatured: true,
      builder: (context, data) => InventoryPage(
        branchId: data['branchId'] ?? 'unknown',
      ),
      category: ModuleCategory.dispensary,
    ),
    AppModule(
      id: 'medicine_proforma',
      title: 'Medicine Proforma',
      description: 'Master medicine catalog — register, edit, and audit medicines',
      icon: Icons.list_alt_rounded,
      requiredPermission: AppPermission.manageInventory,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      isFeatured: true,
      builder: (context, data) {
        final role = (data['role'] as String? ?? '').toLowerCase().trim();
        final isAdminRole = ['chairman', 'ceo', 'admin', 'administrator', 'super admin', 'global admin', 'hq manager', 'president', 'founder'].contains(role);
        return UniversalProformaSheetPage(
          branchId: data['branchId'] ?? 'unknown',
          isDispenser: false,
          isAdmin: isAdminRole,
          isEmbedded: true,
        );
      },
      category: ModuleCategory.dispensary,
    ),
    AppModule(
      id: 'inventory_ledger',
      title: 'Medicine Ledger',
      description: 'Track complete history of medicine stock and dispensing',
      icon: Icons.receipt_long_rounded,
      requiredPermission: AppPermission.manageInventory,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      builder: (context, data) => MedicineLedgerPage(
        branchId: data['branchId'] ?? 'unknown',
        isEmbedded: true,
      ),
      category: ModuleCategory.dispensary,
    ),
    AppModule(
      id: 'pending_requests',
      title: 'Requests & Reversals',
      description: 'Review and approve operational requests',
      icon: Icons.rule_rounded,
      requiredPermission: AppPermission.reverseTokens,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      builder: (context, data) => RequestPage(
        branchId: data['branchId'] ?? 'unknown',
        isSupervisor: (data['role'] as String? ?? '').toLowerCase() == 'supervisor',
      ),
      category: ModuleCategory.dispensary,
    ),
    AppModule(
      id: 'patients_list',
      title: 'Patients',
      description: 'Complete patient medical records database',
      icon: Icons.favorite_border_rounded,
      requiredPermission: AppPermission.viewPatients,
      isBranchDependent: false,
      supportsGlobalWrapper: true,
      builder: (context, data) {
        final role = (data['role'] as String? ?? '').toLowerCase().trim();
        final isRestricted = role == 'branch manager' || role == 'supervisor';
        return UsersScreen(
          isPatientMode: true, 
          branchId: isRestricted ? data['branchId'] : null,
        );
      },
      category: ModuleCategory.dispensary,
    ),
    AppModule(
      id: 'patient_register_standalone',
      title: 'Patient Registration',
      description: 'Independent patient registration entry',
      icon: Icons.app_registration_rounded,
      requiredPermission: AppPermission.registerPatients,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      hideFromExecutives: true,
      builder: (context, data) => PatientRegisterPage(
        branchId: data['branchId'] ?? 'unknown',
        receptionistId: data['uid'] ?? 'unknown',
      ),
      category: ModuleCategory.dispensary,
    ),
    AppModule(
      id: 'patient_details',
      title: 'Patient Records',
      description: 'Search and view detailed patient medical history',
      icon: Icons.assignment_ind_rounded,
      requiredPermission: AppPermission.viewPatients,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      hideFromExecutives: true,
      builder: (context, data) => PatientDetailScreen(
        patientId: '',
        isOnline: true,
        localBox: Hive.box('local'),
        branchId: data['branchId'] ?? 'unknown',
        doctorId: data['uid'] ?? 'unknown',
        isAdmin: true,
      ),
      category: ModuleCategory.dispensary,
    ),

    // ── DASTERKHWAAN MODULES ──
    AppModule(
      id: 'office_boy',
      title: 'Food Tokens',
      description: 'Dasterkhwaan food token issuing and meal management',
      icon: Icons.confirmation_number_rounded,
      requiredPermission: AppPermission.generateFoodTokens,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      isFeatured: true,
      builder: (context, data) => DasterkhwaanOfficeBoy(
        branchId: data['branchId'] ?? 'unknown',
        userName: data['name'] ?? 'User',
        role: data['role'] ?? 'Food Tokens',
      ),
      category: ModuleCategory.dasterkhwaan,
    ),
    AppModule(
      id: 'kitchen',
      title: 'Kitchen',
      description: 'Monitor kitchen activities and supply status',
      icon: Icons.kitchen_rounded,
      requiredPermission: AppPermission.manageKitchen,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      builder: (context, data) => DasterkhwaanKitchen(
        branchId: data['branchId'] ?? 'all',
        username: data['name'] ?? 'Executive',
      ),
      category: ModuleCategory.dasterkhwaan,
    ),
    AppModule(
      id: 'dasterkhwaan_inventory',
      title: 'Dasterkhwaan Inventory',
      description: 'Manage Dasterkhwaan kitchen supplies and stock',
      icon: Icons.inventory_2_outlined,
      requiredPermission: AppPermission.manageKitchen,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      builder: (context, data) => DasterkhwaanStock(
        branchId: data['branchId'] ?? 'all',
      ),
      category: ModuleCategory.dasterkhwaan,
    ),
    AppModule(
      id: 'dasterkhwaan_food_log',
      title: 'Food Log',
      description: 'Track daily food prepared by cook or received from outside hotels',
      icon: Icons.restaurant_menu_rounded,
      requiredPermission: AppPermission.manageKitchen,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      isFeatured: true,
      builder: (context, data) => DasterkhwaanFoodLogScreen(
        branchId: data['branchId'] ?? 'all',
        userName: data['name'] ?? 'Staff',
      ),
      category: ModuleCategory.dasterkhwaan,
    ),

    // ── MADRASSA MODULES ──
    AppModule(
      id: 'madrassa',
      title: 'Madrassa',
      description: 'Daily attendance, student management, and financials',
      icon: Icons.menu_book_rounded,
      requiredPermission: AppPermission.manageMadrassa,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      builder: (context, data) {
        final branchId = data['branchId'] ?? 'unknown';
        final username = data['name'] ?? data['username'] ?? 'User';
        final role = (data['role'] as String? ?? 'madrassa admin').toLowerCase();
        final isAdmin = role.contains('admin') ||
            role.contains('principal') ||
            role.contains('chairman') ||
            role.contains('ceo') ||
            role.contains('hq') ||
            role.contains('manager') ||
            role.contains('supervisor');
        return MadrassaDashboard(branchId: branchId, username: username, role: role, isAdmin: isAdmin);
      },
      category: ModuleCategory.madrassa,
      isFeatured: true,
    ),
    AppModule(
      id: 'madrassa_guardian',
      title: 'Guardian Portal',
      description: 'View children progress reports, attendance calendars and accountability',
      icon: Icons.family_restroom_rounded,
      requiredPermission: AppPermission.viewMadrassaParent,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      isFeatured: true,
      builder: (context, data) {
        return MadrassaGuardianScreen(userData: data);
      },
      category: ModuleCategory.madrassa,
    ),

    // ── SCHOOL MODULES ──
    AppModule(
      id: 'school_module',
      title: 'Taleem-wa-Tarbiyat School',
      description: 'Taleem-wa-Tarbiyat School System dashboard overview, admissions, and analytics (GMWF)',
      icon: Icons.school_rounded,
      requiredPermission: AppPermission.manageSchool,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      isFeatured: true,
      builder: (context, data) => SchoolDashboard(
        branchId: data['branchId'] ?? 'all',
        username: data['name'] ?? data['username'] ?? 'User',
        role: data['role'] ?? 'School Admin',
        initialTabIndex: 0,
      ),
      category: ModuleCategory.school,
    ),
    AppModule(
      id: 'school_attendance',
      title: 'Student Attendance',
      description: 'Daily student attendance log and uniform tracking',
      icon: Icons.how_to_reg_rounded,
      requiredPermission: AppPermission.manageSchool,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      isFeatured: true,
      builder: (context, data) => SchoolDashboard(
        branchId: data['branchId'] ?? 'all',
        username: data['name'] ?? data['username'] ?? 'User',
        role: data['role'] ?? 'School Admin',
        initialTabIndex: 1,
      ),
      category: ModuleCategory.school,
    ),
    AppModule(
      id: 'school_teacher_attendance',
      title: 'Faculty Attendance',
      description: 'Daily faculty attendance, check-in tracking, and leave management',
      icon: Icons.co_present_rounded,
      requiredPermission: AppPermission.manageSchoolAdmin,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      isFeatured: true,
      builder: (context, data) => SchoolDashboard(
        branchId: data['branchId'] ?? 'all',
        username: data['name'] ?? data['username'] ?? 'User',
        role: data['role'] ?? 'School Admin',
        initialTabIndex: 2,
      ),
      category: ModuleCategory.school,
    ),
    AppModule(
      id: 'school_students',
      title: 'School Admissions',
      description: 'Register and manage student profiles and academic streams',
      icon: Icons.groups_rounded,
      requiredPermission: AppPermission.manageSchool,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      builder: (context, data) => SchoolDashboard(
        branchId: data['branchId'] ?? 'all',
        username: data['name'] ?? data['username'] ?? 'User',
        role: data['role'] ?? 'School Admin',
        initialTabIndex: 3,
      ),
      category: ModuleCategory.school,
    ),
    AppModule(
      id: 'school_teachers',
      title: 'School Faculty',
      description: 'Teacher staff registry, departments, and class assignments',
      icon: Icons.record_voice_over_rounded,
      requiredPermission: AppPermission.manageSchoolAdmin,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      builder: (context, data) => SchoolDashboard(
        branchId: data['branchId'] ?? 'all',
        username: data['name'] ?? data['username'] ?? 'User',
        role: data['role'] ?? 'School Admin',
        initialTabIndex: 4,
      ),
      category: ModuleCategory.school,
    ),
    AppModule(
      id: 'school_library',
      title: 'School Library',
      description: 'Book catalog, issue/return records, and overdue tracking',
      icon: Icons.local_library_rounded,
      requiredPermission: AppPermission.manageSchoolLibrary,
      isBranchDependent: true,
      supportsGlobalWrapper: true,
      isFeatured: true,
      builder: (context, data) => SchoolDashboard(
        branchId: data['branchId'] ?? 'all',
        username: data['name'] ?? data['username'] ?? 'User',
        role: data['role'] ?? 'School Admin',
        initialTabIndex: 5,
      ),
      category: ModuleCategory.school,
    ),
  ];

  static List<AppModule> getAvailableModules(String role) {
    final ps = PermissionService();
    final normalizedRole = role.toLowerCase().trim();

    // 1. Initial filter based on permissions
    var modules = allModules.where((m) {
      if (m.requiredPermission == null) return true;
      return ps.hasPermission(role, m.requiredPermission!);
    }).toList();

    // 2. Branch Registration restriction: Strictly Chairman only
    if (normalizedRole != 'chairman') {
      modules.removeWhere((m) => m.id == 'register_branch');
    }

    // 3. HQ Manager specific exclusions: Remove 'server_sync' (Server Control) and 'office_boy' (Office Boy)
    final isHqManager = normalizedRole == 'hq manager' ||
        normalizedRole == 'hq_manager' ||
        normalizedRole == 'headquarters manager' ||
        normalizedRole == 'hqmanager' ||
        normalizedRole == 'hq';
    if (isHqManager) {
      modules.removeWhere((m) => m.id == 'server_sync' || m.id == 'office_boy');
    }

    // 3. Role-specific strict overrides (Supervisor & Branch Manager)
    if (normalizedRole == 'supervisor' || normalizedRole.contains('supervisor') || normalizedRole == 'branch manager') {
      final isBM = normalizedRole == 'branch manager';
      
      // Define the IDs allowed for each role
      final List<String> allowedIds = [
        'branches',
        'inventory',
        'pending_requests',
        'inventory_ledger',
      ];
      
      if (isBM) {
        allowedIds.add('finance');
        allowedIds.addAll([
          'kitchen',
          'dasterkhwaan_inventory',
          'dasterkhwaan_food_log',
          'office_boy',
          'donations',
          'patients_list',
          'patient_register_standalone',
          'reports',
          'madrassa',
          'school_module',
          'employees',
          'payroll',
          'cash_flow',
          'loans',
          'expenses',
          'finance_reports',
        ]);
      }

      // Rename map
      final Map<String, String> renameMap = {
        'branches': 'Summary',
        'inventory': 'Inventory',
        'pending_requests': 'Requests',
        'finance': 'Finance',
        'inventory_ledger': 'Medicine Ledger',
        'office_boy': 'Office',
        'kitchen': 'Kitchen',
        'dasterkhwaan_inventory': 'Dasterkhwaan Stock',
        'donations': 'Donations',
        'patients_list': 'Patients',
        'patient_register_standalone': 'Registration',
        'reports': 'Downloads',
        'madrassa': 'Madrassa',
        'school_module': 'School',
        'employees': 'Employee Management',
        'payroll': 'Payroll',
        'cash_flow': 'Cash Flow & Treasury',
        'loans': 'Loans & Advances',
        'expenses': 'Expenses',
        'finance_reports': 'Finance Reports',
      };

      return modules
          .where((m) => allowedIds.contains(m.id))
          .map((m) {
            var updated = m.copyWith(title: renameMap[m.id]);

            // Override Inventory builder for supervisor/BM to use InventoryPage in read-only mode
            if (m.id == 'inventory') {
              updated = updated.copyWith(
                builder: (context, data) => InventoryPage(
                  branchId: data['branchId'] ?? 'unknown',
                  isSupervisor: true,
                  isReadOnly: true,
                  isEmbedded: true,
                ),
              );
            }
            return updated;
          })
          .toList();
    }

    return modules;
  }
}