// lib/pages/school/views/school_fee_management_view.dart
//
// Fees (School ERP plan §3.5, Phase 4, 2026-11-17), on the ERP kit:
//   Month sheet  each student's fee for the month: base, the six rule credits,
//                concession, due, paid, status; Close month
//   Payments     the receipt book (append-only; reversals are minus entries)
//   Defaulters   who still owes, oldest first
//   Concessions  welfare concessions in force
// Record panel: rule-by-rule sheet, months, payments, Take payment, Print slip,
// Adjust (closed months), Concession.
// Replaces the old screen that kept one editable record per month.

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../../utils/debounced_box_listenable.dart';
import '../../../services/local_storage_service.dart';
import '../constants/school_constants.dart';
import '../daily/daily_models.dart';
import '../daily/daily_rules.dart';
import '../daily/school_daily_service.dart';
import '../daily/views/daily_common.dart';
import '../fees/fee_models.dart';
import '../fees/fee_pdf_service.dart';
import '../fees/fee_rules.dart';
import '../fees/school_fee_service.dart';
import '../fees/widgets/fee_dialogs.dart';
import '../models/school_student.dart';
import '../students/school_student_service.dart';
import '../utils/school_auth_helper.dart';
import '../utils/school_local_storage.dart';
import '../widgets/erp/school_erp.dart';

class SchoolFeeManagementView extends StatefulWidget {
  final String branchId;
  final String userName;
  final String userRole;

  const SchoolFeeManagementView({super.key, required this.branchId, required this.userName, this.userRole = 'School Admin'});

  @override
  State<SchoolFeeManagementView> createState() => _SchoolFeeManagementViewState();
}

enum _Tab { sheet, payments, defaulters, concessions }

class _SchoolFeeManagementViewState extends State<SchoolFeeManagementView> {
  late final Future<void> _ready = SchoolLocalStorage.ensureBoxesOpen();
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  _Tab _tab = _Tab.sheet;
  final _search = TextEditingController();
  String _grade = 'All';
  String _payState = 'All';
  String? _selectedId;

  /// Fees are open to managers (Principal, School admin, head office) and the Accountant.
  bool get _canOpen => SchoolAuthHelper.isAdminOrPrincipal(widget.userRole) || SchoolAuthHelper.isAccountant(widget.userRole);

  /// Settings, reversals, adjustments and concessions: managers only.
  bool get _isPrincipal => SchoolAuthHelper.isAdminOrPrincipal(widget.userRole);

