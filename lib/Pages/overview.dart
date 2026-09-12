// lib/pages/overview.dart
// Unified sidebar-less dashboard for executive roles.

import 'package:flutter/material.dart';
import 'package:collection/collection.dart';
import 'package:intl/intl.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../theme/role_theme_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/dashboard_widgets.dart';
import '../widgets/scroll_reveal.dart';
import 'branches.dart';
import 'donations/donations_shared.dart' as don;
import 'donations/global_audit_trail.dart';
import '../services/donations_local_storage.dart';
import '../services/local_storage_service.dart';
import '../services/auth_service.dart';
import 'donations/donations_screen.dart' show DonDS;
import '../widgets/firestore_quota_monitor_widget.dart';

class OverviewScreen extends StatefulWidget {
  final String username;
  final bool isEmbedded;
  final String? initialBranchId;
  const OverviewScreen({
    super.key,
    this.username = 'User',
    this.isEmbedded = false,
    this.initialBranchId,
  });

  @override
  State<OverviewScreen> createState() => _OverviewScreenState();
}

class _OverviewScreenState extends State<OverviewScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _fadeCtrl;
  late Animation<double> _fadeAnim;
  String _activeTab = 'overall';
  int _refreshKey = 0; // incremented to force FutureBuilder re-fetch after cache clear
  bool _isRefreshing = false;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
        duration: const Duration(milliseconds: 600), vsync: this);
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _fadeCtrl.forward();

    // If an initial branch ID is provided (e.g., for Branch Managers/Supervisors),
    // we default the dashboard filter to that branch.
    if (widget.initialBranchId != null &&
        widget.initialBranchId != 'all' &&
        widget.initialBranchId != 'unknown') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        dashboardController.setBranch(widget.initialBranchId!);
      });
    }
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    super.dispose();
  }

  Future<void> _forceRefresh() async {
    if (_isRefreshing) return;
    setState(() => _isRefreshing = true);
    invalidateDashboardCache();
    await Future.delayed(const Duration(milliseconds: 50)); // let setState flush
    if (mounted) setState(() { _refreshKey++; _isRefreshing = false; });
  }

  Widget _buildTabSwitcher(RoleThemeData t, bool showDonationsTab) {
    final tabs = [
      {'id': 'overall', 'label': 'Overall Metrics', 'icon': Icons.grid_view_rounded},
      {'id': 'dispensary', 'label': 'Dispensary', 'icon': Icons.local_pharmacy_rounded},
      {'id': 'tokens', 'label': 'Tokens / Food', 'icon': Icons.restaurant_rounded},
      if (showDonationsTab)
        {'id': 'donations', 'label': 'Donations', 'icon': Icons.volunteer_activism_rounded},
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4.0),
        child: Row(
          children: tabs.map((tab) {
            final active = _activeTab == tab['id'];
            return GestureDetector(
              onTap: () {
                setState(() {
                  _activeTab = tab['id'] as String;
                });
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.only(right: 12),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  gradient: active ? t.accentGradient : null,
                  color: active ? null : t.bgCard,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: active ? t.accent.withValues(alpha: 0.3) : t.bgRule,
                    width: 1.2,
                  ),
                  boxShadow: active
                      ? [
                          BoxShadow(
                            color: t.accent.withValues(alpha: 0.2),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          )
                        ]
                      : [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.02),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          )
                        ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      tab['icon'] as IconData,
                      size: 15,
                      color: active ? Colors.white : t.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      tab['label'] as String,
                      style: TextStyle(
                        color: active ? Colors.white : t.textSecondary,
                        fontSize: 12,
                        fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    final role = RoleThemeScope.roleOf(context);

    final showDonationsTab = role.name.toLowerCase().contains('chairman') || 
                             role.name.toLowerCase().contains('hq') || 
                             role.name.toLowerCase().contains('admin');

    final roleName = role.name.toLowerCase();
    final isBranchManager = roleName == 'branch manager' || roleName == 'branch_manager' || roleName.contains('branch manager');

    final content = ValueListenableBuilder<DashboardFilter>(
      valueListenable: dashboardController,
      builder: (context, filter, child) {
        final branches = LocalStorageService.getLocalBranchesList();
        final filteredBranches = (isBranchManager ||
                (widget.initialBranchId != null &&
                    widget.initialBranchId != 'all' &&
                    widget.initialBranchId != 'unknown'))
            ? (() {
                final targetB = widget.initialBranchId ?? filter.branchId;
                if (targetB.isNotEmpty && targetB != 'all') {
                  return branches.where((b) => b['id'] == targetB).toList();
                }
                return branches;
              })()
            : branches;

        return SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: DS.s3, vertical: DS.s3),
            child: FadeTransition(
              opacity: _fadeAnim,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _OverviewHeader(
                    t: t,
                    username: widget.username,
                    roleName: role.name.toUpperCase(),
                  ),
                  const SizedBox(height: DS.s3),
                  GlobalFilterBar(controller: dashboardController, branches: branches),
                  const SizedBox(height: DS.s3),
                  _buildTabSwitcher(t, showDonationsTab),
                  const SizedBox(height: DS.s3),

                  if (_activeTab == 'overall') ...[
                    if (!isBranchManager) ...[
                      ExecutiveTopBranchFetcher(
                        t: t,
                        branches: filteredBranches,
                        onGoToBranch: (id) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => Branches(
                                initialBranchId: id,
                                isManager: false,
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: DS.s3),
                    ],
                    _buildKPIOverview(filteredBranches, filter),
                    const SizedBox(height: DS.s3),
                    const FirestoreQuotaMonitorWidget(),
                  ] else if (_activeTab == 'dispensary') ...[
                    _buildKPIOverview(filteredBranches, filter),
                  ] else if (_activeTab == 'tokens') ...[
                    _buildKPIOverview(filteredBranches, filter),
                  ] else if (_activeTab == 'donations' && showDonationsTab) ...[
                    _DonationIntelligenceSection(
                      t: t,
                      branches: filteredBranches,
                      filter: filter,
                    ),
                    const SizedBox(height: DS.s2),
                    _buildKPIOverview(filteredBranches, filter),
                  ],

                  if (!isBranchManager) ...[
                    const SizedBox(height: DS.s4),
                    DashSectionHeader(
                      title: _activeTab == 'overall'
                          ? 'Branch Performance Breakdown'
                          : _activeTab == 'dispensary'
                              ? 'Clinical Performance'
                              : _activeTab == 'tokens'
                                  ? 'Food Service Performance'
                                  : 'Donations Branch Breakdown',
                      subtitle: _activeTab == 'overall'
                          ? 'Detailed operational and financial metrics per branch'
                          : _activeTab == 'dispensary'
                              ? 'Branch-wise patient traffic and dispensary revenues'
                              : _activeTab == 'tokens'
                                  ? 'Dasterkhwaan meals issued vs served counts'
                                  : 'Masjid and general donations share by branch',
                    ),
                    const SizedBox(height: DS.s2),
                    ScrollReveal(
                      delay: const Duration(milliseconds: 280),
                      child: BranchPerformanceTable(
                        t: t,
                        branches: filteredBranches,
                        selectedTab: _activeTab,
                        onGoToBranch: (id) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => Branches(
                                initialBranchId: id,
                                isManager: false,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                  const SizedBox(height: DS.s4),
                ],
              ),
            ),
          ),
        );
      },
    );

    if (widget.isEmbedded) return content;


    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(
        backgroundColor: t.accent,
        elevation: 4,
        surfaceTintColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Colors.white),
        leading: Navigator.canPop(context)
            ? IconButton(
                icon: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 22),
                onPressed: () => Navigator.maybePop(context),
              )
            : null,
        title: Row(children: [
          Image.asset('assets/logo/gmwf-1.webp', height: 26, width: 26),
          const SizedBox(width: 10),
          Text(
            role.name.toUpperCase(),
            style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w800,
                letterSpacing: 3),
          ),
        ]),
        actions: [
          // Refresh button: clears the 5-minute stats cache and re-fetches
          _isRefreshing
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14),
                  child: SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  ),
                )
              : IconButton(
                  icon: const Icon(Icons.refresh_rounded, color: Colors.white, size: 22),
                  tooltip: 'Refresh dashboard',
                  onPressed: _forceRefresh,
                ),
        ],
        bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Divider(height: 1, color: t.bgRule)),
      ),
      body: content,
    );
  }

  Widget _buildKPIOverview(
      List<Map<String, dynamic>> branches, DashboardFilter filter) {
    final allIds = branches.map((b) => b['id'] as String).toList();
    final ids = (filter.branchId == 'all' || filter.branchId.isEmpty)
        ? allIds
        : allIds.where((id) => id == filter.branchId).toList();
    if (filter.timeRange == TimeRange.today && !filter.multiDayMedicineOnly && filter.patientType == null) {
      return StreamBuilder<BranchStats>(
        stream: streamAllBranchesStats(ids, filter: filter),
        builder: (context, snap) {
          if (!snap.hasData && snap.connectionState == ConnectionState.waiting) {
            return DashLoadingCard(t: RoleThemeScope.dataOf(context), height: 260);
          }
          final s = snap.data ?? const BranchStats();
          return _buildInnerKPI(context, s, branches.length);
        },
      );
    } else {
      // Use _refreshKey so tapping the refresh button forces a new Future despite cache.
      // Include filter.customRange bounds so switching between custom date ranges
      // (which share the same timeRange.name == 'custom') also triggers a refetch.
      final cKey = statsCacheKey(filter.branchId, filter);
      final cachedStats = statsCacheGet(cKey);
      return FutureBuilder<BranchStats>(
        key: ValueKey(
            '$_refreshKey|${filter.timeRange.name}|${filter.branchId}|${filter.customRange?.start}|${filter.customRange?.end}|${filter.patientType}|${filter.multiDayMedicineOnly}'),
        initialData: cachedStats,
        future: fetchAllBranchesStats(ids, filter: filter),
        builder: (context, snap) {
          if (!snap.hasData && cachedStats == null && snap.connectionState == ConnectionState.waiting) {
            return DashLoadingCard(t: RoleThemeScope.dataOf(context), height: 260);
          }
          final s = snap.data ?? cachedStats ?? const BranchStats();
          return _buildInnerKPI(context, s, branches.length);
        },
      );
    }
  }

  Widget _buildInnerKPI(BuildContext context, BranchStats s, int branchCount) {
    final t = RoleThemeScope.dataOf(context);
    if (_activeTab == 'overall') {
      return Column(
        children: [
          Row(
            children: [
              Expanded(
                child: ActionableKPICard(
                  label: 'Total Revenue',
                  value: fmtNum(s.totalRevenue),
                  prefix: 'PKR ',
                  icon: Icons.payments_rounded,
                  color: t.cardFillTokens,
                  isPrimary: true,
                  insight: s.totalRevenue > 0
                      ? 'Peak performance reached'
                      : '⚠️ No revenue today',
                ),
              ),
              const SizedBox(width: DS.s2),
              Expanded(
                child: ActionableKPICard(
                  label: 'Total Patients',
                  value: fmtNum(s.tokens),
                  icon: Icons.people_alt_rounded,
                  color: t.cardFillPrescriptions,
                  isPrimary: true,
                  insight: '$branchCount active branches',
                ),
              ),
            ],
          ),
          const SizedBox(height: DS.s2),
          Row(
            children: [
              Expanded(
                child: ActionableKPICard(
                  label: 'Tokens Served',
                  value: fmtNum(s.dasterkhwaanServed),
                  icon: Icons.restaurant_rounded,
                  color: t.cardFillDispensary,
                  insight: '${s.dasterkhwaan} tokens issued',
                ),
              ),
              const SizedBox(width: DS.s2),
              Expanded(
                child: ActionableKPICard(
                  label: 'Donations',
                  value: fmtNum(s.donations),
                  prefix: 'PKR ',
                  icon: Icons.volunteer_activism_rounded,
                  color: t.accent,
                  insight: 'Today\'s contributions',
                ),
              ),
            ],
          ),
          const SizedBox(height: DS.s2),
          PatientDistributionCard(t: t, s: s),
        ],
      );
    } else if (_activeTab == 'dispensary') {
      return Column(
        children: [
          Row(
            children: [
              Expanded(
                child: ActionableKPICard(
                  label: 'Dispensary Revenue',
                  value: fmtNum(s.dispensaryRevenue),
                  prefix: 'PKR ',
                  icon: Icons.payments_rounded,
                  color: t.cardFillDispensary,
                  insight: 'From medicine fee contributions',
                ),
              ),
              const SizedBox(width: DS.s2),
              Expanded(
                child: ActionableKPICard(
                  label: 'Patients Treated',
                  value: fmtNum(s.tokens),
                  icon: Icons.people_alt_rounded,
                  color: t.cardFillTokens,
                  insight: 'Total clinical visits',
                ),
              ),
            ],
          ),
          const SizedBox(height: DS.s2),
          Row(
            children: [
              Expanded(
                child: ActionableKPICard(
                  label: 'Zakat Patients',
                  value: fmtNum(s.zakat),
                  icon: Icons.assignment_ind_rounded,
                  color: t.zakat,
                  insight: 'Received free/subsidized care',
                ),
              ),
              const SizedBox(width: DS.s2),
              Expanded(
                child: ActionableKPICard(
                  label: 'Non-Zakat Patients',
                  value: fmtNum(s.nonZakat),
                  icon: Icons.badge_rounded,
                  color: t.nonZakat,
                  insight: 'Received standard operations',
                ),
              ),
            ],
          ),
          const SizedBox(height: DS.s2),
          PatientDistributionCard(t: t, s: s),
        ],
      );
    } else if (_activeTab == 'tokens') {
      return Column(
        children: [
          Row(
            children: [
              Expanded(
                child: ActionableKPICard(
                  label: 'Tokens Issued',
                  value: fmtNum(s.dasterkhwaan),
                  icon: Icons.tag_rounded,
                  color: t.cardFillTokens,
                  insight: 'Total issued today',
                ),
              ),
              const SizedBox(width: DS.s2),
              Expanded(
                child: ActionableKPICard(
                  label: 'Tokens Served',
                  value: fmtNum(s.dasterkhwaanServed),
                  icon: Icons.restaurant_rounded,
                  color: t.cardFillPrescriptions,
                  insight: 'Dasterkhwaan meals served',
                ),
              ),
            ],
          ),
          const SizedBox(height: DS.s2),
          Row(
            children: [
              Expanded(
                child: ActionableKPICard(
                  label: 'Pending Meals',
                  value: fmtNum(s.dasterkhwaanPending),
                  icon: Icons.hourglass_empty_rounded,
                  color: t.cardFillDispensary,
                  insight: 'Awaiting food service',
                ),
              ),
              const SizedBox(width: DS.s2),
              Expanded(
                child: ActionableKPICard(
                  label: 'Food Service Revenue',
                  value: fmtNum(s.dasterkhwaanRevenue),
                  prefix: 'PKR ',
                  icon: Icons.monetization_on_rounded,
                  color: t.accent,
                  insight: 'Token fee contributions',
                ),
              ),
            ],
          ),
        ],
      );
    } else {
      return ActionableKPICard(
        label: 'Total Donations',
        value: fmtNum(s.donations),
        prefix: 'PKR ',
        icon: Icons.volunteer_activism_rounded,
        color: t.accent,
        insight: 'Global donation portfolio',
      );
    }
  }
}

