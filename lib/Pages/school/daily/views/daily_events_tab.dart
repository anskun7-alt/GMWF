// lib/pages/school/daily/views/daily_events_tab.dart
//
// Bimonthly compulsory events tab inside Daily log (School ERP plan §1, §3.4,
// Phase 5): Bazm-e-Adab, speech gala, training, field trip.
// Report-only (absences are flagged on parent report cards; no fee effect).

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../constants/school_constants.dart';
import '../../events/event_models.dart';
import '../../events/school_event_service.dart';
import '../../models/school_student.dart';
import '../../widgets/erp/school_erp.dart';
import 'daily_common.dart';

class DailyEventsTab extends StatefulWidget {
  const DailyEventsTab({super.key, required this.ctx});
  final DailyContext ctx;

  @override
  State<DailyEventsTab> createState() => _DailyEventsTabState();
}

class _DailyEventsTabState extends State<DailyEventsTab> {
  final _search = TextEditingController();
  String _typeFilter = 'all';
  String _statusFilter = 'all';
  String? _selectedId;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<SchoolStudent> _eligibleStudents(SchoolEvent ev) {
    final all = widget.ctx.roster.students.where((s) {
      if (!ev.appliesTo(s)) return false;
      if (widget.ctx.isTeacher && !widget.ctx.teacherGrades.contains(s.grade)) return false;
      return true;
    }).toList()
      ..sort((a, b) {
        final g = SchoolConstants.grades.indexOf(a.grade).compareTo(SchoolConstants.grades.indexOf(b.grade));
        if (g != 0) return g;
        final sec = a.section.compareTo(b.section);
        if (sec != 0) return sec;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return all;
  }

  Future<void> _openEventForm([SchoolEvent? existing]) async {
    final titleCtrl = TextEditingController(text: existing?.title ?? '');
    final descCtrl = TextEditingController(text: existing?.description ?? '');
    var type = existing?.type ?? SchoolEventType.bazmEAdab;
    var date = (existing != null ? DateTime.tryParse(existing.date) : null) ?? DateTime.now();
    var allClasses = existing == null || existing.targetGrades.isEmpty;
    final selectedGrades = <String>{...?existing?.targetGrades};
    String? error;
    var saving = false;

    final savedId = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dctx) => StatefulBuilder(builder: (dctx, setS) {
        final c = dctx.comfort;
        return AlertDialog(
          title: Row(children: [
            Icon(GIcons.event, color: c.brand),
            const SizedBox(width: Gsp.sp2),
            Expanded(child: Text(existing == null ? 'Schedule bimonthly event' : 'Edit event', style: GText.h3(c.textPrimary))),
          ]),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (error != null) ...[
                  Container(
                    padding: const EdgeInsets.all(Gsp.sp3),
                    decoration: BoxDecoration(color: c.dangerBg, borderRadius: SchoolErp.radius),
                    child: Text(error!, style: GText.body2(c.danger)),
                  ),
                  const SizedBox(height: Gsp.sp3),
                ],
                DropdownButtonFormField<SchoolEventType>(
                  initialValue: type,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Event type', isDense: true),
                  items: [
                    for (final t in SchoolEventType.values)
                      DropdownMenuItem(value: t, child: Text('${t.label} (${t.urdu})')),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      setS(() {
                        type = v;
                        if (titleCtrl.text.trim().isEmpty) titleCtrl.text = v.label;
                      });
                    }
                  },
                ),
                const SizedBox(height: Gsp.sp3),
                TextField(
                  controller: titleCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Event title *',
                    hintText: 'e.g. Bimonthly Bazm-e-Adab & Speech Gala',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: Gsp.sp3),
                InkWell(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: dctx,
                      initialDate: date,
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (picked != null) setS(() => date = picked);
                  },
                  child: InputDecorator(
                    decoration: const InputDecoration(labelText: 'Date', suffixIcon: Icon(GIcons.calendar, size: 18), isDense: true),
                    child: Text(DateFormat('EEEE, d MMM yyyy').format(date), style: GText.body2(c.textPrimary)),
                  ),
                ),
                const SizedBox(height: Gsp.sp3),
                TextField(
                  controller: descCtrl,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'Notes / venue (optional)', isDense: true),
                ),
                const SizedBox(height: Gsp.sp3),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Whole school (all classes)', style: GText.body2Bold(c.textPrimary)),
                  subtitle: Text('Turn off to select specific classes only', style: GText.caption(c.textMuted)),
                  value: allClasses,
                  onChanged: (v) => setS(() => allClasses = v),
                ),
                if (!allClasses) ...[
                  const SizedBox(height: Gsp.sp1),
                  Wrap(
                    spacing: Gsp.sp1,
                    runSpacing: Gsp.sp1,
                    children: [
                      for (final g in SchoolConstants.grades)
                        FilterChip(
                          label: Text(g),
                          selected: selectedGrades.contains(g),
                          onSelected: (v) => setS(() => v ? selectedGrades.add(g) : selectedGrades.remove(g)),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: Gsp.sp2),
                Text(
                  'Participation is compulsory and absences are flagged on report cards. Events do not affect monthly fees.',
                  style: GText.caption(c.textMuted),
                ),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: saving ? null : () => Navigator.pop(dctx), child: const Text('Cancel')),
            FilledButton.icon(
              onPressed: saving
                  ? null
                  : () async {
                      setS(() {
                        saving = true;
                        error = null;
                      });
                      try {
                        final id = await SchoolEventService.save(
                          branchId: widget.ctx.branchId,
                          existingId: existing?.id,
                          title: titleCtrl.text,
                          type: type,
                          date: date,
                          description: descCtrl.text,
                          targetGrades: allClasses ? const [] : (selectedGrades.toList()..sort((a, b) => SchoolConstants.grades.indexOf(a).compareTo(SchoolConstants.grades.indexOf(b)))),
                          editorName: widget.ctx.editorName,
                          isPrincipal: widget.ctx.isPrincipal,
                        );
                        if (dctx.mounted) Navigator.pop(dctx, id);
                      } catch (e) {
                        setS(() {
                          saving = false;
                          error = e is SchoolEventException ? e.message : '$e';
                        });
                      }
                    },
              icon: const Icon(GIcons.save, size: 16),
              label: Text(existing == null ? 'Schedule' : 'Save changes'),
            ),
          ],
        );
      }),
    );

    titleCtrl.dispose();
    descCtrl.dispose();
    if (savedId != null && mounted) {
      setState(() => _selectedId = savedId);
      AppFeedback.success(context, existing == null ? 'Event scheduled' : 'Event updated');
    }
  }

  Future<void> _openAttendanceDialog(SchoolEvent ev) async {
    final students = _eligibleStudents(ev);
    if (students.isEmpty) {
      AppFeedback.error(context, 'No active students found for this event.');
      return;
    }
    final marks = <String, EventAttendanceStatus>{
      for (final s in students) s.id: ev.attendance[s.id] ?? EventAttendanceStatus.present,
    };
    var classFilter = 'All';
    final classOptions = {for (final s in students) s.grade}.toList()
      ..sort((a, b) => SchoolConstants.grades.indexOf(a).compareTo(SchoolConstants.grades.indexOf(b)));

    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dctx) => StatefulBuilder(builder: (dctx, setS) {
        final c = dctx.comfort;
        final visible = classFilter == 'All' ? students : students.where((s) => s.grade == classFilter).toList();
        final present = marks.values.where((v) => v == EventAttendanceStatus.present).length;
        final absent = marks.values.where((v) => v == EventAttendanceStatus.absent).length;
        final excused = marks.values.where((v) => v == EventAttendanceStatus.excused).length;

        return AlertDialog(
          title: Row(children: [
            Icon(GIcons.checklist, color: c.brand),
            const SizedBox(width: Gsp.sp2),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Event attendance · ${ev.title}', style: GText.h3(c.textPrimary)),
                Text('${dailyShortDate(ev.date)} · ${ev.type.label}', style: GText.caption(c.textMuted)),
              ]),
            ),
          ]),
          content: SizedBox(
            width: 600,
            height: 480,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: classFilter,
                    isExpanded: true,
                    decoration: const InputDecoration(isDense: true, labelText: 'Class'),
                    items: [
                      const DropdownMenuItem(value: 'All', child: Text('All classes')),
                      for (final g in classOptions) DropdownMenuItem(value: g, child: Text('Class $g')),
                    ],
                    onChanged: (v) => setS(() => classFilter = v ?? 'All'),
                  ),
                ),
                const SizedBox(width: Gsp.sp2),
                TextButton(
                  onPressed: () => setS(() {
                    for (final s in visible) {
                      marks[s.id] = EventAttendanceStatus.present;
                    }
                  }),
                  child: const Text('Mark all present'),
                ),
              ]),
              const SizedBox(height: Gsp.sp2),
              Text('$present present · $absent absent · $excused excused (of ${students.length})', style: GText.caption(c.textMuted)),
              const SizedBox(height: Gsp.sp2),
              Expanded(
                child: ListView.separated(
                  itemCount: visible.length,
                  separatorBuilder: (_, _) => Divider(height: 1, color: c.border),
                  itemBuilder: (_, i) {
                    final s = visible[i];
                    final cur = marks[s.id] ?? EventAttendanceStatus.present;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: Gsp.sp1 + 2),
                      child: Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(s.name, style: GText.body2Bold(c.textPrimary)),
                            Text('${s.grade}-${s.section} · Roll ${s.rollNo} · ${s.guardianName}', style: GText.caption(c.textMuted)),
                          ]),
                        ),
                        SegmentedButton<EventAttendanceStatus>(
                          showSelectedIcon: false,
                          style: const ButtonStyle(visualDensity: VisualDensity.compact),
                          segments: const [
                            ButtonSegment(value: EventAttendanceStatus.present, label: Text('Present')),
                            ButtonSegment(value: EventAttendanceStatus.absent, label: Text('Absent')),
                            ButtonSegment(value: EventAttendanceStatus.excused, label: Text('Excused')),
                          ],
                          selected: {cur},
                          onSelectionChanged: (set) => setS(() => marks[s.id] = set.first),
                        ),
                      ]),
                    );
                  },
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('Cancel')),
            FilledButton.icon(
              onPressed: () => Navigator.pop(dctx, true),
              icon: const Icon(GIcons.save, size: 16),
              label: const Text('Save attendance'),
            ),
          ],
        );
      }),
    );

    if (saved != true || !mounted) return;
    try {
      await SchoolEventService.saveAttendance(
        branchId: widget.ctx.branchId,
        eventId: ev.id,
        marks: marks,
        editorName: widget.ctx.editorName,
      );
      if (mounted) AppFeedback.success(context, 'Event attendance saved');
    } catch (e) {
      if (mounted) AppFeedback.error(context, e is SchoolEventException ? e.message : '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final all = SchoolEventService.all(widget.ctx.branchId);
    final q = _search.text.trim().toLowerCase();
    final rows = all.where((e) {
      if (_typeFilter != 'all' && e.type.value != _typeFilter) return false;
      if (_statusFilter != 'all' && e.status.value != _statusFilter) return false;
      if (q.isEmpty) return true;
      return e.title.toLowerCase().contains(q) || e.type.label.toLowerCase().contains(q) || e.description.toLowerCase().contains(q);
    }).toList();

    final held = all.where((e) => e.status == SchoolEventStatus.held).length;
    final scheduled = all.where((e) => e.status == SchoolEventStatus.scheduled).length;
    final totalAbsences = all
        .where((e) => e.status == SchoolEventStatus.held)
        .fold<int>(0, (acc, e) => acc + e.absentCount);

    SchoolEvent? selected;
    for (final e in all) {
      if (e.id == _selectedId) selected = e;
    }

    final table = SchoolErpTable<SchoolEvent>(
      rows: rows,
      rowKey: (e) => e.id,
      selectedKey: _selectedId,
      onRowTap: (e) {
        if (SchoolErp.wide(context)) {
          setState(() => _selectedId = e.id);
        } else {
          showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            useSafeArea: true,
            builder: (_) => SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.85,
              child: _EventDetailPanel(
                ev: e,
                ctx: widget.ctx,
                eligible: _eligibleStudents(e),
                onEdit: () => _openEventForm(e),
                onAttendance: () => _openAttendanceDialog(e),
                onToggleCancel: () => _toggleCancel(e),
              ),
            ),
          );
        }
      },
      minWidth: 740,
      empty: AppEmptyState(
        icon: GIcons.event,
        title: all.isEmpty ? 'No bimonthly events yet' : 'No events match',
        subtitle: all.isEmpty
            ? 'Schedule Bazm-e-Adab, speech galas, trainings or field trips. Absences are flagged on report cards (no fee effect).'
            : 'Try another filter or search.',
        action: all.isEmpty && widget.ctx.isPrincipal
            ? FilledButton.icon(onPressed: () => _openEventForm(), icon: const Icon(GIcons.add), label: const Text('Schedule event'))
            : null,
      ),
      columns: [
        SchoolErpColumn(
          label: 'Date',
          width: 112,
          sortValue: (e) => e.date,
          cell: (e) => SchoolErpCell.mono(context, dailyShortDate(e.date)),
        ),
        SchoolErpColumn(
          label: 'Event',
          flex: 5,
          sortValue: (e) => e.title.toLowerCase(),
          cell: (e) => SchoolErpCell.primary(context, e.title, sub: '${e.type.label} · ${e.targetGrades.isEmpty ? 'All classes' : 'Classes ${e.targetGrades.join(', ')}'}'),
        ),
        SchoolErpColumn(
          label: 'Present',
          width: 82,
          numeric: true,
          sortValue: (e) => e.presentCount,
          cell: (e) => SchoolErpCell.mono(context, e.attendance.isEmpty ? '—' : '${e.presentCount}', color: c.success),
        ),
        SchoolErpColumn(
          label: 'Absent',
          width: 82,
          numeric: true,
          sortValue: (e) => e.absentCount,
          cell: (e) => SchoolErpCell.mono(
            context,
            e.attendance.isEmpty ? '—' : '${e.absentCount}',
            color: e.absentCount > 0 ? c.danger : c.textMuted,
          ),
        ),
        SchoolErpColumn(
          label: 'Status',
          width: 120,
          sortValue: (e) => e.status.index,
          cell: (e) => _EventStatusChip(e.status),
        ),
      ],
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SchoolErpStatStrip([
        SchoolErpStat(label: 'Total events', value: GFormat.count(all.length), icon: GIcons.event, caption: 'Report-only · no fee effect'),
        SchoolErpStat(label: 'Held', value: GFormat.count(held), color: c.success, icon: GIcons.checkCircle),
        SchoolErpStat(label: 'Scheduled', value: GFormat.count(scheduled), color: c.info, icon: GIcons.calendar),
        SchoolErpStat(
          label: 'Flagged absences',
          value: GFormat.count(totalAbsences),
          color: totalAbsences > 0 ? c.danger : c.success,
          icon: GIcons.warning,
          caption: 'Shown on report cards',
        ),
      ]),
      const SizedBox(height: Gsp.sp3),
      Expanded(
        child: SchoolErpMasterDetail(
          master: SchoolErpCard(
            toolbar: SchoolErpToolbar(
              search: _search,
              searchHint: 'Search events…',
              onSearch: (_) => setState(() {}),
              filters: [
                SchoolErpFilter<String>(
                  label: 'Type',
                  value: _typeFilter,
                  width: 165,
                  options: {'all': 'All types', for (final t in SchoolEventType.values) t.value: t.label},
                  onChanged: (v) => setState(() => _typeFilter = v),
                ),
                SchoolErpFilter<String>(
                  label: 'Status',
                  value: _statusFilter,
                  width: 135,
                  options: {'all': 'All', for (final s in SchoolEventStatus.values) s.value: s.label},
                  onChanged: (v) => setState(() => _statusFilter = v),
                ),
              ],
              trailing: [
                if (widget.ctx.isPrincipal)
                  FilledButton.icon(
                    onPressed: () => _openEventForm(),
                    icon: const Icon(GIcons.add, size: 16),
                    label: const Text('Schedule event'),
                  ),
              ],
            ),
            child: table,
          ),
          detail: selected == null
              ? null
              : _EventDetailPanel(
                  ev: selected,
                  ctx: widget.ctx,
                  eligible: _eligibleStudents(selected),
                  onEdit: () => _openEventForm(selected!),
                  onAttendance: () => _openAttendanceDialog(selected!),
                  onToggleCancel: () => _toggleCancel(selected!),
                  onClose: () => setState(() => _selectedId = null),
                ),
        ),
      ),
    ]);
  }

  Future<void> _toggleCancel(SchoolEvent ev) async {
    final next = ev.status == SchoolEventStatus.cancelled ? SchoolEventStatus.scheduled : SchoolEventStatus.cancelled;
    try {
      await SchoolEventService.setStatus(
        branchId: widget.ctx.branchId,
        eventId: ev.id,
        status: next,
        editorName: widget.ctx.editorName,
        isPrincipal: widget.ctx.isPrincipal,
      );
      if (mounted) AppFeedback.success(context, next == SchoolEventStatus.cancelled ? 'Event cancelled' : 'Event restored');
    } catch (e) {
      if (mounted) AppFeedback.error(context, e is SchoolEventException ? e.message : '$e');
    }
  }
}

