// lib/pages/madrassa/widgets/madrassa_erp.dart
//
// A small ERP frame for Madrassa screens (adapted from the School ERP kit,
// copied and renamed: madrassa never imports school code). Dense, desktop
// first, built only on gmwf_ui tokens so it follows the user's app theme in
// light and dark. Directional icons come from GIcons, so they mirror in Urdu.
//
//   MadrassaErpHeader     breadcrumb · title + subtitle · small actions
//   MadrassaErpStatStrip  one slim bordered strip of figures
//   MadrassaErpCard       bordered work area: title bar, toolbar, body
//   MadrassaErpFilter     compact dropdown filter ("Program: All ▾")
//   MadrassaTick          tick / cross cell for a yes-no column
//   MadrassaUrduAwareText a name that switches to Noori Nastaliq for Urdu

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';

abstract final class MadrassaErp {
  static const double rowHeight = 58;
  static const double headerHeight = 36;
  static const BorderRadius radius = BorderRadius.all(Radius.circular(8));

  /// Corner radius of every madrassa card.
  static const BorderRadius cardRadius = BorderRadius.all(Radius.circular(12));

  /// Room for the register plus a side panel.
  static bool roomForPanel(BuildContext context) => MediaQuery.sizeOf(context).width >= 1500;

  static bool narrow(BuildContext context) => MediaQuery.sizeOf(context).width < 700;

  static final RegExp _urdu = RegExp(r'[؀-ۿݐ-ݿﭐ-﷿ﹰ-﻿]');

  /// True when [text] is written in Urdu / Arabic script.
  static bool isUrduText(String text) => _urdu.hasMatch(text);
}

/// Compact page header: breadcrumb and title on the start side, actions on the end.
class MadrassaErpHeader extends StatelessWidget {
  const MadrassaErpHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.breadcrumbs = const [],
    this.actions = const [],
    this.icon,
  });

  final String title;
  final String? subtitle;
  final List<String> breadcrumbs;
  final List<Widget> actions;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final narrow = MadrassaErp.narrow(context);
    final pad = narrow ? Gsp.sp3 : Gsp.sp5;
    // The real GMWF logo is always shown at the start of the header.
    final titleBlock = Row(mainAxisSize: MainAxisSize.min, children: [
      GLogo(GBrand.gmwf, size: narrow ? 30 : 36),
      const SizedBox(width: Gsp.sp2 + 2),
      if (icon != null && !narrow) ...[GModuleTile(icon: icon!, size: 28), const SizedBox(width: Gsp.sp2 + 2)],
      Flexible(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          if (breadcrumbs.isNotEmpty && !narrow)
            Text(breadcrumbs.join('  ›  '), style: GText.caption(c.textMuted).copyWith(fontSize: 11)),
          Text(title, style: narrow ? GText.body1Bold(c.textPrimary) : GText.h3(c.textPrimary)),
          if (subtitle != null)
            Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: GText.caption(c.textMuted)),
        ]),
      ),
    ]);
    if (narrow) {
      // Phone: one compact block (title row, then the actions in one line).
      return Container(
        decoration: BoxDecoration(color: c.surface, border: Border(bottom: BorderSide(color: c.border))),
        padding: EdgeInsetsDirectional.fromSTEB(pad, Gsp.sp2, pad, Gsp.sp1),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          titleBlock,
          if (actions.isNotEmpty)
            SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: actions)),
        ]),
      );
    }
    return Container(
      decoration: BoxDecoration(color: c.surface, border: Border(bottom: BorderSide(color: c.border))),
      padding: EdgeInsetsDirectional.fromSTEB(pad, Gsp.sp2 + 2, pad, Gsp.sp2 + 2),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: Gsp.sp4,
        runSpacing: Gsp.sp2,
        children: [
          titleBlock,
          if (actions.isNotEmpty)
            Wrap(spacing: Gsp.sp1, runSpacing: Gsp.sp1, crossAxisAlignment: WrapCrossAlignment.center, children: actions),
        ],
      ),
    );
  }
}

/// A slot in the Madrassa hub's desktop top bar. The hub wraps its desktop body in
/// [MadrassaHubSlot] and shows [toolbar] beside the section title; a screen inside
/// puts its own controls there instead of drawing a second header row.
class MadrassaHubSlot extends InheritedWidget {
  const MadrassaHubSlot({super.key, required super.child});

  /// The controls the active screen wants in the hub bar (null = none).
  static final ValueNotifier<Widget?> toolbar = ValueNotifier<Widget?>(null);

  /// True when the screen is inside the hub's desktop layout (the slot is shown).
  static bool available(BuildContext context) => context.dependOnInheritedWidgetOfExactType<MadrassaHubSlot>() != null;

