// lib/pages/school/library/library_rules.dart
//
// Pure library rules: no Hive, no widgets. Every rule the screens enforce
// lives here so it is unit-tested (sandbox/school_library_test.dart).

import 'library_models.dart';

enum LibraryStockLevel { inStock, low, out, unlisted }

class LibraryRules {
  const LibraryRules._();

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  // ── Stock ─────────────────────────────────────────────────────────────────

  static int copiesOut(String bookId, Iterable<LibraryLoan> loans) =>
      loans.where((l) => l.bookId == bookId && l.isOut).length;

  /// Available copies are derived: total − copies out. Never stored by hand.
  static int available(LibraryBook book, Iterable<LibraryLoan> loans) {
    final a = book.totalCopies - copiesOut(book.id, loans);
    return a < 0 ? 0 : a;
  }

  /// Out = none left; low = one left of three or more, or a quarter or less.
  static LibraryStockLevel stockLevel(LibraryBook book, Iterable<LibraryLoan> loans) {
    if (!book.isListed) return LibraryStockLevel.unlisted;
    final a = available(book, loans);
    if (a <= 0) return LibraryStockLevel.out;
    final total = book.totalCopies <= 0 ? 1 : book.totalCopies;
    if ((a == 1 && total >= 3) || a / total <= 0.25) return LibraryStockLevel.low;
    return LibraryStockLevel.inStock;
  }

  // ── Books ─────────────────────────────────────────────────────────────────

  static String? validateBook(LibraryBook book, {required int copiesOut}) {
    if (book.title.trim().isEmpty || book.title == 'Untitled') return 'Enter the book title.';
    if (book.totalCopies < 1) return 'Total copies must be at least 1.';
    if (book.totalCopies > 999) return 'Total copies looks too high (max 999).';
    if (book.totalCopies < copiesOut) {
      return '$copiesOut ${copiesOut == 1 ? 'copy is' : 'copies are'} out on loan, '
          'so total copies can\'t be less than $copiesOut.';
    }
    return null;
  }

  static String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[\s\p{P}]+', unicode: true), '');

  /// Other listed books with the same title and author (or same ISBN).
  static List<LibraryBook> duplicatesOf(LibraryBook book, Iterable<LibraryBook> books) => books
      .where((b) => b.id != book.id && b.isListed)
      .where((b) =>
          (book.isbn.isNotEmpty && _norm(b.isbn) == _norm(book.isbn)) ||
          (_norm(b.title) == _norm(book.title) && _norm(b.author) == _norm(book.author)))
      .toList();

  // ── Members ───────────────────────────────────────────────────────────────

  static int limitFor(LibraryMember m, LibrarySettings s) => m.loanLimit ?? s.loanLimit;

  static List<LibraryLoan> openLoansOf(String memberId, Iterable<LibraryLoan> loans) =>
      loans.where((l) => l.memberId == memberId && l.isOut).toList();

  static String? validateOutsider({required String name, required String cnic, required String phone}) {
    if (name.trim().length < 3) return 'Enter the member\'s full name.';
    final cnicDigits = cnic.replaceAll(RegExp(r'\D'), '');
    if (cnicDigits.length != 13) return 'CNIC must have 13 digits (e.g. 34201-1234567-1).';
    final phoneDigits = phone.replaceAll(RegExp(r'\D'), '');
    if (!RegExp(r'^03\d{9}$').hasMatch(phoneDigits)) return 'Phone must be 11 digits starting with 03.';
    return null;
  }

  // ── Issue ─────────────────────────────────────────────────────────────────

  /// Why this book can't be issued to this member now, or null if it can.
  static String? canIssue({
    required LibraryBook book,
    required LibraryMember member,
    required Iterable<LibraryLoan> loans,
    required LibrarySettings settings,
    required DateTime dueDate,
    required DateTime now,
  }) {
    if (!book.isListed) return '"${book.title}" is unlisted and can\'t be issued.';
    if (available(book, loans) <= 0) return 'No copies of "${book.title}" are available.';
    if (member.blocked) return '${member.name} is blocked from borrowing.';
    if (member.inactive) return '${member.name} is no longer active at the school.';
    final open = openLoansOf(member.id, loans);
    if (open.any((l) => l.bookId == book.id)) return '${member.name} already has a copy of this book.';
    if (open.any((l) => l.isOverdue(now))) return '${member.name} has an overdue book. Return it first.';
    final limit = limitFor(member, settings);
    if (open.length >= limit) return '${member.name} already has $limit ${limit == 1 ? 'book' : 'books'} (the limit).';
    final due = _day(dueDate);
    final today = _day(now);
    if (due.isBefore(today)) return 'The due date can\'t be in the past.';
    if (due.difference(today).inDays > settings.maxLoanDays) {
      return 'Loans can be at most ${settings.maxLoanDays} days.';
    }
    return null;
  }

  // ── Return ────────────────────────────────────────────────────────────────

  static String? validateReturn(LibraryLoan loan, DateTime returnDate, DateTime now) {
    if (!loan.isOut) return 'This loan is already closed.';
    final d = _day(returnDate);
    if (d.isAfter(_day(now))) return 'The return date can\'t be in the future.';
    if (loan.issueDate != null && d.isBefore(_day(loan.issueDate!))) {
      return 'The return date can\'t be before the issue date.';
    }
    return null;
  }

  /// Fine for returning [loan] on [returnDate].
  static int fineFor(LibraryLoan loan, LibrarySettings s, DateTime returnDate) {
    if (s.finePerDay <= 0 || loan.dueDate == null) return 0;
    final days = _day(returnDate).difference(_day(loan.dueDate!)).inDays;
    return days > 0 ? days * s.finePerDay : 0;
  }
}
