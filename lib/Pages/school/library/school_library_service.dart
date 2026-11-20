// lib/pages/school/library/school_library_service.dart
//
// Library reads and writes over the School store. Screens call this; the
// rules themselves are in library_rules.dart.

import '../core/school_branch_id.dart';
import '../core/school_store.dart';
import '../utils/school_local_storage.dart';
import 'library_models.dart';
import 'library_rules.dart';

class LibraryException implements Exception {
  final String message;
  const LibraryException(this.message);
  @override
  String toString() => message;
}

/// Everything the library screen shows, read once per rebuild.
class LibrarySnapshot {
  final List<LibraryBook> books;

  /// Every loan, with `memberId` resolved (old free-text loans are linked to
  /// the matching student/teacher where possible, otherwise to a legacy member).
  final List<LibraryLoan> loans;
  final List<LibraryMember> members;
  final LibrarySettings settings;

  LibrarySnapshot({required this.books, required this.loans, required this.members, required this.settings})
      : _books = {for (final b in books) b.id: b},
        _members = {for (final m in members) m.id: m};

  final Map<String, LibraryBook> _books;
  final Map<String, LibraryMember> _members;

  LibraryBook? book(String id) => _books[id];
  LibraryMember? member(String id) => _members[id];

  int available(LibraryBook b) => LibraryRules.available(b, loans);
  int copiesOut(String bookId) => LibraryRules.copiesOut(bookId, loans);
  LibraryStockLevel stock(LibraryBook b) => LibraryRules.stockLevel(b, loans);

  List<LibraryLoan> loansOfBook(String bookId) => _sorted(loans.where((l) => l.bookId == bookId));
  List<LibraryLoan> loansOfMember(String memberId) => _sorted(loans.where((l) => l.memberId == memberId));
  List<LibraryLoan> openLoansOfMember(String memberId) => LibraryRules.openLoansOf(memberId, loans);

  static List<LibraryLoan> _sorted(Iterable<LibraryLoan> it) {
    final l = it.toList()
      ..sort((a, b) => (b.issueDate ?? DateTime(2000)).compareTo(a.issueDate ?? DateTime(2000)));
    return l;
  }

  List<String> get categories {
    final s = {...libraryCategories, ...books.map((b) => b.category)}.toList();
    return s;
  }
}

abstract final class SchoolLibraryService {
  static const String _settingsId = 'default';

  // ── Read ──────────────────────────────────────────────────────────────────

