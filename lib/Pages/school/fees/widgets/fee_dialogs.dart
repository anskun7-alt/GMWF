// lib/pages/school/fees/widgets/fee_dialogs.dart
//
// Fee dialogs (Phase 4): take payment, reverse payment, close month,
// adjustment, concession, fee settings. gmwf_ui, School indigo.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gmwf_ui/gmwf_ui.dart';

import '../../daily/daily_models.dart';
import '../../daily/daily_rules.dart';
import '../../models/school_student.dart';
import '../fee_models.dart';
import '../fee_pdf_service.dart';
import '../fee_rules.dart';
import '../school_fee_service.dart';

String _msg(Object e) => e is SchoolFeeException ? e.message : 'Something went wrong: $e';

class _FeeDialog extends StatelessWidget {
  const _FeeDialog({required this.icon, required this.title, required this.child, required this.actions, this.subtitle, this.error, this.width = 480});
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget child;
  final List<Widget> actions;
  final String? error;
  final double width;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    return Dialog(
      insetPadding: const EdgeInsets.all(Gsp.sp4),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width, maxHeight: MediaQuery.sizeOf(context).height * 0.9),
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
                    child: Text(error!, style: GText.body2(c.danger)),
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

// ── Take payment ────────────────────────────────────────────────────────────

/// Returns the saved payment (so the caller can print the receipt), or null.
Future<SchoolFeePayment?> showTakePaymentDialog(
  BuildContext context, {
  required String branchId,
  required SchoolStudent student,
  required SchoolFeeAccount account,
  required String editorName,
  required String branchName,
}) async {
  final amount = TextEditingController(text: account.balance > 0 ? '${account.balance}' : '');
  final note = TextEditingController();
  var method = SchoolPaymentMethod.cash;
  var date = DateTime.now();
  var printIt = true;
  String? error;
  var saving = false;
  final result = await showDialog<SchoolFeePayment>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      final c = ctx.comfort;
      final typed = int.tryParse(amount.text.trim()) ?? 0;
      final after = account.balance - typed;
      return _FeeDialog(
        icon: GIcons.money,
        title: 'Take payment',
        subtitle: '${student.name} · ${student.admissionNo} · Class ${student.grade}-${student.section}',
        error: error,
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton.icon(
            icon: const Icon(GIcons.save),
            label: Text(printIt ? 'Save & print receipt' : 'Save'),
            onPressed: saving
                ? null
                : () async {
                    setS(() => saving = true);
                    try {
                      final p = await SchoolFeeService.takePayment(
                        branchId: branchId,
                        studentId: student.id,
                        amount: int.tryParse(amount.text.trim()) ?? 0,
                        method: method,
                        date: date,
                        note: note.text,
                        editorName: editorName,
                      );
                      if (printIt) {
                        final acc = SchoolFeeService.snapshot(branchId, date.year, date.month).accounts[student.id] ?? account;
                        try {
                          await SchoolFeePdf.printBytes('Receipt-${p.receiptNo}',
                              await SchoolFeePdf.receipt(student: student, payment: p, account: acc, branchName: branchName));
                        } catch (_) {}
                      }
                      if (ctx.mounted) Navigator.pop(ctx, p);
                    } catch (e) {
                      setS(() {
                        saving = false;
                        error = _msg(e);
                      });
                    }
                  },
          ),
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            padding: const EdgeInsets.all(Gsp.sp3),
            decoration: BoxDecoration(color: c.surfaceSunken, borderRadius: Gr.input),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _line(c, 'Owed now', account.balance > 0 ? SchoolFeePdf.rs(account.balance) : 'Nothing'),
              if (account.arrears > 0) _line(c, 'of which earlier months', SchoolFeePdf.rs(account.arrears)),
              if (account.credit > 0) _line(c, 'Advance already held', SchoolFeePdf.rs(account.credit)),
            ]),
          ),
          const SizedBox(height: Gsp.sp4),
          TextField(
            controller: amount,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (_) => setS(() {}),
            decoration: InputDecoration(
              labelText: 'Amount received (Rs) *',
              helperText: typed <= 0
                  ? null
                  : after > 0
                      ? 'Still owed after this: ${SchoolFeePdf.rs(after)}'
                      : after < 0
                          ? 'Rs ${-after} more than owed: kept as advance for next month'
                          : 'Clears the balance',
            ),
          ),
          const SizedBox(height: Gsp.sp3),
          Text('Method', style: GText.label(c.textSecondary)),
          const SizedBox(height: Gsp.sp1),
          Wrap(spacing: Gsp.sp2, runSpacing: Gsp.sp2, children: [
            for (final m in SchoolPaymentMethod.values)
              ChoiceChip(label: Text(m.label), selected: method == m, onSelected: (_) => setS(() => method = m)),
          ]),
          const SizedBox(height: Gsp.sp3),
          TextField(
            controller: note,
            decoration: InputDecoration(labelText: method == SchoolPaymentMethod.cash ? 'Note (optional)' : '${method.label} reference *'),
          ),
          const SizedBox(height: Gsp.sp3),
          InkWell(
            onTap: () async {
              final p = await showDatePicker(context: ctx, initialDate: date, firstDate: DateTime(2024), lastDate: DateTime.now());
              if (p != null) setS(() => date = p);
            },
            child: InputDecorator(
              decoration: const InputDecoration(labelText: 'Received on', suffixIcon: Icon(GIcons.calendar)),
              child: Text(SchoolDailyRules.ymd(date)),
            ),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: printIt,
            onChanged: (v) => setS(() => printIt = v ?? true),
            title: const Text('Print receipt'),
          ),
        ]),
      );
    }),
  );
  amount.dispose();
  note.dispose();
  return result;
}

