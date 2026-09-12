// lib/widgets/home_snapshot_widgets.dart
//
// Phase 1 widgets for the new "Home" snapshot (Today-only, no filter bar).
// Kept in its own file so global_modular_dashboard.dart and
// dashboard_widgets.dart don't need full rewrites — this only reads their
// public API (BranchStats, DS, fmtNum, fmtPKR, RoleThemeData).

import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lottie/lottie.dart';
import '../theme/app_theme.dart';
import '../theme/role_theme_provider.dart';
import '../models/module_registry.dart';
import '../services/home_dashboard_service.dart';
import 'dashboard_widgets.dart';
import '../pages/branches.dart';
import '../pages/office/finance_page.dart';
import '../pages/madrassa/madrassa_dashboard.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../services/local_storage_service.dart';
import '../pages/school/utils/school_local_storage.dart';
import '../pages/school/school_dashboard.dart';
import '../pages/users.dart';
import '../providers/branches_providers.dart';
import 'app_skeleton.dart';
import 'firestore_quota_monitor_widget.dart';

// ════════════════════════════════════════════════════════════════════════
// 1. Compact stat tile w/ "vs yesterday" delta
// ════════════════════════════════════════════════════════════════════════

class HomeStatTile extends StatefulWidget {
  final String label;
  final String value;
  final String? prefix;
  final IconData icon;
  final Color color;
  final double? deltaPct; // null = no yesterday data ("New today")
  final VoidCallback? onTap;

  const HomeStatTile({
    super.key,
    required this.label,
    required this.value,
    this.prefix,
    required this.icon,
    required this.color,
    this.deltaPct,
    this.onTap,
  });

  @override
  State<HomeStatTile> createState() => _HomeStatTileState();
}

class _HomeStatTileState extends State<HomeStatTile> with SingleTickerProviderStateMixin {
  bool _hov = false;
  late AnimationController _pressCtrl;
  late Animation<double> _pressScale;

  @override
  void initState() {
    super.initState();
    _pressCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 100));
    _pressScale = Tween<double>(begin: 1.0, end: 0.97).animate(
        CurvedAnimation(parent: _pressCtrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _pressCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    final hasDelta = widget.deltaPct != null;
    final isUp = hasDelta && widget.deltaPct! >= 0;
    final deltaColor = !hasDelta
        ? DS.neutral
        : (isUp ? const Color(0xFF16A34A) : const Color(0xFFDC2626));
    final isDark = t.isDarkCanvas;

    final Color categoryColor = widget.color;
    final categoryGradient = LinearGradient(
      colors: [categoryColor.withValues(alpha: 0.85), categoryColor],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );

    final tileContent = AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: categoryColor.withValues(alpha: _hov ? (isDark ? 0.35 : 0.22) : (isDark ? 0.12 : 0.06)),
            blurRadius: _hov ? 24 : 14,
            spreadRadius: _hov ? 1.5 : 0,
            offset: Offset(0, _hov ? 8 : 4),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.30 : 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? [
                        const Color(0xFF1E293B).withValues(alpha: _hov ? 0.88 : 0.68),
                        const Color(0xFF0F172A).withValues(alpha: _hov ? 0.82 : 0.60),
                      ]
                    : [
                        Colors.white.withValues(alpha: _hov ? 0.95 : 0.85),
                        Colors.white.withValues(alpha: _hov ? 0.85 : 0.70),
                      ],
              ),
              border: Border.all(
                color: _hov
                    ? categoryColor.withValues(alpha: isDark ? 0.65 : 0.50)
                    : (isDark
                        ? Colors.white.withValues(alpha: 0.14)
                        : Colors.white.withValues(alpha: 0.65)),
                width: 1.0,
              ),
            ),
            child: Stack(
              children: [
                // Localized ambient radial glow spot behind badge
                Positioned(
                  top: -24,
                  left: -24,
                  width: 90,
                  height: 90,
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            categoryColor.withValues(alpha: _hov ? (isDark ? 0.30 : 0.20) : (isDark ? 0.16 : 0.10)),
                            categoryColor.withValues(alpha: 0.0),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 11, 12, 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Floating squircle badge with gradient & soft shadow
                      AnimatedRotation(
                        turns: _hov ? 0.02 : 0,
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOutBack,
                        child: Container(
                          padding: const EdgeInsets.all(8.5),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(13),
                            gradient: categoryGradient,
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.35),
                              width: 0.9,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: categoryColor.withValues(alpha: _hov ? 0.40 : 0.25),
                                blurRadius: _hov ? 10 : 6,
                                offset: const Offset(0, 3),
                              ),
                              BoxShadow(
                                color: Colors.white.withValues(alpha: 0.20),
                                blurRadius: 1,
                                offset: const Offset(-1, -1),
                              ),
                            ],
                          ),
                          child: Icon(
                            widget.icon,
                            color: Colors.white,
                            size: 16,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),

                      // Text info
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              widget.label,
                              style: TextStyle(
                                color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.1,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.baseline,
                              textBaseline: TextBaseline.alphabetic,
                              children: [
                                if (widget.prefix != null)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 3),
                                    child: Text(
                                      widget.prefix!,
                                      style: TextStyle(
                                        color: categoryColor,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                Flexible(
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      widget.value,
                                      style: TextStyle(
                                        color: isDark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A),
                                        fontSize: 16.5,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: -0.5,
                                        height: 1.1,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 3),
                            // Delta pill badge
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5.5, vertical: 1.5),
                              decoration: BoxDecoration(
                                color: deltaColor.withValues(alpha: isDark ? 0.18 : 0.10),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: deltaColor.withValues(alpha: isDark ? 0.28 : 0.18),
                                  width: 0.6,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    !hasDelta
                                        ? Icons.fiber_new_rounded
                                        : (isUp ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded),
                                    size: 9.5,
                                    color: deltaColor,
                                  ),
                                  const SizedBox(width: 2.5),
                                  Text(
                                    !hasDelta ? 'New today' : '${widget.deltaPct!.abs().toStringAsFixed(0)}% vs yesterday',
                                    style: TextStyle(
                                      color: deltaColor,
                                      fontSize: 8.5,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: -0.1,
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
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (widget.onTap != null) {
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hov = true),
        onExit: (_) => setState(() {
          _hov = false;
          _pressCtrl.reverse();
        }),
        child: GestureDetector(
          onTapDown: (_) => _pressCtrl.forward(),
          onTapUp: (_) => _pressCtrl.reverse(),
          onTapCancel: () => _pressCtrl.reverse(),
          onTap: widget.onTap,
          child: ScaleTransition(
            scale: _pressScale,
            child: tileContent,
          ),
        ),
      );
    }
    return tileContent;
  }
}

class HomeStatTileRow extends StatelessWidget {
  final List<HomeStatTile> tiles;
  const HomeStatTileRow({super.key, required this.tiles});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      int cols = 6;
      double aspectRatio = 2.15;

      if (c.maxWidth < 600) {
        cols = 2;
        aspectRatio = 1.85;
      } else if (c.maxWidth < 1100) {
        cols = 6;
        aspectRatio = 1.95;
      } else {
        cols = 6;
        aspectRatio = 2.25;
      }

      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: tiles.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: aspectRatio,
        ),
        itemBuilder: (context, index) => tiles[index],
      );
    });
  }
}

// ════════════════════════════════════════════════════════════════════════
// 2. Patients-by-category donut — flat-row legend (mockup style)
//    Local copy of the donut painter since the original is private to
//    dashboard_widgets.dart (Dart privacy is per-file).
// ════════════════════════════════════════════════════════════════════════

class _FlatDonutPainter extends CustomPainter {
  final List<double> values;
  final List<Color> colors;
  final double progress;
  _FlatDonutPainter({required this.values, required this.colors, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final total = values.fold(0.0, (a, b) => a + b);
    final center = Offset(size.width / 2, size.height / 2);
    final radius = min(size.width, size.height) / 2 - 6;
    const strokeW = 34.0;
    const gap = 0.022;
    double startAngle = -pi / 2;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeW
      ..strokeCap = StrokeCap.butt;

    if (total == 0) {
      paint.color = Colors.grey.withValues(alpha: 0.18);
      canvas.drawArc(Rect.fromCircle(center: center, radius: radius), 0, 2 * pi, false, paint);
      return;
    }

    for (int i = 0; i < values.length; i++) {
      if (values[i] == 0) continue;
      final sweep = (values[i] / total) * 2 * pi * progress - gap;
      if (sweep <= 0) {
        startAngle += (values[i] / total) * 2 * pi * progress;
        continue;
      }
      paint.color = colors[i];
      canvas.drawArc(Rect.fromCircle(center: center, radius: radius), startAngle + gap / 2, sweep, false, paint);
      startAngle += (values[i] / total) * 2 * pi * progress;
    }
  }

  @override
  bool shouldRepaint(_FlatDonutPainter old) => old.progress != progress;
}

class _FlatAnimatedDonut extends StatefulWidget {
  final List<double> values;
  final List<Color> colors;
  final Widget center;
  final double size;
  const _FlatAnimatedDonut({required this.values, required this.colors, required this.center, this.size = 150});

  @override
  State<_FlatAnimatedDonut> createState() => _FlatAnimatedDonutState();
}

class _FlatAnimatedDonutState extends State<_FlatAnimatedDonut> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(duration: const Duration(milliseconds: 1200), vsync: this);
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _anim,
        builder: (_, __) => SizedBox(
          width: widget.size,
          height: widget.size,
          child: Stack(alignment: Alignment.center, children: [
            CustomPaint(
                size: Size(widget.size, widget.size),
                painter: _FlatDonutPainter(values: widget.values, colors: widget.colors, progress: _anim.value)),
            widget.center,
          ]),
        ),
      );
}

class HomePatientDonutCard extends StatelessWidget {
  final RoleThemeData t;
  final BranchStats s;
  const HomePatientDonutCard({super.key, required this.t, required this.s});

  @override
  Widget build(BuildContext context) {
    final total = s.tokens;
    final zPct = total > 0 ? (s.zakat / total * 100).round() : 0;
    final nPct = total > 0 ? (s.nonZakat / total * 100).round() : 0;
    final gPct = total > 0 ? (s.gmwf / total * 100).round() : 0;

    final values = total == 0 ? [0.0] : [s.zakat.toDouble(), s.nonZakat.toDouble(), s.gmwf.toDouble()];
    final colors = total == 0 
        ? [Colors.grey.shade300] 
        : [t.zakat, t.nonZakat, t.gmwf];

    return Container(
      padding: const EdgeInsets.all(DS.s2 + 4),
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(DS.r2),
        border: Border.all(color: t.bgRule),
        boxShadow: Neumorphic3DStyle.raisedShadows(isDark: t.isDarkCanvas, depth: 0.9),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Patients by Category',
            style: TextStyle(color: t.textPrimary, fontSize: 14, fontWeight: FontWeight.w700)),
        const SizedBox(height: DS.s2),
        LayoutBuilder(builder: (context, c) {
          final isWide = c.maxWidth >= 420;
          final donut = _FlatAnimatedDonut(
            size: isWide ? 150 : 130,
            values: values,
            colors: colors,
            center: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('$total', style: TextStyle(color: total == 0 ? t.textTertiary : t.textPrimary, fontSize: 24, fontWeight: FontWeight.w900)),
              const Text('patients', style: TextStyle(color: DS.neutral, fontSize: 11)),
            ]),
          );
          final legend = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _flatLegendRow(total == 0 ? Colors.grey.shade400 : t.zakat, 'Zakat', s.zakat, zPct),
            const SizedBox(height: 10),
            _flatLegendRow(total == 0 ? Colors.grey.shade400 : t.nonZakat, 'Non-Zakat', s.nonZakat, nPct),
            const SizedBox(height: 10),
            _flatLegendRow(total == 0 ? Colors.grey.shade400 : t.gmwf, 'GMWF', s.gmwf, gPct),
          ]);
          if (isWide) {
            return Row(children: [donut, const SizedBox(width: DS.s3), Expanded(child: legend)]);
          }
          return Column(children: [Center(child: donut), const SizedBox(height: DS.s2), legend]);
        }),
      ]),
    );
  }

  Widget _flatLegendRow(Color color, String label, int count, int pct) => Row(children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Expanded(child: Text(label, style: TextStyle(color: color == Colors.grey.shade400 ? Colors.grey.shade500 : const Color(0xFF374151), fontSize: 12, fontWeight: FontWeight.w600))),
        Text('$count', style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w800)),
        const SizedBox(width: 6),
        Text('$pct%', style: const TextStyle(color: DS.neutral, fontSize: 11)),
      ]);
}



class HomeBranchRow {
  final String id;
  final String name;
  final BranchStats today;
  final BranchStats yesterday;
  final int weeklyPatients;
  const HomeBranchRow({required this.id, required this.name, required this.today, required this.yesterday, this.weeklyPatients = 0});
}

class HomeBranchPerformanceTable extends StatelessWidget {
  final RoleThemeData t;
  final List<HomeBranchRow> rows; // pass pre-sorted
  final void Function(String branchId)? onTapBranch;

  const HomeBranchPerformanceTable({super.key, required this.t, required this.rows, this.onTapBranch});