  static LibrarySnapshot snapshot(String branchId) {
    final books = SchoolStore.all(SchoolCollection.books, branchId).map(LibraryBook.fromMap).toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    final settings = LibrarySettings.fromMap(SchoolStore.get(SchoolCollection.librarySettings, branchId, _settingsId));

    // Students and teachers are members automatically.
    final members = <String, LibraryMember>{};
    final studentByRef = <String, String>{};
    final studentByName = <String, List<String>>{};
    for (final s in SchoolLocalStorage.getAllStudentsCached(branchId)) {
      final sid = (s['id'] ?? '').toString();
      if (sid.isEmpty) continue;
      final status = (s['status'] ?? 'active').toString();
      if (status == 'void') continue;
      final id = LibraryMember.studentId(sid);
      // Admission no. is unique per branch since Phase 2; old records typed one
      // number into both fields, so the roll no. still links old loans.
      final ref = (s['admissionNo'] ?? s['rollNo'] ?? '').toString().trim();
      final roll = (s['rollNo'] ?? '').toString().trim();
      if (roll.isNotEmpty && roll != ref) studentByRef.putIfAbsent(roll.toLowerCase(), () => id);
      final name = (s['name'] ?? '').toString().trim();
      final grade = (s['grade'] ?? '').toString();
      final section = (s['section'] ?? '').toString();
      members[id] = LibraryMember(
        id: id,
        type: LibraryMemberType.student,
        name: name.isEmpty ? 'Student' : name,
        reference: ref,
        phone: (s['guardianPhone'] ?? s['phone'] ?? '').toString(),
        photoUrl: (s['photoUrl'] ?? '').toString(),
        detail: [grade, section].where((e) => e.isNotEmpty).join(' – '),
        inactive: status != 'active',
      );
      if (ref.isNotEmpty) studentByRef[ref.toLowerCase()] = id;
      (studentByName[name.toLowerCase()] ??= []).add(id);
    }
    final teacherByRef = <String, String>{};
    final teacherByName = <String, List<String>>{};
    for (final t in SchoolLocalStorage.getAllTeachersCached(branchId)) {
      final tid = (t['id'] ?? '').toString();
      if (tid.isEmpty) continue;
      final id = LibraryMember.teacherId(tid);
      final ref = (t['employeeId'] ?? '').toString().trim();
      final name = (t['name'] ?? '').toString().trim();
      members[id] = LibraryMember(
        id: id,
        type: LibraryMemberType.teacher,
        name: name.isEmpty ? 'Teacher' : name,
        reference: ref,
        phone: (t['phone'] ?? '').toString(),
        photoUrl: (t['photoUrl'] ?? '').toString(),
        detail: (t['designation'] ?? 'Teacher').toString(),
        inactive: (t['status'] ?? 'active').toString() != 'active',
      );
      if (ref.isNotEmpty) teacherByRef[ref.toLowerCase()] = id;
      (teacherByName[name.toLowerCase()] ??= []).add(id);
    }

    // Outsider records and per-member overrides.
    for (final r in SchoolStore.all(SchoolCollection.libraryMembers, branchId)) {
      final id = (r['id'] ?? '').toString();
      if (id.isEmpty) continue;
      final limit = r['loanLimit'] is num ? (r['loanLimit'] as num).toInt() : int.tryParse('${r['loanLimit'] ?? ''}');
      final base = members[id];
      if (base != null) {
        members[id] = LibraryMember(
          id: id,
          type: base.type,
          name: base.name,
          reference: base.reference,
          phone: base.phone,
          photoUrl: base.photoUrl,
          detail: base.detail,
          inactive: base.inactive,
          blocked: r['blocked'] == true,
          loanLimit: limit,
          notes: (r['notes'] ?? '').toString(),
        );
      } else if (!id.startsWith('student:') && !id.startsWith('teacher:')) {
        members[id] = LibraryMember(
          id: id,
          type: LibraryMemberType.outsider,
          name: (r['name'] ?? 'Member').toString(),
          reference: (r['cnic'] ?? '').toString(),
          phone: (r['phone'] ?? '').toString(),
          photoUrl: (r['photoUrl'] ?? '').toString(),
          detail: (r['address'] ?? '').toString(),
          blocked: r['blocked'] == true,
          loanLimit: limit,
          notes: (r['notes'] ?? '').toString(),
          inactive: (r['status'] ?? 'active').toString() == 'inactive',
        );
      }
    }

    // Loans: link old free-text borrowers to records where it is unambiguous.
    String? unique(List<String>? ids) => ids != null && ids.length == 1 ? ids.first : null;
    final loans = <LibraryLoan>[];
    for (final raw in SchoolStore.all(SchoolCollection.bookLoans, branchId)) {
      var loan = LibraryLoan.fromMap(raw);
      if (loan.id.isEmpty || loan.bookId.isEmpty) continue;
      if (loan.memberId.isEmpty || !members.containsKey(loan.memberId)) {
        final ref = loan.borrowerRef.toLowerCase();
        final name = loan.borrowerName.toLowerCase().trim();
        String? linked;
        if (loan.memberType == LibraryMemberType.student) {
          linked = studentByRef[ref] ?? unique(studentByName[name]);
        } else if (loan.memberType == LibraryMemberType.teacher) {
          linked = teacherByRef[ref] ?? unique(teacherByName[name]);
        }
        if (linked == null && loan.memberId.isNotEmpty && loan.memberId.startsWith('OUT-')) linked = loan.memberId;
        final id = linked ?? legacyMemberId(loan);
        loan = loan.withMemberId(id);
        members.putIfAbsent(
          id,
          () => LibraryMember(
            id: id,
            type: loan.memberType,
            name: loan.borrowerName.isEmpty ? 'Unknown borrower' : loan.borrowerName,
            reference: loan.borrowerRef,
            phone: loan.borrowerPhone,
          ),
        );
      }
      loans.add(loan);
    }

    final memberList = members.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return LibrarySnapshot(books: books, loans: loans, members: memberList, settings: settings);
  }