  @override
  bool updateShouldNotify(MadrassaHubSlot oldWidget) => false;
}

/// The slim row a screen shows when it is hosted inside the Madrassa hub, whose
/// top bar already has the logo, title, branch, sync, theme and language: only
/// this screen's own controls go here (one header, never two).
class MadrassaErpControlBar extends StatelessWidget {
  const MadrassaErpControlBar({super.key, this.leading = const [], this.caption, this.trailing = const []});
  final List<Widget> leading;
  final String? caption;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final narrow = MadrassaErp.narrow(context);
    final captionText = caption == null
        ? null
        : Text(caption!, maxLines: 1, overflow: TextOverflow.ellipsis, style: GText.caption(c.textMuted));
    return Container(
      decoration: BoxDecoration(color: c.surface, border: Border(bottom: BorderSide(color: c.border))),
      padding: EdgeInsetsDirectional.fromSTEB(narrow ? Gsp.sp2 : Gsp.sp4, 4, narrow ? Gsp.sp2 : Gsp.sp4, 4),
      child: narrow
          ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              Row(children: [...leading, const Spacer(), ...trailing]),
              if (captionText != null) Padding(padding: const EdgeInsetsDirectional.only(start: Gsp.sp2, bottom: 2), child: captionText),
            ])
          : Row(children: [
              ...leading,
              if (captionText != null) ...[const SizedBox(width: Gsp.sp4), Flexible(child: captionText)],
              const Spacer(),
              ...trailing,
            ]),
    );
  }
}

class MadrassaErpStat {
  const MadrassaErpStat({required this.label, required this.value, this.caption, this.color, this.icon, this.onTap});
  final String label;
  final String value;
  final String? caption;
  final Color? color;
  final IconData? icon;
  final VoidCallback? onTap;
}

/// Compact figures in one bordered strip, split by hairlines.
class MadrassaErpStatStrip extends StatelessWidget {
  const MadrassaErpStatStrip(this.stats, {super.key});
  final List<MadrassaErpStat> stats;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    if (stats.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, box) {
      if (box.maxWidth < 600) {
        // Phone: one slim scrolling line of figures so the list keeps the screen.
        return SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: stats.length,
            separatorBuilder: (_, _) => const SizedBox(width: Gsp.sp2),
            itemBuilder: (context, i) {
              final s = stats[i];
              final color = s.color ?? c.brand;
              return InkWell(
                onTap: s.onTap,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3),
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: c.border),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(s.icon ?? GIcons.chart, size: 14, color: color),
                    const SizedBox(width: 6),
                    Text(s.value, style: GText.body2Bold(c.textPrimary)),
                    const SizedBox(width: 4),
                    Text(s.label, style: GText.caption(c.textMuted)),
                  ]),
                ),
              );
            },
          ),
        );
      }
      const cellMin = 150.0;
      final oneRow = box.maxWidth >= cellMin * stats.length;
      final cols = oneRow ? stats.length : (box.maxWidth / cellMin).floor().clamp(1, stats.length);
      final w = ((box.maxWidth - 2) / cols).floorToDouble();
      final decoration = BoxDecoration(color: c.surface, borderRadius: MadrassaErp.radius, border: Border.all(color: c.border));
      if (oneRow) {
        return Container(
          decoration: decoration,
          clipBehavior: Clip.antiAlias,
          // Fixed height: Nastaliq lines are taller than Latin ones, and a measured
          // (intrinsic) height overflowed in Urdu.
          child: SizedBox(
            height: 64,
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final (i, s) in stats.indexed) ...[
                if (i > 0) VerticalDivider(width: 1, thickness: 1, color: c.border),
                Expanded(child: _StatCell(stat: s)),
              ],
            ]),
          ),
        );
      }
      return Container(
        decoration: decoration,
        clipBehavior: Clip.antiAlias,
        child: Wrap(children: [
          for (final (i, s) in stats.indexed)
            Container(
              width: w,
              decoration: BoxDecoration(
                border: BorderDirectional(
                  start: i % cols == 0 ? BorderSide.none : BorderSide(color: c.border),
                  top: i < cols ? BorderSide.none : BorderSide(color: c.border),
                ),
              ),
              child: _StatCell(stat: s),
            ),
        ]),
      );
    });
  }
}

