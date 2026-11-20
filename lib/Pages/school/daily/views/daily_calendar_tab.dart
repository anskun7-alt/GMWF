// lib/pages/school/daily/views/daily_calendar_tab.dart
//
// Calendar tab: the month's days at a glance, holidays (add / remove), the
// month's PTM (move, cancel, record which parents came) and the school day
// settings (weekly days off, start time and grace, teacher edit window,
// leave on/off). Teachers can view; Principal / School Admin can change.

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../constants/school_constants.dart';
import '../../students/student_rules.dart';
import '../daily_models.dart';
import '../daily_rules.dart';
import '../school_daily_service.dart';
import 'daily_common.dart';

class DailyCalendarTab extends StatelessWidget {
  const DailyCalendarTab({super.key, required this.ctx, required this.month, required this.onMonthChanged, required this.onOpenDay});
  final DailyContext ctx;
  final DateTime month;
  final ValueChanged<DateTime> onMonthChanged;
  final ValueChanged<DateTime> onOpenDay;

  @override
  Widget build(BuildContext context) {
    final m = month;
    final cal = ctx.calendar;
    final now = DateTime.now();
    final logs = SchoolDailyService.month(ctx.branchId, m.year, m.month);

    final left = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        DailyStepper(
          label: dailyMonthLabel(m),
          onPrev: () => onMonthChanged(DateTime(m.year, m.month - 1)),
          onNext: () => onMonthChanged(DateTime(m.year, m.month + 1)),
        ),
      ]),
      const SizedBox(height: Gsp.sp3),
      _MonthGrid(month: m, cal: cal, logs: logs, now: now, onOpenDay: onOpenDay),
      const SizedBox(height: Gsp.sp4),
      _HolidaysCard(ctx: ctx, month: m),
    ]);

    final right = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _PtmCard(ctx: ctx, month: m),
      const SizedBox(height: Gsp.sp4),
      _SettingsCard(ctx: ctx),
    ]);

    return LayoutBuilder(builder: (context, box) {
      if (box.maxWidth < 900) {
        return ListView(children: [left, const SizedBox(height: Gsp.sp4), right]);
      }
      return SingleChildScrollView(
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 3, child: left),
          const SizedBox(width: Gsp.sp4),
          Expanded(flex: 2, child: right),
        ]),
      );
    });
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.icon, required this.child, this.trailing});
  final String title;
  final IconData icon;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    return Container(
      padding: const EdgeInsets.all(Gsp.sp4),
      decoration: BoxDecoration(color: c.surface, borderRadius: Gr.card, border: Border.all(color: c.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(icon, size: GIconSize.md, color: c.brand),
          const SizedBox(width: Gsp.sp2),
          Expanded(child: Text(title, style: GText.h3(c.textPrimary))),
          if (trailing != null) trailing!,
        ]),
        const SizedBox(height: Gsp.sp3),
        child,
      ]),
    );
  }
}

