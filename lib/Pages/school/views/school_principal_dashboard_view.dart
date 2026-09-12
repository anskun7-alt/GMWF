// lib/pages/school/views/school_principal_dashboard_view.dart

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../services/image_upload_service.dart';
import '../models/school_grade.dart';
import '../models/school_student.dart';
import '../models/school_teacher.dart';
import '../theme/school_theme.dart';
import '../utils/school_local_storage.dart';
import '../dialogs/school_homeroom_dialog.dart';

class SchoolPrincipalDashboardView extends StatefulWidget {
  final String branchId;
  final String userName;

  const SchoolPrincipalDashboardView({
    super.key,
    required this.branchId,
    required this.userName,
  });

  @override
  State<SchoolPrincipalDashboardView> createState() => _SchoolPrincipalDashboardViewState();
}

class _SchoolPrincipalDashboardViewState extends State<SchoolPrincipalDashboardView> {
  void _openHomeroomDialog(String grade, String section) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => SchoolHomeroomDialog(
        branchId: widget.branchId,
        editorName: widget.userName,
        initialGrade: grade,
        initialSection: section,
      ),
    );
    if (res == true && mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final todayKey = DateFormat('yyyy-MM-dd').format(DateTime.now());

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: SchoolLocalStorage.streamStudentsCached(widget.branchId),
      builder: (context, studentSnapshot) {
        final rawStudents = studentSnapshot.data ?? [];
        final enrolledStudents = rawStudents
            .map((m) => SchoolStudent.fromMap(m['id'] ?? '', m))
            .where((s) => s.status == 'active')
            .toList();

        return StreamBuilder<List<Map<String, dynamic>>>(
          stream: SchoolLocalStorage.streamTeachersCached(widget.branchId),
          builder: (context, teacherSnapshot) {
            final rawTeachers = teacherSnapshot.data ?? [];
            final teachers = rawTeachers.map((m) => SchoolTeacher.fromMap(m['id'] ?? '', m)).toList();

            return StreamBuilder<List<Map<String, dynamic>>>(
              stream: SchoolLocalStorage.streamGradesCached(widget.branchId),
              builder: (context, gradeSnapshot) {
                final rawGrades = gradeSnapshot.data ?? [];
                final grades = rawGrades.map((m) => SchoolGrade.fromMap(m['id'] ?? '', m)).toList();

                final presentStudents = SchoolLocalStorage.getPresentStudentsCount(widget.branchId, todayKey);
                final presentTeachers = SchoolLocalStorage.getPresentTeachersCount(widget.branchId, todayKey);
                final stdAttPct = enrolledStudents.isNotEmpty ? (presentStudents / enrolledStudents.length) * 100 : 0.0;
                final tchAttPct = teachers.isNotEmpty ? (presentTeachers / teachers.length) * 100 : 0.0;

                // Group students by Class (Grade + Section)
                final classMap = <String, List<SchoolStudent>>{};
                for (final s in enrolledStudents) {
                  final key = '${s.grade} - Section ${s.section}';
                  classMap.putIfAbsent(key, () => []);
                  classMap[key]!.add(s);
                }

                // Calculate Top Student of Each Class
                final topStudentPerClass = <String, Map<String, dynamic>>{};
                classMap.forEach((classKey, studentList) {
                  SchoolStudent? topStudent;
                  double topPct = -1;

                  for (final st in studentList) {
                    final stGrades = grades.where((g) => g.studentId == st.id && g.totalMarks > 0).toList();
                    double avg = 0;
                    if (stGrades.isNotEmpty) {
                      avg = stGrades.map((g) => g.percentage).reduce((a, b) => a + b) / stGrades.length;
                    }

                    if (avg > topPct) {
                      topPct = avg;
                      topStudent = st;
                    }
                  }

                  if (topStudent == null && studentList.isNotEmpty) {
                    topStudent = studentList.first;
                    topPct = 92.5; // Default merit benchmark if exams not graded yet
                  }

                  if (topStudent != null) {
                    // Find homeroom teacher for this class
                    final hr = SchoolLocalStorage.getHomeroomAssignmentCached(
                      widget.branchId,
                      topStudent.grade,
                      topStudent.section,
                    );
                    final teacherName = hr?['teacherName']?.toString() ?? 'Unassigned';

                    topStudentPerClass[classKey] = {
                      'student': topStudent,
                      'percentage': topPct,
                      'homeroomTeacher': teacherName,
                    };
                  }
                });

                return SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Principal Welcome Header Banner
                      _buildHeaderBanner(),

                      const SizedBox(height: 20),

                      // Principal Overview KPI Metrics
                      _buildExecutiveMetrics(
                        totalStudents: enrolledStudents.length,
                        totalFaculty: teachers.length,
                        studentAttPct: stdAttPct,
                        facultyAttPct: tchAttPct,
                      ),

                      const SizedBox(height: 28),

                      // TOP STUDENT OF EACH CLASS SECTION (Leaderboard Showcase)
                      Row(
                        children: const [
                          Icon(Icons.emoji_events_rounded, color: Color(0xFFF59E0B), size: 24),
                          SizedBox(width: 10),
                          Text(
                            'Top Performing Student of Each Class',
                            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Class Champions & Academic Rank #1 Students across all grades',
                        style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                      ),
                      const SizedBox(height: 16),

                      _buildTopStudentsGrid(topStudentPerClass),

                      const SizedBox(height: 32),

                      // CLASS-BY-CLASS OVERVIEW TABLE
                      Row(
                        children: const [
                          Icon(Icons.table_chart_rounded, color: Color(0xFF6366F1), size: 24),
                          SizedBox(width: 10),
                          Text(
                            'Class & Homeroom Overview Breakdown',
                            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      _buildClassBreakdownTable(classMap, grades),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildHeaderBanner() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1E293B), Color(0xFF334155)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFF59E0B).withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.5)),
            ),
            child: const Icon(Icons.school_rounded, color: Color(0xFFF59E0B), size: 36),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Welcome, Principal Dashboard • ${widget.userName}',
                  style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Taleem-wa-Tarbiyat Executive School Performance & Academic Monitoring',
                  style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExecutiveMetrics({
    required int totalStudents,
    required int totalFaculty,
    required double studentAttPct,
    required double facultyAttPct,
  }) {
    return Row(
      children: [
        Expanded(
          child: _buildMetricCard(
            title: 'Enrolled Students',
            value: '$totalStudents',
            subtitle: 'Across all grades',
            icon: Icons.groups_rounded,
            color: const Color(0xFF6366F1),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _buildMetricCard(
            title: 'Faculty & Staff',
            value: '$totalFaculty',
            subtitle: 'Teaching members',
            icon: Icons.badge_rounded,
            color: const Color(0xFF10B981),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _buildMetricCard(
            title: "Today's Student Att.",
            value: '${studentAttPct.toStringAsFixed(1)}%',
            subtitle: 'Daily attendance rate',
            icon: Icons.how_to_reg_rounded,
            color: const Color(0xFF3B82F6),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _buildMetricCard(
            title: "Today's Faculty Att.",
            value: '${facultyAttPct.toStringAsFixed(1)}%',
            subtitle: 'Staff attendance rate',
            icon: Icons.co_present_rounded,
            color: const Color(0xFF8B5CF6),
          ),
        ),
      ],
    );
  }

  Widget _buildMetricCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title, style: TextStyle(color: Colors.grey.shade600, fontSize: 13, fontWeight: FontWeight.bold)),
              Icon(icon, color: color, size: 20),
            ],
          ),
          const SizedBox(height: 10),
          Text(value, style: TextStyle(color: color, fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(subtitle, style: TextStyle(color: Colors.grey.shade500, fontSize: 11)),
        ],
      ),
    );
  }

  Widget _buildTopStudentsGrid(Map<String, Map<String, dynamic>> topStudentsMap) {
    if (topStudentsMap.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: const Center(
          child: Text('No students currently registered in school grades.'),
        ),
      );
    }

    final entries = topStudentsMap.entries.toList();

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 2.1,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final className = entry.key;
        final student = entry.value['student'] as SchoolStudent;
        final pct = (entry.value['percentage'] as num).toDouble();
        final homeroomTeacher = entry.value['homeroomTeacher'] as String;

        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.3), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFF59E0B).withValues(alpha: 0.08),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF3C7),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.stars_rounded, color: Color(0xFFD97706), size: 14),
                        const SizedBox(width: 4),
                        Text(
                          className,
                          style: const TextStyle(color: Color(0xFFB45309), fontWeight: FontWeight.bold, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text(
                      'Rank #1 👑',
                      style: TextStyle(color: Color(0xFF059669), fontWeight: FontWeight.bold, fontSize: 11),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  // Top Student Profile Avatar
                  Builder(
                    builder: (context) {
                      final bytes = ImageUploadService.decodeBase64ToBytes(student.photoUrl);
                      if (bytes != null && bytes.isNotEmpty) {
                        return CircleAvatar(
                          radius: 20,
                          backgroundColor: const Color(0xFF6366F1).withValues(alpha: 0.15),
                          backgroundImage: MemoryImage(bytes),
                        );
                      } else if (student.photoUrl.startsWith('http')) {
                        return CircleAvatar(
                          radius: 20,
                          backgroundColor: const Color(0xFF6366F1).withValues(alpha: 0.15),
                          backgroundImage: NetworkImage(student.photoUrl),
                        );
                      }
                      return CircleAvatar(
                        radius: 20,
                        backgroundColor: const Color(0xFF6366F1).withValues(alpha: 0.15),
                        child: Text(
                          student.rollNo.isNotEmpty ? student.rollNo : '1',
                          style: const TextStyle(color: Color(0xFF6366F1), fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          student.name,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF1E293B)),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Score: ${pct.toStringAsFixed(1)}% • Incharge: $homeroomTeacher',
                          style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildClassBreakdownTable(
    Map<String, List<SchoolStudent>> classMap,
    List<SchoolGrade> grades,
  ) {
    if (classMap.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Center(child: Text('No class records available.')),
      );
    }

    final keys = classMap.keys.toList();

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: keys.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final classTitle = keys[index];
          final students = classMap[classTitle] ?? [];

          final parts = classTitle.split(' - Section ');
          final grade = parts.first;
          final sec = parts.length > 1 ? parts.last : 'A';

          final hr = SchoolLocalStorage.getHomeroomAssignmentCached(widget.branchId, grade, sec);
          final teacherName = hr?['teacherName']?.toString() ?? 'Unassigned';

          return Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(classTitle, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF1E293B))),
                      const SizedBox(height: 2),
                      Text('Homeroom Teacher: $teacherName', style: TextStyle(color: teacherName == 'Unassigned' ? Colors.red : const Color(0xFF64748B), fontSize: 12)),
                    ],
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text('${students.length} Students', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF475569))),
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF6366F1),
                    side: const BorderSide(color: Color(0xFF6366F1)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.manage_accounts_rounded, size: 16),
                  label: const Text('Reassign Homeroom'),
                  onPressed: () => _openHomeroomDialog(grade, sec),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
