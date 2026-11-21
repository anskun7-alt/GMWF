import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:gmwf/design/tokens/comfort_colors.dart';

/// Consistent, theme-aware medicine icon badge used across Doctor, History,
/// Dispenser/Pharmacy form, and Inventory screens.
class MedicineIconBadge extends StatelessWidget {
  final String name;
  final String type;
  final double size;
  final double iconSize;
  final double borderRadius;
  final bool showBorder;

  const MedicineIconBadge({
    super.key,
    required this.name,
    this.type = '',
    this.size = 24,
    this.iconSize = 13,
    this.borderRadius = 6,
    this.showBorder = false,
  });

  static String resolveType({required String name, String type = ''}) {
    final t = type.trim().toLowerCase();
    final n = name.trim().toLowerCase();
    if (t.contains('tablet') || t == 'tab' || n.startsWith('tab')) return 'Tablet';
    if (t.contains('capsule') || t == 'cap' || n.startsWith('cap')) return 'Capsule';
    if (t.contains('syp') ||
        t.contains('syrup') ||
        t.contains('susp') ||
        t.contains('drop') ||
        n.startsWith('syp') ||
        n.startsWith('drop')) {
      return 'Syrup';
    }
    if (t.contains('drip set')) return 'Drip Set';
    if (t.contains('infusion') || t.contains('drip') || t.contains('iv') || n.contains('drip')) {
      return 'Infusion';
    }
    if (t.contains('cannula')) return 'Cannula';
    if (t.contains('syringe') || t.contains('needle')) return 'Syringe';
    if (t.contains('inj') ||
        t.contains('amp') ||
        t.contains('vial') ||
        n.contains('inj')) {
      return 'Injection';
    }
    if (t.contains('nebul')) return 'Nebulization';
    if (t.contains('dress') || t.contains('bandage') || t.contains('plast')) {
      return 'Dressing Item';
    }
    if (t.contains('consum')) return 'Consumables';
    return type.isNotEmpty ? type : 'Tablet';
  }

  static IconData iconFor({required String name, String type = ''}) {
    final t = type.toLowerCase();
    final n = name.toLowerCase();
    if (t.contains('inj') ||
        t.contains('drip') ||
        t.contains('iv') ||
        t.contains('amp') ||
        t.contains('vial') ||
        n.contains('inj') ||
        n.contains('drip')) {
      return Icons.vaccines_rounded;
    }
    if (t.contains('syp') ||
        t.contains('syrup') ||
        t.contains('susp') ||
        t.contains('drop') ||
        n.startsWith('syp') ||
        n.startsWith('drop')) {
      return Icons.local_drink_rounded;
    }
    return Icons.medication_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final resolved = resolveType(name: name, type: type);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.brand.withValues(alpha: isDark ? 0.22 : 0.12),
        borderRadius: BorderRadius.circular(borderRadius),
        border: showBorder
            ? Border.all(color: c.brand.withValues(alpha: isDark ? 0.42 : 0.26))
            : null,
      ),
      child: MedicineTypeIcon(
        type: resolved,
        size: iconSize + 1,
        color: c.brand,
      ),
    );
  }
}

/// Crisp vector illustration icon representing the exact physical form of each
/// medicine category:
/// - Tablet: Round scored tablet with bisecting score line + secondary tablet
/// - Capsule: Tilted two-tone oblong capsule (filled cap + outlined body)
/// - Syrup: Medicine bottle with ribbed cap, sloped shoulders, label & droplet
/// - Dressing Item: Tilted adhesive bandage (Sunny Plast / Band-Aid) with gauze pad
/// - Infusion / Drip: Hanging IV fluid bag with liquid level, ticks & bottom nozzle
/// - Injection: Angled hypodermic syringe with liquid fill, needle & droplet
/// - Syringe / Needle: Graduated syringe with plunger & volume scale ticks
/// - Cannula: Winged IV butterfly cannula with catheter tip & injection port
/// - Drip Set: IV drip chamber with falling droplet & tubing loop
/// - Nebulization: Nebulizer cup/mouthpiece with rising aerosol mist waves
/// - Consumables: Medical supply shield/box with cross
/// - Others: First-aid medical kit with handle and cross
class MedicineTypeIcon extends StatelessWidget {
  final String type;
  final double size;
  final Color color;