  @override
  Widget build(BuildContext context) {
    final isDark = t.isDarkCanvas;

    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDark
                  ? [
                      const Color(0xFF1E293B).withValues(alpha: 0.85),
                      const Color(0xFF0F172A).withValues(alpha: 0.72),
                    ]
                  : [
                      Colors.white.withValues(alpha: 0.94),
                      Colors.white.withValues(alpha: 0.82),
                    ],
            ),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.14)
                  : Colors.white.withValues(alpha: 0.65),
              width: 1.0,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.04),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Dispensaries & Camps Performance Today',
                    style: TextStyle(
                      color: isDark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A),
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0EA5E9).withValues(alpha: isDark ? 0.20 : 0.10),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: const Color(0xFF0EA5E9).withValues(alpha: 0.3),
                        width: 0.8,
                      ),
                    ),
                    child: const Text(
                      'LIVE FEED',
                      style: TextStyle(
                        color: Color(0xFF0EA5E9),
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              // Table header pill
              Container(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.05)
                      : const Color(0xFFF1F5F9).withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Row(
                  children: [
                    Expanded(
                      flex: 4,
                      child: Text('Dispensary / Camp', style: TextStyle(color: Color(0xFF64748B), fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
                    ),
                    Expanded(
                      flex: 2,
                      child: Center(child: Text('Donations', style: TextStyle(color: Color(0xFF64748B), fontSize: 10.5, fontWeight: FontWeight.w700))),
                    ),
                    Expanded(
                      flex: 2,
                      child: Center(child: Text('Patients', style: TextStyle(color: Color(0xFF64748B), fontSize: 10.5, fontWeight: FontWeight.w700))),
                    ),
                    Expanded(
                      flex: 2,
                      child: Center(child: Text('Revenue', style: TextStyle(color: Color(0xFF64748B), fontSize: 10.5, fontWeight: FontWeight.w700))),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: rows.isEmpty
                    ? const Center(
                        child: Text(
                          'No dispensaries or camps to show',
                          style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                        ),
                      )
                    : SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        child: Column(
                          children: rows.asMap().entries.map((e) {
                            final i = e.key;
                            final row = e.value;
                            
                            final don = row.today.donations;
                            final yDon = row.yesterday.donations;
                            final double? donDelta = yDon == 0 ? null : ((don - yDon) / yDon) * 100;

                            final pats = row.today.zakat + row.today.nonZakat + row.today.gmwf;
                            final yPats = row.yesterday.zakat + row.yesterday.nonZakat + row.yesterday.gmwf;
                            final double? patsDelta = yPats == 0 ? null : ((pats - yPats) / yPats) * 100;

                            final rev = row.today.dispensaryRevenue;
                            final yRev = row.yesterday.dispensaryRevenue;
                            final double? revDelta = yRev == 0 ? null : ((rev - yRev) / yRev) * 100;

                            return _BranchPerformanceRow(
                              rank: i + 1,
                              name: row.name,
                              don: don,
                              donDelta: donDelta,
                              pats: pats,
                              patsDelta: patsDelta,
                              rev: rev,
                              revDelta: revDelta,
                              isDark: isDark,
                              onTap: onTapBranch != null ? () => onTapBranch!(row.id) : null,
                            );
                          }).toList(),
                        ),
                      ),
              ),
              const SizedBox(height: 6),
              // View all branches link
              Center(
                child: TextButton(
                  onPressed: () {
                    if (onTapBranch != null) onTapBranch!('all');
                  },
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'View all branches',
                        style: TextStyle(
                          color: t.accent,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.arrow_forward_rounded, color: t.accent, size: 13),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BranchPerformanceRow extends StatefulWidget {
  final int rank;
  final String name;
  final int don;
  final double? donDelta;
  final int pats;
  final double? patsDelta;
  final int rev;
  final double? revDelta;
  final bool isDark;
  final VoidCallback? onTap;

  const _BranchPerformanceRow({
    required this.rank,
    required this.name,
    required this.don,
    required this.donDelta,
    required this.pats,
    required this.patsDelta,
    required this.rev,
    required this.revDelta,
    required this.isDark,
    this.onTap,
  });

  @override
  State<_BranchPerformanceRow> createState() => _BranchPerformanceRowState();
}

class _BranchPerformanceRowState extends State<_BranchPerformanceRow> {
  bool _hov = false;

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;

    return MouseRegion(
      onEnter: (_) => setState(() => _hov = true),
      onExit: (_) => setState(() => _hov = false),
      cursor: widget.onTap != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          margin: const EdgeInsets.symmetric(vertical: 2.5),
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 8),
          decoration: BoxDecoration(
            color: _hov
                ? (isDark ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.04))
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              // Branch name with rank
              Expanded(
                flex: 4,
                child: Row(
                  children: [
                    _RankBadge(rank: widget.rank),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.name,
                        style: TextStyle(
                          color: isDark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              // Donations
              Expanded(
                flex: 2,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        fmtNum(widget.don),
                        style: TextStyle(
                          color: isDark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (widget.donDelta != null) _deltaIndicator(widget.donDelta!, isDark),
                    ],
                  ),
                ),
              ),
              // Patients
              Expanded(
                flex: 2,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        fmtNum(widget.pats),
                        style: TextStyle(
                          color: isDark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (widget.patsDelta != null) _deltaIndicator(widget.patsDelta!, isDark),
                    ],
                  ),
                ),
              ),
              // Revenue
              Expanded(
                flex: 2,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        fmtNum(widget.rev),
                        style: TextStyle(
                          color: isDark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (widget.revDelta != null) _deltaIndicator(widget.revDelta!, isDark),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _deltaIndicator(double delta, bool isDark) {
    final isUp = delta >= 0;
    final color = isUp ? const Color(0xFF10B981) : const Color(0xFFEF4444);
    return Container(
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.symmetric(horizontal: 4.5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.18 : 0.10),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(isUp ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 8.5, color: color),
          const SizedBox(width: 1.5),
          Text(
            '${delta.abs().toStringAsFixed(0)}%',
            style: TextStyle(color: color, fontSize: 8.5, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}

class _RankBadge extends StatelessWidget {
  final int rank;
  const _RankBadge({required this.rank});

  @override
  Widget build(BuildContext context) {
    if (rank == 1) {
      return Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            colors: [Color(0xFFFEF08A), Color(0xFFF59E0B), Color(0xFFD97706)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFF59E0B).withValues(alpha: 0.50),
              blurRadius: 7,
              offset: const Offset(0, 2),
            ),
          ],
          border: Border.all(color: Colors.white.withValues(alpha: 0.75), width: 1.2),
        ),
        child: const Center(
          child: Icon(
            Icons.emoji_events_rounded,
            color: Colors.white,
            size: 15,
          ),
        ),
      );
    }

    if (rank == 2) {
      return Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            colors: [Color(0xFFF8FAFC), Color(0xFF94A3B8), Color(0xFF64748B)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF94A3B8).withValues(alpha: 0.40),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
          border: Border.all(color: Colors.white.withValues(alpha: 0.75), width: 1.2),
        ),
        child: const Center(
          child: Icon(
            Icons.emoji_events_rounded,
            color: Colors.white,
            size: 14,
          ),
        ),
      );
    }

    if (rank == 3) {
      return Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            colors: [Color(0xFFFFEDD5), Color(0xFFD97706), Color(0xFF9A3412)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFD97706).withValues(alpha: 0.40),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
          border: Border.all(color: Colors.white.withValues(alpha: 0.75), width: 1.2),
        ),
        child: const Center(
          child: Icon(
            Icons.emoji_events_rounded,
            color: Colors.white,
            size: 13,
          ),
        ),
      );
    }

    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF64748B).withValues(alpha: 0.12),
        border: Border.all(
          color: const Color(0xFF64748B).withValues(alpha: 0.25),
          width: 0.8,
        ),
      ),
      child: Center(
        child: Text(
          '$rank',
          style: const TextStyle(
            color: Color(0xFF64748B),
            fontSize: 10.5,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class HomeBestBranchSpotlight extends StatefulWidget {
  final String branchName;
  final int revenue;
  final int donations;
  final int patients;
  final double? growthPct;
  final VoidCallback onTap;
  final RoleThemeData? t;
  final String title;

  const HomeBestBranchSpotlight({
    super.key,
    required this.branchName,
    required this.revenue,
    required this.donations,
    required this.patients,
    required this.growthPct,
    required this.onTap,
    this.t,
    this.title = 'Best Branch Today',
  });

  @override
  State<HomeBestBranchSpotlight> createState() => _HomeBestBranchSpotlightState();
}

class _HomeBestBranchSpotlightState extends State<HomeBestBranchSpotlight> {
  bool _hov = false;

  @override
  Widget build(BuildContext context) {
    final hasGrowth = widget.growthPct != null;
    final isUp = hasGrowth && widget.growthPct! >= 0;
    final isDark = widget.t?.isDarkCanvas ?? false;

    return MouseRegion(
      onEnter: (_) => setState(() => _hov = true),
      onExit: (_) => setState(() => _hov = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFF59E0B).withValues(
                  alpha: _hov
                      ? (isDark ? 0.35 : 0.22)
                      : (isDark ? 0.18 : 0.12),
                ),
                blurRadius: _hov ? 24 : 14,
                spreadRadius: _hov ? 1 : 0,
                offset: Offset(0, _hov ? 8 : 4),
              ),
              BoxShadow(
                color: isDark
                    ? Colors.black.withValues(alpha: 0.45)
                    : const Color(0xFF0F172A).withValues(alpha: 0.06),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: isDark
                        ? [
                            const Color(0xFF1E293B).withValues(alpha: 0.95),
                            const Color(0xFF0F172A).withValues(alpha: 0.98),
                          ]
                        : [
                            const Color(0xFFFFFBEB).withValues(alpha: 0.98),
                            Colors.white.withValues(alpha: 0.98),
                          ],
                  ),
                  border: Border.all(
                    color: _hov
                        ? const Color(0xFFF59E0B).withValues(alpha: 0.85)
                        : (isDark
                            ? const Color(0xFFF59E0B).withValues(alpha: 0.38)
                            : const Color(0xFFF59E0B).withValues(alpha: 0.50)),
                    width: _hov ? 1.5 : 1.2,
                  ),
                ),
                child: Stack(
                  children: [
                    // Ambient radial glow behind trophy
                    Positioned(
                      top: -15,
                      right: -15,
                      width: 110,
                      height: 110,
                      child: IgnorePointer(
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                const Color(0xFFF59E0B).withValues(alpha: isDark ? 0.30 : 0.18),
                                const Color(0xFFF59E0B).withValues(alpha: 0.0),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),

                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                        decoration: BoxDecoration(
                                          gradient: const LinearGradient(
                                            colors: [Color(0xFFF59E0B), Color(0xFFD97706)],
                                          ),
                                          borderRadius: BorderRadius.circular(12),
                                          boxShadow: [
                                            BoxShadow(
                                              color: const Color(0xFFF59E0B).withValues(alpha: 0.30),
                                              blurRadius: 6,
                                              offset: const Offset(0, 2),
                                            ),
                                          ],
                                        ),
                                        child: const Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.star_rounded, color: Colors.white, size: 11),
                                            SizedBox(width: 3),
                                            Text(
                                              '#1 TOP PERFORMER',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 9,
                                                fontWeight: FontWeight.w900,
                                                letterSpacing: 0.6,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    widget.branchName,
                                    style: TextStyle(
                                      color: isDark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A),
                                      fontSize: 16.5,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: -0.4,
                                      height: 1.2,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            // Floating 3D Golden trophy badge (themed glass pedestal)
                            AnimatedRotation(
                              turns: _hov ? 0.04 : 0,
                              duration: const Duration(milliseconds: 260),
                              curve: Curves.easeOutBack,
                              child: Container(
                                width: 52,
                                height: 52,
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? const Color(0xFF0F172A).withValues(alpha: 0.85)
                                      : const Color(0xFFFFFBEB),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: const Color(0xFFF59E0B).withValues(alpha: isDark ? 0.55 : 0.70),
                                    width: 1.5,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFFF59E0B).withValues(alpha: isDark ? 0.35 : 0.25),
                                      blurRadius: 10,
                                      offset: const Offset(0, 3),
                                    ),
                                  ],
                                ),
                                child: Lottie.asset(
                                  'assets/animations/Trophy.json',
                                  fit: BoxFit.contain,
                                  errorBuilder: (_, __, ___) => const Icon(
                                    Icons.emoji_events_rounded,
                                    color: Color(0xFFF59E0B),
                                    size: 28,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Container(
                          height: 1,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                Colors.transparent,
                                isDark ? Colors.white.withValues(alpha: 0.15) : const Color(0xFFF59E0B).withValues(alpha: 0.30),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        // 4 Modern metric cards in compact layout
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              _metricRow(Icons.payments_rounded, 'Revenue', fmtPKR(widget.revenue), isDark, valueColor: const Color(0xFF10B981)),
                              _metricRow(Icons.volunteer_activism_rounded, 'Donations', fmtPKR(widget.donations), isDark, valueColor: isDark ? const Color(0xFFFBBF24) : const Color(0xFFD97706)),
                              _metricRow(Icons.people_alt_rounded, 'Patients', widget.patients.toString(), isDark, valueColor: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7)),
                              _metricRow(
                                isUp ? Icons.trending_up_rounded : (hasGrowth ? Icons.trending_down_rounded : Icons.trending_up_rounded),
                                'Growth',
                                hasGrowth
                                    ? '${isUp ? '+' : ''}${widget.growthPct!.toStringAsFixed(0)}% vs yesterday'
                                    : (widget.revenue > 0 || widget.patients > 0 ? '+100% (Active Today)' : 'Steady (0%)'),
                                isDark,
                                valueColor: hasGrowth
                                    ? (isUp ? const Color(0xFF10B981) : const Color(0xFFEF4444))
                                    : (widget.revenue > 0 || widget.patients > 0 ? const Color(0xFF10B981) : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B))),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _metricRow(IconData icon, String label, String value, bool isDark, {Color? valueColor}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5.5),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F172A).withValues(alpha: 0.60) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFFDE68A).withValues(alpha: 0.85),
          width: 0.9,
        ),
        boxShadow: isDark
            ? []
            : [
                BoxShadow(
                  color: const Color(0xFF0F172A).withValues(alpha: 0.03),
                  blurRadius: 4,
                  offset: const Offset(0, 1.5),
                ),
              ],
      ),
      child: Row(
        children: [
          Icon(
            icon,
            color: isDark ? const Color(0xFFFBBF24) : const Color(0xFFD97706),
            size: 14,
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              color: valueColor ?? (isDark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A)),
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class HomePatientsByCategoryDonut extends StatelessWidget {
  final RoleThemeData t;
  final BranchStats s;

  const HomePatientsByCategoryDonut({super.key, required this.t, required this.s});

  @override
  Widget build(BuildContext context) {
    final int total = s.zakat + s.nonZakat + s.gmwf;
    final bool isDark = t.isDarkCanvas;
    
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDark
                  ? [
                      const Color(0xFF1E293B).withValues(alpha: 0.85),
                      const Color(0xFF0F172A).withValues(alpha: 0.72),
                    ]
                  : [
                      Colors.white.withValues(alpha: 0.98),
                      const Color(0xFFF8FAFC).withValues(alpha: 0.90),
                    ],
            ),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.14)
                  : const Color(0xFFE2E8F0).withValues(alpha: 0.85),
              width: 1.0,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.04),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Patients by Category',
                    style: TextStyle(
                      color: isDark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A),
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981).withValues(alpha: isDark ? 0.20 : 0.12),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: const Color(0xFF10B981).withValues(alpha: isDark ? 0.35 : 0.30),
                        width: 0.8,
                      ),
                    ),
                    child: Text(
                      '$total TOTAL',
                      style: const TextStyle(
                        color: Color(0xFF10B981),
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Expanded(
                child: total == 0
                    ? const Center(
                        child: Text('No patient data in this period', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12)),
                      )
                    : Row(
                        children: [
                          // Legend column with frosted pill cards
                          Expanded(
                            flex: 6,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _donutLegendItem('Zakat', s.zakat, total, const Color(0xFF10B981), Icons.assignment_ind_rounded, isDark),
                                _donutLegendItem('Non-Zakat', s.nonZakat, total, const Color(0xFF3B82F6), Icons.badge_rounded, isDark),
                                _donutLegendItem('GMWF', s.gmwf, total, const Color(0xFFF59E0B), Icons.child_care_rounded, isDark),
                              ],
                            ),
                          ),
                          const SizedBox(width: 14),
                          // Donut ring
                          Expanded(
                            flex: 5,
                            child: AspectRatio(
                              aspectRatio: 1.0,
                              child: CustomPaint(
                                painter: _DonutChartPainter(
                                  zakat: s.zakat.toDouble(),
                                  nonZakat: s.nonZakat.toDouble(),
                                  gmwf: s.gmwf.toDouble(),
                                  total: total.toDouble(),
                                  isDark: isDark,
                                ),
                                child: Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        total.toString(),
                                        style: TextStyle(
                                          color: isDark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A),
                                          fontSize: 22,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: -0.5,
                                          height: 1.0,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        'Total Patients',
                                        style: TextStyle(
                                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _donutLegendItem(String label, int val, int total, Color color, IconData icon, bool isDark) {
    final double pct = total == 0 ? 0.0 : (val / total) * 100;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: isDark ? color.withValues(alpha: 0.12) : Colors.white.withValues(alpha: 0.90),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: color.withValues(alpha: isDark ? 0.25 : 0.20),
          width: 0.8,
        ),
        boxShadow: isDark
            ? []
            : [
                BoxShadow(
                  color: color.withValues(alpha: 0.06),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(5.5),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [color, color.withValues(alpha: 0.80)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(7),
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.30),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Icon(icon, color: Colors.white, size: 12),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  val.toString(),
                  style: TextStyle(
                    color: isDark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A),
                    fontSize: 13.5,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: isDark ? 0.20 : 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '${pct.toStringAsFixed(1)}%',
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DonutChartPainter extends CustomPainter {
  final double zakat;
  final double nonZakat;
  final double gmwf;
  final double total;
  final bool isDark;

  _DonutChartPainter({
    required this.zakat,
    required this.nonZakat,
    required this.gmwf,
    required this.total,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = min(size.width, size.height) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius - 10);
    
    // Background track ring
    final paintTrack = Paint()
      ..color = isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE2E8F0)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(rect, 0, 2 * pi, false, paintTrack);

    if (total == 0) return;

    final paintZ = Paint()
      ..color = const Color(0xFF10B981)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round;

    final paintNz = Paint()
      ..color = const Color(0xFF3B82F6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round;

    final paintGm = Paint()
      ..color = const Color(0xFFF59E0B)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round;

    double startAngle = -pi / 2;

    if (zakat > 0) {
      final sweepZ = (zakat / total) * 2 * pi;
      canvas.drawArc(rect, startAngle + 0.05, (sweepZ - 0.1).clamp(0.01, 2 * pi), false, paintZ);
      startAngle += sweepZ;
    }

    if (nonZakat > 0) {
      final sweepNz = (nonZakat / total) * 2 * pi;
      canvas.drawArc(rect, startAngle + 0.05, (sweepNz - 0.1).clamp(0.01, 2 * pi), false, paintNz);
      startAngle += sweepNz;
    }

    if (gmwf > 0) {
      final sweepGm = (gmwf / total) * 2 * pi;
      canvas.drawArc(rect, startAngle + 0.05, (sweepGm - 0.1).clamp(0.01, 2 * pi), false, paintGm);
    }
  }

  @override
  bool shouldRepaint(_DonutChartPainter oldDelegate) =>
      oldDelegate.zakat != zakat ||
      oldDelegate.nonZakat != nonZakat ||
      oldDelegate.gmwf != gmwf ||
      oldDelegate.total != total ||
      oldDelegate.isDark != isDark;
}

class HomeRecentDonationsTable extends StatelessWidget {
  final List<RecentActivity> activities;
  final RoleThemeData t;

  const HomeRecentDonationsTable({super.key, required this.activities, required this.t});

  @override
  Widget build(BuildContext context) {
    final donations = activities.where((a) => a.type == 'donation').toList();
    final bool isDark = t.isDarkCanvas;

    return Container(
      padding: const EdgeInsets.all(DS.s2 + 4),
      decoration: BoxDecoration(
        color: isDark ? t.bgCard : Colors.white,
        borderRadius: BorderRadius.circular(DS.r2),
        border: Border.all(color: isDark ? t.bgRule : DS.border),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 14, offset: const Offset(0, 4)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Recent Donations',
                  style: TextStyle(color: isDark ? t.textPrimary : const Color(0xFF111827), fontSize: 13, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
              Text('View all', style: TextStyle(color: t.accent, fontSize: 10, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: DS.s2),
          // Table header
          Container(
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: isDark ? t.bgRule : DS.border, width: 1.0))),
            child: const Row(
              children: [
                Expanded(flex: 3, child: Text('Donor', style: TextStyle(color: DS.neutral, fontSize: 9, fontWeight: FontWeight.w700))),
                Expanded(flex: 2, child: Center(child: Text('Amount', style: TextStyle(color: DS.neutral, fontSize: 9, fontWeight: FontWeight.w700)))),
                Expanded(flex: 3, child: Text('Branch', style: TextStyle(color: DS.neutral, fontSize: 9, fontWeight: FontWeight.w700))),
                Expanded(flex: 2, child: Center(child: Text('Time', style: TextStyle(color: DS.neutral, fontSize: 9, fontWeight: FontWeight.w700)))),
              ],
            ),
          ),
          if (donations.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(child: Text('No recent donations', style: TextStyle(color: DS.neutral, fontSize: 11))),
            )
          else
            ...donations.take(4).map((a) {
              final match = RegExp(r'Received from ([^(]+)').firstMatch(a.subtitle);
              final donorName = match?.group(1)?.trim() ?? 'Walk-in Donor';
              final amt = a.amount ?? 0.0;
              final timeStr = DateFormat('hh:mm a').format(a.timestamp);

              return Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: isDark ? t.bgRule : DS.border, width: 0.5))),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: Text(donorName, style: TextStyle(color: isDark ? t.textPrimary : const Color(0xFF111827), fontSize: 11.5, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
                    ),
                    Expanded(
                      flex: 2,
                      child: Center(
                        child: Text('Rs ${fmtNum(amt.toInt())}', style: const TextStyle(color: Color(0xFF10B981), fontSize: 11, fontWeight: FontWeight.w800)),
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: Text(a.branchName, style: const TextStyle(color: DS.neutral, fontSize: 11, fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis),
                    ),
                    Expanded(
                      flex: 2,
                      child: Center(
                        child: Text(timeStr, style: const TextStyle(color: DS.neutral, fontSize: 10, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }
}

class HomeRecentPatientsTable extends StatelessWidget {
  final List<RecentActivity> activities;
  final RoleThemeData t;

  const HomeRecentPatientsTable({super.key, required this.activities, required this.t});

  @override
  Widget build(BuildContext context) {
    final tokens = activities.where((a) => a.type == 'token').toList();
    final bool isDark = t.isDarkCanvas;

    return Container(
      padding: const EdgeInsets.all(DS.s2 + 4),
      decoration: BoxDecoration(
        color: isDark ? t.bgCard : Colors.white,
        borderRadius: BorderRadius.circular(DS.r2),
        border: Border.all(color: isDark ? t.bgRule : DS.border),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 14, offset: const Offset(0, 4)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Recent Patients',
                  style: TextStyle(color: isDark ? t.textPrimary : const Color(0xFF111827), fontSize: 13, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
              Text('View all', style: TextStyle(color: t.accent, fontSize: 10, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: DS.s2),
          // Table header
          Container(
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: isDark ? t.bgRule : DS.border, width: 1.0))),
            child: const Row(
              children: [
                Expanded(flex: 3, child: Text('Patient ID', style: TextStyle(color: DS.neutral, fontSize: 9, fontWeight: FontWeight.w700))),
                Expanded(flex: 2, child: Center(child: Text('Category', style: TextStyle(color: DS.neutral, fontSize: 9, fontWeight: FontWeight.w700)))),
                Expanded(flex: 3, child: Text('Branch', style: TextStyle(color: DS.neutral, fontSize: 9, fontWeight: FontWeight.w700))),
                Expanded(flex: 2, child: Center(child: Text('Time', style: TextStyle(color: DS.neutral, fontSize: 9, fontWeight: FontWeight.w700)))),
              ],
            ),
          ),
          if (tokens.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(child: Text('No recent patients', style: TextStyle(color: DS.neutral, fontSize: 11))),
            )
          else
            ...tokens.take(4).map((a) {
              final match = RegExp(r'Patient: ([^\(]+)\s*\(([^)]+)\)').firstMatch(a.subtitle);
              final pName = match?.group(1)?.trim() ?? 'Patient';
              final category = match?.group(2)?.trim() ?? 'ZAKAT';
              
              final hash = a.id.hashCode.abs() % 10000;
              final pId = 'P-${hash.toString().padLeft(5, '0')}';
              
              final timeStr = DateFormat('hh:mm a').format(a.timestamp);

              Color badgeBg = isDark ? const Color(0xFF064E3B) : const Color(0xFFECFDF5);
              Color badgeText = isDark ? const Color(0xFF34D399) : const Color(0xFF047857);
              if (category.toLowerCase() == 'non-zakat') {
                badgeBg = isDark ? const Color(0xFF1E3A8A) : const Color(0xFFEFF6FF);
                badgeText = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
              } else if (category.toLowerCase() == 'gmwf') {
                badgeBg = isDark ? const Color(0xFF78350F) : const Color(0xFFFEF3C7);
                badgeText = isDark ? const Color(0xFFFBBF24) : const Color(0xFFD97706);
              }

              return Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: isDark ? t.bgRule : DS.border, width: 0.5))),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(pId, style: TextStyle(color: isDark ? t.textPrimary : const Color(0xFF111827), fontSize: 11, fontWeight: FontWeight.w700)),
                          Text(pName, style: const TextStyle(color: DS.neutral, fontSize: 9, fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: badgeBg,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            category,
                            style: TextStyle(color: badgeText, fontSize: 8.5, fontWeight: FontWeight.w800),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: Text(a.branchName, style: const TextStyle(color: DS.neutral, fontSize: 11, fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis),
                    ),
                    Expanded(
                      flex: 2,
                      child: Center(
                        child: Text(timeStr, style: const TextStyle(color: DS.neutral, fontSize: 10, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// 5. Patients Revenue Line Chart (CustomPainter)
// ════════════════════════════════════════════════════════════════════════

class HomeRevenueLineChart extends StatefulWidget {
  final List<HomeLineChartPoint> points;
  final RoleThemeData t;
  const HomeRevenueLineChart({super.key, required this.points, required this.t});

  @override
  State<HomeRevenueLineChart> createState() => _HomeRevenueLineChartState();
}

class _HomeRevenueLineChartState extends State<HomeRevenueLineChart> {
  int? hoveredIndex;

  @override
  Widget build(BuildContext context) {
    if (widget.points.isEmpty) {
      return Container(
        height: 250,
        decoration: BoxDecoration(
          color: widget.t.isDarkCanvas ? const Color(0xFF1E232D) : Colors.white,
          borderRadius: BorderRadius.circular(DS.r2),
          border: Border.all(color: DS.border),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.show_chart_rounded, size: 28, color: DS.neutral.withValues(alpha: 0.5)),
              const SizedBox(height: 8),
              const Text('Monthly Revenue & Token Trend', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: DS.neutral)),
              const SizedBox(height: 4),
              Text('Syncing trend data...', style: TextStyle(fontSize: 11, color: DS.neutral.withValues(alpha: 0.6))),
            ],
          ),
        ),
      );
    }

    final double maxMoney = widget.points.isEmpty 
        ? 100 
        : max(100.0, max(
            widget.points.map((p) => p.patientsRevenue.toDouble()).reduce(max),
            widget.points.map((p) => p.donations.toDouble()).reduce(max),
          )) * 1.15;
          
    final double maxTokens = widget.points.isEmpty
        ? 10
        : max(10.0, widget.points.map((p) => p.tokens.toDouble()).reduce(max)) * 1.15;

    final double maxEmployees = widget.points.isEmpty
        ? 10
        : max(10.0, widget.points.map((p) => p.employeesPresent.toDouble()).reduce(max)) * 1.15;

    final bool isDark = widget.t.isDarkCanvas;

    return Container(
      padding: const EdgeInsets.all(DS.s2 + 4),
      decoration: BoxDecoration(
        color: isDark ? widget.t.bgCard : Colors.white,
        borderRadius: BorderRadius.circular(DS.r2),
        border: Border.all(color: isDark ? widget.t.bgRule : DS.border),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 14, offset: const Offset(0, 4)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Monthly Progress Trends',
                        style: TextStyle(color: isDark ? widget.t.textPrimary : const Color(0xFF111827), fontSize: 14, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                    const SizedBox(height: 2),
                    const Text('Metrics for the last 5 months',
                        style: TextStyle(color: DS.neutral, fontSize: 11, fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
              if (hoveredIndex != null && hoveredIndex! < widget.points.length) ...[
                Builder(
                  builder: (context) {
                    final pt = widget.points[hoveredIndex!];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          DateFormat('MMM yyyy').format(pt.date),
                          style: TextStyle(color: isDark ? widget.t.textPrimary : const Color(0xFF111827), fontSize: 11, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            _hoverPill('Donations', fmtPKR(pt.donations), const Color(0xFF10B981)),
                            const SizedBox(width: 4),
                            _hoverPill('Patients Rev', fmtPKR(pt.patientsRevenue), widget.t.accent),
                            const SizedBox(width: 4),
                            _hoverPill('Tokens', pt.tokens.toString(), const Color(0xFF3B82F6)),
                            const SizedBox(width: 4),
                            _hoverPill('Staff', pt.employeesPresent.toString(), const Color(0xFF8B5CF6)),
                          ],
                        ),
                      ],
                    );
                  }
                ),
              ],
            ],
          ),
          const SizedBox(height: DS.s2),
          SizedBox(
            height: 180,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;

                return GestureDetector(
                  onPanUpdate: (details) {
                    final localPos = details.localPosition;
                    final dx = localPos.dx;
                    final stepX = width / (widget.points.length - 1);
                    int index = (dx / stepX).round().clamp(0, widget.points.length - 1);
                    if (hoveredIndex != index) {
                      setState(() {
                        hoveredIndex = index;
                      });
                    }
                  },
                  onPanEnd: (_) {
                    setState(() {
                      hoveredIndex = null;
                    });
                  },
                  onTapDown: (details) {
                    final localPos = details.localPosition;
                    final dx = localPos.dx;
                    final stepX = width / (widget.points.length - 1);
                    int index = (dx / stepX).round().clamp(0, widget.points.length - 1);
                    setState(() {
                      hoveredIndex = index;
                    });
                  },
                  child: CustomPaint(
                    size: Size(width, constraints.maxHeight),
                    painter: _MultiLineChartPainter(
                      points: widget.points,
                      accentColor: widget.t.accent,
                      maxMoney: maxMoney,
                      maxTokens: maxTokens,
                      maxEmployees: maxEmployees,
                      hoveredIndex: hoveredIndex,
                      isDark: isDark,
                      gridColor: isDark ? widget.t.bgRule : DS.border,
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _legendItem('Donations', const Color(0xFF10B981)),
                const SizedBox(width: 12),
                _legendItem('Patients Revenue', widget.t.accent),
                const SizedBox(width: 12),
                _legendItem('Tokens Issued', const Color(0xFF3B82F6)),
                const SizedBox(width: 12),
                _legendItem('Employees Present', const Color(0xFF8B5CF6)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _hoverPill(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.15)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 4, height: 4, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
          const SizedBox(width: 3),
          Text(value, style: TextStyle(color: color, fontSize: 8.5, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }

  Widget _legendItem(String label, Color color) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 3,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(color: DS.neutral, fontSize: 10, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class _MultiLineChartPainter extends CustomPainter {
  final List<HomeLineChartPoint> points;
  final Color accentColor;
  final double maxMoney;
  final double maxTokens;
  final double maxEmployees;
  final int? hoveredIndex;
  final bool isDark;
  final Color gridColor;

  _MultiLineChartPainter({
    required this.points,
    required this.accentColor,
    required this.maxMoney,
    required this.maxTokens,
    required this.maxEmployees,
    required this.isDark,
    required this.gridColor,
    this.hoveredIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final width = size.width;
    final chartHeight = size.height - 24;
    final len = points.length;
    final double stepX = width / (len - 1);

    double getX(int i) => i * stepX;
    
    double getYMoney(double val) {
      final ratio = val / maxMoney;
      return chartHeight - (ratio * chartHeight);
    }

    double getYTokens(double val) {
      final ratio = val / maxTokens;
      return chartHeight - (ratio * chartHeight);
    }

    double getYEmployees(double val) {
      final ratio = val / maxEmployees;
      return chartHeight - (ratio * chartHeight);
    }

    // 1. Draw Grid Lines
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 0.5;
    
    const int gridCount = 4;
    for (int i = 0; i <= gridCount; i++) {
      final y = chartHeight * i / gridCount;
      canvas.drawLine(Offset(0, y), Offset(width, y), gridPaint);
    }

    final donColor = const Color(0xFF10B981);
    final tokColor = const Color(0xFF3B82F6);
    final empColor = const Color(0xFF8B5CF6);

    // 2. Draw Lines (Donations, Patients Rev, Tokens, Employees)
    _drawLine(canvas, points.map((p) => p.donations.toDouble()).toList(), donColor, stepX, chartHeight, maxMoney);
    _drawLine(canvas, points.map((p) => p.patientsRevenue.toDouble()).toList(), accentColor, stepX, chartHeight, maxMoney);
    _drawLine(canvas, points.map((p) => p.tokens.toDouble()).toList(), tokColor, stepX, chartHeight, maxTokens);
    _drawLine(canvas, points.map((p) => p.employeesPresent.toDouble()).toList(), empColor, stepX, chartHeight, maxEmployees);

    // 3. Draw X-axis labels (Day names like Mon, Tue, Wed...)
    final textStyle = const TextStyle(
      color: DS.neutral,
      fontSize: 10,
      fontWeight: FontWeight.w600,
    );

    for (int i = 0; i < len; i++) {
      final x = getX(i);
      final weekLabel = DateFormat('d/M').format(points[i].date);
      
      final textSpan = TextSpan(text: weekLabel, style: textStyle);
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: ui.TextDirection.ltr,
      )..layout();

      textPainter.paint(
        canvas,
        Offset(x - (textPainter.width / 2), chartHeight + 8),
      );
    }

    // 4. Draw hover highlights
    if (hoveredIndex != null) {
      final hIdx = hoveredIndex!;
      final hX = getX(hIdx);

      // Draw vertical reference line
      final linePaintRef = Paint()
        ..color = DS.neutral.withValues(alpha: 0.25)
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke;
      canvas.drawLine(Offset(hX, 0), Offset(hX, chartHeight), linePaintRef);

      _drawHoverCircle(canvas, hX, getYMoney(points[hIdx].donations.toDouble()), donColor);
      _drawHoverCircle(canvas, hX, getYMoney(points[hIdx].patientsRevenue.toDouble()), accentColor);
      _drawHoverCircle(canvas, hX, getYTokens(points[hIdx].tokens.toDouble()), tokColor);
      _drawHoverCircle(canvas, hX, getYEmployees(points[hIdx].employeesPresent.toDouble()), empColor);
    }
  }

  void _drawLine(Canvas canvas, List<double> values, Color color, double stepX, double height, double maxLimit) {
    final path = Path();
    final fillPath = Path();

    double getY(double val) {
      final ratio = val / maxLimit;
      return height - (ratio * height);
    }

    path.moveTo(0, getY(values[0]));
    fillPath.moveTo(0, height);
    fillPath.lineTo(0, getY(values[0]));

    for (int i = 0; i < values.length - 1; i++) {
      final x1 = i * stepX;
      final y1 = getY(values[i]);
      final x2 = (i + 1) * stepX;
      final y2 = getY(values[i + 1]);
      final cx = (x1 + x2) / 2;

      path.cubicTo(cx, y1, cx, y2, x2, y2);
      fillPath.cubicTo(cx, y1, cx, y2, x2, y2);
    }

    fillPath.lineTo((values.length - 1) * stepX, height);
    fillPath.close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        colors: [color.withValues(alpha: 0.15), color.withValues(alpha: 0.0)],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(Rect.fromLTWH(0, 0, (values.length - 1) * stepX, height))
      ..style = PaintingStyle.fill;
    canvas.drawPath(fillPath, fillPaint);

    final linePaint = Paint()
      ..color = color
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(path, linePaint);
  }

  void _drawHoverCircle(Canvas canvas, double x, double y, Color color) {
    final circleOuter = Paint()..color = color.withValues(alpha: 0.25);
    canvas.drawCircle(Offset(x, y), 7.0, circleOuter);

    final circleInner = Paint()..color = color;
    canvas.drawCircle(Offset(x, y), 3.5, circleInner);
  }

  @override
  bool shouldRepaint(_MultiLineChartPainter oldDelegate) =>
      oldDelegate.hoveredIndex != hoveredIndex ||
      oldDelegate.maxMoney != maxMoney ||
      oldDelegate.maxTokens != maxTokens ||
      oldDelegate.maxEmployees != maxEmployees;
}

// ════════════════════════════════════════════════════════════════════════
// 6. Patients by Branch Horizontal Bar Chart
// ════════════════════════════════════════════════════════════════════════

class HomePatientsByBranchBarChart extends StatelessWidget {
  final RoleThemeData t;
  final List<HomeBranchRow> rows;
  const HomePatientsByBranchBarChart({super.key, required this.t, required this.rows});

  @override
  Widget build(BuildContext context) {
    // Consolidate camps into collective branch rows with normalized keys and clean names
    final Map<String, HomeBranchRow> branchMap = {};
    for (final r in rows) {
      final rawKey = r.id.toLowerCase().trim().replaceAll(' ', '_').replaceAll('-', '_');
      final isKarachi = rawKey.contains('karachi') || r.name.toLowerCase().contains('karachi');
      final isJalalpur = rawKey.contains('jalal') || r.name.toLowerCase().contains('jalal');
      final isGujrat = rawKey.contains('gujrat') || r.name.toLowerCase().contains('gujrat');
      final isSialkot = rawKey.contains('sialkot') || r.name.toLowerCase().contains('sialkot');
      final isRawalpindi = rawKey.contains('rawalpindi') || rawKey.contains('pindi') || r.name.toLowerCase().contains('rawalpindi');

      final String branchKey = isKarachi
          ? 'karachi'
          : (isJalalpur
              ? 'jalalpur_jattan'
              : (isGujrat
                  ? 'gujrat'
                  : (isSialkot
                      ? 'sialkot'
                      : (isRawalpindi ? 'rawalpindi' : rawKey))));
      final String branchName = isKarachi
          ? 'Karachi'
          : (isJalalpur
              ? 'Jalalpur Jattan'
              : (isGujrat
                  ? 'Gujrat'
                  : (isSialkot
                      ? 'Sialkot'
                      : (isRawalpindi ? 'Rawalpindi' : r.name))));

      if (!branchMap.containsKey(branchKey)) {
        branchMap[branchKey] = HomeBranchRow(
          id: branchKey,
          name: branchName,
          today: r.today,
          yesterday: r.yesterday,
          weeklyPatients: r.weeklyPatients,
        );
      } else {
        final existing = branchMap[branchKey]!;
        branchMap[branchKey] = HomeBranchRow(
          id: branchKey,
          name: branchName,
          today: combineBranchStats([existing.today, r.today]),
          yesterday: combineBranchStats([existing.yesterday, r.yesterday]),
          weeklyPatients: existing.weeklyPatients + r.weeklyPatients,
        );
      }
    }

    final sortedRows = branchMap.values.toList()
      ..sort((a, b) => b.today.tokens.compareTo(a.today.tokens));

    final maxTokens = sortedRows.isEmpty
        ? 1
        : max(1, sortedRows.map((r) => r.today.tokens).reduce(max));
    final bool isDark = t.isDarkCanvas;

    return Container(
      padding: const EdgeInsets.all(DS.s2 + 4),
      decoration: BoxDecoration(
        color: isDark ? t.bgCard : Colors.white,
        borderRadius: BorderRadius.circular(DS.r2),
        border: Border.all(color: isDark ? t.bgRule : DS.border),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 14, offset: const Offset(0, 4)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Patients by Branch (Last 7 Days)',
              style: TextStyle(color: isDark ? t.textPrimary : const Color(0xFF111827), fontSize: 14, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
          const SizedBox(height: DS.s2),
          if (sortedRows.isEmpty)
            const Expanded(
              child: Center(
                child: Text('No patient data today', style: TextStyle(color: DS.neutral, fontSize: 12)),
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                physics: const NeverScrollableScrollPhysics(),
                itemCount: min(5, sortedRows.length),
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  final row = sortedRows[i];
                    final val = row.weeklyPatients > 0
                      ? row.weeklyPatients
                      : row.today.tokens;
                  final double pct = val / maxTokens;
                  
                  return Row(
                    children: [
                      // Branch name
                      SizedBox(
                        width: 110,
                        child: Text(
                          row.name,
                          style: TextStyle(color: isDark ? t.textSecondary : const Color(0xFF4B5563), fontSize: 11, fontWeight: FontWeight.w700),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Bar
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            return Stack(
                              children: [
                                Container(
                                  height: 10,
                                  decoration: BoxDecoration(
                                    color: isDark ? t.bg : const Color(0xFFF3F4F6),
                                    borderRadius: BorderRadius.circular(5),
                                  ),
                                ),
                                FractionallySizedBox(
                                  alignment: Alignment.centerLeft,
                                  widthFactor: pct.clamp(0.02, 1.0),
                                  child: Container(
                                    height: 10,
                                    decoration: BoxDecoration(
                                      gradient: const LinearGradient(
                                        colors: [Color(0xFF0F766E), Color(0xFF0D9488)],
                                      ),
                                      borderRadius: BorderRadius.circular(5),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          }
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Value
                      SizedBox(
                        width: 24,
                        child: Text(
                          val.toString(),
                          style: TextStyle(color: isDark ? t.textPrimary : const Color(0xFF111827), fontSize: 12, fontWeight: FontWeight.w900),
                          textAlign: TextAlign.right,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// 7. Recent Live Activity Feed
// ════════════════════════════════════════════════════════════════════════

class HomeRecentActivityFeed extends StatelessWidget {
  final List<RecentActivity> activities;
  final RoleThemeData t;
  final List<AppModule> availableModules;
  final void Function(AppModule) onOpenModule;

  const HomeRecentActivityFeed({
    super.key,
    required this.activities,
    required this.t,
    required this.availableModules,
    required this.onOpenModule,
  });

  @override
  Widget build(BuildContext context) {
    final bool isDark = t.isDarkCanvas;

    return Container(
      padding: const EdgeInsets.all(DS.s2 + 4),
      decoration: BoxDecoration(
        color: isDark ? t.bgCard : Colors.white,
        borderRadius: BorderRadius.circular(DS.r2),
        border: Border.all(color: isDark ? t.bgRule : DS.border),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 14, offset: const Offset(0, 4)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Recent Activity',
                  style: TextStyle(color: isDark ? t.textPrimary : const Color(0xFF111827), fontSize: 14, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
              InkWell(
                onTap: () {
                  final reportsModule = availableModules.firstWhere(
                    (m) => m.id == 'branches',
                    orElse: () => availableModules.first,
                  );
                  onOpenModule(reportsModule);
                },
                child: Text('View all', style: TextStyle(color: t.accent, fontSize: 11, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: DS.s2),
          if (activities.isEmpty)
            const Expanded(
              child: Center(
                child: Text('No recent activity records', style: TextStyle(color: DS.neutral, fontSize: 12)),
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                physics: const NeverScrollableScrollPhysics(),
                itemCount: min(4, activities.length),
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final act = activities[i];
                  final isDon = act.type == 'donation';
                  final isToken = act.type == 'token';
                  
                  // Configure color and icons to match the mockup
                  Color iconColor = const Color(0xFF3B82F6); // Blue for Token/Default
                  IconData iconData = Icons.confirmation_number_rounded;
                  
                  if (isDon) {
                    iconColor = const Color(0xFF10B981); // Green for Donations
                    iconData = Icons.volunteer_activism_rounded;
                  } else if (act.type == 'reception' || act.title.contains('Register') || act.title.contains('Patient')) {
                    iconColor = const Color(0xFF8B5CF6); // Purple for Patient Register
                    iconData = Icons.person_add_rounded;
                  } else if (act.type == 'revenue' || act.title.contains('Revenue') || act.title.contains('Record')) {
                    iconColor = const Color(0xFFF59E0B); // Orange for Revenue
                    iconData = Icons.payments_rounded;
                  }

                  return InkWell(
                    onTap: () {
                      final targetModuleId = isDon ? 'donations' : (isToken ? 'token_generation' : 'branches');
                      final module = availableModules.firstWhere(
                        (m) => m.id == targetModuleId,
                        orElse: () => availableModules.firstWhere(
                          (m) => m.id == 'branches',
                          orElse: () => availableModules.first,
                        ),
                      );
                      onOpenModule(module);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: iconColor.withValues(alpha: 0.1),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              iconData,
                              color: iconColor,
                              size: 14,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  act.title,
                                  style: TextStyle(color: isDark ? t.textPrimary : const Color(0xFF111827), fontSize: 11.5, fontWeight: FontWeight.w700),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 1),
                                Text(
                                  act.subtitle,
                                  style: const TextStyle(color: DS.neutral, fontSize: 10, fontWeight: FontWeight.w500),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            DateFormat('hh:mm a').format(act.timestamp),
                            style: const TextStyle(color: DS.neutral, fontSize: 9, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

}

// ════════════════════════════════════════════════════════════════════════
// 8. Quick Actions Row
// ════════════════════════════════════════════════════════════════════════

class QuickActionsRow extends StatelessWidget {
  final List<AppModule> availableModules;
  final RoleThemeData t;
  final void Function(AppModule) onOpenModule;

  const QuickActionsRow({
    super.key,
    required this.availableModules,
    required this.t,
    required this.onOpenModule,
  });

  @override
  Widget build(BuildContext context) {
    final List<Map<String, dynamic>> targetActions = [
      {'id': 'branches', 'label': 'Branches', 'icon': Icons.store_outlined, 'color': const Color(0xFF0D9488)},
      {'id': 'employees', 'label': 'Staff Attendance', 'icon': Icons.badge_outlined, 'color': const Color(0xFF6366F1)},
      {'id': 'madrassa_attendance', 'label': 'Madrassa Attend.', 'icon': Icons.how_to_reg_rounded, 'color': const Color(0xFFEC4899)},
      {'id': 'madrassa_students', 'label': 'Madrassa Students', 'icon': Icons.groups_rounded, 'color': const Color(0xFF14B8A6)},
      {'id': 'school_attendance', 'label': 'School Students', 'icon': Icons.school_rounded, 'color': const Color(0xFF10B981)},
      {'id': 'school_teacher_attendance', 'label': 'School Faculty', 'icon': Icons.co_present_rounded, 'color': const Color(0xFF8B5CF6)},
      {'id': 'office_boy', 'label': 'Food Tokens', 'icon': Icons.room_service_rounded, 'color': const Color(0xFFF59E0B)},
      {'id': 'dasterkhwaan_inventory', 'label': 'Dasterkhwaan', 'icon': Icons.inventory_2_outlined, 'color': const Color(0xFFD97706)},
      {'id': 'inventory', 'label': 'Med Inventory', 'icon': Icons.medication_liquid_rounded, 'color': const Color(0xFF0284C7)},
      {'id': 'finance', 'label': 'Finance & HR', 'icon': Icons.monetization_on_rounded, 'color': const Color(0xFFEF4444)},
      {'id': 'donations', 'label': 'Add Donation', 'icon': Icons.volunteer_activism_rounded, 'color': const Color(0xFF059669)},
      {'id': 'patients_registration', 'label': 'Add Patient', 'icon': Icons.person_add_rounded, 'color': const Color(0xFF7C3AED)},
    ];

    final activeActions = targetActions.where((action) {
      if (action['id'] == 'employees') {
        return availableModules.any((m) => m.id == 'employees' || m.id == 'finance');
      }
      if (action['id'] == 'madrassa_attendance' || action['id'] == 'madrassa_students' || action['id'] == 'add_student' || action['id'] == 'madrassa_report') {
        return availableModules.any((m) => m.id == 'madrassa');
      }
      if (action['id'] == 'school_attendance' || action['id'] == 'school_teacher_attendance' || action['id'] == 'school') {
        return availableModules.any((m) => m.id == 'school' || m.id == 'school_attendance' || m.id == 'school_teacher_attendance' || m.id == 'school_module');
      }
      return availableModules.any((m) => m.id == action['id'] || (action['id'] == 'patients_registration' && m.id == 'patient_register_standalone'));
    }).toList();

    final bool isDark = t.isDarkCanvas;

    return Container(
      padding: const EdgeInsets.all(DS.s2),
      decoration: BoxDecoration(
        color: isDark ? t.bgCard : Colors.white,
        borderRadius: BorderRadius.circular(DS.r2),
        border: Border.all(color: isDark ? t.bgRule : DS.border),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 14, offset: const Offset(0, 4)),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final crossAxisCount = (w / 95).floor().clamp(2, 6);
          final rowCount = (activeActions.length / crossAxisCount).ceil();
          final availableHeight = constraints.maxHeight - 38;
          final calcExtent = (rowCount > 0 && availableHeight > 0)
              ? ((availableHeight - (rowCount - 1) * 8) / rowCount).clamp(62.0, 95.0)
              : 72.0;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Quick Actions',
                  style: TextStyle(color: isDark ? t.textPrimary : const Color(0xFF111827), fontSize: 15, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
              const SizedBox(height: DS.s2),
              Expanded(
                child: GridView.builder(
                  physics: const BouncingScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossAxisCount,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    mainAxisExtent: calcExtent,
                  ),
                  itemCount: activeActions.length,
                  itemBuilder: (context, index) {
                    final action = activeActions[index];
                    final mainModuleId = (action['id'] == 'employees')
                        ? 'employees'
                        : ((action['id'] == 'madrassa_attendance' || action['id'] == 'madrassa_students' || action['id'] == 'add_student' || action['id'] == 'madrassa_report')
                            ? 'madrassa'
                            : ((action['id'] == 'school_attendance' || action['id'] == 'school_teacher_attendance' || action['id'] == 'school')
                                ? 'school_module'
                                : action['id']));
                    final baseModule = availableModules.firstWhere(
                      (m) => m.id == mainModuleId || (mainModuleId == 'patients_registration' && m.id == 'patient_register_standalone') || (mainModuleId == 'school_module' && (m.id == 'school_attendance' || m.id == 'school_teacher_attendance' || m.id == 'school_module')),
                      orElse: () => availableModules.firstWhere((m) => m.id == mainModuleId, orElse: () => availableModules.first),
                    );
                    
                    // Construct custom copy of the module with modified builder
                    var module = baseModule;
                    if (action['id'] == 'employees') {
                      module = baseModule.copyWith(
                        title: 'Employee Management',
                        builder: (context, data) => EmployeeManagementPage(
                          branchId: data['branchId'] ?? 'all',
                          isAdmin: true,
                        ),
                      );
                    } else if (action['id'] == 'madrassa_students') {
                      module = baseModule.copyWith(
                        title: 'Madrassa Students',
                        builder: (context, data) {
                          final branchId = data['branchId'] ?? 'unknown';
                          final username = data['name'] ?? data['username'] ?? 'User';
                          final role = (data['role'] as String? ?? 'madrassa admin').toLowerCase();
                          final isAdmin = role.contains('admin') || role.contains('chairman') || role.contains('ceo') || role.contains('hq');
                          return MadrassaDashboard(
                            branchId: branchId,
                            username: username,
                            role: role,
                            isAdmin: isAdmin,
                            initialIndex: isAdmin ? 2 : 1,
                          );
                        },
                      );
                    } else if (action['id'] == 'madrassa_attendance') {
                      module = baseModule.copyWith(
                        title: 'Madrassa Attendance',
                        builder: (context, data) {
                          final branchId = data['branchId'] ?? 'unknown';
                          final username = data['name'] ?? data['username'] ?? 'User';
                          final role = (data['role'] as String? ?? 'madrassa admin').toLowerCase();
                          final isAdmin = role.contains('admin') || role.contains('chairman') || role.contains('ceo') || role.contains('hq');
                          return MadrassaDashboard(
                            branchId: branchId,
                            username: username,
                            role: role,
                            isAdmin: isAdmin,
                            initialIndex: isAdmin ? 1 : 0,
                          );
                        },
                      );
                    } else if (action['id'] == 'school_attendance') {
                      module = baseModule.copyWith(
                        title: 'School Student Attendance',
                        builder: (context, data) => SchoolDashboard(
                          branchId: data['branchId'] ?? 'all',
                          username: data['name'] ?? data['username'] ?? 'User',
                          role: data['role'] ?? 'School Admin',
                          initialTabIndex: 1,
                        ),
                      );
                    } else if (action['id'] == 'school_teacher_attendance') {
                      module = baseModule.copyWith(
                        title: 'School Faculty Attendance',
                        builder: (context, data) => SchoolDashboard(
                          branchId: data['branchId'] ?? 'all',
                          username: data['name'] ?? data['username'] ?? 'User',
                          role: data['role'] ?? 'School Admin',
                          initialTabIndex: 2,
                        ),
                      );
                    }
                    
                    final color = action['color'] as Color;

                    return InkWell(
                      onTap: () => onOpenModule(module),
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                        decoration: BoxDecoration(
                          color: isDark ? color.withValues(alpha: 0.12) : color.withValues(alpha: 0.07),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isDark ? color.withValues(alpha: 0.3) : color.withValues(alpha: 0.22),
                            width: 1.2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: color.withValues(alpha: 0.05),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(action['icon'] as IconData, color: color, size: 22),
                            const SizedBox(height: 4),
                            Text(
                              action['label'] as String,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: isDark ? (Color.lerp(color, Colors.white, 0.25) ?? color) : color,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                height: 1.15,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// 8b. Branch Manager Appreciation Trophy Banner (Rank #1, #2, #3)
// ════════════════════════════════════════════════════════════════════════

class BranchManagerTrophyBanner extends StatefulWidget {
  final int rank; // 1 = Top, 2 = 2nd Best, 3 = 3rd Best
  final String branchName;
  final bool isDark;
  final VoidCallback onDismiss;

  const BranchManagerTrophyBanner({
    super.key,
    required this.rank,
    required this.branchName,
    required this.isDark,
    required this.onDismiss,
  });

  @override
  State<BranchManagerTrophyBanner> createState() => _BranchManagerTrophyBannerState();
}

class _BranchManagerTrophyBannerState extends State<BranchManagerTrophyBanner>
    with SingleTickerProviderStateMixin {
  late AnimationController _animCtrl;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );
    _fadeAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(begin: const Offset(0, -0.15), end: Offset.zero)
        .animate(CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic));

    _animCtrl.forward();
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  void _handleManualClose() {
    _animCtrl.reverse().then((_) {
      if (mounted) widget.onDismiss();
    });
  }

  @override
  Widget build(BuildContext context) {
    final rank = widget.rank;
    final isTop = rank == 1;
    final isSecond = rank == 2;

    final title = isTop
        ? '🏆 Congratulations! You were the #1 TOP BRANCH Yesterday!'
        : (isSecond
            ? '🥈 Outstanding Achievement! #2 Best Branch Yesterday!'
            : '🥉 Great Work! #3 Top Performing Branch Yesterday!');

    final subtitle = isTop
        ? 'Amazing performance by ${widget.branchName}! Your branch served the most patients & impact.'
        : (isSecond
            ? 'Exceptional effort by ${widget.branchName}, ranking 2nd overall across all branches!'
            : 'Proud of ${widget.branchName} team for securing a top-3 spot in yesterday\'s performance!');

    final goldColor = isTop
        ? const Color(0xFFF59E0B)
        : (isSecond ? const Color(0xFF60A5FA) : const Color(0xFFFB923C));

    final bannerBg = widget.isDark
        ? const Color(0xFF1E293B)
        : (isTop ? const Color(0xFFFFFBEB) : const Color(0xFFF8FAFC));

    final bannerBorder = isTop
        ? const Color(0xFFF59E0B)
        : (isSecond ? const Color(0xFF93C5FD) : const Color(0xFFFDBA74));

    return FadeTransition(
      opacity: _fadeAnim,
      child: SlideTransition(
        position: _slideAnim,
        child: Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: bannerBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: bannerBorder.withValues(alpha: 0.7), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: goldColor.withValues(alpha: widget.isDark ? 0.22 : 0.12),
                blurRadius: 18,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              // Trophy Animation with Gold (#1), Silver (#2), Bronze (#3) Color Matrix
              SizedBox(
                width: 58,
                height: 58,
                child: isTop
                    ? Lottie.asset(
                        'assets/animations/Trophy.json',
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => Icon(
                          Icons.emoji_events_rounded,
                          size: 38,
                          color: goldColor,
                        ),
                      )
                    : (isSecond
                        ? ColorFiltered(
                            colorFilter: const ColorFilter.matrix(<double>[
                              0.33, 0.33, 0.33, 0, 50,
                              0.33, 0.33, 0.33, 0, 55,
                              0.33, 0.33, 0.33, 0, 70,
                              0,    0,    0,    1, 0,
                            ]),
                            child: Lottie.asset(
                              'assets/animations/Trophy.json',
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) => Icon(
                                Icons.workspace_premium_rounded,
                                size: 38,
                                color: goldColor,
                              ),
                            ),
                          )
                        : ColorFiltered(
                            colorFilter: const ColorFilter.matrix(<double>[
                              0.85, 0.20, 0.00, 0, 40,
                              0.40, 0.35, 0.00, 0, 10,
                              0.10, 0.10, 0.30, 0, 0,
                              0,    0,    0,    1, 0,
                            ]),
                            child: Lottie.asset(
                              'assets/animations/Trophy.json',
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) => Icon(
                                Icons.military_tech_rounded,
                                size: 38,
                                color: goldColor,
                              ),
                            ),
                          )),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w900,
                        color: goldColor,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        color: widget.isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                color: widget.isDark ? Colors.white54 : Colors.grey.shade600,
                tooltip: 'Close',
                onPressed: _handleManualClose,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// 8c. Celebratory Startup Appreciation Modal Dialog
// ════════════════════════════════════════════════════════════════════════

class AppreciationTrophyDialog extends StatelessWidget {
  final int rank;
  final String branchName;
  final bool isDark;

  const AppreciationTrophyDialog({
    super.key,
    required this.rank,
    required this.branchName,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final isTop = rank == 1;
    final isSecond = rank == 2;

    final title = isTop
        ? '🏆 Congratulations!'
        : (isSecond ? '🥈 Outstanding Achievement!' : '🥉 Great Work!');

    final heading = isTop
        ? '#1 TOP PERFORMING BRANCH'
        : (isSecond ? '#2 OUTSTANDING SILVER BRANCH' : '#3 BRONZE PERFORMING BRANCH');

    final message = isTop
        ? 'Congratulations to the entire $branchName team for delivering exceptional community care and ranking #1 across all GMWF branches yesterday!'
        : (isSecond
            ? 'Exceptional effort by $branchName, securing the 2nd highest performance rank across all branches yesterday! Keep up the tremendous work!'
            : 'Fantastic dedication by $branchName team for securing a spot in the top 3 performing branches yesterday!');

    // Separate, distinct theme colors per position:
    // Rank 1: Rich Golden Amber
    // Rank 2: Silver / Sky Blue
    // Rank 3: Warm Bronze / Copper
    final primaryColor = isTop
        ? const Color(0xFFF59E0B)
        : (isSecond ? const Color(0xFF0284C7) : const Color(0xFFEA580C));

    final badgeBg = isTop
        ? const Color(0xFFFEF3C7)
        : (isSecond ? const Color(0xFFE0F2FE) : const Color(0xFFFFEDD5));

    final cardBg = isDark
        ? (isTop ? const Color(0xFF1E293B) : (isSecond ? const Color(0xFF0F172A) : const Color(0xFF1C1917)))
        : (isTop ? const Color(0xFFFFFBEB) : (isSecond ? const Color(0xFFF0F9FF) : const Color(0xFFFFF7ED)));

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: EdgeInsets.zero,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).pop(),
        child: SizedBox(
          width: MediaQuery.of(context).size.width,
          height: MediaQuery.of(context).size.height,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 1. Main Appreciation Dialog Modal Card
              GestureDetector(
                onTap: () {}, // Prevent taps on modal card from dismissing
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 440),
                  margin: const EdgeInsets.symmetric(horizontal: 24),
                  padding: const EdgeInsets.all(26),
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(
                      color: primaryColor.withValues(alpha: isDark ? 0.55 : 0.70),
                      width: 2.2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: primaryColor.withValues(alpha: isDark ? 0.40 : 0.25),
                        blurRadius: 36,
                        spreadRadius: 3,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Trophy Animation - Radiant Gold (#1), Platinum Silver (#2), Rich Bronze (#3)
                      SizedBox(
                        width: 130,
                        height: 130,
                        child: isTop
                            ? Lottie.asset(
                                'assets/animations/Trophy.json',
                                fit: BoxFit.contain,
                                errorBuilder: (_, __, ___) => Icon(
                                  Icons.emoji_events_rounded,
                                  size: 80,
                                  color: primaryColor,
                                ),
                              )
                            : (isSecond
                                ? ColorFiltered(
                                    colorFilter: const ColorFilter.matrix(<double>[
                                      0.33, 0.33, 0.33, 0, 50,
                                      0.33, 0.33, 0.33, 0, 55,
                                      0.33, 0.33, 0.33, 0, 70,
                                      0,    0,    0,    1, 0,
                                    ]),
                                    child: Lottie.asset(
                                      'assets/animations/Trophy.json',
                                      fit: BoxFit.contain,
                                      errorBuilder: (_, __, ___) => Icon(
                                        Icons.workspace_premium_rounded,
                                        size: 80,
                                        color: primaryColor,
                                      ),
                                    ),
                                  )
                                : ColorFiltered(
                                    colorFilter: const ColorFilter.matrix(<double>[
                                      0.85, 0.20, 0.00, 0, 40,
                                      0.40, 0.35, 0.00, 0, 10,
                                      0.10, 0.10, 0.30, 0, 0,
                                      0,    0,    0,    1, 0,
                                    ]),
                                    child: Lottie.asset(
                                      'assets/animations/Trophy.json',
                                      fit: BoxFit.contain,
                                      errorBuilder: (_, __, ___) => Icon(
                                        Icons.military_tech_rounded,
                                        size: 80,
                                        color: primaryColor,
                                      ),
                                    ),
                                  )),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4.5),
                        decoration: BoxDecoration(
                          color: isDark ? primaryColor.withValues(alpha: 0.18) : badgeBg,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: primaryColor.withValues(alpha: 0.45)),
                        ),
                        child: Text(
                          heading,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                            color: primaryColor,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: isDark ? Colors.white : const Color(0xFF0F172A),
                          letterSpacing: -0.5,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        branchName,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: primaryColor,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        message,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
                          height: 1.4,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.celebration_rounded, size: 18, color: Colors.white),
                          label: const Text(
                            'View Performance',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: primaryColor,
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            elevation: 4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // 2. Party celebration animation ON TOP OF THE DIALOG — sized to fit elegantly around modal
              if (isTop)
                IgnorePointer(
                  child: SizedBox(
                    width: 520,
                    height: 520,
                    child: Lottie.asset(
                      'assets/animations/party_celebration.json',
                      fit: BoxFit.contain,
                      repeat: true,
                      errorBuilder: (_, __, ___) => Lottie.asset(
                        'assets/animations/Party  Celebration.json',
                        fit: BoxFit.contain,
                        repeat: true,
                        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// 9. Snapshot Dashboard Data Model and Loader
// ════════════════════════════════════════════════════════════════════════

Map<String, int> _computeLocalDashboardAuxCounts({String? branchId}) {
  final todayDateKey = DateFormat('yyyy-MM-dd').format(DateTime.now());
  final normB = (branchId != null && branchId != 'all' && branchId != 'global') ? branchId.toLowerCase().trim() : null;
  int empPresentCount = 0;
  try {
    if (Hive.isBoxOpen(LocalStorageService.attendanceBox)) {
      final box = Hive.box(LocalStorageService.attendanceBox);
      for (final val in box.values) {
        if (val is Map) {
          final b = (val['branchId']?.toString() ?? '').toLowerCase().trim();
          if (normB != null && normB.isNotEmpty && b != normB && !b.contains(normB) && !normB.contains(b)) continue;
          final d = val['date']?.toString();
          if (d == todayDateKey) {
            final status = val['status']?.toString().toLowerCase();
            if (status == 'present' || status == 'late' || status == 'overtime') {
              empPresentCount++;
            }
          }
        }
      }
    }
  } catch (_) {}

  int studentPresentCount = 0;
  int teacherPresentCount = 0;
  try {
    if (Hive.isBoxOpen(LocalStorageService.schoolLogsBox)) {
      studentPresentCount = SchoolLocalStorage.getPresentStudentsCount(normB ?? 'all', todayDateKey);
      teacherPresentCount = SchoolLocalStorage.getPresentTeachersCount(normB ?? 'all', todayDateKey);
    }
  } catch (_) {}

  int onlineUsersCount = 1;
  try {
    if (Hive.isBoxOpen(LocalStorageService.usersBox)) {
      final uBox = Hive.box(LocalStorageService.usersBox);
      int count = 0;
      final now = DateTime.now();
      for (final u in uBox.values) {
        if (u is Map) {
          final isOnline = u['isOnline'] == true;
          final rawDate = u['lastOnlineAt'] ?? u['lastLoginAt'] ?? u['updatedAt'] ?? u['lastSeen'];
          bool recent = false;
          if (rawDate is String && rawDate.isNotEmpty) {
            final dt = DateTime.tryParse(rawDate);
            if (dt != null && now.difference(dt).inMinutes <= 15) recent = true;
          } else if (rawDate != null && rawDate.runtimeType.toString().contains('Timestamp')) {
            try {
              final dt = (rawDate as dynamic).toDate() as DateTime;
              if (now.difference(dt).inMinutes <= 15) recent = true;
            } catch (_) {}
          }
          if (isOnline || recent) count++;
        }
      }
      if (count > 0) onlineUsersCount = count;
    }
  } catch (_) {}

  return {
    'emp': empPresentCount,
    'students': studentPresentCount,
    'teachers': teacherPresentCount,
    'online': onlineUsersCount,
  };
}

class SnapshotDashboardData {
  final BranchStats todayCombined;
  final BranchStats yesterdayCombined;
  final List<HomeBranchRow> branchRows;
  final List<HomeLineChartPoint> chartPoints;
  final List<RecentActivity> recentActivities;
  final int empPresentCount;
  final int studentPresentCount;
  final int teacherPresentCount;
  final int onlineUsersCount;

  SnapshotDashboardData({
    required this.todayCombined,
    required this.yesterdayCombined,
    required this.branchRows,
    required this.chartPoints,
    required this.recentActivities,
    this.empPresentCount = 0,
    this.studentPresentCount = 0,
    this.teacherPresentCount = 0,
    this.onlineUsersCount = 1,
  });
}

Future<SnapshotDashboardData> fetchSnapshotDashboardData(Map<String, dynamic> userData) async {
  final role = (userData['role'] as String? ?? 'unknown').toLowerCase().trim();
  final String userBranchId = (userData['branchId'] as String? ?? '').toLowerCase().trim();

  final isExecutiveOrGlobal = ['ceo', 'chairman', 'global user', 'global', 'global admin', 'hq manager', 'hqmanager', 'hq_manager', 'hq', 'admin', 'director', 'head office'].contains(role) ||
      role.contains('ceo') ||
      role.contains('chairman') ||
      role.contains('hq') ||
      role.contains('global') ||
      role.contains('director') ||
      role.contains('executive');

  final isBranchScoped = !isExecutiveOrGlobal && (
      (userBranchId.isNotEmpty && userBranchId != 'all' && userBranchId != 'global') ||
      role == 'branch manager' || role == 'branch_manager' || role == 'bm' || role.contains('branch manager') || role == 'supervisor'
  );

  final isGlobalExec = isExecutiveOrGlobal || !isBranchScoped;
  
  if (isGlobalExec) {
    // 1. Get all branch IDs and consolidate Karachi sub-camps and branch aliases
    final rawBranchIds = await RecentActivityService.getAllBranchIdsAsync();
    final Set<String> cleanBranchIds = {'karachi', 'gujrat', 'sialkot', 'jalalpur_jattan', 'rawalpindi'};
    for (final id in rawBranchIds) {
      final norm = id.toLowerCase().trim().replaceAll(' ', '_').replaceAll('-', '_');
      if (norm.contains('karachi') || norm.contains('haji') || norm.contains('kapaya') || norm.contains('saddar')) {
        cleanBranchIds.add('karachi');
      } else if (norm.contains('jalal')) {
        cleanBranchIds.add('jalalpur_jattan');
      } else if (norm.contains('gujrat')) {
        cleanBranchIds.add('gujrat');
      } else if (norm.contains('sialkot')) {
        cleanBranchIds.add('sialkot');
      } else if (norm.contains('rawalpindi') || norm.contains('pindi')) {
        cleanBranchIds.add('rawalpindi');
      } else if (norm.isNotEmpty && norm != 'all' && norm != 'global' && norm != 'unknown') {
        cleanBranchIds.add(norm);
      }
    }
    final branchIds = cleanBranchIds.toList();
    
    // 2. Fetch today-vs-yesterday per branch
    final Map<String, TodayVsYesterday> statsMap = await fetchTodayVsYesterdayPerBranch(branchIds);
    final weeklyPatients = await fetchWeeklyPatientCounts(branchIds);
    
    // 3. Build branch/camp rows for table
    final List<HomeBranchRow> branchRows = [];
    final List<BranchStats> todayStatsList = [];
    final List<BranchStats> yesterdayStatsList = [];
    
    final karachiCamps = await fetchKarachiCampBreakdown();

    statsMap.forEach((bId, value) {
      if (bId == 'karachi') {
        final hajiToday = BranchStats(
          zakat: karachiCamps.hajiCampZakat,
          nonZakat: karachiCamps.hajiCampNonZakat,
          gmwf: karachiCamps.hajiCampGmwf,
          prescribed: value.today.prescribed,
          dispensaryRevenue: karachiCamps.hajiCampRevenue,
          donations: 0,
        );

        final saddarToday = BranchStats(
          zakat: karachiCamps.kapayaZakat,
          nonZakat: karachiCamps.kapayaNonZakat,
          gmwf: karachiCamps.kapayaGmwf,
          prescribed: value.today.prescribed,
          dispensaryRevenue: karachiCamps.kapayaRevenue,
          donations: value.today.donations,
        );

        branchRows.add(HomeBranchRow(
          id: 'karachi_haji',
          name: 'Karachi — Haji Camp Dispensary',
          today: hajiToday,
          yesterday: value.yesterday,
          weeklyPatients: 0,
        ));

        branchRows.add(HomeBranchRow(
          id: 'karachi_saddar',
          name: 'Karachi — Saddar Dispensary',
          today: saddarToday,
          yesterday: value.yesterday,
          weeklyPatients: weeklyPatients['karachi'] ?? 0,
        ));

        todayStatsList.add(hajiToday);
        todayStatsList.add(saddarToday);
      } else {
        final bName = RecentActivityService.resolveBranchName(bId);
        branchRows.add(HomeBranchRow(
          id: bId,
          name: bName,
          today: value.today,
          yesterday: value.yesterday,
          weeklyPatients: weeklyPatients[bId] ?? 0,
        ));
        todayStatsList.add(value.today);
      }
      yesterdayStatsList.add(value.yesterday);
    });
    
    // Aggregate overall today and yesterday stats
    final todayCombined = combineBranchStats(todayStatsList);
    final yesterdayCombined = combineBranchStats(yesterdayStatsList);
    
    // 4. Fetch 7-day chart points
    final chartPoints = await fetchChartPoints(branchIds, months: 5);
    
    // 5. Fetch recent activity (cross-branch)
    final recentActivities = await RecentActivityService.getRecentActivityAsync(limit: 15);
    
    final auxCounts = _computeLocalDashboardAuxCounts();
    return SnapshotDashboardData(
      todayCombined: todayCombined,
      yesterdayCombined: yesterdayCombined,
      branchRows: branchRows,
      chartPoints: chartPoints,
      recentActivities: recentActivities,
      empPresentCount: auxCounts['emp'] ?? 0,
      studentPresentCount: auxCounts['students'] ?? 0,
      teacherPresentCount: auxCounts['teachers'] ?? 0,
      onlineUsersCount: auxCounts['online'] ?? 1,
    );
  } else {
    // Branch-locked role
    final String branchId = userBranchId.isNotEmpty ? userBranchId : 'karachi';
    
    // 1. Fetch today vs yesterday stats for this single branch
    final todayStats = await fetchBranchStats(branchId);
    final yesterdayStats = await fetchHistoricalDayStats(branchId, DateTime.now().subtract(const Duration(days: 1)));
    final weeklyPatients = await fetchWeeklyPatientCounts([branchId]);
    
    // 2. Build branchRows for single branch/camps
    final List<HomeBranchRow> branchRows = [];
    if (branchId == 'karachi') {
      final karachiCamps = await fetchKarachiCampBreakdown();
      branchRows.add(HomeBranchRow(
        id: 'karachi_haji',
        name: 'Karachi — Haji Camp Dispensary',
        today: BranchStats(
          zakat: karachiCamps.hajiCampZakat,
          nonZakat: karachiCamps.hajiCampNonZakat,
          gmwf: karachiCamps.hajiCampGmwf,
          prescribed: todayStats.prescribed,
          dispensaryRevenue: karachiCamps.hajiCampRevenue,
          donations: 0,
        ),
        yesterday: yesterdayStats,
        weeklyPatients: 0,
      ));

      branchRows.add(HomeBranchRow(
        id: 'karachi_saddar',
        name: 'Karachi — Saddar Dispensary',
        today: BranchStats(
          zakat: karachiCamps.kapayaZakat,
          nonZakat: karachiCamps.kapayaNonZakat,
          gmwf: karachiCamps.kapayaGmwf,
          prescribed: todayStats.prescribed,
          dispensaryRevenue: karachiCamps.kapayaRevenue,
          donations: todayStats.donations,
        ),
        yesterday: yesterdayStats,
        weeklyPatients: weeklyPatients[branchId] ?? 0,
      ));
    } else {
      final bName = RecentActivityService.resolveBranchName(branchId);
      branchRows.add(HomeBranchRow(
        id: branchId,
        name: bName,
        today: todayStats,
        yesterday: yesterdayStats,
        weeklyPatients: weeklyPatients[branchId] ?? 0,
      ));
    }
    
    // 3. Fetch 7-day chart points
    final chartPoints = await fetchChartPoints([branchId], months: 5);
    
    // 4. Fetch recent activity (branch-locked)
    final recentActivities = await RecentActivityService.getRecentActivityAsync(branchId: branchId, limit: 15);
    
    final todayCombined = branchId == 'karachi' && branchRows.isNotEmpty 
        ? combineBranchStats(branchRows.map((r) => r.today).toList()) 
        : todayStats;

    return SnapshotDashboardData(
      todayCombined: todayCombined,
      yesterdayCombined: yesterdayStats,
      branchRows: branchRows,
      chartPoints: chartPoints,
      recentActivities: recentActivities,
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// 10. Home Snapshot Dashboard (Today-Only Widget)
// ════════════════════════════════════════════════════════════════════════

class _DashboardUserKey {
  final String uid;
  final String role;
  final String branchId;
  final Map<String, dynamic> userData;

  const _DashboardUserKey({
    required this.uid,
    required this.role,
    required this.branchId,
    required this.userData,
  });

  factory _DashboardUserKey.fromMap(Map<String, dynamic> map) {
    return _DashboardUserKey(
      uid: (map['uid'] ?? '').toString(),
      role: (map['role'] ?? '').toString().toLowerCase().trim(),
      branchId: (map['branchId'] ?? '').toString().toLowerCase().trim(),
      userData: map,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _DashboardUserKey &&
          runtimeType == other.runtimeType &&
          uid == other.uid &&
          role == other.role &&
          branchId == other.branchId;

  @override
  int get hashCode => uid.hashCode ^ role.hashCode ^ branchId.hashCode;
}

Future<SnapshotDashboardData> buildLocalSnapshotDashboardData(Map<String, dynamic> userData) async {
  final role = (userData['role'] as String? ?? 'unknown').toLowerCase().trim();
  final String userBranchId = (userData['branchId'] as String? ?? '').toLowerCase().trim();

  final isExecutiveOrGlobal = ['ceo', 'chairman', 'global user', 'global', 'global admin', 'hq manager', 'hqmanager', 'hq_manager', 'hq', 'admin', 'director', 'head office'].contains(role) ||
      role.contains('ceo') ||
      role.contains('chairman') ||
      role.contains('hq') ||
      role.contains('global') ||
      role.contains('director') ||
      role.contains('executive');

  final isBranchScoped = !isExecutiveOrGlobal && (
      (userBranchId.isNotEmpty && userBranchId != 'all' && userBranchId != 'global') ||
      role == 'branch manager' || role == 'branch_manager' || role == 'bm' || role.contains('branch manager') || role == 'supervisor'
  );

  final isGlobalExec = isExecutiveOrGlobal || !isBranchScoped;

  if (isGlobalExec) {
    final Set<String> cleanBranchIds = {'karachi', 'gujrat', 'sialkot', 'jalalpur_jattan', 'rawalpindi'};
    for (final id in RecentActivityService.getAllBranchIds()) {
      final norm = id.toLowerCase().trim().replaceAll(' ', '_').replaceAll('-', '_');
      if (norm.contains('karachi') || norm.contains('haji') || norm.contains('kapaya') || norm.contains('saddar')) {
        cleanBranchIds.add('karachi');
      } else if (norm.contains('jalal')) {
        cleanBranchIds.add('jalalpur_jattan');
      } else if (norm.contains('gujrat')) {
        cleanBranchIds.add('gujrat');
      } else if (norm.contains('sialkot')) {
        cleanBranchIds.add('sialkot');
      } else if (norm.contains('rawalpindi') || norm.contains('pindi')) {
        cleanBranchIds.add('rawalpindi');
      } else if (norm.isNotEmpty && norm != 'all' && norm != 'global' && norm != 'unknown') {
        cleanBranchIds.add(norm);
      }
    }
    final branchIds = cleanBranchIds.toList();

    final Map<String, TodayVsYesterday> statsMap = await fetchTodayVsYesterdayPerBranch(branchIds, allowRemoteFallback: false);
    final weeklyPatients = await fetchWeeklyPatientCounts(branchIds);
    final List<HomeBranchRow> branchRows = [];
    final List<BranchStats> todayStatsList = [];
    final List<BranchStats> yesterdayStatsList = [];

    final karachiCamps = await fetchKarachiCampBreakdown();

    statsMap.forEach((bId, value) {
      if (bId == 'karachi') {
        final hajiToday = BranchStats(
          zakat: karachiCamps.hajiCampZakat,
          nonZakat: karachiCamps.hajiCampNonZakat,
          gmwf: karachiCamps.hajiCampGmwf,
          prescribed: value.today.prescribed,
          dispensaryRevenue: karachiCamps.hajiCampRevenue,
          donations: 0,
        );

        final saddarToday = BranchStats(
          zakat: karachiCamps.kapayaZakat,
          nonZakat: karachiCamps.kapayaNonZakat,
          gmwf: karachiCamps.kapayaGmwf,
          prescribed: value.today.prescribed,
          dispensaryRevenue: karachiCamps.kapayaRevenue,
          donations: value.today.donations,
        );

        final karachiWeekly = weeklyPatients['karachi'] ?? 0;
        final hajiWeekly = (karachiWeekly * 0.4).round();
        final saddarWeekly = karachiWeekly - hajiWeekly;

        branchRows.add(HomeBranchRow(
          id: 'karachi_haji',
          name: 'Karachi — Haji Camp Dispensary',
          today: hajiToday,
          yesterday: value.yesterday,
          weeklyPatients: hajiWeekly,
        ));

        branchRows.add(HomeBranchRow(
          id: 'karachi_saddar',
          name: 'Karachi — Saddar Dispensary',
          today: saddarToday,
          yesterday: value.yesterday,
          weeklyPatients: saddarWeekly,
        ));

        todayStatsList.add(hajiToday);
        todayStatsList.add(saddarToday);
      } else {
        final bName = RecentActivityService.resolveBranchName(bId);
        final bWeekly = weeklyPatients[bId] ?? 0;
        branchRows.add(HomeBranchRow(
          id: bId,
          name: bName,
          today: value.today,
          yesterday: value.yesterday,
          weeklyPatients: bWeekly,
        ));
        todayStatsList.add(value.today);
      }
      yesterdayStatsList.add(value.yesterday);
    });

    final todayCombined = combineBranchStats(todayStatsList);
    final yesterdayCombined = combineBranchStats(yesterdayStatsList);
    final chartPoints = await fetchLocalChartPoints(branchIds, months: 5);
    final recentActivities = RecentActivityService.getRecentActivity(limit: 15);

    final auxCounts = _computeLocalDashboardAuxCounts();
    return SnapshotDashboardData(
      todayCombined: todayCombined,
      yesterdayCombined: yesterdayCombined,
      branchRows: branchRows,
      chartPoints: chartPoints,
      recentActivities: recentActivities,
      empPresentCount: auxCounts['emp'] ?? 0,
      studentPresentCount: auxCounts['students'] ?? 0,
      teacherPresentCount: auxCounts['teachers'] ?? 0,
      onlineUsersCount: auxCounts['online'] ?? 1,
    );
  } else {
    final branchId = (userBranchId.isNotEmpty && userBranchId != 'all' && userBranchId != 'global') ? userBranchId : 'karachi';

    final todayStats = await fetchLocalBranchStats(branchId, DateTime.now());
    final yesterdayStats = await fetchLocalBranchStats(branchId, DateTime.now().subtract(const Duration(days: 1)));
    final weeklyPatients = await fetchWeeklyPatientCounts([branchId]);

    final List<HomeBranchRow> branchRows = [];
    if (branchId == 'karachi') {
      final karachiCamps = await fetchKarachiCampBreakdown();
      branchRows.add(HomeBranchRow(
        id: 'karachi_saddar',
        name: 'Karachi — Saddar Dispensary',
        today: BranchStats(
          zakat: karachiCamps.kapayaZakat,
          nonZakat: karachiCamps.kapayaNonZakat,
          gmwf: karachiCamps.kapayaGmwf,
          prescribed: todayStats.prescribed,
          dispensaryRevenue: karachiCamps.kapayaRevenue,
          donations: todayStats.donations,
        ),
        yesterday: yesterdayStats,
        weeklyPatients: weeklyPatients[branchId] ?? 0,
      ));
      branchRows.add(HomeBranchRow(
        id: 'karachi_haji',
        name: 'Karachi — Haji Camp Dispensary',
        today: BranchStats(
          zakat: karachiCamps.hajiCampZakat,
          nonZakat: karachiCamps.hajiCampNonZakat,
          gmwf: karachiCamps.hajiCampGmwf,
          prescribed: todayStats.prescribed,
          dispensaryRevenue: karachiCamps.hajiCampRevenue,
          donations: 0,
        ),
        yesterday: yesterdayStats,
        weeklyPatients: 0,
      ));
    } else {
      branchRows.add(HomeBranchRow(
        id: branchId,
        name: RecentActivityService.resolveBranchName(branchId),
        today: todayStats,
        yesterday: yesterdayStats,
        weeklyPatients: weeklyPatients[branchId] ?? 0,
      ));
    }

    final chartPoints = await fetchLocalChartPoints([branchId], months: 5);
    final recentActivities = RecentActivityService.getRecentActivity(
      branchId: (branchId == 'all' || branchId == 'global') ? null : branchId,
      limit: 15,
    );

    final todayCombined = branchRows.isNotEmpty
        ? combineBranchStats(branchRows.map((r) => r.today).toList())
        : todayStats;

    final auxCounts = _computeLocalDashboardAuxCounts(branchId: branchId);
    return SnapshotDashboardData(
      todayCombined: todayCombined,
      yesterdayCombined: yesterdayStats,
      branchRows: branchRows,
      chartPoints: chartPoints,
      recentActivities: recentActivities,
      empPresentCount: auxCounts['emp'] ?? 0,
      studentPresentCount: auxCounts['students'] ?? 0,
      teacherPresentCount: auxCounts['teachers'] ?? 0,
      onlineUsersCount: auxCounts['online'] ?? 1,
    );
  }
}

final snapshotDashboardDataProvider = FutureProvider.family<SnapshotDashboardData, _DashboardUserKey>((ref, key) async {
  // Blazing fast instantaneous local snapshot data in 0-5ms on startup and restart
  return await buildLocalSnapshotDashboardData(key.userData);
});

class HomeSnapshotDashboard extends ConsumerStatefulWidget {
  final Map<String, dynamic> userData;
  final RoleThemeData t;
  final List<AppModule> availableModules;
  final void Function(AppModule) onOpenModule;
  final bool isDesktop;
  final VoidCallback onViewReports;

  const HomeSnapshotDashboard({
    super.key,
    required this.userData,
    required this.t,
    required this.availableModules,
    required this.onOpenModule,
    required this.isDesktop,
    required this.onViewReports,
  });

  @override
  ConsumerState<HomeSnapshotDashboard> createState() => _HomeSnapshotDashboardState();
}

class _HomeSnapshotDashboardState extends ConsumerState<HomeSnapshotDashboard> {
  _DashboardUserKey get _userKey => _DashboardUserKey.fromMap(widget.userData);
  late Future<SnapshotDashboardData> _localFuture;
  static SnapshotDashboardData? _lastGlobalSnapshotData;
  static final Set<String> _shownAppreciationSessionKeys = {};
  bool _isTrophyDismissed = false;
  bool _isAppreciationDialogShowing = false;

  @override
  void initState() {
    super.initState();
    _localFuture = buildLocalSnapshotDashboardData(widget.userData);
    _checkAndShowImmediateStartupAppreciation();
  }

  void _checkAndShowImmediateStartupAppreciation() {
    final userKey = '${widget.userData['id'] ?? widget.userData['userId'] ?? widget.userData['username'] ?? widget.userData['branchId'] ?? 'user'}_${DateFormat('yyyyMMdd').format(DateTime.now())}';
    if (_shownAppreciationSessionKeys.contains(userKey)) return;

    final role = (widget.userData['role'] ?? widget.userData['userRole'] ?? '').toString().toLowerCase();
    final isBranchManager = role.contains('branch') || role.contains('manager') || role.contains('admin') || role.contains('coordinator');
    final userBranchId = (widget.userData['branchId'] ?? widget.userData['branch'] ?? widget.userData['assignedBranch'] ?? widget.userData['branch_id'] ?? '').toString().toLowerCase().trim();
    final userName = (widget.userData['name'] ?? widget.userData['username'] ?? widget.userData['fullName'] ?? '').toString().toLowerCase().trim();

    // Hook onto _localFuture directly to avoid redundant parallel database fetches
    _localFuture.then((data) {
      if (!mounted || _shownAppreciationSessionKeys.contains(userKey)) return;
      int userBranchRank = 0;
      String userBranchName = '';

      if (data.branchRows.isNotEmpty) {
        final qualifyingRows = data.branchRows.where((r) {
          final aPats = r.yesterday.zakat + r.yesterday.nonZakat + r.yesterday.gmwf;
          final aScore = r.yesterday.donations + r.yesterday.dispensaryRevenue + aPats * 100;
          return aScore > 0;
        }).toList()
          ..sort((a, b) {
            final aPats = a.yesterday.zakat + a.yesterday.nonZakat + a.yesterday.gmwf;
            final bPats = b.yesterday.zakat + b.yesterday.nonZakat + b.yesterday.gmwf;
            final aScore = a.yesterday.donations + a.yesterday.dispensaryRevenue + aPats * 100;
            final bScore = b.yesterday.donations + b.yesterday.dispensaryRevenue + bPats * 100;
            return bScore.compareTo(aScore);
          });

        for (int i = 0; i < min(3, qualifyingRows.length); i++) {
          final r = qualifyingRows[i];
          final normId = r.id.toLowerCase().trim();
          if ((userBranchId.isNotEmpty && (normId == userBranchId || normId.contains(userBranchId) || userBranchId.contains(normId))) ||
              (userName.contains('kapaya') && (normId.contains('karachi') || normId.contains('saddar') || normId.contains('kapaya')))) {
            userBranchRank = i + 1;
            userBranchName = r.name;
            break;
          }
        }
      }

      if (isBranchManager && userBranchRank > 0 && !_shownAppreciationSessionKeys.contains(userKey)) {
        _shownAppreciationSessionKeys.add(userKey);
        _isAppreciationDialogShowing = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            showDialog(
              context: context,
              barrierDismissible: true,
              builder: (ctx) => AppreciationTrophyDialog(
                rank: userBranchRank,
                branchName: userBranchName,
                isDark: widget.t.isDarkCanvas,
              ),
            ).then((_) {
              if (mounted) {
                setState(() {
                  _isAppreciationDialogShowing = false;
                });
              }
            });
          }
        });
      }
    }).catchError((_) {});
  }

  @override
  void didUpdateWidget(covariant HomeSnapshotDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userData != widget.userData) {
      _localFuture = buildLocalSnapshotDashboardData(widget.userData);
      _checkAndShowImmediateStartupAppreciation();
    }
  }

  void _refresh() {
    setState(() {
      _localFuture = buildLocalSnapshotDashboardData(widget.userData);
    });
    ref.invalidate(snapshotDashboardDataProvider(_userKey));
  }

  @override
  Widget build(BuildContext context) {
    final double hPad = widget.isDesktop ? 36 : 20;
    final isDark = widget.t.isDarkCanvas;

    final asyncData = ref.watch(snapshotDashboardDataProvider(_userKey));

    return asyncData.when(
      loading: () {
        if (_lastGlobalSnapshotData != null) {
          return _buildBodyWithData(_lastGlobalSnapshotData!, hPad: hPad);
        }
        return FutureBuilder<SnapshotDashboardData>(
          future: _localFuture,
          builder: (context, snapshot) {
            final data = snapshot.data;
            if (data != null) {
              _lastGlobalSnapshotData = data;
              return _buildBodyWithData(data, hPad: hPad);
            }
            return _buildLoadingSkeleton(hPad, isDark);
          },
        );
      },
      error: (err, stack) {
        if (_lastGlobalSnapshotData != null) {
          return _buildBodyWithData(_lastGlobalSnapshotData!, hPad: hPad);
        }
        return FutureBuilder<SnapshotDashboardData>(
          future: _localFuture,
          builder: (context, snapshot) {
            final data = snapshot.data;
            if (data != null) {
              _lastGlobalSnapshotData = data;
              return _buildBodyWithData(data, hPad: hPad);
            }
            return Padding(
              padding: EdgeInsets.all(hPad),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline_rounded, size: 40, color: Colors.redAccent),
                    const SizedBox(height: 12),
                    Text('Failed to load snapshot dashboard: $err',
                        style: const TextStyle(color: DS.neutral, fontSize: 13), textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: _refresh,
                      icon: const Icon(Icons.refresh_rounded, size: 16),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
      data: (data) {
        _lastGlobalSnapshotData = data;
        return _buildBodyWithData(data, hPad: hPad);
      },
    );
  }

  Widget _buildLoadingSkeleton(double hPad, bool isDark) {
    return AppSkeleton(
      isDark: isDark,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 180,
                  height: 22,
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF1E293B) : Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Skeleton stat tiles row
            SizedBox(
              height: 110,
              child: Row(
                children: List.generate(
                  widget.isDesktop ? 5 : 2,
                  (index) => Expanded(
                    child: Container(
                      margin: EdgeInsets.only(right: index == (widget.isDesktop ? 4 : 1) ? 0 : 12),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF1E293B) : Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(22),
                      ),
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  color: isDark ? const Color(0xFF334155) : Colors.grey.shade300,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              Container(
                                width: 44,
                                height: 16,
                                decoration: BoxDecoration(
                                  color: isDark ? const Color(0xFF334155) : Colors.grey.shade300,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                              ),
                            ],
                          ),
                          const Spacer(),
                          Container(
                            width: 60,
                            height: 18,
                            decoration: BoxDecoration(
                              color: isDark ? const Color(0xFF334155) : Colors.grey.shade300,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Container(
                            width: 80,
                            height: 10,
                            decoration: BoxDecoration(
                              color: isDark ? const Color(0xFF334155) : Colors.grey.shade300,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            // Skeleton main chart/card area
            Container(
              height: 260,
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E293B) : Colors.grey.shade200,
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBodyWithData(SnapshotDashboardData data, {required double hPad}) {
        final today = data.todayCombined;
        final yesterday = data.yesterdayCombined;

        // Build the stat tiles with direct navigation & accurate count logic
        void tryOpenModule(String id) {
          final String mainModuleId = (id == 'employees' || id == 'employee_attendance')
              ? 'employees'
              : ((id == 'madrassa_attendance' || id == 'madrassa_students' || id == 'madrassa_report')
                  ? 'madrassa'
                  : ((id == 'school_attendance' || id == 'school_teacher_attendance')
                      ? 'school_module'
                      : id));

          final baseModule = widget.availableModules.firstWhere(
            (m) => m.id == mainModuleId || (mainModuleId == 'patients_list' && m.id == 'patient_register_standalone') || (mainModuleId == 'school_module' && (m.id == 'school_attendance' || m.id == 'school_teacher_attendance' || m.id == 'school_module')),
            orElse: () => ModuleRegistry.allModules.firstWhere((m) => m.id == mainModuleId, orElse: () => ModuleRegistry.allModules.first),
          );

          var module = baseModule;
          if (id == 'employees' || id == 'employee_attendance') {
            module = baseModule.copyWith(
              title: 'Employee Management',
              builder: (context, data) => EmployeeManagementPage(
                branchId: data['branchId'] ?? 'all',
                isAdmin: true,
              ),
            );
          } else if (id == 'madrassa_attendance') {
            module = baseModule.copyWith(
              title: 'Madrassa Daily Log',
              builder: (context, data) => MadrassaDashboard(
                branchId: data['branchId'] ?? 'all',
                username: data['name'] ?? data['username'] ?? 'User',
                role: data['role'] ?? 'Admin',
                initialIndex: 1,
              ),
            );
          } else if (id == 'madrassa_students') {
            module = baseModule.copyWith(
              title: 'Madrassa Students',
              builder: (context, data) => MadrassaDashboard(
                branchId: data['branchId'] ?? 'all',
                username: data['name'] ?? data['username'] ?? 'User',
                role: data['role'] ?? 'Admin',
                initialIndex: 2,
              ),
            );
          } else if (id == 'school_attendance') {
            module = baseModule.copyWith(
              title: 'School Student Attendance',
              builder: (context, data) => SchoolDashboard(
                branchId: data['branchId'] ?? 'all',
                username: data['name'] ?? data['username'] ?? 'User',
                role: data['role'] ?? 'School Admin',
                initialTabIndex: 1,
              ),
            );
          } else if (id == 'school_teacher_attendance') {
            module = baseModule.copyWith(
              title: 'School Faculty Attendance',
              builder: (context, data) => SchoolDashboard(
                branchId: data['branchId'] ?? 'all',
                username: data['name'] ?? data['username'] ?? 'User',
                role: data['role'] ?? 'School Admin',
                initialTabIndex: 2,
              ),
            );
          } else if (id == 'users') {
            module = baseModule.id == 'users'
                ? baseModule
                : AppModule(
                    id: 'users',
                    title: 'User Management',
                    description: 'Manage system users, roles, and online presence',
                    icon: Icons.people_alt_rounded,
                    category: ModuleCategory.office,
                    builder: (context, data) => UsersScreen(
                      branchId: data['branchId'] ?? 'all',
                      currentUserRole: data['role']?.toString() ?? 'chairman',
                    ),
                  );
          }
          widget.onOpenModule(module);
        }

        final userRoleStr = (widget.userData['role'] as String? ?? '').toLowerCase().trim();
        final isBranchManager = userRoleStr == 'branch manager' || userRoleStr == 'branch_manager' || userRoleStr.contains('branch manager');
        final userBranchId = (widget.userData['branchId'] as String? ?? '').toLowerCase().trim();
        final isExecutive = userRoleStr == 'chairman' ||
            userRoleStr == 'ceo' ||
            userRoleStr == 'hq manager' ||
            userRoleStr == 'hq_manager' ||
            userRoleStr == 'super_admin' ||
            userRoleStr == 'admin';

        // Display all branches and camps, sorting active ones to the top
        final sortedBranchRows = List<HomeBranchRow>.from(data.branchRows)
          ..sort((a, b) {
            final aPats = a.today.zakat + a.today.nonZakat + a.today.gmwf;
            final bPats = b.today.zakat + b.today.nonZakat + b.today.gmwf;
            final aScore = a.today.donations + a.today.dispensaryRevenue + aPats * 100;
            final bScore = b.today.donations + b.today.dispensaryRevenue + bPats * 100;
            if (bScore != aScore) {
              return bScore.compareTo(aScore);
            }
            return a.name.compareTo(b.name);
          });

        HomeBranchRow? bestBranch;
        if (sortedBranchRows.isNotEmpty) {
          final top = sortedBranchRows.first;
          final pats = top.today.zakat + top.today.nonZakat + top.today.gmwf;
          if (top.today.donations > 0 || pats > 0 || top.today.dispensaryRevenue > 0) {
            bestBranch = top;
          }
        }

        final topRow = sortedBranchRows.isNotEmpty ? sortedBranchRows.first : null;
        final topBranchId = topRow?.id ?? bestBranch?.id ?? (userBranchId.isNotEmpty ? userBranchId : 'karachi');

        void openBranchInBranchesModule(String rawBranchId) {
          String target = rawBranchId.toLowerCase().trim();
          if (target.startsWith('karachi')) {
            target = 'karachi';
          }

          final bool isAllowed = isExecutive ||
              (userBranchId.isNotEmpty &&
                  (userBranchId == target ||
                      userBranchId.startsWith(target) ||
                      target.startsWith(userBranchId)));

          if (!isAllowed) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('⚠️ Access restricted to your assigned branch (${RecentActivityService.resolveBranchName(userBranchId)}).'),
                backgroundColor: Colors.orange.shade800,
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 3),
              ),
            );
            return;
          }

          ref.read(selectedBranchTabIdProvider.notifier).state = target;

          final branchName = RecentActivityService.resolveBranchName(target);
          final branchesModule = AppModule(
            id: 'branches',
            title: 'Branches – $branchName',
            description: 'View performance and dispensary details for $branchName',
            icon: Icons.store_rounded,
            category: ModuleCategory.office,
            builder: (context, data) => Branches(
              branchId: isExecutive ? null : (userBranchId.isNotEmpty ? userBranchId : target),
              initialBranchId: target,
              isManager: false,
            ),
          );

          widget.onOpenModule(branchesModule);
        }

        final donationsTile = HomeStatTile(
          label: 'Donations Today',
          value: fmtNum(today.donations),
          prefix: 'Rs ',
          icon: Icons.volunteer_activism_rounded,
          color: const Color(0xFF10B981),
          deltaPct: yesterday.donations == 0 ? null : ((today.donations - yesterday.donations) / yesterday.donations) * 100,
          onTap: () => tryOpenModule('donations'),
        );

        final patientsTile = HomeStatTile(
          label: 'Patients Today',
          value: fmtNum(today.zakat + today.nonZakat + today.gmwf),
          icon: Icons.people_alt_rounded,
          color: const Color(0xFF8B5CF6),
          deltaPct: (yesterday.zakat + yesterday.nonZakat + yesterday.gmwf) == 0 
              ? null 
              : (((today.zakat + today.nonZakat + today.gmwf) - (yesterday.zakat + yesterday.nonZakat + yesterday.gmwf)) / 
                 (yesterday.zakat + yesterday.nonZakat + yesterday.gmwf)) * 100,
          onTap: () {
            final myBranchOrTop = (userBranchId.isNotEmpty && userBranchId != 'all') ? userBranchId : topBranchId;
            openBranchInBranchesModule(myBranchOrTop);
          },
        );

        // overallRevTile removed per request

        final madrassaTile = HomeStatTile(
          label: 'Madrassa Attendance',
          value: fmtNum(today.prescribed),
          icon: Icons.menu_book_rounded,
          color: const Color(0xFF0D9488),
          deltaPct: yesterday.prescribed == 0 ? null : ((today.prescribed - yesterday.prescribed) / yesterday.prescribed) * 100,
          onTap: () => tryOpenModule('madrassa_attendance'),
        );

        final employeeAttendanceTile = HomeStatTile(
          label: 'Staff Attendance',
          value: fmtNum(data.empPresentCount),
          icon: Icons.co_present_rounded,
          color: const Color(0xFF3F82F6),
          onTap: () => tryOpenModule('employees'),
        );

        final schoolStudentsTile = HomeStatTile(
          label: 'School Students',
          value: fmtNum(data.studentPresentCount),
          icon: Icons.school_rounded,
          color: const Color(0xFF10B981),
          onTap: () => tryOpenModule('school_attendance'),
        );

        final schoolTeachersTile = HomeStatTile(
          label: 'School Teachers',
          value: fmtNum(data.teacherPresentCount),
          icon: Icons.record_voice_over_rounded,
          color: const Color(0xFF8B5CF6),
          onTap: () => tryOpenModule('school_teacher_attendance'),
        );


        final activeBranchTile = HomeStatTile(
          label: isBranchManager ? 'Top Camp Today' : 'Top Branch Today',
          value: topRow != null ? topRow.name : RecentActivityService.resolveBranchName(userBranchId.isNotEmpty ? userBranchId : 'Karachi'),
          icon: Icons.emoji_events_rounded,
          color: const Color(0xFF0D9488),
          onTap: () => openBranchInBranchesModule(topBranchId),
        );

        final branchesSummaryTile = HomeStatTile(
          label: 'Top Branch Today',
          value: topRow != null ? topRow.name : (bestBranch != null ? bestBranch.name : 'Karachi'),
          icon: Icons.emoji_events_rounded,
          color: const Color(0xFF0D9488),
          onTap: () => openBranchInBranchesModule(topBranchId),
        );

        final dasterkhwaanTokensTile = HomeStatTile(
          label: 'Dasterkhawaan Tokens',
          value: 'Tokens',
          icon: Icons.room_service_rounded,
          color: const Color(0xFFF59E0B),
          onTap: () => tryOpenModule('office_boy'),
        );

        final dasterkhwaanStockTile = HomeStatTile(
          label: 'Dasterkhawaan Stock',
          value: 'Stock',
          icon: Icons.inventory_2_outlined,
          color: const Color(0xFFD97706),
          onTap: () => tryOpenModule('dasterkhwaan_inventory'),
        );

        final List<HomeStatTile> statTiles = [
          if (!isBranchManager) branchesSummaryTile else activeBranchTile,
          donationsTile,
          patientsTile,
          madrassaTile,
          employeeAttendanceTile,
          schoolStudentsTile,
          schoolTeachersTile,
          dasterkhwaanTokensTile,
          dasterkhwaanStockTile,
        ];

        // Layout rows with GPU layer caching via RepaintBoundary
        final row2 = SizedBox(
          height: 380,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 4, child: RepaintBoundary(child: HomeRevenueLineChart(points: data.chartPoints, t: widget.t))),
              const SizedBox(width: DS.s2),
              Expanded(flex: 3, child: RepaintBoundary(child: HomePatientsByBranchBarChart(t: widget.t, rows: data.branchRows))),
              const SizedBox(width: DS.s2),
              Expanded(
                flex: 3,
                child: RepaintBoundary(
                  child: HomeRecentActivityFeed(
                    activities: data.recentActivities,
                    t: widget.t,
                    availableModules: widget.availableModules,
                    onOpenModule: widget.onOpenModule,
                  ),
                ),
              ),
            ],
          ),
        );

        final row3 = SizedBox(
          height: 385,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 4, child: RepaintBoundary(child: HomePatientsByCategoryDonut(t: widget.t, s: today))),
              const SizedBox(width: DS.s2),
              Expanded(
                flex: 5,
                child: RepaintBoundary(
                  child: HomeBranchPerformanceTable(
                    t: widget.t,
                    rows: sortedBranchRows,
                    onTapBranch: (bId) => openBranchInBranchesModule(bId),
                  ),
                ),
              ),
              if (bestBranch != null) ...[
                const SizedBox(width: DS.s2),
                Expanded(
                  flex: 4,
                  child: RepaintBoundary(
                    child: HomeBestBranchSpotlight(
                      branchName: bestBranch.name,
                      revenue: bestBranch.today.dispensaryRevenue,
                      donations: bestBranch.today.donations,
                      patients: bestBranch.today.zakat + bestBranch.today.nonZakat + bestBranch.today.gmwf,
                      growthPct: (bestBranch.yesterday.dispensaryRevenue > 0)
                          ? (((bestBranch.today.dispensaryRevenue - bestBranch.yesterday.dispensaryRevenue) /
                                  bestBranch.yesterday.dispensaryRevenue) *
                              100)
                          : ((bestBranch.today.dispensaryRevenue > 0 || (bestBranch.today.zakat + bestBranch.today.nonZakat + bestBranch.today.gmwf) > 0) ? 100.0 : null),
                      onTap: () => openBranchInBranchesModule(bestBranch!.id),
                      t: widget.t,
                      title: isBranchManager ? 'Top Camp Today' : 'Best Branch Today',
                    ),
                  ),
                ),
              ],
            ],
          ),
        );

        final row4 = SizedBox(
          height: 295,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 3, child: HomeRecentDonationsTable(activities: data.recentActivities, t: widget.t)),
              const SizedBox(width: DS.s2),
              Expanded(flex: 4, child: HomeRecentPatientsTable(activities: data.recentActivities, t: widget.t)),
              const SizedBox(width: DS.s2),
              Expanded(flex: 3, child: QuickActionsRow(
                availableModules: widget.availableModules,
                t: widget.t,
                onOpenModule: widget.onOpenModule,
              )),
            ],
          ),
        );

        // Calculate yesterday's top branches to check if the current user/branch was rank 1, 2, or 3
        final userName = (widget.userData['name'] ?? widget.userData['username'] ?? widget.userData['fullName'] ?? '').toString().toLowerCase().trim();
        int userBranchRank = 0;
        String userBranchName = '';
        if (data.branchRows.isNotEmpty) {
          final qualifyingRows = data.branchRows.where((r) {
            final aPats = r.yesterday.zakat + r.yesterday.nonZakat + r.yesterday.gmwf;
            final aScore = r.yesterday.donations + r.yesterday.dispensaryRevenue + aPats * 100;
            return aScore > 0;
          }).toList()
            ..sort((a, b) {
              final aPats = a.yesterday.zakat + a.yesterday.nonZakat + a.yesterday.gmwf;
              final bPats = b.yesterday.zakat + b.yesterday.nonZakat + b.yesterday.gmwf;
              final aScore = a.yesterday.donations + a.yesterday.dispensaryRevenue + aPats * 100;
              final bScore = b.yesterday.donations + b.yesterday.dispensaryRevenue + bPats * 100;
              return bScore.compareTo(aScore);
            });

          for (int i = 0; i < min(3, qualifyingRows.length); i++) {
            final r = qualifyingRows[i];
            final normId = r.id.toLowerCase().trim();
            if ((userBranchId.isNotEmpty && (normId == userBranchId || normId.contains(userBranchId) || userBranchId.contains(normId))) ||
                (userName.contains('kapaya') && (normId.contains('karachi') || normId.contains('saddar') || normId.contains('kapaya')))) {
              userBranchRank = i + 1;
              userBranchName = r.name;
              break;
            }
          }
        }

        final apprecUserKey = '${widget.userData['id'] ?? widget.userData['userId'] ?? widget.userData['username'] ?? widget.userData['branchId'] ?? 'user'}_${DateFormat('yyyyMMdd').format(DateTime.now())}';

        // Show celebratory popup modal dialog once per session on startup for top branches
        if (isBranchManager && userBranchRank > 0 && !_shownAppreciationSessionKeys.contains(apprecUserKey)) {
          _shownAppreciationSessionKeys.add(apprecUserKey);
          _isAppreciationDialogShowing = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              showDialog(
                context: context,
                barrierDismissible: true,
                builder: (ctx) => AppreciationTrophyDialog(
                  rank: userBranchRank,
                  branchName: userBranchName,
                  isDark: widget.t.isDarkCanvas,
                ),
              ).then((_) {
                if (mounted) {
                  setState(() {
                    _isAppreciationDialogShowing = false;
                  });
                }
              });
            }
          });
        }

        final roleStr = (widget.userData['role'] ?? widget.userData['userRole'] ?? '').toString().toLowerCase();
        final isGlobalExecutive = roleStr.contains('ceo') || roleStr.contains('chairman') || roleStr.contains('hq') || roleStr.contains('global');
        final allLocalBranches = LocalStorageService.getLocalBranchesList();

        return ValueListenableBuilder<DashboardFilter>(
          valueListenable: dashboardController,
          builder: (context, filter, _) {
            final isFiltered = filter.timeRange != TimeRange.today ||
                (filter.branchId.isNotEmpty && filter.branchId != 'all') ||
                filter.patientType != null ||
                filter.multiDayMedicineOnly;

            final rangeLabel = filter.timeRange == TimeRange.today
                ? "Today's Snapshot"
                : "${filter.timeRange == TimeRange.yesterday ? 'Yesterday' : filter.timeRange == TimeRange.week ? 'Past 7 Days' : filter.timeRange == TimeRange.biweek ? 'Past 14 Days' : filter.timeRange == TimeRange.month ? 'Past 30 Days' : filter.timeRange == TimeRange.thisMonth ? 'This Month' : 'Custom Range'} Snapshot";

            if (isFiltered) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          rangeLabel,
                          style: TextStyle(
                            color: widget.t.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.4,
                          ),
                        ),
                        GlobalFilterBar(
                          controller: dashboardController,
                          branches: allLocalBranches,
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Builder(
                      builder: (context) {
                        final cKey = statsCacheKey(filter.branchId, filter);
                        final cachedStats = statsCacheGet(cKey);

                        return FutureBuilder<BranchStats>(
                          key: ValueKey(cKey),
                          initialData: cachedStats,
                          future: fetchBranchStats(filter.branchId, filter: filter),
                          builder: (context, snap) {
                            final s = snap.data ?? cachedStats;
                            if (s == null && snap.connectionState == ConnectionState.waiting) {
                              return DashLoadingCard(t: widget.t, height: 260);
                            }
                            final activeStats = s ?? const BranchStats();
                            final multiTiles = [
                              HomeStatTile(
                                label: 'Total Revenue',
                                value: fmtNum(activeStats.totalRevenue),
                                prefix: 'Rs ',
                                icon: Icons.payments_rounded,
                                color: const Color(0xFF10B981),
                              ),
                              HomeStatTile(
                                label: 'Donations',
                                value: fmtNum(activeStats.donations),
                                prefix: 'Rs ',
                                icon: Icons.volunteer_activism_rounded,
                                color: const Color(0xFF0D9488),
                                onTap: () => tryOpenModule('donations'),
                              ),
                              HomeStatTile(
                                label: 'Dispensary Revenue',
                                value: fmtNum(activeStats.dispensaryRevenue),
                                prefix: 'Rs ',
                                icon: Icons.local_pharmacy_rounded,
                                color: const Color(0xFF3F82F6),
                              ),
                              HomeStatTile(
                                label: 'Patients Treated',
                                value: fmtNum(activeStats.tokens),
                                icon: Icons.people_alt_rounded,
                                color: const Color(0xFF8B5CF6),
                              ),
                              HomeStatTile(
                                label: 'Zakat Patients',
                                value: fmtNum(activeStats.zakat),
                                icon: Icons.assignment_ind_rounded,
                                color: const Color(0xFFD97706),
                              ),
                              HomeStatTile(
                                label: 'Non-Zakat Patients',
                                value: fmtNum(activeStats.nonZakat),
                                icon: Icons.badge_rounded,
                                color: const Color(0xFF06B6D4),
                              ),
                              HomeStatTile(
                                label: 'Food Tokens Issued',
                                value: fmtNum(activeStats.dasterkhwaan),
                                icon: Icons.room_service_rounded,
                                color: const Color(0xFFF59E0B),
                                onTap: () => tryOpenModule('office_boy'),
                              ),
                              HomeStatTile(
                                label: 'Food Tokens Served',
                                value: fmtNum(activeStats.dasterkhwaanServed),
                                icon: Icons.restaurant_rounded,
                                color: const Color(0xFF10B981),
                              ),
                            ];

                            final filteredRow3 = SizedBox(
                              height: 385,
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    flex: 4,
                                    child: RepaintBoundary(
                                      child: HomePatientsByCategoryDonut(t: widget.t, s: activeStats),
                                    ),
                                  ),
                                  const SizedBox(width: DS.s2),
                                  Expanded(
                                    flex: 5,
                                    child: RepaintBoundary(
                                      child: HomeBranchPerformanceTable(
                                        t: widget.t,
                                        rows: sortedBranchRows,
                                        onTapBranch: (bId) => openBranchInBranchesModule(bId),
                                      ),
                                    ),
                                  ),
                                  if (bestBranch != null) ...[
                                    const SizedBox(width: DS.s2),
                                    Expanded(
                                      flex: 4,
                                      child: RepaintBoundary(
                                        child: HomeBestBranchSpotlight(
                                          branchName: bestBranch.name,
                                          revenue: bestBranch.today.dispensaryRevenue,
                                          donations: bestBranch.today.donations,
                                          patients: bestBranch.today.zakat + bestBranch.today.nonZakat + bestBranch.today.gmwf,
                                          growthPct: (bestBranch.yesterday.dispensaryRevenue > 0)
                                              ? (((bestBranch.today.dispensaryRevenue - bestBranch.yesterday.dispensaryRevenue) /
                                                      bestBranch.yesterday.dispensaryRevenue) *
                                                  100)
                                              : ((bestBranch.today.dispensaryRevenue > 0 || (bestBranch.today.zakat + bestBranch.today.nonZakat + bestBranch.today.gmwf) > 0) ? 100.0 : null),
                                          onTap: () => openBranchInBranchesModule(bestBranch!.id),
                                          t: widget.t,
                                          title: isBranchManager ? 'Top Camp Today' : 'Best Branch Today',
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            );

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                HomeStatTileRow(tiles: multiTiles),
                                const SizedBox(height: DS.s3),
                                const FirestoreQuotaMonitorWidget(),
                                const SizedBox(height: DS.s3),
                                filteredRow3,
                                const SizedBox(height: DS.s3),
                                row2,
                                const SizedBox(height: DS.s3),
                                row4,
                              ],
                            );
                          },
                        );
                      },
                    ),
                  ],
                ),
              );
            }

            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isBranchManager && userBranchRank > 0 && !_isTrophyDismissed && !_isAppreciationDialogShowing) ...[
                    BranchManagerTrophyBanner(
                      rank: userBranchRank,
                      branchName: userBranchName,
                      isDark: widget.t.isDarkCanvas,
                      onDismiss: () {
                        if (mounted) setState(() => _isTrophyDismissed = true);
                      },
                    ),
                    const SizedBox(height: DS.s3),
                  ],
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Today\'s Snapshot',
                        style: TextStyle(
                          color: widget.t.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4,
                        ),
                      ),
                      GlobalFilterBar(
                        controller: dashboardController,
                        branches: allLocalBranches,
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  if (widget.isDesktop) ...[
                HomeStatTileRow(tiles: statTiles),
                const SizedBox(height: DS.s3),
                const FirestoreQuotaMonitorWidget(),
                const SizedBox(height: DS.s3),
                row3,
                const SizedBox(height: DS.s3),
                if (!isGlobalExecutive) ...[
                  KarachiCampSnapshotWidget(t: widget.t),
                  const SizedBox(height: DS.s3),
                ],
                row2,
                const SizedBox(height: DS.s3),
                row4,
                if (isGlobalExecutive) ...[
                  const SizedBox(height: DS.s3),
                  KarachiCampSnapshotWidget(t: widget.t),
                ],
              ] else ...[
                SizedBox(
                  height: 270,
                  child: QuickActionsRow(
                    availableModules: widget.availableModules,
                    t: widget.t,
                    onOpenModule: widget.onOpenModule,
                  ),
                ),
                const SizedBox(height: DS.s2),
                HomeStatTileRow(tiles: statTiles),
                const SizedBox(height: DS.s2),
                const FirestoreQuotaMonitorWidget(),
                const SizedBox(height: DS.s2),
                if (!isGlobalExecutive) ...[
                  KarachiCampSnapshotWidget(t: widget.t),
                  const SizedBox(height: DS.s2),
                ],
                if (bestBranch != null) ...[
                  HomeBestBranchSpotlight(
                    branchName: bestBranch.name,
                    revenue: bestBranch.today.dispensaryRevenue,
                    donations: bestBranch.today.donations,
                    patients: bestBranch.today.zakat + bestBranch.today.nonZakat + bestBranch.today.gmwf,
                    growthPct: (bestBranch.yesterday.dispensaryRevenue > 0)
                        ? (((bestBranch.today.dispensaryRevenue - bestBranch.yesterday.dispensaryRevenue) /
                                bestBranch.yesterday.dispensaryRevenue) *
                            100)
                        : ((bestBranch.today.dispensaryRevenue > 0 || (bestBranch.today.zakat + bestBranch.today.nonZakat + bestBranch.today.gmwf) > 0) ? 100.0 : null),
                    onTap: () => _navigateToBranch(bestBranch!.id),
                    t: widget.t,
                    title: isBranchManager ? 'Top Camp Today' : 'Best Branch Today',
                  ),
                  const SizedBox(height: DS.s2),
                ],
                SizedBox(height: 240, child: HomePatientsByCategoryDonut(t: widget.t, s: today)),
                const SizedBox(height: DS.s2),
                HomeBranchPerformanceTable(
                  t: widget.t,
                  rows: sortedBranchRows,
                  onTapBranch: (bId) => _navigateToBranch(bId),
                ),
                const SizedBox(height: DS.s2),
                HomeRevenueLineChart(points: data.chartPoints, t: widget.t),
                const SizedBox(height: DS.s2),
                SizedBox(height: 240, child: HomePatientsByBranchBarChart(t: widget.t, rows: data.branchRows)),
                const SizedBox(height: DS.s2),
                if (isGlobalExecutive) ...[
                  KarachiCampSnapshotWidget(t: widget.t),
                  const SizedBox(height: DS.s2),
                ],
                const SizedBox(height: DS.s2),
                SizedBox(
                  height: 330,
                  child: HomeRecentActivityFeed(
                    activities: data.recentActivities,
                    t: widget.t,
                    availableModules: widget.availableModules,
                    onOpenModule: widget.onOpenModule,
                  ),
                ),
                const SizedBox(height: DS.s2),
                HomeRecentDonationsTable(activities: data.recentActivities, t: widget.t),
                const SizedBox(height: DS.s2),
                HomeRecentPatientsTable(activities: data.recentActivities, t: widget.t),
              ],
            ],
          ),
        );
      },
    );
  }

  void _navigateToBranch(String rawBranchId) {
    final normB = rawBranchId.toLowerCase().trim().replaceAll(' ', '_').replaceAll('-', '_');
    if (normB == 'karachi_saddar') {
      ref.read(selectedBranchTabIdProvider.notifier).state = 'karachi';
      ref.read(branchSubDispensaryFilterProvider.notifier).state = 'saddar';
    } else if (normB == 'karachi_haji') {
      ref.read(selectedBranchTabIdProvider.notifier).state = 'karachi';
      ref.read(branchSubDispensaryFilterProvider.notifier).state = 'haji_camp';
    } else if (normB.contains('karachi')) {
      ref.read(selectedBranchTabIdProvider.notifier).state = 'karachi';
      ref.read(branchSubDispensaryFilterProvider.notifier).state = null;
    } else if (normB.contains('jalal')) {
      ref.read(selectedBranchTabIdProvider.notifier).state = 'jalalpur_jattan';
      ref.read(branchSubDispensaryFilterProvider.notifier).state = null;
    } else if (normB.isNotEmpty && normB != 'all' && normB != 'global') {
      ref.read(selectedBranchTabIdProvider.notifier).state = normB;
      ref.read(branchSubDispensaryFilterProvider.notifier).state = null;
    }

    final branchesModule = widget.availableModules.firstWhere(
      (m) => m.id == 'branches',
      orElse: () => widget.availableModules.first,
    );
    widget.onOpenModule(branchesModule);
  }
}

// ════════════════════════════════════════════════════════════════════════
// 10. Karachi Dual-Camp Live Snapshot Widget
// ════════════════════════════════════════════════════════════════════════

class KarachiCampSnapshotWidget extends StatefulWidget {
  final RoleThemeData t;
  const KarachiCampSnapshotWidget({super.key, required this.t});

  @override
  State<KarachiCampSnapshotWidget> createState() => _KarachiCampSnapshotWidgetState();
}

class _KarachiCampSnapshotWidgetState extends State<KarachiCampSnapshotWidget> {
  late Future<KarachiCampBreakdown> _breakdownFuture;

  @override
  void initState() {
    super.initState();
    _breakdownFuture = fetchKarachiCampBreakdown();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.t.isDarkCanvas;
    return FutureBuilder<KarachiCampBreakdown>(
      future: _breakdownFuture,
      builder: (context, snapshot) {
        final data = snapshot.data ?? const KarachiCampBreakdown(
          hajiCampPatients: 0, hajiCampZakat: 0, hajiCampNonZakat: 0, hajiCampGmwf: 0,
          kapayaPatients: 0, kapayaZakat: 0, kapayaNonZakat: 0, kapayaGmwf: 0,
        );

        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: widget.t.bgCard,
            borderRadius: BorderRadius.circular(DS.r2),
            border: Border.all(color: widget.t.bgRule),
            boxShadow: Neumorphic3DStyle.raisedShadows(isDark: isDark, depth: 0.8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.location_city_rounded, color: Color(0xFF0D9488), size: 20),
                      const SizedBox(width: 8),
                      Text(
                        'Karachi Branch — Dual Dispensary Camps Breakdown',
                        style: TextStyle(
                          color: widget.t.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ],
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0D9488).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'Combined: ${data.totalPatients} Patients Today',
                      style: const TextStyle(
                        color: Color(0xFF0D9488),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _buildCampCard(
                      title: 'Saddar Dispensary',
                      total: data.kapayaPatients,
                      revenue: data.kapayaRevenue,
                      zakat: data.kapayaZakat,
                      nonZakat: data.kapayaNonZakat,
                      gmwf: data.kapayaGmwf,
                      morningTotal: data.kapayaMorningPatients,
                      morningZakat: data.kapayaMorningZakat,
                      morningNonZakat: data.kapayaMorningNonZakat,
                      morningGmwf: data.kapayaMorningGmwf,
                      eveningTotal: data.kapayaEveningPatients,
                      eveningZakat: data.kapayaEveningZakat,
                      eveningNonZakat: data.kapayaEveningNonZakat,
                      eveningGmwf: data.kapayaEveningGmwf,
                      badgeColor: const Color(0xFF7C3AED),
                      icon: Icons.local_hospital_rounded,
                      isDark: isDark,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildCampCard(
                      title: 'Haji Camp Dispensary',
                      total: data.hajiCampPatients,
                      revenue: data.hajiCampRevenue,
                      zakat: data.hajiCampZakat,
                      nonZakat: data.hajiCampNonZakat,
                      gmwf: data.hajiCampGmwf,
                      morningTotal: data.hajiCampMorningPatients,
                      morningZakat: data.hajiCampMorningZakat,
                      morningNonZakat: data.hajiCampMorningNonZakat,
                      morningGmwf: data.hajiCampMorningGmwf,
                      eveningTotal: data.hajiCampEveningPatients,
                      eveningZakat: data.hajiCampEveningZakat,
                      eveningNonZakat: data.hajiCampEveningNonZakat,
                      eveningGmwf: data.hajiCampEveningGmwf,
                      badgeColor: const Color(0xFF2563EB),
                      icon: Icons.campaign_rounded,
                      isDark: isDark,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCampCard({
    required String title,
    required int total,
    required int revenue,
    required int zakat,
    required int nonZakat,
    required int gmwf,
    required int morningTotal,
    required int morningZakat,
    required int morningNonZakat,
    required int morningGmwf,
    required int eveningTotal,
    required int eveningZakat,
    required int eveningNonZakat,
    required int eveningGmwf,
    required Color badgeColor,
    required IconData icon,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: badgeColor.withValues(alpha: isDark ? 0.15 : 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: badgeColor.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: badgeColor, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: isDark ? Colors.white : const Color(0xFF1E293B),
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '$total Patients',
                style: TextStyle(
                  color: badgeColor,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                ),
              ),
              Text(
                'Rs $revenue',
                style: const TextStyle(
                  color: Color(0xFF10B981),
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.black.withValues(alpha: 0.03),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: isDark ? Colors.white10 : Colors.black12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Morning Session Row
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.amber.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.wb_sunny_rounded, color: Colors.amber, size: 13),
                          SizedBox(width: 3),
                          Text(
                            'Morning',
                            style: TextStyle(color: Colors.amber, fontSize: 10.5, fontWeight: FontWeight.w800),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$morningTotal Patients',
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF1E293B),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.white10 : Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'Z: $morningZakat   NZ: $morningNonZakat   G: $morningGmwf',
                        style: TextStyle(
                          color: isDark ? Colors.grey.shade300 : const Color(0xFF475569),
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Divider(height: 1, color: Colors.black12),
                const SizedBox(height: 6),
                // Evening Session Row
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.indigo.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.nights_stay_rounded, color: Colors.indigoAccent, size: 13),
                          SizedBox(width: 3),
                          Text(
                            'Evening',
                            style: TextStyle(color: Colors.indigoAccent, fontSize: 10.5, fontWeight: FontWeight.w800),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$eveningTotal Patients',
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF1E293B),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.white10 : Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'Z: $eveningZakat   NZ: $eveningNonZakat   G: $eveningGmwf',
                        style: TextStyle(
                          color: isDark ? Colors.grey.shade300 : const Color(0xFF475569),
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          // Total category summary line
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(
                'Total Categories: ',
                style: TextStyle(
                  color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                'Zakat: $zakat | Non-Zakat: $nonZakat | GMWF: $gmwf',
                style: TextStyle(
                  color: badgeColor,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
