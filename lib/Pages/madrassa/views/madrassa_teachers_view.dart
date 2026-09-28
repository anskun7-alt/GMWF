// lib/pages/madrassa/views/madrassa_teachers_view.dart
//
// Principal page for Madrassa:
// 1. Teacher Daily Attendance (strictly Present, Absent, or Leave)
// 2. Teacher Directory & Management (all teacher details editable)
// Offline-first: Hive local cache -> LAN broadcast -> Firestore sync

import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../dialogs/madrassa_edit_teacher_dialog.dart';
import '../dialogs/register_teacher_dialog.dart';
import '../utils/madrassa_local_storage.dart';
import '../utils/madrassa_report_helper.dart';
import '../madrassa_strings.dart';

class MadrassaTeachersView extends StatefulWidget {
  final String branchId;
  final String principalUsername;
  final String role;

  const MadrassaTeachersView({
    super.key,
    required this.branchId,
    required this.principalUsername,
    required this.role,
  });

  @override
  State<MadrassaTeachersView> createState() => _MadrassaTeachersViewState();
}

class _MadrassaTeachersViewState extends State<MadrassaTeachersView>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _searchCtrl = TextEditingController();

  DateTime _selectedDate = DateTime.now();
  final Map<String, Map<String, dynamic>> _localAttendanceChanges = {};
  bool _isSavingAttendance = false;

  String _filterSpec = 'All';
  String _filterShift = 'All';

  static const _emerald = Color(0xFF0F766E);
  static const _presentColor = Color(0xFF10B981);
  static const _absentColor = Color(0xFFEF4444);
  static const _leaveColor = Color(0xFFF59E0B);

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _initialLoad();
  }

  Future<void> _initialLoad() async {
    final dateKey = DateFormat('yyyy-MM-dd').format(_selectedDate);
    unawaited(MadrassaLocalStorage.downloadTeachers(widget.branchId));
    unawaited(MadrassaLocalStorage.downloadTeacherAttendance(widget.branchId, dateKey));
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  bool _isDark(BuildContext ctx) => Theme.of(ctx).brightness == Brightness.dark;

  // ── Teacher Data Extraction Helpers ────────────────────────────────────────
  static bool _isSpecKeyword(String val) {
    final v = val.toLowerCase().trim();
    return v == 'nazra' ||
        v == 'hifz' ||
        v == 'both' ||
        v == 'hifz & nazra' ||
        v == 'nazra & hifz';
  }

  static String _extractUsername(Map<String, dynamic> teacher) {
    final u = (teacher['username'] ?? '').toString().trim();
    if (u.isNotEmpty) return u;

    final displayName = (teacher['displayName'] ?? '').toString().trim();
    if (displayName.isNotEmpty && !_isSpecKeyword(displayName)) {
      return displayName;
    }
    final name = (teacher['name'] ?? '').toString().trim();
    if (name.isNotEmpty && !_isSpecKeyword(name)) {
      return name;
    }
    return (teacher['id'] ?? teacher['uid'] ?? 'Teacher').toString();
  }

  static String? _extractRealName(Map<String, dynamic> teacher, String username) {
    final displayName = (teacher['displayName'] ?? '').toString().trim();
    if (displayName.isNotEmpty &&
        !_isSpecKeyword(displayName) &&
        displayName.toLowerCase() != username.toLowerCase()) {
      return displayName;
    }
    final name = (teacher['name'] ?? '').toString().trim();
    if (name.isNotEmpty &&
        !_isSpecKeyword(name) &&
        name.toLowerCase() != username.toLowerCase()) {
      return name;
    }
    return null;
  }

  static String _extractSpecialization(Map<String, dynamic> teacher) {
    // 1. Direct explicit field
    final direct = (teacher['specialization'] ?? teacher['teachingType'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    if (direct.isNotEmpty && direct != 'null') {
      if (direct.contains('both') || (direct.contains('nazra') && direct.contains('hifz'))) {
        return 'both';
      }
      if (direct.contains('nazra')) return 'nazra';
      if (direct.contains('hifz')) return 'hifz';
    }

    // 2. Legacy: check if 'name' was used to store 'nazra', 'hifz', or 'both'
    final rawName = (teacher['name'] ?? '').toString().trim().toLowerCase();
    if (rawName == 'nazra' || rawName.contains('nazra')) {
      if (rawName.contains('hifz') || rawName.contains('both')) return 'both';
      return 'nazra';
    }
    if (rawName == 'hifz' || rawName.contains('hifz')) {
      if (rawName.contains('nazra') || rawName.contains('both')) return 'both';
      return 'hifz';
    }
    if (rawName == 'both') return 'both';

    // 3. Role
    final role = (teacher['role'] ?? '').toString().trim().toLowerCase();
    if (role.contains('nazra')) return 'nazra';
    if (role.contains('hifz')) return 'hifz';

    return 'hifz';
  }

  static bool _isNazraTeacher(Map<String, dynamic> teacher) {
    final spec = _extractSpecialization(teacher);
    return spec == 'nazra' || spec == 'both';
  }

  static bool _isHifzTeacher(Map<String, dynamic> teacher) {
    final spec = _extractSpecialization(teacher);
    return spec == 'hifz' || spec == 'both';
  }

  // ── Date Navigation ────────────────────────────────────────────────────────
  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 30)),
    );
    if (picked != null && picked != _selectedDate) {
      setState(() {
        _selectedDate = picked;
        _localAttendanceChanges.clear();
      });
      final dateKey = DateFormat('yyyy-MM-dd').format(picked);
      unawaited(MadrassaLocalStorage.downloadTeacherAttendance(widget.branchId, dateKey));
    }
  }

  // ── Attendance Actions ─────────────────────────────────────────────────────
  void _markAllPresent(List<Map<String, dynamic>> teachers) {
    setState(() {
      for (final t in teachers) {
        final id = (t['id'] ?? t['uid'] ?? t['username']).toString();
        _localAttendanceChanges.putIfAbsent(id, () => {});
        _localAttendanceChanges[id]!['status'] = 'present';
        _localAttendanceChanges[id]!['leaveReason'] = '';
        _localAttendanceChanges[id]!['markedAt'] = DateTime.now().toIso8601String();
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('All teachers set to Present for this date.'),
        duration: Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ── Mandatory Leave Reason Prompt ──────────────────────────────────────────
  Future<String?> _promptLeaveReason({
    required String teacherName,
    String initialReason = '',
  }) async {
    final textCtrl = TextEditingController(text: initialReason);
    String? selectedPreset;

    final presets = [
      context.isUrdu ? 'طبی معائنہ / بیماری' : 'Medical / Sick Leave',
      context.isUrdu ? 'خاندانی ایمرجنسی' : 'Family Emergency',
      context.isUrdu ? 'ذاتی ضروری کام' : 'Personal Urgent Work',
      context.isUrdu ? 'سرکاری سفر / ڈیوٹی' : 'Official Duty / Travel',
      context.isUrdu ? 'اتفاقی رخصت' : 'Casual Leave',
    ];

    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final dark = _isDark(ctx);
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final isSaveDisabled = textCtrl.text.trim().isEmpty;

            return AlertDialog(
              backgroundColor: dark ? const Color(0xFF131B2E) : Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: _leaveColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.event_note_rounded, color: _leaveColor, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.isUrdu ? 'رخصت کی وجہ' : 'Leave Reason Required',
                          style: context.urduStyle(
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: dark ? Colors.white : const Color(0xFF0F172A),
                            ),
                          ),
                        ),
                        Text(
                          '$teacherName • ${DateFormat('d MMM yyyy').format(_selectedDate)}',
                          style: TextStyle(
                            fontSize: 12,
                            color: dark ? Colors.white60 : Colors.black54,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                      decoration: BoxDecoration(
                        color: _leaveColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: _leaveColor.withValues(alpha: 0.25)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline_rounded, size: 15, color: _leaveColor),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              context.isUrdu
                                  ? 'استاد کی رخصت کے لیے وجہ درج کرنا لازمی ہے۔'
                                  : 'A documented reason is mandatory to record teacher leave.',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: dark ? const Color(0xFFFBBF24) : const Color(0xFFB45309),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      context.isUrdu ? 'فوری وجوہات منتخب کریں:' : 'Quick Select Preset:',
                      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: dark ? Colors.white70 : Colors.black87),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: presets.map((p) {
                        final isSel = selectedPreset == p || textCtrl.text == p;
                        return InkWell(
                          onTap: () {
                            setDialogState(() {
                              selectedPreset = p;
                              textCtrl.text = p;
                            });
                          },
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                            decoration: BoxDecoration(
                              color: isSel
                                  ? _leaveColor.withValues(alpha: 0.2)
                                  : (dark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9)),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isSel ? _leaveColor : (dark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
                                width: isSel ? 1.2 : 1,
                              ),
                            ),
                            child: Text(
                              p,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: isSel ? FontWeight.bold : FontWeight.w500,
                                color: isSel ? _leaveColor : (dark ? Colors.white70 : const Color(0xFF334155)),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      context.isUrdu ? 'تفصیلی وجہ (لازمی):' : 'Detailed Reason (Mandatory):',
                      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: dark ? Colors.white70 : Colors.black87),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: textCtrl,
                      maxLines: 3,
                      autofocus: true,
                      onChanged: (_) => setDialogState(() {}),
                      decoration: InputDecoration(
                        hintText: context.isUrdu ? 'رخصت کی تفصیل درج کریں...' : 'Enter reason for leave...',
                        hintStyle: TextStyle(fontSize: 12, color: dark ? Colors.white38 : Colors.black38),
                        filled: true,
                        fillColor: dark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: dark ? const Color(0xFF334155) : const Color(0xFFCBD5E1))),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: dark ? const Color(0xFF334155) : const Color(0xFFCBD5E1))),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: _leaveColor, width: 1.5)),
                        contentPadding: const EdgeInsets.all(10),
                      ),
                      style: TextStyle(fontSize: 13, color: dark ? Colors.white : Colors.black87),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, null),
                  child: Text(context.isUrdu ? 'منسوخ' : 'Cancel', style: TextStyle(color: dark ? Colors.white60 : Colors.black54)),
                ),
                ElevatedButton.icon(
                  onPressed: isSaveDisabled ? null : () => Navigator.pop(ctx, textCtrl.text.trim()),
                  icon: const Icon(Icons.check_rounded, size: 16),
                  label: Text(context.isUrdu ? 'رخصت منظور کریں' : 'Confirm Leave'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _leaveColor,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.grey.shade400,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ── Monthly Presence & Leave Reason Report Modal ────────────────────────────
  Future<void> _showMonthlyPresenceDialog(
    BuildContext context, {
    required List<Map<String, dynamic>> teachers,
    Map<String, dynamic>? preselectedTeacher,
  }) async {
    int selectedYear = _selectedDate.year;
    int selectedMonth = _selectedDate.month;
    String selectedTeacherId = preselectedTeacher != null
        ? (preselectedTeacher['id'] ?? preselectedTeacher['uid'] ?? preselectedTeacher['username']).toString()
        : 'ALL';
    bool isExporting = false;
    String exportStatus = '';

    await showDialog(
      context: context,
      builder: (ctx) {
        final dark = _isDark(ctx);
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            final monthDisplay = DateFormat('MMMM yyyy').format(DateTime(selectedYear, selectedMonth));

            return AlertDialog(
              backgroundColor: dark ? const Color(0xFF131B2E) : Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F766E).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.file_download_rounded, color: Color(0xFF0F766E), size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.isUrdu ? 'ماہانہ حاضری رپورٹ' : 'Monthly Presence Download',
                          style: context.urduStyle(
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: dark ? Colors.white : const Color(0xFF0F172A),
                            ),
                          ),
                        ),
                        Text(
                          context.isUrdu ? 'حاضری اور رخصت کی تفصیلی رپورٹ' : 'Presence records with mandatory leave reasons',
                          style: TextStyle(fontSize: 11.5, color: dark ? Colors.white60 : Colors.black54),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 440,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Month Picker Row
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: dark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: dark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.chevron_left_rounded),
                            onPressed: () {
                              setDialogState(() {
                                if (selectedMonth == 1) {
                                  selectedMonth = 12;
                                  selectedYear--;
                                } else {
                                  selectedMonth--;
                                }
                              });
                            },
                          ),
                          Row(
                            children: [
                              const Icon(Icons.calendar_month_rounded, size: 18, color: Color(0xFF0F766E)),
                              const SizedBox(width: 8),
                              Text(
                                monthDisplay,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                              ),
                            ],
                          ),
                          IconButton(
                            icon: const Icon(Icons.chevron_right_rounded),
                            onPressed: () {
                              setDialogState(() {
                                if (selectedMonth == 12) {
                                  selectedMonth = 1;
                                  selectedYear++;
                                } else {
                                  selectedMonth++;
                                }
                              });
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),

                    // Teacher Selection
                    Text(
                      context.isUrdu ? 'استاد منتخب کریں:' : 'Select Faculty / Teacher:',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: dark ? Colors.white70 : Colors.black87),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: dark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: dark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: selectedTeacherId,
                          isExpanded: true,
                          dropdownColor: dark ? const Color(0xFF1E293B) : Colors.white,
                          items: [
                            DropdownMenuItem(
                              value: 'ALL',
                              child: Row(
                                children: [
                                  const Icon(Icons.groups_rounded, size: 18, color: Color(0xFF0F766E)),
                                  const SizedBox(width: 8),
                                  Text(
                                    context.isUrdu ? 'تمام اساتذہ (پورے برانچ کا خلاصہ)' : 'All Faculty (Complete Branch Matrix)',
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                            ...teachers.map((t) {
                              final id = (t['id'] ?? t['uid'] ?? t['username']).toString();
                              final name = _extractUsername(t);
                              final spec = _extractSpecialization(t).toUpperCase();
                              return DropdownMenuItem(
                                value: id,
                                child: Text(
                                  '$name ($spec)',
                                  style: const TextStyle(fontSize: 13),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              );
                            }),
                          ],
                          onChanged: (val) {
                            if (val != null) setDialogState(() => selectedTeacherId = val);
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    if (isExporting) ...[
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Column(
                            children: [
                              const CircularProgressIndicator(color: Color(0xFF0F766E), strokeWidth: 2.5),
                              const SizedBox(height: 10),
                              Text(exportStatus, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                      ),
                    ] else ...[
                      Text(
                        context.isUrdu ? 'ڈاؤن لوڈ فارمیٹ:' : 'Export Format:',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: dark ? Colors.white70 : Colors.black87),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () async {
                                setDialogState(() {
                                  isExporting = true;
                                  exportStatus = 'Preparing PDF Report...';
                                });
                                try {
                                  final monthlyLogs = await MadrassaLocalStorage.getMonthlyTeacherAttendance(
                                    branchId: widget.branchId,
                                    year: selectedYear,
                                    month: selectedMonth,
                                  );

                                  String branchDisplayName = widget.branchId.toUpperCase();
                                  try {
                                    if (Hive.isBoxOpen('app_settings')) {
                                      final box = Hive.box('app_settings');
                                      final bn = box.get('branch_name_${widget.branchId.toLowerCase()}');
                                      if (bn is String && bn.isNotEmpty) branchDisplayName = bn;
                                    }
                                  } catch (_) {}

                                  if (selectedTeacherId == 'ALL') {
                                    await MadrassaReportHelper.generateAllTeachersMonthlyAttendancePdf(
                                      branchId: widget.branchId,
                                      branchName: branchDisplayName,
                                      year: selectedYear,
                                      month: selectedMonth,
                                      teachers: teachers,
                                      monthlyLogs: monthlyLogs,
                                    );
                                  } else {
                                    final teacher = teachers.firstWhere(
                                      (t) => (t['id'] ?? t['uid'] ?? t['username']).toString() == selectedTeacherId,
                                      orElse: () => teachers.first,
                                    );
                                    await MadrassaReportHelper.generateTeacherMonthlyAttendancePdf(
                                      branchId: widget.branchId,
                                      branchName: branchDisplayName,
                                      year: selectedYear,
                                      month: selectedMonth,
                                      teacher: teacher,
                                      monthlyLogs: monthlyLogs,
                                    );
                                  }
                                } catch (e) {
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error generating PDF: $e')));
                                  }
                                } finally {
                                  if (dialogCtx.mounted) Navigator.pop(dialogCtx);
                                }
                              },
                              icon: const Icon(Icons.picture_as_pdf_rounded, size: 16),
                              label: const Text('PDF Document'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF0F766E),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () async {
                                setDialogState(() {
                                  isExporting = true;
                                  exportStatus = 'Preparing Excel Spreadsheet...';
                                });
                                try {
                                  final monthlyLogs = await MadrassaLocalStorage.getMonthlyTeacherAttendance(
                                    branchId: widget.branchId,
                                    year: selectedYear,
                                    month: selectedMonth,
                                  );

                                  String branchDisplayName = widget.branchId.toUpperCase();
                                  try {
                                    if (Hive.isBoxOpen('app_settings')) {
                                      final box = Hive.box('app_settings');
                                      final bn = box.get('branch_name_${widget.branchId.toLowerCase()}');
                                      if (bn is String && bn.isNotEmpty) branchDisplayName = bn;
                                    }
                                  } catch (_) {}

                                  if (selectedTeacherId == 'ALL') {
                                    await MadrassaReportHelper.exportAllTeachersMonthlyAttendanceExcel(
                                      branchId: widget.branchId,
                                      branchName: branchDisplayName,
                                      year: selectedYear,
                                      month: selectedMonth,
                                      teachers: teachers,
                                      monthlyLogs: monthlyLogs,
                                    );
                                  } else {
                                    final teacher = teachers.firstWhere(
                                      (t) => (t['id'] ?? t['uid'] ?? t['username']).toString() == selectedTeacherId,
                                      orElse: () => teachers.first,
                                    );
                                    await MadrassaReportHelper.exportTeacherMonthlyAttendanceExcel(
                                      branchId: widget.branchId,
                                      branchName: branchDisplayName,
                                      year: selectedYear,
                                      month: selectedMonth,
                                      teacher: teacher,
                                      monthlyLogs: monthlyLogs,
                                    );
                                  }
                                } catch (e) {
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error exporting Excel: $e')));
                                  }
                                } finally {
                                  if (dialogCtx.mounted) Navigator.pop(dialogCtx);
                                }
                              },
                              icon: const Icon(Icons.table_view_rounded, size: 16),
                              label: const Text('Excel (.xlsx)'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF10B981),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(context.isUrdu ? 'بند کریں' : 'Close', style: TextStyle(color: dark ? Colors.white60 : Colors.black54)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ── Save Attendance Log with Mandatory Leave Reason Enforcement ─────────────
  Future<void> _saveAttendanceLog(List<Map<String, dynamic>> teachers) async {
    final dateKey = DateFormat('yyyy-MM-dd').format(_selectedDate);
    final cachedLog = MadrassaLocalStorage.getTeacherAttendanceCached(widget.branchId, dateKey);
    final entries = Map<String, dynamic>.from((cachedLog?['entries'] as Map?) ?? {});

    // STRICT VALIDATION: Ensure no teacher is marked on leave without a documented reason!
    for (final t in teachers) {
      final id = (t['id'] ?? t['uid'] ?? t['username']).toString();
      final existingStatus = entries[id]?['status']?.toString();
      final changedStatus = _localAttendanceChanges[id]?['status']?.toString();
      final finalStatus = (changedStatus ?? existingStatus ?? 'present').toLowerCase();

      if (finalStatus == 'leave') {
        final reason = (_localAttendanceChanges[id]?['leaveReason'] ?? entries[id]?['leaveReason'] ?? '').toString().trim();
        if (reason.isEmpty) {
          final teacherName = _extractUsername(t);
          if (mounted) {
            showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                title: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, color: _leaveColor, size: 24),
                    const SizedBox(width: 8),
                    Text(context.isUrdu ? 'رخصت کی وجہ لازمی ہے' : 'Leave Reason Required'),
                  ],
                ),
                content: Text(
                  context.isUrdu
                      ? 'استاد "$teacherName" کو بغیر وجہ رخصت پر نشان زد نہیں کیا جا سکتا۔ براہ کرم رخصت کی وجہ درج کریں۔'
                      : 'Teacher "$teacherName" is marked on leave without a documented reason. Leave cannot be included without a valid reason.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('OK'),
                  ),
                ],
              ),
            );
          }
          return;
        }
      }
    }

    setState(() => _isSavingAttendance = true);

    // Build finalized entries
    for (final t in teachers) {
      final id = (t['id'] ?? t['uid'] ?? t['username']).toString();
      final existingStatus = entries[id]?['status']?.toString();
      final changedStatus = _localAttendanceChanges[id]?['status']?.toString();
      final finalStatus = (changedStatus ?? existingStatus ?? 'present').toLowerCase();
      final reason = (_localAttendanceChanges[id]?['leaveReason'] ?? entries[id]?['leaveReason'] ?? '').toString().trim();

      entries[id] = {
        ...?entries[id],
        ...?_localAttendanceChanges[id],
        'status': finalStatus,
        'leaveReason': finalStatus == 'leave' ? reason : '',
        'teacherName': _extractUsername(t),
        'specialization': _extractSpecialization(t),
        'session': t['session'] ?? 'morning',
        'markedAt': DateTime.now().toIso8601String(),
        'markedBy': widget.principalUsername,
      };
    }

    try {
      await MadrassaLocalStorage.saveTeacherAttendanceLocalAndSync(
        branchId: widget.branchId,
        dateKey: dateKey,
        entries: entries,
        editorName: widget.principalUsername,
      );

      if (mounted) {
        setState(() {
          _localAttendanceChanges.clear();
          _isSavingAttendance = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Row(children: [
              Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
              SizedBox(width: 8),
              Text('Teacher attendance saved offline & queued for cloud sync ✓'),
            ]),
            backgroundColor: _emerald,
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSavingAttendance = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving attendance: $e'),
            backgroundColor: _absentColor,
          ),
        );
      }
    }
  }

  // ── Register New Teacher ───────────────────────────────────────────────────
  Future<void> _openRegisterDialog() async {
    String branchDisplayName = widget.branchId.toUpperCase();
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final bn = box.get('branch_name_${widget.branchId.toLowerCase()}');
        if (bn is String && bn.isNotEmpty) branchDisplayName = bn;
      }
    } catch (_) {}

    final registered = await showRegisterTeacherDialog(
      context,
      branchId: widget.branchId,
      branchName: branchDisplayName,
      principalUsername: widget.principalUsername,
    );
    if (registered == true && mounted) {
      await MadrassaLocalStorage.downloadTeachers(widget.branchId, force: true);
      setState(() {});
    }
  }

  // ── Edit Teacher Details ───────────────────────────────────────────────────
  Future<void> _openEditTeacherDialog(Map<String, dynamic> teacher) async {
    final updated = await showMadrassaEditTeacherDialog(
      context,
      branchId: widget.branchId,
      teacher: teacher,
      principalUsername: widget.principalUsername,
    );
    if (updated == true && mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context);
    final cardBg = dark ? const Color(0xFF131B2E) : Colors.white;
    final borderColor = dark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0);
    final textPrimary = dark ? const Color(0xFFF1F5F9) : const Color(0xFF0F172A);
    final textMuted = dark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: MadrassaLocalStorage.streamTeachersCached(widget.branchId),
      builder: (context, snapshot) {
        final allTeachers = snapshot.data ?? MadrassaLocalStorage.getAllTeachersCached(widget.branchId);

        return Scaffold(
          backgroundColor: Colors.transparent,
          body: Column(
            children: [
              // Header Toolbar
              _buildTopBar(context, dark, cardBg, borderColor, textPrimary, textMuted, allTeachers),
              // Tab View
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    // Tab 1: Attendance
                    _buildAttendanceTab(context, dark, cardBg, borderColor, textPrimary, textMuted, allTeachers),
                    // Tab 2: Directory & Management
                    _buildDirectoryTab(context, dark, cardBg, borderColor, textPrimary, textMuted, allTeachers),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Top Bar & Tabs ─────────────────────────────────────────────────────────
  Widget _buildTopBar(
    BuildContext context,
    bool dark,
    Color cardBg,
    Color borderColor,
    Color textPrimary,
    Color textMuted,
    List<Map<String, dynamic>> teachers,
  ) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      decoration: BoxDecoration(
        color: cardBg,
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final isVeryNarrow = constraints.maxWidth < 460;
              return Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: _emerald.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.school_rounded, color: _emerald, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.isUrdu ? 'اساتذہ پورٹل' : 'Faculty & Teachers Hub',
                          style: context.urduStyle(
                            style: TextStyle(
                              fontSize: isVeryNarrow ? 15.5 : 18,
                              fontWeight: FontWeight.bold,
                              color: textPrimary,
                            ),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          context.isUrdu
                              ? 'حاضری، نظام الاوقات اور اساتذہ کی تفصیلات'
                              : 'Daily attendance, profiles, shifts & teaching details',
                          style: TextStyle(fontSize: 11.5, color: textMuted),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (isVeryNarrow)
                    IconButton(
                      tooltip: context.isUrdu ? 'نیا استاد درج کریں' : 'Register Teacher',
                      icon: const Icon(Icons.person_add_rounded, color: Colors.white, size: 18),
                      style: IconButton.styleFrom(
                        backgroundColor: _emerald,
                        padding: const EdgeInsets.all(10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: _openRegisterDialog,
                    )
                  else
                    ElevatedButton.icon(
                      onPressed: _openRegisterDialog,
                      icon: const Icon(Icons.person_add_rounded, size: 16),
                      label: Text(
                        context.isUrdu ? 'نیا استاد درج کریں' : 'Register Teacher',
                        style: context.urduStyle(style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _emerald,
                        foregroundColor: Colors.white,
                        elevation: 1,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          // Tab bar (overflow-proof)
          TabBar(
            controller: _tabController,
            isScrollable: false,
            labelPadding: const EdgeInsets.symmetric(horizontal: 4),
            labelColor: dark ? const Color(0xFF2DD4BF) : _emerald,
            unselectedLabelColor: textMuted,
            indicatorColor: dark ? const Color(0xFF2DD4BF) : _emerald,
            indicatorWeight: 3,
            labelStyle: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5)),
            tabs: [
              Tab(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.checklist_rounded, size: 17),
                      const SizedBox(width: 6),
                      Text(context.isUrdu ? 'اساتذہ کی حاضری' : 'Daily Attendance'),
                    ],
                  ),
                ),
              ),
              Tab(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.badge_outlined, size: 17),
                      const SizedBox(width: 6),
                      Text('${context.isUrdu ? "اساتذہ کی تفصیلات" : "Teacher Directory"} (${teachers.length})'),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // TAB 1: ATTENDANCE (Strictly Present, Absent, or Leave)
  // ===========================================================================
  Widget _buildAttendanceTab(
    BuildContext context,
    bool dark,
    Color cardBg,
    Color borderColor,
    Color textPrimary,
    Color textMuted,
    List<Map<String, dynamic>> teachers,
  ) {
    final dateKey = DateFormat('yyyy-MM-dd').format(_selectedDate);

    return StreamBuilder<Map<String, dynamic>?>(
      stream: MadrassaLocalStorage.streamTeacherAttendanceCached(widget.branchId, dateKey),
      builder: (context, attendanceSnap) {
        final logMap = attendanceSnap.data ??
            MadrassaLocalStorage.getTeacherAttendanceCached(widget.branchId, dateKey);
        final entries = Map<String, dynamic>.from((logMap?['entries'] as Map?) ?? {});

        // Count Nazra and Hifz faculty across total branch teachers
        int totalTeachers = teachers.length;
        int nazraCount = 0;
        int hifzCount = 0;
        for (final t in teachers) {
          if (_isNazraTeacher(t)) nazraCount++;
          if (_isHifzTeacher(t)) hifzCount++;
        }

        // Filter teachers based on _filterSpec ('All', 'Nazra', 'Hifz')
        final displayedTeachers = teachers.where((t) {
          if (_filterSpec == 'Nazra') return _isNazraTeacher(t);
          if (_filterSpec == 'Hifz') return _isHifzTeacher(t);
          return true;
        }).toList();

        // Compute attendance statistics for displayed faculty
        int presentCount = 0;
        int absentCount = 0;
        int leaveCount = 0;

        for (final t in displayedTeachers) {
          final id = (t['id'] ?? t['uid'] ?? t['username']).toString();
          final status = (_localAttendanceChanges[id]?['status'] ??
                  entries[id]?['status'] ??
                  'present')
              .toString()
              .toLowerCase();
          if (status == 'present') {
            presentCount++;
          } else if (status == 'absent') {
            absentCount++;
          } else if (status == 'leave') {
            leaveCount++;
          }
        }

        return RefreshIndicator(
          onRefresh: () async {
            await MadrassaLocalStorage.downloadTeacherAttendance(widget.branchId, dateKey);
            await MadrassaLocalStorage.downloadTeachers(widget.branchId, force: true);
            if (mounted) setState(() {});
          },
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Date & Action Control Panel
                _buildAttendanceControls(
                  context,
                  dark,
                  cardBg,
                  borderColor,
                  textPrimary,
                  textMuted,
                  displayedTeachers,
                  dateKey,
                ),
                const SizedBox(height: 16),

                // Attendance KPI summary cards
                _buildAttendanceKpis(
                  context,
                  dark,
                  cardBg,
                  borderColor,
                  total: displayedTeachers.length,
                  present: presentCount,
                  absent: absentCount,
                  leave: leaveCount,
                ),
                const SizedBox(height: 20),

                // Attendance Header
                Row(
                  children: [
                    Text(
                      context.isUrdu ? 'حاضری رجسٹر' : 'Faculty Attendance Roll',
                      style: context.urduStyle(
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: textPrimary,
                        ),
                      ),
                    ),
                    const Spacer(),
                    if (_localAttendanceChanges.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.amber.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.amber.withValues(alpha: 0.4)),
                        ),
                        child: Text(
                          '${_localAttendanceChanges.length} unsaved edits',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.amber[800],
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),

                // Faculty Specialization Filter Bar (All, Nazra, Hifz)
                _buildSpecFilterBar(
                  context,
                  dark: dark,
                  cardBg: cardBg,
                  borderColor: borderColor,
                  textPrimary: textPrimary,
                  textMuted: textMuted,
                  totalCount: totalTeachers,
                  nazraCount: nazraCount,
                  hifzCount: hifzCount,
                ),
                const SizedBox(height: 12),

                // Teacher Attendance Card List
                if (teachers.isEmpty)
                  _buildEmptyState(
                    icon: Icons.person_off_outlined,
                    title: 'No Teachers Found',
                    subtitle: 'Register your madrassa teachers using the "Register Teacher" button.',
                  )
                else if (displayedTeachers.isEmpty)
                  _buildEmptyState(
                    icon: Icons.filter_alt_off_rounded,
                    title: 'No $_filterSpec Teachers',
                    subtitle: 'No teachers match the "$_filterSpec" filter in this branch.',
                  )
                else
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: displayedTeachers.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, idx) {
                      final t = displayedTeachers[idx];
                      final id = (t['id'] ?? t['uid'] ?? t['username']).toString();
                      final currentStatus = (_localAttendanceChanges[id]?['status'] ??
                              entries[id]?['status'] ??
                              'present')
                          .toString()
                          .toLowerCase();
                      final leaveReason = (_localAttendanceChanges[id]?['leaveReason'] ??
                              entries[id]?['leaveReason'] ??
                              '')
                          .toString()
                          .trim();

                      return _buildAttendanceCard(
                        context,
                        dark,
                        cardBg,
                        borderColor,
                        textPrimary,
                        textMuted,
                        teacher: t,
                        teacherId: id,
                        status: currentStatus,
                        leaveReason: leaveReason,
                        allTeachers: teachers,
                      );
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAttendanceControls(
    BuildContext context,
    bool dark,
    Color cardBg,
    Color borderColor,
    Color textPrimary,
    Color textMuted,
    List<Map<String, dynamic>> teachers,
    String dateKey,
  ) {
    final isToday = DateFormat('yyyy-MM-dd').format(DateTime.now()) == dateKey;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // Date Selector Button
          InkWell(
            onTap: _pickDate,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: _emerald.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _emerald.withValues(alpha: 0.25)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.calendar_month_rounded, color: _emerald, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    DateFormat('EEEE, d MMM yyyy').format(_selectedDate),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13.5,
                      color: _emerald,
                    ),
                  ),
                  if (isToday) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: _emerald,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'TODAY',
                        style: TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                  const SizedBox(width: 4),
                  const Icon(Icons.arrow_drop_down, color: _emerald),
                ],
              ),
            ),
          ),

          // Action Buttons
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => _markAllPresent(teachers),
                icon: const Icon(Icons.done_all_rounded, size: 16),
                label: Text(
                  context.isUrdu ? 'سب کو حاضر کریں' : 'Mark All Present',
                  style: context.urduStyle(style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _presentColor,
                  side: const BorderSide(color: _presentColor),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              OutlinedButton.icon(
                onPressed: () => _showMonthlyPresenceDialog(context, teachers: teachers),
                icon: const Icon(Icons.file_download_outlined, size: 16),
                label: Text(
                  context.isUrdu ? 'ماہانہ رپورٹ' : 'Monthly Presence',
                  style: context.urduStyle(style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF0284C7),
                  side: const BorderSide(color: Color(0xFF0284C7)),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              ElevatedButton.icon(
                onPressed: _isSavingAttendance ? null : () => _saveAttendanceLog(teachers),
                icon: _isSavingAttendance
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                      )
                    : const Icon(Icons.save_rounded, size: 16),
                label: Text(
                  _isSavingAttendance
                      ? 'Saving...'
                      : (context.isUrdu ? 'حاضری محفوظ کریں' : 'Save Attendance'),
                  style: context.urduStyle(style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _emerald,
                  foregroundColor: Colors.white,
                  elevation: 2,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAttendanceKpis(
    BuildContext context,
    bool dark,
    Color cardBg,
    Color borderColor, {
    required int total,
    required int present,
    required int absent,
    required int leave,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 600;
        final cardWidth = isNarrow ? (constraints.maxWidth - 12) / 2 : (constraints.maxWidth - 36) / 4;

        final totalTitle = _filterSpec == 'Nazra'
            ? (context.isUrdu ? 'ناظرہ اساتذہ' : 'Nazra Faculty')
            : _filterSpec == 'Hifz'
                ? (context.isUrdu ? 'حفظ اساتذہ' : 'Hifz Faculty')
                : (context.isUrdu ? 'کل اساتذہ' : 'Total Faculty');

        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _kpiCard(
              title: totalTitle,
              count: total,
              color: const Color(0xFF3B82F6),
              icon: Icons.people_alt_rounded,
              width: cardWidth,
              dark: dark,
              cardBg: cardBg,
              borderColor: borderColor,
            ),
            _kpiCard(
              title: context.isUrdu ? 'حاضر' : 'Present',
              count: present,
              color: _presentColor,
              icon: Icons.check_circle_rounded,
              width: cardWidth,
              dark: dark,
              cardBg: cardBg,
              borderColor: borderColor,
            ),
            _kpiCard(
              title: context.isUrdu ? 'غیر حاضر' : 'Absent',
              count: absent,
              color: _absentColor,
              icon: Icons.cancel_rounded,
              width: cardWidth,
              dark: dark,
              cardBg: cardBg,
              borderColor: borderColor,
            ),
            _kpiCard(
              title: context.isUrdu ? 'رخصت' : 'On Leave',
              count: leave,
              color: _leaveColor,
              icon: Icons.time_to_leave_rounded,
              width: cardWidth,
              dark: dark,
              cardBg: cardBg,
              borderColor: borderColor,
            ),
          ],
        );
      },
    );
  }

  Widget _kpiCard({
    required String title,
    required int count,
    required Color color,
    required IconData icon,
    required double width,
    required bool dark,
    required Color cardBg,
    required Color borderColor,
  }) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  count.toString(),
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
                ),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: dark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Specialization Filter Bar (All, Nazra, Hifz) ───────────────────────────
  Widget _buildSpecFilterBar(
    BuildContext context, {
    required bool dark,
    required Color cardBg,
    required Color borderColor,
    required Color textPrimary,
    required Color textMuted,
    required int totalCount,
    required int nazraCount,
    required int hifzCount,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          Icon(Icons.tune_rounded, size: 16, color: _emerald),
          const SizedBox(width: 6),
          Text(
            context.isUrdu ? 'فلٹر:' : 'Filter:',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: textMuted,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _filterPill(
                    filterKey: 'All',
                    label: context.isUrdu ? 'سب' : 'All',
                    count: totalCount,
                    icon: Icons.groups_rounded,
                    activeColor: _emerald,
                  ),
                  const SizedBox(width: 6),
                  _filterPill(
                    filterKey: 'Nazra',
                    label: context.isUrdu ? 'ناظرہ' : 'Nazra',
                    count: nazraCount,
                    icon: Icons.auto_stories_rounded,
                    activeColor: const Color(0xFF0D9488),
                  ),
                  const SizedBox(width: 6),
                  _filterPill(
                    filterKey: 'Hifz',
                    label: context.isUrdu ? 'حفظ' : 'Hifz',
                    count: hifzCount,
                    icon: Icons.mosque_rounded,
                    activeColor: const Color(0xFF4C4DDC),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterPill({
    required String filterKey,
    required String label,
    required int count,
    required IconData icon,
    required Color activeColor,
  }) {
    final isSelected = _filterSpec == filterKey;
    final dark = _isDark(context);

    return InkWell(
      onTap: () => setState(() => _filterSpec = filterKey),
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? activeColor
              : (dark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9)),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? activeColor : (dark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
            width: isSelected ? 1.4 : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 13.5,
              color: isSelected ? Colors.white : (dark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                color: isSelected ? Colors.white : (dark ? Colors.white70 : const Color(0xFF1E293B)),
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
              decoration: BoxDecoration(
                color: isSelected
                    ? Colors.white.withValues(alpha: 0.25)
                    : (dark ? Colors.black38 : Colors.black.withValues(alpha: 0.06)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                count.toString(),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: isSelected ? Colors.white : (dark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAttendanceCard(
    BuildContext context,
    bool dark,
    Color cardBg,
    Color borderColor,
    Color textPrimary,
    Color textMuted, {
    required Map<String, dynamic> teacher,
    required String teacherId,
    required String status,
    required String leaveReason,
    required List<Map<String, dynamic>> allTeachers,
  }) {
    // Extract Teacher Username as primary identifier, plus real name if distinct
    final username = _extractUsername(teacher);
    final realName = _extractRealName(teacher, username);
    final phone = (teacher['phone'] ?? '').toString().trim();
    final spec = _extractSpecialization(teacher);
    final shift = (teacher['session'] ?? 'morning').toString().trim();
    final photo = (teacher['profilePictureBase64'] ?? teacher['profilePictureUrl'] ?? teacher['avatarUrl'])?.toString();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.2 : 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isNarrow = constraints.maxWidth < 600;

          final avatar = CircleAvatar(
            radius: 22,
            backgroundColor: _emerald.withValues(alpha: 0.12),
            backgroundImage: (photo != null && photo.isNotEmpty)
                ? MemoryImage(base64Decode(photo)) as ImageProvider
                : null,
            child: (photo == null || photo.isEmpty)
                ? const Icon(Icons.person_rounded, color: _emerald, size: 22)
                : null,
          );

          final details = Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top line: Teacher Username (prominent)
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        username,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15.5,
                          color: textPrimary,
                          letterSpacing: 0.2,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (realName != null) ...[
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          '($realName)',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                            color: textMuted,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 5),
                // Below line: Is it a Nazra or Hifz teacher + Shift + Phone
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _specBadge(context, spec),
                    _shiftBadge(shift),
                    if (phone.isNotEmpty)
                      Text(
                        '• $phone',
                        style: TextStyle(fontSize: 11.5, color: textMuted),
                      ),
                  ],
                ),
              ],
            ),
          );

          // STRICT STATUS CHIPS: ONLY Present, Absent, or Leave + Monthly download button
          final statusChips = Wrap(
            spacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _statusChoiceChip(teacherId, username, 'present', context.isUrdu ? 'حاضر' : 'Present', _presentColor, status, leaveReason),
              _statusChoiceChip(teacherId, username, 'absent', context.isUrdu ? 'غیر حاضر' : 'Absent', _absentColor, status, leaveReason),
              _statusChoiceChip(teacherId, username, 'leave', context.isUrdu ? 'رخصت' : 'Leave', _leaveColor, status, leaveReason),
              IconButton(
                tooltip: 'Download Monthly Presence (${DateFormat('MMMM yyyy').format(_selectedDate)})',
                icon: const Icon(Icons.file_download_outlined, size: 20, color: Color(0xFF0284C7)),
                padding: const EdgeInsets.all(6),
                constraints: const BoxConstraints(),
                onPressed: () => _showMonthlyPresenceDialog(context, teachers: allTeachers, preselectedTeacher: teacher),
              ),
            ],
          );

          // Dedicated Leave Reason Banner (Mandatory reason indicator)
          Widget? leaveReasonBanner;
          if (status == 'leave') {
            leaveReasonBanner = Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: _leaveColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _leaveColor.withValues(alpha: 0.35)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.event_busy_rounded, size: 16, color: _leaveColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.isUrdu ? 'رخصت کی وجہ (لازمی):' : 'Documented Leave Reason (Mandatory):',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.bold,
                            color: dark ? const Color(0xFFFBBF24) : const Color(0xFFB45309),
                          ),
                        ),
                        Text(
                          leaveReason.isNotEmpty
                              ? leaveReason
                              : (context.isUrdu ? 'کوئی وجہ درج نہیں ہے (براہ کرم وجہ درج کریں)' : 'No reason recorded (Tap to enter)'),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: textPrimary,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  InkWell(
                    onTap: () async {
                      final newReason = await _promptLeaveReason(teacherName: username, initialReason: leaveReason);
                      if (newReason != null && newReason.isNotEmpty && mounted) {
                        setState(() {
                          _localAttendanceChanges.putIfAbsent(teacherId, () => {});
                          _localAttendanceChanges[teacherId]!['status'] = 'leave';
                          _localAttendanceChanges[teacherId]!['leaveReason'] = newReason;
                          _localAttendanceChanges[teacherId]!['markedAt'] = DateTime.now().toIso8601String();
                        });
                      }
                    },
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.edit_note_rounded, size: 16, color: _leaveColor),
                          const SizedBox(width: 2),
                          Text(
                            context.isUrdu ? 'ترمیم' : 'Edit',
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _leaveColor),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          }

          if (isNarrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    avatar,
                    const SizedBox(width: 12),
                    details,
                  ],
                ),
                const SizedBox(height: 10),
                Center(child: statusChips),
                if (leaveReasonBanner != null) leaveReasonBanner,
              ],
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  avatar,
                  const SizedBox(width: 12),
                  details,
                  const SizedBox(width: 12),
                  statusChips,
                ],
              ),
              if (leaveReasonBanner != null) leaveReasonBanner,
            ],
          );
        },
      ),
    );
  }

  Widget _statusChoiceChip(
    String teacherId,
    String teacherName,
    String statusKey,
    String label,
    Color color,
    String currentStatus,
    String currentLeaveReason,
  ) {
    final isSelected = currentStatus.toLowerCase() == statusKey;

    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      selectedColor: color,
      backgroundColor: _isDark(context) ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
      labelStyle: TextStyle(
        color: isSelected ? Colors.white : (_isDark(context) ? const Color(0xFFCBD5E1) : const Color(0xFF334155)),
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        fontSize: 12,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: isSelected ? color : Colors.transparent,
          width: 1.2,
        ),
      ),
      onSelected: (selected) async {
        if (selected) {
          if (statusKey == 'leave') {
            final reason = await _promptLeaveReason(teacherName: teacherName, initialReason: currentLeaveReason);
            if (reason == null || reason.trim().isEmpty) {
              // Abort! Leave CANNOT be included without a reason!
              return;
            }
            if (mounted) {
              setState(() {
                _localAttendanceChanges.putIfAbsent(teacherId, () => {});
                _localAttendanceChanges[teacherId]!['status'] = 'leave';
                _localAttendanceChanges[teacherId]!['leaveReason'] = reason.trim();
                _localAttendanceChanges[teacherId]!['markedAt'] = DateTime.now().toIso8601String();
              });
            }
            return;
          }

          setState(() {
            _localAttendanceChanges.putIfAbsent(teacherId, () => {});
            _localAttendanceChanges[teacherId]!['status'] = statusKey;
            _localAttendanceChanges[teacherId]!['leaveReason'] = '';
            _localAttendanceChanges[teacherId]!['markedAt'] = DateTime.now().toIso8601String();
          });
        }
      },
    );
  }

  // ===========================================================================
  // TAB 2: DIRECTORY & MANAGEMENT (All details editable)
  // ===========================================================================
  Widget _buildDirectoryTab(
    BuildContext context,
    bool dark,
    Color cardBg,
    Color borderColor,
    Color textPrimary,
    Color textMuted,
    List<Map<String, dynamic>> teachers,
  ) {
    final query = _searchCtrl.text.trim().toLowerCase();

    final filtered = teachers.where((t) {
      final name = (t['displayName'] ?? t['name'] ?? '').toString().toLowerCase();
      final username = _extractUsername(t).toLowerCase();
      final phone = (t['phone'] ?? '').toString().toLowerCase();
      final cnic = (t['identification'] ?? t['cnic'] ?? '').toString().toLowerCase();
      final shift = (t['session'] ?? 'morning').toString().toLowerCase();

      final matchesQuery = query.isEmpty ||
          name.contains(query) ||
          username.contains(query) ||
          phone.contains(query) ||
          cnic.contains(query);

      final matchesSpec = _filterSpec == 'All' ||
          (_filterSpec == 'Nazra' && _isNazraTeacher(t)) ||
          (_filterSpec == 'Hifz' && _isHifzTeacher(t));
      final matchesShift = _filterShift == 'All' || shift.contains(_filterShift.toLowerCase());

      return matchesQuery && matchesSpec && matchesShift;
    }).toList();

    return RefreshIndicator(
      onRefresh: () async {
        await MadrassaLocalStorage.downloadTeachers(widget.branchId, force: true);
        if (mounted) setState(() {});
      },
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Search & Filters toolbar
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: borderColor),
              ),
              child: Column(
                children: [
                  TextField(
                    controller: _searchCtrl,
                    onChanged: (_) => setState(() {}),
                    style: TextStyle(color: textPrimary, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: context.isUrdu
                          ? 'نام، یوزرنیم، فون یا شناختی کارڈ نمبر سے تلاش کریں...'
                          : 'Search by teacher name, username, phone, or CNIC...',
                      hintStyle: TextStyle(color: textMuted, fontSize: 13),
                      prefixIcon: const Icon(Icons.search_rounded, color: _emerald),
                      suffixIcon: query.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () => setState(() => _searchCtrl.clear()),
                            )
                          : null,
                      filled: true,
                      fillColor: dark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Filter Chips (Specialization & Shift)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        'Specialization:',
                        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: textMuted),
                      ),
                      for (final s in ['All', 'Nazra', 'Hifz'])
                        ChoiceChip(
                          label: Text(s),
                          selected: _filterSpec == s,
                          selectedColor: _emerald,
                          labelStyle: TextStyle(
                            color: _filterSpec == s ? Colors.white : textPrimary,
                            fontWeight: _filterSpec == s ? FontWeight.bold : FontWeight.normal,
                            fontSize: 11,
                          ),
                          onSelected: (val) {
                            if (val) setState(() => _filterSpec = s);
                          },
                        ),
                      const SizedBox(width: 12),
                      Text(
                        'Shift:',
                        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: textMuted),
                      ),
                      for (final sh in ['All', 'Morning', 'Evening', 'Night'])
                        ChoiceChip(
                          label: Text(sh),
                          selected: _filterShift == sh,
                          selectedColor: const Color(0xFF0284C7),
                          labelStyle: TextStyle(
                            color: _filterShift == sh ? Colors.white : textPrimary,
                            fontWeight: _filterShift == sh ? FontWeight.bold : FontWeight.normal,
                            fontSize: 11,
                          ),
                          onSelected: (val) {
                            if (val) setState(() => _filterShift = sh);
                          },
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Teacher Cards Grid or List
            if (filtered.isEmpty)
              _buildEmptyState(
                icon: Icons.search_off_rounded,
                title: 'No Matching Teachers Found',
                subtitle: 'Try adjusting your search query or filters.',
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: filtered.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, idx) {
                  return _buildTeacherProfileCard(
                    context,
                    dark,
                    cardBg,
                    borderColor,
                    textPrimary,
                    textMuted,
                    teacher: filtered[idx],
                    allTeachers: teachers,
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTeacherProfileCard(
    BuildContext context,
    bool dark,
    Color cardBg,
    Color borderColor,
    Color textPrimary,
    Color textMuted, {
    required Map<String, dynamic> teacher,
    required List<Map<String, dynamic>> allTeachers,
  }) {
    final username = _extractUsername(teacher);
    final realName = _extractRealName(teacher, username);
    final email = (teacher['email'] ?? '').toString().trim();
    final phone = (teacher['phone'] ?? '').toString().trim();
    final cnic = (teacher['identification'] ?? teacher['cnic'] ?? '').toString().trim();
    final address = (teacher['address'] ?? '').toString().trim();
    final spec = _extractSpecialization(teacher);
    final shift = (teacher['session'] ?? 'morning').toString().trim();
    final photo = (teacher['profilePictureBase64'] ?? teacher['profilePictureUrl'] ?? teacher['avatarUrl'])?.toString();
    final isActive = teacher['status']?.toString().toLowerCase() != 'inactive' && teacher['isActive'] != false;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: borderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.2 : 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Avatar
              CircleAvatar(
                radius: 26,
                backgroundColor: _emerald.withValues(alpha: 0.12),
                backgroundImage: (photo != null && photo.isNotEmpty)
                    ? MemoryImage(base64Decode(photo)) as ImageProvider
                    : null,
                child: (photo == null || photo.isEmpty)
                    ? const Icon(Icons.person_rounded, color: _emerald, size: 28)
                    : null,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            username,
                            style: TextStyle(
                              fontSize: 16.5,
                              fontWeight: FontWeight.bold,
                              color: textPrimary,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ),
                        if (realName != null) ...[
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              '($realName)',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: textMuted,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: (isActive ? Colors.green : Colors.red).withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: (isActive ? Colors.green : Colors.red).withValues(alpha: 0.3)),
                          ),
                          child: Text(
                            isActive ? 'ACTIVE' : 'INACTIVE',
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.bold,
                              color: isActive ? Colors.green : Colors.red,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    // Below line: Is it a Nazra or Hifz teacher badge + shift + email
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _specBadge(context, spec),
                        _shiftBadge(shift),
                        if (email.isNotEmpty)
                          Text(email, style: TextStyle(fontSize: 11.5, color: textMuted)),
                      ],
                    ),
                  ],
                ),
              ),
              // Action buttons: Monthly presence & edit details
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Download Monthly Presence',
                    icon: const Icon(Icons.file_download_outlined, size: 20, color: Color(0xFF0284C7)),
                    padding: const EdgeInsets.all(6),
                    constraints: const BoxConstraints(),
                    onPressed: () => _showMonthlyPresenceDialog(context, teachers: allTeachers, preselectedTeacher: teacher),
                  ),
                  const SizedBox(width: 4),
                  ElevatedButton.icon(
                    onPressed: () => _openEditTeacherDialog(teacher),
                    icon: const Icon(Icons.edit_rounded, size: 14),
                    label: Text(context.isUrdu ? 'ترمیم کریں' : 'Edit Details'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _emerald.withValues(alpha: 0.12),
                      foregroundColor: _emerald,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(color: _emerald.withValues(alpha: 0.25)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(height: 1),
          const SizedBox(height: 12),
          // Additional Info Rows (Contact, CNIC, Address)
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              if (phone.isNotEmpty)
                _infoPill(Icons.phone_outlined, phone, textMuted),
              if (cnic.isNotEmpty)
                _infoPill(Icons.badge_outlined, cnic, textMuted),
              if (address.isNotEmpty)
                _infoPill(Icons.location_on_outlined, address, textMuted),
            ],
          ),
        ],
      ),
    );
  }

  Widget _infoPill(IconData icon, String text, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 5),
        Text(text, style: TextStyle(fontSize: 11.5, color: color)),
      ],
    );
  }

  Widget _specBadge(BuildContext context, String spec) {
    final isUrdu = context.isUrdu;
    final s = spec.toLowerCase();
    Color bg;
    Color fg;
    String label;
    IconData icon;

    if (s.contains('both') || (s.contains('nazra') && s.contains('hifz'))) {
      bg = const Color(0xFF7C3AED).withValues(alpha: 0.14);
      fg = const Color(0xFF7C3AED);
      label = isUrdu ? 'ناظرہ و حفظ استاد' : 'Nazra & Hifz Teacher';
      icon = Icons.menu_book_rounded;
    } else if (s.contains('nazra')) {
      bg = const Color(0xFF0D9488).withValues(alpha: 0.14);
      fg = const Color(0xFF0D9488);
      label = isUrdu ? 'ناظرہ استاد' : 'Nazra Teacher';
      icon = Icons.auto_stories_rounded;
    } else {
      bg = const Color(0xFF4C4DDC).withValues(alpha: 0.14);
      fg = const Color(0xFF4C4DDC);
      label = isUrdu ? 'حفظ استاد' : 'Hifz Teacher';
      icon = Icons.mosque_rounded;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: fg.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: fg),
          const SizedBox(width: 4.5),
          Text(
            label,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: fg),
          ),
        ],
      ),
    );
  }

  Widget _shiftBadge(String shift) {
    final sh = shift.toLowerCase();
    String label;
    IconData icon;
    Color color;

    if (sh.contains('evening')) {
      label = 'Evening';
      icon = Icons.wb_twilight_rounded;
      color = const Color(0xFFD97706);
    } else if (sh.contains('night')) {
      label = 'Night';
      icon = Icons.nightlight_round;
      color = const Color(0xFF4338CA);
    } else if (sh.contains('all')) {
      label = 'Full Day';
      icon = Icons.all_inclusive_rounded;
      color = const Color(0xFF0284C7);
    } else {
      label = 'Morning';
      icon = Icons.wb_sunny_rounded;
      color = const Color(0xFF059669);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: color),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final dark = _isDark(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: _emerald.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 42, color: _emerald),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: dark ? Colors.white : const Color(0xFF1E293B),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: dark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
