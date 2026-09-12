// lib/pages/office/employee_form_sheet.dart

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:collection/collection.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:async';
import 'dart:io';
import '../../theme/role_theme_provider.dart';
import '../../theme/app_theme.dart';
import '../../services/finance_local_storage.dart';
import '../../services/finance_ledger_storage.dart';
import '../../services/zkteco_network_service.dart';
import '../../services/local_storage_service.dart';
import '../../services/image_upload_service.dart';
import '../../utils/formatters.dart';
import '../../services/user_theme_service.dart';
import 'shared_widgets.dart';

void openEmployeeFormSheet(
  BuildContext context, {
  required String activeBranchId,
  required List<Map<String, dynamic>> branches,
  String? employeeId,
  VoidCallback? onSaved,
}) {
  final isDark = UserThemeService.isDarkMode();
  final tOriginal = RoleThemeScope.dataOf(context);
  final t = isDark
      ? RoleThemeData(
          roleLabel: tOriginal.roleLabel,
          isDarkCanvas: true,
          bg: const Color(0xFF0F172A),
          bgCard: const Color(0xFF1E293B),
          bgCardAlt: const Color(0xFF0F172A),
          bgRule: const Color(0xFF334155),
          accent: const Color(0xFF10B981),
          accentLight: const Color(0xFF34D399),
          accentMuted: const Color(0xFF064E3B).withValues(alpha: 0.3),
          accentGradient: const LinearGradient(colors: [Color(0xFF10B981), Color(0xFF059669)]),
          glassTint: const Color(0x1A10B981),
          textPrimary: const Color(0xFFF8FAFC),
          textSecondary: const Color(0xFF94A3B8),
          textTertiary: const Color(0xFF64748B),
          danger: const Color(0xFFEF4444),
          zakat: tOriginal.zakat,
          nonZakat: tOriginal.nonZakat,
          gmwf: tOriginal.gmwf,
          cardFillTokens: tOriginal.cardFillTokens,
          cardFillPrescriptions: tOriginal.cardFillPrescriptions,
          cardFillDispensary: tOriginal.cardFillDispensary,
          chartBar1: tOriginal.chartBar1,
          chartBar2: tOriginal.chartBar2,
          chartBar3: tOriginal.chartBar3,
          chartGrid: tOriginal.chartGrid,
        )
      : RoleThemeData(
          roleLabel: tOriginal.roleLabel,
          isDarkCanvas: false,
          bg: const Color(0xFFF8FAFC),
          bgCard: Colors.white,
          bgCardAlt: const Color(0xFFF1F5F9),
          bgRule: const Color(0xFFE2E8F0),
          accent: const Color(0xFF10B981),
          accentLight: const Color(0xFF34D399),
          accentMuted: const Color(0xFFD1FAE5),
          accentGradient: const LinearGradient(colors: [Color(0xFF10B981), Color(0xFF059669)]),
          glassTint: const Color(0x1A10B981),
          textPrimary: const Color(0xFF111827),
          textSecondary: const Color(0xFF6B7280),
          textTertiary: const Color(0xFF9CA3AF),
          danger: const Color(0xFFEF4444),
          zakat: tOriginal.zakat,
          nonZakat: tOriginal.nonZakat,
          gmwf: tOriginal.gmwf,
          cardFillTokens: tOriginal.cardFillTokens,
          cardFillPrescriptions: tOriginal.cardFillPrescriptions,
          cardFillDispensary: tOriginal.cardFillDispensary,
          chartBar1: tOriginal.chartBar1,
          chartBar2: tOriginal.chartBar2,
          chartBar3: tOriginal.chartBar3,
          chartGrid: tOriginal.chartGrid,
        );

  final isEdit = employeeId != null;
  final Map<String, dynamic> existing = isEdit ? (FinanceLocalStorage.getEmployee(employeeId) ?? {}) : {};

  final String initialBank = existing['bankName']?.toString() ??
      (isEdit
          ? ((existing['bankName'] == 'Cash' || (existing['bankName'] == null && existing['bankAccount'] == null))
              ? 'Cash'
              : 'Meezan Bank Limited')
          : 'Meezan Bank Limited');

  final nameController = TextEditingController(text: existing['name'] ?? '');
  final phoneController = TextEditingController(text: existing['phone'] ?? '');
  final alternatePhoneController = TextEditingController(text: existing['alternatePhone'] ?? '');
  final relationshipController = TextEditingController(text: existing['relationshipName'] ?? '');
  final addressController = TextEditingController(text: existing['currentAddress'] ?? '');

  final double initialSalary = existing['currentSalaryMinor'] != null
      ? (existing['currentSalaryMinor'] as int) / 100.0
      : (existing['currentSalary'] as num?)?.toDouble() ?? 0.0;
  final double initialInstallment = existing['monthlyAdvanceInstallmentMinor'] != null
      ? (existing['monthlyAdvanceInstallmentMinor'] as int) / 100.0
      : (existing['monthlyAdvanceInstallment'] as num?)?.toDouble() ?? 0.0;

  final salaryController = TextEditingController(
    text: existing['salaryText']?.toString() ?? (initialSalary > 0 ? initialSalary.toStringAsFixed(0) : ''),
  );
  final bankNameController = TextEditingController(text: initialBank);
  final bankAccountController = TextEditingController(text: existing['bankAccount'] ?? '');
  final educationController = TextEditingController(text: existing['education'] ?? '');
  final monthlyInstallmentController = TextEditingController(
    text: initialInstallment > 0 ? initialInstallment.toStringAsFixed(0) : '',
  );

  final cnicController = TextEditingController(text: existing['cnic'] ?? '');
  final cnicExpiryController = TextEditingController(
      text: existing['cnicExpiry'] != null && existing['cnicExpiry'].toString().isNotEmpty
          ? DateFormat('yyyy-MM-dd').format(DateTime.parse(existing['cnicExpiry']))
          : '');
  final dobController = TextEditingController(
      text: existing['dob'] != null && existing['dob'].toString().isNotEmpty
          ? DateFormat('yyyy-MM-dd').format(DateTime.parse(existing['dob']))
          : '');
  final joiningController = TextEditingController(
      text: existing['joiningDate'] != null && existing['joiningDate'].toString().isNotEmpty
          ? DateFormat('yyyy-MM-dd').format(DateTime.parse(existing['joiningDate']))
          : DateFormat('yyyy-MM-dd').format(DateTime.now()));

  final existingCred = isEdit ? ZkTecoNetworkService.getCredentialByEntityId(employeeId!) : null;
  final initialPin = existingCred?.biometricPin ?? existing['biometricPin']?.toString() ?? '';
  final biometricPinController = TextEditingController(text: initialPin);

  String selectedBranchId = existing['branchId']?.toString() ?? activeBranchId;
  String compensationType = existing['compensationType'] ?? 'monthly';
  String maritalStatus = existing['maritalStatus'] ?? 'Single';
  String role = existing['role'] ?? 'Office Boy';
  String department = existing['department'] ?? 'Office';
  String relationshipType = existing['relationshipType'] ?? 'Father';
  String gender = existing['gender'] ?? 'Male';
  String paymentMethod = isEdit
      ? ((existing['bankName'] == 'Cash' || (existing['bankName'] == null && existing['bankAccount'] == null))
          ? 'Cash'
          : 'Bank Transfer')
      : 'Bank Transfer';
  String selectedBank = initialBank;

  final winterShiftController = TextEditingController(text: existing['workScheduleOverride']?['winter'] ?? '');
  final summerShiftController = TextEditingController(text: existing['workScheduleOverride']?['summer'] ?? '');

  List<Map<String, String>> emergencyContacts = List<Map<String, dynamic>>.from(existing['emergencyContacts'] ?? [])
      .map((e) => {
            'name': e['name']?.toString() ?? '',
            'relation': e['relation']?.toString() ?? '',
            'phone': e['phone']?.toString() ?? '',
          })
      .toList();

  String? existingProfileUrl = existing['profilePictureUrl']?.toString();
  String? existingIdFrontUrl = existing['identificationUrl']?.toString();
  String? existingIdBackUrl  = existing['identificationBackUrl']?.toString();

  XFile? selectedProfileFile;
  XFile? selectedIdFrontFile;
  XFile? selectedIdBackFile;

  int currentStep = 0;
  bool isSaving = false;
  bool showIdDocs = existingIdFrontUrl != null || existingIdBackUrl != null;

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return RoleThemeScope(
        role: RoleTheme.admin,
        child: StatefulBuilder(
          builder: (ctx, setState) {
            final isNarrow = MediaQuery.of(ctx).size.width < 640;

            final List<String> rolesList = List<String>.from(FinanceLocalStorage.getRolesForDepartment(department));
            final curUserRole = RoleThemeScope.dataOf(context).roleLabel.toLowerCase().trim();
            if (curUserRole != 'chairman') {
              rolesList.removeWhere((r) => r.toLowerCase().trim() == 'chairman');
            }
            if (!rolesList.contains(role)) rolesList.add(role);
            if (!rolesList.contains('+ Add Custom Role...')) rolesList.add('+ Add Custom Role...');

            final List<String> deptsList = FinanceLedgerStorage.sortDepartmentsCanonical(
              ['Administration Staff', 'Office', 'Dasterkhwaan', 'Dispensary', 'Madrassa', 'School']
                ..addAll(FinanceLocalStorage.getCustomDepartments())
            );
            if (!deptsList.contains(department)) deptsList.add(department);
            if (!deptsList.contains('+ Add Custom Department...')) deptsList.add('+ Add Custom Department...');

            final allBranches = FinanceLocalStorage.getAllBranches(branches)
                .where((b) {
                  final id = b['id']?.toString() ?? '';
                  return id != 'karachi-2' && id != 'karachi2';
                }).toList();

            final List<String> branchDropdownItems = allBranches.map((b) => b['id']?.toString() ?? '').toList();
            if (!branchDropdownItems.contains('+ Add Custom Branch...')) {
              branchDropdownItems.add('+ Add Custom Branch...');
            }
            if (!branchDropdownItems.contains(selectedBranchId) && branchDropdownItems.isNotEmpty) {
              selectedBranchId = branchDropdownItems.first;
            }

            // ── Step 1: Personal Details ──────────────────────────────────────────
            Widget buildPersonalStep() {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Profile Photo Header
                  Center(
                    child: Stack(
                      children: [
                        Container(
                          width: 84,
                          height: 84,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFFE2E8F0),
                            border: Border.all(color: const Color(0xFF10B981), width: 2.5),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.08),
                                blurRadius: 10,
                                offset: const Offset(0, 3),
                              )
                            ],
                            image: (selectedProfileFile != null)
                                ? DecorationImage(
                                    image: FileImage(File(selectedProfileFile!.path)),
                                    fit: BoxFit.cover,
                                  )
                                : (existingProfileUrl != null && existingProfileUrl!.isNotEmpty)
                                    ? DecorationImage(
                                        image: (ImageUploadService.decodeBase64ToBytes(existingProfileUrl) != null
                                            ? MemoryImage(ImageUploadService.decodeBase64ToBytes(existingProfileUrl)!)
                                            : NetworkImage(existingProfileUrl!) as ImageProvider),
                                        fit: BoxFit.cover,
                                      )
                                    : null,
                          ),
                          child: (selectedProfileFile == null && (existingProfileUrl == null || existingProfileUrl!.isEmpty))
                              ? const Icon(Icons.person_rounded, size: 44, color: Color(0xFF94A3B8))
                              : null,
                        ),
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: InkWell(
                            onTap: () async {
                              final source = await ImageUploadService.showSourceDialog(
                                ctx,
                                title: 'Select Profile Picture',
                              );
                              if (source == null) return;
                              final b64 = await ImageUploadService.pickAndProcessImage(source: source, quality: 80);
                              if (b64 != null && b64.isNotEmpty) {
                                setState(() {
                                  existingProfileUrl = b64;
                                  selectedProfileFile = null;
                                });
                              }
                            },
                            child: Container(
                              padding: const EdgeInsets.all(7),
                              decoration: const BoxDecoration(
                                color: Color(0xFF10B981),
                                shape: BoxShape.circle,
                                boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 4)],
                              ),
                              child: const Icon(Icons.camera_alt_rounded, size: 15, color: Colors.white),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Center(
                    child: Text(
                      existingProfileUrl != null ? 'Tap camera to change photo' : 'Upload Employee Photo (Optional)',
                      style: const TextStyle(fontSize: 11, color: Color(0xFF64748B), fontWeight: FontWeight.w500),
                    ),
                  ),
                  const SizedBox(height: 18),

                  // Name & Gender Row
                  buildResponsiveFieldRow(
                    isNarrow: isNarrow,
                    children: [
                      Expanded(
                        child: buildFormField(
                          controller: nameController,
                          label: 'Full Name *',
                          icon: Icons.person_outline_rounded,
                          theme: t,
                        ),
                      ),
                      Expanded(
                        child: buildDropdownField(
                          label: 'Gender',
                          value: gender,
                          items: const ['Male', 'Female'],
                          onChanged: (val) {
                            if (val != null) {
                              setState(() {
                                gender = val;
                                if (gender == 'Male') relationshipType = 'Father';
                              });
                            }
                          },
                          theme: t,
                        ),
                      ),
                    ],
                  ),

                  // Phone & Alternate Phone Row
                  buildResponsiveFieldRow(
                    isNarrow: isNarrow,
                    children: [
                      Expanded(
                        child: buildFormField(
                          controller: phoneController,
                          label: 'Primary Phone (11 digits) *',
                          icon: Icons.phone_rounded,
                          theme: t,
                          keyboardType: TextInputType.phone,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(11),
                          ],
                        ),
                      ),
                      Expanded(
                        child: buildFormField(
                          controller: alternatePhoneController,
                          label: 'Alternate Phone (Optional)',
                          icon: Icons.phone_android_rounded,
                          theme: t,
                          keyboardType: TextInputType.phone,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(11),
                          ],
                        ),
                      ),
                    ],
                  ),

                  // CNIC & Date of Birth
                  buildResponsiveFieldRow(
                    isNarrow: isNarrow,
                    children: [
                      Expanded(
                        child: buildFormField(
                          controller: cnicController,
                          label: 'CNIC Number (Optional)',
                          icon: Icons.credit_card_rounded,
                          theme: t,
                          inputFormatters: [CNICInputFormatter()],
                        ),
                      ),
                      Expanded(
                        child: buildDatePickerField(
                          context: ctx,
                          controller: dobController,
                          label: 'Date of Birth',
                          icon: Icons.cake_outlined,
                          theme: t,
                        ),
                      ),
                    ],
                  ),

                  // CNIC Expiry & Marital Status
                  buildResponsiveFieldRow(
                    isNarrow: isNarrow,
                    children: [
                      Expanded(
                        child: buildDatePickerField(
                          context: ctx,
                          controller: cnicExpiryController,
                          label: 'CNIC Expiry Date',
                          icon: Icons.calendar_month_outlined,
                          theme: t,
                        ),
                      ),
                      Expanded(
                        child: buildDropdownField(
                          label: 'Marital Status',
                          value: maritalStatus,
                          items: const ['Single', 'Married', 'Divorced', 'Widowed'],
                          onChanged: (val) {
                            if (val != null) setState(() => maritalStatus = val);
                          },
                          theme: t,
                        ),
                      ),
                    ],
                  ),

                  // Relationship / Father Name
                  buildResponsiveFieldRow(
                    isNarrow: isNarrow,
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            SizedBox(
                              width: 110,
                              child: buildDropdownField(
                                label: 'Relation',
                                value: relationshipType,
                                items: gender == 'Male' ? const ['Father'] : const ['Father', 'Spouse'],
                                onChanged: (val) {
                                  if (val != null) setState(() => relationshipType = val);
                                },
                                theme: t,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: buildFormField(
                                controller: relationshipController,
                                label: '$relationshipType Name',
                                icon: Icons.people_outline_rounded,
                                theme: t,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: buildFormField(
                          controller: educationController,
                          label: 'Highest Education / Degree',
                          icon: Icons.school_outlined,
                          theme: t,
                        ),
                      ),
                    ],
                  ),

                  // Address
                  buildFormField(
                    controller: addressController,
                    label: 'Current Address',
                    icon: Icons.home_outlined,
                    theme: t,
                    maxLines: 2,
                  ),

                  // ID Card Attachments Toggle
                  const SizedBox(height: 4),
                  InkWell(
                    onTap: () => setState(() => showIdDocs = !showIdDocs),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                      child: Row(
                        children: [
                          Icon(
                            showIdDocs ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                            color: const Color(0xFF0D9488),
                            size: 20,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            showIdDocs ? 'Hide ID Card Scans' : 'Attach CNIC / ID Card Scans (Front & Back)',
                            style: const TextStyle(
                              color: Color(0xFF0D9488),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  if (showIdDocs) ...[
                    const SizedBox(height: 8),
                    _buildMediaPickerRow(
                      label: 'ID Card (Front)',
                      existingUrl: existingIdFrontUrl,
                      selectedFile: selectedIdFrontFile,
                      onPick: () async {
                        final source = await ImageUploadService.showSourceDialog(ctx, title: 'Select ID Front Source');
                        if (source == null) return;
                        final b64 = await ImageUploadService.pickAndProcessImage(source: source, quality: 80);
                        if (b64 != null && b64.isNotEmpty) {
                          setState(() {
                            existingIdFrontUrl = b64;
                            selectedIdFrontFile = null;
                          });
                        }
                      },
                      onClear: () {
                        setState(() {
                          selectedIdFrontFile = null;
                          existingIdFrontUrl = null;
                        });
                      },
                      theme: t,
                    ),
                    const SizedBox(height: 10),
                    _buildMediaPickerRow(
                      label: 'ID Card (Back)',
                      existingUrl: existingIdBackUrl,
                      selectedFile: selectedIdBackFile,
                      onPick: () async {
                        final source = await ImageUploadService.showSourceDialog(ctx, title: 'Select ID Back Source');
                        if (source == null) return;
                        final b64 = await ImageUploadService.pickAndProcessImage(source: source, quality: 80);
                        if (b64 != null && b64.isNotEmpty) {
                          setState(() {
                            existingIdBackUrl = b64;
                            selectedIdBackFile = null;
                          });
                        }
                      },
                      onClear: () {
                        setState(() {
                          selectedIdBackFile = null;
                          existingIdBackUrl = null;
                        });
                      },
                      theme: t,
                    ),
                  ],
                ],
              );
            }

            // ── Step 2: Job & Compensation ────────────────────────────────────────
            Widget buildJobStep() {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Branch selection
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: t.bgCardAlt,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: t.bgRule),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.business_rounded, color: t.accent, size: 16),
                            const SizedBox(width: 6),
                            Text(
                              'Assigned Branch *',
                              style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 11.5),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        DropdownButtonFormField<String>(
                          value: selectedBranchId,
                          dropdownColor: t.bgCard,
                          decoration: InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(color: t.bgRule),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(color: t.bgRule),
                            ),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          ),
                          style: TextStyle(color: t.textPrimary, fontSize: 13, fontWeight: FontWeight.w500),
                          items: branchDropdownItems.map((id) {
                            if (id == '+ Add Custom Branch...') {
                              return DropdownMenuItem(
                                value: '+ Add Custom Branch...',
                                child: Text('+ Add Custom Branch...', style: TextStyle(fontWeight: FontWeight.bold, color: t.accent)),
                              );
                            }
                            final b = allBranches.firstWhereOrNull((x) => x['id'] == id);
                            String name = b?['name']?.toString() ?? id;
                            if (id == 'karachi-1' || id == 'karachi1') name = 'Karachi';
                            return DropdownMenuItem(value: id, child: Text('$name ($id)'));
                          }).toList(),
                          onChanged: isEdit
                              ? null
                              : (val) {
                                  if (val == '+ Add Custom Branch...') {
                                    showCustomBranchDialog(
                                      context: ctx,
                                      theme: t,
                                      onAdded: (newId, newName) {
                                        setState(() => selectedBranchId = newId);
                                      },
                                    );
                                  } else if (val != null) {
                                    setState(() => selectedBranchId = val);
                                  }
                                },
                        ),
                      ],
                    ),
                  ),

                  // Department & Role
                  buildResponsiveFieldRow(
                    isNarrow: isNarrow,
                    children: [
                      Expanded(
                        child: buildDropdownField(
                          label: 'Department *',
                          value: department,
                          items: deptsList,
                          onChanged: (val) {
                            if (val == '+ Add Custom Department...') {
                              showAddCustomDialog(
                                context: ctx,
                                title: 'Add Custom Department',
                                hint: 'Enter department name',
                                onAdded: (newVal) async {
                                  if (newVal.isNotEmpty) {
                                    await FinanceLocalStorage.addCustomDepartment(newVal);
                                    setState(() {
                                      department = newVal;
                                      final newRoles = FinanceLocalStorage.getRolesForDepartment(newVal);
                                      role = newRoles.isNotEmpty ? newRoles.first : 'Staff';
                                    });
                                  }
                                },
                                theme: t,
                              );
                            } else if (val != null) {
                              setState(() {
                                department = val;
                                final newRoles = FinanceLocalStorage.getRolesForDepartment(val);
                                role = newRoles.isNotEmpty ? newRoles.first : 'Staff';
                              });
                            }
                          },
                          theme: t,
                        ),
                      ),
                      Expanded(
                        child: buildDropdownField(
                          label: 'Role / Designation *',
                          value: role,
                          items: rolesList,
                          onChanged: (val) {
                            if (val == '+ Add Custom Role...') {
                              showAddCustomDialog(
                                context: ctx,
                                title: 'Add Custom Role',
                                hint: 'Enter role name',
                                onAdded: (newVal) async {
                                  if (newVal.isNotEmpty) {
                                    await FinanceLocalStorage.addCustomRoleForDepartment(department, newVal);
                                    setState(() => role = newVal);
                                  }
                                },
                                theme: t,
                              );
                            } else if (val != null) {
                              setState(() => role = val);
                            }
                          },
                          theme: t,
                        ),
                      ),
                    ],
                  ),

                  // Joining Date & Compensation Type
                  buildResponsiveFieldRow(
                    isNarrow: isNarrow,
                    children: [
                      Expanded(
                        child: buildDatePickerField(
                          context: ctx,
                          controller: joiningController,
                          label: 'Joining Date *',
                          icon: Icons.calendar_today_rounded,
                          theme: t,
                        ),
                      ),
                      Expanded(
                        child: buildDropdownField(
                          label: 'Payment Schedule',
                          value: compensationType == 'monthly'
                              ? 'Monthly'
                              : (compensationType == 'hourly' ? 'Hourly' : 'Contract'),
                          items: const ['Monthly', 'Hourly', 'Contract'],
                          onChanged: (val) {
                            if (val != null) {
                              setState(() {
                                if (val == 'Monthly') compensationType = 'monthly';
                                if (val == 'Hourly') compensationType = 'hourly';
                                if (val == 'Contract') compensationType = 'contract';
                              });
                            }
                          },
                          theme: t,
                        ),
                      ),
                    ],
                  ),

                  // Prominent Salary Box
                  Container(
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: isDark
                            ? [const Color(0xFF064E3B).withValues(alpha: 0.35), const Color(0xFF022C22).withValues(alpha: 0.35)]
                            : [const Color(0xFFF0FDF4), const Color(0xFFECFDF5)],
                      ),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: t.accent.withValues(alpha: isDark ? 0.5 : 0.4), width: 1.3),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.payments_rounded, color: t.accent, size: 18),
                            const SizedBox(width: 8),
                            Text(
                              'Base Monthly Salary *',
                              style: TextStyle(color: isDark ? const Color(0xFF34D399) : const Color(0xFF065F46), fontWeight: FontWeight.bold, fontSize: 12),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: t.accent,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text(
                                'PKR',
                                style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 12),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: TextField(
                                controller: salaryController,
                                keyboardType: TextInputType.number,
                                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                style: TextStyle(
                                  color: isDark ? const Color(0xFF6EE7B7) : const Color(0xFF065F46),
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.5,
                                ),
                                decoration: InputDecoration(
                                  hintText: 'e.g. 35000',
                                  hintStyle: TextStyle(
                                    color: isDark ? const Color(0xFF047857) : const Color(0xFFA7F3D0),
                                    fontSize: 18,
                                    fontWeight: FontWeight.normal,
                                  ),
                                  isDense: true,
                                  border: InputBorder.none,
                                  contentPadding: EdgeInsets.zero,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Gross monthly pay before deductions & loan installments.',
                          style: TextStyle(color: isDark ? const Color(0xFF34D399).withValues(alpha: 0.8) : const Color(0xFF047857), fontSize: 10.5),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 8),

                  // Biometric Scanner PIN
                  buildResponsiveFieldRow(
                    isNarrow: isNarrow,
                    children: [
                      Expanded(
                        child: buildFormField(
                          controller: biometricPinController,
                          label: 'Biometric Scanner PIN (Optional)',
                          icon: Icons.fingerprint_rounded,
                          theme: t,
                          keyboardType: TextInputType.number,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        ),
                      ),
                      const Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(top: 4, left: 6),
                          child: Text(
                            'Numeric PIN for physical ZKTeco fingerprint/face attendance hardware (e.g. 159).',
                            style: TextStyle(color: Color(0xFF64748B), fontSize: 11),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              );
            }

            // ── Step 3: Bank & Schedule ───────────────────────────────────────────
            Widget buildBankAndScheduleStep() {
              final List<String> banksList = [
                'Habib Bank Limited (HBL)',
                'United Bank Limited (UBL)',
                'MCB Bank Limited (MCB)',
                'National Bank of Pakistan (NBP)',
                'Meezan Bank Limited',
                'Bank Alfalah Limited',
                'Allied Bank Limited (ABL)',
                'Faysal Bank Limited',
                'Askari Bank Limited',
                'Bank Islami Pakistan',
              ]..addAll(FinanceLocalStorage.getCustomBanks());

              if (paymentMethod == 'Bank Transfer') {
                if (selectedBank == 'Cash') selectedBank = 'Meezan Bank Limited';
                if (!banksList.contains(selectedBank)) banksList.add(selectedBank);
                if (!banksList.contains('+ Add Custom Bank...')) banksList.add('+ Add Custom Bank...');
              } else {
                selectedBank = 'Cash';
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Payment Method Segmented Buttons
                  Text(
                    'Disbursement / Payment Method',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: t.textPrimary),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          onTap: () {
                            setState(() {
                              paymentMethod = 'Bank Transfer';
                              selectedBank = 'Meezan Bank Limited';
                              bankNameController.text = 'Meezan Bank Limited';
                              if (bankAccountController.text == 'N/A') bankAccountController.text = '';
                            });
                          },
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            decoration: BoxDecoration(
                              color: paymentMethod == 'Bank Transfer'
                                  ? (isDark ? const Color(0xFF1E3A8A).withValues(alpha: 0.35) : const Color(0xFFEFF6FF))
                                  : t.bgCardAlt,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: paymentMethod == 'Bank Transfer' ? const Color(0xFF3B82F6) : t.bgRule,
                                width: paymentMethod == 'Bank Transfer' ? 1.8 : 1.0,
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.account_balance_rounded,
                                  size: 16,
                                  color: paymentMethod == 'Bank Transfer' ? const Color(0xFF3B82F6) : t.textSecondary,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Bank Transfer',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.bold,
                                    color: paymentMethod == 'Bank Transfer'
                                        ? (isDark ? const Color(0xFF93C5FD) : const Color(0xFF1E40AF))
                                        : t.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: InkWell(
                          onTap: () {
                            setState(() {
                              paymentMethod = 'Cash';
                              selectedBank = 'Cash';
                              bankNameController.text = 'Cash';
                              bankAccountController.text = 'N/A';
                            });
                          },
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            decoration: BoxDecoration(
                              color: paymentMethod == 'Cash'
                                  ? (isDark ? const Color(0xFF064E3B).withValues(alpha: 0.35) : const Color(0xFFF0FDF4))
                                  : t.bgCardAlt,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: paymentMethod == 'Cash' ? const Color(0xFF10B981) : t.bgRule,
                                width: paymentMethod == 'Cash' ? 1.8 : 1.0,
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.payments_rounded,
                                  size: 16,
                                  color: paymentMethod == 'Cash' ? const Color(0xFF10B981) : t.textSecondary,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Cash in Hand',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.bold,
                                    color: paymentMethod == 'Cash'
                                        ? (isDark ? const Color(0xFF6EE7B7) : const Color(0xFF065F46))
                                        : t.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  if (paymentMethod == 'Bank Transfer') ...[
                    buildResponsiveFieldRow(
                      isNarrow: isNarrow,
                      children: [
                        Expanded(
                          child: buildDropdownField(
                            label: 'Bank Name *',
                            value: selectedBank,
                            items: banksList,
                            onChanged: (val) {
                              if (val == '+ Add Custom Bank...') {
                                showAddCustomDialog(
                                  context: ctx,
                                  title: 'Add Custom Bank',
                                  hint: 'Enter bank name',
                                  onAdded: (newVal) async {
                                    if (newVal.isNotEmpty) {
                                      await FinanceLocalStorage.addCustomBank(newVal);
                                      setState(() {
                                        selectedBank = newVal;
                                        bankNameController.text = newVal;
                                      });
                                    }
                                  },
                                  theme: t,
                                );
                              } else if (val != null) {
                                setState(() {
                                  selectedBank = val;
                                  bankNameController.text = val;
                                });
                              }
                            },
                            theme: t,
                          ),
                        ),
                        Expanded(
                          child: buildFormField(
                            controller: bankAccountController,
                            label: 'Account Number / IBAN *',
                            icon: Icons.numbers_rounded,
                            theme: t,
                          ),
                        ),
                      ],
                    ),
                  ],

                  // Monthly Advance Limit
                  buildFormField(
                    controller: monthlyInstallmentController,
                    label: 'Monthly Advance Deduction Limit (Optional)',
                    icon: Icons.money_off_rounded,
                    theme: t,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),

                  const SizedBox(height: 12),

                  // Work Schedule Timings
                  const Text(
                    'Work Schedule (Optional)',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF334155)),
                  ),
                  const SizedBox(height: 8),
                  buildResponsiveFieldRow(
                    isNarrow: isNarrow,
                    children: [
                      Expanded(
                        child: buildFormField(
                          controller: winterShiftController,
                          label: 'Winter Timings (e.g. 8:00 AM - 4:00 PM)',
                          icon: Icons.ac_unit_rounded,
                          theme: t,
                        ),
                      ),
                      Expanded(
                        child: buildFormField(
                          controller: summerShiftController,
                          label: 'Summer Timings (e.g. 7:30 AM - 3:30 PM)',
                          icon: Icons.wb_sunny_rounded,
                          theme: t,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  // Emergency Contacts
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Emergency Contacts (${emergencyContacts.length})',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF334155)),
                      ),
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFF0D9488),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        ),
                        icon: const Icon(Icons.add_circle_outline_rounded, size: 16),
                        label: const Text('Add Contact', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        onPressed: () {
                          final cName = TextEditingController();
                          final cRel = TextEditingController();
                          final cPhone = TextEditingController();
                          showDialog(
                            context: ctx,
                            builder: (subCtx) => AlertDialog(
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              title: const Text('Add Emergency Contact', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                              content: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  buildFormField(controller: cName, label: 'Contact Name', icon: Icons.person_rounded, theme: t),
                                  buildFormField(controller: cRel, label: 'Relation (e.g. Brother)', icon: Icons.group_rounded, theme: t),
                                  buildFormField(
                                    controller: cPhone,
                                    label: 'Phone Number',
                                    icon: Icons.phone_rounded,
                                    theme: t,
                                    keyboardType: TextInputType.phone,
                                  ),
                                ],
                              ),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(subCtx), child: const Text('Cancel')),
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
                                  onPressed: () {
                                    if (cName.text.trim().isNotEmpty && cPhone.text.trim().isNotEmpty) {
                                      setState(() {
                                        emergencyContacts.add({
                                          'name': cName.text.trim(),
                                          'relation': cRel.text.trim(),
                                          'phone': cPhone.text.trim(),
                                        });
                                      });
                                      Navigator.pop(subCtx);
                                    }
                                  },
                                  child: const Text('Add', style: TextStyle(color: Colors.white)),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  if (emergencyContacts.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: const Center(
                        child: Text(
                          'No emergency contacts added. (Optional)',
                          style: TextStyle(fontSize: 11.5, color: Color(0xFF94A3B8)),
                        ),
                      ),
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: emergencyContacts.map((contact) {
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF1F5F9),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFFCBD5E1)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.person_pin_rounded, size: 14, color: Color(0xFF0D9488)),
                              const SizedBox(width: 6),
                              Text(
                                '${contact['name']} (${contact['relation']}) • ${contact['phone']}',
                                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Color(0xFF334155)),
                              ),
                              const SizedBox(width: 6),
                              InkWell(
                                onTap: () => setState(() => emergencyContacts.remove(contact)),
                                child: const Icon(Icons.close_rounded, size: 14, color: Color(0xFFEF4444)),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                ],
              );
            }

            // ── Save Execution (Local-First + Queue Sync + Realtime) ──────────────
            Future<void> handleSave() async {
              final rawName = nameController.text.trim();
              if (rawName.isEmpty) {
                showCustomSnackBar(ctx, 'Employee name is required.', error: true);
                setState(() => currentStep = 0);
                return;
              }

              final rawSalary = salaryController.text.trim();
              final double parsedSalary = double.tryParse(rawSalary) ?? 0.0;
              if (parsedSalary <= 0 && rawSalary.isEmpty) {
                showCustomSnackBar(ctx, 'Please enter a valid base monthly salary.', error: true);
                setState(() => currentStep = 1);
                return;
              }

              setState(() => isSaving = true);

              try {
                final curUser = RoleThemeScope.dataOf(context).roleLabel;

                // Handle profile and identification image paths
                String? profileUrl = existingProfileUrl;
                String? profilePath;
                String? idFrontUrl = existingIdFrontUrl;
                String? idFrontPath;
                String? idBackUrl = existingIdBackUrl;
                String? idBackPath;

                if (selectedProfileFile != null) {
                  profilePath = selectedProfileFile!.path;
                }
                if (selectedIdFrontFile != null) {
                  idFrontPath = selectedIdFrontFile!.path;
                }
                if (selectedIdBackFile != null) {
                  idBackPath = selectedIdBackFile!.path;
                }

                final enteredPin = biometricPinController.text.trim();
                final enteredCnic = cnicController.text.trim();

                final scheduleOverride = (winterShiftController.text.trim().isNotEmpty || summerShiftController.text.trim().isNotEmpty)
                    ? {
                        'winter': winterShiftController.text.trim(),
                        'summer': summerShiftController.text.trim(),
                      }
                    : null;

                final validContacts = emergencyContacts
                    .where((c) => (c['name']?.isNotEmpty == true) && (c['phone']?.isNotEmpty == true))
                    .toList();

                final employeeData = <String, dynamic>{
                  if (isEdit) 'id': employeeId,
                  if (isEdit) 'localId': employeeId,
                  'name': rawName,
                  'gender': gender,
                  'dob': dobController.text.isNotEmpty ? dobController.text.trim() : null,
                  'cnic': enteredCnic.isNotEmpty ? enteredCnic : null,
                  'cnicExpiry': cnicExpiryController.text.isNotEmpty ? cnicExpiryController.text.trim() : null,
                  'phone': phoneController.text.trim(),
                  'alternatePhone': alternatePhoneController.text.trim().isNotEmpty ? alternatePhoneController.text.trim() : null,
                  'relationshipType': relationshipType,
                  'relationshipName': relationshipController.text.trim().isNotEmpty ? relationshipController.text.trim() : null,
                  'maritalStatus': maritalStatus,
                  'department': department,
                  'role': role,
                  'joiningDate': joiningController.text.isNotEmpty ? joiningController.text.trim() : DateFormat('yyyy-MM-dd').format(DateTime.now()),
                  'compensationType': compensationType,
                  'currentSalary': parsedSalary,
                  'salaryText': salaryController.text.trim(),
                  'bankName': paymentMethod == 'Cash' ? 'Cash' : (bankNameController.text.trim().isNotEmpty ? bankNameController.text.trim() : 'Meezan Bank Limited'),
                  'bankAccount': paymentMethod == 'Cash' ? 'N/A' : bankAccountController.text.trim(),
                  'education': educationController.text.isNotEmpty ? educationController.text.trim() : null,
                  'currentAddress': addressController.text.trim().isNotEmpty ? addressController.text.trim() : null,
                  'emergencyContacts': validContacts,
                  'workScheduleOverride': scheduleOverride,
                  'isActive': existing['isActive'] ?? true,
                  'biometricPin': enteredPin.isNotEmpty ? enteredPin : null,
                  'monthlyAdvanceInstallment': monthlyInstallmentController.text.trim().isNotEmpty
                      ? double.tryParse(monthlyInstallmentController.text) ?? 0.0
                      : 0.0,
                  'branchId': selectedBranchId,
                  'profilePictureUrl': profileUrl,
                  'profilePicturePath': profilePath,
                  'identificationUrl': idFrontUrl,
                  'identificationPath': idFrontPath,
                  'identificationBackUrl': idBackUrl,
                  'identificationBackPath': idBackPath,
                };

                final targetBranchId = isEdit ? (existing['branchId']?.toString() ?? activeBranchId) : selectedBranchId;

                // 1. Instant local save (Hive) + Local audit trail + Biometric cred mapping + Server sync enqueue + LAN WebSocket + Background upload
                final empLocalId = await FinanceLocalStorage.saveEmployee(
                  branchId: targetBranchId,
                  data: employeeData,
                  performedBy: curUser,
                );

                // 2. Initial / Updated Salary History (Safe & local)
                try {
                  if (!isEdit) {
                    await FinanceLocalStorage.saveSalaryHistory(
                      branchId: targetBranchId,
                      employeeId: empLocalId,
                      amount: parsedSalary,
                      effectiveDate: joiningController.text.isNotEmpty ? DateTime.parse(joiningController.text) : DateTime.now(),
                      reason: 'Initial onboarding salary configuration',
                      approvedBy: curUser,
                      performedBy: curUser,
                    );
                  } else if (existing['currentSalary'] != parsedSalary) {
                    await FinanceLocalStorage.saveSalaryHistory(
                      branchId: activeBranchId,
                      employeeId: empLocalId,
                      amount: parsedSalary,
                      effectiveDate: DateTime.now(),
                      reason: 'Updated during employee profile modification',
                      approvedBy: curUser,
                      performedBy: curUser,
                    );
                  }
                } catch (e) {
                  debugPrint('[EmployeeForm] Salary history notice: $e');
                }

                // 3. Assign Biometric PIN (Non-blocking background)
                unawaited(ZkTecoNetworkService.assignPinToEntity(
                  entityId: empLocalId,
                  entityName: rawName,
                  entityType: 'employee',
                  branchId: targetBranchId,
                  customPin: enteredPin.isNotEmpty ? enteredPin : null,
                ).catchError((e) {
                  debugPrint('[EmployeeForm] Biometric PIN assignment notice: $e');
                  return '';
                }));

                // 4. Instant UI Dismiss & Feedback
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext, rootNavigator: true).pop();
                } else if (Navigator.canPop(ctx)) {
                  Navigator.pop(ctx);
                }
                if (onSaved != null) onSaved();
                showCustomSnackBar(context, '✅ $rawName saved locally & queued for sync!');
              } catch (e) {
                if (ctx.mounted) {
                  setState(() => isSaving = false);
                  showCustomSnackBar(ctx, e.toString().replaceAll('Exception: ', ''), error: true);
                }
              }
            }

            return Dialog(
              backgroundColor: t.bgCard,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(color: t.bgRule),
              ),
              insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680, maxHeight: 720),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Header
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: t.accent.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(Icons.badge_rounded, color: t.accent, size: 24),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  isEdit ? 'Edit Employee Profile' : 'Add New Employee',
                                  style: TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w800,
                                    color: t.textPrimary,
                                    letterSpacing: -0.2,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Instant local save with automated server sync',
                                  style: TextStyle(fontSize: 11, color: t.textSecondary),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: Icon(Icons.close_rounded, color: t.textSecondary),
                            onPressed: isSaving ? null : () => Navigator.pop(dialogContext),
                          ),
                        ],
                      ),

                      const SizedBox(height: 16),

                      // Step Pills Navigation Bar
                      Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: t.bgCardAlt,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: t.bgRule),
                        ),
                        child: Row(
                          children: [
                            _buildStepTab(0, '1. Personal', Icons.person_rounded, currentStep, (idx) {
                              if (!isSaving) setState(() => currentStep = idx);
                            }, t, isDark),
                            _buildStepTab(1, '2. Job & Pay', Icons.work_rounded, currentStep, (idx) {
                              if (!isSaving) setState(() => currentStep = idx);
                            }, t, isDark),
                            _buildStepTab(2, '3. Bank & Schedule', Icons.account_balance_rounded, currentStep, (idx) {
                              if (!isSaving) setState(() => currentStep = idx);
                            }, t, isDark),
                          ],
                        ),
                      ),

                      const SizedBox(height: 16),

                      // Scrollable Step Body
                      Expanded(
                        child: SingleChildScrollView(
                          physics: const BouncingScrollPhysics(),
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            child: currentStep == 0
                                ? buildPersonalStep()
                                : (currentStep == 1 ? buildJobStep() : buildBankAndScheduleStep()),
                          ),
                        ),
                      ),

                      const SizedBox(height: 14),

                      // Bottom Navigation & Save Footer
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          if (currentStep > 0)
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: t.textPrimary,
                                side: BorderSide(color: t.bgRule),
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              icon: const Icon(Icons.arrow_back_rounded, size: 16),
                              label: const Text('Back', style: TextStyle(fontWeight: FontWeight.w600)),
                              onPressed: isSaving ? null : () => setState(() => currentStep--),
                            )
                          else
                            TextButton(
                              style: TextButton.styleFrom(
                                foregroundColor: t.textSecondary,
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                              ),
                              child: const Text('Cancel'),
                              onPressed: isSaving ? null : () => Navigator.pop(dialogContext),
                            ),

                          Row(
                            children: [
                              if (currentStep < 2)
                                ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: isDark ? const Color(0xFF334155) : const Color(0xFF0F172A),
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  ),
                                  icon: const Text('Next Step', style: TextStyle(fontWeight: FontWeight.bold)),
                                  label: const Icon(Icons.arrow_forward_rounded, size: 16),
                                  onPressed: () {
                                    if (currentStep == 0 && nameController.text.trim().isEmpty) {
                                      showCustomSnackBar(ctx, 'Please enter the employee name to continue.', error: true);
                                      return;
                                    }
                                    setState(() => currentStep++);
                                  },
                                ),
                              const SizedBox(width: 8),
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: t.accent,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                  elevation: 2,
                                  shadowColor: t.accent.withValues(alpha: 0.4),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                ),
                                icon: isSaving
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                      )
                                    : const Icon(Icons.check_circle_rounded, size: 18),
                                label: Text(
                                  isSaving
                                      ? 'Saving & Syncing...'
                                      : (isEdit ? 'Update Employee' : 'Save Employee'),
                                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
                                ),
                                onPressed: isSaving ? null : handleSave,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      );
    },
  );
}

