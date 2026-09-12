import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../../services/local_storage_service.dart';
import '../widgets/student_progress_dialog.dart';
import 'audit_log_view.dart';
import '../madrassa_strings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/madrassa_providers.dart';
import '../utils/madrassa_local_storage.dart';

// Breakpoints for responsive dashboard sizing
const double kMobileBreakpoint = 600.0;
const double kTabletBreakpoint = 900.0;

class MadrassaOverviewView extends ConsumerWidget {
  final String branchId;
  final Function(int)? onAction;
  final bool isAdmin;

  const MadrassaOverviewView({
    super.key,
    required this.branchId,
    required this.isAdmin,
    this.onAction,
  });

  double _calculateRecentPace(String studentId, String branchId, double overallAvg) {
    try {
      if (!Hive.isBoxOpen(LocalStorageService.madrassaLogsBox)) return overallAvg;
      final box = Hive.box(LocalStorageService.madrassaLogsBox);
      final prefix = '${branchId.toLowerCase().trim()}__log__';
      final now = DateTime.now();
      
      final logsList = <MapEntry<DateTime, int>>[];
      // Direct lookup of recent 35 days instead of scanning entire historical Hive box
      for (int i = 0; i < 35; i++) {
        final d = now.subtract(Duration(days: i));
        final datePart = DateFormat('yyyy-MM-dd').format(d);
        final key = '$prefix$datePart';
        final logVal = box.get(key);
        if (logVal is Map && logVal.containsKey(studentId)) {
          final studentLog = Map<String, dynamic>.from(logVal[studentId] as Map);
          final currentLines = (studentLog['currentLines'] as num?)?.toInt() ?? int.tryParse(studentLog['currentLines']?.toString() ?? '');
          if (currentLines != null && currentLines > 0) {
            logsList.add(MapEntry(d, currentLines));
          }
        }
      }
      
      if (logsList.length < 2) {
        return overallAvg;
      }
      
      // Sort chronologically
      logsList.sort((a, b) => a.key.compareTo(b.key));
      
      final latest = logsList.last;
      
      // Find reference log from 7 to 30 days ago
      MapEntry<DateTime, int>? bestRef;
      for (int i = logsList.length - 2; i >= 0; i--) {
        final ref = logsList[i];
        final daysDiff = latest.key.difference(ref.key).inDays;
        if (daysDiff >= 7 && daysDiff <= 30) {
          bestRef = ref;
          if (daysDiff >= 14) break;
        }
      }
      
      // Fallback
      if (bestRef == null) {
        for (final ref in logsList) {
          if (ref.key != latest.key) {
            bestRef = ref;
            break;
          }
        }
      }
      
      if (bestRef != null) {
        final daysDiff = latest.key.difference(bestRef.key).inDays;
        final linesDiff = latest.value - bestRef.value;
        if (daysDiff > 0 && linesDiff >= 0) {
          final pace = linesDiff / daysDiff;
          return pace >= 0.8 ? pace : overallAvg;
        }
      }
    } catch (e) {
      debugPrint('Error calculating recent pace: $e');
    }
    return overallAvg;
  }

  void _showStudentProgressDialog(BuildContext context, Map<String, dynamic> studentData) {
    final studentId = studentData['id']?.toString() ?? '';
    final totalLines = 8640;
    final currentLines = (studentData['currentLines'] as num?)?.toInt() ?? 0;
    final prevLines = int.tryParse(studentData['prevHifzLines']?.toString() ?? '0') ?? 0;
    
    final dynamic joinField = studentData['joinDate'];
    Timestamp? joinTimestamp;
    if (joinField is Timestamp) {
      joinTimestamp = joinField;
    } else if (joinField is String) {
      try {
        final parsed = DateTime.parse(joinField);
        joinTimestamp = Timestamp.fromDate(parsed);
      } catch (_) {}
    }
    final joinDate = joinTimestamp?.toDate();
    final daysSinceJoin = (joinDate != null) ? DateTime.now().difference(joinDate).inDays : 0;
    final totalMemorized = currentLines + prevLines;
    final avgPerDay = daysSinceJoin > 0 ? totalMemorized / daysSinceJoin : 0.0;
    
    final recentDailyRate = _calculateRecentPace(studentId, branchId, avgPerDay);
    final remainingLines = (totalLines - totalMemorized).clamp(0, totalLines);
    final estimatedDays = recentDailyRate > 0.3 ? (remainingLines / recentDailyRate).ceil() : null;
    final pct = ((totalMemorized / totalLines) * 100).clamp(0.0, 100.0).toStringAsFixed(1);

    showDialog(
      context: context,
      builder: (_) => StudentProgressDialog(
        studentName: studentData['name'] ?? 'Student',
        photoUrl: studentData['photoUrl'],
        className: studentData['class']?.toString() ?? 'Hifz',
        rollNumber: studentData['rollNumber']?.toString() ?? '?',
        joinDate: joinDate,
        totalLines: totalLines,
        currentLines: currentLines,
        prevHifzLines: prevLines,
        percentage: pct,
        estimatedDays: estimatedDays,
        recentDailyRate: recentDailyRate,
      ),
    );
  }

