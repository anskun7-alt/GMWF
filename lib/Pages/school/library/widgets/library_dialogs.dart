// lib/pages/school/library/widgets/library_dialogs.dart
//
// Library dialogs: add/edit book (with cover photo), unlist, issue, return,
// outsider member, member access and library settings. Each dialog validates
// through LibraryRules / SchoolLibraryService and reports errors inline.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gmwf_ui/gmwf_ui.dart';

import '../../../../services/image_upload_service.dart';
import '../../../../utils/formatters.dart';
import '../../../../widgets/media_upload_tile.dart';
import '../library_models.dart';
import '../library_rules.dart';
import '../school_library_service.dart';
import 'library_widgets.dart';

// ── Shared dialog frame ─────────────────────────────────────────────────────

class _LibraryDialog extends StatelessWidget {
  const _LibraryDialog({
    required this.icon,
    required this.title,
    required this.child,
    required this.actions,
    this.subtitle,
    this.width = 520,
    this.error,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget child;
  final List<Widget> actions;
  final double width;
  final String? error;

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
                  if (subtitle != null) LibraryTitle(subtitle!, size: 13, color: c.textSecondary, weight: FontWeight.w400),
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

String _msg(Object e) => e is LibraryException ? e.message : 'Something went wrong: $e';

// ── Add / edit book ─────────────────────────────────────────────────────────

/// Returns the saved book's id, or null if cancelled.
Future<String?> showLibraryBookForm(
  BuildContext context, {
  required String branchId,
  required String editor,
  required LibrarySnapshot snapshot,
  LibraryBook? book,
}) =>
    showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _BookFormDialog(branchId: branchId, editor: editor, snapshot: snapshot, book: book),
    );

class _BookFormDialog extends StatefulWidget {
  const _BookFormDialog({required this.branchId, required this.editor, required this.snapshot, this.book});
  final String branchId;
  final String editor;
  final LibrarySnapshot snapshot;
  final LibraryBook? book;

  @override
  State<_BookFormDialog> createState() => _BookFormDialogState();
}

class _BookFormDialogState extends State<_BookFormDialog> {
  late final _title = TextEditingController(text: widget.book?.title ?? '');
  late final _author = TextEditingController(text: widget.book?.author ?? '');
  late final _isbn = TextEditingController(text: widget.book?.isbn ?? '');
  late final _shelf = TextEditingController(text: widget.book?.shelf ?? '');
  late final _publisher = TextEditingController(text: widget.book?.publisher ?? '');
  late final _notes = TextEditingController(text: widget.book?.notes ?? '');
  late final _copies = TextEditingController(text: '${widget.book?.totalCopies ?? 1}');
  late String _category = widget.book?.category ?? 'General';
  late String _language = widget.book?.language ?? '';
  late String _cover = widget.book?.coverUrl ?? '';
  String? _error;
  bool _saving = false;

  bool get _isEdit => widget.book != null;
  int get _out => _isEdit ? widget.snapshot.copiesOut(widget.book!.id) : 0;

  @override
  void dispose() {
    for (final c in [_title, _author, _isbn, _shelf, _publisher, _notes, _copies]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Covers are kept small: one thumbnail-sized JPEG per book.
  String _compactCover(String value) {
    if (value.isEmpty || value.length < 60000) return value;
    final bytes = ImageUploadService.decodeBase64ToBytes(value);
    if (bytes == null) return value;
    return ImageUploadService.processBytesToBase64(bytes, maxWidth: 360, maxHeight: 520, quality: 60) ?? value;
  }

  LibraryBook _draft() => LibraryBook(
        id: widget.book?.id ?? '',
        title: _title.text.trim(),
        author: _author.text.trim(),
        isbn: _isbn.text.trim(),
        category: _category,
        language: _language.isEmpty ? (hasArabicScript(_title.text) ? 'Urdu' : '') : _language,
        shelf: _shelf.text.trim(),
        publisher: _publisher.text.trim(),
        notes: _notes.text.trim(),
        totalCopies: int.tryParse(_copies.text.trim()) ?? 0,
        coverUrl: _compactCover(_cover),
      );

  Future<void> _save() async {
    final draft = _draft();
    final error = LibraryRules.validateBook(draft, copiesOut: _out);
    if (error != null) return setState(() => _error = error);

    if (!_isEdit) {
      final dups = LibraryRules.duplicatesOf(draft, widget.snapshot.books);
      if (dups.isNotEmpty) {
        final choice = await _askDuplicate(dups.first, draft.totalCopies);
        if (choice == null) return;
        if (choice == _DupChoice.addCopies) {
          final existing = dups.first;
          setState(() => _saving = true);
          try {
            await SchoolLibraryService.saveBook(
              branchId: widget.branchId,
              editor: widget.editor,
              book: existing.copyWith(totalCopies: existing.totalCopies + draft.totalCopies),
            );
            if (mounted) Navigator.of(context).pop(existing.id);
          } catch (e) {
            if (mounted) setState(() { _saving = false; _error = _msg(e); });
          }
          return;
        }
      }
    }

    setState(() { _saving = true; _error = null; });
    try {
      final saved = await SchoolLibraryService.saveBook(branchId: widget.branchId, editor: widget.editor, book: draft);
      if (mounted) Navigator.of(context).pop(saved.id);
    } catch (e) {
      if (mounted) setState(() { _saving = false; _error = _msg(e); });
    }
  }

  Future<_DupChoice?> _askDuplicate(LibraryBook existing, int adding) => showDialog<_DupChoice>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('This book is already in the library'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              LibraryCover(title: existing.title, coverUrl: existing.coverUrl, width: 40),
              const SizedBox(width: Gsp.sp3),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  LibraryTitle(existing.title),
                  Text('${existing.author.isEmpty ? 'Unknown author' : existing.author} · ${existing.totalCopies} '
                      '${existing.totalCopies == 1 ? 'copy' : 'copies'}'),
                ]),
              ),
            ]),
            const SizedBox(height: Gsp.sp3),
            Text('Add the $adding new ${adding == 1 ? 'copy' : 'copies'} to it instead of creating a second entry?'),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(ctx, _DupChoice.saveNew), child: const Text('Save as separate book')),
            FilledButton(onPressed: () => Navigator.pop(ctx, _DupChoice.addCopies), child: Text('Add $adding to existing')),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final wide = MediaQuery.sizeOf(context).width >= 640;
    final cats = widget.snapshot.categories;

    final coverPicker = SizedBox(
      width: wide ? 150 : double.infinity,
      child: Column(children: [
        LibraryCover(title: _title.text.isEmpty ? 'Book' : _title.text, coverUrl: _cover, width: 120),
        const SizedBox(height: Gsp.sp2),
        MediaUploadTile(
          label: _cover.isEmpty ? 'Add cover photo' : 'Change cover',
          icon: GIcons.image,
          initialValue: _cover.isEmpty ? null : _cover,
          onChanged: (v) => setState(() => _cover = v ?? ''),
        ),
      ]),
    );

    final fields = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        controller: _title,
        autofocus: !_isEdit,
        textDirection: hasArabicScript(_title.text) ? TextDirection.rtl : null,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(labelText: 'Title *', hintText: 'Book title (Urdu or English)'),
      ),
      const SizedBox(height: Gsp.sp3),
      TextField(
        controller: _author,
        textDirection: hasArabicScript(_author.text) ? TextDirection.rtl : null,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(labelText: 'Author', hintText: 'Leave blank if unknown'),
      ),
      const SizedBox(height: Gsp.sp3),
      Row(children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: cats.contains(_category) ? _category : 'General',
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Category'),
            items: [for (final cat in cats) DropdownMenuItem(value: cat, child: Text(cat, overflow: TextOverflow.ellipsis))],
            onChanged: (v) => setState(() => _category = v ?? 'General'),
          ),
        ),
        const SizedBox(width: Gsp.sp3),
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: libraryLanguages.contains(_language) ? _language : null,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Language'),
            items: [for (final l in libraryLanguages) DropdownMenuItem(value: l, child: Text(l))],
            onChanged: (v) => setState(() => _language = v ?? ''),
          ),
        ),
      ]),
      const SizedBox(height: Gsp.sp3),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _copies,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(3)],
            decoration: InputDecoration(
              labelText: 'Total copies *',
              helperText: _out > 0 ? '$_out out on loan now' : null,
            ),
          ),
        ),
        const SizedBox(width: Gsp.sp3),
        Expanded(
          child: TextField(controller: _shelf, decoration: const InputDecoration(labelText: 'Shelf / rack', hintText: 'e.g. A-3')),
        ),
      ]),
      const SizedBox(height: Gsp.sp3),
      Row(children: [
        Expanded(child: TextField(controller: _isbn, decoration: const InputDecoration(labelText: 'ISBN / accession no.'))),
        const SizedBox(width: Gsp.sp3),
        Expanded(child: TextField(controller: _publisher, decoration: const InputDecoration(labelText: 'Publisher'))),
      ]),
      const SizedBox(height: Gsp.sp3),
      TextField(controller: _notes, maxLines: 2, decoration: const InputDecoration(labelText: 'Notes')),
      if (_isEdit) ...[
        const SizedBox(height: Gsp.sp3),
        Text('Changes are recorded in the audit trail.', style: GText.caption(c.textMuted)),
      ],
    ]);

    return _LibraryDialog(
      icon: _isEdit ? GIcons.edit : GIcons.add,
      title: _isEdit ? 'Edit book' : 'Add book',
      subtitle: _isEdit ? widget.book!.title : null,
      width: 720,
      error: _error,
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton.icon(
          onPressed: _saving ? null : _save,
          icon: _saving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(GIcons.save),
          label: Text(_isEdit ? 'Save changes' : 'Add book'),
        ),
      ],
      child: wide
          ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              coverPicker,
              const SizedBox(width: Gsp.sp5),
              Expanded(child: fields),
            ])
          : Column(children: [coverPicker, const SizedBox(height: Gsp.sp4), fields]),
    );
  }
}

