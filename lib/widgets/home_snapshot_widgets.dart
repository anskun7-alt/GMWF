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
import 'package:gmwf/design/design_system.dart';
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
import '../pages/madrassa/utils/madrassa_local_storage.dart';
import '../pages/users.dart';
import '../providers/branches_providers.dart';
import 'app_skeleton.dart';
import '../utils/branch_labels.dart';

// ════════════════════════════════════════════════════════════════════════
// Shared Nexus-inspired executive surface, header & toggle primitives
// Uses RoleThemeData + SoftPalette + Design System v2 tokens (0 raw colors)
// ════════════════════════════════════════════════════════════════════════

Color _dashSurface(RoleThemeData t) => t.bgCard;

Color _dashSubtleSurface(RoleThemeData t) => t.bgCardAlt;

Color _dashBorder(RoleThemeData t) => t.bgRule;

BoxDecoration _dashCardDecoration(
  RoleThemeData t, {
  bool hovered = false,
  Color? highlightColor,
  double radius = Gr.r4,
}) {
  final isDark = t.isDarkCanvas;
  final borderCol = hovered
      ? (highlightColor ?? t.accent).withValues(alpha: isDark ? 0.58 : 0.48)
      : _dashBorder(t);
  return BoxDecoration(
    color: _dashSurface(t),
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: borderCol, width: 1.0),
    boxShadow: hovered ? GShadow.s2(isDark) : GShadow.s1(isDark),
  );
}

class _DashCardHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final RoleThemeData t;
  final Widget? trailing;
  final bool showLiveDot;

  const _DashCardHeader({
    required this.title,
    this.subtitle,
    required this.t,
    this.trailing,
    this.showLiveDot = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = t.isDarkCanvas;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      title,
                      style: TextStyle(
                        color: t.textPrimary,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.25,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (showLiveDot) ...[
                    const SizedBox(width: 7),
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: GColor.successOf(isDark),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ],
              ),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: TextStyle(
                    color: t.textSecondary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w400,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 10),
          trailing!,
        ],
      ],
    );
  }
}

class _DashSegmentedToggle<T> extends StatelessWidget {
  final RoleThemeData t;
  final T value;
  final List<(T value, String label)> items;
  final ValueChanged<T> onChanged;

