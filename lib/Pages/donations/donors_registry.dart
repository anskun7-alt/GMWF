// lib/pages/donations/donors_registry.dart
//
// Premium Donor Registry — searchable donor list with contribution summary
// and quick-action buttons.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'package:gmwf/pages/donations/donations_shared.dart';
import 'package:gmwf/theme/role_theme_provider.dart';
import 'package:gmwf/pages/donations/donations_screen.dart' show DonDS;
import 'package:gmwf/services/donations_local_storage.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gmwf/providers/donors_provider.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ENTRY POINT
// ─────────────────────────────────────────────────────────────────────────────

class DonorRegistryDialog extends StatelessWidget {
  final String branchId;
  final String branchName;
  const DonorRegistryDialog({
    super.key,
    required this.branchId,
    required this.branchName,
  });

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Container(
        width: 620,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        decoration: BoxDecoration(
          color: t.bg,
          borderRadius: BorderRadius.circular(DS.r2xl),
          border: Border.all(color: t.bgRule),
          boxShadow: DS.shadowLg,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            // ── Header ──────────────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.fromLTRB(24, 24, 16, 20),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [DonDS.headerTop, DonDS.headerBot],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(DS.rMd),
                    ),
                    child: const Icon(Icons.group_rounded, color: DonDS.tealLight, size: 22),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Donor Registry',
                            style: DS.display(color: DonDS.onDark).copyWith(fontSize: 20)),
                        Text('All registered donors & their contribution history',
                            style: DS.caption(color: DonDS.onDarkSub)),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, color: DonDS.onDarkSub),
                  ),
                ],
              ),
            ),
            Expanded(
              child: DonorRegistryWidget(branchId: branchId, branchName: branchName),
            ),
          ],
        ),
      ),
    );
  }
}

class DonorRegistryWidget extends ConsumerStatefulWidget {
  final String branchId;
  final String branchName;
  const DonorRegistryWidget({
    super.key,
    required this.branchId,
    required this.branchName,
  });

  @override
  ConsumerState<DonorRegistryWidget> createState() => _DonorRegistryWidgetState();
}