enum _DupChoice { addCopies, saveNew }

// ── Unlist ──────────────────────────────────────────────────────────────────

Future<bool> showLibraryUnlistDialog(
  BuildContext context, {
  required String branchId,
  required String editor,
  required LibraryBook book,
  required int copiesOut,
}) async {
  var reason = LibraryUnlistReason.withdrawn;
  final note = TextEditingController();
  String? error;
  var saving = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) {
        final c = ctx.comfort;
        return _LibraryDialog(
          icon: GIcons.unlist,
          title: 'Unlist book',
          subtitle: book.title,
          error: error,
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: c.danger, foregroundColor: GColor.onAccent(c.danger)),
              onPressed: saving
                  ? null
                  : () async {
                      setS(() => saving = true);
                      try {
                        await SchoolLibraryService.unlistBook(
                          branchId: branchId,
                          bookId: book.id,
                          reason: reason,
                          note: note.text,
                          editor: editor,
                        );
                        if (ctx.mounted) Navigator.pop(ctx, true);
                      } catch (e) {
                        setS(() { saving = false; error = _msg(e); });
                      }
                    },
              child: const Text('Unlist'),
            ),
          ],
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(
              'Books are never deleted. An unlisted book is hidden from the catalogue and can\'t be issued, '
              'but its history stays and you can relist it any time.',
              style: GText.body2(c.textSecondary),
            ),
            if (copiesOut > 0) ...[
              const SizedBox(height: Gsp.sp3),
              Container(
                padding: const EdgeInsets.all(Gsp.sp3),
                decoration: BoxDecoration(color: c.warningBg, borderRadius: Gr.input),
                child: Text(
                  '$copiesOut ${copiesOut == 1 ? 'copy is' : 'copies are'} still out on loan. They can still be returned.',
                  style: GText.body2(c.warning),
                ),
              ),
            ],
            const SizedBox(height: Gsp.sp3),
            Text('Reason', style: GText.label(c.textSecondary)),
            const SizedBox(height: Gsp.sp1),
            Wrap(spacing: Gsp.sp2, runSpacing: Gsp.sp2, children: [
              for (final r in LibraryUnlistReason.values)
                ChoiceChip(label: Text(r.label), selected: reason == r, onSelected: (_) => setS(() => reason = r)),
            ]),
            const SizedBox(height: Gsp.sp3),
            TextField(controller: note, decoration: const InputDecoration(labelText: 'Note (optional)')),
          ]),
        );
      },
    ),
  );
  note.dispose();
  return ok == true;
}