Widget _line(GComfortColors c, String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [Expanded(child: Text(k, style: GText.body2(c.textSecondary))), Text(v, style: GText.body2Bold(c.textPrimary))]),
    );

// ── Reverse payment ─────────────────────────────────────────────────────────

Future<bool> showReversePaymentDialog(BuildContext context, {required String branchId, required SchoolFeePayment payment, required String editorName}) async {
  final reason = TextEditingController();
  String? error;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      final c = ctx.comfort;
      return _FeeDialog(
        icon: GIcons.refresh,
        title: 'Reverse payment',
        subtitle: '${payment.receiptNo} · ${SchoolFeePdf.rs(payment.amount)}',
        error: error,
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: c.danger, foregroundColor: GColor.onAccent(c.danger)),
            onPressed: () async {
              try {
                await SchoolFeeService.reversePayment(branchId: branchId, paymentId: payment.id, reason: reason.text, editorName: editorName, isPrincipal: true);
                if (ctx.mounted) Navigator.pop(ctx, true);
              } catch (e) {
                setS(() => error = _msg(e));
              }
            },
            child: const Text('Reverse'),
          ),
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
            'Payments are never edited or deleted. Reversing adds a minus entry with your reason, '
            'so the receipt book still adds up.',
            style: GText.body2(c.textSecondary),
          ),
          const SizedBox(height: Gsp.sp3),
          TextField(controller: reason, autofocus: true, maxLines: 2, decoration: const InputDecoration(labelText: 'Reason *', hintText: 'e.g. Entered for the wrong student')),
        ]),
      );
    }),
  );
  reason.dispose();
  return ok == true;
}

// ── Close month ─────────────────────────────────────────────────────────────

Future<bool> showCloseMonthDialog(
  BuildContext context, {
  required String branchId,
  required SchoolFeeSnapshot snap,
  required List<String> blockers,
  required String editorName,
}) async {
  String? error;
  var saving = false;
  final totalDue = snap.sheets.values.fold<int>(0, (a, s) => a + s.due);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      final c = ctx.comfort;
      return _FeeDialog(
        icon: GIcons.lock,
        title: 'Close ${SchoolFeeRules.monthName(snap.ym)}',
        subtitle: '${snap.students.length} students · ${SchoolFeePdf.rs(totalDue)} due in total',
        error: error,
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          if (blockers.isEmpty)
            FilledButton.icon(
              icon: const Icon(GIcons.lock),
              label: const Text('Close month'),
              onPressed: saving
                  ? null
                  : () async {
                      setS(() => saving = true);
                      try {
                        await SchoolFeeService.closeMonth(branchId: branchId, year: snap.year, month: snap.month, editorName: editorName);
                        if (ctx.mounted) Navigator.pop(ctx, true);
                      } catch (e) {
                        setS(() {
                          saving = false;
                          error = _msg(e);
                        });
                      }
                    },
            ),
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (blockers.isNotEmpty) ...[
            Text('The month cannot be closed yet:', style: GText.body2Bold(c.textPrimary)),
            const SizedBox(height: Gsp.sp2),
            for (final b in blockers)
              Padding(
                padding: const EdgeInsets.only(bottom: Gsp.sp2),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(GIcons.warning, size: 16, color: c.warning),
                  const SizedBox(width: Gsp.sp2),
                  Expanded(child: Text(b, style: GText.body2(c.textSecondary))),
                ]),
              ),
          ] else
            Text(
              'Closing freezes every student\'s fee sheet for the month. After this the month\'s daily log, holidays, PTM '
              'and fee settings cannot change. Corrections are made as adjustments, which keep a record of who changed what.',
              style: GText.body2(c.textSecondary),
            ),
        ]),
      );
    }),
  );
  return ok == true;
}

