// lib/pages/school/daily/views/daily_month_tab.dart
//
// Month tab: per student, how many days earned each of the six fee rules so
// far, out of the days recorded. Lists working days still not recorded (the
// month cannot be closed for fees until they are — Phase 4). Rupee amounts
// come with the fee engine in Phase 4.

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';

import '../../constants/school_constants.dart';
import '../../students/student_rules.dart';
import '../daily_models.dart';
import '../daily_rules.dart';
import '../school_daily_service.dart';
import 'daily_common.dart';

class DailyMonthTab extends StatefulWidget {
  const DailyMonthTab({super.key, required this.ctx, required this.month, required this.onMonthChanged, required this.onOpenDay});
  final DailyContext ctx;
  final DateTime month;
  final ValueChanged<DateTime> onMonthChanged;
  final ValueChanged<DateTime> onOpenDay;

  @override
  State<DailyMonthTab> createState() => _DailyMonthTabState();
}

class _DailyMonthTabState extends State<DailyMonthTab> {
  late String _grade = widget.ctx.firstGradeWithStudents;
  String _section = 'All';

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final ctx = widget.ctx;
    final m = widget.month;
    final now = DateTime.now();
    final cal = ctx.calendar;
    final logs = SchoolDailyService.month(ctx.branchId, m.year, m.month);
    final lastDay = DateTime(m.year, m.month + 1, 0);
    final asOf = lastDay.isBefore(now) ? lastDay : now;
    final students = ctx.classOn(asOf, _grade, _section);
    // Students who left during the month still belong on its sheet.
    final everyone = ctx.roster.students
        .where((s) => s.grade == _grade && (_section == 'All' || s.section == _section) && !s.isVoid)
        .where((s) => SchoolDailyRules.daysOfMonth(m.year, m.month).any((d) => !d.isAfter(now) && StudentRules.isActiveOn(s, d)))
        .toList();
    for (final s in students) {
      if (!everyone.contains(s)) everyone.add(s);
    }
    final working = SchoolDailyRules.workingDays(m.year, m.month, cal);
    final holidays = cal.holidays.values.where((h) => h.date.startsWith(SchoolDailyRules.ym(m))).toList()..sort((a, b) => a.date.compareTo(b.date));
    final ptm = cal.ptmFor(m.year, m.month);
    final unrecorded = SchoolDailyRules.unrecordedDays(students: everyone, year: m.year, month: m.month, cal: cal, logs: logs, now: now);

    final toolbar = Wrap(spacing: Gsp.sp2, runSpacing: Gsp.sp2, crossAxisAlignment: WrapCrossAlignment.center, children: [
      DailyStepper(
        label: dailyMonthLabel(m),
        onPrev: () => widget.onMonthChanged(DateTime(m.year, m.month - 1)),
        onNext: DateTime(m.year, m.month + 1).isAfter(now) ? null : () => widget.onMonthChanged(DateTime(m.year, m.month + 1)),
      ),
      SizedBox(
        width: 140,
        child: DropdownButtonFormField<String>(
          initialValue: _grade,
          isExpanded: true,
          decoration: const InputDecoration(isDense: true, labelText: 'Class'),
          items: [for (final g in ctx.gradeOptions) DropdownMenuItem(value: g, child: Text(g))],
          onChanged: (v) => setState(() => _grade = v ?? _grade),
        ),
      ),
      SizedBox(
        width: 120,
        child: DropdownButtonFormField<String>(
          initialValue: _section,
          isExpanded: true,
          decoration: const InputDecoration(isDense: true, labelText: 'Section'),
          items: [
            const DropdownMenuItem(value: 'All', child: Text('All')),
            for (final s in SchoolConstants.sections) DropdownMenuItem(value: s, child: Text(s)),
          ],
          onChanged: (v) => setState(() => _section = v ?? 'All'),
        ),
      ),
    ]);