// ── Issue ───────────────────────────────────────────────────────────────────

/// Issue a book. Pass [book] to pick a member, [member] to pick a book, or both.
Future<bool> showLibraryIssueDialog(
  BuildContext context, {
  required String branchId,
  required String editor,
  required LibrarySnapshot snapshot,
  LibraryBook? book,
  LibraryMember? member,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _IssueDialog(branchId: branchId, editor: editor, snapshot: snapshot, book: book, member: member),
    ) ==
    true;

class _IssueDialog extends StatefulWidget {
  const _IssueDialog({required this.branchId, required this.editor, required this.snapshot, this.book, this.member});
  final String branchId;
  final String editor;
  final LibrarySnapshot snapshot;
  final LibraryBook? book;
  final LibraryMember? member;

  @override
  State<_IssueDialog> createState() => _IssueDialogState();
}

class _IssueDialogState extends State<_IssueDialog> {
  late LibraryBook? _book = widget.book;
  late LibraryMember? _member = widget.member;
  late DateTime _due = DateTime.now().add(Duration(days: widget.snapshot.settings.loanDays));
  final _search = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String? get _blocker => _book == null || _member == null
      ? null
      : LibraryRules.canIssue(
          book: _book!,
          member: _member!,
          loans: widget.snapshot.loans,
          settings: widget.snapshot.settings,
          dueDate: _due,
          now: DateTime.now(),
        );

  Future<void> _issue() async {
    setState(() { _saving = true; _error = null; });
    try {
      await SchoolLibraryService.issue(
        branchId: widget.branchId,
        bookId: _book!.id,
        memberId: _member!.id,
        dueDate: _due,
        editor: widget.editor,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() { _saving = false; _error = _msg(e); });
    }
  }

  Widget _memberPicker() {
    final c = context.comfort;
    final q = _search.text.trim().toLowerCase();
    final list = widget.snapshot.members
        .where((m) => !m.isLegacy && !m.inactive)
        .where((m) => q.isEmpty || m.name.toLowerCase().contains(q) || m.reference.toLowerCase().contains(q) || m.phone.contains(q))
        .take(30)
        .toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        controller: _search,
        autofocus: true,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(prefixIcon: Icon(GIcons.search), hintText: 'Search name, admission no., employee id or CNIC'),
      ),
      const SizedBox(height: Gsp.sp2),
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 280),
        child: list.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(Gsp.sp4),
                child: Text('No members match. Add outsiders from the Members tab.', style: GText.body2(c.textMuted)),
              )
            : ListView.builder(
                shrinkWrap: true,
                itemCount: list.length,
                itemBuilder: (_, i) {
                  final m = list[i];
                  final open = widget.snapshot.openLoansOfMember(m.id).length;
                  return ListTile(
                    dense: true,
                    leading: LibraryMemberAvatar(member: m, size: 32),
                    title: Text(m.name),
                    subtitle: Text([m.type.label, m.reference, m.detail].where((e) => e.isNotEmpty).join(' · ')),
                    trailing: open > 0 ? AppChip(label: '$open out', state: AppChipState.info) : null,
                    onTap: () => setState(() => _member = m),
                  );
                },
              ),
      ),
    ]);
  }

  Widget _bookPicker() {
    final c = context.comfort;
    final q = _search.text.trim().toLowerCase();
    final list = widget.snapshot.books
        .where((b) => b.isListed && widget.snapshot.available(b) > 0)
        .where((b) => q.isEmpty || b.title.toLowerCase().contains(q) || b.author.toLowerCase().contains(q) || b.isbn.toLowerCase().contains(q))
        .take(30)
        .toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        controller: _search,
        autofocus: true,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(prefixIcon: Icon(GIcons.search), hintText: 'Search available books'),
      ),
      const SizedBox(height: Gsp.sp2),
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 300),
        child: list.isEmpty
            ? Padding(padding: const EdgeInsets.all(Gsp.sp4), child: Text('No available books match.', style: GText.body2(c.textMuted)))
            : ListView.builder(
                shrinkWrap: true,
                itemCount: list.length,
                itemBuilder: (_, i) {
                  final b = list[i];
                  return ListTile(
                    leading: LibraryCover(title: b.title, coverUrl: b.coverUrl, width: 28),
                    title: LibraryTitle(b.title, size: 14),
                    subtitle: Text(b.author.isEmpty ? b.category : '${b.author} · ${b.category}'),
                    trailing: Text('${widget.snapshot.available(b)} left', style: GText.caption(c.textMuted)),
                    onTap: () => setState(() {
                      _book = b;
                      _search.clear();
                    }),
                  );
                },
              ),
      ),
    ]);
  }

  Widget _pickedRow({required Widget leading, required Widget title, required String subtitle, VoidCallback? onChange}) {
    final c = context.comfort;
    return Container(
      padding: const EdgeInsets.all(Gsp.sp3),
      decoration: BoxDecoration(color: c.surfaceSunken, borderRadius: Gr.input, border: Border.all(color: c.border)),
      child: Row(children: [
        leading,
        const SizedBox(width: Gsp.sp3),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [title, Text(subtitle, style: GText.caption(c.textMuted))])),
        if (onChange != null) TextButton(onPressed: onChange, child: const Text('Change')),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final s = widget.snapshot.settings;
    final blocker = _blocker;
    final ready = _book != null && _member != null && blocker == null;

    return _LibraryDialog(
      icon: GIcons.bookIssue,
      title: 'Issue book',
      subtitle: _book?.title,
      width: 560,
      error: _error ?? blocker,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton.icon(
          onPressed: ready && !_saving ? _issue : null,
          icon: const Icon(GIcons.bookIssue),
          label: const Text('Issue'),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Book', style: GText.label(c.textSecondary)),
        const SizedBox(height: Gsp.sp1),
        if (_book == null)
          _bookPicker()
        else
          _pickedRow(
            leading: LibraryCover(title: _book!.title, coverUrl: _book!.coverUrl, width: 32),
            title: LibraryTitle(_book!.title, size: 14),
            subtitle: '${widget.snapshot.available(_book!)} of ${_book!.totalCopies} available',
            onChange: widget.book == null ? () => setState(() => _book = null) : null,
          ),
        const SizedBox(height: Gsp.sp4),
        Text('Borrower', style: GText.label(c.textSecondary)),
        const SizedBox(height: Gsp.sp1),
        if (_member == null && _book != null)
          _memberPicker()
        else if (_member != null)
          _pickedRow(
            leading: LibraryMemberAvatar(member: _member!, size: 32),
            title: Text(_member!.name, style: GText.body1Bold(c.textPrimary)),
            subtitle: [
              _member!.type.label,
              if (_member!.reference.isNotEmpty) _member!.reference,
              '${widget.snapshot.openLoansOfMember(_member!.id).length} of ${LibraryRules.limitFor(_member!, s)} books out',
            ].join(' · '),
            onChange: widget.member == null ? () => setState(() => _member = null) : null,
          )
        else
          Text('Pick a book first.', style: GText.body2(c.textMuted)),
        const SizedBox(height: Gsp.sp4),
        Row(children: [
          Icon(GIcons.calendar, size: GIconSize.sm, color: c.textMuted),
          const SizedBox(width: Gsp.sp2),
          Text('Due back', style: GText.label(c.textSecondary)),
          const Spacer(),
          for (final d in {7, 14, s.loanDays})
            Padding(
              padding: const EdgeInsetsDirectional.only(start: Gsp.sp1),
              child: ChoiceChip(
                label: Text('$d days'),
                selected: DateUtils.isSameDay(_due, DateTime.now().add(Duration(days: d))),
                onSelected: (_) => setState(() => _due = DateTime.now().add(Duration(days: d))),
              ),
            ),
          const SizedBox(width: Gsp.sp2),
          OutlinedButton(
            onPressed: () async {
              final now = DateTime.now();
              final p = await showDatePicker(
                context: context,
                initialDate: _due,
                firstDate: now,
                lastDate: now.add(Duration(days: s.maxLoanDays)),
              );
              if (p != null) setState(() => _due = p);
            },
            child: Text(libraryDate(_due)),
          ),
        ]),
      ]),
    );
  }
}

