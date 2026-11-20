// lib/pages/school/views/school_audit_log_view.dart
//
// Audit log (ERP layout, 2026-11-17): every create / edit / status change /
// payment written by the School store, newest first. Filter by area, person
// and text; click a row to see the before → after values.
// Principal / School Admin / executives only.

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../../utils/debounced_box_listenable.dart';
import '../../../services/local_storage_service.dart';
import '../utils/school_auth_helper.dart';
import '../utils/school_local_storage.dart';
import '../widgets/erp/school_erp.dart';

class SchoolAuditLogView extends StatefulWidget {
  final String branchId;
  final String userRole;

  const SchoolAuditLogView({super.key, required this.branchId, this.userRole = 'School Admin'});

  @override
  State<SchoolAuditLogView> createState() => _SchoolAuditLogViewState();
}

/// Area of an audit action, from its name.
enum _Area {
  all('All'),
  students('Students'),
  daily('Daily log'),
  grades('Grades'),
  library('Library'),
  fees('Fees'),
  staff('Staff'),
  system('System');

  const _Area(this.label);
  final String label;

  static _Area of(String action, String entity) {
    final a = '${action.toUpperCase()} ${entity.toUpperCase()}';
    if (a.contains('STUDENT') || a.contains('PROMOTION')) return students;
    if (a.contains('DAILY') || a.contains('ATTENDANCE') || a.contains('HOLIDAY') || a.contains('PTM') || a.contains('CALENDAR') || a.contains('EVENT')) {
      return daily;
    }
    if (a.contains('GRADE')) return grades;
    if (a.contains('BOOK') || a.contains('LIBRARY') || a.contains('LOAN') || a.contains('MEMBER')) return library;
    if (a.contains('FEE') || a.contains('PAYMENT') || a.contains('RECEIPT')) return fees;
    if (a.contains('TEACHER') || a.contains('STAFF') || a.contains('HOMEROOM')) return staff;
    return system;
  }
}

class _Entry {
  _Entry(this.raw)
      : action = (raw['action'] ?? 'ACTION').toString(),
        user = (raw['user'] ?? 'System').toString(),
        details = (raw['details'] ?? '').toString(),
        at = DateTime.tryParse((raw['timestamp'] ?? '').toString()),
        area = _Area.of((raw['action'] ?? '').toString(), (raw['entity'] ?? '').toString());

  final Map<String, dynamic> raw;
  final String action;
  final String user;
  final String details;
  final DateTime? at;
  final _Area area;

  String get id => (raw['id'] ?? '${action}_${at?.toIso8601String()}').toString();

  /// "STUDENT_STATUS" → "Student status".
  String get actionLabel {
    final s = action.toLowerCase().replaceAll('_', ' ').trim();
    return s.isEmpty ? 'Action' : s[0].toUpperCase() + s.substring(1);
  }
}