  static String legacyMemberId(LibraryLoan l) {
    String n(String s) => s.toLowerCase().replaceAll(RegExp(r'\s+'), '-');
    return 'legacy:${l.memberType.name}:${n(l.borrowerName)}:${n(l.borrowerRef)}';
  }

  /// Every box the library reads (for watching).
  static const watchedBoxes = [
    SchoolLocalStorage.booksBox,
    SchoolLocalStorage.bookLoansBox,
    SchoolLocalStorage.studentsBox,
    SchoolLocalStorage.teachersBox,
  ];

  // ── Books ─────────────────────────────────────────────────────────────────

  /// Adds or edits a book. Returns the saved book.
  static Future<LibraryBook> saveBook({
    required String branchId,
    required LibraryBook book,
    required String editor,
  }) async {
    final snap = snapshot(branchId);
    final isNew = book.id.isEmpty;
    final id = isNew ? SchoolLocalStorage.newId('BK', branchId) : book.id;
    final out = isNew ? 0 : snap.copiesOut(id);
    final error = LibraryRules.validateBook(book, copiesOut: out);
    if (error != null) throw LibraryException(error);

    final saved = await SchoolLocalStorage.saveBook(
      branchId: branchId,
      bookId: id,
      editorName: editor,
      bookData: {
        ...book.toEditableMap(),
        'id': id,
        'availableCopies': book.totalCopies - out,
        if (isNew) 'status': 'listed',
        if (isNew) 'createdAt': DateTime.now().toIso8601String(),
        if (isNew) 'createdBy': editor,
      },
    );
    return LibraryBook.fromMap(saved);
  }

  static Future<void> unlistBook({
    required String branchId,
    required String bookId,
    required LibraryUnlistReason reason,
    String note = '',
    required String editor,
  }) async {
    final book = snapshot(branchId).book(bookId);
    if (book == null) throw const LibraryException('Book not found.');
    if (!book.isListed) return;
    await SchoolStore.put(SchoolCollection.books, branchId: branchId, id: bookId, updatedBy: editor, data: {
      'status': 'unlisted',
      'unlistReason': reason.name,
      'unlistNote': note.trim(),
      'unlistedAt': DateTime.now().toIso8601String(),
      'unlistedBy': editor,
    });
    await SchoolStore.audit(
      branchId: branchId,
      action: 'BOOK_UNLISTED',
      user: editor,
      details: 'Unlisted "${book.title}" (${reason.label})${note.trim().isEmpty ? '' : ': ${note.trim()}'}',
      entity: 'book',
      entityId: bookId,
    );
  }

  static Future<void> relistBook({required String branchId, required String bookId, required String editor}) async {
    final book = snapshot(branchId).book(bookId);
    if (book == null) throw const LibraryException('Book not found.');
    if (book.isListed) return;
    await SchoolStore.put(SchoolCollection.books, branchId: branchId, id: bookId, updatedBy: editor, data: {
      'status': 'listed',
      'unlistReason': '',
      'unlistNote': '',
      'relistedAt': DateTime.now().toIso8601String(),
    });
    await SchoolStore.audit(
      branchId: branchId,
      action: 'BOOK_RELISTED',
      user: editor,
      details: 'Relisted "${book.title}"',
      entity: 'book',
      entityId: bookId,
    );
  }

  // ── Loans ─────────────────────────────────────────────────────────────────