// ── Return ──────────────────────────────────────────────────────────────────

Future<bool> showLibraryReturnDialog(
  BuildContext context, {
  required String branchId,
  required String editor,
  required LibrarySnapshot snapshot,
  required LibraryLoan loan,
}) async {
  var date = DateTime.now();
  var condition = LibraryReturnCondition.good;
  final remarks = TextEditingController();
  String? error;
  var saving = false;
  final book = snapshot.book(loan.bookId);

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      final c = ctx.comfort;
      final fine = LibraryRules.fineFor(loan, snapshot.settings, date);
      final late = loan.dueDate == null ? 0 : DateUtils.dateOnly(date).difference(DateUtils.dateOnly(loan.dueDate!)).inDays;
      return _LibraryDialog(
        icon: GIcons.bookReturn,
        title: 'Return book',
        subtitle: loan.bookTitle,
        error: error,
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton.icon(
            onPressed: saving
                ? null
                : () async {
                    setS(() => saving = true);
                    try {
                      await SchoolLibraryService.returnLoan(
                        branchId: branchId,
                        loanId: loan.id,
                        returnDate: date,
                        condition: condition,
                        remarks: remarks.text,
                        editor: editor,
                      );
                      if (ctx.mounted) Navigator.pop(ctx, true);
                    } catch (e) {
                      setS(() { saving = false; error = _msg(e); });
                    }
                  },
            icon: Icon(condition == LibraryReturnCondition.lost ? GIcons.warning : GIcons.bookReturn),
            label: Text(condition == LibraryReturnCondition.lost ? 'Mark as lost' : 'Confirm return'),
          ),
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            LibraryCover(title: loan.bookTitle, coverUrl: book?.coverUrl ?? '', width: 40),
            const SizedBox(width: Gsp.sp3),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(loan.borrowerName, style: GText.body1Bold(c.textPrimary)),
                Text('Issued ${libraryDate(loan.issueDate)} · due ${libraryDate(loan.dueDate)}', style: GText.caption(c.textMuted)),
              ]),
            ),
          ]),
          const SizedBox(height: Gsp.sp4),
          Row(children: [
            Text('Returned on', style: GText.label(c.textSecondary)),
            const Spacer(),
            OutlinedButton.icon(
              icon: const Icon(GIcons.calendar),
              label: Text(libraryDate(date)),
              onPressed: () async {
                final now = DateTime.now();
                final first = loan.issueDate == null ? DateTime(now.year - 1) : DateUtils.dateOnly(loan.issueDate!);
                final p = await showDatePicker(context: ctx, initialDate: date, firstDate: first, lastDate: now);
                if (p != null) setS(() => date = p);
              },
            ),
          ]),
          if (late > 0) ...[
            const SizedBox(height: Gsp.sp2),
            Text(
              '$late ${late == 1 ? 'day' : 'days'} late${fine > 0 ? ' · fine ${GFormat.pkr(fine)}' : ''}',
              style: GText.body2(c.warning),
            ),
          ],
          const SizedBox(height: Gsp.sp4),
          Text('Condition', style: GText.label(c.textSecondary)),
          const SizedBox(height: Gsp.sp1),
          Wrap(spacing: Gsp.sp2, children: [
            for (final cond in LibraryReturnCondition.values)
              ChoiceChip(label: Text(cond.label), selected: condition == cond, onSelected: (_) => setS(() => condition = cond)),
          ]),
          if (condition == LibraryReturnCondition.lost) ...[
            const SizedBox(height: Gsp.sp2),
            Text('One copy will be removed from the book\'s total.', style: GText.caption(c.danger)),
          ],
          const SizedBox(height: Gsp.sp3),
          TextField(controller: remarks, decoration: const InputDecoration(labelText: 'Remarks (optional)')),
        ]),
      );
    }),
  );
  remarks.dispose();
  return ok == true;
}

