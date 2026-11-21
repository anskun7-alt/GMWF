import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/madrassa_providers.dart';
import '../madrassa_strings.dart';
import '../widgets/madrassa_erp.dart';
import '../../../design/design_system.dart';

class MadrassaProgressView extends ConsumerStatefulWidget {
  final String branchId;
  final bool isAdmin;
  final String? username;

  const MadrassaProgressView({
    super.key,
    required this.branchId,
    required this.isAdmin,
    this.username,
  });

  @override
  ConsumerState<MadrassaProgressView> createState() => _MadrassaProgressViewState();
}

class _MadrassaProgressViewState extends ConsumerState<MadrassaProgressView> {
  String _selectedTimeframe = 'Daily'; // 'Daily', 'Weekly', 'Monthly', 'Overall'
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  int _calculateProgress(Map<String, dynamic> student, List<Map<String, dynamic>> allLogs) {
    final sId = student['id'] ?? '';
    final prevHifzLines = int.tryParse(student['prevHifzLines']?.toString() ?? '0') ?? 0;
    final studentCurrentLines = (student['currentLines'] as num?)?.toInt() ?? (int.tryParse(student['currentLines']?.toString() ?? '') ?? 0);

    if (_selectedTimeframe == 'Overall') {
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

    final sortedLogs = List<Map<String, dynamic>>.from(allLogs)
      ..sort((a, b) => a['dateKey'].toString().compareTo(b['dateKey'].toString()));

    if (_selectedTimeframe == 'Daily') {
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
    if (_selectedTimeframe == 'Weekly') {
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

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final studentsAsync = ref.watch(madrassaStudentsProvider(widget.branchId));
    final logsAsync = ref.watch(madrassaAllLogsProvider(widget.branchId));

    return studentsAsync.when(
      loading: () => Center(
        child: CircularProgressIndicator(color: c.brand),
      ),
      error: (e, st) => Center(child: Text('Error loading students: $e')),
      data: (students) {
        return logsAsync.when(
          loading: () => Center(
            child: CircularProgressIndicator(color: c.brand),
          ),
          error: (e, st) => Center(child: Text('Error loading logs: $e')),
          data: (allLogs) {
            // Process students and compute progress
            final List<Map<String, dynamic>> processedStudents = [];
            for (final std in students) {
              final statusVal = std['status'];
              final isActive = (statusVal == null || statusVal == '')
                  ? (std['active'] == true)
                  : (statusVal == 'active');
              if (!isActive) continue;

              final progress = _calculateProgress(std, allLogs);
              processedStudents.add({
                ...std,
                'calculatedProgress': progress,
              });
            }

            // Filter by search query
            final query = _searchQuery.trim().toLowerCase();
            final filteredStudents = processedStudents.where((std) {
              final name = (std['name']?.toString() ?? '').toLowerCase();
              final roll = (std['rollNumber']?.toString() ?? '').toLowerCase();
              return name.contains(query) || roll.contains(query);
            }).toList();

            // Sort lists
            final bestStudents = List<Map<String, dynamic>>.from(processedStudents)
              ..sort((a, b) => (b['calculatedProgress'] as int).compareTo(a['calculatedProgress'] as int));

            final worstStudents = List<Map<String, dynamic>>.from(processedStudents)
              ..sort((a, b) => (a['calculatedProgress'] as int).compareTo(b['calculatedProgress'] as int));

            // Categorize filtered students with dynamic thresholds based on timeframe
            int goodThreshold = 10;
            int badThreshold = 5;
            if (_selectedTimeframe == 'Weekly') {
              goodThreshold = 70;
              badThreshold = 35;
            } else if (_selectedTimeframe == 'Monthly') {
              goodThreshold = 300;
              badThreshold = 150;
            } else if (_selectedTimeframe == 'Overall') {
              goodThreshold = 10;
              badThreshold = 5;
            }

            final goodProgress = filteredStudents.where((s) => (s['calculatedProgress'] as int) > goodThreshold).toList()
              ..sort((a, b) => (b['calculatedProgress'] as int).compareTo(a['calculatedProgress'] as int));

            final avgProgress = filteredStudents.where((s) {
              final prog = s['calculatedProgress'] as int;
              return prog >= badThreshold && prog <= goodThreshold;
            }).toList()
              ..sort((a, b) => (b['calculatedProgress'] as int).compareTo(a['calculatedProgress'] as int));

            final badProgress = filteredStudents.where((s) => (s['calculatedProgress'] as int) < badThreshold).toList()
              ..sort((a, b) => (b['calculatedProgress'] as int).compareTo(a['calculatedProgress'] as int));

            final c = context.comfort;

            return Scaffold(
              backgroundColor: c.background,
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildTimeframeHeader(),
                    const SizedBox(height: 24),
                    _buildInsightsGrid(bestStudents, worstStudents),
                    const SizedBox(height: 24),
                    _buildSearchAndFilters(),
                    const SizedBox(height: 24),
                    _buildCategorizedLists(goodProgress, avgProgress, badProgress, goodThreshold, badThreshold),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildTimeframeHeader() {
    final c = context.comfort;
    final options = ['Daily', 'Weekly', 'Monthly', 'Overall'];
    final optionsUrdu = {
      'Daily': 'روزانہ',
      'Weekly': 'ہفتہ وار',
      'Monthly': 'ماہانہ',
      'Overall': 'مجموعی',
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < GBreakpoint.mobile;

        final title = MadrassaUrduAwareText(
          context.isUrdu ? 'طالب علموں کی کارکردگی' : 'Student Progress Insights',
          color: c.textPrimary,
          size: 18,
          bold: true,
        );

        final selector = Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: MadrassaErp.radius,
            border: Border.all(color: c.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: options.map((opt) {
              final isSelected = _selectedTimeframe == opt;
              final label = context.isUrdu ? optionsUrdu[opt]! : opt;
              return GestureDetector(
                onTap: () => setState(() => _selectedTimeframe = opt),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: isSelected ? c.brandSoft : Colors.transparent,
                    borderRadius: MadrassaErp.radius,
                    border: isSelected ? Border.all(color: c.brand.withValues(alpha: 0.35)) : null,
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                      color: isSelected ? c.brand : c.textMuted,
                      fontFamilyFallback: const ['Noori'],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        );

        if (isMobile) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              title,
              const SizedBox(height: 12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                child: selector,
              ),
            ],
          );
        } else {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              title,
              selector,
            ],
          );
        }
      },
    );
  }

  Widget _buildInsightsGrid(List<Map<String, dynamic>> best, List<Map<String, dynamic>> worst) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 600;
        final topPerformers = best.take(5).toList();
        final struggling = worst.take(5).toList();

        final bestCard = _buildInsightsCard(
          title: context.isUrdu ? 'بہترین کارکردگی (ٹاپ 5)' : 'Top Performers (Best 5)',
          students: topPerformers,
          isGood: true,
        );

        final worstCard = _buildInsightsCard(
          title: context.isUrdu ? 'توجہ طلب طالب علم (آخری 5)' : 'Needs Attention (Worst 5)',
          students: struggling,
          isGood: false,
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
              const SizedBox(width: 20),
              Expanded(child: worstCard),
            ],
          );
        }
      },
    );
  }

  Widget _buildInsightsCard({
    required String title,
    required List<Map<String, dynamic>> students,
    required bool isGood,
  }) {
    final c = context.comfort;
    final toneColor = isGood ? c.success : c.danger;

    return MadrassaCard(
      tone: toneColor,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isGood ? Icons.stars_rounded : Icons.warning_amber_rounded,
                color: toneColor,
                size: 20,
              ),
              const SizedBox(width: 8),
              MadrassaUrduAwareText(
                title,
                color: c.textPrimary,
                size: 14,
                bold: true,
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (students.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text(
                  context.isUrdu ? 'کوئی ڈیٹا موجود نہیں' : 'No data available',
                  style: TextStyle(color: c.textMuted, fontSize: 12),
                ),
              ),
            )
          else
            ...students.asMap().entries.map((e) {
              final idx = e.key;
              final std = e.value;
              final progress = std['calculatedProgress'] as int;

              return Padding(
                padding: const EdgeInsets.only(bottom: 10.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: c.surfaceSunken,
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: Text(
                                '${idx + 1}',
                                style: TextStyle(
                                  color: c.textMuted,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: MadrassaUrduAwareText(
                              std['name']?.toString() ?? '',
                              color: c.textPrimary,
                              size: 13,
                              bold: true,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: toneColor.withValues(alpha: 0.1),
                        borderRadius: MadrassaErp.radius,
                      ),
                      child: Text(
                        '+$progress ${context.isUrdu ? 'لائنیں' : 'lines'}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: toneColor,
                          fontFamilyFallback: const ['Noori'],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildSearchAndFilters() {
    final c = context.comfort;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: MadrassaErp.cardRadius,
        border: Border.all(color: c.border),
      ),
      child: TextField(
        controller: _searchCtrl,
        style: TextStyle(color: c.textPrimary),
        onChanged: (val) {
          setState(() {
            _searchQuery = val;
          });
        },
        decoration: InputDecoration(
          icon: Icon(Icons.search, color: c.textMuted),
          hintText: context.isUrdu ? 'طالب علم کا نام یا رول نمبر تلاش کریں...' : 'Search student by name or roll number...',
          hintStyle: TextStyle(
            fontSize: 13,
            color: c.textMuted,
          ),
          border: InputBorder.none,
        ),
      ),
    );
  }

  Widget _buildCategorizedLists(
    List<Map<String, dynamic>> good,
    List<Map<String, dynamic>> avg,
    List<Map<String, dynamic>> bad,
    int goodThreshold,
    int badThreshold,
  ) {
    final c = context.comfort;
    return Column(
      children: [
        _buildCategorySection(
          title: context.isUrdu ? 'بہترین ترقی (> $goodThreshold لائنیں)' : 'Good Progress (> $goodThreshold Lines)',
          count: good.length,
          students: good,
          indicatorColor: c.success,
        ),
        const SizedBox(height: 16),
        _buildCategorySection(
          title: context.isUrdu ? 'اوسط ترقی ($badThreshold سے $goodThreshold لائنیں)' : 'Average Progress ($badThreshold - $goodThreshold Lines)',
          count: avg.length,
          students: avg,
          indicatorColor: c.warning,
        ),
        const SizedBox(height: 16),
        _buildCategorySection(
          title: context.isUrdu ? 'کمزور ترقی (< $badThreshold لائنیں)' : 'Slow Progress (< $badThreshold Lines)',
          count: bad.length,
          students: bad,
          indicatorColor: c.danger,
        ),
      ],
    );
  }

  Widget _buildCategorySection({
    required String title,
    required int count,
    required List<Map<String, dynamic>> students,
    required Color indicatorColor,
  }) {
    final c = context.comfort;

    return MadrassaCard(
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        initiallyExpanded: count > 0,
        shape: const Border(),
        leading: Container(
          width: 4,
          height: 24,
          decoration: BoxDecoration(
            color: indicatorColor,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: MadrassaUrduAwareText(
                title,
                color: c.textPrimary,
                size: 14,
                bold: true,
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                color: indicatorColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: indicatorColor,
                ),
              ),
            ),
          ],
        ),
        children: [
          if (students.isEmpty)
            Padding(
              padding: const EdgeInsets.all(20.0),
              child: Center(
                child: Text(
                  context.isUrdu ? 'اس زمرے میں کوئی طالب علم نہیں ہے' : 'No students in this category',
                  style: TextStyle(
                    fontSize: 12,
                    color: c.textMuted,
                  ),
                ),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: students.length,
              separatorBuilder: (context, index) => Divider(color: c.border, height: 1),
              itemBuilder: (context, index) {
                final std = students[index];
                final progress = std['calculatedProgress'] as int;

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 16,
                              backgroundColor: c.surfaceSunken,
                              child: Text(
                                (std['rollNumber']?.toString() ?? '#').substring(0, 1),
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: c.textMuted,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  MadrassaUrduAwareText(
                                    std['name']?.toString() ?? '',
                                    color: c.textPrimary,
                                    size: 13,
                                    bold: true,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${context.isUrdu ? 'رول نمبر' : 'Roll'}: ${std['rollNumber'] ?? ''}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: c.textMuted,
                                      fontWeight: FontWeight.w500,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: indicatorColor.withValues(alpha: 0.1),
                          borderRadius: MadrassaErp.radius,
                          border: Border.all(color: indicatorColor.withValues(alpha: 0.2)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.add_rounded,
                              size: 12,
                              color: indicatorColor,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              '$progress ${context.isUrdu ? 'لائنیں' : 'lines'}',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: indicatorColor,
                                fontFamilyFallback: const ['Noori'],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