// ── Adjustment ──────────────────────────────────────────────────────────────

Future<bool> showAdjustmentDialog(
  BuildContext context, {
  required String branchId,
  required SchoolStudent student,
  required String month,
  required String editorName,
}) async {
  final amount = TextEditingController();
  final reason = TextEditingController();
  var reduce = true;
  String? error;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      final c = ctx.comfort;
      return _FeeDialog(
        icon: GIcons.edit,
        title: 'Adjust ${SchoolFeeRules.monthName(month)}',
        subtitle: student.name,
        error: error,
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              try {
                final v = int.tryParse(amount.text.trim()) ?? 0;
                await SchoolFeeService.addAdjustment(
                  branchId: branchId,
                  studentId: student.id,
                  month: month,
                  amount: reduce ? -v : v,
                  reason: reason.text,
                  editorName: editorName,
                  isPrincipal: true,
                );
                if (ctx.mounted) Navigator.pop(ctx, true);
              } catch (e) {
                setS(() => error = _msg(e));
              }
            },
            child: const Text('Save adjustment'),
          ),
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('The closed sheet stays as it was; this adds a correction line with your reason.', style: GText.body2(c.textSecondary)),
          const SizedBox(height: Gsp.sp3),
          SegmentedButton<bool>(
            segments: const [ButtonSegment(value: true, label: Text('Reduce fee')), ButtonSegment(value: false, label: Text('Add charge'))],
            selected: {reduce},
            onSelectionChanged: (s) => setS(() => reduce = s.first),
          ),
          const SizedBox(height: Gsp.sp3),
          TextField(
            controller: amount,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: 'Amount (Rs) *'),
          ),
          const SizedBox(height: Gsp.sp3),
          TextField(controller: reason, maxLines: 2, decoration: const InputDecoration(labelText: 'Reason *', hintText: 'e.g. Attendance corrected after close')),
        ]),
      );
    }),
  );
  amount.dispose();
  reason.dispose();
  return ok == true;
}

// ── Concession ──────────────────────────────────────────────────────────────

Future<bool> showConcessionDialog(
  BuildContext context, {
  required String branchId,
  required SchoolStudent student,
  required String fromMonth,
  required String editorName,
  SchoolFeeAdjustment? existing,
}) async {
  final amount = TextEditingController(text: existing == null ? '' : '${existing.amount}');
  final reason = TextEditingController(text: existing?.reason ?? '');
  var percent = existing?.percent ?? true;
  var until = existing?.untilMonth ?? '';
  String? error;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      final c = ctx.comfort;
      return _FeeDialog(
        icon: GIcons.donation,
        title: existing == null ? 'Give concession' : 'Change concession',
        subtitle: student.name,
        error: error,
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              try {
                await SchoolFeeService.saveConcession(
                  branchId: branchId,
                  studentId: student.id,
                  fromMonth: existing?.month ?? fromMonth,
                  amount: int.tryParse(amount.text.trim()) ?? 0,
                  percent: percent,
                  untilMonth: until,
                  reason: reason.text,
                  editorName: editorName,
                  isPrincipal: true,
                  id: existing?.id,
                );
                if (ctx.mounted) Navigator.pop(ctx, true);
              } catch (e) {
                setS(() => error = _msg(e));
              }
            },
            child: const Text('Save'),
          ),
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
            'A welfare concession comes off what the parent owes after the six credits, from '
            '${SchoolFeeRules.monthName(existing?.month ?? fromMonth)}. It shows as its own line on the fee slip.',
            style: GText.body2(c.textSecondary),
          ),
          const SizedBox(height: Gsp.sp3),
          SegmentedButton<bool>(
            segments: const [ButtonSegment(value: true, label: Text('Percent')), ButtonSegment(value: false, label: Text('Fixed rupees'))],
            selected: {percent},
            onSelectionChanged: (s) => setS(() => percent = s.first),
          ),
          const SizedBox(height: Gsp.sp3),
          TextField(
            controller: amount,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(labelText: percent ? 'Percent off *' : 'Rupees off per month *', suffixText: percent ? '%' : 'Rs'),
          ),
          const SizedBox(height: Gsp.sp3),
          TextField(controller: reason, decoration: const InputDecoration(labelText: 'Reason *', hintText: 'e.g. Orphan, welfare committee decision')),
          const SizedBox(height: Gsp.sp3),
          DropdownButtonFormField<String>(
            initialValue: until,
            decoration: const InputDecoration(labelText: 'Ends after'),
            items: [
              const DropdownMenuItem(value: '', child: Text('No end date')),
              for (var i = 0; i < 12; i++)
                () {
                  final start = DateTime.parse('${existing?.month ?? fromMonth}-01');
                  final ym = SchoolDailyRules.ym(DateTime(start.year, start.month + i));
                  return DropdownMenuItem(value: ym, child: Text(SchoolFeeRules.monthName(ym)));
                }(),
              if (until.isNotEmpty && !List.generate(12, (i) {
                final start = DateTime.parse('${existing?.month ?? fromMonth}-01');
                return SchoolDailyRules.ym(DateTime(start.year, start.month + i));
              }).contains(until))
                DropdownMenuItem(value: until, child: Text(SchoolFeeRules.monthName(until))),
            ],
            onChanged: (v) => setS(() => until = v ?? ''),
          ),
        ]),
      );
    }),
  );
  amount.dispose();
  reason.dispose();
  return ok == true;
}

