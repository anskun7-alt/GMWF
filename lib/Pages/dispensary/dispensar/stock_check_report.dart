// lib/pages/dispensary/dispensar/stock_check_report.dart
//
// "Report" — one screen for the dispensary's stock reports (user, 2026-11-19: merge the
// Medicine Ledger and the stock check report, and call it Report):
//   • Medicine ledger — a medicine's month history (MedicineLedgerPage, unchanged inside);
//   • Checks          — what the weekly / on-connect stock check found;
//   • Needs a count   — medicines whose record went below 0;
//   • Set aside       — records the one-time repair put aside (no name / unknown camp).
//
// Data: StockDriftLog (box stock_drift_log — the LAN server sends every entry to all desks),
// the stock book (live), and StockRepair.quarantined() (box stock_quarantine).

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';

import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/stock/stock_actions.dart';
import 'package:gmwf/services/stock/stock_ledger.dart';
import 'package:gmwf/services/stock/stock_pool.dart';
import 'package:gmwf/services/stock/stock_repair.dart';
import 'package:gmwf/services/stock/stock_sync.dart';
import 'package:gmwf/widgets/global_module_wrapper.dart';

import 'medicine_ledger.dart';

class StockReportPage extends StatefulWidget {
  const StockReportPage({
    super.key,
    required this.branchId,
    this.canAdjust = false,
    this.isEmbedded = false,
    this.initialMedicine,
    this.initialTab = 0,
  });

  final String branchId;

  /// Dispensar / admin: may enter a counted figure. The doctor only views.
  final bool canAdjust;

  /// Inside another screen (Inventory tab, module shell): no own title bar.
  final bool isEmbedded;

  /// Opens the ledger tab on this medicine.
  final Map<String, dynamic>? initialMedicine;

  /// Tab shown first: 0 ledger, 1 checks, 2 needs a count, 3 set aside.
  final int initialTab;

  @override
  State<StockReportPage> createState() => _StockReportPageState();
}

class _StockReportPageState extends State<StockReportPage> {
  bool _checking = false;
  bool _boxesReady = false;

  @override
  void initState() {
    super.initState();
    _openBoxes();
  }

  Future<void> _openBoxes() async {
    for (final name in [StockDriftLog.boxName, StockRepair.quarantineBox]) {
      if (!Hive.isBoxOpen(name)) await Hive.openBox(name);
    }
    await StockLedger.ensureOpen();
    if (mounted) setState(() => _boxesReady = true);
  }

  String get _branch => StockPool.normalizeBranch(widget.branchId);

  Set<String> get _myPools => StockPool.allFor(widget.branchId).map((p) => p.key).toSet();

  bool _isMyPool(Object? pool) {
    final p = (pool ?? '').toString();
    if (p.isEmpty) return false;
    return p == _branch || p.startsWith('$_branch/') || _myPools.contains(p);
  }

  String _poolLabel(Object? poolKey) {
    final p = StockPool.fromKey(poolKey?.toString());
    if (p == null) return '—';
    final b = p.branch.isEmpty ? '' : '${p.branch[0].toUpperCase()}${p.branch.substring(1)}';
    return p.camp == null ? b : '$b · ${CampSessionService.getCampLabel(p.camp!, p.branch)}';
  }

  static String _fmtQty(Object? v) {
    final n = v is num ? v : num.tryParse(v?.toString() ?? '') ?? 0;
    return n == n.roundToDouble() ? n.toInt().toString() : n.toStringAsFixed(1);
  }

  static String _fmtDate(Object? iso) {
    final dt = DateTime.tryParse(iso?.toString() ?? '');
    if (dt == null) return '—';
    return DateFormat('d MMM yyyy, h:mm a').format(dt.toLocal());
  }

  Future<void> _checkNow() async {
    setState(() => _checking = true);
    try {
      await StockSync.runCheckNow();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(StockSync.isLanClient
            ? 'Check sent to the server. The result appears here in a few seconds.'
            : 'Stock check finished.'),
      ));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final isWrapped = GlobalModuleWrapper.isWrapped(context);
    final tabs = !_boxesReady
        ? const SizedBox(height: 44)
        : _TabsWithCounts(needsCount: _negatives().length, quarantine: _quarantined().length);
    final body = !_boxesReady
        ? const Center(child: CircularProgressIndicator())
        : TabBarView(children: [
            MedicineLedgerPage(
              branchId: widget.branchId,
              initialMedicine: widget.initialMedicine,
              isEmbedded: true,
            ),
            _checksTab(c),
            _needsCountTab(c),
            _quarantineTab(c),
          ]);