class _SchoolAuditLogViewState extends State<SchoolAuditLogView> {
  final _search = TextEditingController();
  _Area _area = _Area.all;
  String _user = 'All';
  String? _selectedId;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (SchoolAuthHelper.isTeacher(widget.userRole)) {
      return const SchoolErpPage(
        breadcrumbs: ['School', 'Administration'],
        title: 'Audit log',
        icon: GIcons.audit,
        child: AppEmptyState(
          icon: GIcons.lock,
          title: 'Principal and School Admin only',
          subtitle: 'The audit log holds administrative records.',
        ),
      );
    }
    return FutureBuilder<void>(
      future: SchoolLocalStorage.ensureBoxesOpen(),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        return ValueListenableBuilder<Box>(
          valueListenable: DebouncedBoxListenable.shared(Hive.box(LocalStorageService.schoolAuditLogsBox)),
          builder: (context, _, _) => _build(context, SchoolLocalStorage.getAuditLogsCached(widget.branchId).map(_Entry.new).toList()),
        );
      },
    );
  }

  Widget _build(BuildContext context, List<_Entry> all) {
    final c = context.comfort;
    final now = DateTime.now();
    final q = _search.text.trim().toLowerCase();
    final users = {for (final e in all) e.user}.toList()..sort();
    final rows = all.where((e) {
      if (_area != _Area.all && e.area != _area) return false;
      if (_user != 'All' && e.user != _user) return false;
      if (q.isEmpty) return true;
      return e.details.toLowerCase().contains(q) || e.action.toLowerCase().contains(q) || e.user.toLowerCase().contains(q);
    }).toList();
    final today = all.where((e) => e.at != null && e.at!.year == now.year && e.at!.month == now.month && e.at!.day == now.day).length;
    final week = all.where((e) => e.at != null && now.difference(e.at!).inDays < 7).length;
    final conflicts = all.where((e) => e.action.contains('CONFLICT')).length;
    _Entry? selected;
    for (final e in all) {
      if (e.id == _selectedId) selected = e;
    }

    final table = SchoolErpTable<_Entry>(
      rows: rows,
      rowKey: (e) => e.id,
      selectedKey: _selectedId,
      onRowTap: (e) => SchoolErp.wide(context) ? setState(() => _selectedId = e.id) : _showSheet(e),
      minWidth: 760,
      empty: AppEmptyState(
        icon: all.isEmpty ? GIcons.history : GIcons.searchOff,
        title: all.isEmpty ? 'No activity recorded yet' : 'Nothing matches',
        subtitle: all.isEmpty ? 'Admissions, daily logs, library and fee actions appear here.' : 'Try another area, person or search.',
      ),
      columns: [
        SchoolErpColumn(
          label: 'When',
          width: 150,
          sortValue: (e) => e.at?.toIso8601String() ?? '',
          cell: (e) => SchoolErpCell.text(context, e.at == null ? '' : DateFormat('d MMM yyyy, h:mm a').format(e.at!)),
        ),
        SchoolErpColumn(label: 'Area', width: 100, sortValue: (e) => e.area.index, cell: (e) => SchoolErpCell.text(context, e.area.label, muted: true)),
        SchoolErpColumn(
          label: 'Action',
          flex: 3,
          sortValue: (e) => e.action,
          cell: (e) => AppChip(
            label: e.actionLabel,
            state: e.action.contains('CONFLICT')
                ? AppChipState.warning
                : (e.action.contains('VOID') || e.action.contains('REMOVED') || e.action.contains('UNLIST'))
                    ? AppChipState.danger
                    : AppChipState.info,
          ),
        ),
        SchoolErpColumn(label: 'By', flex: 2, sortValue: (e) => e.user.toLowerCase(), cell: (e) => SchoolErpCell.text(context, e.user)),
        SchoolErpColumn(label: 'Details', flex: 6, cell: (e) => SchoolErpCell.text(context, e.details)),
      ],
    );

    return SchoolErpPage(
      breadcrumbs: const ['School', 'Administration'],
      title: 'Audit log',
      subtitle: 'Who changed what, and when',
      icon: GIcons.audit,
      tabs: SchoolErpTabs(
        labels: [for (final a in _Area.values) a.label],
        counts: [for (final a in _Area.values) a == _Area.all ? all.length : all.where((e) => e.area == a).length],
        selected: _area.index,
        onChanged: (i) => setState(() => _area = _Area.values[i]),
      ),
      stats: SchoolErpStatStrip([
        SchoolErpStat(label: 'Today', value: GFormat.count(today), icon: GIcons.time),
        SchoolErpStat(label: 'Last 7 days', value: GFormat.count(week), icon: GIcons.calendar, color: c.chart2),
        SchoolErpStat(label: 'People', value: GFormat.count(users.length), icon: GIcons.users, color: c.info),
        SchoolErpStat(
          label: 'Sync conflicts',
          value: GFormat.count(conflicts),
          icon: GIcons.syncProblem,
          color: conflicts > 0 ? c.warning : c.success,
          caption: conflicts > 0 ? 'A newer cloud copy replaced local edits' : 'None',
        ),
      ]),
      child: SchoolErpMasterDetail(
        master: SchoolErpCard(
          toolbar: SchoolErpToolbar(
            search: _search,
            searchHint: 'Search details, action or person',
            onSearch: (_) => setState(() {}),
            filters: [
              SchoolErpFilter<String>(
                label: 'Person',
                value: _user,
                width: 180,
                options: {'All': 'Everyone', for (final u in users) u: u},
                onChanged: (v) => setState(() => _user = v),
              ),
            ],
            trailing: [Center(child: Text('${rows.length} entries', style: GText.caption(c.textMuted)))],
          ),
          child: table,
        ),
        detail: selected == null ? null : _AuditPanel(entry: selected, onClose: () => setState(() => _selectedId = null)),
      ),
    );
  }

  void _showSheet(_Entry e) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => SizedBox(height: MediaQuery.sizeOf(context).height * 0.7, child: _AuditPanel(entry: e)),
      );
}