// ── Outsider member ─────────────────────────────────────────────────────────

/// Returns the member id, or null if cancelled.
Future<String?> showLibraryOutsiderDialog(
  BuildContext context, {
  required String branchId,
  required String editor,
  LibraryMember? member,
}) async {
  final name = TextEditingController(text: member?.name ?? '');
  final cnic = TextEditingController(text: member?.reference ?? '');
  final phone = TextEditingController(text: member?.phone ?? '');
  final address = TextEditingController(text: member?.detail ?? '');
  final notes = TextEditingController(text: member?.notes ?? '');
  var photo = member?.photoUrl ?? '';
  String? error;
  var saving = false;

  final id = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      return _LibraryDialog(
        icon: member == null ? GIcons.memberAdd : GIcons.edit,
        title: member == null ? 'Add outsider member' : 'Edit member',
        subtitle: member?.name,
        error: error,
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: saving
                ? null
                : () async {
                    setS(() => saving = true);
                    try {
                      final saved = await SchoolLibraryService.saveOutsider(
                        branchId: branchId,
                        id: member?.id,
                        name: name.text,
                        cnic: cnic.text,
                        phone: phone.text,
                        address: address.text,
                        notes: notes.text,
                        photoUrl: photo,
                        editor: editor,
                      );
                      if (ctx.mounted) Navigator.pop(ctx, saved);
                    } catch (e) {
                      setS(() { saving = false; error = _msg(e); });
                    }
                  },
            child: Text(member == null ? 'Add member' : 'Save'),
          ),
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          MediaUploadTile(
            label: 'Photo (optional)',
            icon: GIcons.profile,
            initialValue: photo.isEmpty ? null : photo,
            onChanged: (v) => setS(() => photo = v ?? ''),
          ),
          const SizedBox(height: Gsp.sp3),
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Full name *')),
          const SizedBox(height: Gsp.sp3),
          TextField(
            controller: cnic,
            keyboardType: TextInputType.number,
            inputFormatters: [CNICInputFormatter()],
            decoration: const InputDecoration(labelText: 'CNIC *', hintText: '34201-1234567-1'),
          ),
          const SizedBox(height: Gsp.sp3),
          TextField(
            controller: phone,
            keyboardType: TextInputType.phone,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(11)],
            decoration: const InputDecoration(labelText: 'Phone *', hintText: '03001234567'),
          ),
          const SizedBox(height: Gsp.sp3),
          TextField(controller: address, decoration: const InputDecoration(labelText: 'Address')),
          const SizedBox(height: Gsp.sp3),
          TextField(controller: notes, maxLines: 2, decoration: const InputDecoration(labelText: 'Notes')),
        ]),
      );
    }),
  );
  for (final c in [name, cnic, phone, address, notes]) {
    c.dispose();
  }
  return id;
}