  const MedicineTypeIcon({
    super.key,
    required this.type,
    this.size = 16,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _MedicineTypePainter(
          type: type.trim().toLowerCase(),
          color: color,
        ),
      ),
    );
  }
}

class _MedicineTypePainter extends CustomPainter {
  final String type;
  final Color color;

  const _MedicineTypePainter({
    required this.type,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final sw = (w * 0.095).clamp(1.25, 2.2);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = sw
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    final fillSolid = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final fillSoft = Paint()
      ..color = color.withValues(alpha: 0.20)
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    if (type == 'all') {
      _drawAllGrid(canvas, w, h, stroke, fillSolid, fillSoft);
    } else if (type.contains('tablet') || type == 'tab') {
      _drawTablet(canvas, w, h, sw, stroke, fillSoft);
    } else if (type.contains('capsule') || type == 'cap') {
      _drawCapsule(canvas, w, h, sw, stroke, fillSolid, fillSoft);
    } else if (type.contains('syrup') || type.contains('syp') || type.contains('drop')) {
      _drawSyrup(canvas, w, h, sw, stroke, fillSolid, fillSoft);
    } else if (type.contains('dress') || type.contains('bandage') || type.contains('plast')) {
      _drawDressingBandage(canvas, w, h, sw, stroke, fillSolid, fillSoft);
    } else if (type.contains('drip set')) {
      _drawDripSet(canvas, w, h, sw, stroke, fillSolid, fillSoft);
    } else if (type.contains('infusion') || type.contains('drip') || type == 'iv') {
      _drawInfusionBag(canvas, w, h, sw, stroke, fillSolid, fillSoft);
    } else if (type.contains('cannula')) {
      _drawCannula(canvas, w, h, sw, stroke, fillSolid, fillSoft);
    } else if (type.contains('inj') || type.contains('syringe') || type.contains('needle')) {
      _drawSyringe(
        canvas,
        w,
        h,
        sw,
        stroke,
        fillSolid,
        fillSoft,
        withDroplet: type.contains('inj'),
      );
    } else if (type.contains('nebul')) {
      _drawNebulizer(canvas, w, h, sw, stroke, fillSolid, fillSoft);
    } else if (type.contains('consum')) {
      _drawConsumables(canvas, w, h, sw, stroke, fillSolid, fillSoft);
    } else {
      _drawMedicalKit(canvas, w, h, sw, stroke, fillSolid, fillSoft);
    }
  }

  /// 1. TABLET: Round scored medical tablet with bisecting score groove + back tablet
  void _drawTablet(
    Canvas canvas,
    double w,
    double h,
    double sw,
    Paint stroke,
    Paint fillSoft,
  ) {
    // Back tablet at top-right (clipped outside front tablet)
    final frontCenter = Offset(w * 0.42, h * 0.57);
    final frontRadius = w * 0.34;
    final backCenter = Offset(w * 0.68, h * 0.31);
    final backRadius = w * 0.23;

    canvas.save();
    final clipPath = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Rect.fromLTWH(0, 0, w, h))
      ..addOval(Rect.fromCircle(center: frontCenter, radius: frontRadius + sw * 0.6));
    canvas.clipPath(clipPath);
    canvas.drawCircle(backCenter, backRadius, fillSoft);
    canvas.drawCircle(backCenter, backRadius, stroke);
    final backAngle = -math.pi / 4;
    final bOffset = Offset(math.cos(backAngle), math.sin(backAngle)) * (backRadius * 0.72);
    canvas.drawLine(backCenter - bOffset, backCenter + bOffset, stroke);
    canvas.restore();

    // Front main scored tablet
    canvas.drawCircle(frontCenter, frontRadius, fillSoft);
    canvas.drawCircle(frontCenter, frontRadius, stroke);

    // Bisecting score groove across the tablet
    const angle = -math.pi / 4;
    final dir = Offset(math.cos(angle), math.sin(angle));
    canvas.drawLine(
      frontCenter - dir * (frontRadius * 0.85),
      frontCenter + dir * (frontRadius * 0.85),
      stroke,
    );
  }

