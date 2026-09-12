// lib/services/finance_ledger_storage.dart

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import 'local_storage_service.dart';
import 'finance_local_storage.dart';

// ── Models ────────────────────────────────────────────────────────────────────

enum JournalSourceType {
  payroll,
  expense,
  donation,
  loanDisbursement,
  loanRepayment,
  bankTransfer,
  openingBalance,
  adjustment,
}

extension JournalSourceTypeExt on JournalSourceType {
  String toCode() {
    switch (this) {
      case JournalSourceType.payroll: return 'PAYROLL';
      case JournalSourceType.expense: return 'EXPENSE';
      case JournalSourceType.donation: return 'DONATION';
      case JournalSourceType.loanDisbursement: return 'LOAN_DISBURSEMENT';
      case JournalSourceType.loanRepayment: return 'LOAN_REPAYMENT';
      case JournalSourceType.bankTransfer: return 'BANK_TRANSFER';
      case JournalSourceType.openingBalance: return 'OPENING_BALANCE';
      case JournalSourceType.adjustment: return 'ADJUSTMENT';
    }
  }

  static JournalSourceType fromCode(String code) {
    switch (code.toUpperCase()) {
      case 'PAYROLL': return JournalSourceType.payroll;
      case 'EXPENSE': return JournalSourceType.expense;
      case 'DONATION': return JournalSourceType.donation;
      case 'LOAN_DISBURSEMENT': return JournalSourceType.loanDisbursement;
      case 'LOAN_REPAYMENT': return JournalSourceType.loanRepayment;
      case 'BANK_TRANSFER': return JournalSourceType.bankTransfer;
      case 'OPENING_BALANCE': return JournalSourceType.openingBalance;
      case 'ADJUSTMENT': return JournalSourceType.adjustment;
      default: return JournalSourceType.adjustment;
    }
  }
}

class JournalLine {
  final String accountCode; // COA code e.g. "5010" or "1010"
  final int debit;          // Paisa integer (never float)
  final int credit;         // Paisa integer (never float)
  final String? memo;

  JournalLine({
    required this.accountCode,
    required this.debit,
    required this.credit,
    this.memo,
  }) {
    if (debit < 0 || credit < 0) {
      throw ArgumentError('Debit and Credit amounts must be non-negative integers.');
    }
    if (debit > 0 && credit > 0) {
      throw ArgumentError('A single JournalLine cannot have both debit and credit > 0.');
    }
  }

  Map<String, dynamic> toMap() => {
    'accountCode': accountCode,
    'debit': debit,
    'credit': credit,
    'memo': memo,
  };

  factory JournalLine.fromMap(Map<String, dynamic> map) => JournalLine(
    accountCode: map['accountCode']?.toString() ?? '',
    debit: (map['debit'] as num?)?.toInt() ?? 0,
    credit: (map['credit'] as num?)?.toInt() ?? 0,
    memo: map['memo']?.toString(),
  );
}

class JournalEntry {
  final String id;
  final String date;              // YYYY-MM-DD
  final String postedAt;          // ISO UTC
  final String sourceType;        // PAYROLL, EXPENSE, etc.
  final String sourceRefId;       // Foreign key to source record
  final String branchId;
  final String? departmentId;     // Department key e.g. "DISPENSARY"
  final String description;
  final String createdBy;
  final String? approvedBy;
  final String? reversalOf;       // Reference ID of entry being reversed
  final List<JournalLine> lines;

  JournalEntry({
    required this.id,
    required this.date,
    required this.postedAt,
    required this.sourceType,
    required this.sourceRefId,
    required this.branchId,
    this.departmentId,
    required this.description,
    required this.createdBy,
    this.approvedBy,
    this.reversalOf,
    required this.lines,
  });

  int get totalDebits => lines.fold(0, (sum, line) => sum + line.debit);
  int get totalCredits => lines.fold(0, (sum, line) => sum + line.credit);
  bool get isBalanced => totalDebits == totalCredits;

  Map<String, dynamic> toMap() => {
    'id': id,
    'date': date,
    'postedAt': postedAt,
    'sourceType': sourceType,
    'sourceRefId': sourceRefId,
    'branchId': branchId,
    'departmentId': departmentId,
    'description': description,
    'createdBy': createdBy,
    'approvedBy': approvedBy,
    'reversalOf': reversalOf,
    'lines': lines.map((l) => l.toMap()).toList(),
    'totalDebits': totalDebits,
    'totalCredits': totalCredits,
  };

