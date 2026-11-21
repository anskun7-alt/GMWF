// lib/pages/dispensary/dispensar/expiry_page.dart
//
// Med Inventory › Expiry (2026-11-21): one place to see what has expired or is about to,
// and clear it in a few taps.
//
//   • Tiles: Expired · Within 1 month · Within 3 months · All — tap to filter.
//   • Table: one row per batch with stock (expired first), with Remove and Fix expiry.
//   • Bulk: tick rows, or "Remove all expired".
//   • A dispenser's taps become requests; a Supervisor / allowed Doctor / Branch Manager /
//     HQ Manager / Chairman approves them in the "Waiting for approval" box on this screen
//     (or on the Requests page). Everyone else changes stock directly. All of it is logged.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';

import 'package:gmwf/design/design_system.dart';
import 'package:gmwf/services/stock/expiry_service.dart';
import 'package:gmwf/services/stock/stock_ledger.dart';
import 'package:gmwf/services/stock/stock_pool.dart';
import 'package:gmwf_ui/gmwf_ui.dart' show GEmptyIllustration, GEmptyIllustrationKind, GIcons;

class ExpiryPage extends StatefulWidget {
  /// Pools of the branch / camp picked in the top bar.
  final List<StockPool> Function() pools;
  final String branchId;

  /// Dispenser: actions become requests for approval.
  final bool needsApproval;

  const ExpiryPage({
    super.key,
    required this.pools,
    required this.branchId,
    required this.needsApproval,
  });

  @override
  State<ExpiryPage> createState() => _ExpiryPageState();
}

enum _Filter { expired, oneMonth, threeMonths, all }

