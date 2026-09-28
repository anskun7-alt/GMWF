// lib/pages/school/views/school_library_view.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import '../../../services/local_storage_service.dart';
import '../utils/school_local_storage.dart';
import '../utils/school_auth_helper.dart';
import '../theme/school_theme.dart';

class CnicInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    var digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length > 13) digits = digits.substring(0, 13);
    final buf = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      if (i == 5 || i == 12) buf.write('-');
      buf.write(digits[i]);
    }
    final formatted = buf.toString();
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

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

class _SchoolLibraryViewState extends State<SchoolLibraryView> {
  final TextEditingController _searchCtrl = TextEditingController();
  final TextEditingController _loanSearchCtrl = TextEditingController();

  String _selectedCategory = 'All';
  String _selectedLoanStatusFilter = 'All';

  bool get _isTeacher => SchoolAuthHelper.isTeacher(widget.userRole);

  final List<String> _categories = [
    'All',
    'Science & Technology',
    'Mathematics',
    'Literature & English',
    'Islamic Studies',
    'Social Sciences & History',
    'General Knowledge & Reference',
  ];

  late Future<void> _initFuture;

  @override
  void initState() {
    super.initState();
    _initFuture = SchoolLocalStorage.ensureBoxesOpen();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _loanSearchCtrl.dispose();
    super.dispose();
  }

