// lib/pages/school/library/views/library_members.dart
//
// Members tab on the School ERP kit: every borrower (students and teachers
// come from their records, outsiders are library members of their own) in a
// dense sortable grid, with the member record panel on the right: contact
// details, books out, overdue, history, fines and access settings.

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';

import '../../widgets/erp/school_erp.dart';
import '../library_models.dart';
import '../library_rules.dart';
import '../school_library_service.dart';
import '../widgets/library_dialogs.dart';
import '../widgets/library_widgets.dart';
import 'library_catalogue.dart';

enum _MemberFilter { withBooks, all, students, teachers, outsiders, blocked, unlinked }

class LibraryMembersTab extends StatefulWidget {
  const LibraryMembersTab({super.key, required this.lib});
  final LibraryContext lib;

  @override
  State<LibraryMembersTab> createState() => _LibraryMembersTabState();
}

class _LibraryMembersTabState extends State<LibraryMembersTab> {
  final _search = TextEditingController();
  _MemberFilter _filter = _MemberFilter.withBooks;
  String? _selectedId;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(LibraryMember m, _MemberFilter f, LibrarySnapshot s) => switch (f) {
        _MemberFilter.withBooks => s.openLoansOfMember(m.id).isNotEmpty,
        _MemberFilter.all => !m.inactive || s.openLoansOfMember(m.id).isNotEmpty,
        _MemberFilter.students => m.type == LibraryMemberType.student && !m.isLegacy && !m.inactive,
        _MemberFilter.teachers => m.type == LibraryMemberType.teacher && !m.isLegacy && !m.inactive,
        _MemberFilter.outsiders => m.type == LibraryMemberType.outsider && !m.isLegacy,
        _MemberFilter.blocked => m.blocked,
        _MemberFilter.unlinked => m.isLegacy,
      };

  String _label(_MemberFilter f) => switch (f) {
        _MemberFilter.withBooks => 'Have books',
        _MemberFilter.all => 'All members',
        _MemberFilter.students => 'Students',
        _MemberFilter.teachers => 'Teachers',
        _MemberFilter.outsiders => 'Outsiders',
        _MemberFilter.blocked => 'Blocked',
        _MemberFilter.unlinked => 'Unlinked',
      };