    final facts = Wrap(spacing: Gsp.sp2, runSpacing: Gsp.sp2, children: [
      AppChip(label: '${working.length} working days', state: AppChipState.neutral, icon: GIcons.calendar),
      AppChip(label: '${holidays.length} ${holidays.length == 1 ? 'holiday' : 'holidays'}', state: AppChipState.neutral, icon: GIcons.event),
      AppChip(
        label: 'PTM ${dailyShortDate(ptm.date)} · ${switch (ptm.status) {
          SchoolPtmStatus.scheduled => 'scheduled',
          SchoolPtmStatus.held => 'held',
          SchoolPtmStatus.cancelled => 'cancelled',
        }}',
        state: ptm.status == SchoolPtmStatus.held ? AppChipState.active : AppChipState.info,
        icon: GIcons.team,
      ),
      if (cal.closedMonths.contains(SchoolDailyRules.ym(m))) const AppChip(label: 'Month closed', state: AppChipState.warning, icon: GIcons.lock),
    ]);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      toolbar,
      const SizedBox(height: Gsp.sp3),
      facts,
      if (unrecorded.isNotEmpty) ...[
        const SizedBox(height: Gsp.sp3),
        DailyBanner(
          tone: AppChipState.warning,
          icon: GIcons.warning,
          text: '${unrecorded.length} working ${unrecorded.length == 1 ? 'day has' : 'days have'} students not marked. '
              'Unmarked days do not count against anyone, but the month cannot be closed for fees until they are marked.',
        ),
        const SizedBox(height: Gsp.sp2),
        Wrap(spacing: Gsp.sp1, runSpacing: Gsp.sp1, children: [
          for (final d in unrecorded.take(31))
            ActionChip(label: Text(dailyShortDate(SchoolDailyRules.ymd(d))), onPressed: () => widget.onOpenDay(d)),
        ]),
      ],
      const SizedBox(height: Gsp.sp3),
      Expanded(
        child: everyone.isEmpty
            ? const AppEmptyState(icon: GIcons.student, title: 'No students in this class for the month')
            : _MonthTable(
                rows: [
                  for (final s in everyone)
                    (s.name, s.rollNo, SchoolDailyRules.summarize(student: s, year: m.year, month: m.month, cal: cal, logs: logs, now: now)),
                ],
              ),
      ),
      const SizedBox(height: Gsp.sp2),
      Text(
        'Each box shows days that earned the rule out of days recorded. Rupee amounts are worked out when the fee engine is added.',
        style: GText.caption(c.textMuted),
      ),
    ]);
  }
}

class _MonthTable extends StatelessWidget {
  const _MonthTable({required this.rows});
  final List<(String, String, SchoolMonthSummary)> rows;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    Widget head(String t, {int flex = 2}) => Expanded(flex: flex, child: Text(t.toUpperCase(), style: GText.overline(c.textMuted)));

    Widget cell(int got, int of) {
      final ratio = of == 0 ? 1.0 : got / of;
      final color = of == 0 ? c.textMuted : ratio >= 0.9 ? c.success : ratio >= 0.6 ? c.warning : c.danger;
      return Expanded(
        flex: 2,
        child: Padding(
          padding: const EdgeInsetsDirectional.only(end: Gsp.sp3),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(of == 0 ? '—' : '$got/$of', style: GText.label(color)),
            const SizedBox(height: 2),
            GProgressBar(value: ratio, color: color, height: 4),
          ]),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(color: c.surface, borderRadius: Gr.card, border: Border.all(color: c.border)),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(builder: (context, box) {
        final table = SizedBox(
          width: box.maxWidth < 900 ? 900 : box.maxWidth,
          child: Column(children: [
            Container(
              color: c.surfaceSunken,
              padding: const EdgeInsets.symmetric(horizontal: Gsp.sp4, vertical: Gsp.sp3),
              child: Row(children: [
                head('Student', flex: 5),
                for (final r in SchoolFeeRule.daily) head(r.label),
                head('PTM'),
                head('Recorded'),
              ]),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final (name, roll, s) = rows[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Gsp.sp4, vertical: Gsp.sp2 + 2),
                    child: Row(children: [
                      Expanded(
                        flex: 5,
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: GText.body2Bold(c.textPrimary)),
                          Text(
                            '${roll.isEmpty ? '' : '#$roll · '}${s.present}P ${s.absent}A ${s.leave}L${s.late > 0 ? ' · ${s.late} late' : ''}',
                            style: GText.caption(c.textMuted),
                          ),
                        ]),
                      ),
                      for (final r in SchoolFeeRule.daily) cell(s.qualifying[r]!, s.recordedDays),
                      Expanded(
                        flex: 2,
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: switch (s.ptm) {
                            null => AppChip(label: 'Pending', state: AppChipState.neutral),
                            true => const AppChip(label: 'Yes', state: AppChipState.active, icon: GIcons.check),
                            false => const AppChip(label: 'No', state: AppChipState.danger, icon: GIcons.close),
                          },
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: Text(
                          '${s.recordedDays}/${s.activeDays}',
                          style: GText.label(s.unrecorded > 0 ? c.warning : c.textSecondary),
                        ),
                      ),
                    ]),
                  );
                },
              ),
            ),
          ]),
        );
        return box.maxWidth < 900
            ? SingleChildScrollView(scrollDirection: Axis.horizontal, child: SizedBox(height: box.maxHeight, child: table))
            : table;
      }),
    );
  }
}
