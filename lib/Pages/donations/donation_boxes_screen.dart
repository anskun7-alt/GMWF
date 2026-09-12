// lib/pages/donations/donation_boxes_screen.dart
//
// Full UI for Donation Box management:
//  - Box Registry List (with overdue indicators)
//  - Register Box Dialog
//  - Box Detail View (info + opening history timeline)
//  - Open Box Dialog
//  - Yearly Report Dialog with Excel download

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/donation_box_models.dart';
import '../../models/donation_models.dart';
import '../../services/donation_box_storage.dart';
import '../../services/donations_local_storage.dart';
import '../../theme/role_theme_provider.dart';
import '../../theme/app_theme.dart';
import 'donations_shared.dart';

// ─────────────────────────────────────────────────────────────────────────────
// DONATION BOXES WIDGET (embeddable in tab)
// ─────────────────────────────────────────────────────────────────────────────

class DonationBoxesWidget extends StatefulWidget {
  final String branchId;
  final String branchName;
  final String username;
  final UserRole role;

  const DonationBoxesWidget({
    super.key,
    required this.branchId,
    required this.branchName,
    this.username = '',
    this.role = UserRole.staff,
  });

  @override
  State<DonationBoxesWidget> createState() => _DonationBoxesWidgetState();
}

class _DonationBoxesWidgetState extends State<DonationBoxesWidget> {
  List<DonationBox> _boxes = [];
  bool _loading = true;
  String _searchQuery = '';
  final TextEditingController _searchCtrl = TextEditingController();
  int _selectedView = 0; // 0 = Box Registry, 1 = Person Audit & Incident Risk Matrix
  String _statusFilter = 'active'; // Default filter is always 'active'
  String _auditSort = 'accidents'; // 'accidents', 'money', 'loss'