  const _DashSegmentedToggle({
    required this.t,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = t.isDarkCanvas;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: _dashSubtleSurface(t),
        borderRadius: BorderRadius.circular(Gr.r2),
        border: Border.all(color: _dashBorder(t), width: 1.0),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: items.map((item) {
          final isSel = item.$1 == value;
          return MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => onChanged(item.$1),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: isSel ? _dashSurface(t) : Colors.transparent,
                  borderRadius: BorderRadius.circular(Gr.r2 - 2),
                  boxShadow: isSel ? GShadow.s1(isDark) : GShadow.s0,
                ),
                child: Text(
                  item.$2,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: isSel ? FontWeight.w700 : FontWeight.w500,
                    color: isSel ? t.textPrimary : t.textSecondary,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _DashEmptyState extends StatelessWidget {
  final IconData icon;
  final String message;
  final String? hint;
  final RoleThemeData t;

  const _DashEmptyState({
    required this.icon,
    required this.message,
    this.hint,
    required this.t,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: _dashSubtleSurface(t),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 18, color: t.textTertiary),
            ),
            const SizedBox(height: 10),
            Text(
              message,
              style: TextStyle(
                color: t.textPrimary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            if (hint != null && hint!.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(
                hint!,
                style: TextStyle(
                  color: t.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w400,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// 1. Compact stat tile w/ clean NexusMetricCard hierarchy & honest context
// ════════════════════════════════════════════════════════════════════════

class HomeStatTile extends StatefulWidget {
  final String label;
  final String value;
  final String? prefix;
  final IconData icon;
  final String? imageAsset;
  final Color color;
  final double? deltaPct;
  final String? subtext;
  final bool isActionTile;
  final RoleThemeData? t;
  final VoidCallback? onTap;

  const HomeStatTile({
    super.key,
    required this.label,
    required this.value,
    this.prefix,
    required this.icon,
    this.imageAsset,
    required this.color,
    this.deltaPct,
    this.subtext,
    this.isActionTile = false,
    this.t,
    this.onTap,
  });

  @override
  State<HomeStatTile> createState() => _HomeStatTileState();
}

class _HomeStatTileState extends State<HomeStatTile>
    with SingleTickerProviderStateMixin {
  bool _hov = false;
  late AnimationController _pressCtrl;
  late Animation<double> _pressScale;

  @override
  void initState() {
    super.initState();
    _pressCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 100));
    _pressScale = Tween<double>(begin: 1.0, end: 0.98)
        .animate(CurvedAnimation(parent: _pressCtrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _pressCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t ?? RoleThemeScope.dataOf(context);
    final isDark = t.isDarkCanvas;
    final hasDelta = widget.deltaPct != null;
    final isUp = hasDelta && widget.deltaPct! >= 0;
    final Color deltaColor = !hasDelta
        ? t.textSecondary
        : (isUp ? GColor.successOf(isDark) : GColor.dangerOf(isDark));
    final Color categoryColor = widget.color;
    final bool isLongValue = widget.value.length > 10;

    final String? fallbackContext = () {
      if (widget.subtext != null && widget.subtext!.isNotEmpty) {
        return widget.subtext!;
      }
      if (hasDelta) return null;
      final trimmed = widget.value.trim();
      if (trimmed == '0' || trimmed == '0%' || trimmed == 'Rs 0') {
        return 'No entries today';
      }
      return 'Recorded today';
    }();

    final baseDecoration = _dashCardDecoration(
      t,
      hovered: _hov,
      highlightColor: categoryColor,
      radius: Gr.r3,
    );

    final tileContent = AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      decoration: baseDecoration.copyWith(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(
              categoryColor.withValues(alpha: _hov ? (isDark ? 0.14 : 0.065) : (isDark ? 0.07 : 0.03)),
              _dashSurface(t),
            ),
            _dashSurface(t),
          ],
        ),
        boxShadow: _hov
            ? [
                ...GShadow.s2(isDark),
                BoxShadow(
                  color: categoryColor.withValues(alpha: isDark ? 0.20 : 0.11),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ]
            : baseDecoration.boxShadow,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Gr.r3),
        child: Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 2.5,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      categoryColor.withValues(alpha: _hov ? 1.0 : 0.85),
                      categoryColor.withValues(alpha: _hov ? 0.72 : 0.45),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 11),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Top row: uppercase metadata label + bordered vivid icon square
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Text(
                          widget.label.toUpperCase(),
                          style: TextStyle(
                            color: t.textSecondary,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.45,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: categoryColor.withValues(alpha: isDark ? 0.20 : 0.13),
                          borderRadius: BorderRadius.circular(Gr.r2),
                          border: Border.all(
                            color: categoryColor.withValues(alpha: isDark ? 0.36 : 0.24),
                            width: 0.9,
                          ),
                        ),
                        child: widget.imageAsset != null
                            ? Padding(
                                padding: const EdgeInsets.all(4),
                                child: Image.asset(
                                  widget.imageAsset!,
                                  fit: BoxFit.contain,
                                  errorBuilder: (_, __, ___) => Icon(
                                    widget.icon,
                                    color: categoryColor,
                                    size: 15,
                                  ),
                                ),
                              )
                            : Icon(
                                widget.icon,
                                color: categoryColor,
                                size: 15,
                              ),
                      ),
                    ],
                  ),

                  // Center row: crisp tabular KPI figure (or compact branch name)
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
                              color: t.textSecondary,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      Expanded(
                        child: isLongValue
                            ? Text(
                                widget.value,
                                style: TextStyle(
                                  color: t.textPrimary,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.25,
                                  height: 1.15,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              )
                            : FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  widget.value,
                                  style: TextStyle(
                                    color: t.textPrimary,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.5,
                                    height: 1.05,
                                    fontFeatures: const [FontFeature.tabularFigures()],
                                  ),
                                ),
                              ),
                      ),
                    ],
                  ),

                  // Bottom row: delta trend indicator OR clear subtext context
                  Row(
                    children: [
                      if (hasDelta) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: deltaColor.withValues(alpha: isDark ? 0.16 : 0.10),
                            borderRadius: BorderRadius.circular(Gr.r1),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isUp
                                    ? Icons.trending_up_rounded
                                    : Icons.trending_down_rounded,
                                size: 11,
                                color: deltaColor,
                              ),
                              const SizedBox(width: 2.5),
                              Text(
                                '${isUp ? '+' : ''}${widget.deltaPct!.toStringAsFixed(0)}%',
                                style: TextStyle(
                                  color: deltaColor,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            'vs yesterday',
                            style: TextStyle(
                              color: t.textSecondary,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ] else ...[
                        Container(
                          width: 5,
                          height: 5,
                          decoration: BoxDecoration(
                            color: widget.isActionTile
                                ? categoryColor
                                : (widget.value.trim() == '0'
                                    ? t.textTertiary.withValues(alpha: 0.45)
                                    : categoryColor.withValues(alpha: 0.85)),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            fallbackContext ?? 'Recorded today',
                            style: TextStyle(
                              color: widget.isActionTile ? categoryColor : t.textSecondary,
                              fontSize: 10.5,
                              fontWeight: widget.isActionTile ? FontWeight.w600 : FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (widget.isActionTile)
                          Icon(
                            Icons.arrow_forward_rounded,
                            size: 12,
                            color: categoryColor,
                          ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
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
    if (tiles.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, c) {
      final int count = tiles.length;
      final int cols;
      final double extent;

      if (c.maxWidth < 600) {
        cols = 2;
        extent = 104.0;
      } else if (c.maxWidth < 960) {
        cols = (count == 8 || count == 4) ? 4 : 3;
        extent = 106.0;
      } else {
        if (count <= 3) {
          cols = count;
        } else if (count == 4 || count == 8) {
          cols = 4;
        } else {
          // 10 tiles form a balanced 5x2 grid with zero orphan gaps
          cols = 5;
        }
        extent = 108.0;
      }

      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: tiles.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          mainAxisExtent: extent,
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
      paint.color = SoftPalette.gray350.withValues(alpha: 0.18);
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
        builder: (_, _) => SizedBox(
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
        ? [SoftPalette.gray150] 
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
            _flatLegendRow(total == 0 ? SoftPalette.gray300 : t.zakat, BranchLabels.zakat(), s.zakat, zPct),
            const SizedBox(height: 10),
            _flatLegendRow(total == 0 ? SoftPalette.gray300 : t.nonZakat, BranchLabels.nonZakat(), s.nonZakat, nPct),
            const SizedBox(height: 10),
            _flatLegendRow(total == 0 ? SoftPalette.gray300 : t.gmwf, 'GMWF', s.gmwf, gPct),
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
        Expanded(child: Text(label, style: TextStyle(color: color == SoftPalette.gray300 ? SoftPalette.gray350 : SoftPalette.slate700, fontSize: 12, fontWeight: FontWeight.w600))),
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
  final String? subtitle;
  const HomeBranchRow({
    required this.id,
    required this.name,
    required this.today,
    required this.yesterday,
    this.weeklyPatients = 0,
    this.subtitle,
  });
}

class HomeBranchPerformanceTable extends StatelessWidget {
  final RoleThemeData t;
  final List<HomeBranchRow> rows; // pass pre-sorted
  final void Function(String branchId)? onTapBranch;

  const HomeBranchPerformanceTable({
    super.key,
    required this.t,
    required this.rows,
    this.onTapBranch,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = t.isDarkCanvas;
    final activeCount = rows.where((r) {
      final pats = r.today.zakat + r.today.nonZakat + r.today.gmwf;
      return pats > 0 || r.today.donations > 0 || r.today.dispensaryRevenue > 0;
    }).length;
    final liveCol = GColor.successOf(isDark);

    return Container(
      decoration: _dashCardDecoration(t, radius: Gr.r4),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isBounded = constraints.hasBoundedHeight;

          final tableBody = rows.isEmpty
              ? _DashEmptyState(
                  icon: Icons.storefront_outlined,
                  message: 'No dispensaries or camps to show',
                  hint: 'Branch activity appears here once clinics sync.',
                  t: t,
                )
              : ListView.separated(
                  shrinkWrap: !isBounded,
                  physics: isBounded
                      ? const BouncingScrollPhysics()
                      : const NeverScrollableScrollPhysics(),
                  padding: EdgeInsets.zero,
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => Divider(
                    height: 1,
                    thickness: 1,
                    color: _dashBorder(t).withValues(alpha: 0.65),
                  ),
                  itemBuilder: (context, i) {
                    final row = rows[i];

                    final don = row.today.donations;
                    final yDon = row.yesterday.donations;
                    final double? donDelta =
                        yDon == 0 ? null : ((don - yDon) / yDon) * 100;

                    final pats =
                        row.today.zakat + row.today.nonZakat + row.today.gmwf;
                    final yPats = row.yesterday.zakat +
                        row.yesterday.nonZakat +
                        row.yesterday.gmwf;
                    final double? patsDelta =
                        yPats == 0 ? null : ((pats - yPats) / yPats) * 100;

                    final rev = row.today.dispensaryRevenue;
                    final yRev = row.yesterday.dispensaryRevenue;
                    final double? revDelta =
                        yRev == 0 ? null : ((rev - yRev) / yRev) * 100;

                    return _BranchPerformanceRow(
                      rank: i + 1,
                      name: row.name,
                      don: don,
                      donDelta: donDelta,
                      pats: pats,
                      patsDelta: patsDelta,
                      rev: rev,
                      revDelta: revDelta,
                      t: t,
                      subtitle: row.subtitle,
                      onTap: onTapBranch != null
                          ? () => onTapBranch!(row.id)
                          : null,
                    );
                  },
                );

          return Column(
            mainAxisSize: isBounded ? MainAxisSize.max : MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
                child: _DashCardHeader(
                  title: 'Dispensaries & Camps',
                  subtitle: rows.isEmpty
                      ? 'Today\'s site activity'
                      : '$activeCount active of ${rows.length} sites today',
                  showLiveDot: activeCount > 0,
                  t: t,
                  trailing: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                    decoration: BoxDecoration(
                      color: liveCol.withValues(alpha: isDark ? 0.16 : 0.10),
                      borderRadius: BorderRadius.circular(Gr.rFull),
                      border: Border.all(
                        color: liveCol.withValues(alpha: isDark ? 0.35 : 0.25),
                      ),
                    ),
                    child: Text(
                      'LIVE FEED',
                      style: TextStyle(
                        color: liveCol,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ),
                ),
              ),
              Divider(height: 1, thickness: 1, color: _dashBorder(t)),
              // Column header strip (Nexus table style)
              Container(
                color: _dashSubtleSurface(t),
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      flex: 5,
                      child: Text(
                        'DISPENSARY / CAMP',
                        style: TextStyle(
                          color: t.textSecondary,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.55,
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Center(
                        child: Text(
                          'DONATIONS',
                          style: TextStyle(
                            color: t.textSecondary,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Center(
                        child: Text(
                          'PATIENTS',
                          style: TextStyle(
                            color: t.textSecondary,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Center(
                        child: Text(
                          'REVENUE',
                          style: TextStyle(
                            color: t.textSecondary,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, thickness: 1, color: _dashBorder(t)),
              if (isBounded) Expanded(child: tableBody) else tableBody,
              if (onTapBranch != null) ...[
                Divider(height: 1, thickness: 1, color: _dashBorder(t)),
                InkWell(
                  onTap: () => onTapBranch!('all'),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'View all branches',
                          style: TextStyle(
                            color: t.accent,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.arrow_forward_rounded,
                          color: t.accent,
                          size: 13,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          );
        },
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
  final RoleThemeData t;
  final String? subtitle;
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
    required this.t,
    this.subtitle,
    this.onTap,
  });

  @override
  State<_BranchPerformanceRow> createState() => _BranchPerformanceRowState();
}

class _BranchPerformanceRowState extends State<_BranchPerformanceRow> {
  bool _hov = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    final isDark = t.isDarkCanvas;
    final hasActivity = widget.pats > 0 || widget.don > 0 || widget.rev > 0;

    return MouseRegion(
      onEnter: (_) => setState(() => _hov = true),
      onExit: (_) => setState(() => _hov = false),
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          color: _hov
              ? _dashSubtleSurface(t).withValues(alpha: isDark ? 0.65 : 0.75)
              : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
          child: Row(
            children: [
              // Branch name with rank
              Expanded(
                flex: 5,
                child: Row(
                  children: [
                    _RankBadge(rank: widget.rank, t: t),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 6,
                                height: 6,
                                margin: const EdgeInsets.only(right: 6),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: hasActivity
                                      ? GColor.successOf(isDark)
                                      : t.textTertiary.withValues(alpha: 0.45),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  widget.name,
                                  style: TextStyle(
                                    color: hasActivity
                                        ? t.textPrimary
                                        : t.textSecondary,
                                    fontSize: 12.5,
                                    fontWeight: hasActivity
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          if (widget.subtitle != null &&
                              widget.subtitle!.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2, left: 12),
                              child: Text(
                                widget.subtitle!,
                                style: TextStyle(
                                  color: t.textSecondary,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w500,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // Donations
              Expanded(
                flex: 2,
                child: _metricCell(
                  fmtNum(widget.don),
                  widget.don > 0,
                  widget.donDelta,
                  t,
                ),
              ),
              // Patients
              Expanded(
                flex: 2,
                child: _metricCell(
                  fmtNum(widget.pats),
                  widget.pats > 0,
                  widget.patsDelta,
                  t,
                ),
              ),
              // Revenue
              Expanded(
                flex: 2,
                child: _metricCell(
                  fmtNum(widget.rev),
                  widget.rev > 0,
                  widget.revDelta,
                  t,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _metricCell(
    String formatted,
    bool nonZero,
    double? delta,
    RoleThemeData t,
  ) {
    final isDark = t.isDarkCanvas;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            formatted,
            style: TextStyle(
              color: nonZero ? t.textPrimary : t.textTertiary,
              fontSize: 12.5,
              fontWeight: nonZero ? FontWeight.w700 : FontWeight.w500,
              fontFeatures: const [ui.FontFeature.tabularFigures()],
            ),
          ),
          if (delta != null) _deltaIndicator(delta, isDark),
        ],
      ),
    );
  }

  Widget _deltaIndicator(double delta, bool isDark) {
    final isUp = delta >= 0;
    final color = isUp ? GColor.successOf(isDark) : GColor.dangerOf(isDark);
    return Container(
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.16 : 0.10),
        borderRadius: BorderRadius.circular(Gr.r1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isUp ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
            size: 8.5,
            color: color,
          ),
          const SizedBox(width: 1.5),
          Text(
            '${delta.abs().toStringAsFixed(0)}%',
            style: TextStyle(
              color: color,
              fontSize: 8.5,
              fontWeight: FontWeight.w700,
              fontFeatures: const [ui.FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _RankBadge extends StatelessWidget {
  final int rank;
  final RoleThemeData t;
  const _RankBadge({required this.rank, required this.t});

  @override
  Widget build(BuildContext context) {
    final isDark = t.isDarkCanvas;

    if (rank <= 3) {
      final Color tone = switch (rank) {
        1 => isDark ? SoftPalette.brightGold : SoftPalette.warmMarigold,
        2 => isDark ? SoftPalette.brightCobalt : SoftPalette.cobaltBlue,
        _ => isDark ? SoftPalette.brightCoral : SoftPalette.roseCoral,
      };
      return Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Gr.r2),
          color: tone.withValues(alpha: isDark ? 0.18 : 0.12),
          border: Border.all(
            color: tone.withValues(alpha: isDark ? 0.45 : 0.35),
            width: 1.0,
          ),
        ),
        child: Center(
          child: Icon(
            Icons.emoji_events_rounded,
            color: tone,
            size: 13.5,
          ),
        ),
      );
    }

    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Gr.r2),
        color: _dashSubtleSurface(t),
        border: Border.all(color: _dashBorder(t), width: 1.0),
      ),
      child: Center(
        child: Text(
          '$rank',
          style: TextStyle(
            color: t.textSecondary,
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            fontFeatures: const [ui.FontFeature.tabularFigures()],
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
  State<HomeBestBranchSpotlight> createState() =>
      _HomeBestBranchSpotlightState();
}

class _HomeBestBranchSpotlightState extends State<HomeBestBranchSpotlight> {
  bool _hov = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.t ?? RoleThemeScope.dataOf(context);
    final isDark = t.isDarkCanvas;
    final hasGrowth = widget.growthPct != null;
    final isUp = hasGrowth && widget.growthPct! >= 0;
    final amberTone = isDark ? SoftPalette.brightGold : SoftPalette.warmMarigold;
    final patientsTone = isDark ? SoftPalette.brightCobalt : SoftPalette.cobaltBlue;
    final donationsTone = isDark ? SoftPalette.brightCoral : SoftPalette.roseCoral;
    final successCol = GColor.successOf(isDark);
    final dangerCol = GColor.dangerOf(isDark);

    final growthText = hasGrowth
        ? '${isUp ? '+' : ''}${widget.growthPct!.toStringAsFixed(0)}%'
        : (widget.revenue > 0 || widget.patients > 0 ? '+100%' : '0%');
    final growthSub = hasGrowth
        ? 'vs yesterday'
        : (widget.revenue > 0 || widget.patients > 0 ? 'Active today' : 'Steady');
    final growthColor = hasGrowth
        ? (isUp ? successCol : dangerCol)
        : (widget.revenue > 0 || widget.patients > 0
            ? successCol
            : t.textSecondary);

    return MouseRegion(
      onEnter: (_) => setState(() => _hov = true),
      onExit: (_) => setState(() => _hov = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: _dashSurface(t),
            borderRadius: BorderRadius.circular(Gr.r4),
            border: Border.all(
              color: _hov
                  ? amberTone.withValues(alpha: isDark ? 0.72 : 0.75)
                  : amberTone.withValues(alpha: isDark ? 0.35 : 0.42),
              width: _hov ? 1.3 : 1.0,
            ),
            boxShadow: _hov ? GShadow.s2(isDark) : GShadow.s1(isDark),
          ),
          clipBehavior: Clip.antiAlias,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isBounded = constraints.hasBoundedHeight;
              return Column(
                mainAxisSize: isBounded ? MainAxisSize.max : MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.fromLTRB(18, 15, 18, 14),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          amberTone.withValues(alpha: isDark ? 0.14 : 0.11),
                          amberTone.withValues(alpha: isDark ? 0.04 : 0.025),
                        ],
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: amberTone
                                      .withValues(alpha: isDark ? 0.22 : 0.14),
                                  borderRadius: BorderRadius.circular(Gr.rFull),
                                  border: Border.all(
                                    color: amberTone
                                        .withValues(alpha: isDark ? 0.45 : 0.38),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.star_rounded,
                                        color: amberTone, size: 11),
                                    const SizedBox(width: 4),
                                    Text(
                                      '#1 TOP PERFORMER',
                                      style: TextStyle(
                                        color: amberTone,
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 0.6,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                widget.branchName,
                                style: TextStyle(
                                  color: t.textPrimary,
                                  fontSize: 15.5,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.3,
                                  height: 1.2,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                widget.title,
                                style: TextStyle(
                                  color: t.textSecondary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        AnimatedRotation(
                          turns: _hov ? 0.03 : 0,
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOutBack,
                          child: Container(
                            width: 46,
                            height: 46,
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: _dashSurface(t),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: amberTone
                                    .withValues(alpha: isDark ? 0.50 : 0.55),
                                width: 1.2,
                              ),
                            ),
                            child: RepaintBoundary(
                              child: Lottie.asset(
                                'assets/animations/Trophy.json',
                                fit: BoxFit.contain,
                                repeat: !GDecor.reduceMotion,
                                errorBuilder: (_, _, _) => Icon(
                                  Icons.emoji_events_rounded,
                                  color: amberTone,
                                  size: 24,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Divider(height: 1, thickness: 1, color: _dashBorder(t)),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: _metricCell(
                                t: t,
                                icon: Icons.payments_rounded,
                                label: 'REVENUE',
                                value: fmtPKR(widget.revenue),
                                accentColor: successCol,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _metricCell(
                                t: t,
                                icon: Icons.people_alt_rounded,
                                label: 'PATIENTS',
                                value: fmtNum(widget.patients),
                                accentColor: patientsTone,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: _metricCell(
                                t: t,
                                icon: Icons.volunteer_activism_rounded,
                                label: 'DONATIONS',
                                value: fmtPKR(widget.donations),
                                accentColor: donationsTone,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _metricCell(
                                t: t,
                                icon: isUp
                                    ? Icons.trending_up_rounded
                                    : (hasGrowth
                                        ? Icons.trending_down_rounded
                                        : Icons.trending_up_rounded),
                                label: 'VS YESTERDAY',
                                value: growthText,
                                subtext: growthSub,
                                accentColor: growthColor,
                                valueColor: growthColor,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (isBounded) const Spacer(),
                  Divider(height: 1, thickness: 1, color: _dashBorder(t)),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'Inspect branch details',
                          style: TextStyle(
                            color: _hov ? t.accent : t.textSecondary,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.arrow_forward_rounded,
                          color: _hov ? t.accent : t.textSecondary,
                          size: 13,
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _metricCell({
    required RoleThemeData t,
    required IconData icon,
    required String label,
    required String value,
    required Color accentColor,
    Color? valueColor,
    String? subtext,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        color: _dashSubtleSurface(t),
        borderRadius: BorderRadius.circular(Gr.r3),
        border: Border.all(color: _dashBorder(t), width: 1.0),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 12.5, color: accentColor),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: t.textSecondary,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.45,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            value,
            style: TextStyle(
              color: valueColor ?? t.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.25,
              fontFeatures: const [ui.FontFeature.tabularFigures()],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (subtext != null) ...[
            const SizedBox(height: 1),
            Text(
              subtext,
              style: TextStyle(
                color: t.textTertiary,
                fontSize: 9.5,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

class HomePatientsByCategoryDonut extends StatelessWidget {
  final RoleThemeData t;
  final BranchStats s;

  const HomePatientsByCategoryDonut({
    super.key,
    required this.t,
    required this.s,
  });

  @override
  Widget build(BuildContext context) {
    final int total = s.zakat + s.nonZakat + s.gmwf;
    final bool isDark = t.isDarkCanvas;
    final zakatCol = isDark ? SoftPalette.brightMint : SoftPalette.jadeEmerald;
    final nonZakatCol = isDark ? SoftPalette.brightCobalt : SoftPalette.cobaltBlue;
    final gmwfCol = isDark ? SoftPalette.brightGold : SoftPalette.warmMarigold;
    final successCol = GColor.successOf(isDark);

    return Container(
      decoration: _dashCardDecoration(t, radius: Gr.r4),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isBounded = constraints.hasBoundedHeight;
          final isNarrow = constraints.maxWidth < 285;
          final double donutSize = isNarrow
              ? 118.0
              : (constraints.maxWidth * 0.34).clamp(96.0, 140.0);

          final donutRing = SizedBox(
            width: donutSize,
            height: donutSize,
            child: CustomPaint(
              painter: _DonutChartPainter(
                zakat: s.zakat.toDouble(),
                nonZakat: s.nonZakat.toDouble(),
                gmwf: s.gmwf.toDouble(),
                total: total.toDouble(),
                isDark: isDark,
                trackColor: _dashSubtleSurface(t),
                zakatColor: zakatCol,
                nonZakatColor: nonZakatCol,
                gmwfColor: gmwfCol,
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      fmtNum(total),
                      style: TextStyle(
                        color: t.textPrimary,
                        fontSize: donutSize < 112 ? 19 : 22,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5,
                        height: 1.05,
                        fontFeatures: const [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Patients',
                      style: TextStyle(
                        color: t.textSecondary,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );

          final breakdownColumn = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _categoryProgressRow(
                label: BranchLabels.zakat(),
                val: s.zakat,
                total: total,
                color: zakatCol,
              ),
              const SizedBox(height: 7),
              _categoryProgressRow(
                label: BranchLabels.nonZakat(),
                val: s.nonZakat,
                total: total,
                color: nonZakatCol,
              ),
              const SizedBox(height: 7),
              _categoryProgressRow(
                label: 'GMWF',
                val: s.gmwf,
                total: total,
                color: gmwfCol,
              ),
            ],
          );

          final bodyContent = total == 0
              ? _DashEmptyState(
                  icon: Icons.pie_chart_outline_rounded,
                  message: 'No patient data in this period',
                  hint: 'Patient category shares will chart here.',
                  t: t,
                )
              : Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: isNarrow
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            donutRing,
                            const SizedBox(height: 12),
                            breakdownColumn,
                          ],
                        )
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(flex: 6, child: breakdownColumn),
                            const SizedBox(width: 12),
                            Expanded(flex: 4, child: Center(child: donutRing)),
                          ],
                        ),
                );

          return Column(
            mainAxisSize: isBounded ? MainAxisSize.max : MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
                child: _DashCardHeader(
                  title: 'Patients by Category',
                  subtitle: 'Token category share',
                  t: t,
                  trailing: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                    decoration: BoxDecoration(
                      color:
                          successCol.withValues(alpha: isDark ? 0.16 : 0.10),
                      borderRadius: BorderRadius.circular(Gr.rFull),
                      border: Border.all(
                        color:
                            successCol.withValues(alpha: isDark ? 0.35 : 0.25),
                      ),
                    ),
                    child: Text(
                      '$total TOTAL',
                      style: TextStyle(
                        color: successCol,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                        fontFeatures: const [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
              ),
              Divider(height: 1, thickness: 1, color: _dashBorder(t)),
              if (isBounded)
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      physics: const ClampingScrollPhysics(),
                      child: bodyContent,
                    ),
                  ),
                )
              else
                bodyContent,
              Divider(height: 1, thickness: 1, color: _dashBorder(t)),
              Container(
                color: _dashSubtleSurface(t),
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Token Fee Revenue',
                      style: TextStyle(
                        color: t.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      fmtPKR(s.dispensaryRevenue),
                      style: TextStyle(
                        color: s.dispensaryRevenue > 0
                            ? successCol
                            : t.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        fontFeatures: const [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _categoryProgressRow({
    required String label,
    required int val,
    required int total,
    required Color color,
  }) {
    final bool isDark = t.isDarkCanvas;
    final double ratio = total == 0 ? 0.0 : (val / total).clamp(0.0, 1.0);
    final double pct = ratio * 100;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: _dashSubtleSurface(t),
        borderRadius: BorderRadius.circular(Gr.r2),
        border: Border.all(color: _dashBorder(t), width: 1.0),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: t.textPrimary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                fmtNum(val),
                style: TextStyle(
                  color: val > 0 ? t.textPrimary : t.textTertiary,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  fontFeatures: const [ui.FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5.5, vertical: 1.5),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: isDark ? 0.18 : 0.12),
                  borderRadius: BorderRadius.circular(Gr.r1),
                ),
                child: Text(
                  '${pct.toStringAsFixed(0)}%',
                  style: TextStyle(
                    color: color,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [ui.FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(Gr.r1),
            child: Container(
              height: 4,
              color: _dashSurface(t),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: ratio,
                child: Container(
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(Gr.r1),
                  ),
                ),
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
  final Color trackColor;
  final Color zakatColor;
  final Color nonZakatColor;
  final Color gmwfColor;

  _DonutChartPainter({
    required this.zakat,
    required this.nonZakat,
    required this.gmwf,
    required this.total,
    required this.isDark,
    required this.trackColor,
    required this.zakatColor,
    required this.nonZakatColor,
    required this.gmwfColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = min(size.width, size.height) / 2;
    final strokeW = (radius * 0.22).clamp(11.0, 15.0);
    final rect =
        Rect.fromCircle(center: center, radius: radius - strokeW / 2 - 2);

    final paintTrack = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeW
      ..strokeCap = StrokeCap.butt;

    canvas.drawArc(rect, 0, 2 * pi, false, paintTrack);

    if (total <= 0) return;

    final segments = <(double value, Color color)>[
      if (zakat > 0) (zakat, zakatColor),
      if (nonZakat > 0) (nonZakat, nonZakatColor),
      if (gmwf > 0) (gmwf, gmwfColor),
    ];

    if (segments.isEmpty) return;

    if (segments.length == 1) {
      final paintSingle = Paint()
        ..color = segments.first.$2
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeW
        ..strokeCap = StrokeCap.butt;
      canvas.drawArc(rect, -pi / 2, 2 * pi, false, paintSingle);
      return;
    }

    const gap = 0.06;
    double startAngle = -pi / 2;
    for (final seg in segments) {
      final fullSweep = (seg.$1 / total) * 2 * pi;
      final drawSweep = (fullSweep - gap).clamp(0.03, 2 * pi);
      final paintSeg = Paint()
        ..color = seg.$2
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeW
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(rect, startAngle + gap / 2, drawSweep, false, paintSeg);
      startAngle += fullSweep;
    }
  }

  @override
  bool shouldRepaint(_DonutChartPainter oldDelegate) =>
      oldDelegate.zakat != zakat ||
      oldDelegate.nonZakat != nonZakat ||
      oldDelegate.gmwf != gmwf ||
      oldDelegate.total != total ||
      oldDelegate.isDark != isDark ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.zakatColor != zakatColor ||
      oldDelegate.nonZakatColor != nonZakatColor ||
      oldDelegate.gmwfColor != gmwfColor;
}

class HomeRecentDonationsTable extends StatelessWidget {
  final List<RecentActivity> activities;
  final RoleThemeData t;
  final VoidCallback? onViewAll;

  const HomeRecentDonationsTable({
    super.key,
    required this.activities,
    required this.t,
    this.onViewAll,
  });

  @override
  Widget build(BuildContext context) {
    final donations = activities.where((a) => a.type == 'donation').toList();
    final bool isDark = t.isDarkCanvas;
    final successCol = GColor.successOf(isDark);

    return Container(
      decoration: _dashCardDecoration(t, radius: Gr.r4),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isBounded = constraints.hasBoundedHeight;
          final rowsList = donations.isEmpty
              ? _DashEmptyState(
                  icon: Icons.volunteer_activism_outlined,
                  message: 'No recent donations',
                  hint: 'New donor receipts appear here.',
                  t: t,
                )
              : ListView.separated(
                  shrinkWrap: !isBounded,
                  physics: isBounded
                      ? const BouncingScrollPhysics()
                      : const NeverScrollableScrollPhysics(),
                  padding: EdgeInsets.zero,
                  itemCount: min(5, donations.length),
                  separatorBuilder: (_, _) => Divider(
                    height: 1,
                    thickness: 1,
                    color: _dashBorder(t).withValues(alpha: 0.65),
                  ),
                  itemBuilder: (context, index) {
                    final a = donations[index];
                    final match = RegExp(r'Received from ([^(]+)')
                        .firstMatch(a.subtitle);
                    final donorName = match?.group(1)?.trim() ?? 'Walk-in Donor';
                    final amt = a.amount ?? 0.0;
                    final timeStr = DateFormat('hh:mm a').format(a.timestamp);

                    return Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 9),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: Text(
                              donorName,
                              style: TextStyle(
                                color: t.textPrimary,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Center(
                              child: Text(
                                'Rs ${fmtNum(amt.toInt())}',
                                style: TextStyle(
                                  color: successCol,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                  fontFeatures: const [
                                    ui.FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 3,
                            child: Text(
                              a.branchName,
                              style: TextStyle(
                                color: t.textSecondary,
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Center(
                              child: Text(
                                timeStr,
                                style: TextStyle(
                                  color: t.textTertiary,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w500,
                                  fontFeatures: const [
                                    ui.FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );

          return Column(
            mainAxisSize: isBounded ? MainAxisSize.max : MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 13, 16, 11),
                child: _DashCardHeader(
                  title: 'Recent Donations',
                  t: t,
                  trailing: onViewAll != null
                      ? InkWell(
                          onTap: onViewAll,
                          borderRadius: BorderRadius.circular(Gr.r1),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 2),
                            child: Text(
                              'View all →',
                              style: TextStyle(
                                color: t.accent,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        )
                      : null,
                ),
              ),
              Divider(height: 1, thickness: 1, color: _dashBorder(t)),
              Container(
                color: _dashSubtleSurface(t),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: Text(
                        'DONOR',
                        style: TextStyle(
                          color: t.textSecondary,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Center(
                        child: Text(
                          'AMOUNT',
                          style: TextStyle(
                            color: t.textSecondary,
                            fontSize: 9.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: Text(
                        'BRANCH',
                        style: TextStyle(
                          color: t.textSecondary,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Center(
                        child: Text(
                          'TIME',
                          style: TextStyle(
                            color: t.textSecondary,
                            fontSize: 9.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, thickness: 1, color: _dashBorder(t)),
              if (isBounded) Expanded(child: rowsList) else rowsList,
            ],
          );
        },
      ),
    );
  }
}

class HomeRecentPatientsTable extends StatelessWidget {
  final List<RecentActivity> activities;
  final RoleThemeData t;
  final VoidCallback? onViewAll;

  const HomeRecentPatientsTable({
    super.key,
    required this.activities,
    required this.t,
    this.onViewAll,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = activities.where((a) => a.type == 'token').toList();
    final bool isDark = t.isDarkCanvas;

    return Container(
      decoration: _dashCardDecoration(t, radius: Gr.r4),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isBounded = constraints.hasBoundedHeight;
          final rowsList = tokens.isEmpty
              ? _DashEmptyState(
                  icon: Icons.medical_services_outlined,
                  message: 'No recent patients',
                  hint: 'Patient tokens issued today appear here.',
                  t: t,
                )
              : ListView.separated(
                  shrinkWrap: !isBounded,
                  physics: isBounded
                      ? const BouncingScrollPhysics()
                      : const NeverScrollableScrollPhysics(),
                  padding: EdgeInsets.zero,
                  itemCount: min(5, tokens.length),
                  separatorBuilder: (_, _) => Divider(
                    height: 1,
                    thickness: 1,
                    color: _dashBorder(t).withValues(alpha: 0.65),
                  ),
                  itemBuilder: (context, index) {
                    final a = tokens[index];
                    final match = RegExp(r'Patient: ([^\(]+)\s*\(([^)]+)\)')
                        .firstMatch(a.subtitle);
                    final pName = match?.group(1)?.trim() ?? 'Patient';
                    final rawCat = match?.group(2)?.trim() ?? 'ZAKAT';
                    final category = BranchLabels.text(rawCat);

                    final hash = a.id.hashCode.abs() % 10000;
                    final pId = 'P-${hash.toString().padLeft(5, '0')}';

                    final timeStr = DateFormat('hh:mm a').format(a.timestamp);

                    Color catColor =
                        isDark ? SoftPalette.brightMint : SoftPalette.jadeEmerald;
                    if (rawCat.toLowerCase().contains('non')) {
                      catColor = isDark
                          ? SoftPalette.brightCobalt
                          : SoftPalette.cobaltBlue;
                    } else if (rawCat.toLowerCase().contains('gmwf')) {
                      catColor = isDark
                          ? SoftPalette.brightGold
                          : SoftPalette.warmMarigold;
                    }

                    return Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  pName,
                                  style: TextStyle(
                                    color: t.textPrimary,
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  pId,
                                  style: TextStyle(
                                    color: t.textTertiary,
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w500,
                                    fontFeatures: const [
                                      ui.FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 7, vertical: 2.5),
                                decoration: BoxDecoration(
                                  color: catColor
                                      .withValues(alpha: isDark ? 0.18 : 0.11),
                                  borderRadius: BorderRadius.circular(Gr.r1),
                                  border: Border.all(
                                    color: catColor
                                        .withValues(alpha: isDark ? 0.35 : 0.25),
                                  ),
                                ),
                                child: Text(
                                  category,
                                  style: TextStyle(
                                    color: catColor,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 3,
                            child: Text(
                              a.branchName,
                              style: TextStyle(
                                color: t.textSecondary,
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Center(
                              child: Text(
                                timeStr,
                                style: TextStyle(
                                  color: t.textTertiary,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w500,
                                  fontFeatures: const [
                                    ui.FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );

          return Column(
            mainAxisSize: isBounded ? MainAxisSize.max : MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 13, 16, 11),
                child: _DashCardHeader(
                  title: 'Recent Patients',
                  t: t,
                  trailing: onViewAll != null
                      ? InkWell(
                          onTap: onViewAll,
                          borderRadius: BorderRadius.circular(Gr.r1),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 2),
                            child: Text(
                              'View all →',
                              style: TextStyle(
                                color: t.accent,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        )
                      : null,
                ),
              ),
              Divider(height: 1, thickness: 1, color: _dashBorder(t)),
              Container(
                color: _dashSubtleSurface(t),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: Text(
                        'PATIENT',
                        style: TextStyle(
                          color: t.textSecondary,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Center(
                        child: Text(
                          'CATEGORY',
                          style: TextStyle(
                            color: t.textSecondary,
                            fontSize: 9.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: Text(
                        'BRANCH',
                        style: TextStyle(
                          color: t.textSecondary,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Center(
                        child: Text(
                          'TIME',
                          style: TextStyle(
                            color: t.textSecondary,
                            fontSize: 9.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, thickness: 1, color: _dashBorder(t)),
              if (isBounded) Expanded(child: rowsList) else rowsList,
            ],
          );
        },
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// 5. Patients Revenue Line Chart (CustomPainter)
// ════════════════════════════════════════════════════════════════════════

enum _TrendViewMode { indexed, financials, volume }

enum _TrendSeriesId { donations, patientsRev, tokens, staff }

class HomeRevenueLineChart extends StatefulWidget {
  final List<HomeLineChartPoint> points;
  final RoleThemeData t;
  const HomeRevenueLineChart({
    super.key,
    required this.points,
    required this.t,
  });

  @override
  State<HomeRevenueLineChart> createState() => _HomeRevenueLineChartState();
}

class _HomeRevenueLineChartState extends State<HomeRevenueLineChart> {
  static const double _leftMargin = 48.0;
  static const double _rightMargin = 16.0;

  int? hoveredIndex;
  _TrendViewMode _mode = _TrendViewMode.indexed;
  final Set<_TrendSeriesId> _hidden = {};

  List<_TrendSeriesId> get _activeModeSeries => switch (_mode) {
        _TrendViewMode.indexed => const [
            _TrendSeriesId.donations,
            _TrendSeriesId.patientsRev,
            _TrendSeriesId.tokens,
            _TrendSeriesId.staff,
          ],
        _TrendViewMode.financials => const [
            _TrendSeriesId.donations,
            _TrendSeriesId.patientsRev,
          ],
        _TrendViewMode.volume => const [
            _TrendSeriesId.tokens,
            _TrendSeriesId.staff,
          ],
      };

  void _toggleSeries(_TrendSeriesId id) {
    setState(() {
      if (_hidden.contains(id)) {
        _hidden.remove(id);
      } else {
        final visibleInMode =
            _activeModeSeries.where((s) => !_hidden.contains(s)).length;
        if (visibleInMode > 1) {
          _hidden.add(id);
        }
      }
    });
  }

  void _updateHover(double localDx, double width) {
    if (widget.points.isEmpty) return;
    if (widget.points.length == 1) {
      if (hoveredIndex != 0) setState(() => hoveredIndex = 0);
      return;
    }
    final chartW = max(1.0, width - _leftMargin - _rightMargin);
    final relX = (localDx - _leftMargin).clamp(0.0, chartW);
    final stepX = chartW / (widget.points.length - 1);
    final idx = (relX / stepX).round().clamp(0, widget.points.length - 1);
    if (hoveredIndex != idx) {
      setState(() => hoveredIndex = idx);
    }
  }

  String _seriesLatestValue(_TrendSeriesId id, HomeLineChartPoint pt) =>
      switch (id) {
        _TrendSeriesId.donations => fmtPKR(pt.donations),
        _TrendSeriesId.patientsRev => fmtPKR(pt.patientsRevenue),
        _TrendSeriesId.tokens => fmtNum(pt.tokens),
        _TrendSeriesId.staff => fmtNum(pt.employeesPresent),
      };

  String _seriesLabel(_TrendSeriesId id) => switch (id) {
        _TrendSeriesId.donations => 'Donations',
        _TrendSeriesId.patientsRev => 'Patients Rev',
        _TrendSeriesId.tokens => 'Tokens',
        _TrendSeriesId.staff => 'Staff',
      };

  Color _seriesColor(_TrendSeriesId id) {
    final isDark = widget.t.isDarkCanvas;
    return switch (id) {
      _TrendSeriesId.donations =>
        isDark ? SoftPalette.brightMint : SoftPalette.jadeEmerald,
      _TrendSeriesId.patientsRev => widget.t.accent,
      _TrendSeriesId.tokens =>
        isDark ? SoftPalette.brightCobalt : SoftPalette.cobaltBlue,
      _TrendSeriesId.staff =>
        isDark ? SoftPalette.softLavender : SoftPalette.royalViolet,
    };
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    final bool isDark = t.isDarkCanvas;

    return Container(
      decoration: _dashCardDecoration(t, radius: Gr.r4),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isBounded = constraints.hasBoundedHeight;

          if (widget.points.isEmpty) {
            return Column(
              mainAxisSize: isBounded ? MainAxisSize.max : MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
                  child: _DashCardHeader(
                    title: 'Monthly Progress Trends',
                    subtitle: '5-month trajectory',
                    t: t,
                  ),
                ),
                Divider(height: 1, thickness: 1, color: _dashBorder(t)),
                if (isBounded)
                  Expanded(
                    child: _DashEmptyState(
                      icon: Icons.show_chart_rounded,
                      message: 'No monthly trend points yet',
                      hint: 'Historical metrics populate after daily records sync.',
                      t: t,
                    ),
                  )
                else
                  _DashEmptyState(
                    icon: Icons.show_chart_rounded,
                    message: 'No monthly trend points yet',
                    hint: 'Historical metrics populate after daily records sync.',
                    t: t,
                  ),
              ],
            );
          }

          final double maxMoney = max(
                100.0,
                max(
                  widget.points
                      .map((p) => p.patientsRevenue.toDouble())
                      .reduce(max),
                  widget.points.map((p) => p.donations.toDouble()).reduce(max),
                ),
              ) *
              1.15;

          final double maxTokens = max(
                10.0,
                widget.points.map((p) => p.tokens.toDouble()).reduce(max),
              ) *
              1.15;

          final double maxEmployees = max(
                10.0,
                widget.points
                    .map((p) => p.employeesPresent.toDouble())
                    .reduce(max),
              ) *
              1.15;

          final double maxVolume = max(maxTokens, maxEmployees);

          final activeIdx =
              (hoveredIndex != null && hoveredIndex! < widget.points.length)
                  ? hoveredIndex!
                  : widget.points.length - 1;
          final refPoint = widget.points[activeIdx];
          final refMonthLabel = hoveredIndex != null
              ? '${DateFormat('MMM yyyy').format(refPoint.date)} (hover)'
              : '${DateFormat('MMM yyyy').format(refPoint.date)} latest · ${switch (_mode) {
                  _TrendViewMode.indexed => 'Normalized %',
                  _TrendViewMode.financials => 'PKR Scale',
                  _TrendViewMode.volume => 'Headcount / Tokens',
                }}';

          final canvasWidget = LayoutBuilder(
            builder: (context, chartConstraints) {
              final width = chartConstraints.maxWidth;
              final height = chartConstraints.maxHeight;

              return MouseRegion(
                onHover: (ev) => _updateHover(ev.localPosition.dx, width),
                onExit: (_) {
                  if (hoveredIndex != null) {
                    setState(() => hoveredIndex = null);
                  }
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (details) =>
                      _updateHover(details.localPosition.dx, width),
                  onPanEnd: (_) => setState(() => hoveredIndex = null),
                  onTapDown: (details) =>
                      _updateHover(details.localPosition.dx, width),
                  child: CustomPaint(
                    size: Size(width, height),
                    painter: _MultiLineChartPainter(
                      points: widget.points,
                      accentColor: t.accent,
                      donationsColor: _seriesColor(_TrendSeriesId.donations),
                      tokensColor: _seriesColor(_TrendSeriesId.tokens),
                      staffColor: _seriesColor(_TrendSeriesId.staff),
                      maxMoney: maxMoney,
                      maxTokens: maxTokens,
                      maxEmployees: maxEmployees,
                      maxVolume: maxVolume,
                      mode: _mode,
                      hiddenSeries: _hidden,
                      hoveredIndex: hoveredIndex,
                      isDark: isDark,
                      gridColor: _dashBorder(t),
                      labelColor: t.textSecondary,
                      surfaceColor: _dashSurface(t),
                    ),
                  ),
                ),
              );
            },
          );

          return Column(
            mainAxisSize: isBounded ? MainAxisSize.max : MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
                child: _DashCardHeader(
                  title: 'Monthly Progress Trends',
                  subtitle: refMonthLabel,
                  t: t,
                  trailing: _DashSegmentedToggle<_TrendViewMode>(
                    t: t,
                    value: _mode,
                    items: const [
                      (_TrendViewMode.indexed, 'All'),
                      (_TrendViewMode.financials, 'PKR'),
                      (_TrendViewMode.volume, 'Volume'),
                    ],
                    onChanged: (next) => setState(() => _mode = next),
                  ),
                ),
              ),
              Divider(height: 1, thickness: 1, color: _dashBorder(t)),
              // Toggleable legend strip showing active/hovered month metrics
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: _activeModeSeries.map((id) {
                    final isVisible = !_hidden.contains(id);
                    final color = _seriesColor(id);
                    return MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: () => _toggleSeries(id),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 140),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: isVisible
                                ? _dashSubtleSurface(t)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(Gr.r2),
                            border: Border.all(
                              color: isVisible
                                  ? _dashBorder(t)
                                  : _dashBorder(t).withValues(alpha: 0.45),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  color: isVisible
                                      ? color
                                      : color.withValues(alpha: 0.30),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 5),
                              Text(
                                _seriesLabel(id),
                                style: TextStyle(
                                  color: isVisible
                                      ? t.textSecondary
                                      : t.textTertiary,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(width: 5),
                              Text(
                                _seriesLatestValue(id, refPoint),
                                style: TextStyle(
                                  color: isVisible
                                      ? t.textPrimary
                                      : t.textTertiary,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                  fontFeatures: const [
                                    ui.FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              if (isBounded)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 10, 8),
                    child: canvasWidget,
                  ),
                )
              else
                SizedBox(
                  height: 195,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 10, 8),
                    child: canvasWidget,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _MultiLineChartPainter extends CustomPainter {
  final List<HomeLineChartPoint> points;
  final Color accentColor;
  final Color donationsColor;
  final Color tokensColor;
  final Color staffColor;
  final double maxMoney;
  final double maxTokens;
  final double maxEmployees;
  final double maxVolume;
  final _TrendViewMode mode;
  final Set<_TrendSeriesId> hiddenSeries;
  final int? hoveredIndex;
  final bool isDark;
  final Color gridColor;
  final Color labelColor;
  final Color surfaceColor;

  _MultiLineChartPainter({
    required this.points,
    required this.accentColor,
    required this.donationsColor,
    required this.tokensColor,
    required this.staffColor,
    required this.maxMoney,
    required this.maxTokens,
    required this.maxEmployees,
    required this.maxVolume,
    required this.mode,
    required this.hiddenSeries,
    required this.isDark,
    required this.gridColor,
    required this.labelColor,
    required this.surfaceColor,
    this.hoveredIndex,
  });

  String _formatAxisMoney(double val) {
    if (val <= 0) return '0';
    if (val >= 1000000) return '${(val / 1000000).toStringAsFixed(1)}M';
    if (val >= 1000) return '${(val / 1000).toStringAsFixed(val >= 10000 ? 0 : 1)}k';
    return val.round().toString();
  }

  String _yLabelAt(double frac) => switch (mode) {
        _TrendViewMode.indexed => '${(frac * 100).round()}%',
        _TrendViewMode.financials => _formatAxisMoney(maxMoney * frac),
        _TrendViewMode.volume => fmtNum((maxVolume * frac).round()),
      };

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;

    const double leftMargin = 46.0;
    const double rightMargin = 14.0;
    const double topMargin = 8.0;
    const double bottomMargin = 22.0;

    final double chartWidth = max(1.0, size.width - leftMargin - rightMargin);
    final double chartHeight = max(1.0, size.height - topMargin - bottomMargin);
    final int len = points.length;

    double getX(int i) => len <= 1
        ? leftMargin + chartWidth / 2
        : leftMargin + (i / (len - 1)) * chartWidth;

    double getY(double val, double limit) {
      final safeLimit = max(1.0, limit);
      final ratio = (val / safeLimit).clamp(0.0, 1.0);
      return topMargin + chartHeight * (1.0 - ratio);
    }

    final labelStyle = TextStyle(
      color: labelColor,
      fontSize: 10,
      fontWeight: FontWeight.w500,
      fontFeatures: const [ui.FontFeature.tabularFigures()],
    );

    // 1. Horizontal Gridlines + Y-axis labels
    final gridPaint = Paint()
      ..color = gridColor.withValues(alpha: 0.75)
      ..strokeWidth = 1.0;

    const ySteps = [1.0, 0.75, 0.5, 0.25, 0.0];
    for (final step in ySteps) {
      final y = topMargin + chartHeight * (1.0 - step);
      canvas.drawLine(
        Offset(leftMargin, y),
        Offset(leftMargin + chartWidth, y),
        gridPaint,
      );

      final tp = TextPainter(
        text: TextSpan(text: _yLabelAt(step), style: labelStyle),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(leftMargin - tp.width - 7, y - tp.height / 2),
      );
    }

    // Determine limits per mode
    final double tokensLimit =
        mode == _TrendViewMode.volume ? maxVolume : maxTokens;
    final double staffLimit =
        mode == _TrendViewMode.volume ? maxVolume : maxEmployees;

    final donColor = donationsColor;
    final tokColor = tokensColor;
    final empColor = staffColor;

    final bool showDonations = (mode == _TrendViewMode.indexed ||
            mode == _TrendViewMode.financials) &&
        !hiddenSeries.contains(_TrendSeriesId.donations);
    final bool showPatientsRev = (mode == _TrendViewMode.indexed ||
            mode == _TrendViewMode.financials) &&
        !hiddenSeries.contains(_TrendSeriesId.patientsRev);
    final bool showTokens =
        (mode == _TrendViewMode.indexed || mode == _TrendViewMode.volume) &&
            !hiddenSeries.contains(_TrendSeriesId.tokens);
    final bool showStaff =
        (mode == _TrendViewMode.indexed || mode == _TrendViewMode.volume) &&
            !hiddenSeries.contains(_TrendSeriesId.staff);

    // 2. Draw visible series
    if (showDonations) {
      _drawLine(
        canvas,
        [for (int i = 0; i < len; i++) Offset(getX(i), getY(points[i].donations.toDouble(), maxMoney))],
        donColor,
        topMargin + chartHeight,
        leftMargin,
        chartWidth,
      );
    }
    if (showPatientsRev) {
      _drawLine(
        canvas,
        [for (int i = 0; i < len; i++) Offset(getX(i), getY(points[i].patientsRevenue.toDouble(), maxMoney))],
        accentColor,
        topMargin + chartHeight,
        leftMargin,
        chartWidth,
      );
    }
    if (showTokens) {
      _drawLine(
        canvas,
        [for (int i = 0; i < len; i++) Offset(getX(i), getY(points[i].tokens.toDouble(), tokensLimit))],
        tokColor,
        topMargin + chartHeight,
        leftMargin,
        chartWidth,
      );
    }
    if (showStaff) {
      _drawLine(
        canvas,
        [for (int i = 0; i < len; i++) Offset(getX(i), getY(points[i].employeesPresent.toDouble(), staffLimit))],
        empColor,
        topMargin + chartHeight,
        leftMargin,
        chartWidth,
      );
    }

    // 3. Draw X-axis month labels cleanly clamped inside chart bounds (no '30/11' right-edge clip)
    final distinctMonths =
        points.map((p) => '${p.date.year}-${p.date.month}').toSet().length;
    final xFormatter =
        distinctMonths >= len ? DateFormat('MMM') : DateFormat('d MMM');

    for (int i = 0; i < len; i++) {
      final x = getX(i);
      final label = xFormatter.format(points[i].date);
      final tp = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        textDirection: ui.TextDirection.ltr,
      )..layout();

      final clampedX =
          (x - tp.width / 2).clamp(leftMargin, size.width - tp.width - 2);
      tp.paint(canvas, Offset(clampedX, topMargin + chartHeight + 6));
    }

    // 4. Draw hover crosshair or latest-point marker dots
    if (hoveredIndex != null && hoveredIndex! < len) {
      final hIdx = hoveredIndex!;
      final hX = getX(hIdx);

      final linePaintRef = Paint()
        ..color = labelColor.withValues(alpha: 0.35)
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke;
      canvas.drawLine(
        Offset(hX, topMargin),
        Offset(hX, topMargin + chartHeight),
        linePaintRef,
      );

      if (showDonations) {
        _drawHoverCircle(
            canvas, hX, getY(points[hIdx].donations.toDouble(), maxMoney), donColor);
      }
      if (showPatientsRev) {
        _drawHoverCircle(
            canvas, hX, getY(points[hIdx].patientsRevenue.toDouble(), maxMoney), accentColor);
      }
      if (showTokens) {
        _drawHoverCircle(
            canvas, hX, getY(points[hIdx].tokens.toDouble(), tokensLimit), tokColor);
      }
      if (showStaff) {
        _drawHoverCircle(
            canvas, hX, getY(points[hIdx].employeesPresent.toDouble(), staffLimit), empColor);
      }
    }
  }

  void _drawLine(
    Canvas canvas,
    List<Offset> pts,
    Color color,
    double bottomY,
    double leftMargin,
    double chartWidth,
  ) {
    if (pts.isEmpty) return;

    if (pts.length == 1) {
      _drawEndpointDot(canvas, pts.first, color);
      return;
    }

    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    final fillPath = Path()
      ..moveTo(pts.first.dx, bottomY)
      ..lineTo(pts.first.dx, pts.first.dy);

    for (int i = 0; i < pts.length - 1; i++) {
      final p0 = pts[i];
      final p1 = pts[i + 1];
      final cx = (p0.dx + p1.dx) / 2;
      path.cubicTo(cx, p0.dy, cx, p1.dy, p1.dx, p1.dy);
      fillPath.cubicTo(cx, p0.dy, cx, p1.dy, p1.dx, p1.dy);
    }

    fillPath.lineTo(pts.last.dx, bottomY);
    fillPath.close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        colors: [color.withValues(alpha: 0.20), color.withValues(alpha: 0.0)],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(
          Rect.fromLTWH(leftMargin, 0, chartWidth, max(1.0, bottomY)))
      ..style = PaintingStyle.fill;
    canvas.drawPath(fillPath, fillPaint);

    final linePaint = Paint()
      ..color = color
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, linePaint);

    // Subtle endpoint marker like NexusPerformanceChart
    _drawEndpointDot(canvas, pts.last, color);
  }

  void _drawEndpointDot(Canvas canvas, Offset center, Color color) {
    canvas.drawCircle(center, 3.8, Paint()..color = color);
    canvas.drawCircle(center, 2.0, Paint()..color = surfaceColor);
  }

  void _drawHoverCircle(Canvas canvas, double x, double y, Color color) {
    canvas.drawCircle(
        Offset(x, y), 6.5, Paint()..color = color.withValues(alpha: 0.22));
    canvas.drawCircle(Offset(x, y), 3.8, Paint()..color = color);
    canvas.drawCircle(Offset(x, y), 1.8, Paint()..color = surfaceColor);
  }

  @override
  bool shouldRepaint(_MultiLineChartPainter oldDelegate) =>
      oldDelegate.hoveredIndex != hoveredIndex ||
      oldDelegate.points != points ||
      oldDelegate.mode != mode ||
      oldDelegate.hiddenSeries.length != hiddenSeries.length ||
      !oldDelegate.hiddenSeries.containsAll(hiddenSeries) ||
      oldDelegate.maxMoney != maxMoney ||
      oldDelegate.maxTokens != maxTokens ||
      oldDelegate.maxEmployees != maxEmployees ||
      oldDelegate.maxVolume != maxVolume ||
      oldDelegate.isDark != isDark ||
      oldDelegate.accentColor != accentColor ||
      oldDelegate.donationsColor != donationsColor ||
      oldDelegate.tokensColor != tokensColor ||
      oldDelegate.staffColor != staffColor ||
      oldDelegate.gridColor != gridColor;
}

// ════════════════════════════════════════════════════════════════════════
// 6. Patients by Branch Horizontal Bar Chart
// ════════════════════════════════════════════════════════════════════════

class HomePatientsByBranchBarChart extends StatefulWidget {
  final RoleThemeData t;
  final List<HomeBranchRow> rows;
  final void Function(String branchId)? onTapBranch;

  const HomePatientsByBranchBarChart({
    super.key,
    required this.t,
    required this.rows,
    this.onTapBranch,
  });

  @override
  State<HomePatientsByBranchBarChart> createState() =>
      _HomePatientsByBranchBarChartState();
}

class _HomePatientsByBranchBarChartState
    extends State<HomePatientsByBranchBarChart> {
  bool _showWeekly = true;

  @override
  Widget build(BuildContext context) {
    final t = widget.t;

    // Consolidate camps into collective branch rows with normalized keys and clean names
    final Map<String, HomeBranchRow> branchMap = {};
    for (final r in widget.rows) {
      final rawKey =
          r.id.toLowerCase().trim().replaceAll(' ', '_').replaceAll('-', '_');
      final lowName = r.name.toLowerCase();
      final isKarachi =
          rawKey.contains('karachi') || lowName.contains('karachi');
      final isJalalpur =
          rawKey.contains('jalal') || lowName.contains('jalal');
      final isGujrat = rawKey.contains('gujrat') || lowName.contains('gujrat');
      final isSialkot =
          rawKey.contains('sialkot') || lowName.contains('sialkot');
      final isRawalpindi = rawKey.contains('rawalpindi') ||
          rawKey.contains('pindi') ||
          lowName.contains('rawalpindi');

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

    int todayCount(HomeBranchRow r) {
      final catSum = r.today.zakat + r.today.nonZakat + r.today.gmwf;
      return max(r.today.tokens, catSum);
    }

    int displayCount(HomeBranchRow r) {
      final td = todayCount(r);
      return _showWeekly ? max(r.weeklyPatients, td) : td;
    }

    final sortedRows = branchMap.values.toList()
      ..sort((a, b) {
        final dCmp = displayCount(b).compareTo(displayCount(a));
        if (dCmp != 0) return dCmp;
        final tCmp = todayCount(b).compareTo(todayCount(a));
        if (tCmp != 0) return tCmp;
        return a.name.compareTo(b.name);
      });

    final int maxVal = sortedRows.isEmpty
        ? 1
        : max(1, sortedRows.map(displayCount).reduce(max));
    final int totalVal =
        sortedRows.fold<int>(0, (sum, r) => sum + displayCount(r));
    final int activeBranches =
        sortedRows.where((r) => displayCount(r) > 0).length;

    final isDark = t.isDarkCanvas;
    final branchBarPalette = [
      t.accent,
      isDark ? SoftPalette.brightMint : SoftPalette.jadeEmerald,
      isDark ? SoftPalette.brightCobalt : SoftPalette.cobaltBlue,
      isDark ? SoftPalette.softLavender : SoftPalette.royalViolet,
      isDark ? SoftPalette.brightGold : SoftPalette.warmMarigold,
      isDark ? SoftPalette.brightCoral : SoftPalette.roseCoral,
    ];

    return Container(
      decoration: _dashCardDecoration(t, radius: Gr.r4),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isBounded = constraints.hasBoundedHeight;

          final bodyList = sortedRows.isEmpty
              ? _DashEmptyState(
                  icon: Icons.bar_chart_rounded,
                  message: 'No branch patient data',
                  hint: 'Patient totals by city appear here once recorded.',
                  t: t,
                )
              : ListView.separated(
                  shrinkWrap: !isBounded,
                  physics: isBounded
                      ? const BouncingScrollPhysics()
                      : const NeverScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  itemCount: min(8, sortedRows.length),
                  separatorBuilder: (_, _) => const SizedBox(height: 11),
                  itemBuilder: (context, i) {
                    final row = sortedRows[i];
                    final int val = displayCount(row);
                    final int td = todayCount(row);
                    final double ratio = val <= 0 ? 0.0 : val / maxVal;
                    final double widthFactor =
                        val <= 0 ? 0.0 : ratio.clamp(0.025, 1.0);
                    final double sharePct =
                        totalVal > 0 ? (val / totalVal) * 100 : 0.0;
                    final Color barColor = val > 0
                        ? branchBarPalette[i % branchBarPalette.length]
                        : t.textTertiary;

                    final content = Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: val > 0
                                    ? barColor
                                    : t.textTertiary.withValues(alpha: 0.4),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                row.name,
                                style: TextStyle(
                                  color: val > 0
                                      ? t.textPrimary
                                      : t.textSecondary,
                                  fontSize: 12.5,
                                  fontWeight: val > 0
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (val > 0) ...[
                              Text(
                                '${sharePct.toStringAsFixed(sharePct >= 10 ? 0 : 1)}%',
                                style: TextStyle(
                                  color: t.textSecondary,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w500,
                                  fontFeatures: const [
                                    ui.FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            ConstrainedBox(
                              constraints: const BoxConstraints(minWidth: 32),
                              child: Text(
                                fmtNum(val),
                                style: TextStyle(
                                  color:
                                      val > 0 ? t.textPrimary : t.textTertiary,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w800,
                                  fontFeatures: const [
                                    ui.FontFeature.tabularFigures(),
                                  ],
                                ),
                                textAlign: TextAlign.right,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(Gr.r1),
                          child: Container(
                            height: 7,
                            color: _dashSubtleSurface(t),
                            alignment: Alignment.centerLeft,
                            child: widthFactor > 0
                                ? FractionallySizedBox(
                                    alignment: Alignment.centerLeft,
                                    widthFactor: widthFactor,
                                    child: Container(
                                      height: 7,
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          colors: [
                                            barColor,
                                            barColor.withValues(alpha: 0.78),
                                          ],
                                        ),
                                        borderRadius:
                                            BorderRadius.circular(Gr.r1),
                                      ),
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _showWeekly
                                  ? (td > 0
                                      ? '$td visits today'
                                      : (val > 0
                                          ? '0 visits today'
                                          : 'No visits in last 7 days'))
                                  : (row.weeklyPatients > 0
                                      ? '${fmtNum(row.weeklyPatients)} in last 7 days'
                                      : 'No visits today'),
                              style: TextStyle(
                                color: t.textTertiary,
                                fontSize: 10,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          ],
                        ),
                      ],
                    );

                    if (widget.onTapBranch == null) return content;

                    return InkWell(
                      onTap: () => widget.onTapBranch!(row.id),
                      borderRadius: BorderRadius.circular(Gr.r2),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            vertical: 2, horizontal: 2),
                        child: content,
                      ),
                    );
                  },
                );

          return Column(
            mainAxisSize: isBounded ? MainAxisSize.max : MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
                child: _DashCardHeader(
                  title: 'Patients by Branch',
                  subtitle: totalVal > 0
                      ? '${fmtNum(totalVal)} visits · $activeBranches active branches'
                      : 'No visits recorded in window',
                  t: t,
                  trailing: _DashSegmentedToggle<bool>(
                    t: t,
                    value: _showWeekly,
                    items: const [
                      (true, '7D'),
                      (false, 'Today'),
                    ],
                    onChanged: (v) => setState(() => _showWeekly = v),
                  ),
                ),
              ),
              Divider(height: 1, thickness: 1, color: _dashBorder(t)),
              if (isBounded) Expanded(child: bodyList) else bodyList,
            ],
          );
        },
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
      decoration: _dashCardDecoration(t, radius: Gr.r4),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isBounded = constraints.hasBoundedHeight;
          final itemsCount = min(5, activities.length);

          final body = activities.isEmpty
              ? _DashEmptyState(
                  icon: Icons.history_rounded,
                  message: 'No recent activity records',
                  hint: 'Tokens, receipts, and branch updates stream here.',
                  t: t,
                )
              : ListView.separated(
                  shrinkWrap: !isBounded,
                  physics: isBounded
                      ? const BouncingScrollPhysics()
                      : const NeverScrollableScrollPhysics(),
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: itemsCount,
                  separatorBuilder: (_, _) => Divider(
                    height: 1,
                    thickness: 1,
                    indent: 52,
                    color: _dashBorder(t).withValues(alpha: 0.65),
                  ),
                  itemBuilder: (context, i) {
                    final act = activities[i];
                    final isDon = act.type == 'donation';
                    final isToken = act.type == 'token';

                    Color iconColor = isDark
                        ? SoftPalette.brightCobalt
                        : SoftPalette.cobaltBlue;
                    IconData iconData = Icons.confirmation_number_rounded;
                    String badgeLabel = 'TOKEN';

                    if (isDon) {
                      iconColor = isDark
                          ? SoftPalette.brightMint
                          : SoftPalette.jadeEmerald;
                      iconData = Icons.volunteer_activism_rounded;
                      badgeLabel = 'DONATION';
                    } else if (act.type == 'reception' ||
                        act.title.contains('Register') ||
                        act.title.contains('Patient')) {
                      iconColor = isDark
                          ? SoftPalette.softLavender
                          : SoftPalette.royalViolet;
                      iconData = Icons.person_add_rounded;
                      badgeLabel = 'PATIENT';
                    } else if (act.type == 'revenue' ||
                        act.title.contains('Revenue') ||
                        act.title.contains('Record')) {
                      iconColor = isDark
                          ? SoftPalette.brightGold
                          : SoftPalette.warmMarigold;
                      iconData = Icons.payments_rounded;
                      badgeLabel = 'REVENUE';
                    }

                    return InkWell(
                      onTap: availableModules.isEmpty
                          ? null
                          : () {
                              final targetModuleId = isDon
                                  ? 'donations'
                                  : (isToken ? 'token_generation' : 'branches');
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
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 9),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color: iconColor
                                    .withValues(alpha: isDark ? 0.19 : 0.12),
                                borderRadius: BorderRadius.circular(Gr.r2),
                                border: Border.all(
                                  color: iconColor
                                      .withValues(alpha: isDark ? 0.34 : 0.22),
                                  width: 0.9,
                                ),
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
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 5, vertical: 1),
                                        margin: const EdgeInsets.only(right: 6),
                                        decoration: BoxDecoration(
                                          color: iconColor.withValues(
                                              alpha: isDark ? 0.18 : 0.10),
                                          borderRadius:
                                              BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          badgeLabel,
                                          style: TextStyle(
                                            color: iconColor,
                                            fontSize: 8.5,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: 0.4,
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        child: Text(
                                          act.title,
                                          style: TextStyle(
                                            color: t.textPrimary,
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.w600,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    act.subtitle,
                                    style: TextStyle(
                                      color: t.textSecondary,
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w400,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              DateFormat('hh:mm a').format(act.timestamp),
                              style: TextStyle(
                                color: t.textTertiary,
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                                fontFeatures: const [
                                  ui.FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );

          return Column(
            mainAxisSize: isBounded ? MainAxisSize.max : MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
                child: _DashCardHeader(
                  title: 'Recent Activity',
                  subtitle: 'Latest clinic & branch events',
                  showLiveDot: activities.isNotEmpty,
                  t: t,
                  trailing: availableModules.isEmpty
                      ? null
                      : InkWell(
                          onTap: () {
                            final reportsModule = availableModules.firstWhere(
                              (m) => m.id == 'branches',
                              orElse: () => availableModules.first,
                            );
                            onOpenModule(reportsModule);
                          },
                          borderRadius: BorderRadius.circular(Gr.r1),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 2),
                            child: Text(
                              'View all →',
                              style: TextStyle(
                                color: t.accent,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                ),
              ),
              Divider(height: 1, thickness: 1, color: _dashBorder(t)),
              if (isBounded) Expanded(child: body) else body,
            ],
          );
        },
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
  final int? todayFoodTokens;

  const QuickActionsRow({
    super.key,
    required this.availableModules,
    required this.t,
    required this.onOpenModule,
    this.todayFoodTokens,
  });

  @override
  Widget build(BuildContext context) {
    int foodTokensCount = todayFoodTokens ?? 0;
    if (todayFoodTokens == null) {
      try {
        if (Hive.isBoxOpen(LocalStorageService.dasterkhwaanTokensBox)) {
          final box = Hive.box(LocalStorageService.dasterkhwaanTokensBox);
          final todayYmd = DateFormat('yyyy-MM-dd').format(DateTime.now());
          final todayDmyy = DateFormat('ddMMyy').format(DateTime.now());
          for (final raw in box.values) {
            if (raw is Map) {
              final dk = raw['dateKey']?.toString() ?? '';
              if (dk == todayYmd || dk == todayDmyy) foodTokensCount++;
            }
          }
        }
      } catch (_) {}
    }

    final bool isDark = t.isDarkCanvas;
    final List<Map<String, dynamic>> targetActions = [
      {'id': 'branches', 'label': 'Branches', 'icon': Icons.store_outlined, 'color': isDark ? SoftPalette.brightCyan : SoftPalette.deepCyan},
      {'id': 'employees', 'label': 'Staff Attendance', 'icon': Icons.badge_outlined, 'color': isDark ? SoftPalette.softIndigo : SoftPalette.luminousIndigo},
      {'id': 'madrassa_attendance', 'label': 'Madrassa Attend.', 'icon': Icons.how_to_reg_rounded, 'color': isDark ? SoftPalette.brightOrchid : SoftPalette.plumOrchid},
      {'id': 'madrassa_students', 'label': 'Madrassa Students', 'icon': Icons.groups_rounded, 'color': isDark ? SoftPalette.brightMint : SoftPalette.jadeEmerald},
      {'id': 'school_attendance', 'label': 'School Students', 'icon': Icons.school_rounded, 'color': isDark ? SoftPalette.brightCobalt : SoftPalette.cobaltBlue},
      {'id': 'school_teacher_attendance', 'label': 'School Faculty', 'icon': Icons.co_present_rounded, 'color': isDark ? SoftPalette.softLavender : SoftPalette.royalViolet},
      {'id': 'office_boy', 'label': foodTokensCount > 0 ? 'Food Tokens ($foodTokensCount)' : 'Food Tokens', 'icon': Icons.room_service_rounded, 'color': isDark ? SoftPalette.brightGold : SoftPalette.warmMarigold},
      {'id': 'dasterkhwaan_inventory', 'label': 'Dasterkhwaan', 'icon': Icons.inventory_2_outlined, 'color': isDark ? SoftPalette.brightCoral : SoftPalette.roseCoral},
      {'id': 'inventory', 'label': 'Med Inventory', 'icon': Icons.medication_liquid_rounded, 'color': isDark ? SoftPalette.sky350 : SoftPalette.sky550},
      {'id': 'finance', 'label': 'Finance & HR', 'icon': Icons.monetization_on_rounded, 'color': isDark ? SoftPalette.brightCoral : SoftPalette.roseCoral},
      {'id': 'donations', 'label': 'Add Donation', 'icon': Icons.volunteer_activism_rounded, 'color': isDark ? SoftPalette.brightMint : SoftPalette.jadeEmerald},
      {'id': 'patients_registration', 'label': 'Add Patient', 'icon': Icons.person_add_rounded, 'color': isDark ? SoftPalette.softLavender : SoftPalette.royalViolet},
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

    return Container(
      decoration: _dashCardDecoration(t, radius: Gr.r4),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isBounded = constraints.hasBoundedHeight;
          final w = constraints.maxWidth;
          final crossAxisCount = (w / 96).floor().clamp(2, 6);
          final rowCount = activeActions.isEmpty
              ? 1
              : (activeActions.length / crossAxisCount).ceil();
          final availableHeight = constraints.maxHeight - 64;
          final calcExtent = (isBounded && rowCount > 0 && availableHeight > 0)
              ? ((availableHeight - (rowCount - 1) * 8) / rowCount)
                  .clamp(62.0, 90.0)
              : 72.0;

          final grid = activeActions.isEmpty
              ? _DashEmptyState(
                  icon: Icons.apps_outlined,
                  message: 'No shortcuts available',
                  hint: 'Enabled module shortcuts appear here.',
                  t: t,
                )
              : Padding(
                  padding: const EdgeInsets.all(12),
                  child: GridView.builder(
                    shrinkWrap: !isBounded,
                    physics: isBounded
                        ? const BouncingScrollPhysics()
                        : const NeverScrollableScrollPhysics(),
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
                          : ((action['id'] == 'madrassa_attendance' ||
                                  action['id'] == 'madrassa_students' ||
                                  action['id'] == 'add_student' ||
                                  action['id'] == 'madrassa_report')
                              ? 'madrassa'
                              : ((action['id'] == 'school_attendance' ||
                                      action['id'] ==
                                          'school_teacher_attendance' ||
                                      action['id'] == 'school')
                                  ? 'school_module'
                                  : action['id']));
                      final baseModule = availableModules.firstWhere(
                        (m) =>
                            m.id == mainModuleId ||
                            (mainModuleId == 'patients_registration' &&
                                m.id == 'patient_register_standalone') ||
                            (mainModuleId == 'school_module' &&
                                (m.id == 'school_attendance' ||
                                    m.id == 'school_teacher_attendance' ||
                                    m.id == 'school_module')),
                        orElse: () => availableModules.firstWhere(
                          (m) => m.id == mainModuleId,
                          orElse: () => availableModules.first,
                        ),
                      );

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
                            final username =
                                data['name'] ?? data['username'] ?? 'User';
                            final role =
                                (data['role'] as String? ?? 'madrassa admin')
                                    .toLowerCase();
                            final isAdmin = role.contains('admin') ||
                                role.contains('chairman') ||
                                role.contains('ceo') ||
                                role.contains('hq');
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
                            final username =
                                data['name'] ?? data['username'] ?? 'User';
                            final role =
                                (data['role'] as String? ?? 'madrassa admin')
                                    .toLowerCase();
                            final isAdmin = role.contains('admin') ||
                                role.contains('chairman') ||
                                role.contains('ceo') ||
                                role.contains('hq');
                            return MadrassaDashboard(
                              branchId: branchId,
                              username: username,
                              role: role,
                              isAdmin: isAdmin,
                              initialIndex: isAdmin ? 1 : 0,
                            );
                          },
                        );
                      } else if (action['id'] == 'madrassa_teachers') {
                        module = baseModule.copyWith(
                          title: 'Madrassa Teachers',
                          builder: (context, data) {
                            final branchId = data['branchId'] ?? 'unknown';
                            final username =
                                data['name'] ?? data['username'] ?? 'User';
                            final role =
                                (data['role'] as String? ?? 'madrassa admin')
                                    .toLowerCase();
                            final isAdmin = role.contains('admin') ||
                                role.contains('chairman') ||
                                role.contains('ceo') ||
                                role.contains('hq') ||
                                role.contains('principal') ||
                                role.contains('manager');
                            return MadrassaDashboard(
                              branchId: branchId,
                              username: username,
                              role: role,
                              isAdmin: isAdmin,
                              initialIndex: 3,
                            );
                          },
                        );
                      } else if (action['id'] == 'school_attendance') {
                        module = baseModule.copyWith(
                          title: 'School Student Attendance',
                          builder: (context, data) => SchoolDashboard(
                            branchId: data['branchId'] ?? 'all',
                            username: data['name'] ??
                                data['username'] ??
                                LocalStorageService.getActiveUsername(),
                            role: data['role'] ??
                                LocalStorageService.getActiveUserRole(),
                            initialTabIndex: 2,
                          ),
                        );
                      } else if (action['id'] == 'school_teacher_attendance') {
                        module = baseModule.copyWith(
                          title: 'School Faculty Attendance',
                          builder: (context, data) => SchoolDashboard(
                            branchId: data['branchId'] ?? 'all',
                            username: data['name'] ??
                                data['username'] ??
                                LocalStorageService.getActiveUsername(),
                            role: data['role'] ??
                                LocalStorageService.getActiveUserRole(),
                            initialTabIndex: 3,
                          ),
                        );
                      }

                      final color = action['color'] as Color;

                      return InkWell(
                        onTap: () => onOpenModule(module),
                        borderRadius: BorderRadius.circular(Gr.r3),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 4),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Color.alphaBlend(
                                  color.withValues(alpha: isDark ? 0.12 : 0.07),
                                  _dashSubtleSurface(t),
                                ),
                                _dashSurface(t),
                              ],
                            ),
                            borderRadius: BorderRadius.circular(Gr.r3),
                            border: Border.all(
                              color: color.withValues(
                                  alpha: isDark ? 0.34 : 0.25),
                              width: 1.0,
                            ),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                width: 26,
                                height: 26,
                                decoration: BoxDecoration(
                                  color: color.withValues(
                                      alpha: isDark ? 0.22 : 0.13),
                                  borderRadius: BorderRadius.circular(Gr.r2),
                                ),
                                child: Icon(action['icon'] as IconData,
                                    color: color, size: 15),
                              ),
                              const SizedBox(height: 3.5),
                              Text(
                                action['label'] as String,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: t.textPrimary,
                                  fontSize: 10.0,
                                  fontWeight: FontWeight.w600,
                                  height: 1.12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                );

          return Column(
            mainAxisSize: isBounded ? MainAxisSize.max : MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 13, 16, 11),
                child: _DashCardHeader(
                  title: 'Quick Actions',
                  t: t,
                  trailing: Text(
                    '${activeActions.length} shortcuts',
                    style: TextStyle(
                      color: t.textTertiary,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
              Divider(height: 1, thickness: 1, color: _dashBorder(t)),
              if (isBounded) Expanded(child: grid) else grid,
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
        ? SoftPalette.amber300
        : (isSecond ? SoftPalette.blue350 : SoftPalette.orange350);

    final bannerBg = widget.isDark
        ? SoftPalette.slate800
        : (isTop ? SoftPalette.yellow50m : SoftPalette.gray50);

    final bannerBorder = isTop
        ? SoftPalette.amber300
        : (isSecond ? SoftPalette.blue300 : SoftPalette.amber200);

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
                child: RepaintBoundary(child: isTop
                    ? Lottie.asset(
                        'assets/animations/Trophy.json',
                        fit: BoxFit.contain,
                        repeat: !GDecor.reduceMotion,
                        errorBuilder: (_, _, _) => Icon(
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
                              repeat: !GDecor.reduceMotion,
                              errorBuilder: (_, _, _) => Icon(
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
                              repeat: !GDecor.reduceMotion,
                              errorBuilder: (_, _, _) => Icon(
                                Icons.military_tech_rounded,
                                size: 38,
                                color: goldColor,
                              ),
                            ),
                          ))),
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
                        color: widget.isDark ? SoftPalette.slate350 : SoftPalette.slate600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                color: widget.isDark ? SoftPalette.gray50A54 : SoftPalette.gray500,
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
        ? SoftPalette.amber300
        : (isSecond ? SoftPalette.sky500 : SoftPalette.orange400);

    final badgeBg = isTop
        ? SoftPalette.yellow100
        : (isSecond ? SoftPalette.slate100 : SoftPalette.amber100);

    final cardBg = isDark
        ? (isTop ? SoftPalette.slate800 : (isSecond ? SoftPalette.slate900 : SoftPalette.gray900))
        : (isTop ? SoftPalette.yellow50m : (isSecond ? SoftPalette.slate50 : SoftPalette.amber50m));

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
                        child: RepaintBoundary(child: isTop
                            ? Lottie.asset(
                                'assets/animations/Trophy.json',
                                fit: BoxFit.contain,
                                repeat: !GDecor.reduceMotion,
                                errorBuilder: (_, _, _) => Icon(
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
                                      repeat: !GDecor.reduceMotion,
                                      errorBuilder: (_, _, _) => Icon(
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
                                      repeat: !GDecor.reduceMotion,
                                      errorBuilder: (_, _, _) => Icon(
                                        Icons.military_tech_rounded,
                                        size: 80,
                                        color: primaryColor,
                                      ),
                                    ),
                                  ))),
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
                          color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
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
                          color: isDark ? SoftPalette.slate350 : SoftPalette.slate600,
                          height: 1.4,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.celebration_rounded, size: 18, color: SoftPalette.gray50),
                          label: const Text(
                            'View Performance',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: SoftPalette.gray50),
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
                    // 520x520 vector animation: own layer, and one burst only when reduce-motion is on.
                    child: RepaintBoundary(
                      child: Lottie.asset(
                      'assets/animations/party_celebration.json',
                      fit: BoxFit.contain,
                      repeat: !GDecor.reduceMotion,
                      errorBuilder: (_, _, _) => Lottie.asset(
                        'assets/animations/Party  Celebration.json',
                        fit: BoxFit.contain,
                        repeat: !GDecor.reduceMotion,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
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

// The aux counts scan whole Hive boxes (attendance, users, school and madrassa
// logs) on the UI thread, and one dashboard load asks for them from several
// places. A short cache turns that burst into one scan; counts stay ~live.
final Map<String, (DateTime, Map<String, int>)> _auxCountsCache = {};
const Duration _auxCountsTtl = Duration(seconds: 10);

Map<String, int> _computeLocalDashboardAuxCounts({String? branchId}) {
  final cacheKey = branchId ?? '';
  final hit = _auxCountsCache[cacheKey];
  if (hit != null && DateTime.now().difference(hit.$1) < _auxCountsTtl) return hit.$2;
  final result = _computeLocalDashboardAuxCountsUncached(branchId: branchId);
  _auxCountsCache[cacheKey] = (DateTime.now(), result);
  return result;
}

Map<String, int> _computeLocalDashboardAuxCountsUncached({String? branchId}) {
  final todayDateKey = DateFormat('yyyy-MM-dd').format(DateTime.now());
  final normB = (branchId != null && branchId != 'all' && branchId != 'global') ? branchId.toLowerCase().trim() : null;
  int empPresentCount = 0;
  try {
    if (Hive.isBoxOpen(LocalStorageService.attendanceBox)) {
      final box = Hive.box(LocalStorageService.attendanceBox);
      final presentEmpKeys = <String>{};
      for (final val in box.values) {
        if (val is Map) {
          final b = (val['branchId']?.toString() ?? '').toLowerCase().trim();
          if (normB != null && normB.isNotEmpty && b != normB && !b.contains(normB) && !normB.contains(b)) continue;
          final d = val['date']?.toString();
          if (d == todayDateKey) {
            final status = val['status']?.toString().toLowerCase();
            if (status == 'present' || status == 'late' || status == 'overtime') {
              final pin = (val['pin'] ?? val['biometricPin'])?.toString().trim() ?? '';
              final empId = (val['employeeId'] ?? val['localId'] ?? val['id'])?.toString().trim() ?? '';
              final name = (val['employeeName'] ?? val['name'])?.toString().trim().toLowerCase() ?? '';
              final key = pin.isNotEmpty ? 'pin:$pin' : (empId.isNotEmpty ? 'id:$empId' : 'name:$name');
              if (key.isNotEmpty) presentEmpKeys.add(key);
            }
          }
        }
      }
      empPresentCount = presentEmpKeys.length;
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

  int madrassaPresentCount = 0;
  int madrassaYesterdayPresentCount = 0;
  int madrassaTeacherPresentCount = 0;
  int madrassaTeacherYesterdayPresentCount = 0;
  try {
    if (Hive.isBoxOpen(LocalStorageService.madrassaLogsBox)) {
      final yestDateKey = DateFormat('yyyy-MM-dd').format(DateTime.now().subtract(const Duration(days: 1)));
      madrassaPresentCount = MadrassaLocalStorage.getPresentStudentsCount(normB ?? 'all', todayDateKey);
      madrassaYesterdayPresentCount = MadrassaLocalStorage.getPresentStudentsCount(normB ?? 'all', yestDateKey);
      madrassaTeacherPresentCount = MadrassaLocalStorage.getPresentTeachersCount(normB ?? 'all', todayDateKey);
      madrassaTeacherYesterdayPresentCount = MadrassaLocalStorage.getPresentTeachersCount(normB ?? 'all', yestDateKey);
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
    'madrassa': madrassaPresentCount,
    'madrassa_yesterday': madrassaYesterdayPresentCount,
    'madrassa_teachers': madrassaTeacherPresentCount,
    'madrassa_teachers_yesterday': madrassaTeacherYesterdayPresentCount,
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
  final int madrassaPresentCount;
  final int madrassaYesterdayPresentCount;
  final int madrassaTeacherPresentCount;
  final int madrassaTeacherYesterdayPresentCount;
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
    this.madrassaPresentCount = 0,
    this.madrassaYesterdayPresentCount = 0,
    this.madrassaTeacherPresentCount = 0,
    this.madrassaTeacherYesterdayPresentCount = 0,
    this.onlineUsersCount = 1,
  });
}

class BranchDashboardOverlay {
  final Map<String, int> auxCounts;
  final List<HomeLineChartPoint> chartPoints;
  final List<RecentActivity> recentActivities;
  const BranchDashboardOverlay({
    required this.auxCounts,
    required this.chartPoints,
    required this.recentActivities,
  });
}

/// Fetches branch-scoped attendance/aux counts, chart points, and recent
/// activity when an executive filters the HomeDashboard to a single branch.
Future<BranchDashboardOverlay> fetchBranchDashboardOverlay(String rawBranchId) async {
  final parentId = rawBranchId.toLowerCase().startsWith('karachi')
      ? 'karachi'
      : LocalStorageService.sanitizeBranchId(rawBranchId);
  final results = await Future.wait([
    mergeCloudAuxCounts(_computeLocalDashboardAuxCounts(branchId: parentId), [parentId]),
    fetchChartPoints([parentId], months: 5),
    RecentActivityService.getRecentActivityAsync(branchId: parentId, limit: 15),
  ]);
  var activities = results[2] as List<RecentActivity>;
  if (rawBranchId == 'karachi_haji' || rawBranchId == 'karachi_saddar') {
    final token = rawBranchId == 'karachi_haji' ? 'haji' : 'saddar';
    final campFiltered = activities.where((a) =>
        a.branchName.toLowerCase().contains(token) ||
        a.subtitle.toLowerCase().contains(token)).toList();
    if (campFiltered.isNotEmpty) activities = campFiltered;
  }
  return BranchDashboardOverlay(
    auxCounts: results[0] as Map<String, int>,
    chartPoints: results[1] as List<HomeLineChartPoint>,
    recentActivities: activities,
  );
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
    final Set<String> cleanBranchIds = {'karachi', 'gujrat', 'sialkot', 'jalalpurjattan', 'rawalpindi'};
    for (final id in rawBranchIds) {
      final norm = id.toLowerCase().trim().replaceAll(' ', '_').replaceAll('-', '_');
      if (norm.contains('karachi') || norm.contains('haji') || norm.contains('kapaya') || norm.contains('saddar')) {
        cleanBranchIds.add('karachi');
      } else if (norm.contains('jalal')) {
        cleanBranchIds.add('jalalpurjattan');
      } else if (norm.contains('gujrat')) {
        cleanBranchIds.add('gujrat');
      } else if (norm.contains('sialkot')) {
        cleanBranchIds.add('sialkot');
      } else if (norm.contains('rawalpindi') || norm.contains('pindi')) {
        cleanBranchIds.add('rawalpindi');
      } else if (norm.isNotEmpty && norm != 'all' && norm != 'global' && norm != 'unknown') {
        // Short ids ('grt', 'skt', 'rwp', 'khi', 'jlj') fold to their branch; as rows of their
        // own they double-counted local records and looked up empty cloud branches.
        cleanBranchIds.add(LocalStorageService.sanitizeBranchId(norm, fallback: norm));
      }
    }
    final branchIds = cleanBranchIds.toList();
    
    // 2. Fetch today-vs-yesterday per branch. This PC is on no clinic's LAN, so the figures
    // are combined with cached cloud counts (the local-only view is buildLocalSnapshotDashboardData).
    final Map<String, TodayVsYesterday> statsMap = await fetchTodayVsYesterdayPerBranch(branchIds, allowRemoteFallback: true);
    final weeklyPatients = await fetchWeeklyPatientCounts(branchIds, includeCloud: true);

    // 3. Build branch/camp rows for table
    final List<HomeBranchRow> branchRows = [];
    final List<BranchStats> todayStatsList = [];
    final List<BranchStats> yesterdayStatsList = [];

    final karachiCamps = await fetchKarachiCampBreakdown(null, true);

    statsMap.forEach((bId, value) {
      if (bId == 'karachi') {
        final hasCampBreakdown = karachiCamps.totalPatients > 0;
        final hajiToday = BranchStats(
          zakat: hasCampBreakdown ? karachiCamps.hajiCampZakat : 0,
          nonZakat: hasCampBreakdown ? karachiCamps.hajiCampNonZakat : 0,
          gmwf: hasCampBreakdown ? karachiCamps.hajiCampGmwf : 0,
          prescribed: value.today.prescribed,
          dispensaryRevenue: hasCampBreakdown ? karachiCamps.hajiCampRevenue : 0,
          donations: 0,
        );

        final saddarToday = BranchStats(
          zakat: hasCampBreakdown ? karachiCamps.kapayaZakat : value.today.zakat,
          nonZakat: hasCampBreakdown ? karachiCamps.kapayaNonZakat : value.today.nonZakat,
          gmwf: hasCampBreakdown ? karachiCamps.kapayaGmwf : value.today.gmwf,
          prescribed: value.today.prescribed,
          // Karachi's dispensed total (the camp breakdown has none per camp). Both rows used
          // to omit it, so Karachi always added 0 dispensed to the combined figure.
          dispensed: value.today.dispensed,
          dispensaryRevenue: hasCampBreakdown ? karachiCamps.kapayaRevenue : value.today.dispensaryRevenue,
          donations: value.today.donations,
          dasterkhwaan: value.today.dasterkhwaan,
          dasterkhwaanServed: value.today.dasterkhwaanServed,
        );

        branchRows.add(HomeBranchRow(
          id: 'karachi_haji',
          name: 'Karachi — Haji Camp Dispensary', subtitle: 'Morning ${karachiCamps.hajiCampMorningPatients} • Evening ${karachiCamps.hajiCampEveningPatients}',
          today: hajiToday,
          yesterday: value.yesterday,
          weeklyPatients: 0,
        ));

        branchRows.add(HomeBranchRow(
          id: 'karachi_saddar',
          name: 'Karachi — Saddar Dispensary', subtitle: 'Morning ${karachiCamps.kapayaMorningPatients} • Evening ${karachiCamps.kapayaEveningPatients}',
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
    
    // Attendance tiles max-merged with Firestore (they were Hive-only, so HQ showed 0).
    final auxCounts = await mergeCloudAuxCounts(_computeLocalDashboardAuxCounts(), branchIds);
    return SnapshotDashboardData(
      todayCombined: todayCombined,
      yesterdayCombined: yesterdayCombined,
      branchRows: branchRows,
      chartPoints: chartPoints,
      recentActivities: recentActivities,
      empPresentCount: auxCounts['emp'] ?? 0,
      studentPresentCount: auxCounts['students'] ?? 0,
      teacherPresentCount: auxCounts['teachers'] ?? 0,
      madrassaPresentCount: auxCounts['madrassa'] ?? 0,
      madrassaYesterdayPresentCount: auxCounts['madrassa_yesterday'] ?? 0,
      madrassaTeacherPresentCount: auxCounts['madrassa_teachers'] ?? 0,
      madrassaTeacherYesterdayPresentCount: auxCounts['madrassa_teachers_yesterday'] ?? 0,
      onlineUsersCount: auxCounts['online'] ?? 1,
    );
  } else {
    // Branch-locked role. The branch id is folded like the uploaders fold it ('grt' → 'gujrat',
    // 'khi' → 'karachi'), otherwise the cloud counts are looked up under a branch nobody writes.
    final String branchId = userBranchId.isNotEmpty
        ? LocalStorageService.sanitizeBranchId(userBranchId)
        : 'karachi';

    // 1. Today vs yesterday, max-merged with the cloud counts. This used fetchBranchStats /
    // fetchHistoricalDayStats, which read only this PC's Hive, so anything uploaded from other
    // PCs of the branch never showed here.
    final todayStats = await fetchLocalBranchStats(branchId, DateTime.now(), allowRemoteFallback: true);
    final yesterdayStats = await fetchLocalBranchStats(
        branchId, DateTime.now().subtract(const Duration(days: 1)), allowRemoteFallback: true);
    final weeklyPatients = await fetchWeeklyPatientCounts([branchId]);

    // 2. Build branchRows for single branch/camps
    final List<HomeBranchRow> branchRows = [];
    if (branchId == 'karachi') {
      final karachiCamps = await fetchKarachiCampBreakdown(null, true);
      branchRows.add(HomeBranchRow(
        id: 'karachi_haji',
        name: 'Karachi — Haji Camp Dispensary', subtitle: 'Morning ${karachiCamps.hajiCampMorningPatients} • Evening ${karachiCamps.hajiCampEveningPatients}',
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
        name: 'Karachi — Saddar Dispensary', subtitle: 'Morning ${karachiCamps.kapayaMorningPatients} • Evening ${karachiCamps.kapayaEveningPatients}',
        today: BranchStats(
          zakat: karachiCamps.kapayaZakat,
          nonZakat: karachiCamps.kapayaNonZakat,
          gmwf: karachiCamps.kapayaGmwf,
          prescribed: todayStats.prescribed,
          dispensaryRevenue: karachiCamps.kapayaRevenue,
          donations: todayStats.donations,
          dasterkhwaan: todayStats.dasterkhwaan,
          dasterkhwaanServed: todayStats.dasterkhwaanServed,
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

    final auxCounts = await mergeCloudAuxCounts(_computeLocalDashboardAuxCounts(branchId: branchId), [branchId]);
    return SnapshotDashboardData(
      todayCombined: todayCombined,
      yesterdayCombined: yesterdayStats,
      branchRows: branchRows,
      chartPoints: chartPoints,
      recentActivities: recentActivities,
      empPresentCount: auxCounts['emp'] ?? 0,
      studentPresentCount: auxCounts['students'] ?? 0,
      teacherPresentCount: auxCounts['teachers'] ?? 0,
      madrassaPresentCount: auxCounts['madrassa'] ?? 0,
      madrassaYesterdayPresentCount: auxCounts['madrassa_yesterday'] ?? 0,
      madrassaTeacherPresentCount: auxCounts['madrassa_teachers'] ?? 0,
      madrassaTeacherYesterdayPresentCount: auxCounts['madrassa_teachers_yesterday'] ?? 0,
      onlineUsersCount: auxCounts['online'] ?? 1,
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

SnapshotDashboardData? _cachedRecentLocalSnapshot;
DateTime? _cachedRecentLocalSnapshotAt;
String? _cachedRecentLocalSnapshotKey;
Future<SnapshotDashboardData>? _inFlightLocalSnapshot;

Future<SnapshotDashboardData> buildLocalSnapshotDashboardData(Map<String, dynamic> userData) async {
  final role = (userData['role'] as String? ?? 'unknown').toLowerCase().trim();
  final String userBranchId = (userData['branchId'] as String? ?? '').toLowerCase().trim();
  final cacheKey = '$role|$userBranchId';

  final now = DateTime.now();
  if (_cachedRecentLocalSnapshot != null &&
      _cachedRecentLocalSnapshotKey == cacheKey &&
      _cachedRecentLocalSnapshotAt != null &&
      now.difference(_cachedRecentLocalSnapshotAt!).inSeconds < 5) {
    return _cachedRecentLocalSnapshot!;
  }

  if (_inFlightLocalSnapshot != null && _cachedRecentLocalSnapshotKey == cacheKey) {
    return await _inFlightLocalSnapshot!;
  }

  final future = _doBuildLocalSnapshotDashboardData(userData, role, userBranchId);
  _inFlightLocalSnapshot = future;
  _cachedRecentLocalSnapshotKey = cacheKey;
  try {
    final result = await future;
    _cachedRecentLocalSnapshot = result;
    _cachedRecentLocalSnapshotAt = DateTime.now();
    return result;
  } finally {
    _inFlightLocalSnapshot = null;
  }
}

Future<SnapshotDashboardData> _doBuildLocalSnapshotDashboardData(
    Map<String, dynamic> userData, String role, String userBranchId) async {

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
    final Set<String> cleanBranchIds = {'karachi', 'gujrat', 'sialkot', 'jalalpurjattan', 'rawalpindi'};
    for (final id in RecentActivityService.getAllBranchIds()) {
      final norm = id.toLowerCase().trim().replaceAll(' ', '_').replaceAll('-', '_');
      if (norm.contains('karachi') || norm.contains('haji') || norm.contains('kapaya') || norm.contains('saddar')) {
        cleanBranchIds.add('karachi');
      } else if (norm.contains('jalal')) {
        cleanBranchIds.add('jalalpurjattan');
      } else if (norm.contains('gujrat')) {
        cleanBranchIds.add('gujrat');
      } else if (norm.contains('sialkot')) {
        cleanBranchIds.add('sialkot');
      } else if (norm.contains('rawalpindi') || norm.contains('pindi')) {
        cleanBranchIds.add('rawalpindi');
      } else if (norm.isNotEmpty && norm != 'all' && norm != 'global' && norm != 'unknown') {
        // Short ids ('grt', 'skt', 'rwp', 'khi', 'jlj') fold to their branch; as rows of their
        // own they double-counted local records and looked up empty cloud branches.
        cleanBranchIds.add(LocalStorageService.sanitizeBranchId(norm, fallback: norm));
      }
    }
    final branchIds = cleanBranchIds.toList();

    // Background auto-sync of recent Dasterkhwaan tokens for visible branches
    for (final b in branchIds) {
      unawaited(LocalStorageService.downloadDasterkhwaanTokens(b, days: 2));
    }

    final Map<String, TodayVsYesterday> statsMap = await fetchTodayVsYesterdayPerBranch(branchIds, allowRemoteFallback: false);
    final weeklyPatients = await fetchWeeklyPatientCounts(branchIds);
    final List<HomeBranchRow> branchRows = [];
    final List<BranchStats> todayStatsList = [];
    final List<BranchStats> yesterdayStatsList = [];

    final karachiCamps = await fetchKarachiCampBreakdown(null, false);

    statsMap.forEach((bId, value) {
      if (bId == 'karachi') {
        final hasCampBreakdown = karachiCamps.totalPatients > 0;
        final hajiToday = BranchStats(
          zakat: hasCampBreakdown ? karachiCamps.hajiCampZakat : 0,
          nonZakat: hasCampBreakdown ? karachiCamps.hajiCampNonZakat : 0,
          gmwf: hasCampBreakdown ? karachiCamps.hajiCampGmwf : 0,
          prescribed: value.today.prescribed,
          dispensaryRevenue: hasCampBreakdown ? karachiCamps.hajiCampRevenue : 0,
          donations: 0,
        );

        final saddarToday = BranchStats(
          zakat: hasCampBreakdown ? karachiCamps.kapayaZakat : value.today.zakat,
          nonZakat: hasCampBreakdown ? karachiCamps.kapayaNonZakat : value.today.nonZakat,
          gmwf: hasCampBreakdown ? karachiCamps.kapayaGmwf : value.today.gmwf,
          prescribed: value.today.prescribed,
          dispensaryRevenue: hasCampBreakdown ? karachiCamps.kapayaRevenue : value.today.dispensaryRevenue,
          donations: value.today.donations,
          dasterkhwaan: value.today.dasterkhwaan,
          dasterkhwaanServed: value.today.dasterkhwaanServed,
        );

        final karachiWeekly = weeklyPatients['karachi'] ?? 0;
        final hajiWeekly = (karachiWeekly * 0.4).round();
        final saddarWeekly = karachiWeekly - hajiWeekly;

        branchRows.add(HomeBranchRow(
          id: 'karachi_haji',
          name: 'Karachi — Haji Camp Dispensary', subtitle: 'Morning ${karachiCamps.hajiCampMorningPatients} • Evening ${karachiCamps.hajiCampEveningPatients}',
          today: hajiToday,
          yesterday: value.yesterday,
          weeklyPatients: hajiWeekly,
        ));

        branchRows.add(HomeBranchRow(
          id: 'karachi_saddar',
          name: 'Karachi — Saddar Dispensary', subtitle: 'Morning ${karachiCamps.kapayaMorningPatients} • Evening ${karachiCamps.kapayaEveningPatients}',
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
      madrassaPresentCount: auxCounts['madrassa'] ?? 0,
      madrassaYesterdayPresentCount: auxCounts['madrassa_yesterday'] ?? 0,
      madrassaTeacherPresentCount: auxCounts['madrassa_teachers'] ?? 0,
      madrassaTeacherYesterdayPresentCount: auxCounts['madrassa_teachers_yesterday'] ?? 0,
      onlineUsersCount: auxCounts['online'] ?? 1,
    );
  } else {
    final branchId = (userBranchId.isNotEmpty && userBranchId != 'all' && userBranchId != 'global') ? userBranchId : 'karachi';
    unawaited(LocalStorageService.downloadDasterkhwaanTokens(branchId, days: 2));

    final todayStats = await fetchLocalBranchStats(branchId, DateTime.now(), allowRemoteFallback: false);
    final yesterdayStats = await fetchLocalBranchStats(branchId, DateTime.now().subtract(const Duration(days: 1)), allowRemoteFallback: false);
    final weeklyPatients = await fetchWeeklyPatientCounts([branchId]);

    final List<HomeBranchRow> branchRows = [];
    if (branchId == 'karachi') {
      final karachiCamps = await fetchKarachiCampBreakdown(null, false);
      final hasCampBreakdown = karachiCamps.totalPatients > 0;
      branchRows.add(HomeBranchRow(
        id: 'karachi_saddar',
        name: 'Karachi — Saddar Dispensary', subtitle: 'Morning ${karachiCamps.kapayaMorningPatients} • Evening ${karachiCamps.kapayaEveningPatients}',
        today: BranchStats(
          zakat: hasCampBreakdown ? karachiCamps.kapayaZakat : todayStats.zakat,
          nonZakat: hasCampBreakdown ? karachiCamps.kapayaNonZakat : todayStats.nonZakat,
          gmwf: hasCampBreakdown ? karachiCamps.kapayaGmwf : todayStats.gmwf,
          prescribed: todayStats.prescribed,
          dispensaryRevenue: hasCampBreakdown ? karachiCamps.kapayaRevenue : todayStats.dispensaryRevenue,
          donations: todayStats.donations,
          dasterkhwaan: todayStats.dasterkhwaan,
          dasterkhwaanServed: todayStats.dasterkhwaanServed,
        ),
        yesterday: yesterdayStats,
        weeklyPatients: weeklyPatients[branchId] ?? 0,
      ));
      branchRows.add(HomeBranchRow(
        id: 'karachi_haji',
        name: 'Karachi — Haji Camp Dispensary', subtitle: 'Morning ${karachiCamps.hajiCampMorningPatients} • Evening ${karachiCamps.hajiCampEveningPatients}',
        today: BranchStats(
          zakat: hasCampBreakdown ? karachiCamps.hajiCampZakat : 0,
          nonZakat: hasCampBreakdown ? karachiCamps.hajiCampNonZakat : 0,
          gmwf: hasCampBreakdown ? karachiCamps.hajiCampGmwf : 0,
          prescribed: todayStats.prescribed,
          dispensaryRevenue: hasCampBreakdown ? karachiCamps.hajiCampRevenue : 0,
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
      madrassaPresentCount: auxCounts['madrassa'] ?? 0,
      madrassaYesterdayPresentCount: auxCounts['madrassa_yesterday'] ?? 0,
      madrassaTeacherPresentCount: auxCounts['madrassa_teachers'] ?? 0,
      madrassaTeacherYesterdayPresentCount: auxCounts['madrassa_teachers_yesterday'] ?? 0,
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
  // Cloud-merged numbers (fetchSnapshotDashboardData). build() used to render only the
  // provider's local-only data and overwrite this with it, so on HQ/chairman PCs, which hold no
  // clinic tokens in Hive, everything uploaded by the branches showed as 0.
  SnapshotDashboardData? _remoteData;
  static final Set<String> _shownAppreciationSessionKeys = {};
  bool _isTrophyDismissed = false;
  bool _isAppreciationDialogShowing = false;
  DateTime _lastRefreshedAt = DateTime.now();
  bool _isRefreshing = false;

  @override
  void initState() {
    super.initState();
    _localFuture = buildLocalSnapshotDashboardData(widget.userData);
    _checkAndShowImmediateStartupAppreciation();
    _triggerBackgroundRemoteSync();
  }

  void _triggerBackgroundRemoteSync() {
    Future.delayed(const Duration(milliseconds: 600), () async {
      if (!mounted) return;
      try {
        final remoteData = await fetchSnapshotDashboardData(widget.userData);
        if (mounted) {
          setState(() {
            _remoteData = remoteData;
            _lastGlobalSnapshotData = remoteData;
            _localFuture = Future.value(remoteData);
            _lastRefreshedAt = DateTime.now();
          });
        }
      } catch (_) {}
    });
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
      _remoteData = null; // belongs to the previous user
      _localFuture = buildLocalSnapshotDashboardData(widget.userData);
      _checkAndShowImmediateStartupAppreciation();
      _triggerBackgroundRemoteSync();
    }
  }

  void _refresh() {
    clearLocalStatsCache();
    final uB = (widget.userData['branchId'] ?? widget.userData['branch'] ?? '').toString().toLowerCase().trim();
    if (uB.isNotEmpty && uB != 'all' && uB != 'global') {
      unawaited(LocalStorageService.downloadDasterkhwaanTokens(uB, days: 2, force: true));
    } else {
      for (final b in ['karachi', 'gujrat', 'sialkot', 'jalalpurjattan', 'rawalpindi']) {
        unawaited(LocalStorageService.downloadDasterkhwaanTokens(b, days: 2, force: true));
      }
    }
    final remote = fetchSnapshotDashboardData(widget.userData);
    setState(() {
      _isRefreshing = true;
      _localFuture = remote;
    });
    remote.then((d) {
      if (mounted) {
        setState(() {
          _remoteData = d;
          _lastGlobalSnapshotData = d;
          _lastRefreshedAt = DateTime.now();
          _isRefreshing = false;
        });
      }
    }).catchError((_) {
      if (mounted) {
        setState(() => _isRefreshing = false);
      }
    });
    ref.invalidate(snapshotDashboardDataProvider(_userKey));
  }

  Widget _buildSnapshotHeader({
    required String title,
    required List<Map<String, dynamic>> branches,
  }) {
    final t = widget.t;
    final isDark = t.isDarkCanvas;
    final updatedStr = DateFormat('hh:mm a').format(_lastRefreshedAt);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 680;
        final heading = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: TextStyle(
                color: t.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.4,
              ),
            ),
            const SizedBox(height: 3),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: GColor.successOf(isDark),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    'Live & cloud-merged · Updated $updatedStr',
                    style: TextStyle(
                      color: t.textSecondary,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        );

        final controls = Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            GlobalFilterBar(
              controller: dashboardController,
              branches: branches,
            ),
            OutlinedButton.icon(
              onPressed: _isRefreshing ? null : _refresh,
              icon: _isRefreshing
                  ? SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        color: t.textSecondary,
                      ),
                    )
                  : const Icon(Icons.refresh_rounded, size: 15),
              label: Text(
                _isRefreshing ? 'Syncing' : 'Refresh',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: t.textPrimary,
                backgroundColor: _dashSurface(t),
                side: BorderSide(color: _dashBorder(t), width: 1.0),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                minimumSize: const Size(0, 34),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Gr.r2),
                ),
              ),
            ),
          ],
        );

        if (isCompact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heading,
              const SizedBox(height: 10),
              controls,
            ],
          );
        }

        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Flexible(child: heading),
            const SizedBox(width: 12),
            controls,
          ],
        );
      },
    );
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
                    Icon(
                      Icons.error_outline_rounded,
                      size: 40,
                      color: GColor.dangerOf(isDark),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Failed to load snapshot dashboard: $err',
                      style: TextStyle(color: widget.t.textSecondary, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
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
        // Prefer the cloud-merged numbers once they've arrived; local data is the instant
        // first paint only.
        final shown = _remoteData ?? data;
        _lastGlobalSnapshotData = shown;
        return _buildBodyWithData(shown, hPad: hPad);
      },
    );
  }

  Widget _buildLoadingSkeleton(double hPad, bool isDark) {
    final borderCol = _dashBorder(widget.t);
    final fillCol = _dashSurface(widget.t);
    final chipCol = _dashSubtleSurface(widget.t);

    return AppSkeleton(
      isDark: isDark,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 170,
                      height: 20,
                      decoration: BoxDecoration(
                        color: chipCol,
                        borderRadius: BorderRadius.circular(Gr.r1),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      width: 220,
                      height: 12,
                      decoration: BoxDecoration(
                        color: chipCol,
                        borderRadius: BorderRadius.circular(Gr.r1),
                      ),
                    ),
                  ],
                ),
                Container(
                  width: 210,
                  height: 34,
                  decoration: BoxDecoration(
                    color: fillCol,
                    borderRadius: BorderRadius.circular(Gr.r2),
                    border: Border.all(color: borderCol),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Skeleton stat tiles row
            SizedBox(
              height: 106,
              child: Row(
                children: List.generate(
                  widget.isDesktop ? 5 : 2,
                  (index) => Expanded(
                    child: Container(
                      margin: EdgeInsets.only(right: index == (widget.isDesktop ? 4 : 1) ? 0 : 12),
                      decoration: BoxDecoration(
                        color: fillCol,
                        borderRadius: BorderRadius.circular(Gr.r3),
                        border: Border.all(color: borderCol),
                      ),
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Container(
                                width: 84,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: chipCol,
                                  borderRadius: BorderRadius.circular(Gr.r1),
                                ),
                              ),
                              Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  color: chipCol,
                                  borderRadius: BorderRadius.circular(Gr.r2),
                                ),
                              ),
                            ],
                          ),
                          Container(
                            width: 64,
                            height: 20,
                            decoration: BoxDecoration(
                              color: chipCol,
                              borderRadius: BorderRadius.circular(Gr.r1),
                            ),
                          ),
                          Container(
                            width: 96,
                            height: 10,
                            decoration: BoxDecoration(
                              color: chipCol,
                              borderRadius: BorderRadius.circular(Gr.r1),
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
              height: 340,
              decoration: BoxDecoration(
                color: fillCol,
                borderRadius: BorderRadius.circular(Gr.r4),
                border: Border.all(color: borderCol),
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
          } else if (id == 'madrassa_teachers') {
            module = baseModule.copyWith(
              title: 'Madrassa Teachers',
              builder: (context, data) => MadrassaDashboard(
                branchId: data['branchId'] ?? 'all',
                username: data['name'] ?? data['username'] ?? 'User',
                role: data['role'] ?? 'Admin',
                isAdmin: true,
                initialIndex: 3,
              ),
            );
          } else if (id == 'school_attendance') {
            module = baseModule.copyWith(
              title: 'School Student Attendance',
              builder: (context, data) => SchoolDashboard(
                branchId: data['branchId'] ?? 'all',
                username: data['name'] ?? data['username'] ?? LocalStorageService.getActiveUsername(),
                role: data['role'] ?? LocalStorageService.getActiveUserRole(),
                initialTabIndex: 2,
              ),
            );
          } else if (id == 'school_teacher_attendance') {
            module = baseModule.copyWith(
              title: 'School Faculty Attendance',
              builder: (context, data) => SchoolDashboard(
                branchId: data['branchId'] ?? 'all',
                username: data['name'] ?? data['username'] ?? LocalStorageService.getActiveUsername(),
                role: data['role'] ?? LocalStorageService.getActiveUserRole(),
                initialTabIndex: 3,
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
        final isHqManager = userRoleStr == 'hq manager' || userRoleStr == 'hq_manager';
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
            AppToast.showSnackBar(context, 
              SnackBar(
                content: Text('⚠️ Access restricted to your assigned branch (${RecentActivityService.resolveBranchName(userBranchId)}).'),
                backgroundColor: SoftPalette.orange400,
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

        final isDark = widget.t.isDarkCanvas;

        final donationsTile = HomeStatTile(
          label: 'Donations Today',
          value: fmtNum(today.donations),
          prefix: 'Rs ',
          icon: Icons.volunteer_activism_rounded,
          color: isDark ? SoftPalette.brightMint : SoftPalette.jadeEmerald,
          deltaPct: yesterday.donations == 0
              ? null
              : ((today.donations - yesterday.donations) / yesterday.donations) * 100,
          subtext: yesterday.donations == 0
              ? (today.donations > 0 ? 'First recorded today' : 'No receipts today')
              : null,
          t: widget.t,
          onTap: () => tryOpenModule('donations'),
        );

        final int todayPatients = today.zakat + today.nonZakat + today.gmwf;
        final int yesterdayPatients = yesterday.zakat + yesterday.nonZakat + yesterday.gmwf;
        final patientsTile = HomeStatTile(
          label: 'Patients Today',
          value: fmtNum(todayPatients),
          icon: Icons.people_alt_rounded,
          color: isDark ? SoftPalette.softLavender : SoftPalette.royalViolet,
          deltaPct: yesterdayPatients == 0
              ? null
              : ((todayPatients - yesterdayPatients) / yesterdayPatients) * 100,
          subtext: yesterdayPatients == 0
              ? (todayPatients > 0 ? 'Active registrations' : 'No patients today')
              : null,
          t: widget.t,
          onTap: () {
            final myBranchOrTop = (userBranchId.isNotEmpty && userBranchId != 'all') ? userBranchId : topBranchId;
            openBranchInBranchesModule(myBranchOrTop);
          },
        );

        // overallRevTile removed per request

        final madrassaTile = HomeStatTile(
          label: 'Madrassa Attendance',
          value: fmtNum(data.madrassaPresentCount),
          icon: Icons.menu_book_rounded,
          color: isDark ? SoftPalette.brightCyan : SoftPalette.deepCyan,
          deltaPct: data.madrassaYesterdayPresentCount == 0
              ? null
              : (((data.madrassaPresentCount - data.madrassaYesterdayPresentCount) / data.madrassaYesterdayPresentCount) * 100),
          subtext: data.madrassaYesterdayPresentCount == 0
              ? (data.madrassaPresentCount > 0 ? 'Students checked in' : 'No attendance marked')
              : null,
          t: widget.t,
          onTap: () => tryOpenModule('madrassa_attendance'),
        );

        final madrassaTeachersTile = HomeStatTile(
          label: 'Madrassa Teachers',
          value: fmtNum(data.madrassaTeacherPresentCount),
          icon: Icons.record_voice_over_rounded,
          color: isDark ? SoftPalette.brightOrchid : SoftPalette.plumOrchid,
          deltaPct: data.madrassaTeacherYesterdayPresentCount == 0
              ? null
              : (((data.madrassaTeacherPresentCount - data.madrassaTeacherYesterdayPresentCount) / data.madrassaTeacherYesterdayPresentCount) * 100),
          subtext: data.madrassaTeacherYesterdayPresentCount == 0
              ? (data.madrassaTeacherPresentCount > 0 ? 'Faculty present today' : 'No faculty check-ins')
              : null,
          t: widget.t,
          onTap: () => tryOpenModule('madrassa_teachers'),
        );

        final employeeAttendanceTile = HomeStatTile(
          label: 'Staff Attendance',
          value: fmtNum(data.empPresentCount),
          icon: Icons.co_present_rounded,
          color: isDark ? SoftPalette.brightCobalt : SoftPalette.cobaltBlue,
          subtext: data.empPresentCount > 0
              ? 'Biometric & manual check-ins'
              : 'No staff check-ins today',
          t: widget.t,
          onTap: () => tryOpenModule('employees'),
        );

        final schoolStudentsTile = HomeStatTile(
          label: 'School Students',
          value: fmtNum(data.studentPresentCount),
          icon: Icons.school_rounded,
          color: isDark ? SoftPalette.softIndigo : SoftPalette.luminousIndigo,
          subtext: data.studentPresentCount > 0
              ? 'Present across campuses'
              : 'No student check-ins',
          t: widget.t,
          onTap: () => tryOpenModule('school_attendance'),
        );

        final schoolTeachersTile = HomeStatTile(
          label: 'School Teachers',
          value: fmtNum(data.teacherPresentCount),
          icon: Icons.record_voice_over_rounded,
          color: isDark ? SoftPalette.sky350 : SoftPalette.sky550,
          subtext: data.teacherPresentCount > 0
              ? 'Faculty present today'
              : 'No faculty check-ins',
          t: widget.t,
          onTap: () => tryOpenModule('school_teacher_attendance'),
        );

        final String topBranchDisplayName = topRow != null
            ? topRow.name
            : (bestBranch != null
                ? bestBranch.name
                : RecentActivityService.resolveBranchName(userBranchId.isNotEmpty ? userBranchId : 'Karachi'));
        final String topBranchSubtext = (topRow != null &&
                (topRow.today.tokens > 0 || topRow.today.dispensaryRevenue > 0 || topRow.today.donations > 0))
            ? '${topRow.today.tokens} patients · Rs ${fmtNum(topRow.today.dispensaryRevenue + topRow.today.donations)}'
            : 'No branch activity yet';

        final activeBranchTile = HomeStatTile(
          label: isBranchManager ? 'Top Camp Today' : 'Top Branch Today',
          value: topRow != null ? topRow.name : RecentActivityService.resolveBranchName(userBranchId.isNotEmpty ? userBranchId : 'Karachi'),
          icon: Icons.emoji_events_rounded,
          color: isDark ? SoftPalette.brightGold : SoftPalette.warmMarigold,
          subtext: topBranchSubtext,
          t: widget.t,
          onTap: () => openBranchInBranchesModule(topBranchId),
        );

        final branchesSummaryTile = HomeStatTile(
          label: 'Top Branch Today',
          value: topBranchDisplayName,
          icon: Icons.emoji_events_rounded,
          color: isDark ? SoftPalette.brightGold : SoftPalette.warmMarigold,
          subtext: topBranchSubtext,
          t: widget.t,
          onTap: () => openBranchInBranchesModule(topBranchId),
        );

        final dasterkhwaanTokensTile = HomeStatTile(
          label: 'Food Tokens Issued',
          value: fmtNum(today.dasterkhwaan),
          icon: Icons.room_service_rounded,
          color: isDark ? SoftPalette.orange350 : SoftPalette.orange400,
          deltaPct: yesterday.dasterkhwaan == 0 ? null : ((today.dasterkhwaan - yesterday.dasterkhwaan) / yesterday.dasterkhwaan) * 100,
          subtext: yesterday.dasterkhwaan == 0
              ? (today.dasterkhwaan > 0 ? 'Meals queued today' : 'No tokens issued today')
              : null,
          t: widget.t,
          onTap: () => tryOpenModule('office_boy'),
        );

        final dasterkhwaanStockTile = HomeStatTile(
          label: 'Dasterkhawaan Stock',
          value: 'View Inventory',
          icon: Icons.inventory_2_outlined,
          color: isDark ? SoftPalette.brightCoral : SoftPalette.roseCoral,
          subtext: today.dasterkhwaanServed > 0
              ? '${today.dasterkhwaanServed} meals served today'
              : 'Open stock & audit log',
          isActionTile: true,
          t: widget.t,
          onTap: () => tryOpenModule('dasterkhwaan_inventory'),
        );

        final List<HomeStatTile> statTiles = [
          if (!isBranchManager) branchesSummaryTile else activeBranchTile,
          donationsTile,
          patientsTile,
          madrassaTile,
          madrassaTeachersTile,
          employeeAttendanceTile,
          schoolStudentsTile,
          schoolTeachersTile,
          dasterkhwaanTokensTile,
          dasterkhwaanStockTile,
        ];

        // Layout rows with GPU layer caching via RepaintBoundary
        final row2 = SizedBox(
          height: 360,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 4, child: RepaintBoundary(child: HomeRevenueLineChart(points: data.chartPoints, t: widget.t))),
              const SizedBox(width: DS.s2),
              Expanded(
                flex: 3,
                child: RepaintBoundary(
                  child: HomePatientsByBranchBarChart(
                    t: widget.t,
                    rows: data.branchRows,
                    onTapBranch: (bId) => openBranchInBranchesModule(bId),
                  ),
                ),
              ),
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
          height: 365,
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
          height: 300,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 3,
                child: HomeRecentDonationsTable(
                  activities: data.recentActivities,
                  t: widget.t,
                  onViewAll: () => tryOpenModule('donations'),
                ),
              ),
              const SizedBox(width: DS.s2),
              Expanded(
                flex: 4,
                child: HomeRecentPatientsTable(
                  activities: data.recentActivities,
                  t: widget.t,
                  onViewAll: () => tryOpenModule('patients_list'),
                ),
              ),
              const SizedBox(width: DS.s2),
              Expanded(
                flex: 3,
                child: QuickActionsRow(
                  availableModules: widget.availableModules,
                  t: widget.t,
                  onOpenModule: widget.onOpenModule,
                  todayFoodTokens: today.dasterkhwaan,
                ),
              ),
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

            final String rangeSubtitle = switch (filter.timeRange) {
              TimeRange.today => 'Today',
              TimeRange.yesterday => 'Yesterday',
              TimeRange.week => 'Past 7 days',
              TimeRange.biweek => 'Past 14 days',
              TimeRange.month => 'Past 30 days',
              TimeRange.thisMonth => 'This month',
              TimeRange.custom => 'Custom range',
            };

            if (isFiltered) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildSnapshotHeader(
                      title: rangeLabel,
                      branches: allLocalBranches,
                    ),
                    const SizedBox(height: 16),
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
                                color: isDark
                                    ? SoftPalette.brightMint
                                    : SoftPalette.jadeEmerald,
                                subtext: rangeSubtitle,
                                t: widget.t,
                              ),
                              HomeStatTile(
                                label: 'Donations',
                                value: fmtNum(activeStats.donations),
                                prefix: 'Rs ',
                                icon: Icons.volunteer_activism_rounded,
                                color: isDark
                                    ? SoftPalette.brightCyan
                                    : SoftPalette.deepCyan,
                                subtext: activeStats.donations > 0 ? rangeSubtitle : 'No donations in range',
                                t: widget.t,
                                onTap: () => tryOpenModule('donations'),
                              ),
                              HomeStatTile(
                                label: 'Dispensary Revenue',
                                value: fmtNum(activeStats.dispensaryRevenue),
                                prefix: 'Rs ',
                                icon: Icons.local_pharmacy_rounded,
                                color: isDark
                                    ? SoftPalette.brightCobalt
                                    : SoftPalette.cobaltBlue,
                                subtext: rangeSubtitle,
                                t: widget.t,
                              ),
                              HomeStatTile(
                                label: 'Patients Treated',
                                value: fmtNum(activeStats.tokens),
                                icon: Icons.people_alt_rounded,
                                color: isDark
                                    ? SoftPalette.softLavender
                                    : SoftPalette.royalViolet,
                                subtext: '${activeStats.dispensed} prescriptions',
                                t: widget.t,
                              ),
                              HomeStatTile(
                                label: BranchLabels.text('Zakat Patients', filter.branchId),
                                value: fmtNum(activeStats.zakat),
                                icon: Icons.assignment_ind_rounded,
                                color: isDark
                                    ? SoftPalette.brightGold
                                    : SoftPalette.warmMarigold,
                                subtext: activeStats.tokens > 0
                                    ? '${((activeStats.zakat / activeStats.tokens) * 100).toStringAsFixed(0)}% of patients'
                                    : rangeSubtitle,
                                t: widget.t,
                              ),
                              HomeStatTile(
                                label: BranchLabels.text('Non-Zakat Patients', filter.branchId),
                                value: fmtNum(activeStats.nonZakat),
                                icon: Icons.badge_rounded,
                                color: isDark
                                    ? SoftPalette.softIndigo
                                    : SoftPalette.luminousIndigo,
                                subtext: activeStats.tokens > 0
                                    ? '${((activeStats.nonZakat / activeStats.tokens) * 100).toStringAsFixed(0)}% of patients'
                                    : rangeSubtitle,
                                t: widget.t,
                              ),
                              HomeStatTile(
                                label: BranchLabels.text('GMWF Patients', filter.branchId),
                                value: fmtNum(activeStats.gmwf),
                                icon: Icons.favorite_outline_rounded,
                                imageAsset: 'assets/logo/gmwf-1.webp',
                                color: isDark
                                    ? SoftPalette.brightOrchid
                                    : SoftPalette.plumOrchid,
                                subtext: activeStats.tokens > 0
                                    ? '${((activeStats.gmwf / activeStats.tokens) * 100).toStringAsFixed(0)}% of patients'
                                    : rangeSubtitle,
                                t: widget.t,
                              ),
                              HomeStatTile(
                                label: 'Food Tokens Issued',
                                value: fmtNum(activeStats.dasterkhwaan),
                                icon: Icons.room_service_rounded,
                                color: isDark
                                    ? SoftPalette.brightCoral
                                    : SoftPalette.roseCoral,
                                subtext: activeStats.dasterkhwaanServed > 0
                                    ? '${activeStats.dasterkhwaanServed} meals served'
                                    : rangeSubtitle,
                                t: widget.t,
                                onTap: () => tryOpenModule('office_boy'),
                              ),
                            ];

                            final filteredRow3 = SizedBox(
                              height: 365,
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

                            if (!widget.isDesktop) {
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  HomeStatTileRow(tiles: multiTiles),
                                  const SizedBox(height: DS.s2),
                                  HomePatientsByCategoryDonut(t: widget.t, s: activeStats),
                                  const SizedBox(height: DS.s2),
                                  HomeBranchPerformanceTable(
                                    t: widget.t,
                                    rows: sortedBranchRows,
                                    onTapBranch: (bId) => _navigateToBranch(bId),
                                  ),
                                  const SizedBox(height: DS.s2),
                                  HomeRevenueLineChart(points: data.chartPoints, t: widget.t),
                                  const SizedBox(height: DS.s2),
                                  HomePatientsByBranchBarChart(
                                    t: widget.t,
                                    rows: data.branchRows,
                                    onTapBranch: (bId) => _navigateToBranch(bId),
                                  ),
                                ],
                              );
                            }

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                HomeStatTileRow(tiles: multiTiles),
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
                  _buildSnapshotHeader(
                    title: "Today's Snapshot",
                    branches: allLocalBranches,
                  ),
                  const SizedBox(height: 16),
                  if (widget.isDesktop && isHqManager) ...[
                    // ── HQ Manager Command-Center Bento Grid ────────────────
                    SizedBox(
                      height: 350,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            flex: 7,
                            child: Column(
                              children: [
                                Expanded(
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      Expanded(child: donationsTile),
                                      const SizedBox(width: DS.s2),
                                      Expanded(child: patientsTile),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: DS.s2),
                                Expanded(
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      Expanded(child: employeeAttendanceTile),
                                      const SizedBox(width: DS.s2),
                                      Expanded(child: madrassaTile),
                                    ],
                                  ),
                                ),
                              ],
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
                        ],
                      ),
                    ),
                    const SizedBox(height: DS.s3),
                    HomeStatTileRow(tiles: [
                      madrassaTeachersTile,
                      schoolStudentsTile,
                      schoolTeachersTile,
                      activeBranchTile,
                    ]),
                    const SizedBox(height: DS.s3),
                    SizedBox(
                      height: 360,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            flex: 7,
                            child: RepaintBoundary(
                              child: HomeRevenueLineChart(
                                points: data.chartPoints,
                                t: widget.t,
                              ),
                            ),
                          ),
                          const SizedBox(width: DS.s2),
                          Expanded(
                            flex: 5,
                            child: RepaintBoundary(
                              child: HomePatientsByCategoryDonut(
                                t: widget.t,
                                s: today,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: DS.s3),
                    SizedBox(
                      height: 360,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            flex: bestBranch != null ? 7 : 12,
                            child: RepaintBoundary(
                              child: HomePatientsByBranchBarChart(
                                t: widget.t,
                                rows: data.branchRows,
                                onTapBranch: (bId) => openBranchInBranchesModule(bId),
                              ),
                            ),
                          ),
                          if (bestBranch != null) ...[
                            const SizedBox(width: DS.s2),
                            Expanded(
                              flex: 5,
                              child: RepaintBoundary(
                                child: HomeBestBranchSpotlight(
                                  branchName: bestBranch.name,
                                  revenue: bestBranch.today.dispensaryRevenue,
                                  donations: bestBranch.today.donations,
                                  patients: bestBranch.today.zakat +
                                      bestBranch.today.nonZakat +
                                      bestBranch.today.gmwf,
                                  growthPct: (bestBranch.yesterday.dispensaryRevenue > 0)
                                      ? (((bestBranch.today.dispensaryRevenue -
                                                  bestBranch.yesterday.dispensaryRevenue) /
                                              bestBranch.yesterday.dispensaryRevenue) *
                                          100)
                                      : ((bestBranch.today.dispensaryRevenue > 0 ||
                                              (bestBranch.today.zakat +
                                                      bestBranch.today.nonZakat +
                                                      bestBranch.today.gmwf) >
                                                  0)
                                          ? 100.0
                                          : null),
                                  onTap: () => openBranchInBranchesModule(bestBranch!.id),
                                  t: widget.t,
                                  title: 'Best Branch Today',
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: DS.s3),
                    row4,
                  ] else if (widget.isDesktop) ...[
                    HomeStatTileRow(tiles: statTiles),
                    const SizedBox(height: DS.s3),
                    row3,
                    const SizedBox(height: DS.s3),
                    row2,
                    const SizedBox(height: DS.s3),
                    row4,
                  ] else ...[
                    SizedBox(
                      height: 270,
                      child: QuickActionsRow(
                        availableModules: widget.availableModules,
                        t: widget.t,
                        onOpenModule: widget.onOpenModule,
                        todayFoodTokens: today.dasterkhwaan,
                      ),
                    ),
                    const SizedBox(height: DS.s2),
                    HomeStatTileRow(tiles: statTiles),
                    const SizedBox(height: DS.s2),
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
                    HomePatientsByCategoryDonut(t: widget.t, s: today),
                    const SizedBox(height: DS.s2),
                    HomeBranchPerformanceTable(
                      t: widget.t,
                      rows: sortedBranchRows,
                      onTapBranch: (bId) => _navigateToBranch(bId),
                    ),
                    const SizedBox(height: DS.s2),
                    HomeRevenueLineChart(points: data.chartPoints, t: widget.t),
                    const SizedBox(height: DS.s2),
                    HomePatientsByBranchBarChart(
                      t: widget.t,
                      rows: data.branchRows,
                      onTapBranch: (bId) => _navigateToBranch(bId),
                    ),
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
                    HomeRecentDonationsTable(
                      activities: data.recentActivities,
                      t: widget.t,
                      onViewAll: () => tryOpenModule('donations'),
                    ),
                    const SizedBox(height: DS.s2),
                    HomeRecentPatientsTable(
                      activities: data.recentActivities,
                      t: widget.t,
                      onViewAll: () => tryOpenModule('patients_list'),
                    ),
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

        final headerAccent =
            isDark ? SoftPalette.brightCyan : SoftPalette.deepCyan;
        final saddarAccent =
            isDark ? SoftPalette.softLavender : SoftPalette.royalViolet;
        final hajiAccent =
            isDark ? SoftPalette.brightCobalt : SoftPalette.cobaltBlue;

        return Container(
          padding: const EdgeInsets.all(16),
          decoration: _dashCardDecoration(widget.t, radius: Gr.r4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Icon(
                          Icons.location_city_rounded,
                          color: headerAccent,
                          size: 19,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Karachi Branch — Dual Dispensary Camps Breakdown',
                            style: TextStyle(
                              color: widget.t.textPrimary,
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.25,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: headerAccent.withValues(alpha: isDark ? 0.16 : 0.10),
                      borderRadius: BorderRadius.circular(Gr.rFull),
                      border: Border.all(
                        color: headerAccent.withValues(alpha: isDark ? 0.35 : 0.25),
                      ),
                    ),
                    child: Text(
                      'Combined: ${data.totalPatients} Patients Today',
                      style: TextStyle(
                        color: headerAccent,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Divider(height: 1, thickness: 1, color: _dashBorder(widget.t)),
              const SizedBox(height: 12),
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
                      badgeColor: saddarAccent,
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
                      badgeColor: hajiAccent,
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
    final revenueColor =
        isDark ? SoftPalette.brightMint : SoftPalette.jadeEmerald;
    final morningColor =
        isDark ? SoftPalette.brightGold : SoftPalette.warmMarigold;
    final eveningColor =
        isDark ? SoftPalette.softIndigo : SoftPalette.luminousIndigo;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: badgeColor.withValues(alpha: isDark ? 0.14 : 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: badgeColor.withValues(alpha: isDark ? 0.30 : 0.24),
        ),
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
                    color: widget.t.textPrimary,
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
                style: TextStyle(
                  color: revenueColor,
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
              color: _dashSubtleSurface(widget.t),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _dashBorder(widget.t)),
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
                        color: morningColor.withValues(alpha: isDark ? 0.18 : 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.wb_sunny_rounded, color: morningColor, size: 13),
                          const SizedBox(width: 3),
                          Text(
                            'Morning',
                            style: TextStyle(
                              color: morningColor,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$morningTotal Patients',
                      style: TextStyle(
                        color: widget.t.textPrimary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: _dashSurface(widget.t),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: _dashBorder(widget.t)),
                      ),
                      child: Text(
                        'Z: $morningZakat   NZ: $morningNonZakat   G: $morningGmwf',
                        style: TextStyle(
                          color: widget.t.textSecondary,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Divider(height: 1, color: _dashBorder(widget.t)),
                const SizedBox(height: 6),
                // Evening Session Row
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: eveningColor.withValues(alpha: isDark ? 0.18 : 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.nights_stay_rounded, color: eveningColor, size: 13),
                          const SizedBox(width: 3),
                          Text(
                            'Evening',
                            style: TextStyle(
                              color: eveningColor,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$eveningTotal Patients',
                      style: TextStyle(
                        color: widget.t.textPrimary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: _dashSurface(widget.t),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: _dashBorder(widget.t)),
                      ),
                      child: Text(
                        'Z: $eveningZakat   NZ: $eveningNonZakat   G: $eveningGmwf',
                        style: TextStyle(
                          color: widget.t.textSecondary,
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
                  color: widget.t.textTertiary,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                BranchLabels.text('Zakat: $zakat | Non-Zakat: $nonZakat | GMWF: $gmwf'),
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