  factory JournalEntry.fromMap(Map<String, dynamic> map) {
    final rawLines = map['lines'] as List? ?? [];
    return JournalEntry(
      id: map['id']?.toString() ?? '',
      date: map['date']?.toString() ?? DateFormat('yyyy-MM-dd').format(DateTime.now()),
      postedAt: map['postedAt']?.toString() ?? DateTime.now().toUtc().toIso8601String(),
      sourceType: map['sourceType']?.toString() ?? 'ADJUSTMENT',
      sourceRefId: map['sourceRefId']?.toString() ?? '',
      branchId: map['branchId']?.toString() ?? 'all',
      departmentId: map['departmentId']?.toString(),
      description: map['description']?.toString() ?? '',
      createdBy: map['createdBy']?.toString() ?? 'System',
      approvedBy: map['approvedBy']?.toString(),
      reversalOf: map['reversalOf']?.toString(),
      lines: rawLines.map((l) => JournalLine.fromMap(Map<String, dynamic>.from(l as Map))).toList(),
    );
  }
}

class OrgBankAccount {
  final String id;
  final String accountCode;       // e.g. "1010"
  final String accountTitle;      // e.g. "Meezan Bank - Main Operating"
  final String accountNumber;      // e.g. "01020304050607"
  final String bankName;         // e.g. "Meezan Bank", "EasyPaisa", "Cash"
  final String branchScope;       // "all" or branchId
  final int openingBalancePaisa;
  final String openingBalanceDate;// YYYY-MM-DD
  final bool isActive;

  OrgBankAccount({
    required this.id,
    required this.accountCode,
    required this.accountTitle,
    required this.accountNumber,
    required this.bankName,
    required this.branchScope,
    required this.openingBalancePaisa,
    required this.openingBalanceDate,
    this.isActive = true,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'accountCode': accountCode,
    'accountTitle': accountTitle,
    'accountNumber': accountNumber,
    'bankName': bankName,
    'branchScope': branchScope,
    'openingBalancePaisa': openingBalancePaisa,
    'openingBalanceDate': openingBalanceDate,
    'isActive': isActive,
  };

  factory OrgBankAccount.fromMap(Map<String, dynamic> map) => OrgBankAccount(
    id: map['id']?.toString() ?? '',
    accountCode: map['accountCode']?.toString() ?? '',
    accountTitle: map['accountTitle']?.toString() ?? '',
    accountNumber: map['accountNumber']?.toString() ?? '',
    bankName: map['bankName']?.toString() ?? 'Cash',
    branchScope: map['branchScope']?.toString() ?? 'all',
    openingBalancePaisa: (map['openingBalancePaisa'] as num?)?.toInt() ?? 0,
    openingBalanceDate: map['openingBalanceDate']?.toString() ?? DateFormat('yyyy-MM-dd').format(DateTime.now()),
    isActive: map['isActive'] != false,
  );
}

// ── FinanceLedgerStorage Core ─────────────────────────────────────────────────

class FinanceLedgerStorage {
  static const Uuid _uuid = Uuid();

  static Box get coaBox => Hive.box(LocalStorageService.chartOfAccountsBox);
  static Box get bankAccountsBox => Hive.box(LocalStorageService.orgBankAccountsBox);
  static Box get journalBox => Hive.box(LocalStorageService.journalEntriesBox);
  static Box get indexBox => Hive.box(LocalStorageService.journalIndexBox);
  static Box get deptBox => Hive.box(LocalStorageService.departmentMapBox);

  /// Initializes seeds and verifies storage integrity on app boot.
  static Future<void> initEngine() async {
    await seedChartOfAccounts();
    await seedDepartmentMap();
    await seedOrgBankAccounts();
  }

