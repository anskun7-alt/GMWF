// lib/pages/school/daily/views/daily_log_tab.dart
//
// Day tab: mark one class for one day. Per student: attendance (P / A / L /
// leave requested), on time, uniform, behaviour (+ note), message reply.
// Changes stay on screen until Save; only changed students are written.

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';

import '../../constants/school_constants.dart';
import '../../models/school_student.dart';
import '../daily_models.dart';
import '../daily_rules.dart';
import '../school_daily_service.dart';
import 'daily_common.dart';
import '../../widgets/erp/school_erp.dart';

class DailyLogTab extends StatefulWidget {
  const DailyLogTab({super.key, required this.ctx, required this.date, required this.onDateChanged});
  final DailyContext ctx;
  final DateTime date;
  final ValueChanged<DateTime> onDateChanged;

  @override
  State<DailyLogTab> createState() => DailyLogTabState();
}

class DailyLogTabState extends State<DailyLogTab> {
  late String _grade = widget.ctx.firstGradeWithStudents;
  String _section = 'All';
  final Map<String, SchoolDayEntry> _changes = {};
  bool _saving = false;

  bool get hasChanges => _changes.isNotEmpty;

  DailyContext get _c => widget.ctx;

  @override
  void didUpdateWidget(covariant DailyLogTab old) {
    super.didUpdateWidget(old);
    if (!_c.gradeOptions.contains(_grade) && _c.gradeOptions.isNotEmpty) _grade = _c.gradeOptions.first;
    if (!SchoolDailyRules.day(old.date).isAtSameMomentAs(SchoolDailyRules.day(widget.date))) _changes.clear();
  }

