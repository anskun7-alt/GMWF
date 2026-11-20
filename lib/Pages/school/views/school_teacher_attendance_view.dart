// lib/pages/school/views/school_teacher_attendance_view.dart
//
// Staff attendance (ERP layout, 2026-11-17). One day at a time: Present /
// Absent / Leave per teacher, check-in time (biometric punches fill it in),
// and a remark. Only changed teachers are written, each stamped with
// `updatedAt`, so two computers marking different teachers on the same day
// both keep their marks (before, the whole day was overwritten).
// Holidays, weekly days off and future days cannot be marked.

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../../utils/debounced_box_listenable.dart';
import '../core/school_store.dart';
import '../daily/daily_rules.dart';
import '../daily/school_daily_service.dart';
import '../daily/views/daily_common.dart';
import '../models/school_teacher.dart';
import '../utils/school_auth_helper.dart';
import '../utils/school_local_storage.dart';
import '../widgets/erp/school_erp.dart';

class SchoolTeacherAttendanceView extends StatefulWidget {
  final String branchId;
  final String editorName;
  final String userRole;

  const SchoolTeacherAttendanceView({
    super.key,
    required this.branchId,
    this.editorName = 'School Admin',
    this.userRole = 'School Admin',
  });

  @override
  State<SchoolTeacherAttendanceView> createState() => _SchoolTeacherAttendanceViewState();
}

const _statuses = [('present', 'P', 'Present'), ('absent', 'A', 'Absent'), ('leave', 'L', 'Leave')];

class _SchoolTeacherAttendanceViewState extends State<SchoolTeacherAttendanceView> {
  late final Future<void> _ready = SchoolLocalStorage.ensureBoxesOpen();
  DateTime _date = DateTime.now();
  String _department = 'All';
  final Map<String, Map<String, dynamic>> _changes = {};
  bool _saving = false;

  bool get _canEdit => !SchoolAuthHelper.isTeacher(widget.userRole);
  bool get _isPrincipal => SchoolAuthHelper.isAdminOrPrincipal(widget.userRole);
  String get _key => SchoolDailyRules.ymd(_date);

  Future<bool> _confirmDiscard() async {
    if (_changes.isEmpty) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unsaved marks'),
        content: Text('${_changes.length} unsaved ${_changes.length == 1 ? 'mark' : 'marks'}. Discard them?'),
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
    if (await _confirmDiscard()) setState(() => _date = d);
  }

  Map<String, dynamic> _entry(String id, Map<String, dynamic> saved) =>
      _changes[id] ?? (saved[id] is Map ? Map<String, dynamic>.from(saved[id] as Map) : <String, dynamic>{});

  void _mark(String id, Map<String, dynamic> saved, Map<String, dynamic> patch) {
    setState(() => _changes[id] = {..._entry(id, saved), ...patch});
  }

  Future<void> _save(Map<String, dynamic> saved) async {
    setState(() => _saving = true);
    try {
      final stamp = DateTime.now().toIso8601String();
      final merged = {
        ...saved,
        for (final e in _changes.entries) e.key: {...e.value, 'updatedAt': stamp, 'updatedBy': widget.editorName},
      };
      await SchoolLocalStorage.saveTeacherDailyLog(branchId: widget.branchId, dateKey: _key, logEntries: merged, editorName: widget.editorName);
      if (!mounted) return;
      final n = _changes.length;
      setState(_changes.clear);
      AppFeedback.success(context, 'Saved $n staff ${n == 1 ? 'mark' : 'marks'} for ${dailyDayLabel(_date)}');
    } catch (e) {
      if (mounted) AppFeedback.error(context, 'Could not save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _ready,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        final boxes = [SchoolCollection.teacherAttendance.box, SchoolCollection.teachers.box]
            .toSet()
            .where(Hive.isBoxOpen)
            .map((b) => DebouncedBoxListenable.shared(Hive.box(b)))
            .toList();
        return ListenableBuilder(listenable: Listenable.merge(boxes), builder: (context, _) => _build(context));
      },
    );
  }