// ── Member access (block / limit / notes) ───────────────────────────────────

Future<bool> showLibraryMemberAccessDialog(
  BuildContext context, {
  required String branchId,
  required String editor,
  required LibraryMember member,
  required LibrarySettings settings,
}) async {
  var blocked = member.blocked;
  var custom = member.loanLimit != null;
  var limit = member.loanLimit ?? settings.loanLimit;
  final notes = TextEditingController(text: member.notes);
  String? error;

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      final c = ctx.comfort;
      return _LibraryDialog(
        icon: GIcons.shield,
        title: 'Library access',
        subtitle: member.name,
        error: error,
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              try {
                await SchoolLibraryService.saveMemberAccess(
                  branchId: branchId,
                  member: member,
                  blocked: blocked,
                  loanLimit: custom ? limit : null,
                  notes: notes.text,
                  editor: editor,
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
            title: const Text('Blocked from borrowing'),
            subtitle: const Text('Blocked members can still return books.'),
            value: blocked,
            onChanged: (v) => setS(() => blocked = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Custom loan limit'),
            subtitle: Text('Library default: ${settings.loanLimit} at a time'),
            value: custom,
            onChanged: (v) => setS(() => custom = v),
          ),
          if (custom)
            DropdownButtonFormField<int>(
              initialValue: limit.clamp(1, 20),
              decoration: const InputDecoration(labelText: 'Books at a time'),
              items: [
                for (var i = 1; i <= 20; i++)
                  DropdownMenuItem(value: i, child: Text('$i ${i == 1 ? 'book' : 'books'}', style: GText.body1(c.textPrimary))),
              ],
              onChanged: (v) => setS(() => limit = v ?? limit),
            ),
          const SizedBox(height: Gsp.sp2),
          TextField(controller: notes, maxLines: 2, decoration: const InputDecoration(labelText: 'Library notes')),
        ]),
      );
    }),
  );
  notes.dispose();
  return ok == true;
}