  void _open(LibraryMember m) {
    if (SchoolErp.wide(context)) return setState(() => _selectedId = m.id);
    libraryOpenSheet(context, (scroll) => LibraryMemberPanel(lib: widget.lib, memberId: m.id, scrollController: scroll));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final snap = widget.lib.snapshot;
    final now = DateTime.now();
    final q = _search.text.trim().toLowerCase();
    int overdueOf(LibraryMember m) => snap.openLoansOfMember(m.id).where((l) => l.isOverdue(now)).length;
    final members = snap.members
        .where((m) => _matches(m, _filter, snap))
        .where((m) => q.isEmpty || m.name.toLowerCase().contains(q) || m.reference.toLowerCase().contains(q) || m.phone.contains(q) || m.detail.toLowerCase().contains(q))
        .toList()
      ..sort((a, b) {
        final oa = overdueOf(a), ob = overdueOf(b);
        if (oa != ob) return ob.compareTo(oa);
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    final selected = _selectedId == null ? null : snap.member(_selectedId!);

    final toolbar = SchoolErpToolbar(
      search: _search,
      searchHint: 'Name, admission no., CNIC or phone',
      onSearch: (_) => setState(() {}),
      filters: [
        SchoolErpFilter<_MemberFilter>(
          label: 'Show',
          value: _filter,
          width: 180,
          options: {
            for (final f in _MemberFilter.values)
              if (f != _MemberFilter.unlinked || snap.members.any((m) => m.isLegacy))
                f: '${_label(f)} (${snap.members.where((m) => _matches(m, f, snap)).length})',
          },
          onChanged: (v) => setState(() => _filter = v),
        ),
      ],
      trailing: [
        Center(child: Text('${members.length} ${members.length == 1 ? 'member' : 'members'}', style: GText.caption(c.textMuted))),
        if (widget.lib.canManage)
          OutlinedButton.icon(
            icon: const Icon(GIcons.memberAdd, size: 16),
            label: const Text('Add outsider'),
            onPressed: () async {
              final id = await showLibraryOutsiderDialog(context, branchId: widget.lib.branchId, editor: widget.lib.editor);
              if (id == null || !context.mounted) return;
              setState(() {
                _filter = _MemberFilter.outsiders;
                if (SchoolErp.wide(context)) _selectedId = id;
              });
              AppFeedback.success(context, 'Member added');
            },
          ),
      ],
    );

    final table = SchoolErpTable<LibraryMember>(
      rows: members,
      rowKey: (m) => m.id,
      selectedKey: _selectedId,
      onRowTap: _open,
      minWidth: 760,
      empty: AppEmptyState(
        icon: GIcons.users,
        title: _filter == _MemberFilter.withBooks ? 'Nobody has a book right now' : 'No members match',
        subtitle: _filter == _MemberFilter.withBooks ? 'Choose "All members" to see everyone.' : null,
      ),
      columns: [
        SchoolErpColumn(
          label: 'Member',
          flex: 5,
          sortValue: (m) => m.name.toLowerCase(),
          cell: (m) => SchoolErpCell.primary(context, m.name, sub: m.reference, leading: LibraryMemberAvatar(member: m, size: 28)),
        ),
        SchoolErpColumn(
          label: 'Type',
          width: 130,
          sortValue: (m) => m.isLegacy ? 9 : m.type.index,
          cell: (m) => LibraryMemberTypeChip(m),
        ),
        SchoolErpColumn(
          label: 'Class / detail',
          flex: 3,
          hideBelow: 900,
          sortValue: (m) => m.detail.toLowerCase(),
          cell: (m) => SchoolErpCell.text(context, m.detail),
        ),
        SchoolErpColumn(
          label: 'Phone',
          flex: 2,
          hideBelow: 1150,
          cell: (m) => SchoolErpCell.mono(context, m.phone, color: m.phone.isEmpty ? c.textMuted : null),
        ),
        SchoolErpColumn(
          label: 'Out',
          width: 56,
          numeric: true,
          sortValue: (m) => snap.openLoansOfMember(m.id).length,
          cell: (m) {
            final n = snap.openLoansOfMember(m.id).length;
            return SchoolErpCell.mono(context, n == 0 ? '—' : '$n', color: n == 0 ? c.textMuted : null);
          },
        ),
        SchoolErpColumn(
          label: 'Overdue',
          width: 72,
          numeric: true,
          sortValue: (m) => overdueOf(m),
          cell: (m) {
            final n = overdueOf(m);
            return SchoolErpCell.mono(context, n == 0 ? '—' : '$n', color: n == 0 ? c.textMuted : c.danger);
          },
        ),
      ],
    );

    return SchoolErpMasterDetail(
      master: SchoolErpCard(toolbar: toolbar, child: table),
      detail: selected == null
          ? null
          : LibraryMemberPanel(lib: widget.lib, memberId: selected.id, onClose: () => setState(() => _selectedId = null)),
    );
  }
}

// ── Member record panel ─────────────────────────────────────────────────────

class LibraryMemberPanel extends StatelessWidget {
  const LibraryMemberPanel({super.key, required this.lib, required this.memberId, this.onClose, this.scrollController});
  final LibraryContext lib;
  final String memberId;
  final VoidCallback? onClose;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final sheet = scrollController != null;
    final snap = sheet ? SchoolLibraryService.snapshot(lib.branchId) : lib.snapshot;
    final c = context.comfort;
    final m = snap.member(memberId);
    if (m == null) return const LibraryPanel(child: AppEmptyState(icon: GIcons.searchOff, title: 'Member not found', compact: true));

    final now = DateTime.now();
    final loans = snap.loansOfMember(m.id);
    final open = loans.where((l) => l.isOut).toList()..sort((a, b) => (a.dueDate ?? now).compareTo(b.dueDate ?? now));
    final closed = loans.where((l) => !l.isOut).toList();
    final overdue = open.where((l) => l.isOverdue(now)).length;
    final fines = loans.fold<int>(0, (a, l) => a + l.fine);
    final limit = LibraryRules.limitFor(m, snap.settings);
    final canBorrow = !m.blocked && !m.inactive && !m.isLegacy;

    Future<void> done() async {
      if (sheet && context.mounted) Navigator.of(context).pop();
    }

    Widget figure(String label, String value, Color color) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3, vertical: Gsp.sp2),
            decoration: BoxDecoration(borderRadius: SchoolErp.radius, border: Border.all(color: c.border)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(value, style: GText.h3(color)),
              Text(label, style: GText.caption(c.textMuted)),
            ]),
          ),
        );

    return SchoolErpDetailPanel(
      title: m.name,
      subtitle: m.reference.isEmpty ? null : m.reference,
      leading: LibraryMemberAvatar(member: m, size: 48),
      chips: [LibraryMemberTypeChip(m)],
      onClose: onClose,
      scrollController: scrollController,
      actions: [
        if (canBorrow)
          FilledButton.icon(
            onPressed: () async {
              final ok = await showLibraryIssueDialog(context, branchId: lib.branchId, editor: lib.editor, snapshot: snap, member: m);
              if (ok && context.mounted) {
                AppFeedback.success(context, 'Book issued to ${m.name}');
                await done();
              }
            },
            icon: const Icon(GIcons.bookIssue, size: 18),
            label: const Text('Issue a book'),
          ),
        if (lib.canManage && m.type == LibraryMemberType.outsider && !m.isLegacy)
          OutlinedButton.icon(
            onPressed: () async {
              final id = await showLibraryOutsiderDialog(context, branchId: lib.branchId, editor: lib.editor, member: m);
              if (id != null && context.mounted) {
                AppFeedback.success(context, 'Member updated');
                await done();
              }
            },
            icon: const Icon(GIcons.edit, size: 18),
            label: const Text('Edit'),
          ),
        if (lib.canManage && !m.isLegacy)
          OutlinedButton.icon(
            onPressed: () async {
              final ok = await showLibraryMemberAccessDialog(context, branchId: lib.branchId, editor: lib.editor, member: m, settings: snap.settings);
              if (ok && context.mounted) {
                AppFeedback.success(context, 'Access updated');
                await done();
              }
            },
            icon: const Icon(GIcons.shield, size: 18),
            label: const Text('Access'),
          ),
      ],
      children: [
        if (m.isLegacy)
          Container(
            margin: const EdgeInsets.only(top: Gsp.sp3),
            padding: const EdgeInsets.all(Gsp.sp3),
            decoration: BoxDecoration(color: c.warningBg, borderRadius: SchoolErp.radius),
            child: Text(
              'This borrower was typed in by hand on the old library screen and doesn\'t match a student, '
              'teacher or member record. Their loans still count. New loans need a member record.',
              style: GText.body2(c.warning),
            ),
          ),
        const SizedBox(height: Gsp.sp3),
        Row(children: [
          figure('Out now', '${open.length}/$limit', c.textPrimary),
          const SizedBox(width: Gsp.sp2),
          figure('Overdue', '$overdue', overdue > 0 ? c.danger : c.textPrimary),
          const SizedBox(width: Gsp.sp2),
          figure('Borrowed', '${loans.length}', c.textPrimary),
        ]),
        SchoolErpFacts(title: 'Details', facts: [
          (
            switch (m.type) {
              LibraryMemberType.student => 'Admission no.',
              LibraryMemberType.teacher => 'Employee id',
              LibraryMemberType.outsider => 'CNIC',
            },
            m.reference,
          ),
          ('Phone', m.phone),
          (
            switch (m.type) {
              LibraryMemberType.student => 'Class',
              LibraryMemberType.teacher => 'Designation',
              LibraryMemberType.outsider => 'Address',
            },
            m.detail,
          ),
          ('Loan limit', '$limit at a time${m.loanLimit != null ? ' (custom)' : ''}'),
          if (fines > 0) ('Fines', GFormat.pkr(fines)),
          if (m.notes.isNotEmpty) ('Notes', m.notes),
        ]),
        if (m.isLinkedRecord)
          Padding(
            padding: const EdgeInsets.only(top: Gsp.sp2),
            child: Text('Name, phone and class come from the ${m.type.label.toLowerCase()} record. Edit them there.',
                style: GText.caption(c.textMuted)),
          ),
        LibrarySubhead('Books out (${open.length})'),
        if (open.isEmpty) Text('No books out.', style: GText.body2(c.textMuted)),
        for (final l in open) _BookLine(lib: lib, snap: snap, loan: l, now: now, onDone: done),
        if (closed.isNotEmpty) ...[
          LibrarySubhead('History (${closed.length})'),
          for (final l in closed.take(30)) _BookLine(lib: lib, snap: snap, loan: l, now: now, onDone: done),
        ],
      ],
    );
  }
}

