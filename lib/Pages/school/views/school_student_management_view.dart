// lib/pages/school/views/school_student_management_view.dart

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../widgets/media_upload_tile.dart';
import '../../../services/image_upload_service.dart';
import '../dialogs/school_enrollment_dialog.dart';
import '../theme/school_theme.dart';
import '../models/school_student.dart';
import '../utils/school_local_storage.dart';
import '../utils/school_auth_helper.dart';
import '../utils/school_admission_pdf_service.dart';
import '../constants/school_constants.dart';

class SchoolStudentManagementView extends StatefulWidget {
  final String branchId;
  final String userRole;
  final String userName;

  const SchoolStudentManagementView({
    super.key,
    required this.branchId,
    this.userRole = 'School Admin',
    this.userName = 'User',
  });

  @override
  State<SchoolStudentManagementView> createState() => _SchoolStudentManagementViewState();
}

class _SchoolStudentManagementViewState extends State<SchoolStudentManagementView> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _selectedGradeFilter = 'All';
  String _selectedStatusFilter = 'All';

  List<String> _gradeOptions = SchoolConstants.filterGrades;

  bool get _isTeacher => SchoolAuthHelper.isTeacher(widget.userRole);

  @override
  void initState() {
    super.initState();
    _initGradeFilters();
  }

  @override
  void didUpdateWidget(covariant SchoolStudentManagementView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userRole != widget.userRole ||
        oldWidget.userName != widget.userName ||
        oldWidget.branchId != widget.branchId) {
      _initGradeFilters();
    }
  }

  void _initGradeFilters() {
    if (_isTeacher) {
      final assigned = SchoolAuthHelper.getTeacherAssignedGrades(
        widget.branchId,
        widget.userRole,
        widget.userName,
      );
      if (assigned.isNotEmpty) {
        _gradeOptions = assigned;
        if (!_gradeOptions.contains(_selectedGradeFilter)) {
          _selectedGradeFilter = _gradeOptions.first;
        }
      } else {
        _gradeOptions = [];
        _selectedGradeFilter = 'Unassigned';
      }
    } else {
      _gradeOptions = SchoolConstants.filterGrades;
      if (_selectedGradeFilter == 'Unassigned') {
        _selectedGradeFilter = 'All';
      }
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _openEnrollmentDialog([SchoolStudent? student]) async {
    if (_isTeacher) return; // Teachers cannot enroll students
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => SchoolEnrollmentDialog(
        branchId: widget.branchId,
        studentToEdit: student,
      ),
    );
    if (result == true && mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Search & Action Bar
        Container(
          padding: const EdgeInsets.all(16),
          color: Colors.white,
          child: Row(
            children: [
              // Search Input
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'Search student by name, roll no, father name or CNIC / B-Form...',
                    prefixIcon: const Icon(Icons.search_rounded, color: SchoolTheme.primary),
                    filled: true,
                    fillColor: const Color(0xFFF8FAFC),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 12),

              // Grade Filter
              DropdownButtonHideUnderline(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: DropdownButton<String>(
                    value: _selectedGradeFilter,
                    items: _gradeOptions.map((g) {
                      return DropdownMenuItem(value: g, child: Text('Grade: $g'));
                    }).toList(),
                    onChanged: (v) {
                      if (v != null) setState(() => _selectedGradeFilter = v);
                    },
                  ),
                ),
              ),
              const SizedBox(width: 12),

              // Status Filter
              DropdownButtonHideUnderline(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: DropdownButton<String>(
                    value: _selectedStatusFilter,
                    items: const [
                      DropdownMenuItem(value: 'All', child: Text('Status: All')),
                      DropdownMenuItem(value: 'active', child: Text('Active')),
                      DropdownMenuItem(value: 'graduated', child: Text('Graduated')),
                      DropdownMenuItem(value: 'dropped', child: Text('Dropped')),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _selectedStatusFilter = v);
                    },
                  ),
                ),
              ),
              if (!_isTeacher) ...[
                const SizedBox(width: 16),
                // Add Student Button
                ElevatedButton.icon(
                  onPressed: () => _openEnrollmentDialog(),
                  icon: const Icon(Icons.person_add_alt_1_rounded, size: 16),
                  label: const Text('New Admission / داخلہ نیا طالب علم', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: SchoolTheme.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    elevation: 0,
                  ),
                ),
              ],
            ],
          ),
        ),

        const Divider(height: 1),

        // Students Grid/List
        Expanded(
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: SchoolLocalStorage.streamStudentsCached(widget.branchId),
            builder: (context, snapshot) {
              final rawList = snapshot.data ?? [];
              final query = _searchCtrl.text.trim().toLowerCase();

              var filtered = rawList.map((m) => SchoolStudent.fromMap(m['id'] ?? '', m)).toList();

              // Teacher Data Isolation:
              // Teachers can ONLY see students belonging to their assigned class(es)!
              if (_isTeacher) {
                filtered = filtered.where((s) => _gradeOptions.contains(s.grade)).toList();
              }

              if (query.isNotEmpty) {
                filtered = filtered.where((s) {
                  return s.name.toLowerCase().contains(query) ||
                      s.rollNo.toLowerCase().contains(query) ||
                      s.guardianName.toLowerCase().contains(query) ||
                      s.bformNo.toLowerCase().contains(query) ||
                      s.guardianCnic.toLowerCase().contains(query);
                }).toList();
              }

              if (_selectedGradeFilter != 'All') {
                filtered = filtered.where((s) => s.grade == _selectedGradeFilter).toList();
              }

              if (_selectedStatusFilter != 'All') {
                filtered = filtered.where((s) => s.status == _selectedStatusFilter).toList();
              }

              if (filtered.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.school_outlined, size: 64, color: Colors.grey.shade300),
                      const SizedBox(height: 12),
                      Text(
                        _isTeacher
                            ? 'No students found in your assigned class roster ($_selectedGradeFilter).'
                            : 'No school students found / کوئی طالب علم موجود نہیں',
                        style: const TextStyle(color: SchoolTheme.textMid, fontSize: 15, fontWeight: FontWeight.bold),
                      ),
                      if (!_isTeacher) ...[
                        const SizedBox(height: 6),
                        const Text(
                          'Click "+ New Admission" to enroll a student.',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ],
                    ],
                  ),
                );
              }

              return ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: filtered.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final student = filtered[index];
                  return _buildStudentTile(student);
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildStudentAvatar(SchoolStudent student) {
    final bytes = ImageUploadService.decodeBase64ToBytes(student.photoUrl);
    if (bytes != null && bytes.isNotEmpty) {
      return CircleAvatar(
        radius: 26,
        backgroundColor: SchoolTheme.primary.withValues(alpha: 0.1),
        backgroundImage: MemoryImage(bytes),
      );
    } else if (student.photoUrl.startsWith('http')) {
      return CircleAvatar(
        radius: 26,
        backgroundColor: SchoolTheme.primary.withValues(alpha: 0.1),
        backgroundImage: NetworkImage(student.photoUrl),
      );
    }
    return CircleAvatar(
      radius: 26,
      backgroundColor: SchoolTheme.primary.withValues(alpha: 0.1),
      child: Text(
        student.rollNo.isNotEmpty ? student.rollNo : 'N/A',
        style: const TextStyle(
          color: SchoolTheme.primary,
          fontWeight: FontWeight.bold,
          fontSize: 14,
        ),
      ),
    );
  }

  void _showStudentDocumentsDialog(SchoolStudent student) {
    int docCount = (student.photoUrl.isNotEmpty ? 1 : 0) +
        (student.guardianCnicUrl.isNotEmpty ? 1 : 0) +
        (student.bformUrl.isNotEmpty ? 1 : 0) +
        student.additionalDocuments.length;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.folder_shared_rounded, color: SchoolTheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Student Documents ($docCount) — ${student.name}',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 580,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (student.photoUrl.isNotEmpty) ...[
                  const Text('Student Profile Photo / تصویر طالب علم:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF475569))),
                  const SizedBox(height: 6),
                  MediaUploadTile(label: 'Student Photo (Avatar)', icon: Icons.person_outlined, initialValue: student.photoUrl, readOnly: true),
                  const SizedBox(height: 12),
                ],
                if (student.guardianCnicUrl.isNotEmpty) ...[
                  const Text("Father's CNIC Document / شناختی کارڈ والد:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF475569))),
                  const SizedBox(height: 6),
                  MediaUploadTile(label: "Father's CNIC Document", icon: Icons.badge_outlined, isDocument: true, initialValue: student.guardianCnicUrl, readOnly: true),
                  const SizedBox(height: 12),
                ],
                if (student.bformUrl.isNotEmpty) ...[
                  const Text('B-Form / Birth Certificate / ب فارم یا برتھ سرٹیفکیٹ:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF475569))),
                  const SizedBox(height: 6),
                  MediaUploadTile(label: 'B-Form / Birth Certificate Document', icon: Icons.description_outlined, isDocument: true, initialValue: student.bformUrl, readOnly: true),
                  const SizedBox(height: 12),
                ],
                if (student.additionalDocuments.isNotEmpty) ...[
                  const Text('Custom Attached Documents / دیگر دستاویزات:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF475569))),
                  const SizedBox(height: 6),
                  ...student.additionalDocuments.map((doc) => Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: MediaUploadTile(
                          label: doc['name'] ?? 'Document',
                          icon: Icons.file_present_rounded,
                          isDocument: true,
                          initialValue: doc['url'],
                          readOnly: true,
                        ),
                      )),
                ],
                if (docCount == 0)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Center(child: Text('No documents uploaded for this student yet.', style: TextStyle(color: Colors.grey))),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  void _showAdmissionSlipDialog(SchoolStudent student) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Container(
          width: 640,
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.9),
          padding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Authentic Form Box
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF0F172A), width: 1.8),
                  ),
                  child: Column(
                    children: [
                      Text(
                        'تعلیم و تربیت سکول سسٹم',
                        textAlign: TextAlign.center,
                        textDirection: TextDirection.rtl,
                        style: GoogleFonts.notoSansArabic(fontSize: 22, fontWeight: FontWeight.bold, color: const Color(0xFF0F172A)),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'گلزار مدینہ ویلفیئر فاؤنڈیشن گلزار مدینہ روڈ گجرات 0334-4687928',
                        textAlign: TextAlign.center,
                        textDirection: TextDirection.rtl,
                        style: GoogleFonts.notoSansArabic(fontSize: 12.5, fontWeight: FontWeight.w600, color: const Color(0xFF334155)),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Image.asset(
                            'assets/logo/twt.webp',
                            height: 38,
                            errorBuilder: (_, __, ___) => const Icon(Icons.school_rounded, color: SchoolTheme.primary),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            'داخلہ فارم',
                            textDirection: TextDirection.rtl,
                            style: GoogleFonts.notoSansArabic(fontSize: 18, fontWeight: FontWeight.bold, color: const Color(0xFF0F172A)),
                          ),
                        ],
                      ),
                      const Divider(color: Color(0xFF0F172A), thickness: 1.2),
                      const SizedBox(height: 8),

                      // Meta row
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('تاریخ / Date: ${student.admissionDate}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                          Text('داخلہ نمبر / Roll No: ${student.rollNo}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        ],
                      ),
                      const SizedBox(height: 14),

                      // Details rows
                      _buildSlipRow('نام طالب علم / Name:', student.name),
                      _buildSlipRow('والد کا نام / Father Name:', student.guardianName),
                      _buildSlipRow('بچے کا ب فارم نمبر / B-Form No:', student.bformNo.isNotEmpty ? student.bformNo : '—'),
                      _buildSlipRow('والد کا شناختی کارڈ نمبر / Father CNIC:', student.guardianCnic.isNotEmpty ? student.guardianCnic : '—'),
                      _buildSlipRow('تاریخ پیدائش / Date of Birth:', student.dob.isNotEmpty ? student.dob : '—'),
                      _buildSlipRow('کلاس اور سیکشن / Class & Sec:', '${student.grade} - Section ${student.section} (${student.academicGroup})'),
                      _buildSlipRow('پیشہ / Father Profession:', student.fatherProfession.isNotEmpty ? student.fatherProfession : '—'),
                      _buildSlipRow('فون نمبر / Contact Phone:', student.guardianPhone),
                      _buildSlipRow('گھر کا پتہ / Address:', student.address.isNotEmpty ? student.address : '—'),
                      _buildSlipRow('سابقہ مدرسہ/سکول / Prev School:', student.previousSchool.isNotEmpty ? student.previousSchool : '—'),
                      if (student.biometricPin.isNotEmpty)
                        _buildSlipRow('بائیو میٹرک پن / Biometric PIN:', student.biometricPin),
                      const SizedBox(height: 18),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text('دستخط والدین', textDirection: TextDirection.rtl, style: GoogleFonts.notoSansArabic(fontSize: 14, fontWeight: FontWeight.bold, color: const Color(0xFF0F172A))),
                            const SizedBox(width: 120, child: Divider(color: Color(0xFF0F172A), thickness: 1.2)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: () async {
                        await SchoolAdmissionPdfService.printAdmissionSlip(student);
                      },
                      icon: const Icon(Icons.print_rounded, size: 16),
                      label: const Text('Print / Download PDF (پرنٹ / پی ڈی ایف)'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: SchoolTheme.primary,
                        side: const BorderSide(color: SchoolTheme.primary, width: 1.2),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (!_isTeacher)
                      ElevatedButton.icon(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _openEnrollmentDialog(student);
                        },
                        icon: const Icon(Icons.edit_rounded, size: 16),
                        label: const Text('Edit Admission Form'),
                        style: ElevatedButton.styleFrom(backgroundColor: SchoolTheme.primary, foregroundColor: Colors.white),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSlipRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 220,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: Color(0xFF475569)),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF0F172A)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStudentTile(SchoolStudent student) {
    Color statusColor = const Color(0xFF10B981);
    if (student.status == 'graduated') statusColor = const Color(0xFF3B82F6);
    if (student.status == 'dropped') statusColor = const Color(0xFFEF4444);

    int docCount = (student.photoUrl.isNotEmpty ? 1 : 0) +
        (student.guardianCnicUrl.isNotEmpty ? 1 : 0) +
        (student.bformUrl.isNotEmpty ? 1 : 0) +
        student.additionalDocuments.length;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          // Student Profile Avatar
          _buildStudentAvatar(student),
          const SizedBox(width: 14),

          // Name, Grade & Father Details
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      student.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: SchoolTheme.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'Roll: ${student.rollNo}',
                        style: const TextStyle(color: SchoolTheme.primary, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  'Father: ${student.guardianName} ${student.fatherProfession.isNotEmpty ? "(${student.fatherProfession})" : ""}',
                  style: const TextStyle(fontSize: 12.5, color: Color(0xFF334155)),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: SchoolTheme.getGradeColor(student.grade).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        student.grade,
                        style: TextStyle(
                          color: SchoolTheme.getGradeColor(student.grade),
                          fontWeight: FontWeight.bold,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Sec ${student.section} • ${student.academicGroup}',
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // CNIC, B-Form & Contact Phone
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (student.bformNo.isNotEmpty)
                  Text(
                    'B-Form: ${student.bformNo}',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF334155), fontWeight: FontWeight.w600),
                  ),
                if (student.guardianCnic.isNotEmpty)
                  Text(
                    'CNIC: ${student.guardianCnic}',
                    style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700),
                  ),
                Text(
                  'Phone: ${student.guardianPhone}',
                  style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
                ),
                if (student.biometricPin.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2.0),
                    child: Row(
                      children: [
                        const Icon(Icons.fingerprint_rounded, size: 13, color: SchoolTheme.primary),
                        const SizedBox(width: 4),
                        Text(
                          'PIN: ${student.biometricPin}',
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: SchoolTheme.primary),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          // Status Badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              student.status.toUpperCase(),
              style: TextStyle(
                color: statusColor,
                fontWeight: FontWeight.bold,
                fontSize: 11,
              ),
            ),
          ),
          const SizedBox(width: 6),

          // View Admission Slip Action
          IconButton(
            tooltip: 'View / Print Admission Form (داخلہ فارم)',
            icon: const Icon(Icons.receipt_long_rounded, color: SchoolTheme.primary),
            onPressed: () => _showAdmissionSlipDialog(student),
          ),

          // Documents Viewer Icon
          IconButton(
            tooltip: 'View Student Documents ($docCount)',
            icon: Badge(
              label: Text('$docCount'),
              isLabelVisible: docCount > 0,
              child: const Icon(Icons.folder_shared_rounded, color: Color(0xFF6366F1)),
            ),
            onPressed: () => _showStudentDocumentsDialog(student),
          ),

          // Edit Action Button (Admin / Principal only)
          if (!_isTeacher)
            IconButton(
              tooltip: 'Edit Profile & Admission',
              icon: const Icon(Icons.edit_rounded, color: Color(0xFF64748B)),
              onPressed: () => _openEnrollmentDialog(student),
            ),
        ],
      ),
    );
  }
}