class _EventStatusChip extends StatelessWidget {
  const _EventStatusChip(this.status);
  final SchoolEventStatus status;

  @override
  Widget build(BuildContext context) => AppChip(
        label: status.label,
        state: switch (status) {
          SchoolEventStatus.held => AppChipState.active,
          SchoolEventStatus.scheduled => AppChipState.info,
          SchoolEventStatus.cancelled => AppChipState.warning,
        },
      );
}

class _EventDetailPanel extends StatelessWidget {
  const _EventDetailPanel({
    required this.ev,
    required this.ctx,
    required this.eligible,
    required this.onEdit,
    required this.onAttendance,
    required this.onToggleCancel,
    this.onClose,
  });

  final SchoolEvent ev;
  final DailyContext ctx;
  final List<SchoolStudent> eligible;
  final VoidCallback onEdit;
  final VoidCallback onAttendance;
  final VoidCallback onToggleCancel;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final absentStudents = eligible.where((s) => ev.attendance[s.id] == EventAttendanceStatus.absent).toList();
    return SchoolErpDetailPanel(
      onClose: onClose,
      leading: const GModuleTile(icon: GIcons.event, size: 42),
      title: ev.title,
      subtitle: '${ev.type.label} · ${dailyShortDate(ev.date)}',
      chips: [
        _EventStatusChip(ev.status),
        AppChip(label: ev.academicYear.isEmpty ? 'Session' : ev.academicYear, state: AppChipState.neutral, icon: GIcons.calendar),
      ],
      actions: [
        if (ev.status != SchoolEventStatus.cancelled)
          FilledButton.icon(onPressed: onAttendance, icon: const Icon(GIcons.checklist, size: 16), label: const Text('Mark attendance')),
        if (ctx.isPrincipal)
          OutlinedButton.icon(onPressed: onEdit, icon: const Icon(GIcons.edit, size: 16), label: const Text('Edit')),
        if (ctx.isPrincipal)
          OutlinedButton.icon(
            onPressed: onToggleCancel,
            icon: Icon(ev.status == SchoolEventStatus.cancelled ? GIcons.refresh : GIcons.cancel, size: 16),
            label: Text(ev.status == SchoolEventStatus.cancelled ? 'Reopen' : 'Cancel'),
          ),
      ],
      children: [
        SchoolErpFacts(title: 'Details', facts: [
          ('Type', '${ev.type.label} (${ev.type.urdu})'),
          ('Date', dailyShortDate(ev.date)),
          ('Classes', ev.targetGrades.isEmpty ? 'Whole school' : ev.targetGrades.join(', ')),
          ('Attendance', ev.attendance.isEmpty ? 'Not marked yet' : '${ev.presentCount} present · ${ev.absentCount} absent · ${ev.excusedCount} excused'),
          if (ev.description.isNotEmpty) ('Notes', ev.description),
          ('Fee impact', 'None (report card only)'),
        ]),
        Padding(
          padding: const EdgeInsets.only(top: Gsp.sp4, bottom: Gsp.sp2),
          child: Text('ABSENT STUDENTS (${absentStudents.length})', style: GText.overline(c.textMuted)),
        ),
        if (ev.attendance.isEmpty)
          Text('Mark attendance after the event to track compulsory participation.', style: GText.body2(c.textMuted))
        else if (absentStudents.isEmpty)
          Text('No unexcused absences recorded.', style: GText.body2(c.success))
        else
          for (final s in absentStudents)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(GIcons.warning, size: 18, color: c.danger),
              title: Text(s.name, style: GText.body2Bold(c.textPrimary)),
              subtitle: Text('${s.grade}-${s.section} · ${s.admissionNo} · Father: ${s.guardianName}', style: GText.caption(c.textMuted)),
              trailing: const AppChip(label: 'Flagged', state: AppChipState.danger),
            ),
      ],
    );
  }
}
