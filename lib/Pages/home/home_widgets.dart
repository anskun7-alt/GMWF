// lib/pages/home/home_widgets.dart
//
// Layout helpers for the home. The card (GSection), KPI tile (GKpiTile) and
// list (GDataList) all come from gmwf_ui, so every screen shares one look.
//   HomeEmpty  — quiet empty note inside a card
//   homeRow    — flex-weighted row of equal-height cards (stacked when narrow)
//   homeGrid   — even tile grid that never ends ragged

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';

/// Quiet empty note for a card body.
class HomeEmpty extends StatelessWidget {
  const HomeEmpty(
    this.text, {
    super.key,
    this.icon = GIcons.inbox,
    this.illustration,
    this.size = 76,
  });

  final String text;
  final IconData icon;
  final GEmptyIllustrationKind? illustration;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final kind = illustration ??
        GEmptyIllustrationKind.infer(icon: icon, title: text);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Gsp.sp4, horizontal: Gsp.sp3),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          GEmptyIllustration(kind, size: size, fallbackIcon: icon),
          const SizedBox(height: Gsp.sp2),
          Text(text, style: GText.body2(c.textMuted), textAlign: TextAlign.center),
        ]),
      ),
    );
  }
}

/// Lays [children] in a [flex]-weighted row on wide screens (all [height]
/// tall, so cards line up), stacked when narrow; each keeps [height].
Widget homeRow(double width, List<(int, Widget)> children, {double? height}) {
  if (width < 900) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (i, (_, w)) in children.indexed) ...[
        if (i > 0) const SizedBox(height: Gsp.sp4),
        height == null ? w : SizedBox(height: height, child: w),
      ],
    ]);
  }
  final row = Row(crossAxisAlignment: height != null ? CrossAxisAlignment.stretch : CrossAxisAlignment.start, children: [
    for (final (i, (f, w)) in children.indexed) ...[if (i > 0) const SizedBox(width: Gsp.sp4), Expanded(flex: f, child: w)],
  ]);
  return height == null ? row : SizedBox(height: height, child: row);
}

/// Even columns that divide [tiles] (8 → 4/2/1), so rows never end ragged.
Widget homeGrid(double width, List<Widget> tiles, {double min = 220, int max = 4}) {
  final fit = (width / min).floor().clamp(1, max);
  final cols = [6, 4, 3, 2, 1].firstWhere((n) => n <= fit && tiles.length % n == 0, orElse: () => 1);
  final w = (width - Gsp.sp4 * (cols - 1)) / cols;
  return Wrap(spacing: Gsp.sp4, runSpacing: Gsp.sp4, children: [for (final t in tiles) SizedBox(width: w, child: t)]);
}