class _DonorRegistryWidgetState extends ConsumerState<DonorRegistryWidget> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    DonationsLocalStorage.init();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    return Column(
      children: [
        // ── Search & Actions ───────────────────────────────────────────
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: t.bgCard,
            border: Border(
              bottom: BorderSide(color: t.bgRule),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  style: DS.body(color: t.textPrimary),
                  onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
                  decoration: InputDecoration(
                    hintText: 'Search by name or phone…',
                    hintStyle: DS.body(color: t.textTertiary),
                    prefixIcon: Icon(Icons.search_rounded, color: t.textTertiary, size: 20),
                    suffixIcon: _query.isNotEmpty
                        ? IconButton(
                            icon: Icon(Icons.clear_rounded, size: 16, color: t.textTertiary),
                            onPressed: () { _search.clear(); setState(() => _query = ''); },
                          )
                        : null,
                    filled: true,
                    fillColor: t.bg,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(DS.rLg),
                      borderSide: BorderSide(color: t.bgRule),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(DS.rLg),
                      borderSide: BorderSide(color: t.bgRule),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(DS.rLg),
                      borderSide: const BorderSide(color: DonDS.teal, width: 1.5),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                onPressed: () => _showAddNewDonorDialog(context),
                icon: const Icon(Icons.person_add_rounded, size: 18),
                label: const Text('Add'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: DonDS.teal,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.rLg)),
                ),
              ),
            ],
          ),
        ),

        // ── Donor List ───────────────────────────────────────────────────
        Expanded(
          child: ref.watch(donorGroupsProvider(widget.branchId)).when(
            data: (households) {
              final filtered = _query.isEmpty
                  ? households
                  : households.where((group) =>
                      group.any((d) =>
                        d.name.toLowerCase().contains(_query) ||
                        d.phones.any((p) => p.toLowerCase().contains(_query)) ||
                        (d.cnic?.toLowerCase().contains(_query) ?? false) ||
                        (d.place?.toLowerCase().contains(_query) ?? false) ||
                        LocalStorageService.getBranchCode(d.branchId).contains(_query)
                      )).toList();

              if (filtered.isEmpty) {
                return _EmptyState(query: _query);
              }

              return ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: filtered.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, i) => _HouseholdCard(
                  members: filtered[i],
                  branchId: widget.branchId,
                  branchName: widget.branchName,
                ),
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Text('Error: $e'),
          ),
        ),
      ],
    );
  }

  void _showAddNewDonorDialog(BuildContext context) {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final bankNameCtrl = TextEditingController();
    final bankCtrl = TextEditingController();
    final placeCtrl = TextEditingController();
    final joinedSinceCtrl = TextEditingController();
    final balanceCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add New Donor'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Full Name')),
            const SizedBox(height: 12),
            TextField(
              controller: phoneCtrl, 
              keyboardType: TextInputType.phone, 
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(11),
              ],
              decoration: const InputDecoration(labelText: 'Phone Number (11 digits)')
            ),
            const SizedBox(height: 12),
            TextField(controller: placeCtrl, decoration: const InputDecoration(labelText: 'Place / City (Optional)')),
            const SizedBox(height: 12),
            TextField(controller: bankNameCtrl, decoration: const InputDecoration(labelText: 'Account Name (Optional)')),
            const SizedBox(height: 12),
            TextField(controller: bankCtrl, decoration: const InputDecoration(labelText: 'Bank Account / IBAN (Optional)')),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: joinedSinceCtrl,
                    readOnly: true,
                    onTap: () async {
                      final d = await showDatePicker(
                        context: context,
                        initialDate: DateTime.now(),
                        firstDate: DateTime(1980),
                        lastDate: DateTime.now(),
                      );
                      if (d != null) joinedSinceCtrl.text = DateFormat('yyyy-MM-dd').format(d);
                    },
                    decoration: const InputDecoration(labelText: 'Joined Since (Optional)', suffixIcon: Icon(Icons.calendar_today_rounded, size: 16)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: balanceCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Historical Total (Optional)', prefixText: 'PKR '),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              final name = nameCtrl.text.trim();
              final phone = phoneCtrl.text.trim();
              if (name.isEmpty) return;

              if (phone.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Phone number is required to register a donor in the registry.'))
                );
                return;
              }
              
              // Duplicate check: Same Name + Same Phone globally
              final existingList = DonationsLocalStorage.getAllDonors('all').where((d) => 
                d.name.toLowerCase() == name.toLowerCase() && 
                d.phones.contains(phone)
              ).toList();
              
              if (existingList.isNotEmpty) {
                final d = existingList.first;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('A donor with this name and phone already exists in ${d.branchId.toUpperCase()}.'))
                );
                return;
              }

              final accounts = <String>[];
              if (bankCtrl.text.isNotEmpty) {
                accounts.add('${bankNameCtrl.text.isNotEmpty ? '${bankNameCtrl.text} - ' : ''}${bankCtrl.text}');
              }

              final newDonor = DonorRecord(
                id: DateTime.now().millisecondsSinceEpoch.toString(),
                name: name,
                phones: [phone],
                accountNumbers: accounts, 
                address: '', 
                branchId: widget.branchId, 
                createdAt: DateTime.now().toIso8601String(),
                place: placeCtrl.text.trim().isNotEmpty ? placeCtrl.text.trim() : null,
                joinedSince: joinedSinceCtrl.text.trim().isNotEmpty ? joinedSinceCtrl.text.trim() : null,
                openingBalance: double.tryParse(balanceCtrl.text.trim()) ?? 0.0,
              );
              
              DonationsLocalStorage.saveDonor(newDonor);
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('New donor registered successfully')));
            }, 
            child: const Text('Register Donor')
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// DONOR CARD
// ─────────────────────────────────────────────────────────────────────────────

class _HouseholdCard extends StatefulWidget {
  final List<DonorRecord> members;
  final String branchId;
  final String branchName;
  const _HouseholdCard({
    required this.members,
    required this.branchId,
    required this.branchName,
  });

  @override
  State<_HouseholdCard> createState() => _HouseholdCardState();
}

class _HouseholdCardState extends State<_HouseholdCard> {
  bool _expanded = false;
  double _totalAmount = 0;
  double _cashAmount = 0;
  double _goodsAmount = 0;
  double _historicalTotal = 0;
  List<Map<String, dynamic>>? _allDonations;
  Map<String, ({double cash, double goods, double total})> _memberTotals = {};