  /// Month close: managers or the Accountant (plan §3.5).
  bool get _canClose => _canOpen;
  String get _branchName => LocalStorageService.getBranchName(widget.branchId);

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_canOpen) {
      return const SchoolErpPage(
        breadcrumbs: ['School', 'Finance'],
        title: 'Fees',
        icon: GIcons.fees,
        child: AppEmptyState(icon: GIcons.lock, title: 'Office staff only', subtitle: 'Fees are handled by the Principal, School Admin and accounts.'),
      );
    }
    return FutureBuilder<void>(
      future: _ready,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        final boxes = {...SchoolFeeService.watchedBoxes, LocalStorageService.schoolLogsBox}
            .where(Hive.isBoxOpen)
            .map((b) => DebouncedBoxListenable.shared(Hive.box(b)))
            .toList();
        return ListenableBuilder(
          listenable: Listenable.merge(boxes),
          builder: (context, _) => _build(context, SchoolFeeService.snapshot(widget.branchId, _month.year, _month.month)),
        );
      },
    );
  }

  bool _matches(SchoolStudent s) {
    if (_grade != 'All' && s.grade != _grade) return false;
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    return s.name.toLowerCase().contains(q) || s.admissionNo.toLowerCase().contains(q) || s.guardianName.toLowerCase().contains(q);
  }

  Widget _build(BuildContext context, SchoolFeeSnapshot snap) {
    final c = context.comfort;
    final now = DateTime.now();
    final rosterById = {for (final s in SchoolStudentService.roster(widget.branchId).students) s.id: s};
    final monthRows = snap.students.where(_matches).where((s) {
      if (_payState == 'All') return true;
      final st = snap.monthOf(s.id)?.state;
      return switch (_payState) {
        'Paid' => st == SchoolMonthPayState.paid || st == SchoolMonthPayState.nothingDue,
        'Partial' => st == SchoolMonthPayState.partial,
        _ => st == SchoolMonthPayState.unpaid,
      };
    }).toList();

    final due = snap.students.fold<int>(0, (a, s) => a + (snap.monthOf(s.id)?.owed ?? 0));
    final paid = snap.students.fold<int>(0, (a, s) => a + (snap.monthOf(s.id)?.paid ?? 0));
    final fullBase = snap.students.fold<int>(0, (a, s) => a + (snap.sheets[s.id]?.base ?? 0));
    final credits = snap.students.fold<int>(0, (a, s) => a + (snap.sheets[s.id]?.credits ?? 0));
    final collectedThisMonth = snap.payments.where((p) => p.date.startsWith(snap.ym)).fold<int>(0, (a, p) => a + p.amount);
    final defaulters = snap.accounts.values.where((a) => a.arrears > 0).toList()..sort((a, b) => b.arrears.compareTo(a.arrears));
    final conflicts = snap.receiptConflicts;

    final logs = SchoolDailyService.month(widget.branchId, snap.year, snap.month);
    final blockers = SchoolFeeRules.closeBlockers(
      year: snap.year,
      month: snap.month,
      cal: SchoolDailyService.calendar(widget.branchId),
      students: rosterById.values.where((s) => !s.isVoid).toList(),
      logs: logs,
      config: snap.config,
      now: now,
    );

    final selected = _selectedId == null ? null : rosterById[_selectedId!];

    final monthStepper = DailyStepper(
      label: DateFormat('MMMM yyyy').format(_month),
      onPrev: () => setState(() => _month = DateTime(_month.year, _month.month - 1)),
      onNext: DateTime(_month.year, _month.month + 1).isAfter(now) ? null : () => setState(() => _month = DateTime(_month.year, _month.month + 1)),
    );

    final body = switch (_tab) {
      _Tab.sheet => _sheetTable(context, snap, monthRows, monthStepper),
      _Tab.payments => _paymentsTable(context, snap, rosterById),
      _Tab.defaulters => _defaultersTable(context, snap, defaulters, rosterById),
      _Tab.concessions => _concessionsTable(context, snap, rosterById),
    };

    return SchoolErpPage(
      breadcrumbs: const ['School', 'Finance'],
      title: 'Fees',
      subtitle: 'Rs ${snap.config.baseFee} a month, reduced by six earned credits',
      icon: GIcons.fees,
      actions: [
        if (_isPrincipal)
          OutlinedButton.icon(
            icon: const Icon(GIcons.settings),
            label: const Text('Fee settings'),
            onPressed: snap.closed
                ? null
                : () async {
                    final ok = await showFeeSettingsDialog(context, branchId: widget.branchId, config: snap.config, editorName: widget.userName);
                    if (ok && context.mounted) AppFeedback.success(context, 'Fee settings saved from ${SchoolFeeRules.monthName(snap.ym)}');
                  },
          ),
        if (_canClose && !snap.closed)
          FilledButton.icon(
            icon: const Icon(GIcons.lock),
            label: Text('Close ${DateFormat('MMMM').format(_month)}'),
            onPressed: () async {
              final ok = await showCloseMonthDialog(context, branchId: widget.branchId, snap: snap, blockers: blockers, editorName: widget.userName);
              if (ok && context.mounted) AppFeedback.success(context, '${SchoolFeeRules.monthName(snap.ym)} closed; fee sheets frozen');
            },
          ),
      ],
      tabs: SchoolErpTabs(
        labels: const ['Month sheet', 'Payments', 'Defaulters', 'Concessions'],
        icons: const [GIcons.ledger, GIcons.receipt, GIcons.warning, GIcons.donation],
        counts: [
          snap.students.length,
          snap.payments.length,
          defaulters.length,
          snap.adjustments.where((a) => a.kind == SchoolAdjustmentKind.concession && a.active).length,
        ],
        selected: _tab.index,
        onChanged: (i) => setState(() => _tab = _Tab.values[i]),
      ),
      banner: conflicts.isEmpty
          ? null
          : DailyBanner(
              tone: AppChipState.warning,
              icon: GIcons.warning,
              text: '${conflicts.length} receipt ${conflicts.length == 1 ? 'number was' : 'numbers were'} issued twice '
                  '(${conflicts.keys.take(3).join(', ')}), probably by two computers working offline. Both payments are kept; write the second number by hand on its receipt.',
            ),
      stats: SchoolErpStatStrip([
        SchoolErpStat(
          label: snap.closed ? 'Month closed' : 'Month open',
          value: SchoolFeeRules.monthName(snap.ym),
          icon: snap.closed ? GIcons.lock : GIcons.calendar,
          color: snap.closed ? c.textMuted : c.info,
          caption: snap.closed ? 'Sheets frozen' : 'Live from the daily log',
        ),
        SchoolErpStat(label: 'Fee before credits', value: SchoolFeePdf.rs(fullBase), icon: GIcons.fees, caption: '${snap.students.length} students'),
        SchoolErpStat(label: 'Credits earned', value: SchoolFeePdf.rs(credits), icon: GIcons.star, color: c.success,
            caption: fullBase == 0 ? '' : '${(credits * 100 / fullBase).round()}% of the fee'),
        SchoolErpStat(label: 'Due this month', value: SchoolFeePdf.rs(due), icon: GIcons.receipt, color: c.accentStrong,
            caption: '${SchoolFeePdf.rs(paid)} paid toward it'),
        SchoolErpStat(label: 'Collected', value: SchoolFeePdf.rs(collectedThisMonth), icon: GIcons.money, color: c.chart2, caption: 'Receipts dated this month'),
        SchoolErpStat(
          label: 'Arrears',
          value: SchoolFeePdf.rs(defaulters.fold(0, (a, d) => a + d.arrears)),
          icon: GIcons.warning,
          color: defaulters.isEmpty ? c.success : c.danger,
          caption: '${defaulters.length} families',
          onTap: () => setState(() => _tab = _Tab.defaulters),
        ),
      ]),
      child: SchoolErpMasterDetail(
        master: body,
        detail: selected == null
            ? null
            : _FeePanel(
                branchId: widget.branchId,
                branchName: _branchName,
                student: selected,
                snap: snap,
                editorName: widget.userName,
                isPrincipal: _isPrincipal,
                onClose: () => setState(() => _selectedId = null),
              ),
      ),
    );
  }

  void _open(SchoolStudent s, SchoolFeeSnapshot snap) {
    if (SchoolErp.wide(context)) {
      setState(() => _selectedId = s.id);
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.88,
        child: _FeePanel(
          branchId: widget.branchId,
          branchName: _branchName,
          student: s,
          snap: snap,
          editorName: widget.userName,
          isPrincipal: _isPrincipal,
        ),
      ),
    );
  }

  // ── Month sheet ───────────────────────────────────────────────────────────

  Widget _sheetTable(BuildContext context, SchoolFeeSnapshot snap, List<SchoolStudent> rows, Widget stepper) {
    final c = context.comfort;
    Widget ruleCell(SchoolStudent s, SchoolFeeRule r) {
      final sheet = snap.sheets[s.id];
      if (sheet == null || sheet.lines.isEmpty) return SchoolErpCell.text(context, '—', muted: true);
      final l = sheet.line(r);
      final color = l.full ? c.success : (l.none ? c.danger : c.warning);
      return Tooltip(
        message: r == SchoolFeeRule.ptm
            ? 'PTM: ${l.met == null ? 'not held yet' : (l.met! ? 'attended' : 'did not attend')}'
            : '${r.label}: ${l.qualifying} of ${l.outOf} days',
        child: SchoolErpCell.mono(context, l.credit == 0 && r == SchoolFeeRule.ptm && l.met == null ? '…' : _k(l.credit), color: color),
      );
    }

    return SchoolErpCard(
      toolbar: SchoolErpToolbar(
        search: _search,
        searchHint: 'Name, admission no. or father',
        onSearch: (_) => setState(() {}),
        filters: [
          stepper,
          SchoolErpFilter<String>(
            label: 'Class',
            value: _grade,
            options: {'All': 'All classes', for (final g in SchoolConstants.grades) g: g},
            onChanged: (v) => setState(() => _grade = v),
          ),
          SchoolErpFilter<String>(
            label: 'Payment',
            value: _payState,
            width: 130,
            options: const {'All': 'All', 'Paid': 'Paid', 'Partial': 'Partial', 'Unpaid': 'Unpaid'},
            onChanged: (v) => setState(() => _payState = v),
          ),
        ],
      ),
      footer: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3, vertical: Gsp.sp2),
        child: Text(
          'Rule columns show the rupees each child earned off the fee (green = full, amber = part, red = none). '
          '${snap.closed ? 'This month is closed: figures are frozen.' : 'Open month: figures update as the daily log is marked.'}',
          style: GText.caption(c.textMuted),
        ),
      ),
      child: SchoolErpTable<SchoolStudent>(
        rows: rows,
        rowKey: (s) => s.id,
        selectedKey: _selectedId,
        onRowTap: (s) => _open(s, snap),
        minWidth: 1100,
        empty: AppEmptyState(
          icon: GIcons.fees,
          title: snap.students.isEmpty ? 'No students enrolled in ${SchoolFeeRules.monthName(snap.ym)}' : 'No students match',
          compact: true,
        ),
        columns: [
          SchoolErpColumn(label: 'Adm. no', width: 100, sortValue: (s) => s.admissionNo, cell: (s) => SchoolErpCell.mono(context, s.admissionNo)),
          SchoolErpColumn(label: 'Student', flex: 4, sortValue: (s) => s.name.toLowerCase(),
              cell: (s) => SchoolErpCell.primary(context, s.name, sub: 'Class ${s.grade}-${s.section}')),
          SchoolErpColumn(label: 'Fee', width: 72, numeric: true, sortValue: (s) => snap.sheets[s.id]?.base ?? 0,
              cell: (s) => SchoolErpCell.mono(context, _k(snap.sheets[s.id]?.base ?? 0))),
          for (final r in SchoolFeeRule.values)
            SchoolErpColumn(
              label: switch (r) {
                SchoolFeeRule.attendance => 'Attend.',
                SchoolFeeRule.onTime => 'On time',
                SchoolFeeRule.messageReply => 'Reply',
                SchoolFeeRule.behaviour => 'Behav.',
                SchoolFeeRule.ptm => 'PTM',
                SchoolFeeRule.uniform => 'Uniform',
              },
              width: 66,
              numeric: true,
              sortValue: (s) => snap.sheets[s.id]?.lines.isEmpty ?? true ? 0 : snap.sheets[s.id]!.line(r).credit,
              cell: (s) => ruleCell(s, r),
            ),
          SchoolErpColumn(label: 'Due', width: 80, numeric: true, sortValue: (s) => snap.monthOf(s.id)?.owed ?? 0,
              cell: (s) => SchoolErpCell.mono(context, _k(snap.monthOf(s.id)?.owed ?? 0))),
          SchoolErpColumn(label: 'Paid', width: 80, numeric: true, sortValue: (s) => snap.monthOf(s.id)?.paid ?? 0,
              cell: (s) => SchoolErpCell.mono(context, _k(snap.monthOf(s.id)?.paid ?? 0), color: c.success)),
          SchoolErpColumn(label: 'Status', width: 110, sortValue: (s) => snap.monthOf(s.id)?.state.index ?? 0,
              cell: (s) => _PayChip(snap.monthOf(s.id)?.state)),
        ],
      ),
    );
  }

  // ── Payments ──────────────────────────────────────────────────────────────

  Widget _paymentsTable(BuildContext context, SchoolFeeSnapshot snap, Map<String, SchoolStudent> students) {
    final c = context.comfort;
    final q = _search.text.trim().toLowerCase();
    final rows = snap.payments.where((p) {
      if (q.isEmpty) return true;
      final s = students[p.studentId];
      return p.receiptNo.toLowerCase().contains(q) || (s?.name.toLowerCase().contains(q) ?? false) || (s?.admissionNo.toLowerCase().contains(q) ?? false);
    }).toList()
      ..sort((a, b) => b.at.compareTo(a.at));
    final reversed = {for (final p in snap.payments) if (p.isReversal) p.reversalOf};
    return SchoolErpCard(
      toolbar: SchoolErpToolbar(
        search: _search,
        searchHint: 'Receipt no., student or admission no.',
        onSearch: (_) => setState(() {}),
        trailing: [
          Center(
            child: Text('Total ${SchoolFeePdf.rs(rows.fold(0, (a, p) => a + p.amount))}', style: GText.label(c.textSecondary)),
          ),
        ],
      ),
      child: SchoolErpTable<SchoolFeePayment>(
        rows: rows,
        rowKey: (p) => p.id,
        minWidth: 900,
        onRowTap: (p) {
          final s = students[p.studentId];
          if (s != null) _open(s, snap);
        },
        rowColor: (p) => p.isReversal || reversed.contains(p.id) ? c.surfaceSunken : null,
        empty: const AppEmptyState(icon: GIcons.receipt, title: 'No payments yet', compact: true),
        columns: [
          SchoolErpColumn(label: 'Receipt', width: 160, sortValue: (p) => p.receiptNo, cell: (p) => SchoolErpCell.mono(context, p.receiptNo)),
          SchoolErpColumn(label: 'Date', width: 100, sortValue: (p) => p.date, cell: (p) => SchoolErpCell.text(context, p.date)),
          SchoolErpColumn(label: 'Student', flex: 4, sortValue: (p) => students[p.studentId]?.name ?? '',
              cell: (p) => SchoolErpCell.primary(context, students[p.studentId]?.name ?? 'Unknown', sub: students[p.studentId]?.admissionNo)),
          SchoolErpColumn(label: 'Method', flex: 2, hideBelow: 800, cell: (p) => SchoolErpCell.text(context, p.method.label)),
          SchoolErpColumn(label: 'Amount', width: 100, numeric: true, sortValue: (p) => p.amount,
              cell: (p) => SchoolErpCell.mono(context, SchoolFeePdf.rs(p.amount), color: p.amount < 0 ? c.danger : null)),
          SchoolErpColumn(label: 'By', flex: 2, hideBelow: 900, cell: (p) => SchoolErpCell.text(context, p.by)),
          SchoolErpColumn(
            label: '',
            width: 110,
            cell: (p) => p.isReversal
                ? const AppChip(label: 'Reversal', state: AppChipState.danger)
                : reversed.contains(p.id)
                    ? const AppChip(label: 'Reversed', state: AppChipState.neutral)
                    : (_isPrincipal
                        ? TextButton(
                            onPressed: () async {
                              final ok = await showReversePaymentDialog(context, branchId: widget.branchId, payment: p, editorName: widget.userName);
                              if (ok && context.mounted) AppFeedback.success(context, 'Receipt ${p.receiptNo} reversed');
                            },
                            child: const Text('Reverse'),
                          )
                        : const SizedBox.shrink()),
          ),
        ],
      ),
    );
  }

  // ── Defaulters ────────────────────────────────────────────────────────────

  Widget _defaultersTable(BuildContext context, SchoolFeeSnapshot snap, List<SchoolFeeAccount> rows, Map<String, SchoolStudent> students) {
    final c = context.comfort;
    return SchoolErpCard(
      title: 'Owed for closed months',
      subtitle: 'The live month is not counted until it is closed',
      child: SchoolErpTable<SchoolFeeAccount>(
        rows: rows.where((a) => students[a.studentId] != null && _matches(students[a.studentId]!)).toList(),
        rowKey: (a) => a.studentId,
        onRowTap: (a) => _open(students[a.studentId]!, snap),
        minWidth: 760,
        empty: AppEmptyState(icon: GIcons.checkCircle, title: 'Nobody owes for closed months', subtitle: snap.closed ? null : 'Close a month to see arrears.', compact: true),
        columns: [
          SchoolErpColumn(label: 'Student', flex: 4, sortValue: (a) => students[a.studentId]!.name,
              cell: (a) => SchoolErpCell.primary(context, students[a.studentId]!.name, sub: '${students[a.studentId]!.admissionNo} · Class ${students[a.studentId]!.grade}-${students[a.studentId]!.section}')),
          SchoolErpColumn(label: 'Phone', flex: 2, hideBelow: 800, cell: (a) => SchoolErpCell.mono(context, students[a.studentId]!.guardianPhone)),
          SchoolErpColumn(
            label: 'Months owed',
            flex: 3,
            cell: (a) => SchoolErpCell.text(
              context,
              a.months.where((m) => m.sheet.closed && m.outstanding > 0).map((m) => DateFormat('MMM yy').format(DateTime.parse('${m.sheet.month}-01'))).join(', '),
            ),
          ),
          SchoolErpColumn(label: 'Arrears', width: 110, numeric: true, sortValue: (a) => a.arrears,
              cell: (a) => SchoolErpCell.mono(context, SchoolFeePdf.rs(a.arrears), color: c.danger)),
        ],
      ),
    );
  }

  // ── Concessions ───────────────────────────────────────────────────────────

  Widget _concessionsTable(BuildContext context, SchoolFeeSnapshot snap, Map<String, SchoolStudent> students) {
    final rows = snap.adjustments.where((a) => a.kind == SchoolAdjustmentKind.concession && a.active && students[a.studentId] != null).toList();
    return SchoolErpCard(
      title: 'Welfare concessions',
      subtitle: 'Give or change a concession from the student\'s fee panel',
      child: SchoolErpTable<SchoolFeeAdjustment>(
        rows: rows,
        rowKey: (a) => a.id,
        onRowTap: (a) => _open(students[a.studentId]!, snap),
        empty: const AppEmptyState(icon: GIcons.donation, title: 'No concessions', compact: true),
        columns: [
          SchoolErpColumn(label: 'Student', flex: 4, sortValue: (a) => students[a.studentId]!.name,
              cell: (a) => SchoolErpCell.primary(context, students[a.studentId]!.name, sub: students[a.studentId]!.admissionNo)),
          SchoolErpColumn(label: 'Concession', width: 110, cell: (a) => SchoolErpCell.mono(context, a.percent ? '${a.amount}%' : SchoolFeePdf.rs(a.amount))),
          SchoolErpColumn(label: 'From', width: 110, sortValue: (a) => a.month, cell: (a) => SchoolErpCell.text(context, SchoolFeeRules.monthName(a.month))),
          SchoolErpColumn(label: 'Until', width: 110, cell: (a) => SchoolErpCell.text(context, a.untilMonth.isEmpty ? 'No end' : SchoolFeeRules.monthName(a.untilMonth))),
          SchoolErpColumn(label: 'Reason', flex: 4, cell: (a) => SchoolErpCell.text(context, a.reason)),
          SchoolErpColumn(label: 'Approved by', flex: 2, hideBelow: 900, cell: (a) => SchoolErpCell.text(context, a.approvedBy)),
        ],
      ),
    );
  }
}

