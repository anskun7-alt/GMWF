// lib/pages/school/library/views/library_catalogue.dart
//
// Catalogue tab, built on the School ERP kit (redesign of 2026-11-17):
//   toolbar (search · category · stock · table/covers)  ›  dense sortable
//   SchoolErpTable with paging  ›  book record panel on the right (bottom
//   sheet on narrow screens). A cover grid is kept as a second view.

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';

import '../../widgets/erp/school_erp.dart';
import '../library_models.dart';
import '../library_rules.dart';
import '../school_library_service.dart';
import '../widgets/library_dialogs.dart';
import '../widgets/library_widgets.dart';

class LibraryContext {
  const LibraryContext({required this.branchId, required this.editor, required this.canManage, required this.snapshot});
  final String branchId;
  final String editor;
  final bool canManage;
  final LibrarySnapshot snapshot;
}

enum _StockFilter { all, inStock, low, out, unlisted }

/// Row height for library grids: a little taller than the default so a
/// Nastaliq title never touches the row lines.
const double _libraryRowHeight = 44;

/// Compact action inside a table row ("Issue", "Return").
Widget libraryRowAction({required IconData icon, required String label, VoidCallback? onPressed}) => TextButton.icon(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: Gsp.sp2),
        minimumSize: const Size(0, 30),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(icon, size: 16),
      label: Text(label),
    );

/// Opens a record panel as a bottom sheet (narrow screens).
void libraryOpenSheet(BuildContext context, Widget Function(ScrollController scroll) builder) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (ctx, scroll) => builder(scroll),
    ),
  );
}

class LibraryCatalogueTab extends StatefulWidget {
  const LibraryCatalogueTab({super.key, required this.lib});
  final LibraryContext lib;

  @override
  State<LibraryCatalogueTab> createState() => _LibraryCatalogueTabState();
}

class _LibraryCatalogueTabState extends State<LibraryCatalogueTab> {
  final _search = TextEditingController();
  String _category = 'All';
  _StockFilter _stock = _StockFilter.all;
  bool _covers = false;
  String? _selectedId;

  LibrarySnapshot get _snap => widget.lib.snapshot;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _stockMatches(LibraryBook b, _StockFilter f) {
    final level = _snap.stock(b);
    return switch (f) {
      _StockFilter.all => b.isListed,
      _StockFilter.inStock => level == LibraryStockLevel.inStock,
      _StockFilter.low => level == LibraryStockLevel.low,
      _StockFilter.out => level == LibraryStockLevel.out,
      _StockFilter.unlisted => level == LibraryStockLevel.unlisted,
    };
  }

  List<LibraryBook> _visible() {
    final q = _search.text.trim().toLowerCase();
    return _snap.books.where((b) {
      if (!_stockMatches(b, _stock)) return false;
      if (_category != 'All' && b.category != _category) return false;
      if (q.isEmpty) return true;
      return b.title.toLowerCase().contains(q) ||
          b.author.toLowerCase().contains(q) ||
          b.isbn.toLowerCase().contains(q) ||
          b.shelf.toLowerCase().contains(q) ||
          b.publisher.toLowerCase().contains(q);
    }).toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  }

  void _open(LibraryBook b) {
    if (SchoolErp.wide(context)) {
      setState(() => _selectedId = b.id);
      return;
    }
    libraryOpenSheet(context, (scroll) => LibraryBookPanel(lib: widget.lib, bookId: b.id, scrollController: scroll));
  }