  Future<void> _loadDonations() async {
    if (_allDonations != null) return;
    
    final memberIds = widget.members.map((m) => m.id).toSet();
    final memberPhones = widget.members
        .expand((m) => m.phones)
        .map((p) => p.replaceAll(RegExp(r'\D'), ''))
        .where((p) => p.isNotEmpty)
        .toSet();
    
    final all = DonationsLocalStorage.getAllDonations('all');
    final collectedDocs = <Map<String, dynamic>>[];
    final totals = <String, ({double cash, double goods, double total})>{};
    for (var m in widget.members) {
      totals[m.id] = (cash: m.openingBalance, goods: 0.0, total: m.openingBalance);
    }

    final historical = widget.members.fold(0.0, (sum, m) => sum + m.openingBalance);
    double collectiveCash = historical;
    double collectiveGoods = 0.0;

    for (var r in all) {
      final d = r.toMap();
      final dId = d['donorId']?.toString() ?? '';
      final p = (d['phone'] as String? ?? '').replaceAll(RegExp(r'\D'), '');
      
      bool matchesId = memberIds.contains(dId);
      bool matchesPhone = p.isNotEmpty && memberPhones.contains(p);

      if (matchesId || matchesPhone) {
        collectedDocs.add(d);
        final amt = (d['amount'] as num?)?.toDouble() ?? 0.0;
        final prob = (d['probableAmount'] as num?)?.toDouble() ?? 0.0;
        final isGoods = (d['entryType'] as String? ?? 'cash') == 'goods';
        
        if (isGoods) {
          collectiveGoods += prob;
        } else {
          collectiveCash += amt;
        }
        
        if (matchesId) {
          final existing = totals[dId] ?? (cash: 0.0, goods: 0.0, total: 0.0);
          if (isGoods) {
            totals[dId] = (
              cash: existing.cash,
              goods: existing.goods + prob,
              total: existing.total + prob,
            );
          } else {
            totals[dId] = (
              cash: existing.cash + amt,
              goods: existing.goods,
              total: existing.total + amt,
            );
          }
        }
      }
    }

    collectedDocs.sort((a, b) => (b['date'] as String? ?? '').compareTo(a['date'] as String? ?? ''));

    if (mounted) {
      setState(() {
        _allDonations = collectedDocs;
        _totalAmount = collectiveCash + collectiveGoods;
        _cashAmount = collectiveCash;
        _goodsAmount = collectiveGoods;
        _historicalTotal = historical;
        _memberTotals = totals;
      });
    }
  }

  Future<void> _downloadHouseholdReport() async {
    if (_allDonations == null) await _loadDonations();
    if (_allDonations!.isEmpty) {
      _snack('No donations found for this household.', context);
      return;
    }
    
    // We use the first member as the primary representative for the report metadata
    await downloadDonorWeeklyReport(
      widget.members.first, 
      _allDonations!, 
      context, 
      title: 'Household Collective Report',
    );
  }


  Future<void> _downloadWeeklyReport(DonorRecord donor) async {
    if (_allDonations == null) await _loadDonations();
    if (_allDonations == null || _allDonations!.isEmpty) {
      _snack('No donations found for this donor.', context);
      return;
    }

    final donorDonations = _allDonations!.where((d) => d['donorId'] == donor.id).toList();
    if (donorDonations.isEmpty) {
      _snack('No individual donations found for ${donor.name}.', context);
      return;
    }

    final now = DateTime.now();
    final thirtyDaysAgo = now.subtract(const Duration(days: 30));
    
    final filtered = donorDonations.where((d) {
      final date = DateTime.tryParse(d['date'] as String? ?? '') ?? DateTime.now();
      return date.isAfter(thirtyDaysAgo);
    }).toList();

    if (filtered.isEmpty) {
      _snack('No donations found in the last 30 days for ${donor.name}.', context);
      return;
    }
    
    await downloadDonorWeeklyReport(donor, filtered, context, title: 'Contribution Report');
  }

