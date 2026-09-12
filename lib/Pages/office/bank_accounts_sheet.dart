// lib/pages/office/bank_accounts_sheet.dart

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../services/finance_ledger_storage.dart';
import '../../widgets/bank_logo_widget.dart';

class BankAccountsSheet extends StatefulWidget {
  final VoidCallback onSaved;

  const BankAccountsSheet({super.key, required this.onSaved});

  static void show(BuildContext context, {required VoidCallback onSaved}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => BankAccountsSheet(onSaved: onSaved),
    );
  }

  @override
  State<BankAccountsSheet> createState() => _BankAccountsSheetState();
}

class _BankAccountsSheetState extends State<BankAccountsSheet> {
  final _formKey = GlobalKey<FormState>();
  final _titleCtrl = TextEditingController();
  final _numCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _balanceCtrl = TextEditingController();
  
  String _selectedBankName = 'Meezan Bank';
  String _branchScope = 'all';

  static const _availableBanks = [
    'Meezan Bank',
    'United Bank Limited (UBL)',
    'The Bank of Punjab (BOP)',
    'National Bank of Pakistan (NBP)',
    'Faysal Bank',
    'EasyPaisa',
    'JazzCash',
    'Habib Bank Limited (HBL)',
    'MCB Bank',
    'Allied Bank (ABL)',
    'Bank Alfalah',
    'Askari Bank',
    'Cash',
  ];

  @override
  void dispose() {
    _titleCtrl.dispose();
    _numCtrl.dispose();
    _codeCtrl.dispose();
    _balanceCtrl.dispose();
    super.dispose();
  }

  void _saveAccount() async {
    if (!_formKey.currentState!.validate()) return;

    final code = _codeCtrl.text.trim();
    final balancePkr = double.tryParse(_balanceCtrl.text.trim()) ?? 0.0;
    final balancePaisa = (balancePkr * 100).round();

    final newAcc = OrgBankAccount(
      id: 'bank_${code}_${DateTime.now().millisecondsSinceEpoch}',
      accountCode: code,
      accountTitle: _titleCtrl.text.trim(),
      accountNumber: _numCtrl.text.trim(),
      bankName: _selectedBankName,
      branchScope: _branchScope,
      openingBalancePaisa: balancePaisa,
      openingBalanceDate: DateFormat('yyyy-MM-dd').format(DateTime.now()),
    );

    await FinanceLedgerStorage.saveOrgBankAccount(newAcc);
    widget.onSaved();
    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Org Bank Account "${newAcc.accountTitle}" saved successfully.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final existingAccounts = FinanceLedgerStorage.getOrgBankAccounts();
    final balances = FinanceLedgerStorage.getAllAccountBalancesPaisa();

    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.account_balance_rounded, color: Color(0xFF10B981), size: 28),
              const SizedBox(width: 12),
              const Expanded(
                child: Text('Organization Bank & Cash Accounts',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
              ),
              IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
            ],
          ),
          const Divider(height: 24),

          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Active Bank & Treasury Accounts',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
                  const SizedBox(height: 12),

                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: existingAccounts.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, idx) {
                      final acc = existingAccounts[idx];
                      final balancePaisa = balances[acc.accountCode] ?? 0;
                      final balanceStr = NumberFormat.currency(symbol: 'PKR ', decimalDigits: 0).format(balancePaisa / 100);

                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                        ),
                        child: Row(
                          children: [
                            BankLogoWidget(bankName: acc.bankName, size: 36),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(acc.accountTitle, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                  Text('COA: ${acc.accountCode} • ${acc.accountNumber}',
                                      style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                                ],
                              ),
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(balanceStr, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: Color(0xFF10B981))),
                                const Text('Live Balance', style: TextStyle(fontSize: 10, color: Color(0xFF94A3B8))),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),

                  const SizedBox(height: 28),
                  const Divider(),
                  const SizedBox(height: 12),

                  const Text('Add New Org Bank / Cash Account',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
                  const SizedBox(height: 16),

                  Form(
                    key: _formKey,
                    child: Column(
                      children: [
                        DropdownButtonFormField<String>(
                          value: _selectedBankName,
                          decoration: const InputDecoration(labelText: 'Bank Brand / Type *', border: OutlineInputBorder()),
                          items: _availableBanks.map((b) => DropdownMenuItem(
                            value: b,
                            child: Row(
                              children: [
                                BankLogoWidget(bankName: b, size: 20),
                                const SizedBox(width: 8),
                                Text(b, style: const TextStyle(fontSize: 13)),
                              ],
                            ),
                          )).toList(),
                          onChanged: (v) { if (v != null) setState(() => _selectedBankName = v); },
                        ),
                        const SizedBox(height: 12),

                        TextFormField(
                          controller: _titleCtrl,
                          decoration: const InputDecoration(labelText: 'Account Title *', hintText: 'e.g. Meezan Main Operating Account', border: OutlineInputBorder()),
                          validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                        ),
                        const SizedBox(height: 12),

                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: _codeCtrl,
                                decoration: const InputDecoration(labelText: 'COA Asset Code *', hintText: 'e.g. 1015', border: OutlineInputBorder()),
                                keyboardType: TextInputType.number,
                                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                controller: _numCtrl,
                                decoration: const InputDecoration(labelText: 'Account / IBAN Number *', border: OutlineInputBorder()),
                                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),

                        TextFormField(
                          controller: _balanceCtrl,
                          decoration: const InputDecoration(labelText: 'Opening Balance (PKR)', hintText: '0.00', border: OutlineInputBorder()),
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        ),
                        const SizedBox(height: 20),

                        SizedBox(
                          width: double.infinity,
                          height: 46,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981), foregroundColor: Colors.white),
                            icon: const Icon(Icons.add_circle_outline_rounded),
                            label: const Text('Create Org Bank Account', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                            onPressed: _saveAccount,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