  Future<void> _issue(LibraryBook b) async {
    final ok = await showLibraryIssueDialog(context, branchId: widget.lib.branchId, editor: widget.lib.editor, snapshot: _snap, book: b);
    if (ok && mounted) AppFeedback.success(context, '"${b.title}" issued');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final books = _visible();
    final selected = _selectedId == null ? null : _snap.book(_selectedId!);

    final toolbar = SchoolErpToolbar(
      search: _search,
      searchHint: 'Title, author, ISBN, shelf or publisher',
      onSearch: (_) => setState(() {}),
      filters: [
        SchoolErpFilter<String>(
          label: 'Category',
          value: _category,
          width: 210,
          options: {'All': 'All categories', for (final cat in _snap.categories) cat: cat},
          onChanged: (v) => setState(() => _category = v),
        ),
        SchoolErpFilter<_StockFilter>(
          label: 'Stock',
          value: _stock,
          width: 160,
          options: {
            for (final f in _StockFilter.values)
              f: '${switch (f) {
                _StockFilter.all => 'All listed',
                _StockFilter.inStock => 'In stock',
                _StockFilter.low => 'Low',
                _StockFilter.out => 'All out',
                _StockFilter.unlisted => 'Unlisted',
              }} (${_snap.books.where((b) => _stockMatches(b, f)).length})',
          },
          onChanged: (v) => setState(() => _stock = v),
        ),
      ],
      trailing: [
        Center(child: Text('${books.length} of ${_snap.books.length}', style: GText.caption(c.textMuted))),
        SizedBox(
          height: 36,
          child: SegmentedButton<bool>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: false, icon: Icon(GIcons.listView, size: 18), tooltip: 'Table'),
              ButtonSegment(value: true, icon: Icon(GIcons.gridView, size: 18), tooltip: 'Covers'),
            ],
            selected: {_covers},
            onSelectionChanged: (s) => setState(() => _covers = s.first),
          ),
        ),
      ],
    );

    final empty = AppEmptyState(
      icon: _snap.books.isEmpty ? GIcons.library : GIcons.searchOff,
      title: _snap.books.isEmpty ? 'No books yet' : 'No books match',
      subtitle: _snap.books.isEmpty ? 'Add the first book to start the catalogue.' : 'Try another search or filter.',
      action: _snap.books.isEmpty && widget.lib.canManage
          ? FilledButton.icon(
              icon: const Icon(GIcons.add),
              label: const Text('Add book'),
              onPressed: () => showLibraryBookForm(context, branchId: widget.lib.branchId, editor: widget.lib.editor, snapshot: _snap),
            )
          : null,
    );

    final table = SchoolErpTable<LibraryBook>(
      rows: books,
      rowKey: (b) => b.id,
      selectedKey: _selectedId,
      onRowTap: _open,
      rowHeight: _libraryRowHeight,
      pageSizes: const [50, 100, 200],
      minWidth: 760,
      empty: empty,
      rowColor: (b) => b.isListed ? null : c.surfaceSunken.withValues(alpha: 0.6),
      columns: [
        SchoolErpColumn(
          label: 'Title',
          flex: 6,
          sortValue: (b) => b.title.toLowerCase(),
          cell: (b) => Row(children: [
            LibraryCover(title: b.title, coverUrl: b.coverUrl, width: 24, dimmed: !b.isListed),
            const SizedBox(width: Gsp.sp3),
            Flexible(child: LibraryTitle(b.title, size: 14, dense: true, color: b.isListed ? c.textPrimary : c.textMuted)),
          ]),
        ),
        SchoolErpColumn(
          label: 'Author',
          flex: 3,
          sortValue: (b) => b.author.isEmpty ? '\u{FFFF}' : b.author.toLowerCase(),
          cell: (b) => b.author.isEmpty ? SchoolErpCell.text(context, '', muted: true) : LibraryTitle(b.author, size: 13, dense: true, weight: FontWeight.w400, color: c.textSecondary),
        ),
        SchoolErpColumn(
          label: 'Category',
          flex: 3,
          hideBelow: 900,
          sortValue: (b) => b.category.toLowerCase(),
          cell: (b) => SchoolErpCell.text(context, b.category),
        ),
        SchoolErpColumn(
          label: 'Shelf',
          width: 72,
          hideBelow: 1050,
          sortValue: (b) => b.shelf.isEmpty ? '\u{FFFF}' : b.shelf.toLowerCase(),
          cell: (b) => SchoolErpCell.mono(context, b.shelf, color: b.shelf.isEmpty ? c.textMuted : null),
        ),
        SchoolErpColumn(
          label: 'ISBN / Acc.',
          width: 120,
          hideBelow: 1250,
          sortValue: (b) => b.isbn.isEmpty ? '\u{FFFF}' : b.isbn,
          cell: (b) => SchoolErpCell.mono(context, b.isbn, color: b.isbn.isEmpty ? c.textMuted : null),
        ),
        SchoolErpColumn(
          label: 'On shelf',
          width: 120,
          sortValue: (b) => b.isListed ? _snap.available(b) : -1,
          cell: (b) => b.isListed
              ? _StockCell(available: _snap.available(b), total: b.totalCopies, level: _snap.stock(b))
              : Text(b.unlistReason?.label ?? 'Unlisted', style: GText.caption(c.textMuted)),
        ),
        SchoolErpColumn(
          label: 'Status',
          width: 112,
          sortValue: (b) => _snap.stock(b).index,
          cell: (b) => LibraryStockChip(_snap.stock(b)),
        ),
        SchoolErpColumn(
          label: '',
          width: 76,
          numeric: true,
          cell: (b) => b.isListed && _snap.available(b) > 0
              ? libraryRowAction(icon: GIcons.bookIssue, label: 'Issue', onPressed: () => _issue(b))
              : const SizedBox.shrink(),
        ),
      ],
    );

    return SchoolErpMasterDetail(
      master: SchoolErpCard(
        toolbar: toolbar,
        child: _covers
            ? (books.isEmpty
                ? empty
                : Padding(
                    padding: const EdgeInsets.all(Gsp.sp3),
                    child: _CoverGrid(books: books, lib: widget.lib, selectedId: _selectedId, onOpen: _open),
                  ))
            : table,
      ),
      detail: selected == null
          ? null
          : LibraryBookPanel(lib: widget.lib, bookId: selected.id, onClose: () => setState(() => _selectedId = null)),
    );
  }
}