  /// Asks before throwing away unsaved marks. True = go ahead.
  Future<bool> confirmDiscard() async {
    if (_changes.isEmpty) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unsaved marks'),
        content: Text('${_changes.length} ${_changes.length == 1 ? 'student has' : 'students have'} unsaved marks. Discard them?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep editing')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Discard')),
        ],
      ),
    );
    if (ok == true) setState(_changes.clear);
    return ok == true;
  }

  Future<void> _goTo(DateTime d) async {
    if (await confirmDiscard()) widget.onDateChanged(d);
  }

  SchoolDayEntry _entryFor(SchoolStudent s, Map<String, SchoolDayEntry> saved) =>
      _changes[s.id] ?? saved[s.id] ?? SchoolDayEntry(studentId: s.id, grade: s.grade, section: s.section);

  void _set(SchoolStudent s, SchoolDayEntry e) {
    setState(() => _changes[s.id] = e.copyWith(grade: s.grade, section: s.section));
  }

  void _markAllPresent(List<SchoolStudent> students, Map<String, SchoolDayEntry> saved) {
    setState(() {
      for (final s in students) {
        final e = _entryFor(s, saved);
        if (e.isMarked) continue;
        _changes[s.id] = e.copyWith(
          attendance: SchoolAttendance.present,
          uniform: e.uniform ?? true,
          behaviour: e.behaviour ?? SchoolBehaviour.good,
          grade: s.grade,
          section: s.section,
        );
      }
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final n = await SchoolDailyService.saveDay(
        branchId: _c.branchId,
        date: widget.date,
        changes: Map.of(_changes),
        editorName: _c.editorName,
        isPrincipal: _c.isPrincipal,
      );
      if (!mounted) return;
      setState(_changes.clear);
      AppFeedback.success(context, n == 0 ? 'Nothing changed' : 'Saved $n ${n == 1 ? 'student' : 'students'} for ${dailyDayLabel(widget.date)}');
    } catch (e) {
      if (mounted) AppFeedback.error(context, e is SchoolDailyException ? e.message : 'Could not save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editNote(SchoolStudent s, SchoolDayEntry e) async {
    final ctl = TextEditingController(text: e.behaviourNote);
    final note = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Behaviour note · ${s.name}'),
        content: TextField(controller: ctl, autofocus: true, maxLines: 3, decoration: const InputDecoration(hintText: 'What happened? (shown on the parent report)')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('Done')),
        ],
      ),
    );
    ctl.dispose();
    if (note != null) _set(s, e.copyWith(behaviourNote: note, behaviour: SchoolBehaviour.needsImprovement));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final date = widget.date;
    final saved = SchoolDailyService.day(_c.branchId, date);
    final students = _c.classOn(date, _grade, _section);
    var block = SchoolDailyRules.editBlock(date: date, now: DateTime.now(), cal: _c.calendar, isPrincipal: _c.isPrincipal);
    if (block == null && !_c.canMarkGrade(_grade)) block = SchoolEditBlock.notYourClass;
    final readOnly = block != null;
    final ptm = _c.calendar.ptmFor(date.year, date.month);
    final ptmToday = ptm.date == SchoolDailyRules.ymd(date) && ptm.status != SchoolPtmStatus.cancelled;

    final entries = [for (final s in students) _entryFor(s, saved)];
    int count(bool Function(SchoolDayEntry) f) => entries.where(f).length;
    final present = count((e) => e.attendance == SchoolAttendance.present);
    final absent = count((e) => e.attendance == SchoolAttendance.absent || e.attendance == SchoolAttendance.leaveRequested);
    final leave = count((e) => e.attendance == SchoolAttendance.leave);
    final unmarked = count((e) => !e.isMarked);
    final late = count((e) => e.attendance == SchoolAttendance.present && !SchoolDailyRules.isOnTime(e, _c.calendar.settings));

    final toolbar = Wrap(spacing: Gsp.sp2, runSpacing: Gsp.sp2, crossAxisAlignment: WrapCrossAlignment.center, children: [
      DailyStepper(
        label: dailyDayLabel(date),
        onPrev: () => _goTo(date.subtract(const Duration(days: 1))),
        onNext: SchoolDailyRules.day(date).isBefore(SchoolDailyRules.day(DateTime.now())) ? () => _goTo(date.add(const Duration(days: 1))) : null,
        onTap: () async {
          final picked = await showDatePicker(context: context, initialDate: date, firstDate: DateTime(2020), lastDate: DateTime.now());
          if (picked != null) await _goTo(picked);
        },
      ),
      SizedBox(
        width: 140,
        child: DropdownButtonFormField<String>(
          key: ValueKey('grade-$_grade'),
          initialValue: _grade,
          isExpanded: true,
          decoration: const InputDecoration(isDense: true, labelText: 'Class'),
          items: [for (final g in _c.gradeOptions) DropdownMenuItem(value: g, child: Text(g))],
          onChanged: (v) async {
            if (v == null || v == _grade) return;
            if (await confirmDiscard()) setState(() => _grade = v);
          },
        ),
      ),
      SizedBox(
        width: 120,
        child: DropdownButtonFormField<String>(
          key: ValueKey('section-$_section'),
          initialValue: _section,
          isExpanded: true,
          decoration: const InputDecoration(isDense: true, labelText: 'Section'),
          items: [
            const DropdownMenuItem(value: 'All', child: Text('All')),
            for (final s in SchoolConstants.sections) DropdownMenuItem(value: s, child: Text(s)),
          ],
          onChanged: (v) async {
            if (v == null || v == _section) return;
            if (await confirmDiscard()) setState(() => _section = v);
          },
        ),
      ),
      if (!readOnly && unmarked > 0)
        OutlinedButton.icon(
          onPressed: () => _markAllPresent(students, saved),
          icon: const Icon(GIcons.checkCircle),
          label: Text('Mark $unmarked present'),
        ),
      if (!readOnly)
        FilledButton.icon(
          onPressed: _saving || _changes.isEmpty ? null : _save,
          icon: _saving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(GIcons.save),
          label: Text(_changes.isEmpty ? 'Saved' : 'Save ${_changes.length}'),
        ),
    ]);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (block != null) ...[
        DailyBanner(text: SchoolDailyRules.explainBlock(block, _c.calendar, date), tone: AppChipState.warning, icon: GIcons.lock),
        const SizedBox(height: Gsp.sp3),
      ],
      if (ptmToday) ...[
        const DailyBanner(text: 'PTM is today. Record which parents came in the Calendar tab.', tone: AppChipState.info, icon: GIcons.team),
        const SizedBox(height: Gsp.sp3),
      ],
      SchoolErpStatStrip([
        SchoolErpStat(label: 'Present', value: '$present', color: c.success, icon: GIcons.checkCircle, caption: 'of ${students.length}'),
        SchoolErpStat(label: 'Absent', value: '$absent', color: absent > 0 ? c.danger : c.textMuted, icon: GIcons.cancel, caption: 'incl. leave requested'),
        SchoolErpStat(label: 'Leave', value: '$leave', color: c.info, icon: GIcons.event, caption: 'counts as present'),
        SchoolErpStat(label: 'Late', value: '$late', color: late > 0 ? c.warning : c.textMuted, icon: GIcons.time),
        SchoolErpStat(label: 'Not marked', value: '$unmarked', color: unmarked > 0 ? c.warning : c.success, icon: GIcons.warning,
            caption: unmarked > 0 ? 'Not counted yet' : 'All marked'),
      ]),
      const SizedBox(height: Gsp.sp4),
      Expanded(
        child: SchoolErpCard(
          toolbar: toolbar,
          footer: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3, vertical: Gsp.sp2),
            child: Text(
              'P present · A absent · L approved leave (counts as present) · LR leave requested (counts as absent). '
              'Reply = diary read and signed by a parent. Tick = earned, cross = not earned, grey = not counted that day.',
              style: GText.caption(c.textMuted),
            ),
          ),
          child: students.isEmpty
              ? AppEmptyState(
                  icon: GIcons.student,
                  title: 'No students in class $_grade${_section == 'All' ? '' : '-$_section'}',
                  subtitle: 'Students appear here once admitted to this class.',
                )
              : LayoutBuilder(builder: (context, box) {
                  final grid = Column(children: [
                    const _DayHeader(),
                    Expanded(
                      child: ListView.builder(
                        itemCount: students.length,
                        itemExtent: 52,
                        itemBuilder: (context, i) {
                          final s = students[i];
                          final e = entries[i];
                          return _DayRow(
                            index: i,
                            student: s,
                            entry: e,
                            settings: _c.calendar.settings,
                            dirty: _changes.containsKey(s.id),
                            readOnly: readOnly,
                            onChanged: (n) => _set(s, n),
                            onNote: () => _editNote(s, e),
                          );
                        },
                      ),
                    ),
                  ]);
                  if (box.maxWidth >= _DayRow.minWidth) return grid;
                  return SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(width: _DayRow.minWidth, height: box.maxHeight, child: grid),
                  );
                }),
        ),
      ),
    ]);
  }
}