class _OverviewHeader extends StatelessWidget {
  final RoleThemeData t;
  final String username;
  final String roleName;
  const _OverviewHeader(
      {required this.t, required this.username, required this.roleName});

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Color.lerp(t.accent, Colors.black, 0.40)!,
            Color.lerp(t.accent, Colors.black, 0.72)!,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: t.accent.withValues(alpha: 0.7),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: t.accent.withValues(alpha: 0.15),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // Islamic Pattern in WHITE on the Right Side (assets/images/1.webp)
          Positioned(
            right: isMobile ? -55 : -80,
            top: -20,
            bottom: -20,
            width: isMobile ? 220 : 320,
            child: IgnorePointer(
              child: ShaderMask(
                shaderCallback: (rect) {
                  return const LinearGradient(
                    begin: Alignment.centerRight,
                    end: Alignment.centerLeft,
                    colors: [
                      Colors.black,
                      Colors.black87,
                      Colors.transparent,
                    ],
                    stops: [0.0, 0.65, 1.0],
                  ).createShader(rect);
                },
                blendMode: BlendMode.dstIn,
                child: Opacity(
                  opacity: 0.35,
                  child: Transform.rotate(
                    angle: -0.15,
                    child: Image.asset(
                      'assets/images/1.webp',
                      color: Colors.white,
                      colorBlendMode: BlendMode.srcIn,
                      fit: BoxFit.contain,
                      alignment: Alignment.centerRight,
                      errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: isMobile ? 20 : 28,
              vertical: isMobile ? 20 : 24,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Glowing Circle Avatar
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.25),
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        blurRadius: 8,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Image.asset(
                    'assets/logo/gmwf-1.webp',
                    height: isMobile ? 36 : 42,
                    width: isMobile ? 36 : 42,
                    fit: BoxFit.contain,
                  ),
                ),
                SizedBox(width: isMobile ? 16 : 20),
                // Text details
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.2),
                                width: 1,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.workspace_premium_rounded,
                                  color: Colors.white,
                                  size: 12,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  roleName,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Welcome Back,',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.65),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        username,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: isMobile ? 20 : 24,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.5,
                        ),
                      ),
                    ],
                  ),
                ),
                // Calendar Widget on Desktop
                if (!isMobile) ...[
                  const SizedBox(width: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.12),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.calendar_today_rounded,
                          color: Colors.white,
                          size: 16,
                        ),
                        const SizedBox(width: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              DateFormat('EEEE').format(DateTime.now()),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            Text(
                              DateFormat('d MMMM yyyy').format(DateTime.now()),
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.7),
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Donation Intelligence Section for HQ/Chairman ─────────────────────────────

class _DonationIntelligenceSection extends StatelessWidget {
  final RoleThemeData t;
  final List<Map<String, dynamic>> branches;
  final DashboardFilter filter;

  const _DonationIntelligenceSection({
    required this.t,
    required this.branches,
    required this.filter,
  });

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;
    // We fetch ALL donations from local storage (synced from FS)
    final allDonations = DonationsLocalStorage.getAllDonations('all');
    
    // Filter by date range if not 'today'
    final range = _resolveFilter(filter);
    final filtered = allDonations.where((d) {
      try {
        final dt = DateTime.parse(d.date);
        return !dt.isBefore(range.start) && !dt.isAfter(range.end.add(const Duration(hours: 23, minutes: 59)));
      } catch (_) { return false; }
    }).toList();

    // Aggregates
    double totalJamia = 0;
    double totalGmwf = 0;
    final Map<String, double> subCatTotals = {};
    final Map<String, double> branchTotals = {};
    final Map<String, double> donorTotals = {};
    final Map<String, String> donorNames = {};

    final seenReceipts = <String>{};
    for (var d in filtered) {
      if (d.syncStatus == 'deleted') continue;
      if (d.paymentMethod.toLowerCase().trim() == 'bank_deposit') continue;
      
      final cleanRcpt = don.cleanReceiptNumber(d.receiptNo);
      if (seenReceipts.contains(cleanRcpt)) {
        continue;
      }
      seenReceipts.add(cleanRcpt);

      final amt = (d.amount > 0 ? d.amount : d.probableAmount) ?? 0.0;
      if (d.categoryId == 'jamia') {
        totalJamia += amt;
      } else if (d.categoryId == 'gmwf') totalGmwf += amt;

      if (d.gmwfSubCategoryId != null) {
        subCatTotals[d.gmwfSubCategoryId!] = (subCatTotals[d.gmwfSubCategoryId!] ?? 0) + amt;
      }
      
      branchTotals[d.branchId] = (branchTotals[d.branchId] ?? 0) + amt;
      
      if (d.donorId.isNotEmpty) {
        donorTotals[d.donorId] = (donorTotals[d.donorId] ?? 0) + amt;
        donorNames[d.donorId] = d.donorName;
      }
    }

    final topDonors = donorTotals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    
    final sortedBranches = branchTotals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DashSectionHeader(
          title: 'Donation Intelligence',
          subtitle: 'HQ-level insights into global contribution trends',
          actions: [
            TextButton.icon(
              onPressed: () {
                final role = RoleThemeScope.roleOf(context);
                final userRole = don.UserRoleX.fromString(role.name);
                Navigator.push(context, MaterialPageRoute(builder: (_) => GlobalAuditTrailScreen(role: userRole)));
              },
              icon: const Icon(Icons.history_rounded, size: 16),
              label: const Text('Audit Trail', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              style: TextButton.styleFrom(
                foregroundColor: t.accent,
                backgroundColor: t.accentMuted,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.r1)),
              ),
            ),
          ],
        ),
        const SizedBox(height: DS.s2),
        
        // 1. Hero Summary Cards (responsive layout)
        if (isMobile) ...[
          _DonationStatCard(
            label: 'Jamia / Masjid',
            value: totalJamia.toInt(),
            color: don.DS.sapphire500,
            icon: Icons.mosque_rounded,
            t: t,
          ),
          const SizedBox(height: DS.s2),
          _DonationStatCard(
            label: 'GMWF General',
            value: totalGmwf.toInt(),
            color: don.DS.emerald500,
            icon: Icons.volunteer_activism_rounded,
            t: t,
          ),
        ] else
          Row(
            children: [
              Expanded(
                child: _DonationStatCard(
                  label: 'Jamia / Masjid',
                  value: totalJamia.toInt(),
                  color: don.DS.sapphire500,
                  icon: Icons.mosque_rounded,
                  t: t,
                ),
              ),
              const SizedBox(width: DS.s2),
              Expanded(
                child: _DonationStatCard(
                  label: 'GMWF General',
                  value: totalGmwf.toInt(),
                  color: don.DS.emerald500,
                  icon: Icons.volunteer_activism_rounded,
                  t: t,
                ),
              ),
            ],
          ),
        const SizedBox(height: DS.s3),

        // 2. Branch & Category Distribution
        LayoutBuilder(builder: (context, constraints) {
          final isWide = constraints.maxWidth > 700;
          final content = [
            _DistributionCard(
              title: 'Branch Performance',
              data: sortedBranches.take(5).map((e) {
                final bName = branches.firstWhereOrNull((b) => b['id'] == e.key)?['name'] ?? e.key.toUpperCase();
                return _DistItem(label: bName, value: e.value, color: don.DS.sapphire500);
              }).toList(),
              t: t,
            ),
            const SizedBox(width: DS.s2, height: DS.s2),
            _DistributionCard(
              title: 'Department Shares',
              data: subCatTotals.entries.map((e) {
                final sub = don.GmwfSubCategory.values.firstWhereOrNull((s) => s.name == e.key);
                return _DistItem(
                  label: sub?.label ?? e.key.toUpperCase(),
                  value: e.value,
                  color: sub?.color ?? don.DS.ink500,
                );
              }).toList(),
              t: t,
            ),
          ];
          
          if (isWide) {
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: content[0]),
            content[1],
            Expanded(child: content[2]),
          ]);
          }
          return Column(children: [content[0], content[1], content[2]]);
        }),
        
        const SizedBox(height: DS.s3),

        // 3. Top Donors List
        _TopDonorsCard(topDonors: topDonors.take(5).toList(), names: donorNames, t: t),
      ],
    );
  }

  DateTimeRange _resolveFilter(DashboardFilter filter) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (filter.timeRange) {
      case TimeRange.today:
        return DateTimeRange(start: today, end: today);
      case TimeRange.yesterday:
        final yest = today.subtract(const Duration(days: 1));
        return DateTimeRange(start: yest, end: yest);
      case TimeRange.week:
        return DateTimeRange(start: today.subtract(const Duration(days: 6)), end: today);
      case TimeRange.biweek:
        return DateTimeRange(start: today.subtract(const Duration(days: 13)), end: today);
      case TimeRange.month:
        return DateTimeRange(start: today.subtract(const Duration(days: 29)), end: today);
      case TimeRange.thisMonth:
        return DateTimeRange(start: DateTime(now.year, now.month, 1), end: today);
      case TimeRange.custom:
        return filter.customRange ?? DateTimeRange(start: today, end: today);
    }
  }
}