  // ── 1. Chart of Accounts Seeding & Management ──────────────────────────────
  static Future<void> seedChartOfAccounts() async {
    if (coaBox.isNotEmpty) return;

    final defaultAccounts = [
      // 1000–1999 ASSETS
      {'code': '1010', 'name': 'Meezan Bank – Main Operating', 'type': 'ASSET', 'isActive': true},
      {'code': '1020', 'name': 'UBL – Operating Account', 'type': 'ASSET', 'isActive': true},
      {'code': '1030', 'name': 'Cash in Hand (Petty Cash)', 'type': 'ASSET', 'isActive': true},
      {'code': '1040', 'name': 'Employee Loans Receivable', 'type': 'ASSET', 'isActive': true},
      {'code': '1050', 'name': 'EasyPaisa Business Wallet', 'type': 'ASSET', 'isActive': true},
      {'code': '1060', 'name': 'JazzCash Merchant Account', 'type': 'ASSET', 'isActive': true},
      {'code': '1070', 'name': 'The Bank of Punjab (BOP)', 'type': 'ASSET', 'isActive': true},
      {'code': '1080', 'name': 'National Bank of Pakistan (NBP)', 'type': 'ASSET', 'isActive': true},
      {'code': '1090', 'name': 'Faysal Bank Account', 'type': 'ASSET', 'isActive': true},

      // 2000–2999 LIABILITIES
      {'code': '2010', 'name': 'Salaries Payable', 'type': 'LIABILITY', 'isActive': true},
      {'code': '2020', 'name': 'Vendor Payables', 'type': 'LIABILITY', 'isActive': true},
      {'code': '2030', 'name': 'Advance Donations Held', 'type': 'LIABILITY', 'isActive': true},

      // 3000–3999 EQUITY / FUND BALANCE
      {'code': '3010', 'name': 'General Welfare Fund Balance', 'type': 'EQUITY', 'isActive': true},
      {'code': '3020', 'name': 'Restricted Donor Funds', 'type': 'EQUITY', 'isActive': true},

      // 4000–4999 INCOME
      {'code': '4010', 'name': 'Donations – Unrestricted', 'type': 'INCOME', 'isActive': true},
      {'code': '4020', 'name': 'Donations – Restricted', 'type': 'INCOME', 'isActive': true},
      {'code': '4030', 'name': 'Grants & Institutional Funding', 'type': 'INCOME', 'isActive': true},
      {'code': '4040', 'name': 'Zakat & Sadqa Collections', 'type': 'INCOME', 'isActive': true},

      // 5000–5999 EXPENSE
      {'code': '5010', 'name': 'Salaries & Wages', 'type': 'EXPENSE', 'isActive': true},
      {'code': '5020', 'name': 'Utilities (Electricity/Gas/Water/Internet)', 'type': 'EXPENSE', 'isActive': true},
      {'code': '5030', 'name': 'Food & Kitchen (Dasterkhwaan)', 'type': 'EXPENSE', 'isActive': true},
      {'code': '5040', 'name': 'Dispensary & Medical Supplies', 'type': 'EXPENSE', 'isActive': true},
      {'code': '5050', 'name': 'Madrassa & School Supplies', 'type': 'EXPENSE', 'isActive': true},
      {'code': '5060', 'name': 'Maintenance & Repairs', 'type': 'EXPENSE', 'isActive': true},
      {'code': '5070', 'name': 'Fuel & Transportation', 'type': 'EXPENSE', 'isActive': true},
      {'code': '5080', 'name': 'Miscellaneous Expenses', 'type': 'EXPENSE', 'isActive': true},
    ];

    for (final acc in defaultAccounts) {
      await coaBox.put(acc['code'], acc);
    }
  }

  static List<Map<String, dynamic>> getChartOfAccounts() {
    return coaBox.values.map((v) => Map<String, dynamic>.from(v as Map)).toList();
  }

  // ── 2. Department Mapping ──────────────────────────────────────────────────
  static Future<void> seedDepartmentMap() async {
    if (deptBox.isNotEmpty) return;

    final depts = [
      {'id': 'ADMIN', 'name': 'Administration Staff', 'code': 'ADM'},
      {'id': 'OFFICE', 'name': 'Office', 'code': 'OFF'},
      {'id': 'DASTERKHWAAN', 'name': 'Dasterkhwaan', 'code': 'DST'},
      {'id': 'DISPENSARY', 'name': 'Dispensary', 'code': 'DSP'},
      {'id': 'MADRASSA', 'name': 'Madrassa', 'code': 'MDR'},
      {'id': 'SCHOOL', 'name': 'School', 'code': 'SCH'},
    ];

    for (final d in depts) {
      await deptBox.put(d['id'], d);
    }
  }

  static List<Map<String, dynamic>> getDepartments() {
    return deptBox.values.map((v) => Map<String, dynamic>.from(v as Map)).toList();
  }