/// "12,000" without the Rs (dense tables).
String _k(int v) => SchoolFeePdf.rs(v).replaceFirst('Rs ', '');

class _PayChip extends StatelessWidget {
  const _PayChip(this.state);
  final SchoolMonthPayState? state;

  @override
  Widget build(BuildContext context) => switch (state) {
        null => const AppChip(label: '—', state: AppChipState.neutral),
        SchoolMonthPayState.paid => const AppChip(label: 'Paid', state: AppChipState.active, icon: GIcons.checkCircle),
        SchoolMonthPayState.partial => const AppChip(label: 'Partial', state: AppChipState.warning, icon: GIcons.partial),
        SchoolMonthPayState.unpaid => const AppChip(label: 'Unpaid', state: AppChipState.danger),
        SchoolMonthPayState.nothingDue => const AppChip(label: 'Nothing due', state: AppChipState.info),
      };
}

// ── Student fee panel ───────────────────────────────────────────────────────

class _FeePanel extends StatelessWidget {
  const _FeePanel({
    required this.branchId,
    required this.branchName,
    required this.student,
    required this.snap,
    required this.editorName,
    required this.isPrincipal,
    this.onClose,
  });

  final String branchId;
  final String branchName;
  final SchoolStudent student;
  final SchoolFeeSnapshot snap;
  final String editorName;
  final bool isPrincipal;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final account = snap.accounts[student.id] ??
        const SchoolFeeAccount(studentId: '', months: [], payments: [], credit: 0);
    final month = account.month(snap.ym);
    final sheet = month?.sheet;
    final concession = snap.adjustments.where((a) => a.studentId == student.id && a.kind == SchoolAdjustmentKind.concession && a.active).firstOrNull;

