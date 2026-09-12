import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../models/donation_models.dart';
import '../../../theme/app_theme.dart';
import '../../../theme/role_theme_provider.dart';
import '../../../services/user_theme_service.dart';
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

    for (var d in currentDonations) {
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

    final avgAmount = currentDonations.isNotEmpty ? (total / currentDonations.length).roundToDouble() : 0.0;
    final fmt = NumberFormat('#,##0');

    return LayoutBuilder(builder: (context, constraints) {
      final t = RoleThemeScope.dataOf(context);
      final isWide = constraints.maxWidth > 1000;
      final isMedium = constraints.maxWidth > 650;
      final cardWidth = isWide
          ? (constraints.maxWidth - 48) / 4
          : (isMedium ? (constraints.maxWidth - 16) / 2 : constraints.maxWidth);

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Action Buttons (Hidden for Office Boy) ──
          if (!role.isOfficeBoy) ...[
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
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
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              SizedBox(
                width: cardWidth,
                child: _buildKpiCard(
                  title: "Total Volume",
                  mainCount: "PKR ${fmt.format(total)}",
                  trendText: "${currentDonations.length} records",
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
                ),
              ),
              SizedBox(
                width: cardWidth,
                child: _buildKpiCard(
                  title: "Received",
                  mainCount: "PKR ${fmt.format(received)}",
                  trendText: "$receivedCount verified",
                  isPositiveTrend: true,
                  badgeColor: const Color(0xFF10B981),
                  badgeIcon: Icons.check_circle_rounded,
                  symbolIcon: Icons.verified_rounded,
                  subItems: [
                    {'label': 'Cash', 'val': 'PKR ${fmt.format(cashTotal)}'},
                    {'label': 'Bank/Online', 'val': 'PKR ${fmt.format(bankTotal)}'},
                  ],
                  t: t,
                ),
              ),
              SizedBox(
                width: cardWidth,
                child: _buildKpiCard(
                  title: "Pending Verification",
                  mainCount: "PKR ${fmt.format(pending)}",
                  trendText: "$pendingCount pending",
                  isPositiveTrend: pendingCount == 0,
                  badgeColor: const Color(0xFFF59E0B),
                  badgeIcon: Icons.hourglass_top_rounded,
                  symbolIcon: Icons.pending_actions_rounded,
                  subItems: [
                    {'label': 'Pending', 'val': 'PKR ${fmt.format(pending)}'},
                    {'label': 'Count', 'val': '$pendingCount recs'},
                  ],
                  t: t,
                ),
              ),
              SizedBox(
                width: cardWidth,
                child: _buildKpiCard(
                  title: "Peak Contribution",
                  mainCount: "PKR ${fmt.format(topAmount)}",
                  trendText: currentDonations.isNotEmpty ? "Highest Single" : "No records",
                  isPositiveTrend: true,
                  badgeColor: const Color(0xFFD97706),
                  badgeIcon: Icons.emoji_events_rounded,
                  symbolIcon: Icons.auto_awesome_rounded,
                  subItems: [
                    {'label': 'Top Donor', 'val': topDonor.length > 12 ? '${topDonor.substring(0, 10)}...' : topDonor},
                    {'label': 'Avg / Receipt', 'val': 'PKR ${fmt.format(avgAmount)}'},
                  ],
                  t: t,
                ),
              ),
            ],
          ),
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
  }) {
    final isDark = t.isDarkCanvas || UserThemeService.isDarkMode();

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
                return Column(
                  children: [
                    Text(item['label'] ?? '', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w500, color: t.textTertiary)),
                    const SizedBox(height: 2),
                    Text(
                      item['val'] ?? '0',
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: t.textPrimary),
                    ),
                  ],
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
