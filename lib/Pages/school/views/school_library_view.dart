// lib/pages/school/views/school_library_view.dart
//
// School Library (School ERP plan §3.2, Phase 1). An inventory-style screen:
//   KPI strip  ·  Catalogue | Loans | Members  ·  detail side panels.
// Books are never deleted (unlist / relist). Covers, member profiles and loan
// rules (limits, overdue block, due-date range, fines) live in ../library/.

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../../utils/debounced_box_listenable.dart';
import '../library/library_models.dart';
import '../library/school_library_service.dart';
import '../library/views/library_catalogue.dart';
import '../library/views/library_loans.dart';
import '../library/views/library_members.dart';
import '../library/widgets/library_dialogs.dart';
import '../utils/school_auth_helper.dart';
import '../utils/school_local_storage.dart';
import '../widgets/erp/school_erp.dart';

class SchoolLibraryView extends StatefulWidget {
  final String branchId;
  final String userName;
  final String userRole;

  const SchoolLibraryView({
    super.key,
    required this.branchId,
    this.userName = 'Library Admin',
    this.userRole = 'School Admin',
  });

  @override
  State<SchoolLibraryView> createState() => _SchoolLibraryViewState();
}

enum _Tab { catalogue, loans, members }

class _SchoolLibraryViewState extends State<SchoolLibraryView> {
  late final Future<void> _ready = SchoolLocalStorage.ensureBoxesOpen();
  _Tab _tab = _Tab.catalogue;
  LibraryLoanFilter _loanFilter = LibraryLoanFilter.out;

  /// Adding, editing, unlisting and member access are for Librarian, Principal,
  /// School Admin and executives only. Teachers can browse and issue/return.
  bool get _canManage => SchoolAuthHelper.isAdminOrPrincipal(widget.userRole) || SchoolAuthHelper.isLibrarian(widget.userRole);
  bool get _canIssue => _canManage || SchoolAuthHelper.isTeacher(widget.userRole);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _ready,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final boxes = SchoolLibraryService.watchedBoxes.where(Hive.isBoxOpen).map((b) => DebouncedBoxListenable.shared(Hive.box(b)));
        return ListenableBuilder(
          listenable: Listenable.merge(boxes.toList()),
          builder: (context, _) => _build(context, SchoolLibraryService.snapshot(widget.branchId)),
        );
      },
    );
  }

  Widget _build(BuildContext context, LibrarySnapshot snap) {
    final c = context.comfort;
    final lib = LibraryContext(branchId: widget.branchId, editor: widget.userName, canManage: _canManage, snapshot: snap);
    final now = DateTime.now();
    final listed = snap.books.where((b) => b.isListed).toList();
    final copies = listed.fold<int>(0, (a, b) => a + b.totalCopies);
    final out = snap.loans.where((l) => l.isOut).length;
    final overdue = snap.loans.where((l) => l.isOverdue(now)).length;
    final borrowers = snap.loans.where((l) => l.isOut).map((l) => l.memberId).toSet().length;
    const labels = {_Tab.catalogue: 'Catalogue', _Tab.loans: 'Loans', _Tab.members: 'Members'};
    final body = switch (_tab) {
      _Tab.catalogue => LibraryCatalogueTab(lib: lib),
      _Tab.loans => LibraryLoansTab(lib: lib, initialFilter: _loanFilter),
      _Tab.members => LibraryMembersTab(lib: lib),
    };

    return SchoolErpPage(
      breadcrumbs: const ['School'],
      title: 'Library',
      subtitle: '${listed.length} titles · $copies copies · $out out',
      icon: GIcons.library,
      actions: [
        if (_canManage)
          IconButton(
            tooltip: 'Library settings',
            icon: const Icon(GIcons.settings),
            onPressed: () async {
              final ok = await showLibrarySettingsDialog(context, branchId: widget.branchId, editor: widget.userName, settings: snap.settings);
              if (ok && context.mounted) AppFeedback.success(context, 'Library settings saved');
            },
          ),
        if (_canIssue)
          OutlinedButton.icon(
            icon: const Icon(GIcons.bookIssue),
            label: const Text('Issue book'),
            onPressed: () async {
              final ok = await showLibraryIssueDialog(context, branchId: widget.branchId, editor: widget.userName, snapshot: snap);
              if (ok && context.mounted) AppFeedback.success(context, 'Book issued');
            },
          ),
        if (_canManage)
          FilledButton.icon(
            icon: const Icon(GIcons.add),
            label: const Text('Add book'),
            onPressed: () async {
              final id = await showLibraryBookForm(context, branchId: widget.branchId, editor: widget.userName, snapshot: snap);
              if (id != null && context.mounted) AppFeedback.success(context, 'Book saved');
            },
          ),
      ],
      tabs: SchoolErpTabs(
        labels: [for (final t in _Tab.values) labels[t]!],
        icons: const [GIcons.book, GIcons.bookIssue, GIcons.users],
        counts: [listed.length, out, snap.members.where((m) => !m.isLegacy && !m.inactive).length],
        selected: _tab.index,
        onChanged: (i) => setState(() => _tab = _Tab.values[i]),
      ),
      stats: SchoolErpStatStrip([
        SchoolErpStat(
          label: 'Titles',
          value: GFormat.count(listed.length),
          icon: GIcons.book,
          caption: '${snap.books.length - listed.length} unlisted',
          onTap: () => setState(() => _tab = _Tab.catalogue),
        ),
        SchoolErpStat(label: 'Copies', value: GFormat.count(copies), icon: GIcons.inventory, color: c.chart2, caption: '${copies - out} on the shelf'),
        SchoolErpStat(
          label: 'Out now',
          value: GFormat.count(out),
          icon: GIcons.bookIssue,
          color: c.info,
          caption: '$borrowers ${borrowers == 1 ? 'borrower' : 'borrowers'}',
          onTap: () => setState(() {
            _tab = _Tab.loans;
            _loanFilter = LibraryLoanFilter.out;
          }),
        ),
        SchoolErpStat(
          label: 'Overdue',
          value: GFormat.count(overdue),
          icon: GIcons.overdue,
          color: overdue > 0 ? c.danger : c.success,
          caption: overdue > 0 ? 'Follow up' : 'All on time',
          onTap: () => setState(() {
            _tab = _Tab.loans;
            _loanFilter = LibraryLoanFilter.overdue;
          }),
        ),
        SchoolErpStat(
          label: 'Members',
          value: GFormat.count(snap.members.where((m) => !m.isLegacy && !m.inactive).length),
          icon: GIcons.users,
          color: c.accent,
          caption: '${snap.members.where((m) => m.type == LibraryMemberType.outsider && !m.isLegacy).length} outsiders',
          onTap: () => setState(() => _tab = _Tab.members),
        ),
      ]),
      child: body,
    );
  }
}