  static Future<LibraryLoan> issue({
    required String branchId,
    required String bookId,
    required String memberId,
    required DateTime dueDate,
    required String editor,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final snap = snapshot(branchId);
    final book = snap.book(bookId);
    final member = snap.member(memberId);
    if (book == null) throw const LibraryException('Book not found.');
    if (member == null) throw const LibraryException('Member not found.');
    final error = LibraryRules.canIssue(
      book: book,
      member: member,
      loans: snap.loans,
      settings: snap.settings,
      dueDate: dueDate,
      now: at,
    );
    if (error != null) throw LibraryException(error);

    final loanId = SchoolLocalStorage.newId('LN', branchId);
    final saved = await SchoolLocalStorage.saveBookLoan(
      branchId: branchId,
      loanId: loanId,
      editorName: editor,
      loanData: {
        'id': loanId,
        'bookId': book.id,
        'bookTitle': book.title,
        'memberId': member.id,
        'memberType': member.type.name,
        // Kept for older screens/reports that read the borrower directly.
        'borrowerName': member.name,
        'borrowerType': member.type.label,
        'borrowerRef': member.reference,
        'borrowerId': member.reference,
        'borrowerPhone': member.phone,
        'issueDate': at.toIso8601String(),
        'dueDate': DateTime(dueDate.year, dueDate.month, dueDate.day, 23, 59).toIso8601String(),
        'status': 'borrowed',
        'issuedBy': editor,
      },
    );
    await SchoolLocalStorage.refreshBookAvailability(branchId, book.id, editorName: editor);
    await SchoolStore.audit(
      branchId: branchId,
      action: 'BOOK_ISSUED',
      user: editor,
      details: 'Issued "${book.title}" to ${member.name} (${member.type.label}), due '
          '${dueDate.day}/${dueDate.month}/${dueDate.year}',
      entity: 'loan',
      entityId: loanId,
    );
    return LibraryLoan.fromMap(saved);
  }

  /// Closes a loan. A lost book also removes one copy from the book's total.
  static Future<void> returnLoan({
    required String branchId,
    required String loanId,
    required DateTime returnDate,
    required LibraryReturnCondition condition,
    String remarks = '',
    required String editor,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final snap = snapshot(branchId);
    final loan = snap.loans.where((l) => l.id == loanId).firstOrNull;
    if (loan == null) throw const LibraryException('Loan not found.');
    final error = LibraryRules.validateReturn(loan, returnDate, at);
    if (error != null) throw LibraryException(error);
    final fine = LibraryRules.fineFor(loan, snap.settings, returnDate);

    await SchoolLocalStorage.saveBookLoan(
      branchId: branchId,
      loanId: loanId,
      editorName: editor,
      loanData: {
        'status': condition == LibraryReturnCondition.lost ? 'lost' : 'returned',
        'returnedDate': returnDate.toIso8601String(),
        'condition': condition.name,
        'returnRemarks': remarks.trim(),
        'fine': fine,
        'returnedTo': editor,
        if (loan.memberId.isNotEmpty) 'memberId': loan.memberId,
      },
    );

    final book = snap.book(loan.bookId);
    if (book != null && condition == LibraryReturnCondition.lost) {
      // The copy is gone: total drops by one (never below 0); a book with no
      // copies left is unlisted as lost.
      final newTotal = (book.totalCopies - 1).clamp(0, 999);
      await SchoolStore.put(SchoolCollection.books, branchId: branchId, id: book.id, updatedBy: editor, data: {
        'totalCopies': newTotal,
        if (newTotal == 0) 'status': 'unlisted',
        if (newTotal == 0) 'unlistReason': LibraryUnlistReason.lost.name,
        if (newTotal == 0) 'unlistedAt': at.toIso8601String(),
        if (newTotal == 0) 'unlistedBy': editor,
      });
    }
    if (book != null) await SchoolLocalStorage.refreshBookAvailability(branchId, book.id, editorName: editor);

    await SchoolStore.audit(
      branchId: branchId,
      action: condition == LibraryReturnCondition.lost ? 'BOOK_LOST' : 'BOOK_RETURNED',
      user: editor,
      details: '"${loan.bookTitle}" ${condition == LibraryReturnCondition.lost ? 'reported lost by' : 'returned by'} '
          '${loan.borrowerName} (${condition.label})${fine > 0 ? ', fine PKR $fine' : ''}',
      entity: 'loan',
      entityId: loanId,
    );
  }

  // ── Members ───────────────────────────────────────────────────────────────

  /// Adds or edits an outsider member. Returns its id.
  static Future<String> saveOutsider({
    required String branchId,
    String? id,
    required String name,
    required String cnic,
    required String phone,
    String address = '',
    String notes = '',
    String photoUrl = '',
    required String editor,
  }) async {
    final error = LibraryRules.validateOutsider(name: name, cnic: cnic, phone: phone);
    if (error != null) throw LibraryException(error);
    final snap = snapshot(branchId);
    final digits = cnic.replaceAll(RegExp(r'\D'), '');
    final clash = snap.members.where((m) =>
        m.type == LibraryMemberType.outsider && m.id != id && m.reference.replaceAll(RegExp(r'\D'), '') == digits);
    if (clash.isNotEmpty) throw LibraryException('${clash.first.name} is already a member with this CNIC.');

    final memberId = (id == null || id.isEmpty) ? SchoolLocalStorage.newId('OUT', branchId) : id;
    await SchoolStore.put(SchoolCollection.libraryMembers, branchId: branchId, id: memberId, updatedBy: editor, data: {
      'type': 'outsider',
      'name': name.trim(),
      'cnic': cnic.trim(),
      'phone': phone.trim(),
      'address': address.trim(),
      'notes': notes.trim(),
      'photoUrl': photoUrl,
      if (id == null || id.isEmpty) 'createdAt': DateTime.now().toIso8601String(),
    });
    await SchoolStore.audit(
      branchId: branchId,
      action: id == null || id.isEmpty ? 'LIBRARY_MEMBER_ADDED' : 'LIBRARY_MEMBER_UPDATED',
      user: editor,
      details: '${id == null || id.isEmpty ? 'Added' : 'Updated'} library member ${name.trim()}',
      entity: 'library_member',
      entityId: memberId,
    );
    return memberId;
  }

  /// Library-only settings for any member (students and teachers keep their
  /// details in their own record).
  static Future<void> saveMemberAccess({
    required String branchId,
    required LibraryMember member,
    required bool blocked,
    int? loanLimit,
    String notes = '',
    required String editor,
  }) async {
    if (member.isLegacy) {
      throw const LibraryException('Link this borrower to a member record before changing their access.');
    }
    if (loanLimit != null && (loanLimit < 1 || loanLimit > 20)) {
      throw const LibraryException('Loan limit must be between 1 and 20.');
    }
    await SchoolStore.put(SchoolCollection.libraryMembers, branchId: branchId, id: member.id, updatedBy: editor, data: {
      'blocked': blocked,
      'loanLimit': loanLimit,
      'notes': notes.trim(),
    });
    if (blocked != member.blocked) {
      await SchoolStore.audit(
        branchId: branchId,
        action: blocked ? 'LIBRARY_MEMBER_BLOCKED' : 'LIBRARY_MEMBER_UNBLOCKED',
        user: editor,
        details: '${blocked ? 'Blocked' : 'Unblocked'} ${member.name} from borrowing',
        entity: 'library_member',
        entityId: member.id,
      );
    }
  }

  static Future<void> saveSettings({
    required String branchId,
    required LibrarySettings settings,
    required String editor,
  }) async {
    if (SchoolBranchId.isAll(branchId)) throw const LibraryException('Pick a branch first.');
    if (settings.loanDays > settings.maxLoanDays) {
      throw const LibraryException('The default loan period can\'t be longer than the maximum.');
    }
    await SchoolStore.put(
      SchoolCollection.librarySettings,
      branchId: branchId,
      id: _settingsId,
      updatedBy: editor,
      data: settings.toMap(),
    );
    await SchoolStore.audit(
      branchId: branchId,
      action: 'LIBRARY_SETTINGS_UPDATED',
      user: editor,
      details: 'Library settings: limit ${settings.loanLimit}, ${settings.loanDays} days '
          '(max ${settings.maxLoanDays}), fine PKR ${settings.finePerDay}/day',
    );
  }
}