class _DonationStatCard extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  final IconData icon;
  final RoleThemeData t;

  const _DonationStatCard({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
    required this.t,
  });

  @override
  Widget build(BuildContext context) {
    final cleanLabel = label.toLowerCase();
    final LinearGradient gradient;
    final Color glowColor;
    final Color labelColor = Colors.white.withValues(alpha: 0.75);
    final Color valueColor = Colors.white;
    final Color prefixColor = Colors.white.withValues(alpha: 0.7);
    final Color iconBgColor = Colors.white.withValues(alpha: 0.15);
    final Color iconColor = Colors.white;

    if (cleanLabel.contains('jamia') || cleanLabel.contains('masjid')) {
      gradient = const LinearGradient(
        colors: [Color(0xFF2563EB), Color(0xFF1D4ED8)], // Sapphire
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );
      glowColor = const Color(0xFF1D4ED8).withValues(alpha: 0.35);
    } else {
      gradient = const LinearGradient(
        colors: [Color(0xFF0D9488), Color(0xFF0F766E)], // Emerald / Teal
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );
      glowColor = const Color(0xFF0F766E).withValues(alpha: 0.35);
    }

    return Container(
      decoration: BoxDecoration(
        gradient: gradient,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: glowColor,
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            right: -20,
            top: -20,
            child: Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.05),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: iconBgColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: iconColor, size: 24),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          color: labelColor,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 4),
                      AnimatedCount(
                        value: value,
                        prefix: 'PKR ',
                        style: TextStyle(
                          color: valueColor,
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                          fontFamily: 'DMMono',
                          letterSpacing: -0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DistItem {
  final String label;
  final double value;
  final Color color;
  _DistItem({required this.label, required this.value, required this.color});
}

class _DistributionCard extends StatelessWidget {
  final String title;
  final List<_DistItem> data;
  final RoleThemeData t;

  const _DistributionCard({required this.title, required this.data, required this.t});

  @override
  Widget build(BuildContext context) {
    final total = data.fold(0.0, (sum, item) => sum + item.value);
    
    return Container(
      padding: const EdgeInsets.all(DS.s3),
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(DS.r4),
        border: Border.all(color: t.bgRule),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(color: t.textPrimary, fontSize: 14, fontWeight: FontWeight.w800)),
          const SizedBox(height: DS.s3),
          if (total == 0)
            const Center(child: Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Text('No data for this period', style: TextStyle(color: DS.neutral, fontSize: 12)),
            ))
          else
            ...data.map((item) {
              final pct = (item.value / total);
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            item.label,
                            style: TextStyle(color: t.textSecondary, fontSize: 12, fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(fmtPKR(item.value.toInt()), style: const TextStyle(color: DS.neutral, fontSize: 11, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    AnimatedProgressBar(value: pct, color: item.color, height: 4),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }
}

class _TopDonorsCard extends StatelessWidget {
  final List<MapEntry<String, double>> topDonors;
  final Map<String, String> names;
  final RoleThemeData t;

  const _TopDonorsCard({required this.topDonors, required this.names, required this.t});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(DS.s3),
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(DS.r4),
        border: Border.all(color: t.bgRule),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.stars_rounded, color: don.DS.gold500, size: 20),
              const SizedBox(width: 8),
              Text('Top Contributors (Global)', style: TextStyle(color: t.textPrimary, fontSize: 14, fontWeight: FontWeight.w800)),
            ],
          ),
          const SizedBox(height: DS.s3),
          if (topDonors.isEmpty)
            const Center(child: Text('No donor data available', style: TextStyle(color: DS.neutral, fontSize: 12)))
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: topDonors.length,
              separatorBuilder: (_, _) => Divider(color: t.bgRule, height: 24),
              itemBuilder: (context, i) {
                final entry = topDonors[i];
                final name = names[entry.key] ?? 'Unknown Donor';
                final isMobile = MediaQuery.of(context).size.width < 600;
                return Row(
                  children: [
                    Container(
                      width: 36, height: 36,
                      decoration: BoxDecoration(color: t.accentMuted, shape: BoxShape.circle),
                      child: Center(child: Text('${i + 1}', style: TextStyle(color: t.accent, fontWeight: FontWeight.w900, fontSize: 13))),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            style: TextStyle(color: t.textPrimary, fontSize: isMobile ? 12 : 13, fontWeight: FontWeight.w700),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                          Text('Donor ID: ${entry.key}', style: TextStyle(color: t.textTertiary, fontSize: isMobile ? 9 : 10)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(fmtPKR(entry.value.toInt()), style: TextStyle(color: don.DS.emerald600, fontSize: isMobile ? 12 : 14, fontWeight: FontWeight.w900)),
                        Text(isMobile ? 'Total' : 'Total Contributions', style: const TextStyle(color: DS.neutral, fontSize: 9, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}