// ── Settings ────────────────────────────────────────────────────────────────

Future<bool> showLibrarySettingsDialog(
  BuildContext context, {
  required String branchId,
  required String editor,
  required LibrarySettings settings,
}) async {
  final limit = TextEditingController(text: '${settings.loanLimit}');
  final days = TextEditingController(text: '${settings.loanDays}');
  final maxDays = TextEditingController(text: '${settings.maxLoanDays}');
  final fine = TextEditingController(text: '${settings.finePerDay}');
  String? error;
  final digits = [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)];

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      return _LibraryDialog(
        icon: GIcons.settings,
        title: 'Library settings',
        error: error,
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              try {
                await SchoolLibraryService.saveSettings(
                  branchId: branchId,
                  editor: editor,
                  settings: LibrarySettings.fromMap({
                    'loanLimit': int.tryParse(limit.text),
                    'loanDays': int.tryParse(days.text),
                    'maxLoanDays': int.tryParse(maxDays.text),
                    'finePerDay': int.tryParse(fine.text),
                  }),
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
          TextField(controller: limit, inputFormatters: digits, decoration: const InputDecoration(labelText: 'Books per member at a time', helperText: '1–20')),
          const SizedBox(height: Gsp.sp3),
          TextField(controller: days, inputFormatters: digits, decoration: const InputDecoration(labelText: 'Default loan period (days)')),
          const SizedBox(height: Gsp.sp3),
          TextField(controller: maxDays, inputFormatters: digits, decoration: const InputDecoration(labelText: 'Longest loan allowed (days)')),
          const SizedBox(height: Gsp.sp3),
          TextField(
            controller: fine,
            inputFormatters: digits,
            decoration: const InputDecoration(labelText: 'Late fine per day (PKR)', helperText: '0 = no fines'),
          ),
        ]),
      );
    }),
  );
  for (final c in [limit, days, maxDays, fine]) {
    c.dispose();
  }
  return ok == true;
}