    return SchoolErpDetailPanel(
      onClose: onClose,
      leading: const GModuleTile(icon: GIcons.fees, size: 44),
      title: student.name,
      subtitle: '${student.admissionNo} · Class ${student.grade}-${student.section}',
      chips: [
        AppChip(
          label: account.balance > 0 ? 'Owes ${SchoolFeePdf.rs(account.balance)}' : (account.credit > 0 ? 'Advance ${SchoolFeePdf.rs(account.credit)}' : 'Nothing owed'),
          state: account.balance > 0 ? AppChipState.danger : AppChipState.active,
        ),
        if (concession != null) AppChip(label: 'Concession ${concession.percent ? '${concession.amount}%' : SchoolFeePdf.rs(concession.amount)}', state: AppChipState.info),
      ],
      actions: [
        FilledButton.icon(
          icon: const Icon(GIcons.money, size: 16),
          label: const Text('Take payment'),
          onPressed: () async {
            final p = await showTakePaymentDialog(context, branchId: branchId, student: student, account: account, editorName: editorName, branchName: branchName);
            if (p != null && context.mounted) AppFeedback.success(context, 'Receipt ${p.receiptNo}: ${SchoolFeePdf.rs(p.amount)} received');
          },
        ),
        if (month != null)
          OutlinedButton.icon(
            icon: const Icon(GIcons.print, size: 16),
            label: const Text('Fee slip'),
            onPressed: () async {
              try {
                await SchoolFeePdf.printBytes('Fee-slip-${student.admissionNo}-${snap.ym}',
                    await SchoolFeePdf.feeSlip(student: student, month: month, account: account, branchName: branchName));
              } catch (e) {
                if (context.mounted) AppFeedback.error(context, 'Could not print: $e');
              }
            },
          ),
        if (isPrincipal && snap.closed && month != null)
          OutlinedButton.icon(
            icon: const Icon(GIcons.edit, size: 16),
            label: const Text('Adjust'),
            onPressed: () async {
              final ok = await showAdjustmentDialog(context, branchId: branchId, student: student, month: snap.ym, editorName: editorName);
              if (ok && context.mounted) AppFeedback.success(context, 'Adjustment saved');
            },
          ),
        if (isPrincipal)
          OutlinedButton.icon(
            icon: const Icon(GIcons.donation, size: 16),
            label: Text(concession == null ? 'Concession' : 'Change concession'),
            onPressed: () async {
              final open = snap.closed ? SchoolDailyRules.ym(DateTime(snap.year, snap.month + 1)) : snap.ym;
              final ok = await showConcessionDialog(context, branchId: branchId, student: student, fromMonth: open, editorName: editorName, existing: concession);
              if (ok && context.mounted) AppFeedback.success(context, 'Concession saved');
            },
          ),
      ],
      children: [
        if (sheet == null)
          Padding(
            padding: const EdgeInsets.only(top: Gsp.sp4),
            child: Text('No fee for ${SchoolFeeRules.monthName(snap.ym)} (not enrolled that month).', style: GText.body2(c.textMuted)),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.only(top: Gsp.sp4, bottom: Gsp.sp2),
            child: Text(
              '${SchoolFeeRules.monthName(snap.ym).toUpperCase()} · ${sheet.closed ? 'CLOSED' : 'PROVISIONAL'}',
              style: GText.overline(c.textMuted),
            ),
          ),
          Container(
            decoration: BoxDecoration(borderRadius: SchoolErp.radius, border: Border.all(color: c.border)),
            child: Column(children: [
              for (final (i, l) in sheet.lines.indexed)
                Container(
                  decoration: BoxDecoration(border: i == 0 ? null : Border(top: BorderSide(color: c.border))),
                  padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3, vertical: Gsp.sp2),
                  child: Row(children: [
                    Icon(l.full ? GIcons.checkCircle : (l.none ? GIcons.cancel : GIcons.partial), size: 18,
                        color: l.full ? c.success : (l.none ? c.danger : c.warning)),
                    const SizedBox(width: Gsp.sp2),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(l.rule.label, style: GText.body2Bold(c.textPrimary)),
                        Text(
                          l.rule == SchoolFeeRule.ptm
                              ? (l.met == null ? 'PTM not held yet' : (l.met! ? 'Parent attended' : 'Parent did not attend'))
                              : '${l.qualifying} of ${l.outOf} days',
                          style: GText.caption(c.textMuted),
                        ),
                      ]),
                    ),
                    Text('− ${SchoolFeePdf.rs(l.credit)}', style: GText.label(c.success)),
                  ]),
                ),
            ]),
          ),
          SchoolErpFacts(title: 'Working out', facts: [
            ('Days', '${sheet.activeDays} of ${sheet.workingDays} working days enrolled · ${sheet.recordedDays} marked'),
            ('Fee', SchoolFeePdf.rs(sheet.base)),
            ('Credits', '− ${SchoolFeePdf.rs(sheet.credits)}'),
            if (sheet.concession > 0) ('Concession', '− ${SchoolFeePdf.rs(sheet.concession)}  (${sheet.concessionNote})'),
            if (sheet.admissionFee > 0) ('Admission fee', '+ ${SchoolFeePdf.rs(sheet.admissionFee)}'),
            if (month!.adjustments != 0) ('Adjustments', SchoolFeePdf.rs(month.adjustments)),
            ('Due', SchoolFeePdf.rs(month.owed)),
            ('Paid toward it', SchoolFeePdf.rs(month.paid)),
          ]),
        ],
        Padding(
          padding: const EdgeInsets.only(top: Gsp.sp4, bottom: Gsp.sp2),
          child: Text('ALL MONTHS', style: GText.overline(c.textMuted)),
        ),
        for (final m in account.months.reversed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Expanded(child: Text(SchoolFeeRules.monthName(m.sheet.month) + (m.sheet.closed ? '' : ' (open)'), style: GText.body2(c.textPrimary))),
              Text('${SchoolFeePdf.rs(m.paid)} / ${SchoolFeePdf.rs(m.owed)}', style: GText.caption(c.textSecondary)),
              const SizedBox(width: Gsp.sp2),
              _PayChip(m.state),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.only(top: Gsp.sp4, bottom: Gsp.sp2),
          child: Text('PAYMENTS (${account.payments.length})', style: GText.overline(c.textMuted)),
        ),
        if (account.payments.isEmpty) Text('No payments yet.', style: GText.body2(c.textMuted)),
        for (final p in account.payments.reversed)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('${p.receiptNo} · ${SchoolFeePdf.rs(p.amount)}', style: GText.body2Bold(p.amount < 0 ? c.danger : c.textPrimary)),
            subtitle: Text('${p.date} · ${p.method.label}${p.note.isEmpty ? '' : ' · ${p.note}'} · ${p.by}', style: GText.caption(c.textMuted)),
            trailing: IconButton(
              tooltip: 'Print receipt',
              icon: const Icon(GIcons.print, size: 18),
              onPressed: () async {
                try {
                  await SchoolFeePdf.printBytes('Receipt-${p.receiptNo}', await SchoolFeePdf.receipt(student: student, payment: p, account: account, branchName: branchName));
                } catch (e) {
                  if (context.mounted) AppFeedback.error(context, 'Could not print: $e');
                }
              },
            ),
          ),
      ],
    );
  }
}