  @override
  void initState() {
    super.initState();
    _loadBoxes();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(DonationBoxesWidget old) {
    super.didUpdateWidget(old);
    if (old.branchId != widget.branchId) _loadBoxes();
  }

  List<DonationBox> get _filteredBoxes {
    final q = _searchQuery.trim().toLowerCase();
    List<DonationBox> list = _boxes;

    if (_statusFilter == 'active') {
      list = list.where((b) => b.status == 'active' && b.isActive).toList();
    } else if (_statusFilter == 'overdue') {
      list = list.where((b) => b.isOverdue).toList();
    } else if (_statusFilter == 'snatched') {
      list = list.where((b) => b.status == 'snatched').toList();
    } else if (_statusFilter == 'stolen') {
      list = list.where((b) => b.status == 'stolen').toList();
    } else if (_statusFilter == 'broken') {
      list = list.where((b) => b.status == 'broken').toList();
    } else if (_statusFilter == 'replaced') {
      list = list.where((b) => b.status == 'replaced' || b.replacedByBoxId != null).toList();
    }

    if (q.isEmpty) return list;
    return list.where((b) {
      return b.boxNumber.toLowerCase().contains(q) ||
          b.holderName.toLowerCase().contains(q) ||
          b.holderPhone.toLowerCase().contains(q) ||
          b.holderAddress.toLowerCase().contains(q) ||
          b.area.toLowerCase().contains(q) ||
          b.notes.toLowerCase().contains(q) ||
          b.status.toLowerCase().contains(q) ||
          (b.policeReportNo?.toLowerCase().contains(q) ?? false);
    }).toList();
  }

  List<PersonBoxAuditSummary> get _filteredPersonSummaries {
    final all = DonationBoxStorage.getPersonAuditSummaries(widget.branchId);
    final q = _searchQuery.trim().toLowerCase();

    List<PersonBoxAuditSummary> list = all;
    if (q.isNotEmpty) {
      list = list.where((p) {
        return p.personName.toLowerCase().contains(q) ||
            p.phone.toLowerCase().contains(q) ||
            p.area.toLowerCase().contains(q);
      }).toList();
    }

    if (_auditSort == 'accidents') {
      list.sort((a, b) {
        final cmp = b.totalIncidents.compareTo(a.totalIncidents);
        if (cmp != 0) return cmp;
        return b.totalMoneyOutput.compareTo(a.totalMoneyOutput);
      });
    } else if (_auditSort == 'money') {
      list.sort((a, b) => b.totalMoneyOutput.compareTo(a.totalMoneyOutput));
    } else if (_auditSort == 'loss') {
      list.sort((a, b) => b.totalEstimatedCashLost.compareTo(a.totalEstimatedCashLost));
    }

    return list;
  }

  Future<void> _loadBoxes() async {
    setState(() => _loading = true);
    try {
      await DonationBoxStorage.init();
      if (widget.branchId.isNotEmpty && widget.branchId != 'all') {
        await DonationBoxStorage.downloadBoxes(widget.branchId);
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _boxes = DonationBoxStorage.getBoxes(widget.branchId);
      _loading = false;
    });
  }

  void _refresh() {
    setState(() {
      _boxes = DonationBoxStorage.getBoxes(widget.branchId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    final isMobile = MediaQuery.of(context).size.width < 600;

    if (_loading) {
      return Center(
        child: CircularProgressIndicator(color: t.accent),
      );
    }

    final filteredBoxes = _filteredBoxes;
    final personSummaries = _filteredPersonSummaries;

    final activeCount = _boxes.where((b) => b.status == 'active' && b.isActive).length;
    final overdueCount = _boxes.where((b) => b.isOverdue).length;
    final snatchedCount = _boxes.where((b) => b.status == 'snatched').length;
    final stolenCount = _boxes.where((b) => b.status == 'stolen').length;
    final brokenCount = _boxes.where((b) => b.status == 'broken').length;
    final replacedCount = _boxes.where((b) => b.status == 'replaced' || b.replacedByBoxId != null).length;

    return CustomScrollView(
      slivers: [
        // ── Header & Switcher ─────────────────────────────────────────────
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(isMobile ? 16 : 24, 24, isMobile ? 16 : 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(t, isMobile),
                const SizedBox(height: 16),
                _buildSummaryCards(t, isMobile),
                const SizedBox(height: 16),

                // ── View Switcher Tab ──
                _buildViewSwitcher(t),
                const SizedBox(height: 16),

                // ── Search Bar ──
                Container(
                  decoration: BoxDecoration(
                    color: t.bgCard,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: t.bgRule),
                  ),
                  child: TextField(
                    controller: _searchCtrl,
                    onChanged: (val) => setState(() => _searchQuery = val),
                    style: TextStyle(fontSize: 13, color: t.textPrimary, fontWeight: FontWeight.w600),
                    decoration: InputDecoration(
                      hintText: _selectedView == 0
                          ? 'Search boxes by number (e.g. B-01), holder name, phone...'
                          : 'Search persons by name, phone, area...',
                      hintStyle: TextStyle(fontSize: 13, color: t.textTertiary, fontWeight: FontWeight.normal),
                      prefixIcon: Icon(Icons.search_rounded, color: t.accent, size: 20),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: Icon(Icons.clear_rounded, color: t.textTertiary, size: 18),
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() => _searchQuery = '');
                              },
                            )
                          : null,
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                // ── Filter / Sort Row ──
                if (_selectedView == 0) ...[
                  // Box Status Filter Chips
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    child: Row(
                      children: [
                        _buildFilterChip('all', 'All (${_boxes.length})', t),
                        _buildFilterChip('active', 'Active ($activeCount)', t),
                        _buildFilterChip('overdue', 'Overdue ($overdueCount)', t, color: const Color(0xFFDC2626)),
                        _buildFilterChip('snatched', 'Snatched 🚨 ($snatchedCount)', t, color: const Color(0xFFDC2626)),
                        _buildFilterChip('stolen', 'Stolen ⚠️ ($stolenCount)', t, color: const Color(0xFFEA580C)),
                        _buildFilterChip('broken', 'Broken 🔨 ($brokenCount)', t, color: const Color(0xFFD97706)),
                        _buildFilterChip('replaced', 'Replaced 🔄 ($replacedCount)', t, color: const Color(0xFF7C3AED)),
                      ],
                    ),
                  ),
                ] else ...[
                  // Person Audit Sort Chips
                  Row(
                    children: [
                      Text(
                        'SORT AUDIT BY:',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: t.textTertiary, letterSpacing: 1.0),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          physics: const BouncingScrollPhysics(),
                          child: Row(
                            children: [
                              _buildSortChip('accidents', 'Most Accidents / Incidents First 🚨', t),
                              _buildSortChip('money', 'Highest Lifetime Money Output 💰', t),
                              _buildSortChip('loss', 'Highest Cash Lost ⚠️', t),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],

                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _selectedView == 0 ? 'REGISTERED BOXES' : 'PERSON RISK & OUTPUT MATRIX',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        color: t.textTertiary,
                        letterSpacing: 1.2,
                      ),
                    ),
                    Text(
                      _selectedView == 0
                          ? '${filteredBoxes.length} of ${_boxes.length} boxes'
                          : '${personSummaries.length} person${personSummaries.length == 1 ? '' : 's'} tracked',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: t.accent,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),

        // ── View Content: Box Registry (0) vs Person Audit Matrix (1) ──
        if (_selectedView == 0) ...[
          // Box Registry View
          if (_boxes.isEmpty)
            SliverFillRemaining(hasScrollBody: false, child: _buildEmptyState(t))
          else if (filteredBoxes.isEmpty)
            SliverFillRemaining(hasScrollBody: false, child: _buildNoSearchResults(t))
          else
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: isMobile ? 16 : 24),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (ctx, index) => _BoxCard(
                    box: filteredBoxes[index],
                    onTap: () => _showBoxDetail(filteredBoxes[index]),
                    onOpenBox: () => _showOpenBoxDialog(filteredBoxes[index]),
                    onEdit: () => _showEditBoxDialog(filteredBoxes[index]),
                    onReportIncident: () => _showReportIncidentDialog(filteredBoxes[index]),
                    onAssignReplacement: () => _showAssignReplacementBoxDialog(filteredBoxes[index]),
                  ),
                  childCount: filteredBoxes.length,
                ),
              ),
            ),
        ] else ...[
          // Person Audit & Incident Risk Matrix View
          if (personSummaries.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.person_search_rounded, size: 48, color: t.textTertiary),
                      const SizedBox(height: 12),
                      Text('No person audit data available', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: t.textSecondary)),
                    ],
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: isMobile ? 16 : 24),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (ctx, index) => _PersonAuditCard(
                    summary: personSummaries[index],
                    onRefresh: _refresh,
                    onOpenBox: _showOpenBoxDialog,
                    onShowDetail: _showBoxDetail,
                    onReportIncident: _showReportIncidentDialog,
                    onAssignReplacement: _showAssignReplacementBoxDialog,
                  ),
                  childCount: personSummaries.length,
                ),
              ),
            ),
        ],

        const SliverToBoxAdapter(child: SizedBox(height: 100)),
      ],
    );
  }

  Widget _buildViewSwitcher(RoleThemeData t) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.bgRule),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () => setState(() => _selectedView = 0),
              borderRadius: BorderRadius.circular(9),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(vertical: 9),
                decoration: BoxDecoration(
                  color: _selectedView == 0 ? t.accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.inventory_2_rounded, size: 16, color: _selectedView == 0 ? Colors.white : t.textSecondary),
                    const SizedBox(width: 8),
                    Text(
                      'Box Registry (${_boxes.length})',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: _selectedView == 0 ? Colors.white : t.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: InkWell(
              onTap: () => setState(() => _selectedView = 1),
              borderRadius: BorderRadius.circular(9),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(vertical: 9),
                decoration: BoxDecoration(
                  color: _selectedView == 1 ? t.accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.analytics_rounded, size: 16, color: _selectedView == 1 ? Colors.white : t.textSecondary),
                    const SizedBox(width: 8),
                    Text(
                      'Person Audit & Risk Matrix',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: _selectedView == 1 ? Colors.white : t.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String key, String label, RoleThemeData t, {Color? color}) {
    final isSelected = _statusFilter == key;
    final chipColor = color ?? t.accent;

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        selected: isSelected,
        label: Text(label),
        labelStyle: TextStyle(
          fontSize: 11.5,
          fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
          color: isSelected ? Colors.white : (color ?? t.textPrimary),
        ),
        backgroundColor: color != null ? color.withValues(alpha: 0.08) : t.bgCard,
        selectedColor: chipColor,
        checkmarkColor: Colors.white,
        showCheckmark: false,
        side: BorderSide(
          color: isSelected ? chipColor : (color?.withValues(alpha: 0.3) ?? t.bgRule),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        onSelected: (_) => setState(() => _statusFilter = key),
      ),
    );
  }

  Widget _buildSortChip(String key, String label, RoleThemeData t) {
    final isSelected = _auditSort == key;

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        selected: isSelected,
        label: Text(label),
        labelStyle: TextStyle(
          fontSize: 11,
          fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
          color: isSelected ? Colors.white : t.textPrimary,
        ),
        backgroundColor: t.bgCard,
        selectedColor: t.accent,
        showCheckmark: false,
        side: BorderSide(color: isSelected ? t.accent : t.bgRule),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        onSelected: (_) => setState(() => _auditSort = key),
      ),
    );
  }

  Widget _buildNoSearchResults(RoleThemeData t) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off_rounded, size: 48, color: t.textTertiary),
            const SizedBox(height: 12),
            Text('No results matching "$_searchQuery"', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: t.textSecondary)),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () {
                _searchCtrl.clear();
                setState(() => _searchQuery = '');
              },
              child: const Text('Clear Search'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIncidentTypeChip(String type, String label, Color color, String selected, Function(String) onSelect) {
    final isSelected = selected == type;
    return Expanded(
      child: InkWell(
        onTap: () => onSelect(type),
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isSelected ? color : color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: isSelected ? color : color.withValues(alpha: 0.3)),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: isSelected ? Colors.white : color,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(RoleThemeData t, bool isMobile) {
    final currentYear = DateTime.now().year;

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Donation Boxes',
                style: TextStyle(
                  fontSize: isMobile ? 22 : 28,
                  fontWeight: FontWeight.w900,
                  color: t.textPrimary,
                  letterSpacing: -0.8,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${_boxes.length} box${_boxes.length == 1 ? '' : 'es'} registered',
                style: TextStyle(
                  fontSize: 13,
                  color: t.textTertiary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        // ── 12-Month Annual Report Button ──
        OutlinedButton.icon(
          onPressed: () async {
            if (_boxes.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('No donation boxes to export')),
              );
              return;
            }
            await DonationBoxStorage.exportAllBoxesYearlyReport(
              branchId: widget.branchId,
              branchName: widget.branchName,
              year: currentYear,
            );
          },
          icon: Icon(Icons.table_chart_rounded, size: 16, color: t.accent),
          label: Text(
            isMobile ? '12M Report' : 'Annual Excel ($currentYear)',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: t.accent,
            ),
          ),
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: t.accent.withValues(alpha: 0.5)),
            backgroundColor: t.accent.withValues(alpha: 0.05),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        const SizedBox(width: 10),
        _RegisterBoxButton(
          onTap: () => _showRegisterBoxDialog(),
          isMobile: isMobile,
        ),
      ],
    );
  }

  Widget _buildSummaryCards(RoleThemeData t, bool isMobile) {
    final activeCount = _boxes.where((b) => b.isActive && b.status == 'active').length;
    final overdueCount = _boxes.where((b) => b.isOverdue).length;
    final incidentsCount = _boxes.where((b) => b.isCompromised).length;
    final totalCollected = DonationBoxStorage.getOpenings(widget.branchId)
        .fold<double>(0, (sum, o) => sum + o.amount);
    final fmt = NumberFormat('#,##0');

    final cards = [
      _SummaryMiniCard(
        label: 'Active Boxes',
        value: '$activeCount',
        icon: Icons.inventory_2_rounded,
        color: const Color(0xFF047857),
        t: t,
      ),
      _SummaryMiniCard(
        label: 'Overdue (30d+)',
        value: '$overdueCount',
        icon: Icons.warning_amber_rounded,
        color: overdueCount > 0 ? const Color(0xFFDC2626) : const Color(0xFF6B7280),
        t: t,
      ),
      _SummaryMiniCard(
        label: 'Total Collected',
        value: 'PKR ${fmt.format(totalCollected)}',
        icon: Icons.payments_rounded,
        color: const Color(0xFF1D4ED8),
        t: t,
      ),
      _SummaryMiniCard(
        label: 'Incidents / Compromised',
        value: '$incidentsCount',
        icon: Icons.report_problem_rounded,
        color: incidentsCount > 0 ? const Color(0xFFDC2626) : const Color(0xFF10B981),
        t: t,
      ),
    ];

    if (isMobile) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        physics: const BouncingScrollPhysics(),
        child: Row(
          children: cards.map((c) => Padding(
            padding: const EdgeInsets.only(right: 10),
            child: SizedBox(width: 160, child: c),
          )).toList(),
        ),
      );
    }

    return Row(
      children: cards.map((c) => Expanded(
        child: Padding(
          padding: const EdgeInsets.only(right: 12),
          child: c,
        ),
      )).toList(),
    );
  }

  Widget _buildEmptyState(RoleThemeData t) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: t.accent.withValues(alpha: 0.06),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.inventory_2_rounded, size: 44, color: t.accent.withValues(alpha: 0.3)),
            ),
            const SizedBox(height: 24),
            Text(
              'No Donation Boxes',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: t.textPrimary, letterSpacing: -0.5),
            ),
            const SizedBox(height: 8),
            Text(
              'Register your first donation box to start tracking collections.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: t.textTertiary, height: 1.5),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _showRegisterBoxDialog,
              icon: const Icon(Icons.add_rounded, size: 20),
              label: const Text('Register Box', style: TextStyle(fontWeight: FontWeight.w700)),
              style: ElevatedButton.styleFrom(
                backgroundColor: t.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // DIALOGS
  // ══════════════════════════════════════════════════════════════════════════

  void _showRegisterBoxDialog() {
    final numberCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final areaCtrl = TextEditingController();
    final addressCtrl = TextEditingController();
    final notesCtrl = TextEditingController();

    final numberFocus = FocusNode();
    final nameFocus = FocusNode();
    final phoneFocus = FocusNode();
    final areaFocus = FocusNode();
    final addressFocus = FocusNode();
    final notesFocus = FocusNode();

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        final t = RoleThemeScope.dataOf(ctx);
        return Dialog(
          backgroundColor: t.bgCard,
          insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: SingleChildScrollView(
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                physics: const ClampingScrollPhysics(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: t.accent.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(Icons.add_box_rounded, size: 22, color: t.accent),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Register New Box', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: t.textPrimary, letterSpacing: -0.5)),
                              Text('Assign box number and holder details', style: TextStyle(fontSize: 12, color: t.textTertiary)),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    _DialogField(
                      label: 'Box Number * (Enter Manually)',
                      controller: numberCtrl,
                      focusNode: numberFocus,
                      autofocus: true,
                      textInputAction: TextInputAction.next,
                      onFieldSubmitted: (_) => FocusScope.of(ctx).requestFocus(nameFocus),
                      hint: 'e.g. BOX-045',
                      t: t,
                    ),
                    const SizedBox(height: 12),
                    _DialogField(
                      label: 'Holder Name *',
                      controller: nameCtrl,
                      focusNode: nameFocus,
                      textInputAction: TextInputAction.next,
                      onFieldSubmitted: (_) => FocusScope.of(ctx).requestFocus(phoneFocus),
                      hint: 'Person who keeps the box',
                      t: t,
                    ),
                    const SizedBox(height: 12),
                    _DialogField(
                      label: 'Phone',
                      controller: phoneCtrl,
                      focusNode: phoneFocus,
                      textInputAction: TextInputAction.next,
                      onFieldSubmitted: (_) => FocusScope.of(ctx).requestFocus(areaFocus),
                      hint: '03xx-xxxxxxx',
                      t: t,
                      keyboardType: TextInputType.phone,
                    ),
                    const SizedBox(height: 12),
                    _DialogField(
                      label: 'Area / Zone',
                      controller: areaCtrl,
                      focusNode: areaFocus,
                      textInputAction: TextInputAction.next,
                      onFieldSubmitted: (_) => FocusScope.of(ctx).requestFocus(addressFocus),
                      hint: 'e.g. Sector F-7, Main Bazar, Saddar',
                      t: t,
                    ),
                    const SizedBox(height: 12),
                    _DialogField(
                      label: 'Address',
                      controller: addressCtrl,
                      focusNode: addressFocus,
                      textInputAction: TextInputAction.next,
                      onFieldSubmitted: (_) => FocusScope.of(ctx).requestFocus(notesFocus),
                      hint: 'Shop / House address',
                      t: t,
                      maxLines: 2,
                    ),
                    const SizedBox(height: 12),
                    _DialogField(
                      label: 'Notes',
                      controller: notesCtrl,
                      focusNode: notesFocus,
                      textInputAction: TextInputAction.done,
                      hint: 'Optional notes',
                      t: t,
                      maxLines: 2,
                    ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(ctx),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: t.textSecondary,
                              side: BorderSide(color: t.bgRule),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w700)),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () async {
                              final boxNum = numberCtrl.text.trim().toUpperCase();
                              if (boxNum.isEmpty) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  const SnackBar(content: Text('Box number is required'), backgroundColor: Colors.red),
                                );
                                return;
                              }
                              if (nameCtrl.text.trim().isEmpty) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  const SnackBar(content: Text('Holder name is required'), backgroundColor: Colors.red),
                                );
                                return;
                              }
                              if (DonationBoxStorage.isBoxNumberTaken(boxNum)) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  SnackBar(
                                    content: Text('Box number "$boxNum" has already been assigned in the past. Box numbers can never be reused.'),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                                return;
                              }
                              final box = DonationBoxStorage.createBox(
                                boxNumber: boxNum,
                                holderName: nameCtrl.text.trim(),
                                holderPhone: phoneCtrl.text.trim(),
                                area: areaCtrl.text.trim(),
                                holderAddress: addressCtrl.text.trim(),
                                branchId: widget.branchId,
                                branchName: widget.branchName,
                                notes: notesCtrl.text.trim(),
                              );
                              await DonationBoxStorage.saveBox(box);
                              if (ctx.mounted) Navigator.pop(ctx);
                              _refresh();
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Box ${box.boxNumber} registered'), backgroundColor: Colors.green),
                                );
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: t.accent,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            child: const Text('Register', style: TextStyle(fontWeight: FontWeight.w800)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _showEditBoxDialog(DonationBox box) {
    final numberCtrl = TextEditingController(text: box.boxNumber);
    final nameCtrl = TextEditingController(text: box.holderName);
    final phoneCtrl = TextEditingController(text: box.holderPhone);
    final areaCtrl = TextEditingController(text: box.area);
    final addressCtrl = TextEditingController(text: box.holderAddress);
    final notesCtrl = TextEditingController(text: box.notes);
    final reasonCtrl = TextEditingController();
    bool isActive = box.isActive;

    final numberFocus = FocusNode();
    final nameFocus = FocusNode();
    final phoneFocus = FocusNode();
    final areaFocus = FocusNode();
    final addressFocus = FocusNode();
    final notesFocus = FocusNode();
    final reasonFocus = FocusNode();

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        final t = RoleThemeScope.dataOf(ctx);
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return Dialog(
              backgroundColor: t.bgCard,
              insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: SingleChildScrollView(
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    physics: const ClampingScrollPhysics(),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.blue.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(Icons.edit_note_rounded, size: 22, color: Colors.blue),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Edit Box ${box.boxNumber}', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: t.textPrimary, letterSpacing: -0.5)),
                                  Text('Updates are tracked in the global audit trail', style: TextStyle(fontSize: 12, color: t.textTertiary)),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        _DialogField(
                          label: 'Box Number',
                          controller: numberCtrl,
                          focusNode: numberFocus,
                          textInputAction: TextInputAction.next,
                          onFieldSubmitted: (_) => FocusScope.of(ctx).requestFocus(nameFocus),
                          hint: 'BOX-001',
                          t: t,
                        ),
                        const SizedBox(height: 12),
                        _DialogField(
                          label: 'Holder Name *',
                          controller: nameCtrl,
                          focusNode: nameFocus,
                          textInputAction: TextInputAction.next,
                          onFieldSubmitted: (_) => FocusScope.of(ctx).requestFocus(phoneFocus),
                          hint: 'Person who keeps the box',
                          t: t,
                        ),
                        const SizedBox(height: 12),
                        _DialogField(
                          label: 'Phone',
                          controller: phoneCtrl,
                          focusNode: phoneFocus,
                          textInputAction: TextInputAction.next,
                          onFieldSubmitted: (_) => FocusScope.of(ctx).requestFocus(areaFocus),
                          hint: '03xx-xxxxxxx',
                          t: t,
                          keyboardType: TextInputType.phone,
                        ),
                        const SizedBox(height: 12),
                        _DialogField(
                          label: 'Area / Zone',
                          controller: areaCtrl,
                          focusNode: areaFocus,
                          textInputAction: TextInputAction.next,
                          onFieldSubmitted: (_) => FocusScope.of(ctx).requestFocus(addressFocus),
                          hint: 'e.g. Sector F-7, Main Bazar',
                          t: t,
                        ),
                        const SizedBox(height: 12),
                        _DialogField(
                          label: 'Address',
                          controller: addressCtrl,
                          focusNode: addressFocus,
                          textInputAction: TextInputAction.next,
                          onFieldSubmitted: (_) => FocusScope.of(ctx).requestFocus(notesFocus),
                          hint: 'Shop / House address',
                          t: t,
                          maxLines: 2,
                        ),
                        const SizedBox(height: 12),
                        _DialogField(
                          label: 'Notes',
                          controller: notesCtrl,
                          focusNode: notesFocus,
                          textInputAction: TextInputAction.next,
                          onFieldSubmitted: (_) => FocusScope.of(ctx).requestFocus(reasonFocus),
                          hint: 'Optional notes',
                          t: t,
                          maxLines: 2,
                        ),
                        const SizedBox(height: 12),
                        // Active Status Switch
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: t.bgCardAlt,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: t.bgRule),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Active Status', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: t.textPrimary)),
                                  Text(isActive ? 'Box is currently active & deployed' : 'Box is retired / disabled', style: TextStyle(fontSize: 11, color: t.textTertiary)),
                                ],
                              ),
                              Switch(
                                value: isActive,
                                activeThumbColor: const Color(0xFF047857),
                                onChanged: (v) => setDialogState(() => isActive = v),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        // Audit Reason field
                        _DialogField(
                          label: 'Reason for Edit * (Required for Audit)',
                          controller: reasonCtrl,
                          focusNode: reasonFocus,
                          textInputAction: TextInputAction.done,
                          hint: 'e.g. Changed box holder phone number',
                          t: t,
                        ),
                        const SizedBox(height: 24),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => Navigator.pop(ctx),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: t.textSecondary,
                                  side: BorderSide(color: t.bgRule),
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                                child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w700)),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: () async {
                                  final cleanNum = numberCtrl.text.trim().toUpperCase();
                                  if (cleanNum.isEmpty) {
                                    ScaffoldMessenger.of(ctx).showSnackBar(
                                      const SnackBar(content: Text('Box number cannot be empty'), backgroundColor: Colors.red),
                                    );
                                    return;
                                  }
                                  if (cleanNum != box.boxNumber.toUpperCase() && DonationBoxStorage.isBoxNumberTaken(cleanNum, excludeBoxId: box.id)) {
                                    ScaffoldMessenger.of(ctx).showSnackBar(
                                      SnackBar(
                                        content: Text('Box number "$cleanNum" has already been assigned in the past. Box numbers can never be reused.'),
                                        backgroundColor: Colors.red,
                                      ),
                                    );
                                    return;
                                  }
                                  if (nameCtrl.text.trim().isEmpty) {
                                    ScaffoldMessenger.of(ctx).showSnackBar(
                                      const SnackBar(content: Text('Holder name is required'), backgroundColor: Colors.red),
                                    );
                                    return;
                                  }
                                  if (reasonCtrl.text.trim().isEmpty) {
                                    ScaffoldMessenger.of(ctx).showSnackBar(
                                      const SnackBar(content: Text('Please provide a reason for editing for audit trail'), backgroundColor: Colors.red),
                                    );
                                    return;
                                  }

                                  final updated = box.copyWith(
                                    boxNumber: cleanNum,
                                    holderName: nameCtrl.text.trim(),
                                    holderPhone: phoneCtrl.text.trim(),
                                    area: areaCtrl.text.trim(),
                                    holderAddress: addressCtrl.text.trim(),
                                    isActive: isActive,
                                    notes: notesCtrl.text.trim(),
                                    syncStatus: 'pending',
                                  );

                                  await DonationBoxStorage.updateBox(updated);

                                  // Record to global audit trail
                                  try {
                                    await DonationsLocalStorage.enqueueAuditLog(
                                      branchId: box.branchId,
                                      collection: 'donation_boxes',
                                      documentId: box.id,
                                      action: 'update',
                                      userId: widget.username,
                                      username: widget.username,
                                      oldData: box.toMap(),
                                      newData: updated.toMap(),
                                      reason: reasonCtrl.text.trim(),
                                    );
                                  } catch (auditErr) {
                                    debugPrint('[DonationBoxes] Failed to log audit: $auditErr');
                                  }

                                  if (ctx.mounted) Navigator.pop(ctx);
                                  _refresh();
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Box ${updated.boxNumber} updated successfully'), backgroundColor: Colors.green),
                                    );
                                  }
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: t.accent,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                                child: const Text('Save Changes', style: TextStyle(fontWeight: FontWeight.w800)),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showOpenBoxDialog(DonationBox box) {
    final amountCtrl = TextEditingController();
    final receiptNoCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    DateTime selectedDate = DateTime.now();

    showDialog(
      context: context,
      builder: (ctx) {
        final t = RoleThemeScope.dataOf(ctx);
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return Dialog(
              backgroundColor: t.bgCard,
              insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFF047857).withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.lock_open_rounded, size: 22, color: Color(0xFF047857)),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Open Box', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: t.textPrimary)),
                                Text(box.boxNumber, style: TextStyle(fontSize: 13, color: t.textTertiary, fontWeight: FontWeight.w600)),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      // Date picker
                      Text('Date', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: t.textSecondary)),
                      const SizedBox(height: 6),
                      InkWell(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: ctx,
                            initialDate: selectedDate,
                            firstDate: DateTime(2020),
                            lastDate: DateTime.now(),
                          );
                          if (picked != null) {
                            setDialogState(() => selectedDate = picked);
                          }
                        },
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: t.bgCardAlt,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: t.bgRule),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.calendar_today_rounded, size: 16, color: t.accent),
                              const SizedBox(width: 10),
                              Text(
                                DateFormat('dd MMM yyyy').format(selectedDate),
                                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: t.textPrimary),
                              ),
                              const Spacer(),
                              Icon(Icons.edit_rounded, size: 14, color: t.textTertiary),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      _DialogField(label: 'Amount (PKR) *', controller: amountCtrl, hint: '0', t: t, keyboardType: TextInputType.number),
                      const SizedBox(height: 14),
                      _DialogField(label: 'Physical / Paper Receipt # (Optional)', controller: receiptNoCtrl, hint: 'e.g. R-10492', t: t),
                      const SizedBox(height: 14),
                      _DialogField(label: 'Notes', controller: notesCtrl, hint: 'Optional', t: t),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => Navigator.pop(ctx),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: t.textSecondary,
                                side: BorderSide(color: t.bgRule),
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w700)),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: () async {
                                if (selectedDate.isAfter(DateTime.now())) {
                                  ScaffoldMessenger.of(ctx).showSnackBar(
                                    const SnackBar(content: Text('Cannot record donation box openings for future dates'), backgroundColor: Colors.red),
                                  );
                                  return;
                                }
                                final amt = double.tryParse(amountCtrl.text.trim().replaceAll(',', ''));
                                if (amt == null || amt < 0) {
                                  ScaffoldMessenger.of(ctx).showSnackBar(
                                    const SnackBar(content: Text('Enter a valid amount'), backgroundColor: Colors.red),
                                  );
                                  return;
                                }
                                final receiptNo = receiptNoCtrl.text.trim();
                                final opening = DonationBoxStorage.createOpening(
                                  boxId: box.id,
                                  boxNumber: box.boxNumber,
                                  openDate: DateFormat('yyyy-MM-dd').format(selectedDate),
                                  amount: amt,
                                  collectedBy: widget.username,
                                  branchId: widget.branchId,
                                  branchName: widget.branchName,
                                  notes: notesCtrl.text.trim(),
                                  physicalReceiptNo: receiptNo.isNotEmpty ? receiptNo : null,
                                );
                                await DonationBoxStorage.saveOpening(opening);

                                // Also record into master Donations collection
                                try {
                                  await DonationsLocalStorage.saveDonation(
                                    branchId: widget.branchId,
                                    data: {
                                      'donorName': 'Box ${box.boxNumber} (${box.holderName})',
                                      'phone': box.holderPhone,
                                      'donorId': box.id,
                                      'isAnonymous': false,
                                      'isBoxDonation': true,
                                      'boxId': box.id,
                                      'boxNumber': box.boxNumber,
                                      'amount': amt,
                                      'categoryId': 'gmwf',
                                      'gmwfSubCategoryId': 'dasterkhwaan',
                                      'subtypeId': 'sadqaAtyaat',
                                      'entryType': 'cash',
                                      'paymentMethod': 'Cash',
                                      'notes': notesCtrl.text.trim().isNotEmpty
                                          ? 'Donation Box ${box.boxNumber} Opening: ${notesCtrl.text.trim()}'
                                          : 'Donation Box ${box.boxNumber} Opening',
                                      'recordedBy': widget.username,
                                      'recordedByRole': widget.role.name,
                                      'status': widget.role.canMarkReceived ? DonationStatus.received : DonationStatus.pending,
                                      'date': DateFormat('yyyy-MM-dd').format(selectedDate),
                                      'timestamp': DateTime(
                                        selectedDate.year,
                                        selectedDate.month,
                                        selectedDate.day,
                                        DateTime.now().hour,
                                        DateTime.now().minute,
                                        DateTime.now().second,
                                      ).toIso8601String(),
                                      if (receiptNo.isNotEmpty) 'bookReceiptNo': receiptNo,
                                      'branchName': widget.branchName,
                                    },
                                  );
                                } catch (err) {
                                  debugPrint('[DonationBoxesScreen] Failed to save donation receipt for box: $err');
                                }

                                if (ctx.mounted) Navigator.pop(ctx);
                                _refresh();
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('Box ${box.boxNumber} opened — PKR ${NumberFormat('#,##0').format(amt)}'),
                                      backgroundColor: Colors.green,
                                    ),
                                  );
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF047857),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              child: const Text('Record Opening', style: TextStyle(fontWeight: FontWeight.w800)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showReportIncidentDialog(DonationBox box) {
    String incidentType = 'snatched'; // 'snatched', 'stolen', 'broken'
    DateTime incidentDate = DateTime.now();
    final reporterCtrl = TextEditingController(text: widget.username);
    final policeCtrl = TextEditingController();
    final lossCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    bool immediatelyReplace = true;

    showDialog(
      context: context,
      builder: (ctx) {
        final t = RoleThemeScope.dataOf(ctx);
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return Dialog(
              backgroundColor: t.bgCard,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: const Color(0xFFDC2626).withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(Icons.report_problem_rounded, size: 24, color: Color(0xFFDC2626)),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Report Box Incident', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: t.textPrimary)),
                                  Text('${box.boxNumber} • ${box.holderName}', style: TextStyle(fontSize: 12.5, color: t.textTertiary, fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                            IconButton(
                              onPressed: () => Navigator.pop(ctx),
                              icon: Icon(Icons.close_rounded, color: t.textTertiary),
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        Text('What happened to this box? *', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: t.textSecondary)),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            _buildIncidentTypeChip('snatched', 'Snatched 🚨', const Color(0xFFDC2626), incidentType, (val) => setDialogState(() => incidentType = val)),
                            const SizedBox(width: 8),
                            _buildIncidentTypeChip('stolen', 'Stolen ⚠️', const Color(0xFFEA580C), incidentType, (val) => setDialogState(() => incidentType = val)),
                            const SizedBox(width: 8),
                            _buildIncidentTypeChip('broken', 'Broken 🔨', const Color(0xFFD97706), incidentType, (val) => setDialogState(() => incidentType = val)),
                          ],
                        ),
                        const SizedBox(height: 16),
                        // Date picker
                        Text('Incident Date *', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: t.textSecondary)),
                        const SizedBox(height: 6),
                        InkWell(
                          onTap: () async {
                            final picked = await showDatePicker(
                              context: ctx,
                              initialDate: incidentDate,
                              firstDate: DateTime(2020),
                              lastDate: DateTime.now(),
                            );
                            if (picked != null) {
                              setDialogState(() => incidentDate = picked);
                            }
                          },
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(
                              color: t.bgCardAlt,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: t.bgRule),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.calendar_today_rounded, size: 16, color: t.accent),
                                const SizedBox(width: 10),
                                Text(DateFormat('dd MMM yyyy').format(incidentDate), style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: t.textPrimary)),
                                const Spacer(),
                                Icon(Icons.edit_rounded, size: 14, color: t.textTertiary),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        _DialogField(label: 'Reported By (Collector / Staff)', controller: reporterCtrl, hint: 'Name of reporter', t: t),
                        const SizedBox(height: 14),
                        _DialogField(label: 'Police FIR / Complaint # (Optional)', controller: policeCtrl, hint: 'e.g. FIR-2026/89', t: t),
                        const SizedBox(height: 14),
                        _DialogField(label: 'Estimated Cash in Box Lost (PKR, Optional)', controller: lossCtrl, hint: '0', t: t, keyboardType: TextInputType.number),
                        const SizedBox(height: 14),
                        _DialogField(label: 'Incident Notes & Circumstances', controller: notesCtrl, hint: 'Describe what occurred...', t: t, maxLines: 2),
                        const SizedBox(height: 16),
                        // Immediate replacement option
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: t.accent.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: t.accent.withValues(alpha: 0.2)),
                          ),
                          child: Row(
                            children: [
                              Checkbox(
                                value: immediatelyReplace,
                                activeColor: t.accent,
                                onChanged: (val) => setDialogState(() => immediatelyReplace = val ?? true),
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Immediately assign a replacement box', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: t.textPrimary)),
                                    Text('Keep historical data and assign new box number for ${box.holderName}', style: TextStyle(fontSize: 11, color: t.textTertiary)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => Navigator.pop(ctx),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: t.textSecondary,
                                  side: BorderSide(color: t.bgRule),
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                                child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w700)),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: () async {
                                  final lossAmt = double.tryParse(lossCtrl.text.trim().replaceAll(',', ''));
                                  final updatedBox = await DonationBoxStorage.reportIncident(
                                    boxId: box.id,
                                    incidentType: incidentType,
                                    incidentDate: DateFormat('yyyy-MM-dd').format(incidentDate),
                                    incidentReportedBy: reporterCtrl.text.trim(),
                                    incidentNotes: notesCtrl.text.trim(),
                                    policeReportNo: policeCtrl.text.trim(),
                                    estimatedCashLost: lossAmt,
                                  );

                                  if (ctx.mounted) Navigator.pop(ctx);
                                  _refresh();

                                  if (immediatelyReplace && mounted) {
                                    _showAssignReplacementBoxDialog(updatedBox);
                                  } else {
                                    if (mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text('Incident logged for ${box.boxNumber}. Historical collections preserved.'),
                                          backgroundColor: Colors.orange.shade800,
                                        ),
                                      );
                                    }
                                  }
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFFDC2626),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                                child: const Text('Confirm Report', style: TextStyle(fontWeight: FontWeight.w800)),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showAssignReplacementBoxDialog(DonationBox compromisedBox) {
    final boxNumCtrl = TextEditingController();
    final holderNameCtrl = TextEditingController(text: compromisedBox.holderName);
    final phoneCtrl = TextEditingController(text: compromisedBox.holderPhone);
    final addressCtrl = TextEditingController(text: compromisedBox.holderAddress);
    final areaCtrl = TextEditingController(text: compromisedBox.area);
    final notesCtrl = TextEditingController(text: 'Replacement for ${compromisedBox.boxNumber} (${compromisedBox.status.toUpperCase()})');

    showDialog(
      context: context,
      builder: (ctx) {
        final t = RoleThemeScope.dataOf(ctx);
        return Dialog(
          backgroundColor: t.bgCard,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF7C3AED).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.sync_alt_rounded, size: 24, color: Color(0xFF7C3AED)),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Assign Replacement Box', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: t.textPrimary)),
                              Text('Replaces ${compromisedBox.boxNumber} (${compromisedBox.status.toUpperCase()})', style: TextStyle(fontSize: 12.5, color: t.textTertiary, fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(ctx),
                          icon: Icon(Icons.close_rounded, color: t.textTertiary),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: t.bgCardAlt,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: t.bgRule),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline_rounded, size: 16, color: t.accent),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Historical collections for ${compromisedBox.boxNumber} will remain completely safe and linked in the audit ledger.',
                              style: TextStyle(fontSize: 11.5, color: t.textSecondary),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF7C3AED).withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF7C3AED).withValues(alpha: 0.2)),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.edit_note_rounded, size: 16, color: Color(0xFF7C3AED)),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Please manually enter the physical box number. Box numbers can never be reused.',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF7C3AED)),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    _DialogField(
                      label: 'New Unique Box Number * (Enter Manually)',
                      controller: boxNumCtrl,
                      hint: 'e.g. BOX-045',
                      autofocus: true,
                      t: t,
                    ),
                    const SizedBox(height: 12),
                    _DialogField(label: 'Holder Name *', controller: holderNameCtrl, hint: 'Name of person keeping box', t: t),
                    const SizedBox(height: 12),
                    _DialogField(label: 'Holder Phone', controller: phoneCtrl, hint: '03XX-XXXXXXX', t: t, keyboardType: TextInputType.phone),
                    const SizedBox(height: 12),
                    _DialogField(label: 'Area / Sector', controller: areaCtrl, hint: 'e.g. Market A', t: t),
                    const SizedBox(height: 12),
                    _DialogField(label: 'Full Address', controller: addressCtrl, hint: 'Shop / house address', t: t),
                    const SizedBox(height: 12),
                    _DialogField(label: 'Notes', controller: notesCtrl, hint: 'Optional remarks', t: t),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(ctx),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: t.textSecondary,
                              side: BorderSide(color: t.bgRule),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w700)),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () async {
                              final newBoxNo = boxNumCtrl.text.trim().toUpperCase();
                              if (newBoxNo.isEmpty) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  const SnackBar(content: Text('Please enter a new box number'), backgroundColor: Colors.red),
                                );
                                return;
                              }
                              if (DonationBoxStorage.isBoxNumberTaken(newBoxNo)) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  SnackBar(
                                    content: Text('Box number "$newBoxNo" has already been assigned in the past. An assigned box number can never be reused.'),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                                return;
                              }

                              final created = await DonationBoxStorage.assignReplacementBox(
                                compromisedBoxId: compromisedBox.id,
                                newBoxNumber: newBoxNo,
                                customHolderName: holderNameCtrl.text.trim(),
                                customPhone: phoneCtrl.text.trim(),
                                customAddress: addressCtrl.text.trim(),
                                customArea: areaCtrl.text.trim(),
                                notes: notesCtrl.text.trim(),
                              );

                              if (ctx.mounted) Navigator.pop(ctx);
                              _refresh();

                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Replacement Box ${created.boxNumber} successfully registered and linked!'),
                                    backgroundColor: Colors.green.shade800,
                                  ),
                                );
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF7C3AED),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            child: const Text('Assign Box', style: TextStyle(fontWeight: FontWeight.w800)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _showBoxDetail(DonationBox box) {
    showDialog(
      context: context,
      builder: (ctx) => _BoxDetailDialog(
        box: box,
        branchId: widget.branchId,
        username: widget.username,
        onOpenBox: () {
          Navigator.pop(ctx);
          _showOpenBoxDialog(box);
        },
        onEditBox: () {
          Navigator.pop(ctx);
          _showEditBoxDialog(box);
        },
        onReportIncident: () {
          Navigator.pop(ctx);
          _showReportIncidentDialog(box);
        },
        onAssignReplacement: () {
          Navigator.pop(ctx);
          _showAssignReplacementBoxDialog(box);
        },
        onRefresh: _refresh,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BOX CARD
// ─────────────────────────────────────────────────────────────────────────────

class _BoxCard extends StatefulWidget {
  final DonationBox box;
  final VoidCallback onTap;
  final VoidCallback onOpenBox;
  final VoidCallback onEdit;
  final VoidCallback onReportIncident;
  final VoidCallback onAssignReplacement;

  const _BoxCard({
    required this.box,
    required this.onTap,
    required this.onOpenBox,
    required this.onEdit,
    required this.onReportIncident,
    required this.onAssignReplacement,
  });

  @override
  State<_BoxCard> createState() => _BoxCardState();
}

class _BoxCardState extends State<_BoxCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    final box = widget.box;
    final fmt = NumberFormat('#,##0');

    final Color statusColor;
    final String statusLabel;
    final IconData statusIcon;

    if (box.isSnatched) {
      statusColor = const Color(0xFFDC2626);
      statusLabel = 'Snatched 🚨';
      statusIcon = Icons.warning_rounded;
    } else if (box.isStolen) {
      statusColor = const Color(0xFFEA580C);
      statusLabel = 'Stolen ⚠️';
      statusIcon = Icons.warning_amber_rounded;
    } else if (box.isBroken) {
      statusColor = const Color(0xFFD97706);
      statusLabel = 'Broken 🔨';
      statusIcon = Icons.build_circle_rounded;
    } else if (box.isReplaced) {
      statusColor = const Color(0xFF7C3AED);
      statusLabel = 'Replaced 🔄';
      statusIcon = Icons.sync_alt_rounded;
    } else if (!box.isActive) {
      statusColor = const Color(0xFF6B7280);
      statusLabel = 'Inactive';
      statusIcon = Icons.pause_circle_rounded;
    } else if (box.isOverdue) {
      statusColor = const Color(0xFFDC2626);
      statusLabel = 'Overdue ${box.daysSinceLastOpened ?? 30}d';
      statusIcon = Icons.warning_amber_rounded;
    } else {
      statusColor = const Color(0xFF047857);
      statusLabel = box.lastOpenedDate != null ? '${box.daysSinceLastOpened}d ago' : 'New';
      statusIcon = Icons.check_circle_rounded;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(16),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _isHovered ? t.accent.withValues(alpha: 0.03) : t.bgCard,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _isHovered ? t.accent.withValues(alpha: 0.2) : t.bgRule,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: _isHovered ? 0.04 : 0.02),
                  blurRadius: _isHovered ? 12 : 6,
                  offset: Offset(0, _isHovered ? 4 : 2),
                ),
              ],
            ),
            child: Row(
              children: [
                // Box number badge
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: statusColor.withValues(alpha: 0.15)),
                  ),
                  child: Center(
                    child: Text(
                      box.boxNumber.replaceAll('BOX-', ''),
                      style: GoogleFonts.dmMono(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: statusColor,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                // Info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              box.holderName,
                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: t.textPrimary),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (box.area.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: t.accent.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: t.accent.withValues(alpha: 0.2)),
                              ),
                              child: Text(
                                box.area,
                                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: t.accent),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        box.holderAddress.isNotEmpty
                            ? box.holderAddress
                            : (box.holderPhone.isNotEmpty ? box.holderPhone : 'No address specified'),
                        style: TextStyle(fontSize: 12, color: t.textTertiary),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: statusColor.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(statusIcon, size: 11, color: statusColor),
                                const SizedBox(width: 4),
                                Text(statusLabel, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: statusColor)),
                              ],
                            ),
                          ),
                          if (box.replacementForBoxId != null)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                              decoration: BoxDecoration(
                                color: const Color(0xFF7C3AED).withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                'Replaces ${box.replacementForBoxId}',
                                style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, color: Color(0xFF7C3AED)),
                              ),
                            ),
                          if (box.lastOpenedAmount != null)
                            Text(
                              'PKR ${fmt.format(box.lastOpenedAmount)}',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: t.textSecondary),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),

                // Actions based on state
                if (box.isCompromised) ...[
                  if (box.replacedByBoxId != null) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                      decoration: BoxDecoration(
                        color: const Color(0xFF7C3AED).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text('Replaced 🔄', style: GoogleFonts.plusJakartaSans(fontSize: 11, fontWeight: FontWeight.w800, color: const Color(0xFF7C3AED))),
                    ),
                  ] else ...[
                    ElevatedButton.icon(
                      onPressed: widget.onAssignReplacement,
                      icon: const Icon(Icons.sync_alt_rounded, size: 13),
                      label: const Text('Replace', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF7C3AED),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        visualDensity: VisualDensity.compact,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ],
                ] else ...[
                  // Report Incident icon button
                  IconButton(
                    onPressed: widget.onReportIncident,
                    icon: const Icon(Icons.report_problem_outlined, size: 17, color: Color(0xFFDC2626)),
                    tooltip: 'Report Incident (Snatched/Stolen/Broken)',
                    style: IconButton.styleFrom(
                      padding: const EdgeInsets.all(8),
                      backgroundColor: const Color(0xFFDC2626).withValues(alpha: 0.08),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    onPressed: widget.onEdit,
                    icon: Icon(Icons.edit_rounded, size: 18, color: t.textTertiary),
                    tooltip: 'Edit Box',
                    style: IconButton.styleFrom(
                      padding: const EdgeInsets.all(8),
                      backgroundColor: t.bgCardAlt,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // Open button
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: widget.onOpenBox,
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF047857).withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF047857).withValues(alpha: 0.2)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.lock_open_rounded, size: 14, color: Color(0xFF047857)),
                            const SizedBox(width: 6),
                            Text(
                              'Open',
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                color: const Color(0xFF047857),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BOX DETAIL DIALOG
// ─────────────────────────────────────────────────────────────────────────────

class _BoxDetailDialog extends StatefulWidget {
  final DonationBox box;
  final String branchId;
  final String username;
  final VoidCallback onOpenBox;
  final VoidCallback onEditBox;
  final VoidCallback onReportIncident;
  final VoidCallback onAssignReplacement;
  final VoidCallback onRefresh;

  const _BoxDetailDialog({
    required this.box,
    required this.branchId,
    required this.username,
    required this.onOpenBox,
    required this.onEditBox,
    required this.onReportIncident,
    required this.onAssignReplacement,
    required this.onRefresh,
  });

  @override
  State<_BoxDetailDialog> createState() => _BoxDetailDialogState();
}

class _BoxDetailDialogState extends State<_BoxDetailDialog> {
  late List<BoxOpening> _openings;
  int _reportYear = DateTime.now().year;

  @override
  void initState() {
    super.initState();
    _openings = DonationBoxStorage.getOpeningsForBox(widget.box.id);
  }

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    final box = widget.box;
    final fmt = NumberFormat('#,##0');
    final totalCollected = _openings.fold<double>(0, (sum, o) => sum + o.amount);
    final isMobile = MediaQuery.of(context).size.width < 600;

    return Dialog(
      backgroundColor: t.bgCard,
      insetPadding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 40, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 560, maxHeight: MediaQuery.of(context).size.height * 0.85),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: t.bgRule)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 48, height: 48,
                    decoration: BoxDecoration(
                      color: (box.isCompromised ? const Color(0xFFDC2626) : t.accent).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Center(
                      child: Text(
                        box.boxNumber.replaceAll('BOX-', ''),
                        style: GoogleFonts.dmMono(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: box.isCompromised ? const Color(0xFFDC2626) : t.accent,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(box.boxNumber, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: t.textPrimary)),
                            if (box.isCompromised) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFDC2626).withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: const Color(0xFFDC2626).withValues(alpha: 0.3)),
                                ),
                                child: Text(
                                  box.status.toUpperCase(),
                                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Color(0xFFDC2626)),
                                ),
                              ),
                            ],
                          ],
                        ),
                        Text(box.holderName, style: TextStyle(fontSize: 13, color: t.textSecondary)),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(Icons.close_rounded, color: t.textTertiary),
                  ),
                ],
              ),
            ),
            // Body
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Incident Banner if box is compromised
                    if (box.isCompromised) ...[
                      Container(
                        padding: const EdgeInsets.all(14),
                        margin: const EdgeInsets.only(bottom: 18),
                        decoration: BoxDecoration(
                          color: const Color(0xFFDC2626).withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFFDC2626).withValues(alpha: 0.25)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.report_problem_rounded, color: Color(0xFFDC2626), size: 20),
                                const SizedBox(width: 8),
                                Text(
                                  'INCIDENT REPORTED: ${box.status.toUpperCase()}',
                                  style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xFFDC2626), fontSize: 13),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            if (box.incidentDate != null && box.incidentDate!.isNotEmpty)
                              Text('Date: ${box.incidentDate} (Reported by: ${box.incidentReportedBy ?? "Staff"})', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.textSecondary)),
                            if (box.policeReportNo != null && box.policeReportNo!.isNotEmpty)
                              Text('FIR / Police Report #: ${box.policeReportNo}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: t.textPrimary)),
                            if (box.estimatedCashLost != null && box.estimatedCashLost! > 0)
                              Text('Estimated Cash Lost: PKR ${fmt.format(box.estimatedCashLost)}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Color(0xFFDC2626))),
                            if (box.incidentNotes != null && box.incidentNotes!.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text('Notes: ${box.incidentNotes}', style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: t.textTertiary)),
                              ),
                            if (box.replacedByBoxId != null) ...[
                              const SizedBox(height: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF7C3AED).withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text('Replaced by Box: ${box.replacedByBoxId}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFF7C3AED))),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],

                    if (box.replacementForBoxId != null) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.only(bottom: 18),
                        decoration: BoxDecoration(
                          color: const Color(0xFF7C3AED).withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF7C3AED).withValues(alpha: 0.2)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.sync_alt_rounded, size: 16, color: Color(0xFF7C3AED)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'This box is a replacement for compromised box ${box.replacementForBoxId}. Historical data has been transferred and preserved.',
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF7C3AED)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    // Info section
                    _InfoRow(label: 'Holder', value: box.holderName, icon: Icons.person_rounded, t: t),
                    if (box.holderPhone.isNotEmpty) _InfoRow(label: 'Phone', value: box.holderPhone, icon: Icons.phone_rounded, t: t),
                    if (box.area.isNotEmpty) _InfoRow(label: 'Area / Zone', value: box.area, icon: Icons.location_city_rounded, t: t),
                    if (box.holderAddress.isNotEmpty) _InfoRow(label: 'Address', value: box.holderAddress, icon: Icons.location_on_rounded, t: t),
                    _InfoRow(label: 'Status', value: box.status.toUpperCase(), icon: box.isActive ? Icons.check_circle_rounded : Icons.pause_circle_rounded, t: t),
                    _InfoRow(label: 'Registered', value: box.registeredDate, icon: Icons.calendar_today_rounded, t: t),
                    _InfoRow(label: 'Total Collected', value: 'PKR ${fmt.format(totalCollected)}', icon: Icons.payments_rounded, t: t),
                    _InfoRow(label: 'Times Opened', value: '${_openings.length}', icon: Icons.lock_open_rounded, t: t),

                    const SizedBox(height: 20),

                    // Actions
                    Row(
                      children: [
                        if (!box.isCompromised && !box.isReplaced) ...[
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: widget.onOpenBox,
                              icon: const Icon(Icons.lock_open_rounded, size: 18),
                              label: const Text('Open Box', style: TextStyle(fontWeight: FontWeight.w800)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF047857),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: widget.onReportIncident,
                            icon: const Icon(Icons.report_problem_outlined, size: 16, color: Color(0xFFDC2626)),
                            label: const Text('Report', style: TextStyle(fontWeight: FontWeight.w800, color: Color(0xFFDC2626))),
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(color: const Color(0xFFDC2626).withValues(alpha: 0.3)),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                        ] else ...[
                          if (box.replacedByBoxId == null) ...[
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: widget.onAssignReplacement,
                                icon: const Icon(Icons.sync_alt_rounded, size: 18),
                                label: const Text('Assign Replacement Box', style: TextStyle(fontWeight: FontWeight.w800)),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF7C3AED),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                        ],
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: widget.onEditBox,
                          icon: Icon(Icons.edit_rounded, size: 16, color: t.accent),
                          label: Text('Edit', style: TextStyle(fontWeight: FontWeight.w800, color: t.accent)),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: t.accent.withValues(alpha: 0.3)),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _showYearlyReport(),
                            icon: Icon(Icons.download_rounded, size: 18, color: t.textSecondary),
                            label: Text('Report', style: TextStyle(fontWeight: FontWeight.w800, color: t.textPrimary)),
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(color: t.bgRule),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 24),

                    // Opening history
                    Text('OPENING HISTORY', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: t.textTertiary, letterSpacing: 1.2)),
                    const SizedBox(height: 12),

                    if (_openings.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: t.bgCardAlt,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Center(
                          child: Text('No openings recorded yet', style: TextStyle(color: t.textTertiary, fontSize: 13)),
                        ),
                      )
                    else
                      ..._openings.take(20).map((o) => _OpeningTimelineItem(opening: o, t: t)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showYearlyReport() {
    showDialog(
      context: context,
      builder: (ctx) {
        final t = RoleThemeScope.dataOf(ctx);
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final report = DonationBoxStorage.getYearlyReport(widget.box.id, _reportYear);
            final fmt = NumberFormat('#,##0');
            final totalAmount = report.fold<double>(0, (sum, r) => sum + r.amount);
            final openedCount = report.where((r) => r.wasOpened).length;

            return Dialog(
              backgroundColor: t.bgCard,
              insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 500, maxHeight: MediaQuery.of(ctx).size.height * 0.8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Header
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
                      child: Row(
                        children: [
                          Icon(Icons.analytics_rounded, color: t.accent, size: 24),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              '${widget.box.boxNumber} — $_reportYear Report',
                              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: t.textPrimary),
                            ),
                          ),
                          // Year picker
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: t.bgCardAlt,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: t.bgRule),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                InkWell(
                                  onTap: () => setDialogState(() => _reportYear--),
                                  child: Icon(Icons.chevron_left_rounded, size: 20, color: t.textSecondary),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 8),
                                  child: Text('$_reportYear', style: TextStyle(fontWeight: FontWeight.w800, color: t.textPrimary, fontSize: 14)),
                                ),
                                InkWell(
                                  onTap: _reportYear < DateTime.now().year ? () => setDialogState(() => _reportYear++) : null,
                                  child: Icon(Icons.chevron_right_rounded, size: 20, color: _reportYear < DateTime.now().year ? t.textSecondary : t.textTertiary.withValues(alpha: 0.3)),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Divider(color: t.bgRule, height: 1),
                    // Report grid
                    Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          children: [
                            // Summary bar
                            Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: t.accent.withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: t.accent.withValues(alpha: 0.12)),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceAround,
                                children: [
                                  Column(children: [
                                    Text('Opened', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: t.textTertiary)),
                                    const SizedBox(height: 4),
                                    Text('$openedCount / 12', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: t.accent)),
                                  ]),
                                  Container(width: 1, height: 32, color: t.bgRule),
                                  Column(children: [
                                    Text('Total', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: t.textTertiary)),
                                    const SizedBox(height: 4),
                                    Text('PKR ${fmt.format(totalAmount)}', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: t.textPrimary)),
                                  ]),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),
                            // Monthly rows
                            ...report.map((r) {
                              final Color rowColor = r.wasOpened
                                  ? const Color(0xFF047857).withValues(alpha: 0.06)
                                  : const Color(0xFFDC2626).withValues(alpha: 0.04);
                              final Color textColor = r.wasOpened
                                  ? const Color(0xFF047857)
                                  : const Color(0xFFDC2626);

                              return Container(
                                margin: const EdgeInsets.only(bottom: 6),
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                decoration: BoxDecoration(
                                  color: rowColor,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 80,
                                      child: Text(r.monthName, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: t.textPrimary)),
                                    ),
                                    Icon(
                                      r.wasOpened ? Icons.check_circle_rounded : Icons.cancel_rounded,
                                      size: 16,
                                      color: textColor,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      r.wasOpened ? 'OPENED' : 'NOT OPENED',
                                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: textColor),
                                    ),
                                    const Spacer(),
                                    if (r.wasOpened)
                                      Text(
                                        'PKR ${fmt.format(r.amount)}',
                                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: t.textPrimary),
                                      ),
                                  ],
                                ),
                              );
                            }),
                          ],
                        ),
                      ),
                    ),
                    // Footer
                    Container(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                      decoration: BoxDecoration(
                        border: Border(top: BorderSide(color: t.bgRule)),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => Navigator.pop(ctx),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: t.textSecondary,
                                side: BorderSide(color: t.bgRule),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              child: const Text('Close', style: TextStyle(fontWeight: FontWeight.w700)),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () async {
                                await DonationBoxStorage.exportBoxYearlyReport(widget.box, _reportYear);
                                if (ctx.mounted) {
                                  ScaffoldMessenger.of(ctx).showSnackBar(
                                    const SnackBar(content: Text('Report exported'), backgroundColor: Colors.green),
                                  );
                                }
                              },
                              icon: const Icon(Icons.download_rounded, size: 18),
                              label: const Text('Download Excel', style: TextStyle(fontWeight: FontWeight.w800)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: t.accent,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// HELPER WIDGETS
// ─────────────────────────────────────────────────────────────────────────────

class _SummaryMiniCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final RoleThemeData t;

  const _SummaryMiniCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    required this.t,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.bgRule),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 6, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(height: 10),
          Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: t.textTertiary, letterSpacing: 0.6)),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: t.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