// ── Month grid ──────────────────────────────────────────────────────────────

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({required this.month, required this.cal, required this.logs, required this.now, required this.onOpenDay});
  final DateTime month;
  final SchoolCalendar cal;
  final Map<String, Map<String, SchoolDayEntry>> logs;
  final DateTime now;
  final ValueChanged<DateTime> onOpenDay;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final days = SchoolDailyRules.daysOfMonth(month.year, month.month);
    final lead = (days.first.weekday - 1) % 7; // Monday first
    final ptm = cal.ptmFor(month.year, month.month);
    final names = [for (var i = 0; i < 7; i++) DateFormat('E').format(DateTime(2024, 1, 1 + i))];

    return Container(
      padding: const EdgeInsets.all(Gsp.sp3),
      decoration: BoxDecoration(color: c.surface, borderRadius: Gr.card, border: Border.all(color: c.border)),
      child: Column(children: [
        Row(children: [for (final n in names) Expanded(child: Center(child: Text(n, style: GText.overline(c.textMuted))))]),
        const SizedBox(height: Gsp.sp2),
        GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 1.9,
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
          children: [
            for (var i = 0; i < lead; i++) const SizedBox.shrink(),
            for (final d in days)
              Builder(builder: (context) {
                final kind = cal.kindOf(d);
                final key = SchoolDailyRules.ymd(d);
                final marked = (logs[key] ?? const {}).values.where((e) => e.isMarked).length;
                final isPtm = ptm.date == key && ptm.status != SchoolPtmStatus.cancelled;
                final today = SchoolDailyRules.day(now) == d;
                final future = d.isAfter(SchoolDailyRules.day(now));
                final (Color bg, Color fg) = switch (kind) {
                  SchoolDayKind.holiday => (c.warningBg, c.warning),
                  SchoolDayKind.weeklyOff => (c.surfaceSunken, c.textMuted),
                  SchoolDayKind.working => future
                      ? (c.surface, c.textSecondary)
                      : marked > 0
                          ? (c.successBg, c.success)
                          : (c.dangerBg, c.danger),
                };
                return Tooltip(
                  message: switch (kind) {
                    SchoolDayKind.holiday => cal.holidays[key]?.name ?? 'Holiday',
                    SchoolDayKind.weeklyOff => 'Day off',
                    SchoolDayKind.working => future ? 'Working day' : (marked > 0 ? '$marked marked' : 'Not marked'),
                  } + (isPtm ? ' · PTM' : ''),
                  child: InkWell(
                    borderRadius: Gr.input,
                    onTap: kind == SchoolDayKind.working && !future ? () => onOpenDay(d) : null,
                    child: Container(
                      decoration: BoxDecoration(
                        color: bg,
                        borderRadius: Gr.input,
                        border: Border.all(color: today ? c.brand : Colors.transparent, width: 2),
                      ),
                      alignment: Alignment.center,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text('${d.day}', style: GText.label(fg)),
                        if (isPtm) Icon(GIcons.team, size: 12, color: c.brand),
                      ]),
                    ),
                  ),
                );
              }),
          ],
        ),
        const SizedBox(height: Gsp.sp2),
        Wrap(spacing: Gsp.sp3, runSpacing: Gsp.sp1, children: [
          _legend(c.successBg, 'Marked', c),
          _legend(c.dangerBg, 'Not marked', c),
          _legend(c.warningBg, 'Holiday', c),
          _legend(c.surfaceSunken, 'Day off', c),
        ]),
      ]),
    );
  }

  Widget _legend(Color color, String label, GComfortColors c) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 12, height: 12, decoration: BoxDecoration(color: color, borderRadius: Gr.chip, border: Border.all(color: c.border))),
        const SizedBox(width: 4),
        Text(label, style: GText.caption(c.textMuted)),
      ]);
}

// ── Holidays ────────────────────────────────────────────────────────────────

class _HolidaysCard extends StatelessWidget {
  const _HolidaysCard({required this.ctx, required this.month});
  final DailyContext ctx;
  final DateTime month;

  Future<void> _add(BuildContext context) async {
    final name = TextEditingController();
    var date = DateTime(month.year, month.month, 1);
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dctx) => StatefulBuilder(builder: (dctx, setS) {
        return AlertDialog(
          title: const Text('Add holiday'),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (error != null) ...[Text(error!, style: GText.body2(dctx.comfort.danger)), const SizedBox(height: Gsp.sp2)],
              InkWell(
                onTap: () async {
                  final p = await showDatePicker(
                    context: dctx,
                    initialDate: date,
                    firstDate: DateTime(month.year - 1),
                    lastDate: DateTime(month.year + 1, 12, 31),
                  );
                  if (p != null) setS(() => date = p);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: 'Date', suffixIcon: Icon(GIcons.calendar)),
                  child: Text(dailyDayLabel(date)),
                ),
              ),
              const SizedBox(height: Gsp.sp3),
              TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. Quaid Day, Eid ul Fitr')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                try {
                  await SchoolDailyService.addHoliday(branchId: ctx.branchId, date: date, name: name.text, editorName: ctx.editorName);
                  if (dctx.mounted) Navigator.pop(dctx);
                } catch (e) {
                  setS(() => error = e is SchoolDailyException ? e.message : '$e');
                }
              },
              child: const Text('Add'),
            ),
          ],
        );
      }),
    );
    name.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final prefix = SchoolDailyRules.ym(month);
    final list = ctx.calendar.holidays.values.where((h) => h.date.startsWith(prefix)).toList()..sort((a, b) => a.date.compareTo(b.date));
    return _Card(
      title: 'Holidays',
      icon: GIcons.event,
      trailing: ctx.isPrincipal
          ? TextButton.icon(onPressed: () => _add(context), icon: const Icon(GIcons.add), label: const Text('Add'))
          : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (list.isEmpty) Text('No holidays this month.', style: GText.body2(c.textMuted)),
        for (final h in list)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: const Icon(GIcons.event),
            title: Text(h.name, style: GText.body2Bold(c.textPrimary)),
            subtitle: Text(dailyDayLabel(DateTime.parse(h.date)), style: GText.caption(c.textMuted)),
            trailing: ctx.isPrincipal
                ? IconButton(
                    tooltip: 'Remove holiday',
                    icon: const Icon(GIcons.close),
                    onPressed: () async {
                      try {
                        await SchoolDailyService.removeHoliday(branchId: ctx.branchId, date: h.date, editorName: ctx.editorName);
                      } catch (e) {
                        if (context.mounted) AppFeedback.error(context, '$e');
                      }
                    },
                  )
                : null,
          ),
        const SizedBox(height: Gsp.sp1),
        Text(
          'Holidays and weekly days off are left out of attendance and the fee on both sides. '
          'A day that already has marks cannot be made a holiday.',
          style: GText.caption(c.textMuted),
        ),
      ]),
    );
  }
}

