import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../models/donation_models.dart';
import '../../../theme/app_theme.dart';
import '../../../theme/role_theme_provider.dart';
import '../../../services/user_theme_service.dart';
import '../../../services/donations_local_storage.dart';
import '../donations_shared.dart';
import '../donors_registry.dart';
import '../global_audit_trail.dart';

class DashboardPremiumOverview extends StatelessWidget {
  final List<DonationRecord> currentDonations;
  final String branchName;
  final String branchId;
  final UserRole role;
  final VoidCallback onAddTap;
  final VoidCallback onExportTap;
  final VoidCallback onSummaryTap;
  final bool isAnalyticsActive;
  final VoidCallback? onImportTap;
  final VoidCallback? onSyncTap;
  final bool isSyncing;

  const DashboardPremiumOverview({
    super.key,
    required this.currentDonations,
    required this.branchName,
    required this.branchId,
    required this.role,
    required this.onAddTap,
    required this.onExportTap,
    required this.onSummaryTap,
    required this.isAnalyticsActive,
    this.onImportTap,
    this.onSyncTap,
    this.isSyncing = false,
  });

  @override
  Widget build(BuildContext context) {
    double total = 0, received = 0, pending = 0;
    double gmwfTotal = 0, jamiaTotal = 0, boxTotal = 0;
    double cashTotal = 0, bankTotal = 0;
    int receivedCount = 0;
    int pendingCount = 0;
    double topAmount = 0;
    String topDonor = '—';

    // Retrieve overall historical records stored permanently in local Hive
    final allLocal = DonationsLocalStorage.getAllDonations(branchId)
        .where((d) => d.syncStatus != 'deleted')
        .toList();

    // Use full local storage archive whenever available so cards display the overall total
    final computationPool = allLocal.length >= currentDonations.length ? allLocal : currentDonations;

    for (var d in computationPool) {
      final amt = d.amount > 0 ? d.amount : (d.probableAmount ?? 0.0);
      total += amt;
      if (amt > topAmount) {
        topAmount = amt;
        topDonor = d.donorName.isNotEmpty ? d.donorName : 'Anonymous';
      }

      final cat = d.categoryId.toLowerCase();
      if (cat.contains('box')) {
        boxTotal += amt;
      } else if (cat.contains('jamia')) {
        jamiaTotal += amt;
      } else {
        gmwfTotal += amt;
      }

      final method = d.paymentMethod.toLowerCase();
      if (method.contains('cash')) {
        cashTotal += amt;
      } else {
        bankTotal += amt;
      }

      if (d.status == DonationStatus.received) {
        received += amt;
        receivedCount++;
      } else {
        pending += amt;
        pendingCount++;
      }
    }

    final avgAmount = computationPool.isNotEmpty ? (total / computationPool.length).roundToDouble() : 0.0;
    final fmt = NumberFormat('#,##0');

    return LayoutBuilder(builder: (context, constraints) {
      final t = RoleThemeScope.dataOf(context);
      final isWide = constraints.maxWidth > 1000;
      final isMobile = constraints.maxWidth <= 650;
      final gridSpacing = isMobile ? 12.0 : 16.0;

      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Action Buttons (Hidden for Office Boy) ──
          if (!role.isOfficeBoy) ...[
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                if (onSyncTap != null)
                  _buildActionPill(
                    context: context,
                    t: t,
                    icon: Icons.sync_rounded,
                    label: isSyncing
                        ? 'Syncing...'
                        : (role.canSeeAllBranches ? 'Sync All (Permanent Local Save)' : 'Sync My Collections (Local Save)'),
                    color: const Color(0xFF0284C7),
                    isActive: isSyncing,
                    onTap: onSyncTap!,
                  ),
                _buildActionPill(
                  context: context,
                  t: t,
                  icon: Icons.people_alt_rounded,
                  label: 'Donors Registry',
                  color: const Color(0xFF6366F1),
                  onTap: () => showDialog(
                    context: context,
                    builder: (_) => DonorRegistryDialog(branchId: branchId, branchName: branchName),
                  ),
                ),
                _buildActionPill(
                  context: context,
                  t: t,
                  icon: Icons.file_download_rounded,
                  label: 'Export Excel',
                  color: const Color(0xFF10B981),
                  onTap: onExportTap,
                ),
                _buildActionPill(
                  context: context,
                  t: t,
                  icon: Icons.analytics_rounded,
                  label: 'Analytics Summary',
                  color: const Color(0xFF0EA5E9),
                  isActive: isAnalyticsActive,
                  onTap: onSummaryTap,
                ),
                if (role.canSeeAllBranches) ...[
                  _buildActionPill(
                    context: context,
                    t: t,
                    icon: Icons.history_rounded,
                    label: 'Global Audit Trail',
                    color: const Color(0xFFF59E0B),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => GlobalAuditTrailScreen(role: role)),
                    ),
                  ),
                ],
                if (onImportTap != null) ...[
                  _buildActionPill(
                    context: context,
                    t: t,
                    icon: Icons.file_upload_rounded,
                    label: 'Import Excel',
                    color: const Color(0xFF8B5CF6),
                    onTap: onImportTap!,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 18),
          ],

          // ── Top 4 KPI Summary Cards matching branches.dart ──
          Builder(builder: (context) {
            final card1 = _buildKpiCard(
              title: "Total Volume",
              mainCount: "PKR ${fmt.format(total)}",
              trendText: "${computationPool.length} recs",
              subtitle: allLocal.length > currentDonations.length ? "Overall total" : "All time",
              isPositiveTrend: true,
              badgeColor: const Color(0xFF6366F1),
              badgeIcon: Icons.account_balance_wallet_rounded,
              symbolIcon: Icons.payments_rounded,
              subItems: [
                {'label': 'GMWF', 'val': 'PKR ${fmt.format(gmwfTotal)}'},
                {'label': 'Jamia', 'val': 'PKR ${fmt.format(jamiaTotal)}'},
                {'label': 'Boxes', 'val': 'PKR ${fmt.format(boxTotal)}'},
              ],
              t: t,
              isMobile: isMobile,
            );
            final card2 = _buildKpiCard(
              title: "Received",
              mainCount: "PKR ${fmt.format(received)}",
              trendText: "$receivedCount verified",
              subtitle: "Verified collections",
              isPositiveTrend: true,
              badgeColor: const Color(0xFF10B981),
              badgeIcon: Icons.check_circle_rounded,
              symbolIcon: Icons.verified_rounded,
              subItems: [
                {'label': 'Cash', 'val': 'PKR ${fmt.format(cashTotal)}'},
                {'label': 'Bank/Online', 'val': 'PKR ${fmt.format(bankTotal)}'},
              ],
              t: t,
              isMobile: isMobile,
            );
            final card3 = _buildKpiCard(
              title: "Pending",
              mainCount: "PKR ${fmt.format(pending)}",
              trendText: "$pendingCount pending",
              subtitle: "Awaiting review",
              isPositiveTrend: pendingCount == 0,
              badgeColor: const Color(0xFFF59E0B),
              badgeIcon: Icons.hourglass_top_rounded,
              symbolIcon: Icons.pending_actions_rounded,
              subItems: [
                {'label': 'Pending', 'val': 'PKR ${fmt.format(pending)}'},
                {'label': 'Count', 'val': '$pendingCount recs'},
              ],
              t: t,
              isMobile: isMobile,
            );
            final card4 = _buildKpiCard(
              title: "Peak Record",
              mainCount: "PKR ${fmt.format(topAmount)}",
              trendText: computationPool.isNotEmpty ? "Highest" : "No records",
              subtitle: topDonor.isNotEmpty && topDonor != '—' ? topDonor : "Highest single",
              isPositiveTrend: true,
              badgeColor: const Color(0xFFD97706),
              badgeIcon: Icons.emoji_events_rounded,
              symbolIcon: Icons.auto_awesome_rounded,
              subItems: [
                {'label': 'Top Donor', 'val': topDonor.length > 12 ? '${topDonor.substring(0, 10)}...' : topDonor},
                {'label': 'Avg / Receipt', 'val': 'PKR ${fmt.format(avgAmount)}'},
              ],
              t: t,
              isMobile: isMobile,
            );

            if (isMobile) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(child: card1),
                      SizedBox(width: gridSpacing),
                      Expanded(child: card2),
                    ],
                  ),
                  SizedBox(height: gridSpacing),
                  Row(
                    children: [
                      Expanded(child: card3),
                      SizedBox(width: gridSpacing),
                      Expanded(child: card4),
                    ],
                  ),
                ],
              );
            } else if (isWide) {
              return Row(
                children: [
                  Expanded(child: card1),
                  const SizedBox(width: 16),
                  Expanded(child: card2),
                  const SizedBox(width: 16),
                  Expanded(child: card3),
                  const SizedBox(width: 16),
                  Expanded(child: card4),
                ],
              );
            } else {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(child: card1),
                      const SizedBox(width: 16),
                      Expanded(child: card2),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(child: card3),
                      const SizedBox(width: 16),
                      Expanded(child: card4),
                    ],
                  ),
                ],
              );
            }
          }),
        ],
      );
    });
  }

  Widget _buildKpiCard({
    required String title,
    required String mainCount,
    required String trendText,
    required bool isPositiveTrend,
    required Color badgeColor,
    required IconData badgeIcon,
    required IconData symbolIcon,
    required List<Map<String, String>> subItems,
    required RoleThemeData t,
    String? subtitle,
    bool isMobile = false,
  }) {
    final isDark = t.isDarkCanvas || UserThemeService.isDarkMode();

    if (isMobile) {
      final effectiveSubtitle = subtitle ?? (subItems.isNotEmpty ? subItems.first['label'] ?? '' : '');

      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: t.bgCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: t.bgRule.withValues(alpha: 0.8), width: 1),
          boxShadow: [
            BoxShadow(
              color: isDark ? Colors.black.withValues(alpha: 0.25) : badgeColor.withValues(alpha: 0.04),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Top Row: Icon on left, Pill badge on right
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        badgeColor.withValues(alpha: 0.18),
                        badgeColor.withValues(alpha: 0.06),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: badgeColor.withValues(alpha: 0.25), width: 1),
                  ),
                  child: Icon(badgeIcon, color: badgeColor, size: 17),
                ),
                if (trendText.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
                    decoration: BoxDecoration(
                      color: (isPositiveTrend ? const Color(0xFF10B981) : Colors.amber).withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isPositiveTrend ? Icons.arrow_upward_rounded : Icons.schedule_rounded,
                          size: 9.5,
                          color: isPositiveTrend ? const Color(0xFF10B981) : Colors.amber[800],
                        ),
                        const SizedBox(width: 2.5),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 70),
                          child: Text(
                            trendText,
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: isPositiveTrend ? const Color(0xFF10B981) : Colors.amber[800],
                            ),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),

            // Large Value
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                mainCount,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                  color: t.textPrimary,
                  letterSpacing: -0.4,
                ),
              ),
            ),
            const SizedBox(height: 3),

            // Label / Title
            Text(
              title,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: t.textSecondary,
                letterSpacing: 0.1,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 1.5),

            // Subtitle / context
            Text(
              effectiveSubtitle,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: t.textTertiary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.bgRule.withValues(alpha: 0.8), width: 1),
        boxShadow: [
          BoxShadow(
            color: isDark ? Colors.black.withValues(alpha: 0.25) : badgeColor.withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      badgeColor.withValues(alpha: 0.18),
                      badgeColor.withValues(alpha: 0.06),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: badgeColor.withValues(alpha: 0.25), width: 1),
                ),
                child: Icon(badgeIcon, color: badgeColor, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.textSecondary)),
                    const SizedBox(height: 3),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Flexible(
                          child: Text(
                            mainCount,
                            style: TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w900,
                              color: t.textPrimary,
                              letterSpacing: -0.5,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: isPositiveTrend ? const Color(0xFF10B981).withValues(alpha: 0.12) : Colors.amber.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isPositiveTrend ? Icons.arrow_upward_rounded : Icons.schedule_rounded,
                                size: 10,
                                color: isPositiveTrend ? const Color(0xFF10B981) : Colors.amber[800],
                              ),
                              const SizedBox(width: 2),
                              Text(
                                trendText,
                                style: TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w700,
                                  color: isPositiveTrend ? const Color(0xFF10B981) : Colors.amber[800],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      badgeColor.withValues(alpha: 0.15),
                      badgeColor.withValues(alpha: 0.05),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: badgeColor.withValues(alpha: 0.28), width: 0.8),
                ),
                child: Icon(symbolIcon, size: 16, color: badgeColor),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
            decoration: BoxDecoration(
              color: t.bg.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: t.bgRule.withValues(alpha: 0.5), width: 0.5),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: subItems.map((item) {
                return Expanded(
                  child: Column(
                    children: [
                      Text(
                        item['label'] ?? '',
                        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w500, color: t.textTertiary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          item['val'] ?? '0',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: t.textPrimary),
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionPill({
    required BuildContext context,
    required RoleThemeData t,
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
    bool isActive = false,
    bool isPrimary = false,
  }) {
    final bgColor = isPrimary
        ? color
        : isActive
            ? color.withValues(alpha: 0.15)
            : t.bgCard;
    final borderColor = isPrimary ? color : (isActive ? color : t.bgRule);
    final fgColor = isPrimary ? Colors.white : t.textPrimary;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: borderColor, width: 1),
          boxShadow: isPrimary
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: 0.25),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ]
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.02),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: isPrimary ? Colors.white : color),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: fgColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