  void _openAddBookDialog([Map<String, dynamic>? bookToEdit]) async {
    final titleCtrl = TextEditingController(text: bookToEdit?['title'] ?? '');
    final authorCtrl = TextEditingController(text: bookToEdit?['author'] ?? '');
    final isbnCtrl = TextEditingController(text: bookToEdit?['isbn'] ?? '');
    final copiesCtrl = TextEditingController(text: (bookToEdit?['totalCopies'] ?? 1).toString());
    String category = bookToEdit?['category'] ?? _categories[1];

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: [
                const Icon(Icons.local_library_rounded, color: Color(0xFF6366F1)),
                const SizedBox(width: 10),
                Text(bookToEdit != null ? 'Edit Library Book' : 'Add New Book to Catalog'),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: titleCtrl,
                    decoration: const InputDecoration(labelText: 'Book Title *'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: authorCtrl,
                    decoration: const InputDecoration(labelText: 'Author Name *'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: isbnCtrl,
                    decoration: const InputDecoration(labelText: 'ISBN / Accession Number'),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: category,
                    decoration: const InputDecoration(labelText: 'Category'),
                    items: _categories
                        .where((c) => c != 'All')
                        .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) setDlgState(() => category = v);
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: copiesCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Total Copies'),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6366F1),
                  foregroundColor: Colors.white,
                ),
                onPressed: () async {
                  if (titleCtrl.text.trim().isEmpty) return;
                  final bookId = bookToEdit?['id'] ?? 'BK-${DateTime.now().millisecondsSinceEpoch}';
                  final totalCopies = int.tryParse(copiesCtrl.text.trim()) ?? 1;

                  final bookData = {
                    'id': bookId,
                    'title': titleCtrl.text.trim(),
                    'author': authorCtrl.text.trim(),
                    'isbn': isbnCtrl.text.trim(),
                    'category': category,
                    'totalCopies': totalCopies,
                    'availableCopies': totalCopies,
                    'branchId': widget.branchId,
                    'updatedAt': DateTime.now().toIso8601String(),
                  };

                  await SchoolLocalStorage.saveBook(
                    branchId: widget.branchId,
                    bookId: bookId,
                    bookData: bookData,
                  );

                  // Audit Log
                  await SchoolLocalStorage.logAudit(
                    branchId: widget.branchId,
                    action: bookToEdit != null ? 'EDIT_BOOK' : 'ADD_BOOK',
                    user: widget.userName,
                    details: 'Book: "${titleCtrl.text.trim()}" (ISBN: ${isbnCtrl.text.trim()})',
                  );

                  if (mounted) Navigator.pop(ctx);
                },
                child: const Text('Save Book'),
              ),
            ],
          );
        },
      ),
    );
    setState(() {});
  }

  void _openIssueBookDialog(Map<String, dynamic> book) async {
    final borrowerNameCtrl = TextEditingController();
    final borrowerIdCtrl = TextEditingController(); // Roll / Emp / CNIC
    final borrowerPhoneCtrl = TextEditingController();
    String borrowerType = 'Student'; // 'Student', 'Teacher', 'Outsider'
    DateTime dueDate = DateTime.now().add(const Duration(days: 7));

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          String idLabel = 'ID';
          if (borrowerType == 'Student') idLabel = 'ID (Roll No)';
          if (borrowerType == 'Teacher') idLabel = 'ID (Employee ID)';
          if (borrowerType == 'Outsider') idLabel = 'ID (CNIC) *';

          final isOutsider = borrowerType == 'Outsider';

          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: [
                const Icon(Icons.output_rounded, color: Color(0xFF10B981)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Issue Book: "${book['title']}"',
                    style: const TextStyle(fontSize: 18),
                  ),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<String>(
                    value: borrowerType,
                    decoration: const InputDecoration(labelText: 'Borrower Category'),
                    items: const [
                      DropdownMenuItem(value: 'Student', child: Text('Student')),
                      DropdownMenuItem(value: 'Teacher', child: Text('Teacher / Faculty')),
                      DropdownMenuItem(value: 'Outsider', child: Text('Outsider / Guest Borrower')),
                    ],
                    onChanged: (v) {
                      if (v != null) {
                        setDlgState(() {
                          borrowerType = v;
                          borrowerIdCtrl.clear();
                        });
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: borrowerNameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Borrower Full Name *',
                      hintText: 'Enter full name',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: borrowerIdCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: isOutsider ? [CnicInputFormatter()] : [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: idLabel,
                      hintText: isOutsider ? '35201-1234567-1' : 'e.g. Roll No, Employee ID, or CNIC',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: borrowerPhoneCtrl,
                    keyboardType: TextInputType.phone,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: isOutsider ? 'Phone Number *' : 'Contact Phone Number',
                      hintText: '03001234567',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Text('Due Return Date: ', style: TextStyle(fontWeight: FontWeight.bold)),
                      Text(DateFormat('dd MMM yyyy').format(dueDate)),
                      const Spacer(),
                      TextButton(
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: ctx,
                            initialDate: dueDate,
                            firstDate: DateTime.now(),
                            lastDate: DateTime.now().add(const Duration(days: 90)),
                          );
                          if (picked != null) setDlgState(() => dueDate = picked);
                        },
                        child: const Text('Select Date'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                  foregroundColor: Colors.white,
                ),
                onPressed: () async {
                  final name = borrowerNameCtrl.text.trim();
                  final idNum = borrowerIdCtrl.text.trim();
                  final phone = borrowerPhoneCtrl.text.trim();

                  if (name.isEmpty) return;
                  if (borrowerType == 'Outsider' && (idNum.isEmpty || phone.isEmpty)) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('Outsider borrowers require valid CNIC and Phone Number!')),
                    );
                    return;
                  }

                  final loanId = 'LN-${DateTime.now().millisecondsSinceEpoch}';
                  final loanData = {
                    'id': loanId,
                    'bookId': book['id'],
                    'bookTitle': book['title'],
                    'borrowerName': name,
                    'borrowerType': borrowerType,
                    'borrowerId': idNum,
                    'borrowerPhone': phone,
                    'issueDate': DateTime.now().toIso8601String(),
                    'dueDate': dueDate.toIso8601String(),
                    'status': 'borrowed',
                    'branchId': widget.branchId,
                  };

                  await SchoolLocalStorage.saveBookLoan(
                    branchId: widget.branchId,
                    loanId: loanId,
                    loanData: loanData,
                  );

                  // Update available copies
                  final currAvailable = (book['availableCopies'] as int? ?? 1) - 1;
                  book['availableCopies'] = currAvailable.clamp(0, 99999);
                  await SchoolLocalStorage.saveBook(
                    branchId: widget.branchId,
                    bookId: book['id'] ?? '',
                    bookData: Map<String, dynamic>.from(book),
                  );

                  // Audit Log
                  await SchoolLocalStorage.logAudit(
                    branchId: widget.branchId,
                    action: 'ISSUE_BOOK',
                    user: widget.userName,
                    details: 'Issued "${book['title']}" to $borrowerType: $name ($idNum)',
                  );

                  if (mounted) Navigator.pop(ctx);
                },
                child: const Text('Confirm Issue'),
              ),
            ],
          );
        },
      ),
    );
    setState(() {});
  }

  Future<void> _markBookReturned(Map<String, dynamic> loan) async {
    DateTime returnDate = DateTime.now();
    final remarksCtrl = TextEditingController();

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: const [
                Icon(Icons.assignment_return_rounded, color: Color(0xFF10B981)),
                SizedBox(width: 10),
                Text('Mark Book as Returned'),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Book: "${loan['bookTitle']}"',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Borrower: ${loan['borrowerName']} (${loan['borrowerType'] ?? "Guest"})',
                    style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  const Text('Manual Return Date *', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 6),
                  InkWell(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: returnDate,
                        firstDate: DateTime(2024),
                        lastDate: DateTime.now().add(const Duration(days: 365)),
                      );
                      if (picked != null) setDlgState(() => returnDate = picked);
                    },
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.calendar_today_rounded, size: 18, color: Color(0xFF10B981)),
                          const SizedBox(width: 10),
                          Text(
                            DateFormat('EEEE, dd MMM yyyy').format(returnDate),
                            style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
                          ),
                          const Spacer(),
                          const Text('Change', style: TextStyle(color: Color(0xFF10B981), fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: remarksCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Return Remarks (Optional)',
                      hintText: 'e.g. Returned on time in good condition',
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Confirm Return'),
              ),
            ],
          );
        },
      ),
    );

    if (confirm != true) return;

    final loanId = loan['id'];
    final bookId = loan['bookId'];

    // Update loan status to returned
    loan['status'] = 'returned';
    loan['returnedDate'] = returnDate.toIso8601String();
    if (remarksCtrl.text.trim().isNotEmpty) {
      loan['returnRemarks'] = remarksCtrl.text.trim();
    }
    final loansBox = Hive.box(LocalStorageService.schoolBookLoansBox);
    await loansBox.put('${widget.branchId.toLowerCase()}__$loanId', loan);

    // Restore available copy
    final booksBox = Hive.box(LocalStorageService.schoolBooksBox);
    final bookKey = '${widget.branchId.toLowerCase()}__$bookId';
    final bookRaw = booksBox.get(bookKey);
    if (bookRaw != null) {
      final book = Map<String, dynamic>.from(bookRaw as Map);
      final currentAvailable = (book['availableCopies'] as int? ?? 0) + 1;
      final total = (book['totalCopies'] as int? ?? 1);
      book['availableCopies'] = currentAvailable > total ? total : currentAvailable;
      await booksBox.put(bookKey, book);
    }

    // Audit Log
    await SchoolLocalStorage.logAudit(
      branchId: widget.branchId,
      action: 'RETURN_BOOK',
      user: widget.userName,
      details: 'Book "${loan['bookTitle']}" returned by ${loan['borrowerName']} (Return Date: ${DateFormat('dd MMM yyyy').format(returnDate)})',
    );

    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _initFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            backgroundColor: Color(0xFFF8FAFC),
            body: Center(child: CircularProgressIndicator(color: Color(0xFF6366F1))),
          );
        }

        return DefaultTabController(
          length: 2,
          child: Scaffold(
            backgroundColor: const Color(0xFFF8FAFC),
            appBar: PreferredSize(
              preferredSize: const Size.fromHeight(48),
              child: Container(
                color: Colors.white,
                child: const TabBar(
                  indicatorColor: Color(0xFF6366F1),
                  labelColor: Color(0xFF6366F1),
                  unselectedLabelColor: Color(0xFF64748B),
                  labelStyle: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  tabs: [
                    Tab(text: 'Book Catalog & Inventory', icon: Icon(Icons.menu_book_rounded, size: 18)),
                    Tab(text: 'Borrowed & Issued Loans', icon: Icon(Icons.assignment_turned_in_rounded, size: 18)),
                  ],
                ),
              ),
            ),
            body: TabBarView(
              children: [
                _buildCatalogTab(),
                _buildLoansTab(),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCatalogTab() {
    return Column(
      children: [
        // Catalog Toolbar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          color: Colors.white,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isNarrow = constraints.maxWidth < 650;
              if (isNarrow) {
                return Column(
                  children: [
                    TextField(
                      controller: _searchCtrl,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        hintText: 'Search books by title, author, or ISBN...',
                        prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF6366F1), size: 20),
                        filled: true,
                        fillColor: const Color(0xFFF8FAFC),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF1F5F9),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: _selectedCategory,
                                isExpanded: true,
                                items: _categories.map((c) {
                                  return DropdownMenuItem(value: c, child: Text('Cat: $c', style: const TextStyle(fontSize: 12)));
                                }).toList(),
                                onChanged: (v) {
                                  if (v != null) setState(() => _selectedCategory = v);
                                },
                              ),
                            ),
                          ),
                        ),
                        if (!_isTeacher) ...[
                          const SizedBox(width: 8),
                          ElevatedButton.icon(
                            onPressed: () => _openAddBookDialog(),
                            icon: const Icon(Icons.add_rounded, size: 16),
                            label: const Text('Add Book', style: TextStyle(fontSize: 12)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: SchoolTheme.primary,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                );
              }

              return Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchCtrl,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        hintText: 'Search books by title, author, or ISBN...',
                        prefixIcon: const Icon(Icons.search_rounded, color: SchoolTheme.primary),
                        filled: true,
                        fillColor: const Color(0xFFF8FAFC),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  DropdownButtonHideUnderline(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: DropdownButton<String>(
                        value: _selectedCategory,
                        items: _categories.map((c) {
                          return DropdownMenuItem(value: c, child: Text('Category: $c'));
                        }).toList(),
                        onChanged: (v) {
                          if (v != null) setState(() => _selectedCategory = v);
                        },
                      ),
                    ),
                  ),
                  if (!_isTeacher) ...[
                    const SizedBox(width: 16),
                    ElevatedButton.icon(
                      onPressed: () => _openAddBookDialog(),
                      icon: const Icon(Icons.add_rounded, size: 16),
                      label: const Text('Add Book', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: SchoolTheme.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
        const Divider(height: 1),

        // Catalog List
        Expanded(
          child: ValueListenableBuilder<Box>(
            valueListenable: Hive.box(LocalStorageService.schoolBooksBox).listenable(),
            builder: (context, box, _) {
              final prefix = '${widget.branchId.toLowerCase()}__';
              final books = box.keys
                  .where((k) => k.toString().startsWith(prefix))
                  .map((k) => Map<String, dynamic>.from(box.get(k) as Map))
                  .toList();

              final query = _searchCtrl.text.trim().toLowerCase();
              var filtered = books;

              if (query.isNotEmpty) {
                filtered = filtered.where((b) {
                  final title = (b['title'] ?? '').toString().toLowerCase();
                  final author = (b['author'] ?? '').toString().toLowerCase();
                  final isbn = (b['isbn'] ?? '').toString().toLowerCase();
                  return title.contains(query) || author.contains(query) || isbn.contains(query);
                }).toList();
              }

              if (_selectedCategory != 'All') {
                filtered = filtered.where((b) => (b['category'] ?? '') == _selectedCategory).toList();
              }

              if (filtered.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.menu_book_rounded, size: 64, color: Colors.grey.shade300),
                      const SizedBox(height: 12),
                      const Text(
                        'No books found in Library Catalog',
                        style: TextStyle(color: Colors.grey, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Click "+ Add Book" to add books to your school library.',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                );
              }

              return ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: filtered.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final book = filtered[index];
                  final available = (book['availableCopies'] as int? ?? 0);
                  final total = (book['totalCopies'] as int? ?? 1);

                  return Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: const Color(0xFF6366F1).withValues(alpha: 0.1),
                          child: const Icon(Icons.book_rounded, color: Color(0xFF6366F1)),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          flex: 3,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                book['title'] ?? 'Untitled Book',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'By ${book['author']} • ${book['category']}',
                                style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: available > 0
                                ? const Color(0xFF10B981).withValues(alpha: 0.1)
                                : const Color(0xFFEF4444).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            'Available: $available / $total',
                            style: TextStyle(
                              color: available > 0 ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        ElevatedButton.icon(
                          onPressed: available > 0 ? () => _openIssueBookDialog(book) : null,
                          icon: const Icon(Icons.output_rounded, size: 16),
                          label: const Text('Issue Book'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF10B981),
                            foregroundColor: Colors.white,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.edit_rounded, color: Colors.grey),
                          onPressed: () => _openAddBookDialog(book),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildLoansTab() {
    return Column(
      children: [
        // Loans Toolbar
        Container(
          padding: const EdgeInsets.all(16),
          color: Colors.white,
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _loanSearchCtrl,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'Search loans by borrower name, book title, CNIC, or Roll No...',
                    prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF10B981)),
                    filled: true,
                    fillColor: const Color(0xFFF8FAFC),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              DropdownButtonHideUnderline(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: DropdownButton<String>(
                    value: _selectedLoanStatusFilter,
                    items: const [
                      DropdownMenuItem(value: 'All', child: Text('Status: All')),
                      DropdownMenuItem(value: 'borrowed', child: Text('Currently Borrowed')),
                      DropdownMenuItem(value: 'returned', child: Text('Returned')),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _selectedLoanStatusFilter = v);
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),

        // Loans List
        Expanded(
          child: ValueListenableBuilder<Box>(
            valueListenable: Hive.box(LocalStorageService.schoolBookLoansBox).listenable(),
            builder: (context, box, _) {
              final prefix = '${widget.branchId.toLowerCase()}__';
              final loans = box.keys
                  .where((k) => k.toString().startsWith(prefix))
                  .map((k) => Map<String, dynamic>.from(box.get(k) as Map))
                  .toList();

              final query = _loanSearchCtrl.text.trim().toLowerCase();
              var filtered = loans;

              if (query.isNotEmpty) {
                filtered = filtered.where((l) {
                  final title = (l['bookTitle'] ?? '').toString().toLowerCase();
                  final borrower = (l['borrowerName'] ?? '').toString().toLowerCase();
                  final bId = (l['borrowerId'] ?? '').toString().toLowerCase();
                  return title.contains(query) || borrower.contains(query) || bId.contains(query);
                }).toList();
              }

              if (_selectedLoanStatusFilter != 'All') {
                filtered = filtered.where((l) => (l['status'] ?? 'borrowed') == _selectedLoanStatusFilter).toList();
              }

              if (filtered.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.assignment_turned_in_rounded, size: 64, color: Colors.grey.shade300),
                      const SizedBox(height: 12),
                      const Text(
                        'No book loan records found',
                        style: TextStyle(color: Colors.grey, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Issued books to Students, Teachers, or Outsiders will appear here.',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                );
              }

              return ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: filtered.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final loan = filtered[index];
                  final status = (loan['status'] ?? 'borrowed').toString();
                  final isBorrowed = status == 'borrowed';

                  final dueDateStr = loan['dueDate'] ?? '';
                  DateTime? dueDate;
                  if (dueDateStr.isNotEmpty) dueDate = DateTime.tryParse(dueDateStr);
                  final isOverdue = isBorrowed && dueDate != null && DateTime.now().isAfter(dueDate);

                  Color badgeColor = isBorrowed ? const Color(0xFFF59E0B) : const Color(0xFF10B981);
                  if (isOverdue) badgeColor = const Color(0xFFEF4444);

                  return Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: badgeColor.withValues(alpha: 0.1),
                          child: Icon(
                            isBorrowed ? Icons.bookmark_outlined : Icons.check_circle_rounded,
                            color: badgeColor,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          flex: 3,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                loan['bookTitle'] ?? 'Book',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Borrower: ${loan['borrowerName']} (${loan['borrowerType'] ?? "Guest"}) • ID/CNIC: ${loan['borrowerId'] ?? "N/A"}',
                                style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
                              ),
                              if ((loan['borrowerPhone'] ?? '').isNotEmpty)
                                Text(
                                  'Phone: ${loan['borrowerPhone']}',
                                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                                ),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: badgeColor.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                isOverdue ? 'OVERDUE' : status.toUpperCase(),
                                style: TextStyle(color: badgeColor, fontWeight: FontWeight.bold, fontSize: 11),
                              ),
                            ),
                            const SizedBox(height: 4),
                             Text(
                                isBorrowed
                                    ? (dueDate != null ? 'Due: ${DateFormat("dd MMM yyyy").format(dueDate)}' : '')
                                    : (loan['returnedDate'] != null
                                        ? 'Returned: ${DateFormat("dd MMM yyyy").format(DateTime.parse(loan['returnedDate']))}'
                                        : 'Returned'),
                                style: TextStyle(
                                  color: isOverdue
                                      ? Colors.red
                                      : isBorrowed
                                          ? Colors.grey.shade600
                                          : const Color(0xFF10B981),
                                  fontWeight: isBorrowed ? FontWeight.normal : FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(width: 16),
                        if (isBorrowed)
                          ElevatedButton.icon(
                            onPressed: () => _markBookReturned(loan),
                            icon: const Icon(Icons.check_circle_outline, size: 16),
                            label: const Text('Mark Returned'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF10B981),
                              foregroundColor: Colors.white,
                            ),
                          ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