class _StatCell extends StatelessWidget {
  const _StatCell({required this.stat});
  final MadrassaErpStat stat;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final color = stat.color ?? c.brand;
    return InkWell(
      onTap: stat.onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3, vertical: Gsp.sp1),
        child: Row(children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)),
            child: Icon(stat.icon ?? GIcons.chart, size: 15, color: color),
          ),
          const SizedBox(width: Gsp.sp2 + 2),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(stat.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: GText.caption(c.textMuted)),
              // Centre-aligned, not baseline: a baseline row reports a smaller
              // intrinsic height and overflowed the strip by a pixel.
              Row(children: [
                Text(stat.value,
                    style: GText.body1Bold(c.textPrimary).copyWith(fontSize: 17, fontFeatures: const [FontFeature.tabularFigures()])),
                if (stat.caption != null) ...[
                  const SizedBox(width: Gsp.sp2),
                  Flexible(child: Text(stat.caption!, maxLines: 1, overflow: TextOverflow.ellipsis, style: GText.caption(c.textMuted))),
                ],
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// A bordered work area: title bar (title + wrapping actions), optional
/// toolbar, then [child] filling the remaining height.
class MadrassaErpCard extends StatelessWidget {
  const MadrassaErpCard({
    super.key,
    required this.child,
    this.title,
    this.subtitle,
    this.actions = const [],
    this.toolbar,
  });

  final String? title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget? toolbar;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final theme = Theme.of(context);
    final compact = Theme(
      data: theme.copyWith(
        visualDensity: VisualDensity.compact,
        filledButtonTheme: FilledButtonThemeData(
          style: (theme.filledButtonTheme.style ?? const ButtonStyle()).merge(FilledButton.styleFrom(
            minimumSize: const Size(0, 32),
            padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3),
            textStyle: GText.label(c.onBrand),
          )),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: (theme.outlinedButtonTheme.style ?? const ButtonStyle()).merge(OutlinedButton.styleFrom(
            minimumSize: const Size(0, 32),
            padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3),
            textStyle: GText.label(c.textPrimary),
          )),
        ),
      ),
      child: Wrap(
          alignment: WrapAlignment.end,
          spacing: Gsp.sp2,
          runSpacing: Gsp.sp2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: actions),
    );
    return Container(
      decoration: BoxDecoration(color: c.surface, borderRadius: MadrassaErp.radius, border: Border.all(color: c.border)),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (title != null || actions.isNotEmpty)
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(Gsp.sp4, Gsp.sp2 + 2, Gsp.sp3, Gsp.sp2 + 2),
            // Title on the start side; actions packed to the end and wrapping
            // there (they no longer drop under the title on medium widths).
            child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                if (title != null) Text(title!, style: GText.body1Bold(c.textPrimary)),
                if (subtitle != null) Text(subtitle!, style: GText.caption(c.textMuted)),
              ]),
              const SizedBox(width: Gsp.sp3),
              if (actions.isNotEmpty)
                Expanded(child: Align(alignment: AlignmentDirectional.centerEnd, child: compact)),
            ]),
          ),
        if (toolbar != null) ...[
          if (title != null || actions.isNotEmpty) Divider(height: 1, color: c.border),
          Padding(padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3, vertical: Gsp.sp2), child: toolbar),
        ],
        Divider(height: 1, color: c.border),
        Expanded(child: child),
      ]),
    );
  }
}

/// THE card for madrassa screens (teachers and parents). One look everywhere:
/// theme surface, 1 px border, 12 px corners, no gradient or shadow; an optional
/// title row (icon · title · subtitle · trailing action) and the content below.
class MadrassaCard extends StatelessWidget {
  const MadrassaCard({
    super.key,
    required this.child,
    this.title,
    this.subtitle,
    this.icon,
    this.trailing,
    this.onTap,
    this.padding = const EdgeInsets.all(14),
    this.tone,
  });

  final Widget child;
  final String? title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  /// Optional status tone for a notice card (soft tint + coloured border).
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final hasHeader = title != null || trailing != null;
    final card = Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: tone == null ? c.surface : Color.alphaBlend(tone!.withValues(alpha: 0.07), c.surface),
        borderRadius: MadrassaErp.cardRadius,
        border: Border.all(color: tone == null ? c.border : tone!.withValues(alpha: 0.35)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        if (hasHeader) ...[
          Row(children: [
            if (icon != null) ...[
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(color: (tone ?? c.brand).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                child: Icon(icon, size: 17, color: tone ?? c.brand),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                if (title != null)
                  Text(title!, style: GText.body1Bold(c.textPrimary).copyWith(fontSize: 15, fontFamilyFallback: const ['Noori'])),
                if (subtitle != null)
                  Text(subtitle!, style: GText.caption(c.textMuted).copyWith(fontFamilyFallback: const ['Noori'])),
              ]),
            ),
            ?trailing,
            if (onTap != null && trailing == null) Icon(GIcons.chevronRight, size: 18, color: c.textMuted),
          ]),
          const SizedBox(height: 12),
        ],
        child,
      ]),
    );
    if (onTap == null) return card;
    return Material(
      color: Colors.transparent,
      child: InkWell(borderRadius: MadrassaErp.cardRadius, onTap: onTap, child: card),
    );
  }
}