// ── Fee settings ────────────────────────────────────────────────────────────

Future<bool> showFeeSettingsDialog(BuildContext context, {required String branchId, required SchoolFeeConfig config, required String editorName}) async {
  final base = TextEditingController(text: '${config.baseFee}');
  final admission = TextEditingController(text: '${config.admissionFee}');
  final amounts = {for (final r in SchoolFeeRule.values) r: TextEditingController(text: '${config.amountOf(r)}')};
  var enabled = config.enabled;
  String? error;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      final c = ctx.comfort;
      final sum = amounts.values.fold<int>(0, (a, t) => a + (int.tryParse(t.text) ?? 0));
      final b = int.tryParse(base.text) ?? 0;
      return _FeeDialog(
        icon: GIcons.settings,
        title: 'Fee settings',
        subtitle: 'From ${SchoolFeeRules.monthName(config.month)} onward · earlier closed months keep theirs',
        error: error,
        width: 520,
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              try {
                await SchoolFeeService.saveConfig(
                  branchId: branchId,
                  editorName: editorName,
                  config: config.copyWith(
                    baseFee: int.tryParse(base.text) ?? 0,
                    admissionFee: int.tryParse(admission.text) ?? 0,
                    enabled: enabled,
                    amounts: {for (final e in amounts.entries) e.key: int.tryParse(e.value.text) ?? 0},
                  ),
                );
                if (ctx.mounted) Navigator.pop(ctx, true);
              } catch (e) {
                setS(() => error = _msg(e));
              }
            },
            child: const Text('Save'),
          ),
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: enabled,
            onChanged: (v) => setS(() => enabled = v),
            title: const Text('Charge fees this month'),
          ),
          Row(children: [
            Expanded(
              child: TextField(
                controller: base,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (_) => setS(() {}),
                decoration: const InputDecoration(labelText: 'Monthly fee (Rs)'),
              ),
            ),
            const SizedBox(width: Gsp.sp3),
            Expanded(
              child: TextField(
                controller: admission,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'Admission fee (once)', helperText: '0 = none'),
              ),
            ),
          ]),
          const SizedBox(height: Gsp.sp4),
          Text('CREDIT PER RULE', style: GText.overline(c.textMuted)),
          const SizedBox(height: Gsp.sp2),
          for (final r in SchoolFeeRule.values)
            Padding(
              padding: const EdgeInsets.only(bottom: Gsp.sp2),
              child: Row(children: [
                Expanded(child: Text('${r.label} · ${r.urdu}', style: GText.body2(c.textPrimary))),
                SizedBox(
                  width: 130,
                  child: TextField(
                    controller: amounts[r],
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (_) => setS(() {}),
                    decoration: const InputDecoration(isDense: true, prefixText: 'Rs '),
                  ),
                ),
              ]),
            ),
          Text(
            sum == b ? 'Rules add up to the monthly fee.' : 'Rules add up to Rs $sum; they must equal the monthly fee (Rs $b).',
            style: GText.caption(sum == b ? c.success : c.danger),
          ),
        ]),
      );
    }),
  );
  base.dispose();
  admission.dispose();
  for (final t in amounts.values) {
    t.dispose();
  }
  return ok == true;
}