class _RegisterBoxButton extends StatefulWidget {
  final VoidCallback onTap;
  final bool isMobile;

  const _RegisterBoxButton({required this.onTap, required this.isMobile});

  @override
  State<_RegisterBoxButton> createState() => _RegisterBoxButtonState();
}

class _RegisterBoxButtonState extends State<_RegisterBoxButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: EdgeInsets.symmetric(horizontal: widget.isMobile ? 14 : 20, vertical: 12),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: _isHovered
                  ? [t.accent, t.accent.withValues(alpha: 0.85)]
                  : [t.accent.withValues(alpha: 0.9), t.accent],
            ),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: t.accent.withValues(alpha: _isHovered ? 0.35 : 0.15),
                blurRadius: _isHovered ? 16 : 8,
                offset: Offset(0, _isHovered ? 6 : 3),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.add_rounded, size: 18, color: Colors.white),
              if (!widget.isMobile) ...[
                const SizedBox(width: 8),
                const Text('Register Box', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DialogField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String hint;
  final RoleThemeData t;
  final TextInputType? keyboardType;
  final int maxLines;
  final List<TextInputFormatter>? inputFormatters;
  final FocusNode? focusNode;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onFieldSubmitted;
  final bool autofocus;

  const _DialogField({
    required this.label,
    required this.controller,
    required this.hint,
    required this.t,
    this.keyboardType,
    this.maxLines = 1,
    this.inputFormatters,
    this.focusNode,
    this.textInputAction,
    this.onFieldSubmitted,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: t.textSecondary)),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          focusNode: focusNode,
          autofocus: autofocus,
          textInputAction: textInputAction ?? (maxLines > 1 ? TextInputAction.newline : TextInputAction.next),
          onSubmitted: onFieldSubmitted,
          keyboardType: keyboardType,
          inputFormatters: inputFormatters ??
              (keyboardType == TextInputType.phone
                  ? [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(11)]
                  : (keyboardType == TextInputType.number
                      ? [FilteringTextInputFormatter.digitsOnly]
                      : null)),
          maxLines: maxLines,
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.textPrimary),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: t.textTertiary, fontWeight: FontWeight.w400),
            filled: true,
            fillColor: t.bgCardAlt,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: t.bgRule),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: t.bgRule),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: t.accent, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final RoleThemeData t;

  const _InfoRow({required this.label, required this.value, required this.icon, required this.t});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: t.accent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 14, color: t.accent),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 80,
            child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.textTertiary)),
          ),
          Expanded(
            child: Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: t.textPrimary)),
          ),
        ],
      ),
    );
  }
}