  Widget _build(BuildContext context) {
    final c = context.comfort;
    final cal = SchoolDailyService.calendar(widget.branchId);
    final teachers = SchoolLocalStorage.getAllTeachersCached(widget.branchId)
        .map((m) => SchoolTeacher.fromMap((m['id'] ?? '').toString(), m))
        .where((t) => t.status.toLowerCase() != 'inactive' && t.status.toLowerCase() != 'revoked')
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final departments = {for (final t in teachers) if (t.department.isNotEmpty) t.department}.toList()..sort();
    final visible = teachers.where((t) => _department == 'All' || t.department == _department).toList();
    final doc = SchoolLocalStorage.getTeacherLogCached(widget.branchId, _key);
    final saved = doc?['entries'] is Map ? Map<String, dynamic>.from(doc!['entries'] as Map) : <String, dynamic>{};

    final block = SchoolDailyRules.editBlock(date: _date, now: DateTime.now(), cal: cal, isPrincipal: _isPrincipal);
    final readOnly = !_canEdit || block != null;
    String statusOf(SchoolTeacher t) => (_entry(t.id, saved)['status'] ?? '').toString().toLowerCase();
    final present = visible.where((t) => statusOf(t) == 'present').length;
    final absent = visible.where((t) => statusOf(t) == 'absent').length;
    final leave = visible.where((t) => statusOf(t) == 'leave').length;
    final unmarked = visible.length - present - absent - leave;

    final toolbar = SchoolErpToolbar(
      filters: [
        DailyStepper(
          label: dailyDayLabel(_date),
          onPrev: () => _goTo(_date.subtract(const Duration(days: 1))),
          onNext: SchoolDailyRules.day(_date).isBefore(SchoolDailyRules.day(DateTime.now())) ? () => _goTo(_date.add(const Duration(days: 1))) : null,
          onTap: () async {
            final p = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2020), lastDate: DateTime.now());
            if (p != null) await _goTo(p);
          },
        ),
        SchoolErpFilter<String>(
          label: 'Department',
          value: _department,
          width: 200,
          options: {'All': 'All departments', for (final d in departments) d: d},
          onChanged: (v) => setState(() => _department = v),
        ),
      ],
      trailing: [
        if (!readOnly && unmarked > 0)
          OutlinedButton.icon(
            onPressed: () => setState(() {
              for (final t in visible) {
                if (statusOf(t).isEmpty) {
                  _changes[t.id] = {..._entry(t.id, saved), 'status': 'present', 'checkIn': DateFormat('hh:mm a').format(DateTime.now())};
                }
              }
            }),
            icon: const Icon(GIcons.checkCircle),
            label: Text('Mark $unmarked present'),
          ),
        if (!readOnly)
          FilledButton.icon(
            onPressed: _saving || _changes.isEmpty ? null : () => _save(saved),
            icon: const Icon(GIcons.save),
            label: Text(_changes.isEmpty ? 'Saved' : 'Save ${_changes.length}'),
          ),
      ],
    );

    final table = SchoolErpTable<SchoolTeacher>(
      rows: visible,
      rowKey: (t) => t.id,
      minWidth: 760,
      rowColor: (t) => _changes.containsKey(t.id) ? c.brandSoft : null,
      empty: const AppEmptyState(icon: GIcons.teacher, title: 'No teachers', subtitle: 'Add teachers in the Teachers page first.'),
      columns: [
        SchoolErpColumn(label: 'Emp. ID', width: 96, sortValue: (t) => t.employeeId, cell: (t) => SchoolErpCell.mono(context, t.employeeId)),
        SchoolErpColumn(label: 'Teacher', flex: 4, sortValue: (t) => t.name.toLowerCase(), cell: (t) => SchoolErpCell.primary(context, t.name, sub: t.designation)),
        SchoolErpColumn(label: 'Department', flex: 3, hideBelow: 900, cell: (t) => SchoolErpCell.text(context, t.department)),
        SchoolErpColumn(
          label: 'Check-in',
          width: 110,
          cell: (t) {
            final e = _entry(t.id, saved);
            final time = (e['time'] ?? e['checkIn'] ?? '').toString();
            return Row(mainAxisSize: MainAxisSize.min, children: [
              if ((e['source'] ?? '').toString().isNotEmpty) ...[Icon(GIcons.fingerprint, size: 14, color: c.textMuted), const SizedBox(width: 4)],
              SchoolErpCell.mono(context, time),
            ]);
          },
        ),
        SchoolErpColumn(
          label: 'Attendance',
          width: 140,
          sortValue: (t) => statusOf(t),
          cell: (t) => Row(mainAxisSize: MainAxisSize.min, children: [
            for (final (value, short, label) in _statuses)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 4),
                child: _StatusButton(
                  short: short,
                  tooltip: label,
                  selected: statusOf(t) == value,
                  color: switch (value) {
                    'present' => c.success,
                    'absent' => c.danger,
                    _ => c.info,
                  },
                  onTap: readOnly
                      ? null
                      : () => _mark(t.id, saved, {
                            'status': value,
                            if (value == 'present' && (_entry(t.id, saved)['checkIn'] ?? _entry(t.id, saved)['time']) == null)
                              'checkIn': DateFormat('hh:mm a').format(DateTime.now()),
                          }),
                ),
              ),
          ]),
        ),
        SchoolErpColumn(
          label: 'Remark',
          flex: 3,
          hideBelow: 1000,
          cell: (t) => SchoolErpCell.text(context, (_entry(t.id, saved)['remarks'] ?? '').toString(), muted: true),
        ),
      ],
    );

    return PopScope(
      canPop: _changes.isEmpty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && context.mounted) Navigator.of(context).maybePop();
      },
      child: SchoolErpPage(
        breadcrumbs: const ['School', 'Staff'],
        title: 'Staff attendance',
        subtitle: 'Daily attendance for teachers and staff',
        icon: GIcons.fingerprint,
        banner: !_canEdit
            ? const DailyBanner(text: 'View only.', tone: AppChipState.info, icon: GIcons.lock)
            : block == null
                ? null
                : DailyBanner(text: SchoolDailyRules.explainBlock(block, cal, _date), tone: AppChipState.warning, icon: GIcons.lock),
        stats: SchoolErpStatStrip([
          SchoolErpStat(label: 'Present', value: '$present', caption: 'of ${visible.length}', color: c.success, icon: GIcons.checkCircle),
          SchoolErpStat(label: 'Absent', value: '$absent', color: absent > 0 ? c.danger : c.textMuted, icon: GIcons.cancel),
          SchoolErpStat(label: 'On leave', value: '$leave', color: c.info, icon: GIcons.event),
          SchoolErpStat(label: 'Not marked', value: '$unmarked', color: unmarked > 0 ? c.warning : c.success, icon: GIcons.warning),
        ]),
        child: SchoolErpCard(toolbar: toolbar, child: table),
      ),
    );
  }
}

class _StatusButton extends StatelessWidget {
  const _StatusButton({required this.short, required this.tooltip, required this.selected, required this.color, this.onTap});
  final String short;
  final String tooltip;
  final bool selected;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: Gr.input,
        onTap: onTap,
        child: Container(
          width: 34,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? color : c.surface,
            borderRadius: Gr.input,
            border: Border.all(color: selected ? color : c.borderStrong),
          ),
          child: Text(short, style: GText.label(selected ? GColor.onAccent(color) : c.textSecondary)),
        ),
      ),
    );
  }
}