// ── Marking grid ────────────────────────────────────────────────────────────

const _colRoll = 48.0;
const _colAttendance = 186.0;
const _colToggle = 92.0;

class _DayHeader extends StatelessWidget {
  const _DayHeader();

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    Widget h(String t, {double? w, bool center = false}) {
      final text = Text(t.toUpperCase(), style: GText.overline(c.textMuted), textAlign: center ? TextAlign.center : TextAlign.start);
      return w == null ? Expanded(child: text) : SizedBox(width: w, child: center ? Center(child: text) : text);
    }

    return Container(
      height: SchoolErp.headerHeight,
      color: c.surfaceSunken,
      padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3),
      child: Row(children: [
        h('Roll', w: _colRoll),
        h('Student'),
        h('Attendance', w: _colAttendance),
        for (final r in const ['On time', 'Uniform', 'Behaviour', 'Reply']) h(r, w: _colToggle, center: true),
        h('Note', w: 48, center: true),
      ]),
    );
  }
}

class _DayRow extends StatelessWidget {
  const _DayRow({
    required this.index,
    required this.student,
    required this.entry,
    required this.settings,
    required this.dirty,
    required this.readOnly,
    required this.onChanged,
    required this.onNote,
  });

  static const double minWidth = _colRoll + 220 + _colAttendance + _colToggle * 4 + 48 + Gsp.sp3 * 2;

  final int index;
  final SchoolStudent student;
  final SchoolDayEntry entry;
  final SchoolCalendarSettings settings;
  final bool dirty;
  final bool readOnly;
  final ValueChanged<SchoolDayEntry> onChanged;
  final VoidCallback onNote;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final a = entry.attendance;
    final present = a == SchoolAttendance.present;
    final onTime = SchoolDailyRules.isOnTime(entry, settings);

