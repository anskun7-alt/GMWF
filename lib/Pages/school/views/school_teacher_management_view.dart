// lib/pages/school/views/school_teacher_management_view.dart

import 'package:flutter/material.dart';
import '../../../services/image_upload_service.dart';
import '../dialogs/school_teacher_dialog.dart';
import '../models/school_teacher.dart';
import '../theme/school_theme.dart';
import '../utils/school_local_storage.dart';
import '../utils/school_auth_helper.dart';

class SchoolTeacherManagementView extends StatefulWidget {
  final String branchId;
  final String userRole;
  final String userName;

  const SchoolTeacherManagementView({
    super.key,
    required this.branchId,
    this.userRole = 'School Admin',
    this.userName = 'Admin',
  });

  @override
  State<SchoolTeacherManagementView> createState() => _SchoolTeacherManagementViewState();
}

class _SchoolTeacherManagementViewState extends State<SchoolTeacherManagementView> {
  final TextEditingController _searchCtrl = TextEditingController();

  bool get _isTeacher => SchoolAuthHelper.isTeacher(widget.userRole);

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _openTeacherDialog([SchoolTeacher? teacher]) async {
    if (_isTeacher) return; // Teachers cannot register or edit teachers
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => SchoolTeacherDialog(
        branchId: widget.branchId,
        teacherToEdit: teacher,
      ),
    );
    if (result == true && mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SchoolTheme.bgLight,
      body: Column(
        children: [
          // Search & Action Toolbar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: SchoolTheme.borderLight)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: _isTeacher
                          ? 'My Faculty Profile Record...'
                          : 'Search faculty by name, employee ID, or subject...',
                      prefixIcon: const Icon(Icons.search_rounded, color: SchoolTheme.primary, size: 20),
                      filled: true,
                      fillColor: const Color(0xFFF8FAFC),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: SchoolTheme.borderLight),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: SchoolTheme.borderLight),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: SchoolTheme.primary, width: 1.5),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                    ),
                  ),
                ),
                if (!_isTeacher) ...[
                  const SizedBox(width: 14),
                  ElevatedButton.icon(
                    onPressed: () => _openTeacherDialog(),
                    icon: const Icon(Icons.person_add_alt_1_rounded, size: 16),
                    label: const Text('Register Faculty', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: SchoolTheme.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      elevation: 0,
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Teacher List
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: SchoolLocalStorage.streamTeachersCached(widget.branchId),
              builder: (context, snapshot) {
                final rawList = snapshot.data ?? [];
                final query = _searchCtrl.text.trim().toLowerCase();

                var teachers = rawList.map((m) => SchoolTeacher.fromMap(m['id'] ?? '', m)).toList();

                // Strict Teacher Data Isolation:
                // One teacher CANNOT see another teacher's profile/data!
                if (_isTeacher) {
                  teachers = teachers.where((t) {
                    final n = t.name.toLowerCase().trim();
                    final e = t.email.toLowerCase().trim();
                    final u = widget.userName.toLowerCase().trim();
                    return n == u || e == u || (u.isNotEmpty && (n.contains(u) || u.contains(n)));
                  }).toList();
                } else if (query.isNotEmpty) {
                  teachers = teachers.where((t) {
                    return t.name.toLowerCase().contains(query) ||
                        t.employeeId.toLowerCase().contains(query) ||
                        t.subjects.any((s) => s.toLowerCase().contains(query)) ||
                        t.department.toLowerCase().contains(query);
                  }).toList();
                }

                if (teachers.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.badge_outlined, size: 56, color: Colors.grey.shade300),
                        const SizedBox(height: 12),
                        Text(
                          _isTeacher
                              ? 'No faculty profile found for user @${widget.userName}.'
                              : 'No faculty members found in registry.',
                          style: const TextStyle(color: SchoolTheme.textMid, fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                        if (!_isTeacher) ...[
                          const SizedBox(height: 6),
                          const Text('Click "+ Register Faculty" to onboard new teachers.', style: TextStyle(color: Colors.grey, fontSize: 12)),
                        ],
                      ],
                    ),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: teachers.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, idx) {
                    final t = teachers[idx];
                    return Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: SchoolTheme.radius16,
                        border: Border.all(color: SchoolTheme.borderLight),
                        boxShadow: SchoolTheme.cardShadow,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Profile picture or Avatar
                              ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Container(
                                  width: 52,
                                  height: 52,
                                  color: SchoolTheme.primaryLight,
                                  child: _buildTeacherAvatar(t),
                                ),
                              ),
                              const SizedBox(width: 14),

                              // Name & Basic Info
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          t.name,
                                          style: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                            color: SchoolTheme.textDark,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        SchoolBadge(
                                          label: t.designation,
                                          color: SchoolTheme.primary,
                                          fontSize: 11,
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'ID: ${t.employeeId.isNotEmpty ? t.employeeId : "N/A"} • ${t.department}',
                                      style: const TextStyle(
                                        color: SchoolTheme.textMuted,
                                        fontSize: 12.5,
                                      ),
                                    ),
                                    if (t.isHomeroom) ...[
                                      const SizedBox(height: 4),
                                      Row(
                                        children: [
                                          const Icon(Icons.star_rounded, size: 14, color: Colors.amber),
                                          const SizedBox(width: 4),
                                          Text(
                                            'Homeroom In-charge: Grade ${t.homeroomGrade} (Sec ${t.homeroomSection.isNotEmpty ? t.homeroomSection : "A"})',
                                            style: const TextStyle(
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.bold,
                                              color: Color(0xFFD97706),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ],
                                ),
                              ),

                              // Edit Button (Admins/Principals only)
                              if (!_isTeacher)
                                IconButton(
                                  icon: const Icon(Icons.edit_rounded, color: SchoolTheme.primary, size: 20),
                                  tooltip: 'Edit Faculty Record',
                                  onPressed: () => _openTeacherDialog(t),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          const Divider(height: 1),
                          const SizedBox(height: 10),

                          // Assigned Classes & Subjects Chips
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              if (t.assignedGrades.isNotEmpty) ...[
                                ...t.assignedGrades.map((g) => SchoolBadge(
                                      label: 'Class: $g',
                                      color: SchoolTheme.getGradeColor(g),
                                      fontSize: 11,
                                    )),
                              ],
                              if (t.subjects.isNotEmpty) ...[
                                ...t.subjects.map((s) => SchoolBadge(
                                      label: s,
                                      color: const Color(0xFF0284C7),
                                      fontSize: 11,
                                    )),
                              ],
                              if (t.degree.isNotEmpty)
                                SchoolBadge(
                                  label: t.degree,
                                  color: SchoolTheme.textMid,
                                  backgroundColor: const Color(0xFFF1F5F9),
                                  fontSize: 11,
                                ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTeacherAvatar(SchoolTeacher t) {
    if (t.photoUrl.isEmpty) {
      return const Icon(Icons.person_rounded, size: 28, color: SchoolTheme.primary);
    }
    final bytes = ImageUploadService.decodeBase64ToBytes(t.photoUrl);
    if (bytes != null && bytes.isNotEmpty) {
      return Image.memory(
        bytes,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const Icon(Icons.person_rounded, size: 28, color: SchoolTheme.primary),
      );
    }
    if (t.photoUrl.startsWith('http')) {
      return Image.network(
        t.photoUrl,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const Icon(Icons.person_rounded, size: 28, color: SchoolTheme.primary),
      );
    }
    return const Icon(Icons.person_rounded, size: 28, color: SchoolTheme.primary);
  }
}
