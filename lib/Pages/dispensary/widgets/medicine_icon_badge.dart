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
      child: Icon(
        iconFor(name: name, type: type),
        size: iconSize,
        color: c.brand,
      ),
    );
  }
}