/// "3 / 5" with a thin bar beside it, coloured by stock level.
class _StockCell extends StatelessWidget {
  const _StockCell({required this.available, required this.total, required this.level});
  final int available;
  final int total;
  final LibraryStockLevel level;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    return Row(children: [
      SizedBox(
        width: 48,
        child: Text.rich(
          TextSpan(children: [
            TextSpan(text: '$available', style: GText.body2Bold(c.textPrimary).copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
            TextSpan(text: ' / $total', style: GText.caption(c.textMuted).copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
        ),
      ),
      Expanded(child: GProgressBar(value: total <= 0 ? 0 : available / total, color: libraryStockColor(context, level), height: 4)),
    ]);
  }
}

// ── Cover grid ──────────────────────────────────────────────────────────────

class _CoverGrid extends StatelessWidget {
  const _CoverGrid({required this.books, required this.lib, required this.selectedId, required this.onOpen});
  final List<LibraryBook> books;
  final LibraryContext lib;
  final String? selectedId;
  final ValueChanged<LibraryBook> onOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 168,
        mainAxisExtent: 268,
        crossAxisSpacing: Gsp.sp3,
        mainAxisSpacing: Gsp.sp3,
      ),
      itemCount: books.length,
      itemBuilder: (context, i) {
        final b = books[i];
        final level = lib.snapshot.stock(b);
        final selected = b.id == selectedId;
        return Material(
          color: selected ? c.brandSoft : c.surface,
          shape: RoundedRectangleBorder(borderRadius: SchoolErp.radius, side: BorderSide(color: selected ? c.brand : c.border)),
          child: InkWell(
            borderRadius: SchoolErp.radius,
            onTap: () => onOpen(b),
            child: Padding(
              padding: const EdgeInsets.all(Gsp.sp3),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Center(
                  child: LayoutBuilder(
                    builder: (_, box) => LibraryCover(title: b.title, coverUrl: b.coverUrl, width: box.maxWidth.clamp(56, 104), dimmed: !b.isListed),
                  ),
                ),
                const Spacer(),
                LibraryTitle(b.title, size: 13, maxLines: 1, dense: true),
                Text(b.author.isEmpty ? '—' : b.author, maxLines: 1, overflow: TextOverflow.ellipsis, style: GText.caption(c.textMuted)),
                const SizedBox(height: Gsp.sp2),
                Row(children: [
                  LibraryStockChip(level),
                  const Spacer(),
                  if (b.isListed) Text('${lib.snapshot.available(b)}/${b.totalCopies}', style: GText.label(c.textSecondary)),
                ]),
              ]),
            ),
          ),
        );
      },
    );
  }
}

