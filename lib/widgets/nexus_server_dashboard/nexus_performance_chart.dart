import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'nexus_colors.dart';

class NexusTelemetryPoint {
  final DateTime timestamp;
  final double cpuPercent; // 0.0 - 1.0
  final double ramPercent; // 0.0 - 1.0

  const NexusTelemetryPoint({
    required this.timestamp,
    required this.cpuPercent,
    required this.ramPercent,
  });
}

class NexusPerformanceChart extends StatefulWidget {
  final List<NexusTelemetryPoint> telemetryHistory;
  final double currentCpu;
  final double currentRam;

  const NexusPerformanceChart({
    super.key,
    required this.telemetryHistory,
    required this.currentCpu,
    required this.currentRam,
  });

  @override
  State<NexusPerformanceChart> createState() => _NexusPerformanceChartState();
}

class _NexusPerformanceChartState extends State<NexusPerformanceChart> {
  String _selectedRange = '15m';
  final List<String> _ranges = const ['15m', '1h', '6h', '24h'];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: NexusColors.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NexusColors.cardBorder, width: 1.0),
        boxShadow: const [
          BoxShadow(
            color: Color(0x06000000),
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Server Performance',
                    style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: NexusColors.textMain,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Live telemetry for CPU and memory utilization',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: NexusColors.textSecondary,
                    ),
                  ),
                ],
              ),
              // Time Range Selector
              Container(
                decoration: BoxDecoration(
                  color: NexusColors.mainBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: NexusColors.cardBorder),
                ),
                padding: const EdgeInsets.all(3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: _ranges.map((r) {
                    final isSel = r == _selectedRange;
                    return InkWell(
                      onTap: () => setState(() => _selectedRange = r),
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: isSel ? NexusColors.cardBg : Colors.transparent,
                          borderRadius: BorderRadius.circular(6),
                          boxShadow: isSel
                              ? const [
                                  BoxShadow(
                                    color: Color(0x08000000),
                                    blurRadius: 4,
                                    offset: Offset(0, 1),
                                  )
                                ]
                              : null,
                        ),
                        child: Text(
                          r,
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: isSel ? FontWeight.w600 : FontWeight.w500,
                            color: isSel ? NexusColors.textMain : NexusColors.textSecondary,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Legend Row
          Row(
            children: [
              _buildLegendItem('CPU Utilization', NexusColors.cpuAccent, '${(widget.currentCpu * 100).toStringAsFixed(0)}%'),
              const SizedBox(width: 20),
              _buildLegendItem('Memory Usage', NexusColors.ramAccent, '${(widget.currentRam * 100).toStringAsFixed(0)}%'),
            ],
          ),
          const SizedBox(height: 20),

          // Chart Canvas
          SizedBox(
            height: 220,
            child: CustomPaint(
              painter: _NexusLineChartPainter(
                history: widget.telemetryHistory,
                currentCpu: widget.currentCpu,
                currentRam: widget.currentRam,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLegendItem(String label, Color color, String currentValue) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: NexusColors.textSecondary,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          currentValue,
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: NexusColors.textMain,
          ),
        ),
      ],
    );
  }
}

class _NexusLineChartPainter extends CustomPainter {
  final List<NexusTelemetryPoint> history;
  final double currentCpu;
  final double currentRam;

  _NexusLineChartPainter({
    required this.history,
    required this.currentCpu,
    required this.currentRam,
  });

  /// Theme the last paint used (repaint when the server theme switches light/dark).
  bool _paintedDark = NexusColors.isDark;

  @override
  void paint(Canvas canvas, Size size) {
    _paintedDark = NexusColors.isDark;
    const leftMargin = 38.0;
    const bottomMargin = 24.0;
    final chartWidth = size.width - leftMargin;
    final chartHeight = size.height - bottomMargin;

    // Grid line paint
    final gridPaint = Paint()
      ..color = NexusColors.cardBorder
      ..strokeWidth = 1.0;

    // Label style
    final labelStyle = GoogleFonts.inter(
      fontSize: 10,
      fontWeight: FontWeight.w500,
      color: NexusColors.textSecondary,
    );

    // 1. Draw horizontal grid lines & Y-axis labels (0%, 25%, 50%, 75%, 100%)
    const ySteps = [1.0, 0.75, 0.5, 0.25, 0.0];
    for (final step in ySteps) {
      final y = chartHeight * (1.0 - step);
      canvas.drawLine(
        Offset(leftMargin, y),
        Offset(size.width, y),
        gridPaint,
      );

      final textSpan = TextSpan(
        text: '${(step * 100).toInt()}%',
        style: labelStyle,
      );
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(
        canvas,
        Offset(leftMargin - textPainter.width - 8, y - textPainter.height / 2),
      );
    }

    // Real samples only (this used to draw invented sine-wave points when there was no
    // history, which looked like live CPU data but was not).
    final effectiveHistory = List<NexusTelemetryPoint>.from(history);
    final n = effectiveHistory.length;
    if (n < 2) {
      final tp = TextPainter(
        text: TextSpan(text: 'Collecting live readings…', style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(leftMargin + (chartWidth - tp.width) / 2, chartHeight / 2 - tp.height / 2));
      return;
    }

    final cpuPoints = <Offset>[];
    final ramPoints = <Offset>[];

    for (int i = 0; i < n; i++) {
      final x = leftMargin + (i / (n - 1)) * chartWidth;
      final pt = effectiveHistory[i];
      final yCpu = chartHeight * (1.0 - pt.cpuPercent.clamp(0.0, 1.0));
      final yRam = chartHeight * (1.0 - pt.ramPercent.clamp(0.0, 1.0));
      cpuPoints.add(Offset(x, yCpu));
      ramPoints.add(Offset(x, yRam));
    }

    // 2. Draw gradients and lines for RAM (Green)
    _drawSeries(canvas, ramPoints, chartHeight, leftMargin, size.width, NexusColors.ramAccent);

    // 3. Draw gradients and lines for CPU (Blue)
    _drawSeries(canvas, cpuPoints, chartHeight, leftMargin, size.width, NexusColors.cpuAccent);

    // 4. Draw X-axis timestamps from the real time span of the samples.
    final spanSec = math.max(1, effectiveHistory.last.timestamp.difference(effectiveHistory.first.timestamp).inSeconds);
    String ago(double frac) {
      final s = (spanSec * frac).round();
      if (s <= 0) return 'Now';
      return s >= 60 ? '${(s / 60).round()}m ago' : '${s}s ago';
    }
    final xSteps = [ago(1.0), ago(2 / 3), ago(1 / 3), 'Now'];
    for (int i = 0; i < xSteps.length; i++) {
      final x = leftMargin + (i / (xSteps.length - 1)) * chartWidth;
      final textSpan = TextSpan(
        text: xSteps[i],
        style: labelStyle,
      );
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      )..layout();
      final textX = (x - textPainter.width / 2).clamp(leftMargin, size.width - textPainter.width);
      textPainter.paint(canvas, Offset(textX, chartHeight + 8));
    }
  }

  void _drawSeries(
    Canvas canvas,
    List<Offset> points,
    double chartHeight,
    double leftMargin,
    double totalWidth,
    Color color,
  ) {
    if (points.isEmpty) return;

    // Fill Path
    final fillPath = Path();
    fillPath.moveTo(points.first.dx, chartHeight);
    fillPath.lineTo(points.first.dx, points.first.dy);

    for (int i = 1; i < points.length; i++) {
      final p0 = points[i - 1];
      final p1 = points[i];
      final cx = (p0.dx + p1.dx) / 2;
      fillPath.cubicTo(cx, p0.dy, cx, p1.dy, p1.dx, p1.dy);
    }

    fillPath.lineTo(points.last.dx, chartHeight);
    fillPath.close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          color.withValues(alpha: 0.16),
          color.withValues(alpha: 0.0),
        ],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(Rect.fromLTWH(leftMargin, 0, totalWidth - leftMargin, chartHeight));

    canvas.drawPath(fillPath, fillPaint);

    // Stroke Path
    final strokePath = Path();
    strokePath.moveTo(points.first.dx, points.first.dy);
    for (int i = 1; i < points.length; i++) {
      final p0 = points[i - 1];
      final p1 = points[i];
      final cx = (p0.dx + p1.dx) / 2;
      strokePath.cubicTo(cx, p0.dy, cx, p1.dy, p1.dx, p1.dy);
    }

    final strokePaint = Paint()
      ..color = color
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawPath(strokePath, strokePaint);

    // Current point dot
    final last = points.last;
    canvas.drawCircle(
      last,
      4.5,
      Paint()..color = NexusColors.cardBg,
    );
    canvas.drawCircle(
      last,
      3.2,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _NexusLineChartPainter oldDelegate) {
    // History is a rolling list (same length once full), so compare the newest sample too.
    return oldDelegate.currentCpu != currentCpu ||
        oldDelegate.currentRam != currentRam ||
        oldDelegate.history.length != history.length ||
        (history.isNotEmpty && oldDelegate.history.isNotEmpty &&
            oldDelegate.history.last.timestamp != history.last.timestamp) ||
        NexusColors.isDark != _paintedDark;
  }
}

