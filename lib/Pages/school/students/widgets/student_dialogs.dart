// lib/pages/school/students/widgets/student_dialogs.dart
//
// Student dialogs (School ERP Phase 2): possible-duplicate warning and the
// dated status change. Built on gmwf_ui in the School (Scholar Indigo) theme.

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../models/school_student.dart';
import '../school_student_service.dart';
import '../student_rules.dart';

class _StudentDialog extends StatelessWidget {
  const _StudentDialog({
    required this.icon,
    required this.title,
    required this.child,
    required this.actions,
    this.subtitle,
    this.error,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget child;
  final List<Widget> actions;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    return Dialog(
      insetPadding: const EdgeInsets.all(Gsp.sp4),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 500, maxHeight: MediaQuery.sizeOf(context).height * 0.9),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gsp.sp5, Gsp.sp5, Gsp.sp3, Gsp.sp3),
            child: Row(children: [
              GModuleTile(icon: icon, size: 38),
              const SizedBox(width: Gsp.sp3),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: GText.h3(c.textPrimary)),
                  if (subtitle != null) Text(subtitle!, style: GText.body2(c.textSecondary)),
                ]),
              ),
              IconButton(tooltip: 'Close', icon: const Icon(GIcons.close), onPressed: () => Navigator.of(context).pop()),
            ]),
          ),
          const Divider(height: 1),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(Gsp.sp5),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (error != null) ...[
                  Container(
                    padding: const EdgeInsets.all(Gsp.sp3),
                    decoration: BoxDecoration(color: c.dangerBg, borderRadius: Gr.input),
                    child: Row(children: [
                      Icon(GIcons.error, size: GIconSize.sm, color: c.danger),
                      const SizedBox(width: Gsp.sp2),
                      Expanded(child: Text(error!, style: GText.body2(c.danger))),
                    ]),
                  ),
                  const SizedBox(height: Gsp.sp4),
                ],
                child,
              ]),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(Gsp.sp4),
            child: Wrap(alignment: WrapAlignment.end, spacing: Gsp.sp2, runSpacing: Gsp.sp2, children: actions),
          ),
        ]),
      ),
    );
  }
}

/// Shows students that look like the one being saved.
/// True = the user confirmed it is a different child.
Future<bool?> showStudentDuplicateDialog(BuildContext context, List<StudentMatch> matches) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) {
      final c = ctx.comfort;
      return _StudentDialog(
        icon: GIcons.warning,
        title: 'Already registered?',
        subtitle: 'Check these records before saving a second admission',
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Different child — save')),
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final m in matches.take(5))
            Container(
              margin: const EdgeInsets.only(bottom: Gsp.sp2),
              padding: const EdgeInsets.all(Gsp.sp3),
              decoration: BoxDecoration(color: c.surfaceSunken, borderRadius: Gr.card, border: Border.all(color: c.border)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${m.student.name}  ·  ${m.student.admissionNo}', style: GText.label(c.textPrimary)),
                const SizedBox(height: 2),
                Text(
                  'Father: ${m.student.guardianName} · Class ${m.student.grade}-${m.student.section} · '
                  '${StudentStatus.parse(m.student.status).label}',
                  style: GText.caption(c.textSecondary),
                ),
                const SizedBox(height: 2),
                Text(m.reason, style: GText.caption(c.warning)),
              ]),
            ),
          const SizedBox(height: Gsp.sp2),
          Text(
            "Brothers and sisters share the father's CNIC, and that is fine. A child should be admitted only once: "
            'if one of these is the same child, cancel and edit or rejoin that record instead.',
            style: GText.caption(c.textMuted),
          ),
        ]),
      );
    },
  );
}