  String _initials(String name) {
    final parts = name.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    final isHousehold = widget.members.length > 1;
    final head = widget.members.first; // Earliest created
    final color = _avatarColor(head.name);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(DS.rLg),
        border: Border.all(color: _expanded ? color.withValues(alpha: 0.3) : t.bgRule),
        boxShadow: DS.shadowSm,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: () async {
              setState(() => _expanded = !_expanded);
              if (_expanded) await _loadDonations();
            },
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 46, height: 46,
                    decoration: BoxDecoration(color: color.withValues(alpha: 0.12), shape: BoxShape.circle),
                    child: Center(child: Icon(isHousehold ? Icons.house_rounded : Icons.person_rounded, color: color, size: 24)),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(isHousehold ? '${head.name} Household' : head.name,
                            style: DS.heading(color: t.textPrimary).copyWith(fontSize: 15)),
                        const SizedBox(height: 3),
                        Text(head.phones.isNotEmpty ? head.phones.first : 'No Phone', 
                            style: DS.caption(color: t.textTertiary).copyWith(fontSize: 11)),
                        if (head.joinedSince != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text('Since ${head.joinedSince}', 
                                style: DS.caption(color: DonDS.teal).copyWith(fontSize: 9, fontWeight: FontWeight.w700)),
                          ),
                      ],
                    ),
                  ),
                  if (isHousehold)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(color: Colors.indigo.shade50, borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.indigo.shade100)),
                      child: Text('${widget.members.length} MEMBERS', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: Colors.indigo.shade700, letterSpacing: 0.5)),
                    ),
                  const SizedBox(width: 12),
                  Icon(_expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18, color: t.textTertiary),
                ],
              ),
            ),
          ),

          if (_expanded) ...[
            Container(height: 1, color: t.bgRule),
            if (_allDonations == null)
              const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
            else ...[
              Container(
                padding: const EdgeInsets.all(16),
                color: color.withValues(alpha: 0.03),
                child: Column(
                  children: [
                    Row(
                      children: [
                        _StatPill(label: 'Cash Contrib.', value: 'PKR ${NumberFormat('#,###').format(_cashAmount)}', color: Colors.green),
                        const SizedBox(width: 8),
                        _StatPill(label: 'Goods Contrib.', value: 'PKR ${NumberFormat('#,###').format(_goodsAmount)}', color: Colors.purple),
                        const SizedBox(width: 8),
                        _StatPill(label: 'Total Household', value: 'PKR ${NumberFormat('#,###').format(_totalAmount)}', color: DonDS.teal),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        if (_historicalTotal > 0) ...[
                          _StatPill(label: 'Opening Bal', value: 'PKR ${NumberFormat('#,###').format(_historicalTotal)}', color: DonDS.amber),
                          const SizedBox(width: 8),
                        ],
                        _StatPill(label: 'Records', value: '${_allDonations!.length}', color: color),
                        const SizedBox(width: 8),
                        _StatPill(
                          label: 'Home Branch',
                          value: head.branchId.toUpperCase(),
                          color: DonDS.teal,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(child: Text('HOUSEHOLD MEMBERS', style: DS.label(color: t.textTertiary).copyWith(fontSize: 9, letterSpacing: 1))),
                        TextButton.icon(
                          onPressed: () => _showAddMemberDialog(context, head),
                          icon: const Icon(Icons.person_add_alt_1_rounded, size: 14),
                          label: const Text('Add Member', style: TextStyle(fontSize: 11)),
                          style: TextButton.styleFrom(
                            foregroundColor: DonDS.teal,
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ...widget.members.map((m) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          CircleAvatar(radius: 12, backgroundColor: t.bg, child: Text(m.name[0], style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.bold))),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(m.name, style: DS.body(color: t.textPrimary).copyWith(fontSize: 13)),
                                if (m.joinedSince != null)
                                  Text('Joined ${m.joinedSince}', style: DS.caption(color: t.textTertiary).copyWith(fontSize: 9)),
                              ],
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text('PKR ${NumberFormat('#,###').format(_memberTotals[m.id]?.total ?? 0)}', style: DS.heading(color: t.textSecondary).copyWith(fontSize: 12)),
                              Text(
                                'Cash: ${NumberFormat('#,###').format(_memberTotals[m.id]?.cash ?? 0)} · Goods: ${NumberFormat('#,###').format(_memberTotals[m.id]?.goods ?? 0)}',
                                style: DS.caption(color: t.textTertiary).copyWith(fontSize: 9),
                              ),
                            ],
                          ),
                          const SizedBox(width: 4),
                          IconButton(
                            icon: Icon(Icons.edit_rounded, size: 15, color: t.textTertiary),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: () => showEditDonorDialog(context, m),
                            tooltip: 'Edit',
                          ),
                          const SizedBox(width: 4),
                          IconButton(
                            icon: Icon(Icons.download_rounded, size: 15, color: color),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: () => _downloadWeeklyReport(m),
                            tooltip: 'Report',
                          ),
                          // Only show Remove if this is not the sole member
                          if (widget.members.length > 1) ...[
                            const SizedBox(width: 4),
                            IconButton(
                              icon: const Icon(Icons.person_remove_alt_1_rounded, size: 15, color: DS.crimson500),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              onPressed: () => _removeMemberFromHousehold(context, m),
                              tooltip: 'Remove from household',
                            ),
                          ],
                        ],
                      ),
                    )),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(child: _QuickBtn(label: 'Edit Household', icon: Icons.edit_rounded, color: DonDS.teal, onTap: () => showEditDonorDialog(context, head))),
                        const SizedBox(width: 12),
                        Expanded(child: _QuickBtn(label: 'Download Report', icon: Icons.picture_as_pdf_rounded, color: Colors.redAccent, onTap: _downloadHouseholdReport)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Color _avatarColor(String name) {
    final colors = [DonDS.teal, DonDS.amber, const Color(0xFF7C3AED), const Color(0xFF059669), const Color(0xFFDC2626), const Color(0xFF2563EB)];
    return colors[name.length % colors.length];
  }

  // ── Add a new person to this household ──────────────────────────────────────
  void _showAddMemberDialog(BuildContext context, DonorRecord head) {
    // The household key is the head's id. All members share this householdId.
    final householdId = head.householdId ?? head.id;
    final allDonors = DonationsLocalStorage.getAllDonors(widget.branchId);
    // Donors not yet in this household
    final unlinked = allDonors.where((d) =>
        d.id != head.id &&
        (d.householdId == null || d.householdId!.isEmpty) &&
        !widget.members.any((m) => m.id == d.id)).toList();

    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final placeCtrl = TextEditingController();
    bool createNew = true;
    DonorRecord? selectedExisting;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.rXl)),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: DonDS.teal.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(DS.rMd),
                ),
                child: const Icon(Icons.person_add_alt_1_rounded, color: DonDS.teal, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Add Household Member', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                    Text('Adding to ${head.name}\'s household', style: const TextStyle(fontSize: 11, color: DS.ink500, fontWeight: FontWeight.w400)),
                  ],
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Toggle: Create new vs link existing
                Row(
                  children: [
                    Expanded(
                      child: _ToggleChip(
                        label: 'New Person',
                        icon: Icons.person_add_rounded,
                        selected: createNew,
                        onTap: () => setLocal(() => createNew = true),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _ToggleChip(
                        label: 'Link Existing',
                        icon: Icons.link_rounded,
                        selected: !createNew,
                        onTap: unlinked.isEmpty ? null : () => setLocal(() => createNew = false),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (createNew) ...[
                  TextField(
                    controller: nameCtrl,
                    decoration: InputDecoration(
                      labelText: 'Full Name',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(DS.rMd)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: phoneCtrl,
                    keyboardType: TextInputType.phone,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(11)],
                    decoration: InputDecoration(
                      labelText: 'Phone (optional)',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(DS.rMd)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: placeCtrl,
                    decoration: InputDecoration(
                      labelText: 'Place / City (optional)',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(DS.rMd)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                ] else ...[
                  if (unlinked.isEmpty)
                    const Text('No unlinked donors available in this branch.',
                        style: TextStyle(color: DS.ink500, fontSize: 13))
                  else
                    DropdownButtonFormField<DonorRecord>(
                      initialValue: selectedExisting,
                      decoration: InputDecoration(
                        labelText: 'Select donor to link',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(DS.rMd)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                      items: unlinked.map((d) => DropdownMenuItem(
                        value: d,
                        child: Text('${d.name}  ${d.phone.isNotEmpty ? "(${d.phone})" : ""}',
                            style: const TextStyle(fontSize: 13)),
                      )).toList(),
                      onChanged: (v) => setLocal(() => selectedExisting = v),
                    ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: DonDS.teal, foregroundColor: Colors.white),
              onPressed: () {
                if (createNew) {
                  final name = nameCtrl.text.trim();
                  if (name.isEmpty) return;
                  final newMember = DonorRecord(
                    id: DateTime.now().millisecondsSinceEpoch.toString(),
                    name: name,
                    phones: phoneCtrl.text.trim().isNotEmpty ? [phoneCtrl.text.trim()] : [],
                    branchId: widget.branchId,
                    createdAt: DateTime.now().toIso8601String(),
                    householdId: householdId,
                    place: placeCtrl.text.trim().isNotEmpty ? placeCtrl.text.trim() : null,
                  );
                  // Also tag the head with householdId if not already set
                  if (head.householdId == null || head.householdId!.isEmpty) {
                    DonationsLocalStorage.saveDonor(head.copyWith(householdId: householdId));
                  }
                  DonationsLocalStorage.saveDonor(newMember);
                  Navigator.pop(ctx);
                  _snack('$name added to ${head.name}\'s household', context);
                } else {
                  if (selectedExisting == null) return;
                  // Tag the head if not yet in a household
                  if (head.householdId == null || head.householdId!.isEmpty) {
                    DonationsLocalStorage.saveDonor(head.copyWith(householdId: householdId));
                  }
                  // Tag all existing members
                  for (final m in widget.members) {
                    if (m.householdId == null || m.householdId!.isEmpty) {
                      DonationsLocalStorage.saveDonor(m.copyWith(householdId: householdId));
                    }
                  }
                  DonationsLocalStorage.saveDonor(selectedExisting!.copyWith(householdId: householdId));
                  Navigator.pop(ctx);
                  _snack('${selectedExisting!.name} linked to ${head.name}\'s household', context);
                }
              },
              child: const Text('Add to Household'),
            ),
          ],
        ),
      ),
    );
  }

  // ── Remove a member from this household (detaches, doesn't delete) ───────────
  void _removeMemberFromHousehold(BuildContext context, DonorRecord member) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.rXl)),
        title: const Text('Remove from Household?', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: Text(
          '"${member.name}" will be removed from this household and become an independent donor. Their donation records will not be affected.',
          style: const TextStyle(fontSize: 13, color: DS.ink700),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: DS.crimson500, foregroundColor: Colors.white),
            onPressed: () {
              // Clear householdId to detach
              final detached = DonorRecord(
                id: member.id,
                name: member.name,
                phones: member.phones,
                accountNumbers: member.accountNumbers,
                address: member.address,
                branchId: member.branchId,
                createdAt: member.createdAt,
                cnic: member.cnic,
                householdId: null,   // detached
                notes: member.notes,
                place: member.place,
                joinedSince: member.joinedSince,
                openingBalance: member.openingBalance,
              );
              DonationsLocalStorage.saveDonor(detached);
              Navigator.pop(ctx);
              _snack('${member.name} removed from household', context);
            },
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

  void _snack(String msg, BuildContext ctx) {
    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.all(16),
    ));
  }

  void _showAccountsDialog(BuildContext context, DonorRecord d) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${d.name}\'s Accounts'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: d.accountNumbers.map((acc) => ListTile(
            leading: const Icon(Icons.credit_card_rounded, color: DonDS.amber),
            title: Text(acc, style: DS.body(color: RoleThemeScope.dataOf(ctx).textPrimary)),
            trailing: IconButton(
              icon: const Icon(Icons.copy_rounded, size: 18),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: acc));
                Navigator.pop(ctx);
                _snack('Account copied to clipboard', context);
              },
            ),
          )).toList(),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }



  String _formatJoinDate(String iso) {
    try {
      return DateFormat('MMM yyyy').format(DateTime.parse(iso));
    } catch (_) {
      return '—';
    }
  }

  void _confirmDeleteDonor(BuildContext context, DonorRecord donor) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.rXl)),
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: DS.crimson500, size: 28),
            const SizedBox(width: 12),
            const Text('Delete Donor?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Are you sure you want to delete "${donor.name}"?',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            const SizedBox(height: 12),
            const Text(
              'This action will remove the donor from the registry and Firestore. Existing donation records will remain but will be unlinked from this donor profile.',
              style: TextStyle(fontSize: 13, color: DS.ink500),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: DS.crimson500, foregroundColor: Colors.white),
            onPressed: () async {
              await DonationsLocalStorage.deleteDonor(donor.id, donor.branchId);
              Navigator.pop(ctx);
              _snack('Donor "${donor.name}" deleted.', context);
            },
            child: const Text('Delete Permanently'),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MINI HELPERS
// ─────────────────────────────────────────────────────────────────────────────

class _StatPill extends StatelessWidget {
  final String label, value;
  final Color color;
  const _StatPill({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(DS.rMd),
          border: Border.all(color: color.withValues(alpha: 0.15)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label.toUpperCase(),
              style: DS.label(color: t.textTertiary).copyWith(fontSize: 8, letterSpacing: 0.8)),
          const SizedBox(height: 3),
          Text(value,
              style: DS.heading(color: color).copyWith(fontSize: 12),
              overflow: TextOverflow.ellipsis),
        ]),
      ),
    );
  }
}