    if (widget.isEmbedded || isWrapped) {
      return DefaultTabController(
        length: 4,
        initialIndex: widget.initialTab.clamp(0, 3),
        child: Container(
          color: c.background,
          child: Column(children: [
            Container(color: c.surface, child: tabs),
            Expanded(child: body),
          ]),
        ),
      );
    }

    return DefaultTabController(
      length: 4,
        initialIndex: widget.initialTab.clamp(0, 3),
      child: Scaffold(
        backgroundColor: c.background,
        appBar: AppBar(
          backgroundColor: c.surface,
          foregroundColor: c.textPrimary,
          elevation: 0,
          scrolledUnderElevation: 0,
          title: Row(children: [
            Icon(GIcons.report, size: GIconSize.md, color: c.brand),
            const SizedBox(width: Gsp.sp2),
            Text('Report', style: GText.h3(c.textPrimary)),
          ]),
          bottom: PreferredSize(preferredSize: const Size.fromHeight(44), child: tabs),
        ),
        body: body,
      ),
    );
  }

  Widget _header(GComfortColors c) {
    final last = StockSync.lastCheckAt;
    return Container(
      color: c.surface,
      padding: const EdgeInsets.symmetric(horizontal: Gsp.sp4, vertical: Gsp.sp3),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              last == null ? 'No check has run on this PC yet' : 'Last check: ${_fmtDate(last.toIso8601String())}',
              style: GText.body2Bold(c.textPrimary),
            ),
            const SizedBox(height: 2),
            Text(
              'Runs on its own every week and whenever a PC connects to the server.',
              style: GText.caption(c.textSecondary),
            ),
          ]),
        ),
        FilledButton.icon(
          onPressed: _checking ? null : _checkNow,
          icon: _checking
              ? SizedBox(
                  width: GIconSize.sm,
                  height: GIconSize.sm,
                  child: CircularProgressIndicator(strokeWidth: 2, color: c.onBrand),
                )
              : Icon(GIcons.refresh, size: GIconSize.sm),
          label: Text(_checking ? 'Checking…' : 'Check now'),
          style: FilledButton.styleFrom(
            backgroundColor: c.brand,
            foregroundColor: c.onBrand,
            shape: RoundedRectangleBorder(borderRadius: Gr.button),
          ),
        ),
      ]),
    );
  }

  // ── Tab 1: checks ────────────────────────────────────────────────────────────

  Widget _checksTab(GComfortColors c) {
    return Column(children: [
      _header(c),
      Divider(height: 1, color: c.border),
      Expanded(
        child: ValueListenableBuilder(
          valueListenable: Hive.box(StockDriftLog.boxName).listenable(),
          builder: (context, _, _) {
            final entries = StockDriftLog.entries().where((e) => _isMyPool(e['pool'])).toList();
            if (entries.isEmpty) {
              return _empty(c, GIcons.checkCircle, 'No checks recorded yet',
                  'Press "Check now", or wait for the weekly check.');
            }
            return ListView.separated(
              padding: const EdgeInsets.all(Gsp.sp4),
              itemCount: entries.length,
              separatorBuilder: (_, _) => const SizedBox(height: Gsp.sp3),
              itemBuilder: (context, i) => _checkCard(c, entries[i]),
            );
          },
        ),
      ),
    ]);
  }

  Widget _checkCard(GComfortColors c, Map<String, dynamic> e) {
    final rows = (e['rows'] is List ? e['rows'] as List : const []).whereType<Map>().toList();
    final negatives = (e['negatives'] is List ? e['negatives'] as List : const []).whereType<Map>().toList();
    final isCloud = e['kind'] == 'cloud';
    final ok = rows.isEmpty && negatives.isEmpty;
    final tone = ok ? c.success : c.warning;
    final toneBg = ok ? c.successBg : c.warningBg;
    final who = isCloud
        ? 'Server figures vs cloud'
        : '${(e['device'] ?? '').toString().isEmpty ? 'A desk' : e['device']} vs server';
    final reason = switch ((e['reason'] ?? '').toString()) {
      'weekly' => 'Weekly check',
      'manual' => 'Checked by hand',
      'connect' => 'On connect',
      _ => isCloud ? 'Weekly check' : 'Check',
    };

    return Container(
      decoration: BoxDecoration(color: c.surface, borderRadius: Gr.card, border: Border.all(color: c.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gsp.sp4, Gsp.sp3, Gsp.sp3, Gsp.sp3),
          child: Row(children: [
            Icon(ok ? GIcons.checkCircle : GIcons.warning, size: GIconSize.md, color: tone),
            const SizedBox(width: Gsp.sp2),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${_poolLabel(e['pool'])} · $who', style: GText.body1Bold(c.textPrimary)),
                Text('$reason · ${_fmtDate(e['at'])}', style: GText.caption(c.textSecondary)),
              ]),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: Gsp.sp2, vertical: 2),
              decoration: BoxDecoration(color: toneBg, borderRadius: BorderRadius.circular(Gr.r1)),
              child: Text(
                ok ? 'All matched' : '${rows.length + negatives.length} to look at',
                style: GText.label(tone),
              ),
            ),
          ]),
        ),
        if (!ok) ...[
          Divider(height: 1, color: c.border),
          if (rows.isNotEmpty) _diffTable(c, rows, isCloud: isCloud),
          if (negatives.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(Gsp.sp4, Gsp.sp3, Gsp.sp4, 0),
              child: Text('Below 0 — needs a physical count', style: GText.label(c.danger)),
            ),
          if (negatives.isNotEmpty)
            _simpleTable(c, const ['Medicine', 'Figure'], [
              for (final n in negatives) [(n['name'] ?? n['medicineId'] ?? '').toString(), _fmtQty(n['figure'] ?? n['quantity'])],
            ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gsp.sp4, Gsp.sp2, Gsp.sp4, Gsp.sp3),
            child: Text((e['action'] ?? '').toString(), style: GText.caption(c.textSecondary)),
          ),
        ],
      ]),
    );
  }

  Widget _diffTable(GComfortColors c, List<Map> rows, {required bool isCloud}) {
    final headers = isCloud
        ? const ['Medicine', 'Server', 'Cloud', 'Difference']
        : const ['Medicine', 'Desk had', 'Server', 'Difference'];
    final data = <List<String>>[
      for (final r in rows)
        [
          (r['name'] ?? '').toString().isEmpty ? (r['medicineId'] ?? '').toString() : r['name'].toString(),
          _fmtQty(isCloud ? r['server'] : r['device']),
          _fmtQty(isCloud ? r['cloud'] : r['server']),
          _signed(r['difference']),
        ],
    ];
    return _simpleTable(c, headers, data, highlightLast: true);
  }

  static String _signed(Object? v) {
    final n = v is num ? v : num.tryParse(v?.toString() ?? '') ?? 0;
    final s = _fmtQty(n.abs());
    return n > 0 ? '+$s' : (n < 0 ? '−$s' : '0');
  }

  Widget _simpleTable(GComfortColors c, List<String> headers, List<List<String>> rows, {bool highlightLast = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gsp.sp4, vertical: Gsp.sp2),
      child: Table(
        columnWidths: {
          0: const FlexColumnWidth(3),
          for (var i = 1; i < headers.length; i++) i: const FlexColumnWidth(1.2),
        },
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          TableRow(
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.border))),
            children: [
              for (var i = 0; i < headers.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Gsp.sp2),
                  child: Text(headers[i],
                      textAlign: i == 0 ? TextAlign.start : TextAlign.end, style: GText.label(c.textMuted)),
                ),
            ],
          ),
          for (final r in rows)
            TableRow(
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.border.withValues(alpha: 0.5)))),
              children: [
                for (var i = 0; i < r.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Gsp.sp2),
                    child: Text(
                      r[i],
                      textAlign: i == 0 ? TextAlign.start : TextAlign.end,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: i == 0
                          ? GText.body2(c.textPrimary)
                          : (highlightLast && i == r.length - 1
                              ? GText.body2Bold(r[i].startsWith('−') ? c.danger : c.warning)
                              : GText.body2(c.textSecondary)),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  // ── Tab 2: needs a count ─────────────────────────────────────────────────────

  List<Map<String, dynamic>> _negatives() => [
        for (final it in StockLedger.items())
          if (_isMyPool(it['pool']) && ((it['quantityRaw'] ?? 0) as num) < 0) it,
      ];

  Widget _needsCountTab(GComfortColors c) {
    return ValueListenableBuilder(
      valueListenable: Hive.box(LocalStorageService.stockBox).listenable(),
      builder: (context, _, _) {
        final list = _negatives()
          ..sort((a, b) => (a['name'] ?? '').toString().compareTo((b['name'] ?? '').toString()));
        if (list.isEmpty) {
          return _empty(c, GIcons.checkCircle, 'Nothing below 0',
              'Medicines whose records went below 0 show up here for a count.');
        }
        return ListView(
          padding: const EdgeInsets.all(Gsp.sp4),
          children: [
            Text(
              'These records went below 0 (two PCs gave out the last units at the same time, '
              'or old figures were wrong). Screens show 0. Count the shelf and enter the figure.',
              style: GText.body2(c.textSecondary),
            ),
            const SizedBox(height: Gsp.sp3),
            for (final it in list) _negativeTile(c, it),
          ],
        );
      },
    );
  }

  Widget _negativeTile(GComfortColors c, Map<String, dynamic> it) {
    final name = (it['name'] ?? it['medicineId'] ?? '').toString();
    final details = [it['type'], it['dose'], it['expiryDate']]
        .where((v) => (v ?? '').toString().trim().isNotEmpty)
        .join(' · ');
    return Container(
      margin: const EdgeInsets.only(bottom: Gsp.sp2),
      padding: const EdgeInsets.all(Gsp.sp3),
      decoration: BoxDecoration(color: c.surface, borderRadius: Gr.card, border: Border.all(color: c.border)),
      child: Row(children: [
        Icon(GIcons.lowStock, size: GIconSize.md, color: c.danger),
        const SizedBox(width: Gsp.sp3),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: GText.body1Bold(c.textPrimary)),
            Text('${_poolLabel(it['pool'])}${details.isEmpty ? '' : ' · $details'}',
                style: GText.caption(c.textSecondary)),
          ]),
        ),
        Text('Record: ${_fmtQty(it['quantityRaw'])}', style: GText.body2Bold(c.danger)),
        if (widget.canAdjust) ...[
          const SizedBox(width: Gsp.sp3),
          OutlinedButton(
            onPressed: () => _enterCount(it),
            style: OutlinedButton.styleFrom(
              foregroundColor: c.brand,
              side: BorderSide(color: c.brand),
              shape: RoundedRectangleBorder(borderRadius: Gr.button),
            ),
            child: const Text('Enter count'),
          ),
        ],
      ]),
    );
  }

  Future<void> _enterCount(Map<String, dynamic> it) async {
    final pool = StockPool.fromKey(it['pool']?.toString());
    final id = (it['medicineId'] ?? it['id'] ?? '').toString();
    if (pool == null || id.isEmpty) return;
    final ctrl = TextEditingController();
    final counted = await showDialog<double>(
      context: context,
      builder: (ctx) {
        final c = ctx.comfort;
        return AlertDialog(
          backgroundColor: c.surface,
          shape: RoundedRectangleBorder(borderRadius: Gr.modal),
          title: Text('Counted on the shelf', style: GText.h3(c.textPrimary)),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text((it['name'] ?? id).toString(), style: GText.body1Bold(c.textPrimary)),
            Text(_poolLabel(it['pool']), style: GText.caption(c.textSecondary)),
            const SizedBox(height: Gsp.sp3),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Quantity counted', border: OutlineInputBorder()),
              onSubmitted: (v) => Navigator.pop(ctx, double.tryParse(v.trim())),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, double.tryParse(ctrl.text.trim())),
              style: FilledButton.styleFrom(backgroundColor: c.brand, foregroundColor: c.onBrand),
              child: const Text('Save count'),
            ),
          ],
        );
      },
    );
    ctrl.dispose();
    if (counted == null || counted < 0) return;
    // Recorded as the difference from the current record (a movement), so it reaches every PC
    // once and keeps any dispense made meanwhile on another PC.
    final shown = (it['quantityRaw'] ?? 0) as num;
    final delta = counted - shown.toDouble();
    if (delta == 0) return;
    // The difference is taken from the true (below 0) figure, not the displayed 0.
    await StockActions.countDifference(pool, id, delta, name: (it['name'] ?? '').toString());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Count saved: ${_fmtQty(counted)} ${(it['name'] ?? '').toString()}')),
    );
  }

  // ── Tab 3: quarantine ────────────────────────────────────────────────────────

  List<Map<String, dynamic>> _quarantined() =>
      StockRepair.quarantined().where((q) => q['branchId'] == null || _isMyBranch(q['branchId'])).toList();

  bool _isMyBranch(Object? b) => StockPool.normalizeBranch(b?.toString()) == _branch;

  Widget _quarantineTab(GComfortColors c) {
    return ValueListenableBuilder(
      valueListenable: Hive.box(StockRepair.quarantineBox).listenable(),
      builder: (context, _, _) {
        final list = _quarantined();
        if (list.isEmpty) {
          return _empty(c, GIcons.checkCircle, 'Nothing set aside',
              'The one-time repair puts records here that had stock but no name or a wrong camp.');
        }
        return ListView(
          padding: const EdgeInsets.all(Gsp.sp4),
          children: [
            Text(
              'The one-time repair set these aside: they had stock but no medicine name, or a camp '
              'this branch does not have. They are not counted anywhere. If the stock is real, add it '
              'to the right medicine with Add Stock, then remove the entry here.',
              style: GText.body2(c.textSecondary),
            ),
            const SizedBox(height: Gsp.sp3),
            _simpleTable(
              c,
              const ['Record', 'Reason', 'Quantity'],
              [
                for (final q in list)
                  [
                    '${(q['name'] ?? '').toString().trim().isEmpty ? '(no name)' : q['name']} · ${q['medicineId']}',
                    '${q['reason'] ?? ''} (${q['source'] ?? ''})',
                    _fmtQty(q['quantity']),
                  ],
              ],
            ),
            if (widget.canAdjust)
              for (final q in list)
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton.icon(
                    onPressed: () => _dismissQuarantine(q),
                    icon: Icon(GIcons.delete, size: GIconSize.sm, color: c.textSecondary),
                    label: Text('Remove ${q['medicineId']}', style: GText.caption(c.textSecondary)),
                  ),
                ),
          ],
        );
      },
    );
  }

  Future<void> _dismissQuarantine(Map<String, dynamic> q) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this entry?'),
        content: Text('${q['medicineId']} (${_fmtQty(q['quantity'])}) will be removed from this list. '
            'Stock figures do not change.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    final box = Hive.box(StockRepair.quarantineBox);
    final key = box.keys.firstWhere(
      (k) => box.get(k) is Map && (box.get(k) as Map)['medicineId'] == q['medicineId'] && (box.get(k) as Map)['at'] == q['at'],
      orElse: () => null,
    );
    if (key != null) await box.delete(key);
  }

  Widget _empty(GComfortColors c, IconData icon, String title, String body) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gsp.sp8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: GIconSize.xxl, color: c.success),
          const SizedBox(height: Gsp.sp3),
          Text(title, style: GText.h3(c.textPrimary)),
          const SizedBox(height: Gsp.sp1),
          Text(body, textAlign: TextAlign.center, style: GText.body2(c.textSecondary)),
        ]),
      ),
    );
  }
}

class _TabsWithCounts extends StatelessWidget {
  const _TabsWithCounts({required this.needsCount, required this.quarantine});

  final int needsCount;
  final int quarantine;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: TabBar(
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        labelColor: c.brand,
        unselectedLabelColor: c.textSecondary,
        indicatorColor: c.brand,
        labelStyle: GText.body2Bold(c.brand),
        unselectedLabelStyle: GText.body2(c.textSecondary),
        dividerColor: c.border,
        tabs: [
          const Tab(text: 'Medicine ledger'),
          const Tab(text: 'Checks'),
          Tab(text: needsCount == 0 ? 'Needs a count' : 'Needs a count ($needsCount)'),
          Tab(text: quarantine == 0 ? 'Set aside' : 'Set aside ($quarantine)'),
        ],
      ),
    );
  }
}