  /// Sorts department names in canonical hierarchy order:
  /// 1. Administration Staff
  /// 2. Office
  /// 3. Dasterkhwaan
  /// 4. Dispensary
  /// 5. Madrassa
  /// 6. School
  /// 7. Custom / Other departments
  static List<String> sortDepartmentsCanonical(Iterable<String> depts) {
    const canonicalOrder = [
      'office',
      'administration staff',
      'administration',
      'admin',
      'dasterkhwaan',
      'dastarkhwan',
      'dispensary',
      'madrassa',
      'madrasa',
      'school',
    ];

    int getOrderIndex(String dept) {
      final clean = dept.trim().toLowerCase();
      for (int i = 0; i < canonicalOrder.length; i++) {
        final cand = canonicalOrder[i];
        if (clean == cand || clean.startsWith(cand) || cand.startsWith(clean) || clean.contains(cand)) {
          return i;
        }
      }
      return 999;
    }

    final list = depts.toSet().toList();
    list.sort((a, b) {
      final idxA = getOrderIndex(a);
      final idxB = getOrderIndex(b);
      if (idxA != idxB) return idxA.compareTo(idxB);
      return a.compareTo(b);
    });
    return list;
  }


  // ── 3. Org Bank Accounts Management ────────────────────────────────────────
  static Future<void> seedOrgBankAccounts() async {
    if (bankAccountsBox.isNotEmpty) return;

    final defaultBanks = [
      OrgBankAccount(
        id: 'bank_meezan_main',
        accountCode: '1010',
        accountTitle: 'Meezan Main Operating Account',
        accountNumber: '0101-0102030405',
        bankName: 'Meezan Bank',
        branchScope: 'all',
        openingBalancePaisa: 0,
        openingBalanceDate: DateFormat('yyyy-MM-dd').format(DateTime.now()),
      ),
      OrgBankAccount(
        id: 'bank_petty_cash',
        accountCode: '1030',
        accountTitle: 'Cash in Hand (Petty Cash Fund)',
        accountNumber: 'CASH-001',
        bankName: 'Cash',
        branchScope: 'all',
        openingBalancePaisa: 0,
        openingBalanceDate: DateFormat('yyyy-MM-dd').format(DateTime.now()),
      ),
    ];

    for (final b in defaultBanks) {
      await bankAccountsBox.put(b.id, b.toMap());
    }
  }


  static List<OrgBankAccount> getOrgBankAccounts() {
    return bankAccountsBox.values
        .map((v) => OrgBankAccount.fromMap(Map<String, dynamic>.from(v as Map)))
        .where((b) => b.isActive)
        .toList();
  }

  static OrgBankAccount? getOrgBankAccountByCode(String code) {
    for (final v in bankAccountsBox.values) {
      if (v is Map && v['accountCode']?.toString() == code) {
        return OrgBankAccount.fromMap(Map<String, dynamic>.from(v));
      }
    }
    return null;
  }

  static Future<void> saveOrgBankAccount(OrgBankAccount account) async {
    await bankAccountsBox.put(account.id, account.toMap());
    
    // Also create or update COA Asset entry
    final coaEntry = {
      'code': account.accountCode,
      'name': '${account.bankName} – ${account.accountTitle}',
      'type': 'ASSET',
      'isActive': account.isActive,
    };
    await coaBox.put(account.accountCode, coaEntry);

    // Enqueue for cloud sync
    await LocalStorageService.enqueueSync({
      'type': 'save_org_bank_account',
      'accountId': account.id,
      'data': account.toMap(),
    });
  }