class _MiniDonRow extends StatelessWidget {
  final Map<String, dynamic> data;
  final Color color;
  const _MiniDonRow({required this.data, required this.color});

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    final isGoods = (data['entryType'] as String? ?? '') == 'goods';
    final rawAmt = (data['amount'] as num?)?.toDouble() ?? 0;
    final probable = (data['probableAmount'] as num?)?.toDouble() ?? 0;
    final amt = rawAmt > 0 ? rawAmt : probable;
    final cat = DonationCategory.values
        .firstWhere((c) => c.name == (data['categoryId'] as String? ?? ''),
            orElse: () => DonationCategory.gmwf);
    final date = data['date'] as String? ?? '';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: cat.color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(DS.rSm),
          ),
          child: Icon(cat.icon, size: 11, color: cat.color),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(cat.label,
              style: DS.label(color: t.textSecondary).copyWith(fontSize: 11)),
        ),
        Text(
          isGoods ? 'Goods' : 'PKR ${NumberFormat('#,###').format(amt)}',
          style: DS.heading(color: color).copyWith(fontSize: 12),
        ),
        const SizedBox(width: 10),
        Text(
          _fmt(date),
          style: DS.caption(color: t.textTertiary).copyWith(fontSize: 10),
        ),
      ]),
    );
  }

  String _fmt(String d) {
    try { return DateFormat('dd MMM').format(DateTime.parse(d)); }
    catch (_) { return d; }
  }
}

