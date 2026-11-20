// lib/pages/school/library/library_models.dart
//
// School library records (School ERP plan §3.2). Plain value objects read from
// and written to the School store. `fromMap` tolerates records written by the
// old library screen (free-text borrowers, missing status, int/str numbers).

int _int(Object? v, [int fallback = 0]) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? fallback;
String _str(Object? v) => v?.toString().trim() ?? '';
DateTime? _date(Object? v) => v == null ? null : DateTime.tryParse(v.toString());

/// True when [s] contains Arabic-script letters (Urdu / Arabic titles).
bool hasArabicScript(String s) => RegExp(r'[؀-ۿݐ-ݿﭐ-﷿ﹰ-﻿]').hasMatch(s);

// ── Book ────────────────────────────────────────────────────────────────────

enum LibraryBookStatus { listed, unlisted }

/// Why a book was unlisted. Books are never deleted, only unlisted.
enum LibraryUnlistReason {
  lost('Lost'),
  damaged('Damaged'),
  withdrawn('Withdrawn'),
  duplicate('Duplicate entry');

  const LibraryUnlistReason(this.label);
  final String label;

  static LibraryUnlistReason? parse(Object? v) {
    final s = _str(v);
    for (final r in values) {
      if (r.name == s) return r;
    }
    return null;
  }
}

class LibraryBook {
  final String id;
  final String title;
  final String author;
  final String isbn;
  final String category;
  final String language;
  final String shelf;
  final String publisher;
  final int totalCopies;
  final String coverUrl;
  final LibraryBookStatus status;
  final LibraryUnlistReason? unlistReason;
  final String unlistNote;
  final String unlistedAt;
  final String unlistedBy;
  final String notes;
  final String createdAt;
  final String lastModified;

  const LibraryBook({
    required this.id,
    required this.title,
    this.author = '',
    this.isbn = '',
    this.category = 'General',
    this.language = '',
    this.shelf = '',
    this.publisher = '',
    this.totalCopies = 1,
    this.coverUrl = '',
    this.status = LibraryBookStatus.listed,
    this.unlistReason,
    this.unlistNote = '',
    this.unlistedAt = '',
    this.unlistedBy = '',
    this.notes = '',
    this.createdAt = '',
    this.lastModified = '',
  });

  bool get isListed => status == LibraryBookStatus.listed;
  bool get isUrdu => hasArabicScript(title);

  factory LibraryBook.fromMap(Map<String, dynamic> m) => LibraryBook(
        id: _str(m['id']),
        title: _str(m['title']).isEmpty ? 'Untitled' : _str(m['title']),
        author: _str(m['author']),
        isbn: _str(m['isbn']),
        category: _str(m['category']).isEmpty ? 'General' : _str(m['category']),
        language: _str(m['language']),
        shelf: _str(m['shelf']),
        publisher: _str(m['publisher']),
        totalCopies: _int(m['totalCopies'], 1),
        coverUrl: _str(m['coverUrl']),
        status: _str(m['status']) == 'unlisted' ? LibraryBookStatus.unlisted : LibraryBookStatus.listed,
        unlistReason: LibraryUnlistReason.parse(m['unlistReason']),
        unlistNote: _str(m['unlistNote']),
        unlistedAt: _str(m['unlistedAt']),
        unlistedBy: _str(m['unlistedBy']),
        notes: _str(m['notes']),
        createdAt: _str(m['createdAt']),
        lastModified: _str(m['lastModified']),
      );

  /// Editable fields only (stock, status and audit fields are set by the service).
  Map<String, dynamic> toEditableMap() => {
        'title': title,
        'author': author,
        'isbn': isbn,
        'category': category,
        'language': language,
        'shelf': shelf,
        'publisher': publisher,
        'totalCopies': totalCopies,
        'coverUrl': coverUrl,
        'notes': notes,
      };

  LibraryBook copyWith({
    String? title,
    String? author,
    String? isbn,
    String? category,
    String? language,
    String? shelf,
    String? publisher,
    int? totalCopies,
    String? coverUrl,
    String? notes,
  }) =>
      LibraryBook(
        id: id,
        title: title ?? this.title,
        author: author ?? this.author,
        isbn: isbn ?? this.isbn,
        category: category ?? this.category,
        language: language ?? this.language,
        shelf: shelf ?? this.shelf,
        publisher: publisher ?? this.publisher,
        totalCopies: totalCopies ?? this.totalCopies,
        coverUrl: coverUrl ?? this.coverUrl,
        status: status,
        unlistReason: unlistReason,
        unlistNote: unlistNote,
        unlistedAt: unlistedAt,
        unlistedBy: unlistedBy,
        notes: notes ?? this.notes,
        createdAt: createdAt,
        lastModified: lastModified,
      );
}

// ── Member ──────────────────────────────────────────────────────────────────

enum LibraryMemberType {
  student('Student'),
  teacher('Teacher'),
  outsider('Outsider');

  const LibraryMemberType(this.label);
  final String label;

  static LibraryMemberType parse(Object? v) {
    final s = _str(v).toLowerCase();
    if (s.startsWith('student')) return student;
    if (s.startsWith('teacher') || s.startsWith('faculty')) return teacher;
    return outsider;
  }
}

class LibraryMember {
  /// `student:<id>`, `teacher:<id>`, `OUT-…` (outsider record) or
  /// `legacy:<…>` (a borrower typed as free text on an old loan).
  final String id;
  final LibraryMemberType type;
  final String name;

  /// Admission no. / employee id / CNIC.
  final String reference;
  final String phone;
  final String photoUrl;

  /// Class + section for students, designation for teachers, address for outsiders.
  final String detail;
  final bool blocked;

  /// Per-member override of the library's loan limit. Null = the default.
  final int? loanLimit;
  final String notes;