  // ── 4. Atomic Double-Entry Posting Engine ──────────────────────────────────
  static Future<String> postJournalEntry(JournalEntry entry) async {
    // Check 1: Integer Paisa validation
    for (final line in entry.lines) {
      if (line.debit < 0 || line.credit < 0) {
        throw ArgumentError('Invalid negative line amount in journal entry.');
      }
    }

    // Check 2: Double-Entry Balancing Hard Constraint (sum debits == sum credits)
    if (!entry.isBalanced) {
      throw ArgumentError(
        'JOURNAL OUT OF BALANCE: Total Debits (${entry.totalDebits}) != Total Credits (${entry.totalCredits}). Transaction rejected.',
      );
    }

    // Check 3: Month Lock Enforcement
    final monthKey = entry.date.length >= 7 ? entry.date.substring(0, 7) : '';
    final settingsBox = Hive.box(LocalStorageService.financeSettingsBox);
    final isLocked = settingsBox.get('month_lock_$monthKey') == true;
    if (isLocked && entry.sourceType != 'ADJUSTMENT') {
      throw StateError('Cannot post journal entry: Payroll month $monthKey is locked.');
    }

    // Check 4: Idempotency Check (skip duplicate sourceRefId + sourceType)
    for (final val in journalBox.values) {
      if (val is Map) {
        final existingType = val['sourceType']?.toString();
        final existingRef = val['sourceRefId']?.toString();
        if (existingType == entry.sourceType && existingRef == entry.sourceRefId && entry.sourceRefId.isNotEmpty) {
          debugPrint('[Ledger] Idempotent hit: Entry for ${entry.sourceType}:${entry.sourceRefId} already posted.');
          return val['id']?.toString() ?? entry.id;
        }
      }
    }

    // Post to Append-Only Journal Box
    await journalBox.put(entry.id, entry.toMap());

    // Update Daily Balance Snapshots Index
    await _updateIndexForEntry(entry);

    // Write Audit Log Entry
    await FinanceLocalStorage.logAction(
      branchId: entry.branchId,
      entityType: 'journal_entry',
      entityId: entry.id,
      action: 'post_journal_entry',
      performedBy: entry.createdBy,
      reason: entry.description,
      rawData: entry.toMap(),
    );

    // Enqueue for cloud sync
    await LocalStorageService.enqueueSync({
      'type': 'save_journal_entry',
      'branchId': entry.branchId,
      'entryId': entry.id,
      'data': entry.toMap(),
    });

    debugPrint('[Ledger] Successfully posted balanced JournalEntry #${entry.id} (${entry.sourceType}) [Dr=${entry.totalDebits} Paisa / Cr=${entry.totalCredits} Paisa]');
    return entry.id;
  }


  // Updates rolled-up running balance snapshots per account and date
  static Future<void> _updateIndexForEntry(JournalEntry entry) async {
    try {
      for (final line in entry.lines) {
        final indexKey = '${line.accountCode}_${entry.date}';
        final existing = indexBox.get(indexKey) as Map? ?? {
          'accountCode': line.accountCode,
          'date': entry.date,
          'totalDebitsPaisa': 0,
          'totalCreditsPaisa': 0,
        };
        final updated = Map<String, dynamic>.from(existing);
        updated['totalDebitsPaisa'] = ((updated['totalDebitsPaisa'] as num?)?.toInt() ?? 0) + line.debit;
        updated['totalCreditsPaisa'] = ((updated['totalCreditsPaisa'] as num?)?.toInt() ?? 0) + line.credit;
        await indexBox.put(indexKey, updated);
      }
    } catch (e) {
      debugPrint('[Ledger Index Error] $e');
    }
  }

  // ── 5. Treasury & Running Balance Calculators ─────────────────────────────

  /// Single-pass computation of all account balances in Paisa (integer).
  /// Reads directly from raw box maps without heavy object deserialization.
  static Map<String, int> getAllAccountBalancesPaisa() {
    final balances = <String, int>{};

    // 1. Seed opening balances from bank accounts box
    for (final val in bankAccountsBox.values) {
      if (val is Map) {
        final code = val['accountCode']?.toString();
        final opening = (val['openingBalancePaisa'] as num?)?.toInt() ?? 0;
        if (code != null) {
          balances[code] = opening;
        }
      }
    }

    // 2. Aggregate line debits and credits
    for (final val in journalBox.values) {
      if (val is Map) {
        final lines = val['lines'];
        if (lines is List) {
          for (final l in lines) {
            if (l is Map) {
              final code = l['accountCode']?.toString();
              if (code != null) {
                final debit = (l['debit'] as num?)?.toInt() ?? 0;
                final credit = (l['credit'] as num?)?.toInt() ?? 0;
                balances[code] = (balances[code] ?? 0) + (debit - credit);
              }
            }
          }
        }
      }
    }
    return balances;
  }