// ── Book record panel ───────────────────────────────────────────────────────

class LibraryBookPanel extends StatelessWidget {
  const LibraryBookPanel({super.key, required this.lib, required this.bookId, this.onClose, this.scrollController});
  final LibraryContext lib;
  final String bookId;
  final VoidCallback? onClose;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    // In a bottom sheet the snapshot passed in goes stale after an action, so re-read.
    final sheet = scrollController != null;
    final snap = sheet ? SchoolLibraryService.snapshot(lib.branchId) : lib.snapshot;
    final live = LibraryContext(branchId: lib.branchId, editor: lib.editor, canManage: lib.canManage, snapshot: snap);
    final book = snap.book(bookId);
    final c = context.comfort;
    if (book == null) {
      return const LibraryPanel(child: AppEmptyState(icon: GIcons.searchOff, title: 'Book not found', compact: true));
    }
    final now = DateTime.now();
    final loans = snap.loansOfBook(book.id);
    final open = loans.where((l) => l.isOut).toList()..sort((a, b) => (a.dueDate ?? now).compareTo(b.dueDate ?? now));
    final closed = loans.where((l) => !l.isOut).take(15).toList();
    final available = snap.available(book);
    final level = snap.stock(book);

    Future<void> refresh() async {
      if (sheet && context.mounted) Navigator.of(context).pop();
    }

