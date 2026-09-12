// lib/pages/school/views/school_overview_view.dart

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../utils/school_local_storage.dart';
import '../../../theme/role_theme_provider.dart';
import '../../../theme/app_theme.dart';

class SchoolOverviewView extends StatelessWidget {
  final String branchId;

  const SchoolOverviewView({
    super.key,
    required this.branchId,
  });

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    final todayKey = DateFormat('yyyy-MM-dd').format(DateTime.now());

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: SchoolLocalStorage.streamStudentsCached(branchId),
      builder: (context, studentSnapshot) {
        final students = studentSnapshot.data ?? [];
        final totalStudents = students.length;
        final activeStudents = students.where((s) => (s['status'] ?? 'active') == 'active').length;

        return StreamBuilder<List<Map<String, dynamic>>>(
          stream: SchoolLocalStorage.streamTeachersCached(branchId),
          builder: (context, teacherSnapshot) {
            final teachers = teacherSnapshot.data ?? [];
            final totalTeachers = teachers.length;
            final activeTeachers = teachers.where((tc) => (tc['status'] ?? 'active') == 'active').length;

            return StreamBuilder<Map<String, dynamic>?>(
              stream: SchoolLocalStorage.streamLogCached(branchId, todayKey),
              builder: (context, logSnapshot) {
                final logData = logSnapshot.data;
                final entries = (logData?['entries'] as Map?) ?? {};

                int stdPresent = 0;
                int stdAbsent = 0;
                int stdLeave = 0;

                entries.forEach((key, value) {
                  if (value is Map) {
                    final status = (value['status'] ?? '').toString().toLowerCase();
                    if (status == 'present') {
                      stdPresent++;
                    } else if (status == 'absent') {
                      stdAbsent++;
                    } else if (status == 'leave') {
                      stdLeave++;
                    }
                  }
                });

                final attendancePct = activeStudents > 0
                    ? ((stdPresent / activeStudents) * 100).toStringAsFixed(1)
                    : '0.0';

                return StreamBuilder<Map<String, dynamic>?>(
                  stream: SchoolLocalStorage.streamTeacherLogCached(branchId, todayKey),
                  builder: (context, tchLogSnap) {
                    final tchEntries = (tchLogSnap.data?['entries'] as Map?) ?? {};
                    int tchPresent = 0;
                    int tchAbsent = 0;
                    int tchLeave = 0;

                    tchEntries.forEach((key, value) {
                      if (value is Map) {
                        final status = (value['status'] ?? '').toString().toLowerCase();
                        if (status == 'present') {
                          tchPresent++;
                        } else if (status == 'absent') {
                          tchAbsent++;
                        } else if (status == 'leave') {
                          tchLeave++;
                        }
                      }
                    });

                    return StreamBuilder<List<Map<String, dynamic>>>(
                      stream: SchoolLocalStorage.streamBooksCached(branchId),
                      builder: (context, booksSnap) {
                        final books = booksSnap.data ?? [];
                        final totalBooks = books.fold<int>(0, (sum, b) {
                          final q = b['copies'] ?? b['totalCopies'] ?? b['quantity'] ?? 1;
                          return sum + (q is int ? q : int.tryParse(q.toString()) ?? 1);
                        });

                        return StreamBuilder<List<Map<String, dynamic>>>(
                          stream: SchoolLocalStorage.streamBookLoansCached(branchId),
                          builder: (context, loansSnap) {
                            final loans = loansSnap.data ?? [];
                            final activeLoans = loans.where((l) => (l['status'] ?? 'issued') == 'issued' || (l['status'] ?? '') == 'borrowed').length;
                            final availableBooks = (totalBooks - activeLoans).clamp(0, 999999);

                            return StreamBuilder<List<Map<String, dynamic>>>(
                              stream: SchoolLocalStorage.streamGradesCached(branchId),
                              builder: (context, gradeSnap) {
                                final grades = gradeSnap.data ?? [];
                                double totalPct = 0;
                                int validCount = 0;
                                for (final g in grades) {
                                  final total = (g['totalMarks'] as num? ?? 100).toDouble();
                                  final obt = (g['marksObtained'] as num? ?? 0).toDouble();
                                  if (total > 0) {
                                    totalPct += (obt / total) * 100;
                                    validCount++;
                                  }
                                }
                                final avgPct = validCount > 0 ? (totalPct / validCount).toStringAsFixed(1) : 'N/A';

                                return SingleChildScrollView(
                                  padding: const EdgeInsets.all(24),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      // ── Overview Header Banner ──────────────────────────────
                                      Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.all(24),
                                        decoration: BoxDecoration(
                                          gradient: const LinearGradient(
                                            colors: [Color(0xFF0F172A), Color(0xFF1E293B), Color(0xFF1E1B4B)],
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                          ),
                                          borderRadius: BorderRadius.circular(20),
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.black.withValues(alpha: 0.12),
                                              blurRadius: 16,
                                              offset: const Offset(0, 8),
                                            ),
                                          ],
                                        ),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  Row(
                                                    children: [
                                                      // 1. GMWF Logo
                                                      ClipRRect(
                                                        borderRadius: BorderRadius.circular(10),
                                                        child: Image.asset(
                                                          'assets/logo/gmwf-1.webp',
                                                          height: 42,
                                                          width: 42,
                                                          fit: BoxFit.contain,
                                                          errorBuilder: (context, error, stackTrace) => Container(
                                                            padding: const EdgeInsets.all(6),
                                                            decoration: BoxDecoration(
                                                              color: Colors.white.withValues(alpha: 0.2),
                                                              borderRadius: BorderRadius.circular(8),
                                                            ),
                                                            child: const Text('GMWF', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 10)),
                                                          ),
                                                        ),
                                                      ),
                                                      const SizedBox(width: 12),
                                                      const Text('•', style: TextStyle(color: Colors.white38, fontSize: 20)),
                                                      const SizedBox(width: 12),

                                                      // 2. TWT Official School Logo
                                                      ClipRRect(
                                                        borderRadius: BorderRadius.circular(10),
                                                        child: Image.asset(
                                                          'assets/logo/twt.webp',
                                                          height: 42,
                                                          width: 42,
                                                          fit: BoxFit.contain,
                                                          errorBuilder: (context, error, stackTrace) => Container(
                                                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                                            decoration: BoxDecoration(
                                                              color: const Color(0xFF1E3A8A),
                                                              borderRadius: BorderRadius.circular(8),
                                                            ),
                                                            child: const Text('TWT', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                  const SizedBox(height: 16),
                                                  const Text(
                                                    'Taleem-wa-Tarbiyat School System',
                                                    style: TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 22,
                                                      fontWeight: FontWeight.w900,
                                                      letterSpacing: -0.4,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 4),
                                                  Text(
                                                    'A Project of Gulzar Madina Welfare Foundation (GMWF) • Campus Intelligence & Performance Hub',
                                                    style: TextStyle(
                                                      color: Colors.white.withValues(alpha: 0.85),
                                                      fontSize: 13,
                                                      fontWeight: FontWeight.w500,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 24),

                                      // ── Comprehensive Metric Cards ─────────────────────────
                                      LayoutBuilder(
                                        builder: (context, constraints) {
                                          final isMobile = constraints.maxWidth < 700;
                                          final isTablet = constraints.maxWidth < 1100;
                                          final cols = isMobile ? 2 : (isTablet ? 3 : 4);

                                          return GridView.count(
                                            crossAxisCount: cols,
                                            shrinkWrap: true,
                                            physics: const NeverScrollableScrollPhysics(),
                                            crossAxisSpacing: 14,
                                            mainAxisSpacing: 14,
                                            childAspectRatio: isMobile ? 1.25 : 1.45,
                                            children: [
                                              _buildMetricCard(
                                                t: t,
                                                title: 'Active Students',
                                                value: '$activeStudents',
                                                subtitle: 'Total Enrolled: $totalStudents',
                                                icon: Icons.groups_rounded,
                                                color: const Color(0xFF6366F1),
                                              ),
                                              _buildMetricCard(
                                                t: t,
                                                title: 'Student Attendance',
                                                value: '$stdPresent Present',
                                                subtitle: '$attendancePct% • Absent: $stdAbsent • Leave: $stdLeave',
                                                icon: Icons.how_to_reg_rounded,
                                                color: const Color(0xFF10B981),
                                              ),
                                              _buildMetricCard(
                                                t: t,
                                                title: 'Teaching Faculty',
                                                value: '$activeTeachers Staff',
                                                subtitle: 'Total Registered: $totalTeachers',
                                                icon: Icons.record_voice_over_rounded,
                                                color: const Color(0xFF3B82F6),
                                              ),
                                              _buildMetricCard(
                                                t: t,
                                                title: 'Faculty Present',
                                                value: '$tchPresent Present',
                                                subtitle: 'Absent: $tchAbsent • Leave: $tchLeave',
                                                icon: Icons.co_present_rounded,
                                                color: const Color(0xFF06B6D4),
                                              ),
                                              _buildMetricCard(
                                                t: t,
                                                title: 'Library Stock',
                                                value: '$availableBooks Available',
                                                subtitle: 'Total Catalog: $totalBooks',
                                                icon: Icons.local_library_rounded,
                                                color: const Color(0xFFF59E0B),
                                              ),
                                              _buildMetricCard(
                                                t: t,
                                                title: 'Books Lent / Issued',
                                                value: '$activeLoans Lent',
                                                subtitle: '${totalBooks > 0 ? ((activeLoans / totalBooks) * 100).toStringAsFixed(0) : 0}% Circulation',
                                                icon: Icons.book_outlined,
                                                color: const Color(0xFFEC4899),
                                              ),
                                              _buildMetricCard(
                                                t: t,
                                                title: 'Academic Performance',
                                                value: avgPct == 'N/A' ? 'N/A' : '$avgPct%',
                                                subtitle: '$validCount grade archives',
                                                icon: Icons.grade_rounded,
                                                color: const Color(0xFF8B5CF6),
                                              ),
                                              _buildMetricCard(
                                                t: t,
                                                title: 'Campus Campus ID',
                                                value: branchId.toUpperCase(),
                                                subtitle: 'Secure Local Database',
                                                icon: Icons.domain_rounded,
                                                color: const Color(0xFF64748B),
                                              ),
                                            ],
                                          );
                                        },
                                      ),
                                      const SizedBox(height: 32),

                                      // ── Class-wise Breakdown Section ───────────────────────
                                      Text(
                                        'Class Distribution & Enrolment',
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w900,
                                          color: t.textPrimary,
                                          letterSpacing: -0.3,
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      _buildClassDistributionCard(students, t),
                                    ],
                                  ),
                                );
                              },
                            );
                          },
                        );
                      },
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildMetricCard({
    required RoleThemeData t,
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.bgRule),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: t.textSecondary,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color, size: 16),
              ),
            ],
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w900,
              color: t.textPrimary,
              letterSpacing: -0.3,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            subtitle,
            style: TextStyle(
              color: t.textTertiary,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildClassDistributionCard(List<Map<String, dynamic>> students, RoleThemeData t) {
    final Map<String, int> classCounts = {};
    for (var s in students) {
      final grade = (s['grade'] ?? 'Unassigned').toString();
      classCounts[grade] = (classCounts[grade] ?? 0) + 1;
    }

    if (classCounts.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: t.bgCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: t.bgRule),
        ),
        child: Center(
          child: Text(
            'No students registered yet. Click on "Student Admissions" to enroll students.',
            style: TextStyle(color: t.textTertiary),
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.bgRule),
      ),
      child: Wrap(
        spacing: 14,
        runSpacing: 14,
        children: classCounts.entries.map((e) {
          return Container(
            width: 155,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: t.isDarkCanvas ? const Color(0xFF161B22) : const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: t.bgRule),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.key,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: t.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${e.value} Students',
                  style: TextStyle(
                    color: t.accent,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}