class _BookLine extends StatelessWidget {
  const _BookLine({required this.lib, required this.snap, required this.loan, required this.now, required this.onDone});
  final LibraryContext lib;
  final LibrarySnapshot snap;
  final LibraryLoan loan;
  final DateTime now;
  final Future<void> Function() onDone;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final book = snap.book(loan.bookId);
    final title = loan.bookTitle.isEmpty ? (book?.title ?? 'Book') : loan.bookTitle;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: Gsp.sp2),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.border))),
      child: Row(children: [
        LibraryCover(title: title, coverUrl: book?.coverUrl ?? '', width: 24),
        const SizedBox(width: Gsp.sp3),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            LibraryTitle(title, size: 14, dense: true),
            Text(
              loan.isOut
                  ? 'Issued ${libraryDate(loan.issueDate)} · due ${libraryDate(loan.dueDate)}'
                  : '${libraryDate(loan.issueDate)} → ${libraryDate(loan.returnedDate)}${loan.fine > 0 ? ' · fine ${GFormat.pkr(loan.fine)}' : ''}',
              style: GText.caption(c.textMuted),
            ),
          ]),
        ),
        LibraryLoanStatusChip(loan, now: now),
        if (loan.isOut) ...[
          const SizedBox(width: Gsp.sp1),
          libraryRowAction(
            icon: GIcons.bookReturn,
            label: 'Return',
            onPressed: () async {
              final ok = await showLibraryReturnDialog(context, branchId: lib.branchId, editor: lib.editor, snapshot: snap, loan: loan);
              if (ok && context.mounted) {
                AppFeedback.success(context, 'Return recorded');
                await onDone();
              }
            },
          ),
        ],
      ]),
    );
  }
}
