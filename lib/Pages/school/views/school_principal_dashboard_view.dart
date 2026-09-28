// lib/pages/school/views/school_principal_dashboard_view.dart

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/school_grade.dart';
import '../models/school_student.dart';
import '../models/school_teacher.dart';
import '../theme/school_theme.dart';
import '../utils/school_local_storage.dart';
import '../utils/school_auth_helper.dart';
import '../dialogs/school_homeroom_dialog.dart';
import '../../../theme/role_theme_provider.dart';

class SchoolPrincipalDashboardView extends StatefulWidget {
  final String branchId;
  final String userName;
  final String userRole;

  const SchoolPrincipalDashboardView({
    super.key,
    required this.branchId,
    required this.userName,
    this.userRole = 'School Principal',
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
    if (SchoolAuthHelper.isTeacher(widget.userRole)) {
      return const SchoolAccessDenied(
        title: 'Principal Dashboard Restricted',
        message: 'The Principal Dashboard is reserved for Institutional Leadership and School Administration. Teachers cannot access administrative oversight.',
      );
    }

    final t = RoleThemeScope.dataOf(context);
    final todayKey = DateFormat('yyyy-MM-dd').format(DateTime.now());

    return Scaffold(
      backgroundColor: t.bg,
      body: StreamBuilder<List<Map<String, dynamic>>>(
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
                      topPct = 0;
                    }

                    if (topStudent != null) {
                      topStudentPerClass[classKey] = {
                        'student': topStudent,
                        'percentage': topPct,
                      };
                    }
                  });

                  return SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Executive Welcome Banner
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFF0F172A), Color(0xFF1E293B), Color(0xFF1E1B4B)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: SchoolTheme.radius20,
                            boxShadow: [
                              BoxShadow(
                                color: SchoolTheme.primaryDark.withValues(alpha: 0.3),
                                blurRadius: 18,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.15),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.workspace_premium_rounded, color: Colors.amberAccent, size: 30),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Welcome back, ${widget.userName}',
                                      style: const TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.w800,
                                        color: Colors.white,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'Principal Oversight, Faculty Supervision, and Class Homeroom In-charges',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: Colors.white.withValues(alpha: 0.85),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
                                ),
                                child: Column(
                                  children: [
                                    const Text('Branch', style: TextStyle(color: Colors.white70, fontSize: 10)),
                                    Text(
                                      widget.branchId.toUpperCase(),
                                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),

                        // Metric Cards
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final cols = constraints.maxWidth < 650 ? 2 : 4;
                            return GridView.count(
                              crossAxisCount: cols,
                              crossAxisSpacing: 16,
                              mainAxisSpacing: 16,
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              childAspectRatio: constraints.maxWidth < 650 ? 1.3 : 1.5,
                              children: [
                                SchoolMetricCard(
                                  title: 'Total Enrolled',
                                  value: '${enrolledStudents.length}',
                                  subtitle: 'Active Students',
                                  icon: Icons.groups_rounded,
                                  accentColor: SchoolTheme.primary,
                                ),
                                SchoolMetricCard(
                                  title: 'Total Faculty',
                                  value: '${teachers.length}',
                                  subtitle: 'Teaching Staff',
                                  icon: Icons.co_present_rounded,
                                  accentColor: const Color(0xFF3B82F6),
                                ),
                                SchoolMetricCard(
                                  title: 'Student Attendance',
                                  value: '${stdAttPct.toStringAsFixed(1)}%',
                                  subtitle: '$presentStudents / ${enrolledStudents.length} Present',
                                  icon: Icons.how_to_reg_rounded,
                                  accentColor: SchoolTheme.statusPresent,
                                ),
                                SchoolMetricCard(
                                  title: 'Faculty Attendance',
                                  value: '${tchAttPct.toStringAsFixed(1)}%',
                                  subtitle: '$presentTeachers / ${teachers.length} Present',
                                  icon: Icons.badge_rounded,
                                  accentColor: SchoolTheme.statusLeave,
                                ),
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 28),

                        // Homeroom Teachers & Class Supervision Table
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: t.bgCard,
                            borderRadius: SchoolTheme.radius16,
                            border: Border.all(color: t.bgRule),
                            boxShadow: SchoolTheme.cardShadow,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Class Homeroom Teachers & Assigned In-Charges',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          color: t.textPrimary,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'Manage designated homeroom teachers who hold daily attendance & class accountability',
                                        style: TextStyle(fontSize: 12.5, color: t.textSecondary),
                                      ),
                                    ],
                                  ),
                                  SchoolBadge(
                                    label: 'SUPERVISION',
                                    color: t.accent,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              Divider(height: 1, color: t.bgRule),
                              const SizedBox(height: 12),

                              ListView.separated(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: classMap.keys.length,
                                separatorBuilder: (_, __) => const Divider(height: 1),
                                itemBuilder: (context, idx) {
                                  final classKey = classMap.keys.elementAt(idx);
                                  final studentsInClass = classMap[classKey]!;
                                  final parts = classKey.split(' - Section ');
                                  final grade = parts.first;
                                  final section = parts.length > 1 ? parts[1] : 'A';

                                  final homeroomInfo = SchoolLocalStorage.getHomeroomAssignmentCached(
                                    widget.branchId,
                                    grade,
                                    section,
                                  );
                                  final teacherName = homeroomInfo?['teacherName']?.toString() ?? 'Unassigned';
                                  final isAssigned = teacherName != 'Unassigned' && teacherName.isNotEmpty;

                                  final topStudentData = topStudentPerClass[classKey];
                                  final topStudent = topStudentData?['student'] as SchoolStudent?;
                                  final topPct = (topStudentData?['percentage'] as double?) ?? 0.0;

                                  return Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                    child: Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.all(10),
                                          decoration: BoxDecoration(
                                            color: SchoolTheme.getGradeColor(grade).withValues(alpha: 0.1),
                                            borderRadius: BorderRadius.circular(10),
                                          ),
                                          child: Icon(
                                            Icons.class_rounded,
                                            color: SchoolTheme.getGradeColor(grade),
                                            size: 20,
                                          ),
                                        ),
                                        const SizedBox(width: 14),
                                        Expanded(
                                          flex: 3,
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                classKey,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 14,
                                                  color: SchoolTheme.textDark,
                                                ),
                                              ),
                                              Text(
                                                '${studentsInClass.length} Students enrolled',
                                                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                                              ),
                                            ],
                                          ),
                                        ),
                                        Expanded(
                                          flex: 3,
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              const Text('Homeroom In-charge', style: TextStyle(fontSize: 11, color: Colors.grey)),
                                              Text(
                                                teacherName,
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w600,
                                                  color: isAssigned ? SchoolTheme.primary : Colors.grey.shade500,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        if (topStudent != null)
                                          Expanded(
                                            flex: 3,
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                const Text('Class Top Performer', style: TextStyle(fontSize: 11, color: Colors.grey)),
                                                Row(
                                                  children: [
                                                    const Icon(Icons.star_rounded, size: 14, color: Colors.amber),
                                                    const SizedBox(width: 4),
                                                    Flexible(
                                                      child: Text(
                                                        topStudent.name,
                                                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold),
                                                        overflow: TextOverflow.ellipsis,
                                                      ),
                                                    ),
                                                    const SizedBox(width: 6),
                                                    Text(
                                                      '(${topPct.toStringAsFixed(0)}%)',
                                                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                        IconButton(
                                          icon: const Icon(Icons.edit_note_rounded, color: SchoolTheme.primary),
                                          tooltip: 'Change Homeroom Teacher',
                                          onPressed: () => _openHomeroomDialog(grade, section),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