  /// 2. CAPSULE: Tilted two-tone oblong pill capsule (half solid cap, half tinted body)
  void _drawCapsule(
    Canvas canvas,
    double w,
    double h,
    double sw,
    Paint stroke,
    Paint fillSolid,
    Paint fillSoft,
  ) {
    canvas.save();
    canvas.translate(w * 0.5, h * 0.5);
    canvas.rotate(-math.pi / 4);

    final pillW = w * 0.42;
    final pillH = h * 0.88;
    final r = pillW / 2;
    final pillRect = Rect.fromCenter(center: Offset.zero, width: pillW, height: pillH);
    final pillRRect = RRect.fromRectAndRadius(pillRect, Radius.circular(r));

    // Bottom half (body) soft tint
    canvas.save();
    canvas.clipRRect(pillRRect);
    canvas.drawRect(Rect.fromLTRB(-pillW, 0, pillW, pillH), fillSoft);
    // Top half (cap) solid fill
    canvas.drawRect(Rect.fromLTRB(-pillW, -pillH, pillW, 0), fillSolid);
    canvas.restore();

    // Full capsule outline + middle seam line
    canvas.drawRRect(pillRRect, stroke);
    canvas.drawLine(Offset(-pillW * 0.48, 0), Offset(pillW * 0.48, 0), stroke);

    // Subtle highlight line on bottom body half
    final highlightPaint = Paint()
      ..color = color.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = sw * 0.75
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(-pillW * 0.22, pillH * 0.14),
      Offset(-pillW * 0.22, pillH * 0.30),
      highlightPaint,
    );