Widget _buildStepTab(int stepIndex, String title, IconData icon, int currentStep, ValueChanged<int> onSelect, RoleThemeData t, bool isDark) {
  final isActive = currentStep == stepIndex;
  final isDone = currentStep > stepIndex;

  return Expanded(
    child: InkWell(
      onTap: () => onSelect(stepIndex),
      borderRadius: BorderRadius.circular(9),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        decoration: BoxDecoration(
          color: isActive ? (isDark ? t.bgCard : Colors.white) : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          border: isActive ? Border.all(color: t.bgRule) : null,
          boxShadow: isActive
              ? [BoxShadow(color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.06), blurRadius: 4, offset: const Offset(0, 2))]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isDone ? Icons.check_circle_rounded : icon,
              size: 14,
              color: isDone
                  ? const Color(0xFF10B981)
                  : (isActive ? t.accent : t.textTertiary),
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: isActive ? FontWeight.w800 : FontWeight.w600,
                  color: isActive ? t.textPrimary : t.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

void showCustomBranchDialog({
  required BuildContext context,
  required RoleThemeData theme,
  required void Function(String id, String name) onAdded,
}) {
  final idController = TextEditingController();
  final nameController = TextEditingController();
  showDialog(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        backgroundColor: theme.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('Add Custom Branch', style: TextStyle(color: theme.textPrimary, fontSize: 16, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: idController,
              autofocus: true,
              style: TextStyle(color: theme.textPrimary),
              decoration: InputDecoration(
                hintText: 'Enter Branch ID (e.g. lahore)',
                hintStyle: TextStyle(color: theme.textTertiary),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: theme.bgRule)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: theme.accent)),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: nameController,
              style: TextStyle(color: theme.textPrimary),
              decoration: InputDecoration(
                hintText: 'Enter Branch Name (e.g. Lahore)',
                hintStyle: TextStyle(color: theme.textTertiary),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: theme.bgRule)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: theme.accent)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: theme.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: theme.accent),
            onPressed: () async {
              final id = idController.text.trim().toLowerCase();
              final name = nameController.text.trim();
              if (id.isNotEmpty && name.isNotEmpty) {
                await FinanceLocalStorage.addCustomBranch(id, name);
                Navigator.pop(ctx);
                onAdded(id, name);
              }
            },
            child: const Text('Add Branch', style: TextStyle(color: Colors.white)),
          ),
        ],
      );
    },
  );
}