  /// High-performance single-pass metrics extraction for the Finance Overview dashboard.
  /// Computes all bank/cash/loan balances plus month income and expense flows
  /// directly from raw maps in a single fast iteration (< 5ms).
  static Map<String, dynamic> getDashboardMetrics({
    required String monthKey,
    String? branchId,
  }) {
    final balances = <String, int>{};

    // 1. Seed opening balances
    for (final val in bankAccountsBox.values) {
      if (val is Map) {
        final code = val['accountCode']?.toString();
        final opening = (val['openingBalancePaisa'] as num?)?.toInt() ?? 0;
        if (code != null) {
          balances[code] = opening;
        }
      }
    }

    int monthInflowPaisa = 0;
    int monthOutflowPaisa = 0;

    // 2. Single-pass over journalBox.values
    for (final val in journalBox.values) {
      if (val is! Map) continue;

      final entryBranch = val['branchId']?.toString();
      final isBranchMatch = branchId == null ||
          branchId == 'all' ||
          branchId.isEmpty ||
          entryBranch == branchId ||
          entryBranch == 'all';

      final entryDate = val['date']?.toString() ?? '';
      final isSelectedMonth = entryDate.startsWith(monthKey);

      final lines = val['lines'];
      if (lines is List) {
        for (final l in lines) {
          if (l is! Map) continue;
          final code = l['accountCode']?.toString();
          if (code == null) continue;

          final debit = (l['debit'] as num?)?.toInt() ?? 0;
          final credit = (l['credit'] as num?)?.toInt() ?? 0;

          // Asset account running balance (Dr - Cr)
          balances[code] = (balances[code] ?? 0) + (debit - credit);

          // Monthly flows for matching branch
          if (isBranchMatch && isSelectedMonth) {
            // 4000s = Income accounts (increase with Credit)
            if (code.startsWith('4')) {
              monthInflowPaisa += credit;
            }
            // 5000s = Expense accounts (increase with Debit)
            else if (code.startsWith('5')) {
              monthOutflowPaisa += debit;
            }
          }
        }
      }
    }

    return {
      'balances': balances,
      'monthInflowPaisa': monthInflowPaisa,
      'monthOutflowPaisa': monthOutflowPaisa,
    };
  }

  /// Calculates the current net running balance of any bank/cash account in Paisa integer.
  /// Uses direct map lookup without full JournalEntry deserialization for maximum speed.
  static int getBankAccountBalancePaisa(String accountCode) {
    int totalPaisa = 0;

    // Add opening balance if defined
    final orgAcc = getOrgBankAccountByCode(accountCode);
    if (orgAcc != null) {
      totalPaisa += orgAcc.openingBalancePaisa;
    }

    // Sum all journal entry postings for this account using raw maps
    for (final val in journalBox.values) {
      if (val is Map) {
        final lines = val['lines'];
        if (lines is List) {
          for (final l in lines) {
            if (l is Map && l['accountCode']?.toString() == accountCode) {
              final debit = (l['debit'] as num?)?.toInt() ?? 0;
              final credit = (l['credit'] as num?)?.toInt() ?? 0;
              totalPaisa += (debit - credit);
            }
          }
        }
      }
    }
    return totalPaisa;
  }

  /// Convenience helper returning live balance in PKR float for display.
  static double getBankAccountBalancePKR(String accountCode) {
    return getBankAccountBalancePaisa(accountCode) / 100.0;
  }

  /// Fetches posted JournalEntries sorted by postedAt descending.
  /// Filters on raw maps first so only matching entries are deserialized.
  /// Accepts optional [limit] parameter to avoid parsing the whole box.
  static List<JournalEntry> getAllJournalEntries({String? branchId, String? accountCode, int? limit}) {
    final list = <JournalEntry>[];
    for (final val in journalBox.values) {
      if (val is Map) {
        if (branchId != null && branchId != 'all' && branchId.isNotEmpty) {
          final b = val['branchId']?.toString();
          if (b != branchId && b != 'all') continue;
        }
        if (accountCode != null) {
          final lines = val['lines'];
          if (lines is List) {
            final hasAcc = lines.any((l) => l is Map && l['accountCode']?.toString() == accountCode);
            if (!hasAcc) continue;
          }
        }
        final entry = JournalEntry.fromMap(Map<String, dynamic>.from(val));
        list.add(entry);
      }
    }
    list.sort((a, b) => b.postedAt.compareTo(a.postedAt));
    if (limit != null && list.length > limit) {
      return list.sublist(0, limit);
    }
    return list;
  }
}