    canvas.restore();
  }

  /// 3. SYRUP: Classic pharmacy syrup bottle with cap, neck, sloped shoulders & label
  void _drawSyrup(
    Canvas canvas,
    double w,
    double h,
    double sw,
    Paint stroke,
    Paint fillSolid,
    Paint fillSoft,
  ) {
    // Cap
    final capRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(w * 0.5, h * 0.14), width: w * 0.34, height: h * 0.12),
      Radius.circular(w * 0.04),
    );
    canvas.drawRRect(capRect, fillSolid);

    // Bottle path: neck -> sloped shoulders -> body
    final bodyPath = Path()
      ..moveTo(w * 0.39, h * 0.20)
      ..lineTo(w * 0.39, h * 0.28)
      ..quadraticBezierTo(w * 0.22, h * 0.36, w * 0.22, h * 0.46)
      ..lineTo(w * 0.22, h * 0.84)
      ..quadraticBezierTo(w * 0.22, h * 0.91, w * 0.30, h * 0.91)
      ..lineTo(w * 0.70, h * 0.91)
      ..quadraticBezierTo(w * 0.78, h * 0.91, w * 0.78, h * 0.84)
      ..lineTo(w * 0.78, h * 0.46)
      ..quadraticBezierTo(w * 0.78, h * 0.36, w * 0.61, h * 0.28)
      ..lineTo(w * 0.61, h * 0.20)
      ..close();

    canvas.drawPath(bodyPath, fillSoft);
    canvas.drawPath(bodyPath, stroke);

    // Medical cross on bottle label
    final cx = w * 0.50;
    final cy = h * 0.63;
    final arm = w * 0.11;
    canvas.drawLine(Offset(cx - arm, cy), Offset(cx + arm, cy), stroke);
    canvas.drawLine(Offset(cx, cy - arm), Offset(cx, cy + arm), stroke);
  }

  /// 4. DRESSING ITEM: Tilted Adhesive First-Aid Bandage (Sunny Plast / Band-Aid)
  void _drawDressingBandage(
    Canvas canvas,
    double w,
    double h,
    double sw,
    Paint stroke,
    Paint fillSolid,
    Paint fillSoft,
  ) {
    canvas.save();
    canvas.translate(w * 0.5, h * 0.5);
    canvas.rotate(-math.pi / 4);

    final stripW = w * 0.42;
    final stripH = h * 0.90;
    final stripRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset.zero, width: stripW, height: stripH),
      Radius.circular(stripW / 2),
    );
    canvas.drawRRect(stripRect, fillSoft);
    canvas.drawRRect(stripRect, stroke);

    // Center absorbent gauze pad
    final padRect = Rect.fromCenter(center: Offset.zero, width: stripW * 0.92, height: stripH * 0.32);
    canvas.drawRect(padRect, fillSoft);
    canvas.drawLine(Offset(-stripW * 0.46, -stripH * 0.16), Offset(stripW * 0.46, -stripH * 0.16), stroke);
    canvas.drawLine(Offset(-stripW * 0.46, stripH * 0.16), Offset(stripW * 0.46, stripH * 0.16), stroke);

    // Ventilation perforation dots on top and bottom adhesive wings
    final dotR = (sw * 0.52).clamp(0.7, 1.3);
    for (final dy in [-stripH * 0.29, stripH * 0.29]) {
      canvas.drawCircle(Offset(-stripW * 0.16, dy), dotR, fillSolid);
      canvas.drawCircle(Offset(stripW * 0.16, dy), dotR, fillSolid);
    }

    canvas.restore();
  }

  /// 5. INFUSION / DRIP: Hanging IV fluid bag with liquid level, ticks & bottom drip port
  void _drawInfusionBag(
    Canvas canvas,
    double w,
    double h,
    double sw,
    Paint stroke,
    Paint fillSolid,
    Paint fillSoft,
  ) {
    // Top hanger loop
    canvas.drawArc(
      Rect.fromCenter(center: Offset(w * 0.5, h * 0.14), width: w * 0.20, height: h * 0.12),
      math.pi,
      math.pi,
      false,
      stroke,
    );

    // IV Bag body
    final bagRect = RRect.fromRectAndRadius(
      Rect.fromLTRB(w * 0.22, h * 0.16, w * 0.78, h * 0.76),
      Radius.circular(w * 0.10),
    );

    // Fluid fill in lower portion of bag
    canvas.save();
    canvas.clipRRect(bagRect);
    canvas.drawRect(Rect.fromLTRB(w * 0.20, h * 0.40, w * 0.80, h * 0.78), fillSoft);
    canvas.restore();

    canvas.drawRRect(bagRect, stroke);

    // Fluid level line & measurement ticks
    canvas.drawLine(Offset(w * 0.25, h * 0.40), Offset(w * 0.75, h * 0.40), stroke);
    canvas.drawLine(Offset(w * 0.62, h * 0.52), Offset(w * 0.76, h * 0.52), stroke);
    canvas.drawLine(Offset(w * 0.62, h * 0.63), Offset(w * 0.76, h * 0.63), stroke);

    // Bottom drip nozzle & tube
    canvas.drawLine(Offset(w * 0.50, h * 0.76), Offset(w * 0.50, h * 0.92), stroke);
    canvas.drawCircle(Offset(w * 0.50, h * 0.84), sw * 0.65, fillSolid);
  }

  /// 6. INJECTION / SYRINGE: Angled medical syringe with barrel, ticks, plunger & needle
  void _drawSyringe(
    Canvas canvas,
    double w,
    double h,
    double sw,
    Paint stroke,
    Paint fillSolid,
    Paint fillSoft, {
    required bool withDroplet,
  }) {
    canvas.save();
    canvas.translate(w * 0.5, h * 0.5);
    canvas.rotate(math.pi / 4); // Needle points top-right

    final bw = w * 0.30;
    final barrelRect = RRect.fromRectAndRadius(
      Rect.fromLTRB(-bw / 2, -h * 0.24, bw / 2, h * 0.22),
      Radius.circular(w * 0.04),
    );

    // Liquid inside barrel
    canvas.save();
    canvas.clipRRect(barrelRect);
    canvas.drawRect(Rect.fromLTRB(-bw, -h * 0.24, bw, h * 0.06), fillSoft);
    canvas.restore();

    canvas.drawRRect(barrelRect, stroke);

    // Graduation ticks on barrel
    for (final ty in [-h * 0.12, 0.0, h * 0.11]) {
      canvas.drawLine(Offset(bw * 0.05, ty), Offset(bw * 0.48, ty), stroke);
    }

    // Finger flange at bottom of barrel
    canvas.drawLine(Offset(-bw * 0.85, h * 0.22), Offset(bw * 0.85, h * 0.22), stroke);

    // Plunger rod & thumb rest at bottom
    canvas.drawLine(Offset(0, h * 0.22), Offset(0, h * 0.40), stroke);
    canvas.drawLine(Offset(-bw * 0.55, h * 0.40), Offset(bw * 0.55, h * 0.40), stroke);

    // Needle hub & needle tip at top
    canvas.drawLine(Offset(0, -h * 0.24), Offset(0, -h * 0.46), stroke);

    canvas.restore();

    // Tiny medicine droplet near needle tip for Injection
    if (withDroplet) {
      canvas.drawCircle(Offset(w * 0.83, h * 0.31), sw * 0.72, fillSolid);
    }
  }

  /// 7. CANNULA: Winged IV butterfly cannula with catheter tip & top port
  void _drawCannula(
    Canvas canvas,
    double w,
    double h,
    double sw,
    Paint stroke,
    Paint fillSolid,
    Paint fillSoft,
  ) {
    // Butterfly wings
    final leftWing = Path()
      ..moveTo(w * 0.42, h * 0.38)
      ..lineTo(w * 0.14, h * 0.28)
      ..quadraticBezierTo(w * 0.08, h * 0.48, w * 0.16, h * 0.64)
      ..lineTo(w * 0.42, h * 0.58)
      ..close();
    final rightWing = Path()
      ..moveTo(w * 0.58, h * 0.38)
      ..lineTo(w * 0.86, h * 0.28)
      ..quadraticBezierTo(w * 0.92, h * 0.48, w * 0.84, h * 0.64)
      ..lineTo(w * 0.58, h * 0.58)
      ..close();

    canvas.drawPath(leftWing, fillSoft);
    canvas.drawPath(rightWing, fillSoft);
    canvas.drawPath(leftWing, stroke);
    canvas.drawPath(rightWing, stroke);

    // Central catheter hub
    final hubRect = RRect.fromRectAndRadius(
      Rect.fromLTRB(w * 0.41, h * 0.30, w * 0.59, h * 0.76),
      Radius.circular(w * 0.04),
    );
    canvas.drawRRect(hubRect, fillSolid);

    // Top needle/catheter tip & bottom Luer cap
    canvas.drawLine(Offset(w * 0.50, h * 0.10), Offset(w * 0.50, h * 0.30), stroke);
    canvas.drawLine(Offset(w * 0.40, h * 0.86), Offset(w * 0.60, h * 0.86), stroke);
    canvas.drawLine(Offset(w * 0.50, h * 0.76), Offset(w * 0.50, h * 0.86), stroke);
  }

  /// 8. DRIP SET: IV drip chamber with droplet + curved tubing loop
  void _drawDripSet(
    Canvas canvas,
    double w,
    double h,
    double sw,
    Paint stroke,
    Paint fillSolid,
    Paint fillSoft,
  ) {
    // Drip chamber on left
    final chamber = RRect.fromRectAndRadius(
      Rect.fromLTRB(w * 0.18, h * 0.20, w * 0.46, h * 0.64),
      Radius.circular(w * 0.08),
    );
    canvas.drawRRect(chamber, fillSoft);
    canvas.drawRRect(chamber, stroke);
    // Top spike
    canvas.drawLine(Offset(w * 0.32, h * 0.10), Offset(w * 0.32, h * 0.20), stroke);
    // Droplet inside chamber
    canvas.drawCircle(Offset(w * 0.32, h * 0.40), sw * 0.7, fillSolid);

    // Coiled IV tube looping to right connector
    final tube = Path()
      ..moveTo(w * 0.32, h * 0.64)
      ..cubicTo(w * 0.32, h * 0.94, w * 0.74, h * 0.94, w * 0.74, h * 0.52)
      ..lineTo(w * 0.74, h * 0.22);
    canvas.drawPath(tube, stroke);

    // Roller clamp on right tube
    final clamp = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(w * 0.74, h * 0.42), width: w * 0.18, height: h * 0.20),
      Radius.circular(w * 0.03),
    );
    canvas.drawRRect(clamp, fillSolid);
  }

  /// 9. NEBULIZATION: Nebulizer cup with rising aerosol mist waves
  void _drawNebulizer(
    Canvas canvas,
    double w,
    double h,
    double sw,
    Paint stroke,
    Paint fillSolid,
    Paint fillSoft,
  ) {
    // Nebulizer medicine cup at bottom
    final cup = Path()
      ..moveTo(w * 0.26, h * 0.52)
      ..lineTo(w * 0.32, h * 0.88)
      ..lineTo(w * 0.68, h * 0.88)
      ..lineTo(w * 0.74, h * 0.52)
      ..close();
    canvas.drawPath(cup, fillSoft);
    canvas.drawPath(cup, stroke);

    // Cap & nozzle
    canvas.drawLine(Offset(w * 0.22, h * 0.52), Offset(w * 0.78, h * 0.52), stroke);
    canvas.drawLine(Offset(w * 0.50, h * 0.42), Offset(w * 0.50, h * 0.52), stroke);

    // Rising aerosol mist arcs
    final mist1 = Path()
      ..moveTo(w * 0.34, h * 0.30)
      ..quadraticBezierTo(w * 0.50, h * 0.20, w * 0.66, h * 0.30);
    final mist2 = Path()
      ..moveTo(w * 0.24, h * 0.18)
      ..quadraticBezierTo(w * 0.50, h * 0.06, w * 0.76, h * 0.18);
    canvas.drawPath(mist1, stroke);
    canvas.drawPath(mist2, stroke);
  }

  /// 10. CONSUMABLES: Medical supply cross shield
  void _drawConsumables(
    Canvas canvas,
    double w,
    double h,
    double sw,
    Paint stroke,
    Paint fillSolid,
    Paint fillSoft,
  ) {
    final shield = Path()
      ..moveTo(w * 0.50, h * 0.10)
      ..lineTo(w * 0.84, h * 0.24)
      ..lineTo(w * 0.84, h * 0.52)
      ..quadraticBezierTo(w * 0.84, h * 0.78, w * 0.50, h * 0.90)
      ..quadraticBezierTo(w * 0.16, h * 0.78, w * 0.16, h * 0.52)
      ..lineTo(w * 0.16, h * 0.24)
      ..close();
    canvas.drawPath(shield, fillSoft);
    canvas.drawPath(shield, stroke);

    final cx = w * 0.50;
    final cy = h * 0.50;
    final arm = w * 0.14;
    canvas.drawLine(Offset(cx - arm, cy), Offset(cx + arm, cy), stroke);
    canvas.drawLine(Offset(cx, cy - arm), Offset(cx, cy + arm), stroke);
  }

  /// 11. OTHERS: First-aid medical kit with handle and cross
  void _drawMedicalKit(
    Canvas canvas,
    double w,
    double h,
    double sw,
    Paint stroke,
    Paint fillSolid,
    Paint fillSoft,
  ) {
    // Handle
    final handle = Path()
      ..moveTo(w * 0.36, h * 0.28)
      ..lineTo(w * 0.36, h * 0.18)
      ..quadraticBezierTo(w * 0.36, h * 0.14, w * 0.42, h * 0.14)
      ..lineTo(w * 0.58, h * 0.14)
      ..quadraticBezierTo(w * 0.64, h * 0.14, w * 0.64, h * 0.18)
      ..lineTo(w * 0.64, h * 0.28);
    canvas.drawPath(handle, stroke);

    // Kit box
    final box = RRect.fromRectAndRadius(
      Rect.fromLTRB(w * 0.14, h * 0.28, w * 0.86, h * 0.86),
      Radius.circular(w * 0.10),
    );
    canvas.drawRRect(box, fillSoft);
    canvas.drawRRect(box, stroke);

    // Cross
    final cx = w * 0.50;
    final cy = h * 0.57;
    final arm = w * 0.13;
    canvas.drawLine(Offset(cx - arm, cy), Offset(cx + arm, cy), stroke);
    canvas.drawLine(Offset(cx, cy - arm), Offset(cx, cy + arm), stroke);
  }

  /// 12. ALL: 2x2 category grid
  void _drawAllGrid(
    Canvas canvas,
    double w,
    double h,
    Paint stroke,
    Paint fillSolid,
    Paint fillSoft,
  ) {
    final s = w * 0.31;
    final r = Radius.circular(w * 0.07);
    final tl = RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.14, h * 0.14, s, s), r);
    final tr = RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.55, h * 0.14, s, s), r);
    final bl = RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.14, h * 0.55, s, s), r);
    final br = RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.55, h * 0.55, s, s), r);

    canvas.drawRRect(tl, fillSolid);
    canvas.drawRRect(tr, fillSoft);
    canvas.drawRRect(bl, fillSoft);
    canvas.drawRRect(br, fillSoft);
    canvas.drawRRect(tr, stroke);
    canvas.drawRRect(bl, stroke);
    canvas.drawRRect(br, stroke);
  }

  @override
  bool shouldRepaint(covariant _MedicineTypePainter oldDelegate) =>
      oldDelegate.type != type || oldDelegate.color != color;
}