    return SchoolErpDetailPanel(
      title: book.title,
      titleWidget: LibraryTitle(book.title, size: 18, maxLines: 3, weight: FontWeight.w700),
      subtitle: book.author.isEmpty ? 'Author not recorded' : book.author,
      leading: LibraryCover(title: book.title, coverUrl: book.coverUrl, width: 56, dimmed: !book.isListed),
      onClose: onClose,
      scrollController: scrollController,
      chips: [
        LibraryStockChip(level),
        AppChip(label: book.category, state: AppChipState.neutral, icon: GIcons.catalogue),
        if (book.language.isNotEmpty) AppChip(label: book.language, state: AppChipState.neutral, icon: GIcons.language),
      ],
      actions: [
        if (book.isListed)
          FilledButton.icon(
            onPressed: available > 0
                ? () async {
                    final ok = await showLibraryIssueDialog(context, branchId: lib.branchId, editor: lib.editor, snapshot: snap, book: book);
                    if (ok && context.mounted) {
                      AppFeedback.success(context, '"${book.title}" issued');
                      await refresh();
                    }
                  }
                : null,
            icon: const Icon(GIcons.bookIssue, size: 18),
            label: const Text('Issue'),
          ),
        if (lib.canManage)
          OutlinedButton.icon(
            onPressed: () async {
              final id = await showLibraryBookForm(context, branchId: lib.branchId, editor: lib.editor, snapshot: snap, book: book);
              if (id != null && context.mounted) {
                AppFeedback.success(context, 'Book updated');
                await refresh();
              }
            },
            icon: const Icon(GIcons.edit, size: 18),
            label: const Text('Edit'),
          ),
        if (lib.canManage && book.isListed)
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: c.danger),
            onPressed: () async {
              final ok = await showLibraryUnlistDialog(context, branchId: lib.branchId, editor: lib.editor, book: book, copiesOut: open.length);
              if (ok && context.mounted) {
                AppFeedback.success(context, '"${book.title}" unlisted');
                await refresh();
              }
            },
            icon: const Icon(GIcons.unlist, size: 18),
            label: const Text('Unlist'),
          ),
        if (lib.canManage && !book.isListed)
          OutlinedButton.icon(
            onPressed: () async {
              try {
                await SchoolLibraryService.relistBook(branchId: lib.branchId, bookId: book.id, editor: lib.editor);
                if (context.mounted) AppFeedback.success(context, '"${book.title}" is back in the catalogue');
                await refresh();
              } catch (e) {
                if (context.mounted) AppFeedback.error(context, '$e');
              }
            },
            icon: const Icon(GIcons.visibility, size: 18),
            label: const Text('Relist'),
          ),
      ],
      children: [
        if (!book.isListed)
          Container(
            margin: const EdgeInsets.only(top: Gsp.sp3),
            padding: const EdgeInsets.all(Gsp.sp3),
            decoration: BoxDecoration(color: c.surfaceSunken, borderRadius: SchoolErp.radius, border: Border.all(color: c.border)),
            child: Text(
              'Unlisted${book.unlistReason == null ? '' : ' · ${book.unlistReason!.label}'}'
              '${book.unlistedBy.isEmpty ? '' : ' by ${book.unlistedBy}'}'
              '${book.unlistedAt.isEmpty ? '' : ' on ${libraryDate(DateTime.tryParse(book.unlistedAt))}'}'
              '${book.unlistNote.isEmpty ? '' : '\n${book.unlistNote}'}',
              style: GText.body2(c.textSecondary),
            ),
          ),
        if (book.isListed)
          Padding(
            padding: const EdgeInsets.only(top: Gsp.sp3),
            child: LibraryStockBar(available: available, total: book.totalCopies, level: level, wide: true),
          ),
        SchoolErpFacts(title: 'Book', facts: [
          ('Shelf', book.shelf),
          ('ISBN / Acc. no.', book.isbn),
          ('Publisher', book.publisher),
          ('Language', book.language),
          ('Copies', '$available on shelf · ${open.length} out · ${book.totalCopies} total'),
          ('Added', libraryDate(DateTime.tryParse(book.createdAt))),
          if (book.notes.isNotEmpty) ('Notes', book.notes),
        ]),
        LibrarySubhead('Out now (${open.length})'),
        if (open.isEmpty) Text('All copies are on the shelf.', style: GText.body2(c.textMuted)),
        for (final l in open) _LoanLine(lib: live, loan: l, now: now, onDone: refresh),
        if (closed.isNotEmpty) ...[
          LibrarySubhead('Recent history (${closed.length})'),
          for (final l in closed) _LoanLine(lib: live, loan: l, now: now, onDone: refresh),
        ],
      ],
    );
  }
}

/// One loan in the book panel: borrower, dates, status, Return action.
class _LoanLine extends StatelessWidget {
  const _LoanLine({required this.lib, required this.loan, required this.now, required this.onDone});
  final LibraryContext lib;
  final LibraryLoan loan;
  final DateTime now;
  final Future<void> Function() onDone;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final member = lib.snapshot.member(loan.memberId);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: Gsp.sp2),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.border))),
      child: Row(children: [
        if (member != null) ...[LibraryMemberAvatar(member: member, size: 28), const SizedBox(width: Gsp.sp3)],
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(loan.borrowerName.isEmpty ? (member?.name ?? 'Unknown') : loan.borrowerName,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: GText.body2Bold(c.textPrimary)),
            Text(
              loan.isOut
                  ? 'Issued ${libraryDate(loan.issueDate)} · due ${libraryDate(loan.dueDate)}'
                  : 'Returned ${libraryDate(loan.returnedDate)}${loan.fine > 0 ? ' · fine ${GFormat.pkr(loan.fine)}' : ''}',
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
              final ok = await showLibraryReturnDialog(context, branchId: lib.branchId, editor: lib.editor, snapshot: lib.snapshot, loan: loan);
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