class _AuditPanel extends StatelessWidget {
  const _AuditPanel({required this.entry, this.onClose});
  final _Entry entry;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final before = entry.raw['before'] is Map ? Map<String, dynamic>.from(entry.raw['before'] as Map) : const <String, dynamic>{};
    final after = entry.raw['after'] is Map ? Map<String, dynamic>.from(entry.raw['after'] as Map) : const <String, dynamic>{};
    final keys = {...before.keys, ...after.keys}.toList()..sort();
    return SchoolErpDetailPanel(
      onClose: onClose,
      leading: const GModuleTile(icon: GIcons.audit, size: 40),
      title: entry.actionLabel,
      subtitle: entry.at == null ? null : DateFormat('EEEE d MMM yyyy, h:mm a').format(entry.at!),
      chips: [AppChip(label: entry.area.label, state: AppChipState.neutral), AppChip(label: entry.user, state: AppChipState.info, icon: GIcons.profile)],
      children: [
        SchoolErpFacts(title: 'Record', facts: [
          ('Details', entry.details),
          if ((entry.raw['entity'] ?? '').toString().isNotEmpty) ('Type', entry.raw['entity'].toString()),
          if ((entry.raw['entityId'] ?? '').toString().isNotEmpty) ('Record id', entry.raw['entityId'].toString()),
        ]),
        Padding(
          padding: const EdgeInsets.only(top: Gsp.sp4, bottom: Gsp.sp2),
          child: Text('CHANGES', style: GText.overline(c.textMuted)),
        ),
        if (keys.isEmpty) Text('No field-by-field change was recorded for this action.', style: GText.body2(c.textMuted)),
        if (keys.isNotEmpty)
          Container(
            decoration: BoxDecoration(borderRadius: SchoolErp.radius, border: Border.all(color: c.border)),
            child: Column(children: [
              Container(
                color: c.surfaceSunken,
                padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3, vertical: Gsp.sp2),
                child: Row(children: [
                  Expanded(flex: 3, child: Text('FIELD', style: GText.overline(c.textMuted))),
                  Expanded(flex: 4, child: Text('BEFORE', style: GText.overline(c.textMuted))),
                  Expanded(flex: 4, child: Text('AFTER', style: GText.overline(c.textMuted))),
                ]),
              ),
              for (final k in keys)
                Container(
                  decoration: BoxDecoration(border: Border(top: BorderSide(color: c.border))),
                  padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3, vertical: Gsp.sp2),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(flex: 3, child: Text(k, style: GText.caption(c.textSecondary))),
                    Expanded(flex: 4, child: Text('${before[k] ?? '—'}', style: GText.body2(c.danger))),
                    Expanded(flex: 4, child: Text('${after[k] ?? '—'}', style: GText.body2(c.success))),
                  ]),
                ),
            ]),
          ),
      ],
    );
  }
}