class _OpeningTimelineItem extends StatelessWidget {
  final BoxOpening opening;
  final RoleThemeData t;

  const _OpeningTimelineItem({required this.opening, required this.t});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat('#,##0');
    final date = DateTime.tryParse(opening.openDate);
    final dateLabel = date != null ? DateFormat('dd MMM yyyy').format(date) : opening.openDate;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 10, height: 10,
                decoration: BoxDecoration(
                  color: const Color(0xFF047857),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF047857).withValues(alpha: 0.3), width: 2),
                ),
              ),
              Container(width: 2, height: 30, color: t.bgRule),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: t.bgCardAlt,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(dateLabel, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: t.textPrimary)),
                            if (opening.physicalReceiptNo != null && opening.physicalReceiptNo!.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF047857).withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: const Color(0xFF047857).withValues(alpha: 0.25)),
                                ),
                                child: Text(
                                  'Receipt #: ${opening.physicalReceiptNo}',
                                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFF047857)),
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (opening.collectedBy.isNotEmpty)
                          Text('by ${opening.collectedBy}', style: TextStyle(fontSize: 11, color: t.textTertiary)),
                        if (opening.notes.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(opening.notes, style: TextStyle(fontSize: 11, color: t.textTertiary, fontStyle: FontStyle.italic)),
                          ),
                      ],
                    ),
                  ),
                  Text(
                    'PKR ${fmt.format(opening.amount)}',
                    style: GoogleFonts.dmMono(fontSize: 14, fontWeight: FontWeight.w800, color: const Color(0xFF047857)),
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

// ─────────────────────────────────────────────────────────────────────────────
// PERSON AUDIT & RISK CARD
// ─────────────────────────────────────────────────────────────────────────────

class _PersonAuditCard extends StatefulWidget {
  final PersonBoxAuditSummary summary;
  final VoidCallback onRefresh;
  final Function(DonationBox) onOpenBox;
  final Function(DonationBox) onShowDetail;
  final Function(DonationBox) onReportIncident;
  final Function(DonationBox) onAssignReplacement;

  const _PersonAuditCard({
    required this.summary,
    required this.onRefresh,
    required this.onOpenBox,
    required this.onShowDetail,
    required this.onReportIncident,
    required this.onAssignReplacement,
  });

  @override
  State<_PersonAuditCard> createState() => _PersonAuditCardState();
}

class _PersonAuditCardState extends State<_PersonAuditCard> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    final s = widget.summary;
    final fmt = NumberFormat('#,##0');

    final bool hasIncidents = s.totalIncidents > 0;
    final Color riskColor;
    final Color riskBg;
    final String riskBadge;
    final IconData riskIcon;

    if (s.totalIncidents >= 2) {
      riskColor = const Color(0xFFDC2626);
      riskBg = const Color(0xFFDC2626).withValues(alpha: 0.1);
      riskBadge = 'High Accident Risk (${s.totalIncidents} Incidents)';
      riskIcon = Icons.warning_rounded;
    } else if (s.totalIncidents == 1) {
      riskColor = const Color(0xFFEA580C);
      riskBg = const Color(0xFFEA580C).withValues(alpha: 0.1);
      riskBadge = 'Incident Reported (1 Accident)';
      riskIcon = Icons.warning_amber_rounded;
    } else if (s.totalMoneyOutput > 50000) {
      riskColor = const Color(0xFF047857);
      riskBg = const Color(0xFF047857).withValues(alpha: 0.1);
      riskBadge = 'Top Output / Trusted';
      riskIcon = Icons.verified_rounded;
    } else {
      riskColor = const Color(0xFF2563EB);
      riskBg = const Color(0xFF2563EB).withValues(alpha: 0.1);
      riskBadge = 'Normal / Stable';
      riskIcon = Icons.check_circle_outline_rounded;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        decoration: BoxDecoration(
          color: t.bgCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: hasIncidents ? const Color(0xFFDC2626).withValues(alpha: 0.3) : t.bgRule,
            width: hasIncidents ? 1.5 : 1.0,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: hasIncidents ? 0.04 : 0.02),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Avatar
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: riskBg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: riskColor.withValues(alpha: 0.25)),
                    ),
                    child: Center(
                      child: Icon(riskIcon, color: riskColor, size: 22),
                    ),
                  ),
                  const SizedBox(width: 14),
                  // Name and details
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                s.personName,
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: t.textPrimary),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: riskBg,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: riskColor.withValues(alpha: 0.2)),
                              ),
                              child: Text(
                                riskBadge,
                                style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: riskColor),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            if (s.phone.isNotEmpty) ...[
                              Icon(Icons.phone_outlined, size: 12, color: t.textTertiary),
                              const SizedBox(width: 4),
                              Text(s.phone, style: TextStyle(fontSize: 12, color: t.textSecondary)),
                              const SizedBox(width: 12),
                            ],
                            if (s.area.isNotEmpty) ...[
                              Icon(Icons.location_on_outlined, size: 12, color: t.textTertiary),
                              const SizedBox(width: 4),
                              Text(s.area, style: TextStyle(fontSize: 12, color: t.textSecondary)),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  // Expand Toggle
                  IconButton(
                    onPressed: () => setState(() => _isExpanded = !_isExpanded),
                    icon: Icon(
                      _isExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                      color: t.textSecondary,
                    ),
                    tooltip: _isExpanded ? 'Collapse' : 'Show Boxes & Audit',
                  ),
                ],
              ),
            ),

            // Key Metrics Banner (Money Output vs Accidents)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: t.bgCardAlt,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: t.bgRule),
              ),
              child: Row(
                children: [
                  // Lifetime Money Output
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.payments_rounded, size: 13, color: Color(0xFF047857)),
                            const SizedBox(width: 4),
                            Text('TOTAL MONEY OUTPUT', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: t.textTertiary, letterSpacing: 0.5)),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'PKR ${fmt.format(s.totalMoneyOutput)}',
                          style: GoogleFonts.dmMono(fontSize: 16, fontWeight: FontWeight.w900, color: const Color(0xFF047857)),
                        ),
                        Text('${s.totalOpeningsCount} collections', style: TextStyle(fontSize: 10.5, color: t.textTertiary)),
                      ],
                    ),
                  ),
                  Container(width: 1, height: 38, color: t.bgRule),
                  const SizedBox(width: 14),
                  // Accidents / Incidents
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.report_problem_rounded, size: 13, color: hasIncidents ? const Color(0xFFDC2626) : t.textTertiary),
                            const SizedBox(width: 4),
                            Text('TOTAL ACCIDENTS', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: hasIncidents ? const Color(0xFFDC2626) : t.textTertiary, letterSpacing: 0.5)),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${s.totalIncidents} Accidents',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                            color: hasIncidents ? const Color(0xFFDC2626) : t.textPrimary,
                          ),
                        ),
                        Text(
                          s.totalIncidents > 0
                              ? [
                                  if (s.snatchedCount > 0) '${s.snatchedCount} Snatched',
                                  if (s.stolenCount > 0) '${s.stolenCount} Stolen',
                                  if (s.brokenCount > 0) '${s.brokenCount} Broken',
                                ].join(' • ')
                              : '0 incidents logged',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: hasIncidents ? FontWeight.w700 : FontWeight.w500,
                            color: hasIncidents ? const Color(0xFFDC2626) : t.textTertiary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  Container(width: 1, height: 38, color: t.bgRule),
                  const SizedBox(width: 14),
                  // Boxes overview
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.inventory_2_outlined, size: 13, color: t.textTertiary),
                            const SizedBox(width: 4),
                            Text('BOXES HELD', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: t.textTertiary, letterSpacing: 0.5)),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${s.totalBoxesAssigned} Total',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: t.textPrimary),
                        ),
                        Text(
                          '${s.activeBoxesCount} Active • ${s.compromisedBoxesCount} Lost/Broken',
                          style: TextStyle(fontSize: 10.5, color: t.textTertiary),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            if (s.totalEstimatedCashLost > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFFDC2626).withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFDC2626).withValues(alpha: 0.2)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.money_off_rounded, size: 14, color: Color(0xFFDC2626)),
                      const SizedBox(width: 6),
                      Text(
                        'Estimated Cash Lost in Incidents: PKR ${fmt.format(s.totalEstimatedCashLost)}',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFFDC2626)),
                      ),
                    ],
                  ),
                ),
              ),

            // Expandable Box List
            if (_isExpanded) ...[
              const SizedBox(height: 12),
              Divider(height: 1, color: t.bgRule),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('BOXES ASSIGNED TO THIS PERSON (${s.boxes.length})', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w900, color: t.textTertiary, letterSpacing: 1.0)),
                    const SizedBox(height: 10),
                    ...s.boxes.map((box) {
                      final Color bColor;
                      final String bLabel;
                      if (box.isSnatched) {
                        bColor = const Color(0xFFDC2626);
                        bLabel = 'Snatched 🚨';
                      } else if (box.isStolen) {
                        bColor = const Color(0xFFEA580C);
                        bLabel = 'Stolen ⚠️';
                      } else if (box.isBroken) {
                        bColor = const Color(0xFFD97706);
                        bLabel = 'Broken 🔨';
                      } else if (box.isReplaced) {
                        bColor = const Color(0xFF7C3AED);
                        bLabel = 'Replaced 🔄';
                      } else if (!box.isActive) {
                        bColor = const Color(0xFF6B7280);
                        bLabel = 'Inactive';
                      } else {
                        bColor = const Color(0xFF047857);
                        bLabel = 'Active';
                      }

                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: t.bgCardAlt,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: t.bgRule),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: bColor.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                box.boxNumber,
                                style: GoogleFonts.dmMono(fontSize: 12, fontWeight: FontWeight.w800, color: bColor),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: bColor.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                bLabel,
                                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: bColor),
                              ),
                            ),
                            if (box.replacementForBoxId != null) ...[
                              const SizedBox(width: 6),
                              Text('Replaces ${box.replacementForBoxId}', style: TextStyle(fontSize: 10, color: t.textTertiary)),
                            ],
                            const Spacer(),
                            if (box.isCompromised && box.replacedByBoxId == null) ...[
                              ElevatedButton.icon(
                                onPressed: () => widget.onAssignReplacement(box),
                                icon: const Icon(Icons.sync_alt_rounded, size: 12),
                                label: const Text('Replace', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF7C3AED),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  visualDensity: VisualDensity.compact,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                ),
                              ),
                              const SizedBox(width: 6),
                            ] else if (box.isActive) ...[
                              OutlinedButton.icon(
                                onPressed: () => widget.onReportIncident(box),
                                icon: const Icon(Icons.report_problem_outlined, size: 12, color: Color(0xFFDC2626)),
                                label: const Text('Incident', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFFDC2626))),
                                style: OutlinedButton.styleFrom(
                                  side: BorderSide(color: const Color(0xFFDC2626).withValues(alpha: 0.3)),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                  visualDensity: VisualDensity.compact,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                ),
                              ),
                              const SizedBox(width: 6),
                              ElevatedButton(
                                onPressed: () => widget.onOpenBox(box),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF047857),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  visualDensity: VisualDensity.compact,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                ),
                                child: const Text('Open', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
                              ),
                              const SizedBox(width: 6),
                            ],
                            IconButton(
                              onPressed: () => widget.onShowDetail(box),
                              icon: Icon(Icons.visibility_outlined, size: 16, color: t.textSecondary),
                              tooltip: 'View Box Details',
                              visualDensity: VisualDensity.compact,
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ] else ...[
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    );
  }
}