  /// The student / teacher record no longer exists or is inactive.
  final bool inactive;

  const LibraryMember({
    required this.id,
    required this.type,
    required this.name,
    this.reference = '',
    this.phone = '',
    this.photoUrl = '',
    this.detail = '',
    this.blocked = false,
    this.loanLimit,
    this.notes = '',
    this.inactive = false,
  });

  bool get isLegacy => id.startsWith('legacy:');
  bool get isLinkedRecord => type != LibraryMemberType.outsider && !isLegacy;

  static String studentId(String id) => 'student:$id';
  static String teacherId(String id) => 'teacher:$id';
}

// ── Loan ────────────────────────────────────────────────────────────────────

enum LibraryLoanStatus { borrowed, returned, lost }

enum LibraryReturnCondition {
  good('Good'),
  damaged('Damaged'),
  lost('Lost');

  const LibraryReturnCondition(this.label);
  final String label;
}

class LibraryLoan {
  final String id;
  final String bookId;
  final String bookTitle;
  final String memberId;
  final LibraryMemberType memberType;
  final String borrowerName;
  final String borrowerRef;
  final String borrowerPhone;
  final DateTime? issueDate;
  final DateTime? dueDate;
  final LibraryLoanStatus status;
  final DateTime? returnedDate;
  final String condition;
  final String returnRemarks;
  final int fine;
  final String issuedBy;

  const LibraryLoan({
    required this.id,
    required this.bookId,
    this.bookTitle = '',
    this.memberId = '',
    this.memberType = LibraryMemberType.outsider,
    this.borrowerName = '',
    this.borrowerRef = '',
    this.borrowerPhone = '',
    this.issueDate,
    this.dueDate,
    this.status = LibraryLoanStatus.borrowed,
    this.returnedDate,
    this.condition = '',
    this.returnRemarks = '',
    this.fine = 0,
    this.issuedBy = '',
  });

  bool get isOut => status == LibraryLoanStatus.borrowed;

  bool isOverdue(DateTime now) => isOut && dueDate != null && _day(now).isAfter(_day(dueDate!));

  int daysOverdue(DateTime now) {
    if (dueDate == null) return 0;
    final end = isOut ? now : (returnedDate ?? now);
    final d = _day(end).difference(_day(dueDate!)).inDays;
    return d > 0 ? d : 0;
  }

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  LibraryLoan withMemberId(String id) => LibraryLoan(
        id: this.id,
        bookId: bookId,
        bookTitle: bookTitle,
        memberId: id,
        memberType: memberType,
        borrowerName: borrowerName,
        borrowerRef: borrowerRef,
        borrowerPhone: borrowerPhone,
        issueDate: issueDate,
        dueDate: dueDate,
        status: status,
        returnedDate: returnedDate,
        condition: condition,
        returnRemarks: returnRemarks,
        fine: fine,
        issuedBy: issuedBy,
      );

  factory LibraryLoan.fromMap(Map<String, dynamic> m) {
    final statusStr = _str(m['status']);
    return LibraryLoan(
      id: _str(m['id']),
      bookId: _str(m['bookId']),
      bookTitle: _str(m['bookTitle']),
      memberId: _str(m['memberId']),
      memberType: LibraryMemberType.parse(m['memberType'] ?? m['borrowerType']),
      borrowerName: _str(m['borrowerName']),
      borrowerRef: _str(m['borrowerRef']).isNotEmpty ? _str(m['borrowerRef']) : _str(m['borrowerId']),
      borrowerPhone: _str(m['borrowerPhone']),
      issueDate: _date(m['issueDate']),
      dueDate: _date(m['dueDate']),
      status: statusStr == 'returned'
          ? LibraryLoanStatus.returned
          : statusStr == 'lost'
              ? LibraryLoanStatus.lost
              : LibraryLoanStatus.borrowed,
      returnedDate: _date(m['returnedDate']),
      condition: _str(m['condition']),
      returnRemarks: _str(m['returnRemarks']),
      fine: _int(m['fine']),
      issuedBy: _str(m['issuedBy'] ?? m['updatedBy']),
    );
  }
}

// ── Settings ────────────────────────────────────────────────────────────────

class LibrarySettings {
  /// Books one member may hold at once (members can override).
  final int loanLimit;

  /// Default loan period.
  final int loanDays;

  /// Longest allowed loan period.
  final int maxLoanDays;

  /// Fine per overdue day in rupees (0 = no fines).
  final int finePerDay;

  const LibrarySettings({this.loanLimit = 2, this.loanDays = 7, this.maxLoanDays = 90, this.finePerDay = 0});

  factory LibrarySettings.fromMap(Map<String, dynamic>? m) => m == null
      ? const LibrarySettings()
      : LibrarySettings(
          loanLimit: _int(m['loanLimit'], 2).clamp(1, 20),
          loanDays: _int(m['loanDays'], 7).clamp(1, 90),
          maxLoanDays: _int(m['maxLoanDays'], 90).clamp(1, 365),
          finePerDay: _int(m['finePerDay']).clamp(0, 10000),
        );

  Map<String, dynamic> toMap() =>
      {'loanLimit': loanLimit, 'loanDays': loanDays, 'maxLoanDays': maxLoanDays, 'finePerDay': finePerDay};
}

/// The library's fixed category list (old records may carry others; they are kept).
/// The first six match the old library screen so existing books keep their category.
const List<String> libraryCategories = [
  'Islamic Studies',
  'Science & Technology',
  'Mathematics',
  'Literature & English',
  'Social Sciences & History',
  'General Knowledge & Reference',
  'Urdu Literature',
  'Children',
  'General',
];

const List<String> libraryLanguages = ['Urdu', 'English', 'Arabic', 'Other'];