/// A small figure tile inside a card (label · value · note).
class MadrassaMetric extends StatelessWidget {
  const MadrassaMetric({super.key, required this.label, required this.value, this.note, this.icon, this.color});
  final String label;
  final String value;
  final String? note;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final tone = color ?? c.brand;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: c.surfaceSunken, borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        if (icon != null) ...[Icon(icon, size: 18, color: tone), const SizedBox(width: 8)],
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: GText.caption(c.textMuted).copyWith(fontFamilyFallback: const ['Noori'])),
            Text(value, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: GText.body1Bold(c.textPrimary).copyWith(fontFeatures: const [FontFeature.tabularFigures()], fontFamilyFallback: const ['Noori'])),
            if (note != null)
              Text(note!, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: GText.caption(c.textMuted).copyWith(fontSize: 11, fontFamilyFallback: const ['Noori'])),
          ]),
        ),
      ]),
    );
  }
}

/// A compact dropdown filter for toolbars.
class MadrassaErpFilter<T> extends StatelessWidget {
  const MadrassaErpFilter({super.key, required this.label, required this.value, required this.options, required this.onChanged, this.width = 150});
  final String label;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: 38,
      child: DropdownButtonFormField<T>(
        key: ValueKey('$label-$value-${options.length}'),
        initialValue: options.containsKey(value) ? value : options.keys.first,
        isExpanded: true,
        isDense: true,
        style: GText.body2(context.comfort.textPrimary),
        decoration: InputDecoration(
          isDense: true,
          labelText: label,
          contentPadding: const EdgeInsets.symmetric(horizontal: Gsp.sp3, vertical: 6),
        ),
        items: [for (final e in options.entries) DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis))],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }
}

/// A yes / no cell: a tick on a tinted square, or a muted cross.
class MadrassaTick extends StatelessWidget {
  const MadrassaTick({super.key, required this.on, this.onTap, this.color, this.onIcon = GIcons.check, this.tooltip, this.label});
  final bool on;
  final VoidCallback? onTap;
  final Color? color;
  final IconData onIcon;
  final String? tooltip;

  /// Small text shown beside the mark when on (e.g. an arrival time).
  final String? label;

  @override
  Widget build(BuildContext context) {
    // An icon toggle, not a tick/cross box: the icon says what the mark is
    // (clock = late, uniform, reply…) in both states. Off = light outline and a
    // muted icon; on = filled with the colour and a white icon; unavailable =
    // faint with no outline. No crosses, so a full register stays calm to read.
    final c = context.comfort;
    final tone = color ?? c.success;
    final enabled = onTap != null;
    final Color bg;
    final Color fg;
    final Color? edge;
    if (on) {
      bg = enabled ? tone : tone.withValues(alpha: 0.35);
      fg = c.onBrand;
      edge = null;
    } else if (enabled) {
      bg = c.surface;
      fg = c.textMuted;
      edge = c.borderStrong.withValues(alpha: 0.6);
    } else {
      bg = Colors.transparent;
      fg = c.textMuted.withValues(alpha: 0.3);
      edge = null;
    }
    final box = Container(
      width: 30,
      height: 28,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: edge == null ? null : Border.all(color: edge),
      ),
      child: Icon(onIcon, size: 16, color: fg),
    );
    Widget child = label == null || !on
        ? box
        : Row(mainAxisSize: MainAxisSize.min, children: [
            box,
            const SizedBox(width: 4),
            Flexible(child: Text(label!, maxLines: 1, overflow: TextOverflow.ellipsis, style: GText.micro(tone))),
          ]);
    child = InkWell(onTap: onTap, borderRadius: BorderRadius.circular(6), child: Padding(padding: const EdgeInsets.all(2), child: child));
    return tooltip == null ? child : Tooltip(message: tooltip!, child: child);
  }
}

/// Text that uses Noori Nastaliq when it is written in Urdu.
class MadrassaUrduAwareText extends StatelessWidget {
  const MadrassaUrduAwareText(this.text, {super.key, required this.color, this.size = 14, this.bold = true});
  final String text;
  final Color color;
  final double size;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    if (MadrassaErp.isUrduText(text)) {
      return Text(text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          // Nastaliq has tall ascenders/descenders: a fixed strut keeps the line
          // the same height as Latin text so it never runs into the caption below.
          strutStyle: StrutStyle(fontSize: size, height: 1.35, forceStrutHeight: true),
          style: GText.urdu(color, size: size, weight: bold ? FontWeight.w600 : FontWeight.w400).copyWith(height: 1.35));
    }
    return Text(text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: (bold ? GText.body2Bold(color) : GText.body2(color)).copyWith(fontSize: size));
  }
}