/// Dated status change (suspend, left, graduated, rejoin, entered by mistake…).
/// Returns true when saved.
Future<bool> showStudentStatusDialog(
  BuildContext context, {
  required String branchId,
  required SchoolStudent student,
  required String editorName,
  required bool isPrincipal,
}) async {
  final from = StudentStatus.parse(student.status);
  final options = StudentRules.nextStatuses(from, isPrincipal: isPrincipal);
  if (options.isEmpty) return false;
  var to = options.first;
  var date = DateTime.now();
  final reason = TextEditingController();
  String? error;
  var saving = false;

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      final c = ctx.comfort;
      final danger = to == StudentStatus.voided || to == StudentStatus.left;
      return _StudentDialog(
        icon: GIcons.history,
        title: 'Change status',
        subtitle: '${student.name} · now ${from.label.toLowerCase()}',
        error: error,
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: danger ? FilledButton.styleFrom(backgroundColor: c.danger, foregroundColor: GColor.onAccent(c.danger)) : null,
            onPressed: saving
                ? null
                : () async {
                    setS(() => saving = true);
                    try {
                      await SchoolStudentService.changeStatus(
                        branchId: branchId,
                        studentId: student.id,
                        to: to,
                        effectiveDate: date,
                        reason: reason.text,
                        editorName: editorName,
                        isPrincipal: isPrincipal,
                      );
                      if (ctx.mounted) Navigator.pop(ctx, true);
                    } catch (e) {
                      setS(() {
                        saving = false;
                        error = e is StudentException ? e.message : 'Could not save: $e';
                      });
                    }
                  },
            child: Text(to.actionFrom(from)),
          ),
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('New status', style: GText.label(c.textSecondary)),
          const SizedBox(height: Gsp.sp1),
          Wrap(spacing: Gsp.sp2, runSpacing: Gsp.sp2, children: [
            for (final o in options)
              ChoiceChip(label: Text(o.actionFrom(from)), selected: to == o, onSelected: (_) => setS(() => to = o)),
          ]),
          const SizedBox(height: Gsp.sp3),
          Text(_explain(to), style: GText.body2(c.textSecondary)),
          const SizedBox(height: Gsp.sp4),
          InkWell(
            borderRadius: Gr.input,
            onTap: () async {
              final picked = await showDatePicker(
                context: ctx,
                initialDate: date,
                firstDate: DateTime(2015),
                lastDate: DateTime.now().add(const Duration(days: 31)),
              );
              if (picked != null) setS(() => date = picked);
            },
            child: InputDecorator(
              decoration: const InputDecoration(labelText: 'Effective from', suffixIcon: Icon(GIcons.calendar)),
              child: Text(DateFormat('d MMM yyyy').format(date), style: GText.body1(c.textPrimary)),
            ),
          ),
          const SizedBox(height: Gsp.sp3),
          TextField(
            controller: reason,
            maxLines: 2,
            decoration: InputDecoration(
              labelText: to.needsReason ? 'Reason *' : 'Note (optional)',
              hintText: switch (to) {
                StudentStatus.suspended => 'e.g. Discipline — 3 days',
                StudentStatus.left => 'e.g. Family moved to Lahore; SLC issued',
                StudentStatus.graduated => 'e.g. Passed 10th',
                StudentStatus.voided => 'e.g. Saved twice by mistake',
                StudentStatus.active => 'e.g. Fee cleared, rejoined',
              },
            ),
          ),
        ]),
      );
    }),
  );
  reason.dispose();
  return ok == true;
}

String _explain(StudentStatus to) => switch (to) {
      StudentStatus.active => 'The student is back on attendance, fees and class lists from this date.',
      StudentStatus.suspended => 'The student stays enrolled but is off attendance and the fee sheet while suspended.',
      StudentStatus.left => 'The student is taken off class lists from this date. The record and history are kept and they can rejoin.',
      StudentStatus.graduated => 'The student finished school. The record is kept for certificates and reports.',
      StudentStatus.voided =>
        'Use this only for a record saved by mistake (for example twice). It is hidden everywhere but kept in the audit log, and a Principal can restore it.',
    };