// ── PTM ─────────────────────────────────────────────────────────────────────

class _PtmCard extends StatelessWidget {
  const _PtmCard({required this.ctx, required this.month});
  final DailyContext ctx;
  final DateTime month;

  Future<void> _run(BuildContext context, Future<void> Function() action, String done) async {
    try {
      await action();
      if (context.mounted) AppFeedback.success(context, done);
    } catch (e) {
      if (context.mounted) AppFeedback.error(context, e is SchoolDailyException ? e.message : '$e');
    }
  }

  Future<void> _move(BuildContext context, SchoolPtm ptm) async {
    final current = DateTime.tryParse(ptm.date) ?? DateTime(month.year, month.month, 1);
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(month.year, month.month, 1),
      lastDate: DateTime(month.year, month.month + 1, 0),
      selectableDayPredicate: ctx.calendar.isWorkingDay,
    );
    if (picked == null || !context.mounted) return;
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text('Move PTM to ${dailyDayLabel(picked)}?'),
        content: TextField(controller: reason, decoration: const InputDecoration(labelText: 'Reason (optional)')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dctx, true), child: const Text('Move')),
        ],
      ),
    );
    final why = reason.text;
    reason.dispose();
    if (ok != true || !context.mounted) return;
    await _run(context, () => SchoolDailyService.schedulePtm(branchId: ctx.branchId, date: picked, editorName: ctx.editorName, reason: why),
        'PTM moved to ${dailyDayLabel(picked)}');
  }

  Future<void> _attendance(BuildContext context, SchoolPtm ptm) async {
    final date = DateTime.tryParse(ptm.date) ?? DateTime.now();
    final students = ctx.roster.students.where((s) => !s.isVoid && StudentRules.isActiveOn(s, date)).toList()
      ..sort((a, b) {
        final g = SchoolConstants.grades.indexOf(a.grade).compareTo(SchoolConstants.grades.indexOf(b.grade));
        return g != 0 ? g : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    final marks = {for (final s in students) s.id: ptm.attended[s.id] ?? false};
    var filter = 'All';
    final saved = await showDialog<bool>(
      context: context,
      builder: (dctx) => StatefulBuilder(builder: (dctx, setS) {
        final c = dctx.comfort;
        final visible = filter == 'All' ? students : students.where((s) => s.grade == filter).toList();
        return AlertDialog(
          title: Text('Who came to the PTM · ${dailyShortDate(ptm.date)}'),
          content: SizedBox(
            width: 520,
            height: 480,
            child: Column(children: [
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: filter,
                    isExpanded: true,
                    decoration: const InputDecoration(isDense: true, labelText: 'Class'),
                    items: [
                      const DropdownMenuItem(value: 'All', child: Text('All classes')),
                      for (final g in SchoolConstants.grades) DropdownMenuItem(value: g, child: Text(g)),
                    ],
                    onChanged: (v) => setS(() => filter = v ?? 'All'),
                  ),
                ),
                const SizedBox(width: Gsp.sp2),
                TextButton(
                  onPressed: () => setS(() {
                    for (final s in visible) {
                      marks[s.id] = true;
                    }
                  }),
                  child: const Text('All came'),
                ),
              ]),
              const SizedBox(height: Gsp.sp2),
              Text('${marks.values.where((v) => v).length} of ${students.length} parents came', style: GText.caption(c.textMuted)),
              const SizedBox(height: Gsp.sp2),
              Expanded(
                child: ListView(children: [
                  for (final s in visible)
                    CheckboxListTile(
                      dense: true,
                      value: marks[s.id],
                      onChanged: (v) => setS(() => marks[s.id] = v ?? false),
                      title: Text(s.name),
                      subtitle: Text('${s.grade}-${s.section} · Father: ${s.guardianName}'),
                    ),
                ]),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(dctx, true), child: const Text('Save')),
          ],
        );
      }),
    );
    if (saved != true || !context.mounted) return;
    await _run(
      context,
      () => SchoolDailyService.savePtmAttendance(branchId: ctx.branchId, year: month.year, month: month.month, attended: marks, editorName: ctx.editorName),
      'PTM attendance saved',
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final ptm = ctx.calendar.ptmFor(month.year, month.month);
    final saved = ctx.calendar.ptms.containsKey(ptm.month);
    final date = DateTime.tryParse(ptm.date);
    final came = ptm.attended.values.where((v) => v).length;
    final canRecord = date != null && !date.isAfter(DateTime.now()) && ptm.status != SchoolPtmStatus.cancelled;

    return _Card(
      title: 'Parent-teacher meeting',
      icon: GIcons.team,
      trailing: AppChip(
        label: switch (ptm.status) {
          SchoolPtmStatus.scheduled => saved ? 'Scheduled' : 'Default date',
          SchoolPtmStatus.held => 'Held',
          SchoolPtmStatus.cancelled => 'Cancelled',
        },
        state: switch (ptm.status) {
          SchoolPtmStatus.scheduled => AppChipState.info,
          SchoolPtmStatus.held => AppChipState.active,
          SchoolPtmStatus.cancelled => AppChipState.warning,
        },
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(date == null ? '—' : dailyDayLabel(date), style: GText.h2(c.textPrimary)),
        const SizedBox(height: Gsp.sp1),
        Text(
          ptm.status == SchoolPtmStatus.held
              ? '$came ${came == 1 ? 'parent' : 'parents'} came.'
              : ptm.status == SchoolPtmStatus.cancelled
                  ? 'Cancelled: every student gets the PTM credit this month.'
                  : 'Default is the last Saturday of the month. Students admitted after the PTM get the credit.',
          style: GText.body2(c.textSecondary),
        ),
        if (ptm.history.isNotEmpty) ...[
          const SizedBox(height: Gsp.sp2),
          for (final h in ptm.history) Text('Moved: $h', style: GText.caption(c.textMuted)),
        ],
        if (ctx.isPrincipal) ...[
          const SizedBox(height: Gsp.sp3),
          Wrap(spacing: Gsp.sp2, runSpacing: Gsp.sp2, children: [
            if (canRecord)
              FilledButton.icon(onPressed: () => _attendance(context, ptm), icon: const Icon(GIcons.checklist), label: const Text('Who came')),
            if (ptm.status != SchoolPtmStatus.held)
              OutlinedButton.icon(onPressed: () => _move(context, ptm), icon: const Icon(GIcons.calendar), label: Text(saved ? 'Move' : 'Set date')),
            if (ptm.status == SchoolPtmStatus.scheduled)
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: c.danger),
                onPressed: () => _run(
                  context,
                  () => SchoolDailyService.setPtmStatus(
                      branchId: ctx.branchId, year: month.year, month: month.month, status: SchoolPtmStatus.cancelled, editorName: ctx.editorName),
                  'PTM cancelled',
                ),
                icon: const Icon(GIcons.cancel),
                label: const Text('Cancel PTM'),
              ),
            if (ptm.status == SchoolPtmStatus.cancelled)
              OutlinedButton.icon(
                onPressed: () => _run(
                  context,
                  () => SchoolDailyService.setPtmStatus(
                      branchId: ctx.branchId, year: month.year, month: month.month, status: SchoolPtmStatus.scheduled, editorName: ctx.editorName),
                  'PTM back on',
                ),
                icon: const Icon(GIcons.refresh),
                label: const Text('Undo cancel'),
              ),
          ]),
        ],
      ]),
    );
  }
}