class _ExpiryPageState extends State<ExpiryPage> {
  _Filter _filter = _Filter.expired;
  String _query = '';
  final Set<String> _selected = {};
  bool _busy = false;
  List<ExpiryRow> _rows = const [];
  List<Map<String, dynamic>> _pending = const [];
  StreamSubscription? _stockSub;
  StreamSubscription? _reqSub;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _reload();
    _stockSub = StockLedger.changes.listen((_) => _scheduleReload());
    unawaited(() async {
      const name = ExpiryService.requestsBox;
      final box = Hive.isBoxOpen(name) ? Hive.box(name) : await Hive.openBox(name);
      if (!mounted) return;
      _reqSub = box.watch().listen((_) => _scheduleReload());
      _reload();
    }());
  }

  @override
  void didUpdateWidget(covariant ExpiryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.branchId != widget.branchId) {
      _selected.clear();
      _reload();
    }
  }

  @override
  void dispose() {
    _stockSub?.cancel();
    _reqSub?.cancel();
    _debounce?.cancel();
    super.dispose();
  }

  void _scheduleReload() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _reload);
  }

  void _reload() {
    if (!mounted) return;
    final pools = widget.pools();
    setState(() {
      _rows = ExpiryService.rows(pools);
      _pending = ExpiryService.pendingRequests(branchId: widget.branchId);
      _selected.removeWhere((k) => !_rows.any((r) => r.key == k));
    });
  }

  bool _matches(ExpiryRow r) {
    switch (_filter) {
      case _Filter.expired:
        if (r.status != ExpiryStatus.expired) return false;
      case _Filter.oneMonth:
        if (r.status != ExpiryStatus.withinOneMonth) return false;
      case _Filter.threeMonths:
        if (r.status != ExpiryStatus.withinOneMonth && r.status != ExpiryStatus.withinThreeMonths) return false;
      case _Filter.all:
        break;
    }
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return '${r.name} ${r.barcode} ${r.type} ${r.dose}'.toLowerCase().contains(q);
  }

  /// Batches that already have a pending request (so nobody asks twice).
  Set<String> get _pendingKeys => {
        for (final req in _pending)
          for (final it in (req['items'] is List ? req['items'] as List : const []))
            if (it is Map) '${it['pool']}|${it['medicineId']}',
      };

  // ── Actions ──────────────────────────────────────────────────────────────────

  Future<void> _remove(List<ExpiryRow> rows) async {
    if (rows.isEmpty || _busy) return;
    final units = rows.fold<double>(0, (a, r) => a + r.quantity);
    final reason = await _askReason(
      title: 'Remove ${rows.length} expired batch${rows.length == 1 ? '' : 'es'}?',
      body: '${_fmt(units)} units will be written down to 0 and hidden on every PC. '
          'Their history stays in the log.',
      options: const ['Expired', 'Damaged', 'Recalled'],
      confirm: widget.needsApproval ? 'Send for approval' : 'Remove',
      danger: true,
    );
    if (reason == null) return;
    await _run([for (final r in rows) ExpiryAction.fromRow(r, 'writeoff')], reason);
  }

  Future<void> _fixExpiry(ExpiryRow r) async {
    if (_busy) return;
    final now = DateTime.now();
    final initial = r.month ?? DateTime(now.year + 1, now.month, 1);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(DateTime(2020)) ? DateTime(2020) : initial,
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime(now.year + 10, 12, 31),
      initialDatePickerMode: DatePickerMode.year,
      helpText: 'Correct expiry month (day is set to 01)',
    );
    if (picked == null || !mounted) return;
    final month = DateTime(picked.year, picked.month, 1);
    final reason = await _askReason(
      title: 'Change expiry of ${r.name}?',
      body: '${r.expiryLabel}  →  ${DateFormat('MMM yyyy').format(month)}',
      options: const ['Typed wrong', 'Checked the box again'],
      confirm: widget.needsApproval ? 'Send for approval' : 'Save',
    );
    if (reason == null) return;
    await _run([ExpiryAction.fromRow(r, 'fix_expiry', newExpiry: month)], reason);
  }

  Future<void> _run(List<ExpiryAction> actions, String reason) async {
    setState(() => _busy = true);
    try {
      if (widget.needsApproval) {
        final branch = actions.first.pool.branch;
        await ExpiryService.sendRequest(branchId: branch, actions: actions, reason: reason);
        _toast('Sent for approval. A supervisor will approve it.');
      } else {
        final n = await ExpiryService.applyDirect(actions, reason: reason);
        _toast('Done: $n batch${n == 1 ? '' : 'es'} updated and logged.');
      }
      _selected.clear();
    } catch (e) {
      _toast('Could not save: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
      _reload();
    }
  }

  Future<void> _decide(Map<String, dynamic> req, bool approve) async {
    String? note;
    if (!approve) {
      note = await _askReason(
        title: 'Reject this request?',
        body: (req['summary'] ?? '').toString(),
        options: const ['Not expired', 'Wrong batch', 'Count again first'],
        confirm: 'Reject',
        danger: true,
      );
      if (note == null) return;
    }
    setState(() => _busy = true);
    final err = await ExpiryService.decide(req, approve: approve, note: note);
    if (!mounted) return;
    setState(() => _busy = false);
    _toast(err ?? (approve ? 'Approved and applied.' : 'Rejected.'), error: err != null);
    _reload();
  }

  Future<String?> _askReason({
    required String title,
    required String body,
    required List<String> options,
    required String confirm,
    bool danger = false,
  }) async {
    String? picked = options.first;
    final note = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          final c = ctx.comfort;
          return AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: 440,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(body, style: TextStyle(fontSize: 13, color: c.textSecondary)),
                const SizedBox(height: 14),
                Text('Reason', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: c.textSecondary)),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final o in options)
                    ChoiceChip(label: Text(o), selected: picked == o, onSelected: (_) => setDlg(() => picked = o)),
                ]),
                const SizedBox(height: 10),
                TextField(
                  controller: note,
                  decoration: const InputDecoration(labelText: 'Note (optional)', isDense: true, border: OutlineInputBorder()),
                ),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              FilledButton(
                style: danger ? FilledButton.styleFrom(backgroundColor: c.danger, foregroundColor: c.onBrand) : null,
                onPressed: picked == null
                    ? null
                    : () {
                        final n = note.text.trim();
                        Navigator.pop(ctx, n.isEmpty ? picked : '$picked: $n');
                      },
                child: Text(confirm),
              ),
            ],
          );
        },
      ),
    );
    note.dispose();
    return result;
  }

  void _toast(String msg, {bool error = false}) {
    if (!mounted) return;
    final c = context.comfort;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? c.danger : null,
      behavior: SnackBarBehavior.floating,
    ));
  }

  static String _fmt(double v) => v == v.roundToDouble() ? NumberFormat('#,###').format(v) : v.toStringAsFixed(1);

  // ── UI ───────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final expired = _rows.where((r) => r.status == ExpiryStatus.expired).toList();
    final one = _rows.where((r) => r.status == ExpiryStatus.withinOneMonth).toList();
    final three = _rows.where((r) => r.status == ExpiryStatus.withinThreeMonths).toList();
    final visible = _rows.where(_matches).toList();
    final canApprove = ExpiryService.canApprove(branchId: widget.branchId);
    final pendingKeys = _pendingKeys;

    return Container(
      color: c.background,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Expiry', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: c.textPrimary)),
                  const SizedBox(height: 2),
                  Text(
                    'Remove expired medicines and fix wrongly typed dates. A medicine expires on the 1st of the month shown.',
                    style: TextStyle(fontSize: 12.5, color: c.textSecondary),
                  ),
                ]),
              ),
              if (widget.needsApproval)
                _pill(c, 'Changes need approval', c.info, c.infoBg, GIcons.lock),
            ]),
            const SizedBox(height: 12),
            Wrap(spacing: 10, runSpacing: 10, children: [
              _tile(c, _Filter.expired, 'Expired', expired, c.danger, c.dangerBg, GIcons.delete),
              _tile(c, _Filter.oneMonth, 'Within 1 month', one, c.warning, c.warningBg, GIcons.calendar),
              _tile(c, _Filter.threeMonths, 'Within 3 months', [...one, ...three], c.info, c.infoBg, GIcons.event),
              _tile(c, _Filter.all, 'All batches', _rows, c.brand, c.brandSoft, GIcons.inventory),
            ]),
          ]),
        ),
        if (_pending.isNotEmpty) _pendingBox(c, canApprove),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(children: [
            Expanded(
              child: SizedBox(
                height: 40,
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    hintText: 'Search medicine or barcode',
                    prefixIcon: Icon(GIcons.search, size: 18, color: c.textMuted),
                    isDense: true,
                    filled: true,
                    fillColor: c.surface,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: c.border)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: c.border)),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            if (_selected.isNotEmpty)
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: c.danger, foregroundColor: c.onBrand),
                onPressed: _busy ? null : () => _remove(_rows.where((r) => _selected.contains(r.key)).toList()),
                icon: const Icon(GIcons.delete, size: 17),
                label: Text('Remove selected (${_selected.length})'),
              )
            else if (expired.isNotEmpty)
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: c.danger, side: BorderSide(color: c.danger)),
                onPressed: _busy
                    ? null
                    : () => _remove(expired.where((r) => !pendingKeys.contains(r.key)).toList()),
                icon: const Icon(GIcons.delete, size: 17),
                label: Text('Remove all expired (${expired.length})'),
              ),
          ]),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: visible.isEmpty ? _empty(c) : _table(c, visible, pendingKeys),
          ),
        ),
      ]),
    );
  }

  Widget _pill(GComfortColors c, String text, Color fg, Color bg, IconData icon) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20), border: Border.all(color: fg.withValues(alpha: 0.3))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fg)),
        ]),
      );

  Widget _tile(GComfortColors c, _Filter f, String label, List<ExpiryRow> rows, Color fg, Color bg, IconData icon) {
    final selected = _filter == f;
    final units = rows.fold<double>(0, (a, r) => a + r.quantity);
    return InkWell(
      onTap: () => setState(() {
        _filter = f;
        _selected.clear();
      }),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 200,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? bg : c.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? fg : c.border, width: selected ? 1.6 : 1),
        ),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 18, color: fg),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.textSecondary)),
              const SizedBox(height: 2),
              Text('${rows.length}', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: fg)),
              Text('${_fmt(units)} units', style: TextStyle(fontSize: 11, color: c.textMuted)),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _pendingBox(GComfortColors c, bool canApprove) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.infoBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.info.withValues(alpha: 0.3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(GIcons.waiting, size: 16, color: c.info),
          const SizedBox(width: 6),
          Text('Waiting for approval (${_pending.length})',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: c.info)),
        ]),
        const SizedBox(height: 8),
        for (final req in _pending.take(5))
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(10), border: Border.all(color: c.border)),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text((req['summary'] ?? 'Expiry request').toString(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: c.textPrimary)),
                  const SizedBox(height: 2),
                  Text(
                    'By ${req['requestedByName'] ?? 'dispenser'} · ${_ago(req['requestedAt'])}'
                    '${(req['reason'] ?? '').toString().isNotEmpty ? ' · ${req['reason']}' : ''}',
                    style: TextStyle(fontSize: 11.5, color: c.textMuted),
                  ),
                ]),
              ),
              if (canApprove) ...[
                TextButton(onPressed: _busy ? null : () => _decide(req, false), child: const Text('Reject')),
                const SizedBox(width: 4),
                FilledButton(onPressed: _busy ? null : () => _decide(req, true), child: const Text('Approve')),
              ] else
                Text('Waiting', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: c.info)),
            ]),
          ),
        if (_pending.length > 5)
          Text('+${_pending.length - 5} more on the Requests page', style: TextStyle(fontSize: 11.5, color: c.textMuted)),
      ]),
    );
  }

  static String _ago(Object? iso) {
    final t = DateTime.tryParse(iso?.toString() ?? '');
    if (t == null) return '';
    final d = DateTime.now().difference(t.toLocal());
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return DateFormat('d MMM').format(t.toLocal());
  }

  Widget _empty(GComfortColors c) {
    final text = switch (_filter) {
      _Filter.expired => 'Nothing has expired.',
      _Filter.oneMonth => 'Nothing expires next month.',
      _Filter.threeMonths => 'Nothing expires in the next 3 months.',
      _Filter.all => 'No batches with stock here.',
    };
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        GEmptyIllustration(
          _query.isNotEmpty ? GEmptyIllustrationKind.search : GEmptyIllustrationKind.inventory,
          size: 140,
        ),
        const SizedBox(height: 12),
        Text(_query.isNotEmpty ? 'No medicine matches your search.' : text,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.textPrimary)),
      ]),
    );
  }

  Widget _table(GComfortColors c, List<ExpiryRow> rows, Set<String> pendingKeys) {
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 820;
      const chkW = 40.0, idxW = 40.0, barW = 72.0, expW = 100.0, leftW = 112.0, qtyW = 76.0;
      final actW = wide ? 210.0 : 96.0;
      final selectable = rows.where((r) => r.status == ExpiryStatus.expired && !pendingKeys.contains(r.key)).toList();
      final allSelected = selectable.isNotEmpty && selectable.every((r) => _selected.contains(r.key));

      TextStyle head() => TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.4, color: c.textMuted);

      final header = Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(color: c.surfaceSunken, border: Border(bottom: BorderSide(color: c.border))),
        child: Row(children: [
          SizedBox(
            width: chkW,
            child: selectable.isEmpty
                ? null
                : Checkbox(
                    value: allSelected,
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        _selected.addAll(selectable.map((r) => r.key));
                      } else {
                        _selected.removeAll(selectable.map((r) => r.key));
                      }
                    }),
                  ),
          ),
          SizedBox(width: idxW, child: Text('#', style: head(), textAlign: TextAlign.center)),
          if (wide) SizedBox(width: barW, child: Text('BARCODE', style: head())),
          Expanded(child: Text('MEDICINE', style: head())),
          SizedBox(width: expW, child: Text('EXPIRY', style: head())),
          SizedBox(width: leftW, child: Text('STATUS', style: head())),
          SizedBox(width: qtyW, child: Text('QTY', style: head(), textAlign: TextAlign.end)),
          SizedBox(width: actW),
        ]),
      );

      Widget row(int i) {
        final r = rows[i];
        final isPending = pendingKeys.contains(r.key);
        final canSelect = r.status == ExpiryStatus.expired && !isPending;
        final sel = _selected.contains(r.key);
        final (Color fg, Color bg, String label) = switch (r.status) {
          ExpiryStatus.expired => (c.danger, c.dangerBg, 'Expired'),
          ExpiryStatus.withinOneMonth => (c.warning, c.warningBg, 'Next month'),
          ExpiryStatus.withinThreeMonths => (c.info, c.infoBg, 'In ${r.monthsLeft} months'),
          ExpiryStatus.later => (c.success, c.successBg, 'In ${r.monthsLeft} months'),
          ExpiryStatus.noExpiry => (c.textMuted, c.surfaceSunken, 'No expiry'),
        };
        return Container(
          constraints: const BoxConstraints(minHeight: 50),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          decoration: BoxDecoration(
            color: sel ? c.dangerBg : (i.isEven ? c.surface : c.surfaceSunken.withValues(alpha: 0.45)),
            border: Border(bottom: BorderSide(color: c.border.withValues(alpha: 0.6))),
          ),
          child: Row(children: [
            SizedBox(
              width: chkW,
              child: canSelect
                  ? Checkbox(
                      value: sel,
                      onChanged: (v) => setState(() => v == true ? _selected.add(r.key) : _selected.remove(r.key)),
                    )
                  : null,
            ),
            SizedBox(
              width: idxW,
              child: Text('${i + 1}',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: c.textMuted, fontFeatures: const [FontFeature.tabularFigures()])),
            ),
            if (wide)
              SizedBox(
                width: barW,
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: c.brandSoft,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: c.brand.withValues(alpha: 0.3)),
                    ),
                    child: Text(r.barcode.isEmpty ? '—' : r.barcode,
                        style: TextStyle(fontFamily: 'monospace', fontSize: 12, fontWeight: FontWeight.w800, color: c.brandStrong)),
                  ),
                ),
              ),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(r.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: c.textPrimary)),
                Text(
                  [if (r.dose.isNotEmpty) r.dose, if (r.type.isNotEmpty) r.type, if (!wide && r.barcode.isNotEmpty) '#${r.barcode}'].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: c.textSecondary),
                ),
              ]),
            ),
            SizedBox(
              width: expW,
              child: Text(r.expiryLabel,
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: fg == c.textMuted ? c.textMuted : c.textPrimary)),
            ),
            SizedBox(
              width: leftW,
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20), border: Border.all(color: fg.withValues(alpha: 0.35))),
                  child: Text(isPending ? 'Request sent' : label,
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: isPending ? c.info : fg)),
                ),
              ),
            ),
            SizedBox(
              width: qtyW,
              child: Text(_fmt(r.quantity),
                  textAlign: TextAlign.end,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: c.textPrimary, fontFeatures: const [FontFeature.tabularFigures()])),
            ),
            SizedBox(
              width: actW,
              child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                if (wide) ...[
                  TextButton.icon(
                    onPressed: _busy || isPending ? null : () => _fixExpiry(r),
                    icon: const Icon(GIcons.calendar, size: 16),
                    label: const Text('Fix expiry'),
                  ),
                  if (r.status == ExpiryStatus.expired)
                    TextButton.icon(
                      style: TextButton.styleFrom(foregroundColor: c.danger),
                      onPressed: _busy || isPending ? null : () => _remove([r]),
                      icon: const Icon(GIcons.delete, size: 16),
                      label: const Text('Remove'),
                    ),
                ] else ...[
                  IconButton(
                    tooltip: 'Fix expiry',
                    onPressed: _busy || isPending ? null : () => _fixExpiry(r),
                    icon: Icon(GIcons.calendar, size: 18, color: c.brand),
                  ),
                  if (r.status == ExpiryStatus.expired)
                    IconButton(
                      tooltip: 'Remove',
                      onPressed: _busy || isPending ? null : () => _remove([r]),
                      icon: Icon(GIcons.delete, size: 18, color: c.danger),
                    ),
                ],
              ]),
            ),
          ]),
        );
      }

      return Container(
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          header,
          Expanded(child: ListView.builder(itemCount: rows.length, itemBuilder: (_, i) => row(i))),
        ]),
      );
    });
  }
}
