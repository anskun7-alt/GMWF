// lib/pages/school/library/views/library_loans.dart
//
// Loans tab on the School ERP kit: search + status filter, then one dense
// sortable grid (book · borrower · issued · due · returned · status · fine)
// with a Return action per open loan. Open loans list most overdue first.

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';

import '../../widgets/erp/school_erp.dart';
import '../library_models.dart';
import '../widgets/library_dialogs.dart';
import '../widgets/library_widgets.dart';
import 'library_catalogue.dart';

enum LibraryLoanFilter { out, overdue, returned, all }

class LibraryLoansTab extends StatefulWidget {
  const LibraryLoansTab({super.key, required this.lib, this.initialFilter = LibraryLoanFilter.out});
  final LibraryContext lib;
  final LibraryLoanFilter initialFilter;

  @override
  State<LibraryLoansTab> createState() => _LibraryLoansTabState();
}

class _LibraryLoansTabState extends State<LibraryLoansTab> {
  late LibraryLoanFilter _filter = widget.initialFilter;
  final _search = TextEditingController();

  @override
  void didUpdateWidget(covariant LibraryLoansTab old) {
    super.didUpdateWidget(old);
    if (old.initialFilter != widget.initialFilter) _filter = widget.initialFilter;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(LibraryLoan l, LibraryLoanFilter f, DateTime now) => switch (f) {
        LibraryLoanFilter.out => l.isOut,
        LibraryLoanFilter.overdue => l.isOverdue(now),
        LibraryLoanFilter.returned => !l.isOut,
        LibraryLoanFilter.all => true,
      };

  String _label(LibraryLoanFilter f) => switch (f) {
        LibraryLoanFilter.out => 'Out now',
        LibraryLoanFilter.overdue => 'Overdue',
        LibraryLoanFilter.returned => 'Returned',
        LibraryLoanFilter.all => 'All loans',
      };

  Future<void> _return(LibraryLoan l) async {
    final ok = await showLibraryReturnDialog(context,
        branchId: widget.lib.branchId, editor: widget.lib.editor, snapshot: widget.lib.snapshot, loan: l);
    if (ok && mounted) AppFeedback.success(context, 'Return recorded');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final now = DateTime.now();
    final snap = widget.lib.snapshot;
    final q = _search.text.trim().toLowerCase();
    final far = DateTime(9999);
    final loans = snap.loans
        .where((l) => _matches(l, _filter, now))
        .where((l) => q.isEmpty || l.bookTitle.toLowerCase().contains(q) || l.borrowerName.toLowerCase().contains(q) || l.borrowerRef.toLowerCase().contains(q))
        .toList()
      ..sort((a, b) {
        // Open loans: most overdue first, then soonest due. Closed: newest return first.
        if (a.isOut != b.isOut) return a.isOut ? -1 : 1;
        if (a.isOut) return (a.dueDate ?? now).compareTo(b.dueDate ?? now);
        return (b.returnedDate ?? now).compareTo(a.returnedDate ?? now);
      });

    String borrower(LibraryLoan l) => l.borrowerName.isEmpty ? (snap.member(l.memberId)?.name ?? 'Unknown') : l.borrowerName;

    final toolbar = SchoolErpToolbar(
      search: _search,
      searchHint: 'Book, borrower or admission no.',
      onSearch: (_) => setState(() {}),
      filters: [
        SchoolErpFilter<LibraryLoanFilter>(
          label: 'Show',
          value: _filter,
          width: 170,
          options: {for (final f in LibraryLoanFilter.values) f: '${_label(f)} (${snap.loans.where((l) => _matches(l, f, now)).length})'},
          onChanged: (v) => setState(() => _filter = v),
        ),
      ],
      trailing: [Center(child: Text('${loans.length} ${loans.length == 1 ? 'loan' : 'loans'}', style: GText.caption(c.textMuted)))],
    );

    final table = SchoolErpTable<LibraryLoan>(
      rows: loans,
      rowKey: (l) => l.id,
      rowHeight: 50,
      minWidth: 820,
      rowColor: (l) => l.isOverdue(now) ? c.dangerBg.withValues(alpha: 0.35) : null,
      empty: AppEmptyState(
        icon: _filter == LibraryLoanFilter.overdue ? GIcons.checkCircle : GIcons.inbox,
        title: _filter == LibraryLoanFilter.overdue ? 'Nothing overdue' : 'No loans here',
        subtitle: _filter == LibraryLoanFilter.out ? 'Books issued from the catalogue appear here.' : null,
      ),
      columns: [
        SchoolErpColumn(
          label: 'Book',
          flex: 5,
          sortValue: (l) => l.bookTitle.toLowerCase(),
          cell: (l) {
            final book = snap.book(l.bookId);
            final title = l.bookTitle.isEmpty ? (book?.title ?? 'Book') : l.bookTitle;
            return Row(children: [
              LibraryCover(title: title, coverUrl: book?.coverUrl ?? '', width: 24),
              const SizedBox(width: Gsp.sp3),
              Flexible(child: LibraryTitle(title, size: 14, dense: true)),
            ]);
          },
        ),
        SchoolErpColumn(
          label: 'Borrower',
          flex: 4,
          sortValue: (l) => borrower(l).toLowerCase(),
          cell: (l) {
            final member = snap.member(l.memberId);
            return SchoolErpCell.primary(
              context,
              borrower(l),
              sub: [l.memberType.label, if (l.borrowerRef.isNotEmpty) l.borrowerRef].join(' · '),
              leading: member == null ? null : LibraryMemberAvatar(member: member, size: 26),
            );
          },
        ),
        SchoolErpColumn(
          label: 'Issued',
          width: 96,
          hideBelow: 1000,
          sortValue: (l) => l.issueDate ?? far,
          cell: (l) => SchoolErpCell.text(context, libraryDate(l.issueDate)),
        ),
        SchoolErpColumn(
          label: 'Due',
          width: 96,
          sortValue: (l) => l.dueDate ?? far,
          cell: (l) => SchoolErpCell.mono(context, libraryDate(l.dueDate), color: l.isOverdue(now) ? c.danger : null),
        ),
        SchoolErpColumn(
          label: 'Returned',
          width: 96,
          hideBelow: 1150,
          sortValue: (l) => l.returnedDate ?? far,
          cell: (l) => SchoolErpCell.text(context, l.returnedDate == null ? '' : libraryDate(l.returnedDate), muted: true),
        ),
        SchoolErpColumn(
          label: 'Status',
          width: 150,
          sortValue: (l) => l.isOut ? (l.isOverdue(now) ? 0 : 1) : 2,
          cell: (l) => LibraryLoanStatusChip(l, now: now),
        ),
        SchoolErpColumn(
          label: 'Fine',
          width: 72,
          numeric: true,
          hideBelow: 1100,
          sortValue: (l) => l.fine,
          cell: (l) => SchoolErpCell.mono(context, l.fine > 0 ? GFormat.pkr(l.fine) : '', color: l.fine > 0 ? c.warning : c.textMuted),
        ),
        SchoolErpColumn(
          label: '',
          width: 86,
          numeric: true,
          cell: (l) => l.isOut ? libraryRowAction(icon: GIcons.bookReturn, label: 'Return', onPressed: () => _return(l)) : const SizedBox.shrink(),
        ),
      ],
    );

    return SchoolErpCard(toolbar: toolbar, child: table);
  }
}