Widget _buildMediaPickerRow({
  required String label,
  required String? existingUrl,
  required XFile? selectedFile,
  required VoidCallback onPick,
  required VoidCallback onClear,
  required RoleThemeData theme,
}) {
  final bool hasImage = selectedFile != null || (existingUrl != null && existingUrl.isNotEmpty);

  return Container(
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: theme.bgCardAlt,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: theme.bgRule),
    ),
    child: Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: theme.bgRule,
            borderRadius: BorderRadius.circular(8),
            image: hasImage
                ? DecorationImage(
                    image: selectedFile != null
                        ? FileImage(File(selectedFile.path))
                        : (ImageUploadService.decodeBase64ToBytes(existingUrl) != null
                            ? MemoryImage(ImageUploadService.decodeBase64ToBytes(existingUrl)!)
                            : NetworkImage(existingUrl!) as ImageProvider),
                    fit: BoxFit.cover,
                  )
                : null,
          ),
          child: !hasImage
              ? Icon(Icons.image_outlined, color: theme.textTertiary, size: 18)
              : null,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: theme.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 11.5,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                selectedFile != null
                    ? 'Ready to upload'
                    : (existingUrl != null ? 'Uploaded' : 'No file chosen'),
                style: TextStyle(
                  color: selectedFile != null
                      ? theme.accent
                      : (existingUrl != null ? theme.textSecondary : theme.textTertiary),
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        if (hasImage) ...[
          IconButton(
            icon: Icon(Icons.delete_outline_rounded, color: theme.danger, size: 18),
            onPressed: onClear,
          ),
        ] else ...[
          TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: theme.accent,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            ),
            icon: const Icon(Icons.upload_file_rounded, size: 14),
            label: const Text('Choose', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
            onPressed: onPick,
          ),
        ],
      ],
    ),
  );
}