  Widget _buildDailyProgressSummary(BuildContext context, List<Map<String, dynamic>> activeStudents, Map<String, dynamic> logData) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    int present = 0;
    int absent = 0;
    int leave = 0;
    int totalLinesToday = 0;

    final progressList = <Map<String, dynamic>>[];

    for (final s in activeStudents) {
      final sId = s['id']?.toString() ?? '';
      if (logData.containsKey(sId)) {
        final entry = Map<String, dynamic>.from(logData[sId] as Map);
        final att = entry['attendance']?.toString() ?? 'absent';
        if (att == 'present') {
          present++;
          final currentLines = entry['currentLines'] as int? ?? 0;
          if (currentLines > 0) {
            final prevLines = _getPreviousLines(sId, DateTime.now(), currentLines);
            final diff = currentLines - prevLines;
            if (diff > 0) {
              totalLinesToday += diff;
              progressList.add({
                'name': s['name'] ?? 'Student',
                'rollNumber': s['rollNumber']?.toString() ?? '?',
                'diff': diff,
                'currentLines': currentLines,
              });
            }
          }
        } else if (att == 'leave') {
          leave++;
        } else {
          absent++;
        }
      } else {
        absent++;
      }
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: isDark ? Colors.white10 : const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final isNarrow = constraints.maxWidth < 420;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF10B981).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.auto_graph_rounded, color: Color(0xFF10B981), size: 20),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              context.isUrdu ? 'روزانہ کی کارکردگی کا خلاصہ' : 'Daily Progress Summary',
                              overflow: TextOverflow.ellipsis,
                              style: context.urduStyle(
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                                ),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              context.isUrdu ? 'حاضری اور آج کے اسباق کی تازہ ترین تفصیلات' : 'Live attendance & memorization progress for today',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: isDark ? Colors.white60 : const Color(0xFF64748B),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (totalLinesToday > 0 && !isNarrow) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: const Color(0xFF10B981).withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.3)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.bolt_rounded, color: Color(0xFF10B981), size: 14),
                              const SizedBox(width: 4),
                              Text(
                                context.isUrdu ? '+$totalLinesToday لائنیں' : '+$totalLinesToday lines',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF047857),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (totalLinesToday > 0 && isNarrow) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.bolt_rounded, color: Color(0xFF10B981), size: 14),
                          const SizedBox(width: 4),
                          Text(
                            context.isUrdu ? '+$totalLinesToday لائنیں' : '+$totalLinesToday lines today',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF047857),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _pillIndicator(context, context.isUrdu ? 'حاضر: $present' : 'Present: $present', const Color(0xFF10B981), const Color(0xFFD1FAE5), onTap: () => onAction?.call(isAdmin ? 1 : 0)),
              _pillIndicator(context, context.isUrdu ? 'غیر حاضر: $absent' : 'Absent: $absent', const Color(0xFFEF4444), const Color(0xFFFEE2E2), onTap: () => onAction?.call(isAdmin ? 1 : 0)),
              _pillIndicator(context, context.isUrdu ? 'رخصت: $leave' : 'Leave: $leave', const Color(0xFFF59E0B), const Color(0xFFFEF3C7), onTap: () => onAction?.call(isAdmin ? 1 : 0)),
            ],
          ),
          const SizedBox(height: 20),
          const Divider(height: 1, color: Color(0xFFE2E8F0)),
          const SizedBox(height: 16),
          Text(
            context.isUrdu ? 'آج کی حفظ کی تفصیلات' : 'Today\'s Memorization Updates',
            style: context.urduStyle(
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white70 : const Color(0xFF334155),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (progressList.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14.0),
              child: Center(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.history_toggle_off_rounded, color: Colors.grey.shade400, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      context.isUrdu ? 'آج ابھی تک کوئی کارکردگی درج نہیں ہوئی۔' : 'No daily progress updates recorded yet today.',
                      style: context.urduStyle(style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: progressList.length,
              separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFFF1F5F9)),
              itemBuilder: (context, idx) {
                final p = progressList[idx];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: const Color(0xFF0F766E).withValues(alpha: 0.1),
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: Text(
                                (p['name'] as String).isNotEmpty ? (p['name'] as String)[0].toUpperCase() : '?',
                                style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF0F766E), fontSize: 13),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${p['name']}',
                                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: isDark ? Colors.white : const Color(0xFF0F172A)),
                              ),
                              Text(
                                'Roll #${p['rollNumber']}',
                                style: TextStyle(fontSize: 11, color: isDark ? Colors.white54 : const Color(0xFF64748B)),
                              ),
                            ],
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                            decoration: BoxDecoration(
                              color: const Color(0xFFD1FAE5),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '+${p['diff']} lines',
                              style: const TextStyle(color: Color(0xFF065F46), fontWeight: FontWeight.bold, fontSize: 11.5),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            'Total: ${p['currentLines']}',
                            style: TextStyle(fontSize: 11.5, color: isDark ? Colors.white60 : Colors.grey.shade600, fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _pillIndicator(BuildContext context, String text, Color color, Color bg, {VoidCallback? onTap}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(
                text,
                style: context.urduStyle(
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  int _getPreviousLines(String studentId, DateTime today, int currentLinesToday) {
    try {
      if (!Hive.isBoxOpen(LocalStorageService.madrassaLogsBox)) return currentLinesToday;
      final box = Hive.box(LocalStorageService.madrassaLogsBox);
      for (int i = 1; i <= 7; i++) {
        final date = today.subtract(Duration(days: i));
        final dateStr = DateFormat('yyyy-MM-dd').format(date);
        final key = '${branchId.toLowerCase().trim()}__log__$dateStr';
        final val = box.get(key);
        if (val is Map && val.containsKey(studentId)) {
          final studentLog = Map<String, dynamic>.from(val[studentId] as Map);
          final prevLines = (studentLog['currentLines'] as num?)?.toInt() ?? int.tryParse(studentLog['currentLines']?.toString() ?? '');
          if (prevLines != null && prevLines >= 0) {
            return prevLines;
          }
        }
      }
    } catch (e) {
      debugPrint('Error getting previous lines: $e');
    }
    return 0;
  }

  int _calculateProgress(Map<String, dynamic> student, List<Map<String, dynamic>> allLogs, String timeframe) {
    final sId = student['id'] ?? '';
    final prevHifzLines = int.tryParse(student['prevHifzLines']?.toString() ?? '0') ?? 0;
    final studentCurrentLines = (student['currentLines'] as num?)?.toInt() ?? (int.tryParse(student['currentLines']?.toString() ?? '') ?? 0);

    if (timeframe == 'Overall') {
      int latestMadrassaLines = studentCurrentLines;
      if (allLogs.isNotEmpty) {
        final sortedLogs = List<Map<String, dynamic>>.from(allLogs)
          ..sort((a, b) => a['dateKey'].toString().compareTo(b['dateKey'].toString()));
        for (int i = sortedLogs.length - 1; i >= 0; i--) {
          final sLog = sortedLogs[i][sId];
          if (sLog is Map && sLog.containsKey('currentLines')) {
            final parsed = (sLog['currentLines'] as num?)?.toInt() ?? int.tryParse(sLog['currentLines']?.toString() ?? '');
            if (parsed != null && parsed >= 0) {
              latestMadrassaLines = parsed;
              break;
            }
          }
        }
      }
      return latestMadrassaLines + prevHifzLines;
    }

    if (allLogs.isEmpty) return 0;
    final sortedLogs = allLogs;

    if (timeframe == 'Daily') {
      final latestLog = sortedLogs.last;
      final studentLog = latestLog[sId];
      if (studentLog is Map && studentLog.containsKey('currentLines')) {
        final current = (studentLog['currentLines'] as num?)?.toInt() ?? int.tryParse(studentLog['currentLines']?.toString() ?? '') ?? 0;
        int prev = 0;
        for (int i = sortedLogs.length - 2; i >= 0; i--) {
          final sLog = sortedLogs[i][sId];
          if (sLog is Map && sLog.containsKey('currentLines')) {
            final p = (sLog['currentLines'] as num?)?.toInt() ?? int.tryParse(sLog['currentLines']?.toString() ?? '');
            if (p != null) {
              prev = p;
              break;
            }
          }
        }
        return (current - prev).clamp(0, 9999);
      }
      return 0;
    }

    final latestDateKey = sortedLogs.last['dateKey']?.toString() ?? '';
    final latestDate = DateTime.tryParse(latestDateKey) ?? DateTime.now();

    DateTime startDate;
    if (timeframe == 'Weekly') {
      startDate = latestDate.subtract(const Duration(days: 6));
    } else { // Monthly
      startDate = latestDate.subtract(const Duration(days: 29));
    }

    int endLines = -1;
    int startLines = -1;
    for (final log in sortedLogs) {
      final dateKey = log['dateKey']?.toString() ?? '';
      final parsedDate = DateTime.tryParse(dateKey);
      if (parsedDate == null) continue;

      if (parsedDate.isBefore(startDate) || parsedDate.isAfter(latestDate)) {
        continue;
      }

      final studentLog = log[sId];
      if (studentLog is Map && studentLog.containsKey('currentLines')) {
        final parsed = (studentLog['currentLines'] as num?)?.toInt() ?? int.tryParse(studentLog['currentLines']?.toString() ?? '');
        if (parsed != null) {
          if (startLines == -1) startLines = parsed;
          endLines = parsed;
        }
      }
    }

    if (endLines != -1 && startLines != -1) {
      return (endLines - startLines).clamp(0, 8640);
    }

    return 0;
  }

  Widget _buildInsightsGrid(BuildContext context, List<Map<String, dynamic>> best, List<Map<String, dynamic>> worst) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 600;
        final topPerformers = best.take(5).toList();
        final struggling = worst.take(5).toList();

        final bestCard = _buildInsightsCard(
          context: context,
          title: context.isUrdu ? 'بہترین کارکردگی (ٹاپ 5)' : 'Top Performers (Best 5)',
          subtitle: context.isUrdu ? 'ہفتہ وار سب سے زیادہ حفظ کرنے والے' : 'Highest weekly memorization gain',
          students: topPerformers,
          isGood: true,
          gradient: const [Color(0xFF065F46), Color(0xFF0F766E)],
        );

        final worstCard = _buildInsightsCard(
          context: context,
          title: context.isUrdu ? 'توجہ طلب طالب علم (آخری 5)' : 'Needs Attention (Worst 5)',
          subtitle: context.isUrdu ? 'کم رفتار یا اضافی مدد کے ضرورت مند' : 'Slow pace or requiring teacher support',
          students: struggling,
          isGood: false,
          gradient: const [Color(0xFF991B1B), Color(0xFFBE123C)],
        );

        if (isMobile) {
          return Column(
            children: [
              bestCard,
              const SizedBox(height: 16),
              worstCard,
            ],
          );
        } else {
          return Row(
            children: [
              Expanded(child: bestCard),
              const SizedBox(width: 24),
              Expanded(child: worstCard),
            ],
          );
        }
      },
    );
  }

  Widget _buildInsightsCard({
    required BuildContext context,
    required String title,
    required String subtitle,
    required List<Map<String, dynamic>> students,
    required bool isGood,
    required List<Color> gradient,
  }) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: gradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: gradient.first.withValues(alpha: 0.35),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isGood ? Icons.stars_rounded : Icons.warning_amber_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.white.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${students.length} ${context.isUrdu ? 'طلبہ' : 'Students'}',
                  style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (students.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  context.isUrdu ? 'کوئی ڈیٹا موجود نہیں' : 'No data available',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            )
          else
            ...students.asMap().entries.map((e) {
              final idx = e.key;
              final std = e.value;
              final progress = std['calculatedProgress'] as int;

              return Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => _showStudentProgressDialog(context, std),
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              Container(
                                width: 24,
                                height: 24,
                                decoration: BoxDecoration(
                                  color: isGood && idx == 0
                                      ? const Color(0xFFFBBF24)
                                      : Colors.white.withValues(alpha: 0.22),
                                  shape: BoxShape.circle,
                                ),
                                child: Center(
                                  child: Text(
                                    '${idx + 1}',
                                    style: TextStyle(
                                      color: isGood && idx == 0 ? const Color(0xFF78350F) : Colors.white,
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  std['name']?.toString() ?? '',
                                  style: const TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '+$progress ${context.isUrdu ? 'لائنیں' : 'lines'}',
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configAsync = ref.watch(madrassaConfigProvider(branchId));
    final studentsAsync = ref.watch(madrassaStudentsProvider(branchId));
    final logsAsync = ref.watch(madrassaAllLogsProvider(branchId));
    final dateKey = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final dailyLogAsync = ref.watch(madrassaDailyLogProvider((branchId: branchId, dateKey: dateKey)));

    return configAsync.when(
      loading: () => const Center(
        child: CircularProgressIndicator(color: Color(0xFF0F766E)),
      ),
      error: (e, st) => Center(child: Text('Error loading config: $e')),
      data: (config) {
        return studentsAsync.when(
          loading: () => const Center(
            child: CircularProgressIndicator(color: Color(0xFF0F766E)),
          ),
          error: (e, st) => Center(child: Text('Error loading students: $e')),
          data: (allStudents) {
            return logsAsync.when(
              loading: () => const Center(
                child: CircularProgressIndicator(color: Color(0xFF0F766E)),
              ),
              error: (e, st) => Center(child: Text('Error loading logs: $e')),
              data: (allLogs) {
                return dailyLogAsync.when(
                  loading: () => const Center(
                    child: CircularProgressIndicator(color: Color(0xFF0F766E)),
                  ),
                  error: (e, st) => Center(child: Text('Error loading daily log: $e')),
                  data: (logData) {
                    final activeStudents = allStudents.where((d) {
                      final statusVal = d['status'];
                      return (statusVal == null || statusVal == '')
                          ? (d['active'] == true)
                          : (statusVal == 'active');
                    }).toList();

                    // Sort logs once outside the loop for high performance
                    final sortedLogs = List<Map<String, dynamic>>.from(allLogs)
                      ..sort((a, b) => a['dateKey'].toString().compareTo(b['dateKey'].toString()));

                    // Calculate progress for each active student (Weekly timeframe)
                    final List<Map<String, dynamic>> processedStudents = [];
                    for (final std in activeStudents) {
                      final progress = _calculateProgress(std, sortedLogs, 'Weekly');
                      processedStudents.add({
                        ...std,
                        'calculatedProgress': progress,
                      });
                    }

                    // Sort lists for best (descending) and worst (ascending)
                    final bestStudents = List<Map<String, dynamic>>.from(processedStudents)
                      ..sort((a, b) => (b['calculatedProgress'] as int).compareTo(a['calculatedProgress'] as int));

                    final worstStudents = List<Map<String, dynamic>>.from(processedStudents)
                      ..sort((a, b) => (a['calculatedProgress'] as int).compareTo(b['calculatedProgress'] as int));

                    return RefreshIndicator(
                      onRefresh: () async {
                        await MadrassaLocalStorage.downloadStudents(branchId, force: true);
                        final now = DateTime.now();
                        await MadrassaLocalStorage.downloadLogsForMonth(branchId, now.year, now.month);
                        await MadrassaLocalStorage.downloadHolidays(branchId);
                        ref.invalidate(madrassaStudentsProvider(branchId));
                        ref.invalidate(madrassaAllLogsProvider(branchId));
                        ref.invalidate(madrassaDailyLogProvider((branchId: branchId, dateKey: dateKey)));
                      },
                      child: SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildWelcomeHeader(context),
                            const SizedBox(height: 24),
                            _buildRealtimeStatGrid(context, ref),
                            const SizedBox(height: 24),
                            _buildDailyProgressSummary(context, activeStudents, logData),
                            const SizedBox(height: 24),
                            _buildInsightsGrid(context, bestStudents, worstStudents),
                            const SizedBox(height: 24),
                            _buildQuickActions(context),
                            const SizedBox(height: 24),
                            _buildRecentActivity(context),
                          ],
                        ),
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
  }

  Widget _buildWelcomeHeader(BuildContext context) {
    // Localized formatted current date with safe fallback
    String formattedDate;
    try {
      formattedDate = DateFormat.yMMMMEEEEd(context.isUrdu ? 'ur' : 'en').format(DateTime.now());
    } catch (_) {
      formattedDate = DateFormat.yMMMMEEEEd().format(DateTime.now());
    }

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF064E3B), Color(0xFF0F766E), Color(0xFF059669)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F766E).withValues(alpha: 0.35),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isMobile = constraints.maxWidth < kMobileBreakpoint;

          final mosqueBadge = Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withValues(alpha: 0.25), width: 1.5),
            ),
            child: const Center(
              child: Icon(
                Icons.mosque_rounded,
                color: Colors.white,
                size: 32,
              ),
            ),
          );

          final titleText = Text(
            context.l.overviewTitle,
            style: context.urduStyle(
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                letterSpacing: -0.5,
              ),
            ),
          );

          final subtitleText = Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Color(0xFF34D399),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Principal Executive Dashboard • Branch Overview',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Colors.white.withValues(alpha: 0.9),
                  ),
                ),
              ),
            ],
          );

          final dateChip = Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: Colors.white.withValues(alpha: 0.2), width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.calendar_today_rounded,
                  color: Colors.white,
                  size: 14,
                ),
                const SizedBox(width: 8),
                Text(
                  formattedDate,
                  style: context.urduStyle(
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          );

          if (isMobile) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    mosqueBadge,
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          titleText,
                          const SizedBox(height: 2),
                          subtitleText,
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                dateChip,
              ],
            );
          } else {
            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      mosqueBadge,
                      const SizedBox(width: 18),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            titleText,
                            const SizedBox(height: 4),
                            subtitleText,
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                dateChip,
              ],
            );
          }
        },
      ),
    );
  } // End of _buildWelcomeHeader

  // Rewritten realtime stat grid with individual StreamBuilders and placeholders
   Widget _buildRealtimeStatGrid(BuildContext context, WidgetRef ref) {
     final theme = Theme.of(context);

     // Helper placeholder card
     Widget placeholderCard(String label) {
       return Container(
         padding: const EdgeInsets.all(16),
         decoration: BoxDecoration(
           color: theme.cardColor,
           borderRadius: BorderRadius.circular(20),
           boxShadow: [
             BoxShadow(
               color: Colors.black.withValues(alpha: 0.04),
               blurRadius: 12,
               offset: const Offset(0, 4),
             ),
           ],
         ),
         child: Center(
           child: SizedBox(
             width: 24,
             height: 24,
             child: CircularProgressIndicator(strokeWidth: 2, color: theme.primaryColor),
           ),
         ),
       );
     }

     // Determine grid layout
     return LayoutBuilder(
       builder: (context, constraints) {
         final bool isFeeEnabled = LocalStorageService.isMadrassaFeeEnabled(branchId);
         final width = constraints.maxWidth;
         final int crossAxisCount;
         final double childAspectRatio;

         if (width < kMobileBreakpoint) {
           crossAxisCount = 2;
           childAspectRatio = 1.15;
         } else if (width < kTabletBreakpoint) {
           crossAxisCount = 3;
           childAspectRatio = 1.3;
         } else {
           crossAxisCount = isFeeEnabled ? 4 : 3;
           childAspectRatio = 1.25;
         }

         final studentsAsync = ref.watch(madrassaStudentsProvider(branchId));
         final configAsync = ref.watch(madrassaConfigProvider(branchId));
         final now = DateTime.now();
         final dateKey = DateFormat('yyyy-MM-dd').format(now);
         final dailyLogAsync = ref.watch(madrassaDailyLogProvider((branchId: branchId, dateKey: dateKey)));

         return GridView.count(
           crossAxisCount: crossAxisCount,
           shrinkWrap: true,
           physics: const NeverScrollableScrollPhysics(),
           mainAxisSpacing: 14,
           crossAxisSpacing: 14,
           childAspectRatio: childAspectRatio,
           children: [
             // 1. Students Card -> Navigates to Students tab
             studentsAsync.when(
               loading: () => placeholderCard(context.l.totalStudents),
               error: (_, __) => _statCard(
                 context,
                 context.l.totalStudents,
                 '0',
                 Icons.people_alt_rounded,
                 210,
                 badge: 'Active',
                 onTap: () => onAction?.call(isAdmin ? 2 : 1),
               ),
               data: (students) {
                 final activeCount = students.where((d) {
                   final statusVal = d['status'];
                   return (statusVal == null || statusVal == '')
                       ? (d['active'] == true)
                       : (statusVal == 'active');
                 }).length;
                 return _statCard(
                   context,
                   context.l.totalStudents,
                   '$activeCount',
                   Icons.people_alt_rounded,
                   210,
                   badge: '$activeCount Enrolled',
                   onTap: () => onAction?.call(isAdmin ? 2 : 1),
                 );
               },
             ),
             // 2. Attendance / Daily Log Card -> Navigates to Daily Log tab
             dailyLogAsync.when(
               loading: () => placeholderCard(context.l.dailyLogTitle),
               error: (_, __) => _statCard(
                 context,
                 context.l.dailyLogTitle,
                 '0 / 0',
                 Icons.edit_calendar_rounded,
                 160,
                 badge: 'Today',
                 onTap: () => onAction?.call(isAdmin ? 1 : 0),
               ),
               data: (logData) {
                 final totalActive = studentsAsync.value?.where((d) {
                   final statusVal = d['status'];
                   return (statusVal == null || statusVal == '')
                       ? (d['active'] == true)
                       : (statusVal == 'active');
                 }).length ?? 0;
                 
                 int present = 0;
                 logData.forEach((k, v) {
                   if (v is Map && v['attendance'] == 'present') present++;
                 });
                 final pct = totalActive > 0 ? ((present / totalActive) * 100).toInt() : 0;
                 return _statCard(
                   context,
                   context.l.dailyLogTitle,
                   '$present / $totalActive',
                   Icons.edit_calendar_rounded,
                   160,
                   badge: '$pct% Present',
                   onTap: () => onAction?.call(isAdmin ? 1 : 0),
                 );
               },
             ),
             // 3. PTM Card -> Accurate Current Month PTM & Navigates to Daily Log
             configAsync.when(
               loading: () => placeholderCard(context.l.ptmDay),
               error: (_, __) => _statCard(
                 context,
                 context.l.ptmDay,
                 '-',
                 Icons.event_available_rounded,
                 280,
                 badge: 'Event',
                 onTap: () => onAction?.call(isAdmin ? 1 : 0),
               ),
               data: (config) {
                 final ptmDate = config.getPtmDate(targetYear: now.year, targetMonth: now.month);
                 return _statCard(
                   context,
                   context.l.ptmDay,
                   DateFormat('MMM d').format(ptmDate),
                   Icons.event_available_rounded,
                   280,
                   badge: 'Scheduled',
                   onTap: () => onAction?.call(isAdmin ? 1 : 0),
                 );
               },
             ),
             // 4. Fees Card -> Navigates to Monthly Report tab
             if (isFeeEnabled)
               configAsync.when(
                 loading: () => placeholderCard(context.l.baseFeeLabel),
                 error: (_, __) => _statCard(
                   context,
                   context.l.baseFeeLabel,
                   '-',
                   Icons.account_balance_wallet_rounded,
                   35,
                   badge: 'Base',
                   onTap: () => onAction?.call(isAdmin ? 4 : 3),
                 ),
                 data: (config) => _statCard(
                   context,
                   context.l.baseFeeLabel,
                   'Rs. ${config.baseFee.toInt()}',
                   Icons.account_balance_wallet_rounded,
                   35,
                   badge: 'Per Student',
                   onTap: () => onAction?.call(isAdmin ? 4 : 3),
                 ),
               ),
           ],
         );
       },
     );
   }

  Widget _statCard(
    BuildContext context,
    String label,
    String value,
    IconData icon,
    double hue, {
    String? badge,
    VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isMobile = MediaQuery.of(context).size.width < kMobileBreakpoint;

    // Derived HSL colors
    final accentColor = HSLColor.fromAHSL(1.0, hue, 0.75, 0.46).toColor();
    final bgTint = HSLColor.fromAHSL(1.0, hue, 0.70, 0.94).toColor();

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        splashColor: accentColor.withValues(alpha: 0.12),
        highlightColor: accentColor.withValues(alpha: 0.06),
        child: Ink(
          padding: EdgeInsets.all(isMobile ? 12 : 18),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF131B2E) : Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.04),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
              if (onTap != null)
                BoxShadow(
                  color: accentColor.withValues(alpha: isDark ? 0.08 : 0.03),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
            ],
            border: Border.all(
              color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE2E8F0),
              width: 1.2,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: EdgeInsets.all(isMobile ? 7 : 10),
                    decoration: BoxDecoration(
                      color: isDark ? accentColor.withValues(alpha: 0.22) : bgTint,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: accentColor.withValues(alpha: isDark ? 0.4 : 0.2),
                        width: 1,
                      ),
                    ),
                    child: Icon(icon, color: accentColor, size: isMobile ? 18 : 22),
                  ),
                  if (badge != null)
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
                        decoration: BoxDecoration(
                          color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isDark ? Colors.white10 : const Color(0xFFE2E8F0),
                            width: 0.75,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                badge,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: isMobile ? 9.5 : 10.5,
                                  fontWeight: FontWeight.w700,
                                  color: isDark ? Colors.white70 : const Color(0xFF475569),
                                ),
                              ),
                            ),
                            if (onTap != null) ...[
                              const SizedBox(width: 3),
                              Icon(
                                Icons.arrow_forward_ios_rounded,
                                size: isMobile ? 7.5 : 9,
                                color: isDark ? Colors.white38 : const Color(0xFF94A3B8),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        value,
                        style: TextStyle(
                          fontSize: isMobile ? 20 : 23,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                          color: isDark ? Colors.white : const Color(0xFF0F172A),
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.urduStyle(
                              style: TextStyle(
                                fontSize: isMobile ? 11 : 12,
                                color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQuickActions(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Enumerate quick actions and their navigation destinations
    final actions = [
      // 1. Daily Log -> attendance/lesson tab (indexes correspond to _selectedIndex in MadrassaDashboard)
      _QuickActionItem(
        title: context.l.dailyLog,
        subtitle: context.isUrdu
            ? "حاضری اور اسباق کی روزانہ رپورٹ درج کریں"
            : "Track attendance and lesson progress",
        icon: Icons.checklist_rounded,
        hue: 220, // Indigo
        onTap: () => onAction?.call(1),
      ),
      if (isAdmin) ...[
        // 2. Monthly Report -> analytical summary/exports (index 3)
        _QuickActionItem(
          title: context.l.monthlyReport,
          subtitle: context.isUrdu
              ? "ماہانہ حاضری، فیس اور کارکردگی کی رپورٹ اور ڈاؤن لوڈ"
              : "Analyze monthly metrics and export PDF/Excel files",
          icon: Icons.analytics_rounded,
          hue: 170, // Teal
          onTap: () => onAction?.call(3),
        ),
        // 3. Configuration -> settings parameters (index 4)
        _QuickActionItem(
          title: context.l.config,
          subtitle: context.isUrdu
              ? "بنیادی فیس، چھٹیوں اور پی ٹی ایم کی تاریخوں کی ترتیبات"
              : "Manage base fees, holiday dates, and PTM timings",
          icon: Icons.settings_suggest_rounded,
          hue: 35, // Orange/Gold
          onTap: () => onAction?.call(4),
        ),
      ],
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l.todayActions,
          style: context.urduStyle(
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : const Color(0xFF0F172A),
            ),
          ),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final isMobile = constraints.maxWidth < kMobileBreakpoint;
            if (isMobile) {
              return Column(
                children: actions
                    .map((act) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _quickActionCard(context, act),
                        ))
                    .toList(),
              );
            } else {
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 16,
                  mainAxisExtent: 88,
                ),
                itemCount: actions.length,
                itemBuilder: (context, idx) {
                  return _quickActionCard(context, actions[idx]);
                },
              );
            }
          },
        ),
      ],
    );
  }

  Widget _quickActionCard(BuildContext context, _QuickActionItem item) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final accentColor = HSLColor.fromAHSL(1.0, item.hue, 0.70, 0.45).toColor();
    final bgTint = HSLColor.fromAHSL(1.0, item.hue, 0.70, 0.94).toColor();

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: item.onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          decoration: BoxDecoration(
            color: theme.cardColor,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: isDark ? Colors.white10 : const Color(0xFFE2E8F0), width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: isDark ? accentColor.withValues(alpha: 0.2) : bgTint,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(item.icon, color: accentColor, size: 24),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      item.title,
                      style: context.urduStyle(
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : const Color(0xFF0F172A),
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.urduStyle(
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white70 : const Color(0xFF64748B),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.arrow_forward_ios_rounded,
                size: 14,
                color: isDark ? Colors.white54 : const Color(0xFF94A3B8),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRecentActivity(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return ValueListenableBuilder(
      valueListenable: Hive.box(LocalStorageService.auditLogsBox).listenable(),
      builder: (context, Box box, _) {
        final normBranch = branchId.toLowerCase().trim();
        final List<Map<String, dynamic>> logs = [];
        for (final val in box.values) {
          if (val is! Map) continue;
          final m = Map<String, dynamic>.from(val);
          final mod = m['module']?.toString().toLowerCase();
          final b = (m['branchId'] ?? m['branchContext'])?.toString().toLowerCase().trim();
          if (mod == 'madrassa' || mod == 'education' || m['entityType'] == 'madrassa') {
            if (b == null || b.isEmpty || b == 'all' || b == normBranch) {
              logs.add(m);
            }
          }
        }
        logs.sort((a, b) {
          final tA = a['timestamp']?.toString() ?? a['date']?.toString() ?? '';
          final tB = b['timestamp']?.toString() ?? b['date']?.toString() ?? '';
          return tB.compareTo(tA);
        });
        final docs = logs.take(10).toList();

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF131B2E) : Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: isDark ? Colors.white10 : const Color(0xFFE2E8F0)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    context.l.auditLog,
                    style: context.urduStyle(
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                      ),
                    ),
                  ),
                  Icon(Icons.history_rounded, color: isDark ? Colors.white54 : const Color(0xFF0F766E)),
                ],
              ),
              const SizedBox(height: 20),
              if (docs.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24.0),
                  child: Center(
                    child: Column(
                      children: [
                        Icon(Icons.event_note_rounded, size: 36, color: Colors.grey.shade400),
                        const SizedBox(height: 8),
                        Text(
                          context.isUrdu ? 'کوئی حالیہ سرگرمی ریکارڈ نہیں ہے' : 'No recent activity logs recorded yet',
                          style: context.urduStyle(style: TextStyle(color: Colors.grey.shade500, fontSize: 13.5)),
                        ),
                      ],
                    ),
                  ),
                )
              else ...[
                ...List.generate(docs.length, (index) {
                  final doc = docs[index];
                  final log = doc;
                  final editor = (log['editor'] ?? log['userName'] ?? log['user'] ?? 'System').toString();
                  final role = (log['role'] ?? log['userRole'] ?? '').toString();
                  final message = (log['message'] ?? log['action'] ?? log['details'] ?? log['note'] ?? 'Activity recorded').toString();
                  final timestampObj = log['timestamp'] ?? log['date'] ?? log['createdAt'];

                  DateTime? timestamp;
                  if (timestampObj is Timestamp) {
                    timestamp = timestampObj.toDate();
                  } else if (timestampObj is String) {
                    timestamp = DateTime.tryParse(timestampObj);
                  }

                  final timeStr = timestamp != null ? _formatRelativeTime(timestamp) : '';

                  String title = editor;
                  IconData icon = Icons.info_outline;
                  Color color = const Color(0xFF0F766E);

                  final type = log['type'] ?? '';
                  if (type == 'ptm_reschedule') {
                    icon = Icons.notification_important_rounded;
                    color = const Color(0xFFEF4444);
                  } else if (type == 'daily_log_edit') {
                    icon = Icons.edit_calendar_rounded;
                    color = const Color(0xFF0F766E);
                  } else if (type == 'status_change') {
                    icon = Icons.swap_horiz_rounded;
                    color = const Color(0xFFF59E0B);
                  } else if (type == 'config_change') {
                    icon = Icons.settings_rounded;
                    color = const Color(0xFF0284C7);
                  } else if (type == 'student_enrollment') {
                    icon = Icons.person_add_rounded;
                    color = const Color(0xFF10B981);
                  } else if (type == 'student_edit') {
                    icon = Icons.edit_note_rounded;
                    color = const Color(0xFF6366F1);
                  }

                  final isLast = index == docs.length - 1;

                  return _buildActivityTimelineItem(
                    context: context,
                    title: title,
                    message: message,
                    timeStr: timeStr,
                    timestamp: timestamp,
                    icon: icon,
                    color: color,
                    isLast: isLast,
                    role: role,
                  );
                }),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.center,
                  child: TextButton.icon(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => AuditLogView(branchId: branchId),
                        ),
                      );
                    },
                    icon: const Icon(Icons.arrow_forward_rounded, size: 14),
                    label: Text(context.isUrdu ? 'تمام لاگز دیکھیں' : 'View All Logs', style: const TextStyle(fontWeight: FontWeight.bold)),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF0F766E),
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildActivityTimelineItem({
    required BuildContext context,
    required String title,
    required String message,
    required String timeStr,
    required DateTime? timestamp,
    required IconData icon,
    required Color color,
    required bool isLast,
    required String role,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Left column: Icon and vertical connecting bar
          Column(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                  border: Border.all(color: color.withValues(alpha: 0.3), width: 1.2),
                ),
                child: Icon(icon, color: color, size: 16),
              ),
              if (!isLast)
                Container(
                  width: 2,
                  height: 38,
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  color: isDark ? Colors.white12 : const Color(0xFFE2E8F0),
                ),
            ],
          ),
          const SizedBox(width: 10),
          // Right column: Content card
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                  width: 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header Row: Editor Name & Timestamp
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: context.urduStyle(
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12.5,
                              color: isDark ? Colors.white : const Color(0xFF0F172A),
                            ),
                          ),
                        ),
                      ),
                      if (timeStr.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Text(
                          timeStr,
                          style: TextStyle(
                            color: isDark ? Colors.white54 : const Color(0xFF94A3B8),
                            fontSize: 10.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ],
                  ),
                  // Role Badge Pill
                  if (role.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(color: color.withValues(alpha: 0.2), width: 0.6),
                      ),
                      child: Text(
                        role.toUpperCase(),
                        style: TextStyle(
                          fontSize: 9.0,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                          color: color,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  // Message Body
                  Text(
                    message,
                    style: context.urduStyle(
                      style: TextStyle(
                        color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569),
                        fontSize: 11.5,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatRelativeTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inSeconds < 60) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      final minutes = difference.inMinutes;
      return '$minutes minute${minutes == 1 ? '' : 's'} ago';
    } else if (difference.inHours < 24) {
      final hours = difference.inHours;
      return '$hours hour${hours == 1 ? '' : 's'} ago';
    } else if (difference.inDays == 1) {
      return 'Yesterday';
    } else if (difference.inDays < 7) {
      final days = difference.inDays;
      return '$days day${days == 1 ? '' : 's'} ago';
    } else {
      return DateFormat('yyyy-MM-dd').format(dateTime);
    }
  }
}

class _QuickActionItem {
  final String title;
  final String subtitle;
  final IconData icon;
  final double hue;
  final VoidCallback onTap;

  const _QuickActionItem({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.hue,
    required this.onTap,
  });
}