    Widget attendanceButton(SchoolAttendance v, Color color) {
      final on = a == v;
      return Padding(
        padding: const EdgeInsetsDirectional.only(end: 4),
        child: Tooltip(
          message: v.label,
          child: InkWell(
            borderRadius: Gr.input,
            onTap: readOnly
                ? null
                : () => onChanged(entry.copyWith(
                      attendance: v,
                      uniform: v == SchoolAttendance.present ? (entry.uniform ?? true) : null,
                      behaviour: v == SchoolAttendance.present ? (entry.behaviour ?? SchoolBehaviour.good) : null,
                    )),
            child: Container(
              width: v == SchoolAttendance.leaveRequested ? 40 : 34,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: on ? color : c.surface,
                borderRadius: Gr.input,
                border: Border.all(color: on ? color : c.borderStrong),
              ),
              child: Text(v.short, style: GText.label(on ? GColor.onAccent(color) : c.textSecondary)),
            ),
          ),
        ),
      );
    }

    /// A tick / cross cell. [value] null = not counted that day (grey dash).
    Widget toggle(bool? value, String tip, ValueChanged<bool> set) {
      final enabled = value != null && !readOnly;
      final (IconData icon, Color color) = switch (value) {
        null => (GIcons.close, c.border),
        true => (GIcons.checkCircle, c.success),
        false => (GIcons.cancel, c.danger),
      };
      return SizedBox(
        width: _colToggle,
        child: Center(
          child: Tooltip(
            message: value == null ? '$tip: not counted today' : '$tip: ${value ? 'earned' : 'not earned'} (click to change)',
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: enabled ? () => set(!value) : null,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: value == null
                    ? Text('—', style: GText.label(c.textMuted))
                    : Icon(icon, size: 22, color: color),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: dirty ? c.brandSoft : (index.isOdd ? c.surfaceSunken.withValues(alpha: 0.35) : c.surface),
        border: Border(
          bottom: BorderSide(color: c.border),
          left: BorderSide(color: dirty ? c.brand : Colors.transparent, width: 3),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3),
      child: Row(children: [
        SizedBox(width: _colRoll, child: SchoolErpCell.mono(context, student.rollNo)),
        Expanded(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(student.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: GText.body2Bold(c.textPrimary)),
            Text(
              [
                '${student.grade}-${student.section}',
                if (entry.time.isNotEmpty) 'punched ${entry.time}',
                if (dirty) 'not saved',
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GText.caption(dirty ? c.warning : c.textMuted),
            ),
          ]),
        ),
        SizedBox(
          width: _colAttendance,
          child: Row(children: [
            attendanceButton(SchoolAttendance.present, c.success),
            attendanceButton(SchoolAttendance.absent, c.danger),
            if (settings.allowLeave || a == SchoolAttendance.leave) attendanceButton(SchoolAttendance.leave, c.info),
            if (settings.allowLeave || a == SchoolAttendance.leaveRequested) attendanceButton(SchoolAttendance.leaveRequested, c.warning),
          ]),
        ),
        toggle(present ? onTime : null, 'On time', (v) => onChanged(entry.copyWith(onTime: v))),
        toggle(present ? entry.uniform != false : null, 'Uniform', (v) => onChanged(entry.copyWith(uniform: v))),
        toggle(
          present ? entry.behaviour != SchoolBehaviour.needsImprovement : null,
          'Behaviour',
          (v) => onChanged(entry.copyWith(behaviour: v ? SchoolBehaviour.good : SchoolBehaviour.needsImprovement)),
        ),
        toggle(a == null ? null : entry.parentReplied, 'Diary reply', (v) => onChanged(entry.copyWith(parentReplied: v))),
        SizedBox(
          width: 48,
          child: Center(
            child: present && entry.behaviour == SchoolBehaviour.needsImprovement
                ? IconButton(
                    tooltip: entry.behaviourNote.isEmpty ? 'Add behaviour note' : entry.behaviourNote,
                    onPressed: readOnly ? null : onNote,
                    icon: Icon(GIcons.edit, size: 18, color: entry.behaviourNote.isEmpty ? c.textMuted : c.warning),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ]),
    );
  }
}