class _QuickBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _QuickBtn({required this.label, required this.icon, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DS.rMd),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(DS.rMd),
            border: Border.all(color: color.withValues(alpha: 0.25), width: 1.5),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 8),
              Text(label, style: DS.heading(color: color).copyWith(fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// EMPTY STATE
// ─────────────────────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final String query;
  const _EmptyState({required this.query});

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: DonDS.teal.withValues(alpha: 0.06),
                shape: BoxShape.circle,
              ),
              child: Icon(
                query.isNotEmpty ? Icons.search_off_rounded : Icons.group_off_rounded,
                size: 40,
                color: DonDS.teal.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              query.isNotEmpty ? 'No donors match "$query"' : 'No Donors Registered Yet',
              style: DS.heading(color: t.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              query.isNotEmpty
                  ? 'Try a different name or phone number'
                  : 'Donors are automatically registered when you add a donation with a phone number.',
              style: DS.caption(color: t.textTertiary),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TOGGLE CHIP — used in Add Member dialog
// ─────────────────────────────────────────────────────────────────────────────

class _ToggleChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback? onTap;
  const _ToggleChip({required this.label, required this.icon, required this.selected, this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = selected ? DonDS.teal : DS.ink300;
    final bg    = selected ? DonDS.teal.withValues(alpha: 0.08) : Colors.transparent;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(DS.rMd),
          border: Border.all(color: color, width: selected ? 1.5 : 1),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 15, color: selected ? DonDS.teal : DS.ink500),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? DonDS.teal : DS.ink500,
            )),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// GLOBAL HELPER: Edit Donor Dialog
// ─────────────────────────────────────────────────────────────────────────────
void showEditDonorDialog(BuildContext context, DonorRecord d) {
  final nameCtrl = TextEditingController(text: d.name);
  final phoneCtrl = TextEditingController(text: d.phones.isNotEmpty ? d.phones.first : '');
  
  // Parse existing account if present
  String accName = '';
  String accNumber = '';
  if (d.accountNumbers.isNotEmpty) {
    final accStr = d.accountNumbers.first;
    if (accStr.contains(' - ')) {
      final parts = accStr.split(' - ');
      accName = parts[0];
      accNumber = parts.sublist(1).join(' - ');
    } else {
      accNumber = accStr;
    }
  }
  
  final bankNameCtrl = TextEditingController(text: accName);
  final bankCtrl = TextEditingController(text: accNumber);
  final placeCtrl = TextEditingController(text: d.place ?? '');
  final joinedSinceCtrl = TextEditingController(text: d.joinedSince ?? '');
  final balanceCtrl = TextEditingController(text: d.openingBalance > 0 ? d.openingBalance.toStringAsFixed(0) : '');

  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Edit Donor'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Full Name')),
          const SizedBox(height: 12),
          TextField(
            controller: phoneCtrl, 
            keyboardType: TextInputType.phone, 
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(11),
            ],
            decoration: const InputDecoration(labelText: 'Phone Number (11 digits)')
          ),
          const SizedBox(height: 12),
          TextField(controller: placeCtrl, decoration: const InputDecoration(labelText: 'Place / City (Optional)')),
          const SizedBox(height: 12),
          TextField(controller: bankNameCtrl, decoration: const InputDecoration(labelText: 'Account Name (Optional)')),
          const SizedBox(height: 12),
          TextField(controller: bankCtrl, decoration: const InputDecoration(labelText: 'Bank Account / IBAN (Optional)')),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: joinedSinceCtrl,
                  readOnly: true,
                  onTap: () async {
                    final dt = await showDatePicker(
                      context: context,
                      initialDate: DateTime.tryParse(joinedSinceCtrl.text) ?? DateTime.now(),
                      firstDate: DateTime(1980),
                      lastDate: DateTime.now(),
                    );
                    if (dt != null) joinedSinceCtrl.text = DateFormat('yyyy-MM-dd').format(dt);
                  },
                  decoration: const InputDecoration(labelText: 'Joined Since', suffixIcon: Icon(Icons.calendar_today_rounded, size: 16)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: balanceCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Historical Total', prefixText: 'PKR '),
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () async {
            if (nameCtrl.text.isEmpty) return;
            
            final updatedAccounts = <String>[];
            if (bankCtrl.text.isNotEmpty) {
              updatedAccounts.add('${bankNameCtrl.text.isNotEmpty ? '${bankNameCtrl.text} - ' : ''}${bankCtrl.text}');
            }

            final updatedDonor = DonorRecord(
              id: d.id,
              name: nameCtrl.text,
              phones: phoneCtrl.text.isNotEmpty ? [phoneCtrl.text] : [],
              accountNumbers: updatedAccounts, 
              address: d.address, 
              branchId: d.branchId, 
              createdAt: d.createdAt,
              place: placeCtrl.text.trim().isNotEmpty ? placeCtrl.text.trim() : null,
              joinedSince: joinedSinceCtrl.text.trim().isNotEmpty ? joinedSinceCtrl.text.trim() : null,
              openingBalance: double.tryParse(balanceCtrl.text.trim()) ?? 0.0,
            );
            
            DonationsLocalStorage.saveDonor(updatedDonor);

            // Audit trail for donor edit
            await DonationsLocalStorage.enqueueAuditLog(
              branchId: d.branchId,
              collection: 'donors',
              documentId: d.id,
              action: 'update',
              userId: 'manager',
              username: 'Manager',
              oldData: d.toMap(),
              newData: updatedDonor.toMap(),
              reason: 'Donor profile edited via registry',
            );

            Navigator.pop(ctx);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Donor updated successfully'))
              );
            }
          }, 
          child: const Text('Save Changes')
        ),
      ],
    ),
  );
}