// ── Settings ────────────────────────────────────────────────────────────────

class _SettingsCard extends StatefulWidget {
  const _SettingsCard({required this.ctx});
  final DailyContext ctx;

  @override
  State<_SettingsCard> createState() => _SettingsCardState();
}

class _SettingsCardState extends State<_SettingsCard> {
  late SchoolCalendarSettings _s = widget.ctx.calendar.settings;
  late final _start = TextEditingController(text: _s.startTime);
  bool _saving = false;

  @override
  void dispose() {
    _start.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final can = widget.ctx.isPrincipal;
    final names = [for (var i = 1; i <= 7; i++) DateFormat('E').format(DateTime(2024, 1, i))]; // Mon..Sun
    return _Card(
      title: 'School day',
      icon: GIcons.settings,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Weekly days off', style: GText.label(c.textSecondary)),
        const SizedBox(height: Gsp.sp1),
        Wrap(spacing: Gsp.sp1, runSpacing: Gsp.sp1, children: [
          for (var d = 1; d <= 7; d++)
            FilterChip(
              label: Text(names[d - 1]),
              selected: _s.weeklyOff.contains(d),
              onSelected: !can
                  ? null
                  : (v) => setState(() {
                        final set = {..._s.weeklyOff};
                        v ? set.add(d) : set.remove(d);
                        _s = _s.copyWith(weeklyOff: set);
                      }),
            ),
        ]),
        const SizedBox(height: Gsp.sp3),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _start,
              enabled: can,
              decoration: const InputDecoration(labelText: 'School starts', hintText: '08:00'),
              onChanged: (v) => _s = _s.copyWith(startTime: v.trim()),
            ),
          ),
          const SizedBox(width: Gsp.sp2),
          Expanded(
            child: DropdownButtonFormField<int>(
              initialValue: _s.graceMinutes,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Late after'),
              items: [for (final m in {0, 5, 10, 15, 20, 30, _s.graceMinutes}) DropdownMenuItem(value: m, child: Text('$m min'))],
              onChanged: can ? (v) => setState(() => _s = _s.copyWith(graceMinutes: v)) : null,
            ),
          ),
        ]),
        const SizedBox(height: Gsp.sp3),
        DropdownButtonFormField<int>(
          initialValue: _s.teacherEditDays,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Teachers can edit'),
          items: [
            for (final d in {0, 1, 2, 3, 5, 7, _s.teacherEditDays})
              DropdownMenuItem(value: d, child: Text(d == 0 ? 'Today only' : 'Today and the past $d ${d == 1 ? 'day' : 'days'}')),
          ],
          onChanged: can ? (v) => setState(() => _s = _s.copyWith(teacherEditDays: v)) : null,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Allow marking leave'),
          subtitle: const Text('Approved leave counts as present for the fee'),
          value: _s.allowLeave,
          onChanged: can ? (v) => setState(() => _s = _s.copyWith(allowLeave: v)) : null,
        ),
        if (can) ...[
          const SizedBox(height: Gsp.sp2),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton.icon(
              onPressed: _saving
                  ? null
                  : () async {
                      setState(() => _saving = true);
                      try {
                        await SchoolDailyService.saveSettings(branchId: widget.ctx.branchId, settings: _s, editorName: widget.ctx.editorName);
                        if (context.mounted) AppFeedback.success(context, 'School day settings saved');
                      } catch (e) {
                        if (context.mounted) AppFeedback.error(context, e is SchoolDailyException ? e.message : '$e');
                      } finally {
                        if (mounted) setState(() => _saving = false);
                      }
                    },
              icon: const Icon(GIcons.save),
              label: const Text('Save'),
            ),
          ),
        ],
      ]),
    );
  }
}
