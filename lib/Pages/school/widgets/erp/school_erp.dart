// lib/pages/school/widgets/erp/school_erp.dart
//
// The School ERP frame (redesign of 2026-11-17: "look like an ERP, not a
// mobile app"). Every School screen is built from these pieces so they all
// read the same way on a desktop:
//
//   SchoolErpPage       breadcrumb · title + actions · tabs · stat strip · body
//   SchoolErpStatStrip  one bordered strip of compact figures (not big cards)
//   SchoolErpCard       a bordered work area with a title bar and toolbar
//   SchoolErpToolbar    search + filters + actions in one line
//   SchoolErpTable<T>   dense grid: sortable columns, sticky header, hover,
//                       selected row, paging footer ("1–25 of 312")
//   SchoolErpDetailPanel / SchoolErpFacts  the right-hand record panel
//
// Built only on gmwf_ui (follows the user's app theme; Nexus default for school).
// Directional icons come from GIcons, so they mirror in Urdu.

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';

/// Desktop density used across the ERP screens.
abstract final class SchoolErp {
  static const double rowHeight = 44;
  static const double headerHeight = 38;
  static const double pagePad = Gsp.sp5;
  static const double panelWidth = 400;
  static const BorderRadius radius = BorderRadius.all(Radius.circular(8));

  /// True when there is room for a table plus a side panel.
  static bool wide(BuildContext context) => MediaQuery.sizeOf(context).width >= 1100;
}

// ── Page ────────────────────────────────────────────────────────────────────

class SchoolErpPage extends StatelessWidget {
  const SchoolErpPage({
    super.key,
    required this.title,
    required this.child,
    this.breadcrumbs = const [],
    this.subtitle,
    this.icon,
    this.actions = const [],
    this.tabs,
    this.stats,
    this.banner,
    this.scroll = false,
    this.flush = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;

  /// e.g. ['School', 'Academics'] → "School › Academics › <title>".
  final List<String> breadcrumbs;
  final List<Widget> actions;
  final Widget? tabs;
  final Widget? stats;
  final Widget? banner;
  final Widget child;

  /// Scroll the whole body (forms, dashboards) instead of letting [child]
  /// fill the remaining height (tables).
  final bool scroll;

  /// No padding around [child] (older screens that bring their own layout).
  final bool flush;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final narrow = MediaQuery.sizeOf(context).width < 700;
    final pad = narrow ? Gsp.sp4 : SchoolErp.pagePad;

    // Compact desktop header: one line of title (breadcrumb + subtitle in
    // small type beside it) and small action buttons, then tabs.
    final theme = Theme.of(context);
    final compactActions = Theme(
      data: theme.copyWith(
        visualDensity: VisualDensity.compact,
        filledButtonTheme: FilledButtonThemeData(
          style: (theme.filledButtonTheme.style ?? const ButtonStyle()).merge(FilledButton.styleFrom(
            minimumSize: const Size(0, 34),
            padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3),
            textStyle: GText.label(c.onBrand),
          )),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: (theme.outlinedButtonTheme.style ?? const ButtonStyle()).merge(OutlinedButton.styleFrom(
            minimumSize: const Size(0, 34),
            padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3),
            textStyle: GText.label(c.textPrimary),
          )),
        ),
        iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(iconSize: 20, minimumSize: const Size(34, 34))),
      ),
      child: Wrap(spacing: Gsp.sp2, runSpacing: Gsp.sp2, crossAxisAlignment: WrapCrossAlignment.center, children: actions),
    );

    final header = Container(
      decoration: BoxDecoration(color: c.surface, border: Border(bottom: BorderSide(color: c.border))),
      padding: EdgeInsets.fromLTRB(pad, Gsp.sp2 + 2, pad, tabs == null ? Gsp.sp2 + 2 : 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: Gsp.sp4,
          runSpacing: Gsp.sp2,
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              if (icon != null) ...[GModuleTile(icon: icon!, size: 28), const SizedBox(width: Gsp.sp2 + 2)],
              Flexible(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  if (breadcrumbs.isNotEmpty)
                    Text(breadcrumbs.join('  ›  '), style: GText.caption(c.textMuted).copyWith(fontSize: 11)),
                  Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                    Text(title, style: GText.h3(c.textPrimary)),
                    if (subtitle != null && !narrow) ...[
                      const SizedBox(width: Gsp.sp3),
                      Flexible(child: Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: GText.caption(c.textMuted))),
                    ],
                  ]),
                ]),
              ),
            ]),
            if (actions.isNotEmpty) compactActions,
          ],
        ),
        if (tabs != null) ...[const SizedBox(height: Gsp.sp1), tabs!],
      ]),
    );

    final top = <Widget>[
      if (banner != null) ...[banner!, const SizedBox(height: Gsp.sp2)],
      if (stats != null) ...[stats!, const SizedBox(height: Gsp.sp3)],
    ];

    return ColoredBox(
      color: c.background,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        header,
        Expanded(
          child: flush
              ? child
              : scroll
              ? SingleChildScrollView(
                  padding: EdgeInsets.all(pad),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...top, child]),
                )
              : Padding(
                  padding: EdgeInsets.fromLTRB(pad, pad, pad, Gsp.sp3),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...top, Expanded(child: child)]),
                ),
        ),
      ]),
    );
  }
}

/// Underlined page tabs (sit at the bottom of the page header).
class SchoolErpTabs extends StatelessWidget {
  const SchoolErpTabs({super.key, required this.labels, required this.selected, required this.onChanged, this.icons, this.counts});
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onChanged;
  final List<IconData>? icons;

  /// Optional count badge per tab (null = none).
  final List<int?>? counts;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        for (final (i, l) in labels.indexed)
          InkWell(
            onTap: () => onChanged(i),
            child: Container(
              padding: const EdgeInsets.fromLTRB(Gsp.sp3, Gsp.sp2, Gsp.sp3, Gsp.sp3 - 2),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: i == selected ? c.brand : Colors.transparent, width: 2)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (icons != null && i < icons!.length) ...[
                  Icon(icons![i], size: 16, color: i == selected ? c.brand : c.textMuted),
                  const SizedBox(width: Gsp.sp2),
                ],
                Text(l, style: GText.label(i == selected ? c.brand : c.textSecondary)),
                if (counts != null && i < counts!.length && counts![i] != null) ...[
                  const SizedBox(width: Gsp.sp2),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(color: i == selected ? c.brandSoft : c.surfaceSunken, borderRadius: Gr.chip),
                    child: Text('${counts![i]}', style: GText.caption(i == selected ? c.brand : c.textMuted)),
                  ),
                ],
              ]),
            ),
          ),
      ]),
    );
  }
}

// ── Stat strip ──────────────────────────────────────────────────────────────

class SchoolErpStat {
  const SchoolErpStat({required this.label, required this.value, this.caption, this.color, this.icon, this.onTap});
  final String label;
  final String value;
  final String? caption;
  final Color? color;
  final IconData? icon;
  final VoidCallback? onTap;
}

/// Compact figures in one bordered strip, split by hairlines.
class SchoolErpStatStrip extends StatelessWidget {
  const SchoolErpStatStrip(this.stats, {super.key});
  final List<SchoolErpStat> stats;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    if (stats.isEmpty) return const SizedBox.shrink();
    // One slim bordered bar (about 56 px high), not a row of big cards, so
    // the table below keeps most of the screen.
    return LayoutBuilder(builder: (context, box) {
      final oneRow = box.maxWidth >= 210.0 * stats.length;
      final cols = oneRow ? stats.length : (box.maxWidth / 210).floor().clamp(1, stats.length);
      // Floor so rounding never pushes the last cell onto a new line.
      final w = ((box.maxWidth - 2) / cols).floorToDouble();
      final decoration = BoxDecoration(color: c.surface, borderRadius: SchoolErp.radius, border: Border.all(color: c.border));
      if (oneRow) {
        return Container(
          decoration: decoration,
          clipBehavior: Clip.antiAlias,
          child: IntrinsicHeight(
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
  final SchoolErpStat stat;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final color = stat.color ?? c.brand;
    return InkWell(
      onTap: stat.onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3, vertical: Gsp.sp2),
        child: Row(children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)),
            child: Icon(stat.icon ?? GIcons.chart, size: 16, color: color),
          ),
          const SizedBox(width: Gsp.sp3),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(stat.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: GText.caption(c.textMuted)),
              Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                Flexible(
                  flex: 3,
                  child: Text(stat.value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GText.body1Bold(c.textPrimary).copyWith(fontSize: 17, fontFeatures: const [FontFeature.tabularFigures()])),
                ),
                if (stat.caption != null) ...[
                  const SizedBox(width: Gsp.sp2),
                  Flexible(flex: 2, child: Text(stat.caption!, maxLines: 1, overflow: TextOverflow.ellipsis, style: GText.caption(c.textMuted))),
                ],
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ── Card & toolbar ──────────────────────────────────────────────────────────

/// A bordered work area. With a fixed height parent the [child] fills it.
class SchoolErpCard extends StatelessWidget {
  const SchoolErpCard({
    super.key,
    required this.child,
    this.title,
    this.subtitle,
    this.actions = const [],
    this.toolbar,
    this.footer,
    this.padding = EdgeInsets.zero,
    this.expand = true,
  });

  final String? title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget? toolbar;
  final Widget? footer;
  final Widget child;
  final EdgeInsetsGeometry padding;

  /// Let [child] take the remaining height (tables). False = size to content.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final body = Padding(padding: padding, child: child);
    return Container(
      decoration: BoxDecoration(color: c.surface, borderRadius: SchoolErp.radius, border: Border.all(color: c.border)),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (title != null || actions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gsp.sp4, Gsp.sp3, Gsp.sp3, Gsp.sp3),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  if (title != null) Text(title!, style: GText.body1Bold(c.textPrimary)),
                  if (subtitle != null) Text(subtitle!, style: GText.caption(c.textMuted)),
                ]),
              ),
              ...actions,
            ]),
          ),
        if (toolbar != null) ...[
          if (title != null || actions.isNotEmpty) Divider(height: 1, color: c.border),
          Padding(padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3, vertical: Gsp.sp2), child: toolbar),
        ],
        if (title != null || actions.isNotEmpty || toolbar != null) Divider(height: 1, color: c.border),
        if (expand) Expanded(child: body) else body,
        if (footer != null) ...[Divider(height: 1, color: c.border), footer!],
      ]),
    );
  }
}

/// Search + filters + trailing actions in one wrapping line.
class SchoolErpToolbar extends StatelessWidget {
  const SchoolErpToolbar({super.key, this.search, this.searchHint = 'Search', this.onSearch, this.filters = const [], this.trailing = const []});
  final TextEditingController? search;
  final String searchHint;
  final ValueChanged<String>? onSearch;
  final List<Widget> filters;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final searchBox = search == null
          ? null
          : SizedBox(
              width: box.maxWidth < 600 ? box.maxWidth : 300,
              height: 38,
              child: TextField(
                controller: search,
                onChanged: onSearch,
                style: GText.body2(context.comfort.textPrimary),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  prefixIcon: const Icon(GIcons.search, size: 18),
                  hintText: searchHint,
                  suffixIcon: search!.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(GIcons.close, size: 16),
                          onPressed: () {
                            search!.clear();
                            onSearch?.call('');
                          },
                        ),
                ),
              ),
            );
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Wrap(spacing: Gsp.sp2, runSpacing: Gsp.sp2, crossAxisAlignment: WrapCrossAlignment.center, children: [
            ?searchBox,
            ...filters,
          ]),
        ),
        if (trailing.isNotEmpty) ...[
          const SizedBox(width: Gsp.sp2),
          Wrap(spacing: Gsp.sp2, runSpacing: Gsp.sp2, children: trailing),
        ],
      ]);
    });
  }
}

/// A compact dropdown filter for toolbars ("Class: All ▾").
class SchoolErpFilter<T> extends StatelessWidget {
  const SchoolErpFilter({super.key, required this.label, required this.value, required this.options, required this.onChanged, this.width = 150});
  final String label;
  final T value;

  /// value → text.
  final Map<T, String> options;
  final ValueChanged<T> onChanged;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: 38,
      child: DropdownButtonFormField<T>(
        key: ValueKey('$label-$value'),
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

// ── Table ───────────────────────────────────────────────────────────────────

class SchoolErpColumn<T> {
  const SchoolErpColumn({
    required this.label,
    required this.cell,
    this.flex = 2,
    this.width,
    this.numeric = false,
    this.sortValue,
    this.hideBelow,
  });

  final String label;
  final Widget Function(T row) cell;
  final int flex;

  /// Fixed width instead of [flex].
  final double? width;
  final bool numeric;

  /// Makes the column sortable.
  final Comparable<Object?> Function(T row)? sortValue;

  /// Hide when the table is narrower than this.
  final double? hideBelow;
}

/// Dense data grid with sortable headers and a paging footer.
class SchoolErpTable<T> extends StatefulWidget {
  const SchoolErpTable({
    super.key,
    required this.columns,
    required this.rows,
    required this.rowKey,
    this.onRowTap,
    this.selectedKey,
    this.empty,
    this.pageSizes = const [25, 50, 100],
    this.rowHeight = SchoolErp.rowHeight,
    this.rowColor,
    this.minWidth = 0,
  });

  final List<SchoolErpColumn<T>> columns;
  final List<T> rows;
  final String Function(T row) rowKey;
  final ValueChanged<T>? onRowTap;
  final String? selectedKey;
  final Widget? empty;
  final List<int> pageSizes;
  final double rowHeight;

  /// Optional row tint (e.g. unsaved, warning).
  final Color? Function(T row)? rowColor;

  /// Scroll sideways below this width instead of squeezing columns.
  final double minWidth;

  @override
  State<SchoolErpTable<T>> createState() => _SchoolErpTableState<T>();
}

class _SchoolErpTableState<T> extends State<SchoolErpTable<T>> {
  int? _sortCol;
  bool _asc = true;
  int _page = 0;
  late int _pageSize = widget.pageSizes.first;

  // Sorting is cached: it only re-runs when the rows or the sort change, not
  // on every rebuild (hover, paging, a parent setState).
  List<T>? _sortedCache;
  Object? _sortedFor;

  List<T> get _sorted {
    final key = (identityHashCode(widget.rows), widget.rows.length, _sortCol, _asc);
    if (_sortedCache != null && _sortedFor == key) return _sortedCache!;
    final list = [...widget.rows];
    final col = _sortCol == null || _sortCol! >= widget.columns.length ? null : widget.columns[_sortCol!];
    if (col?.sortValue != null) {
      final values = {for (final r in list) r: col!.sortValue!(r)};
      list.sort((a, b) {
        final r = values[a]!.compareTo(values[b]);
        return _asc ? r : -r;
      });
    }
    _sortedFor = key;
    return _sortedCache = list;
  }

  @override
  void didUpdateWidget(covariant SchoolErpTable<T> old) {
    super.didUpdateWidget(old);
    final pages = (widget.rows.length / _pageSize).ceil();
    if (_page >= pages) _page = pages == 0 ? 0 : pages - 1;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    if (widget.rows.isEmpty) return widget.empty ?? const AppEmptyState(icon: GIcons.inbox, title: 'Nothing to show', compact: true);

    return LayoutBuilder(builder: (context, box) {
      final width = box.maxWidth < widget.minWidth ? widget.minWidth : box.maxWidth;
      final visible = [
        for (final (i, col) in widget.columns.indexed)
          if (col.hideBelow == null || width >= col.hideBelow!) i,
      ];
      final sorted = _sorted;
      final pages = (sorted.length / _pageSize).ceil();
      final start = _page * _pageSize;
      final pageRows = sorted.sublist(start, (start + _pageSize).clamp(0, sorted.length));

      Widget cellBox(int i, Widget child) {
        final col = widget.columns[i];
        final aligned = Align(alignment: col.numeric ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart, child: child);
        return col.width != null ? SizedBox(width: col.width, child: aligned) : Expanded(flex: col.flex, child: aligned);
      }

      final header = Container(
        height: SchoolErp.headerHeight,
        color: c.surfaceSunken,
        padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3),
        child: Row(children: [
          for (final (n, i) in visible.indexed) ...[
            if (n > 0) const SizedBox(width: Gsp.sp3),
            cellBox(
              i,
              InkWell(
                onTap: widget.columns[i].sortValue == null
                    ? null
                    : () => setState(() {
                          if (_sortCol == i) {
                            _asc = !_asc;
                          } else {
                            _sortCol = i;
                            _asc = true;
                          }
                          _page = 0;
                        }),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Flexible(
                    child: Text(widget.columns[i].label.toUpperCase(),
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: GText.overline(_sortCol == i ? c.brand : c.textMuted)),
                  ),
                  if (_sortCol == i) Icon(_asc ? GIcons.trendUp : GIcons.trendDown, size: 12, color: c.brand),
                ]),
              ),
            ),
          ],
        ]),
      );

      final body = ListView.builder(
        itemCount: pageRows.length,
        itemExtent: widget.rowHeight,
        itemBuilder: (context, r) {
          final row = pageRows[r];
          final key = widget.rowKey(row);
          final selected = key == widget.selectedKey;
          final tint = widget.rowColor?.call(row);
          // Hover is drawn by the row's own InkWell, so moving the mouse never
          // rebuilds the table (that rebuild caused lag and mouse-tracker errors).
          return RepaintBoundary(
            child: Material(
              color: selected ? c.brandSoft : tint ?? (r.isOdd ? c.surfaceSunken.withValues(alpha: 0.35) : c.surface),
              child: InkWell(
                hoverColor: c.textPrimary.withValues(alpha: 0.05),
                onTap: widget.onRowTap == null ? null : () => widget.onRowTap!(row),
                child: Container(
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: c.border),
                      left: BorderSide(color: selected ? c.brand : Colors.transparent, width: 3),
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3),
                  child: Row(children: [
                    for (final (n, i) in visible.indexed) ...[
                      if (n > 0) const SizedBox(width: Gsp.sp3),
                      cellBox(i, widget.columns[i].cell(row)),
                    ],
                  ]),
                ),
              ),
            ),
          );
        },
      );

      final footer = Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3),
        decoration: BoxDecoration(color: c.surface, border: Border(top: BorderSide(color: c.border))),
        child: Row(children: [
          Text('Rows per page', style: GText.caption(c.textMuted)),
          const SizedBox(width: Gsp.sp2),
          DropdownButton<int>(
            value: _pageSize,
            isDense: true,
            underline: const SizedBox.shrink(),
            style: GText.caption(c.textPrimary),
            items: [for (final s in widget.pageSizes) DropdownMenuItem(value: s, child: Text('$s'))],
            onChanged: (v) => setState(() {
              _pageSize = v ?? _pageSize;
              _page = 0;
            }),
          ),
          const Spacer(),
          Text('${start + 1}–${start + pageRows.length} of ${sorted.length}', style: GText.caption(c.textSecondary)),
          IconButton(
            tooltip: 'Previous page',
            visualDensity: VisualDensity.compact,
            onPressed: _page > 0 ? () => setState(() => _page--) : null,
            icon: const Icon(GIcons.back, size: 18),
          ),
          IconButton(
            tooltip: 'Next page',
            visualDensity: VisualDensity.compact,
            onPressed: _page < pages - 1 ? () => setState(() => _page++) : null,
            icon: const Icon(GIcons.forward, size: 18),
          ),
        ]),
      );

      // Only the grid scrolls sideways; the paging footer always stays in view.
      final grid = Column(children: [header, Expanded(child: body)]);
      return Column(children: [
        Expanded(
          child: width > box.maxWidth
              ? LayoutBuilder(
                  builder: (context, inner) => SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(width: width, height: inner.maxHeight, child: grid),
                  ),
                )
              : grid,
        ),
        footer,
      ]);
    });
  }
}

/// Standard table cells so every grid reads the same.
abstract final class SchoolErpCell {
  static Widget text(BuildContext context, String v, {bool muted = false}) =>
      Text(v.isEmpty ? '—' : v, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: GText.body2(muted ? context.comfort.textMuted : context.comfort.textSecondary));

  static Widget primary(BuildContext context, String v, {String? sub, Widget? leading}) {
    final c = context.comfort;
    final texts = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(v, maxLines: 1, overflow: TextOverflow.ellipsis, style: GText.body2Bold(c.textPrimary)),
      if (sub != null && sub.isNotEmpty) Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: GText.caption(c.textMuted)),
    ]);
    if (leading == null) return texts;
    return Row(children: [leading, const SizedBox(width: Gsp.sp3), Expanded(child: texts)]);
  }

  static Widget mono(BuildContext context, String v, {Color? color}) =>
      Text(v.isEmpty ? '—' : v, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: GText.label(color ?? context.comfort.textPrimary).copyWith(fontFeatures: const [FontFeature.tabularFigures()]));
}

// ── Detail panel ────────────────────────────────────────────────────────────

/// The right-hand record panel: header (avatar, title, chips, close), action
/// bar, then scrolling sections.
class SchoolErpDetailPanel extends StatelessWidget {
  const SchoolErpDetailPanel({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.leading,
    this.chips = const [],
    this.actions = const [],
    this.onClose,
    this.scrollController,
    this.titleWidget,
  });

  final String title;

  /// Replaces the plain [title] text (e.g. an Urdu title in Nastaliq).
  final Widget? titleWidget;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> chips;
  final List<Widget> actions;
  final List<Widget> children;
  final VoidCallback? onClose;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    return Container(
      decoration: BoxDecoration(color: c.surface, borderRadius: SchoolErp.radius, border: Border.all(color: c.border)),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          color: c.surfaceSunken,
          padding: const EdgeInsets.fromLTRB(Gsp.sp4, Gsp.sp4, Gsp.sp2, Gsp.sp3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (leading != null) ...[leading!, const SizedBox(width: Gsp.sp3)],
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                titleWidget ?? Text(title, style: GText.h3(c.textPrimary)),
                if (subtitle != null) Text(subtitle!, style: GText.body2(c.textSecondary)),
                if (chips.isNotEmpty) ...[
                  const SizedBox(height: Gsp.sp2),
                  Wrap(spacing: Gsp.sp1, runSpacing: Gsp.sp1, children: chips),
                ],
              ]),
            ),
            if (onClose != null) IconButton(tooltip: 'Close', onPressed: onClose, icon: const Icon(GIcons.close)),
          ]),
        ),
        if (actions.isNotEmpty)
          Container(
            decoration: BoxDecoration(border: Border(top: BorderSide(color: c.border), bottom: BorderSide(color: c.border))),
            padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3, vertical: Gsp.sp2),
            child: Wrap(spacing: Gsp.sp2, runSpacing: Gsp.sp2, children: actions),
          ),
        Expanded(
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(Gsp.sp4, Gsp.sp2, Gsp.sp4, Gsp.sp4),
            children: children,
          ),
        ),
      ]),
    );
  }
}

/// A titled group of label / value rows inside a detail panel.
class SchoolErpFacts extends StatelessWidget {
  const SchoolErpFacts({super.key, required this.title, required this.facts, this.trailing});
  final String title;

  /// label → value (empty values show "—").
  final List<(String, String)> facts;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.only(top: Gsp.sp4, bottom: Gsp.sp2),
        child: Row(children: [
          Expanded(child: Text(title.toUpperCase(), style: GText.overline(c.textMuted))),
          ?trailing,
        ]),
      ),
      Container(
        decoration: BoxDecoration(borderRadius: SchoolErp.radius, border: Border.all(color: c.border)),
        child: Column(children: [
          for (final (i, f) in facts.indexed)
            Container(
              decoration: BoxDecoration(border: i == 0 ? null : Border(top: BorderSide(color: c.border))),
              padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3, vertical: Gsp.sp2),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 120, child: Text(f.$1, style: GText.caption(c.textMuted))),
                Expanded(child: Text(f.$2.isEmpty ? '—' : f.$2, style: GText.body2(c.textPrimary))),
              ]),
            ),
        ]),
      ),
    ]);
  }
}

/// Table + detail panel side by side on wide screens; table only otherwise
/// (the caller opens the panel as a bottom sheet).
class SchoolErpMasterDetail extends StatelessWidget {
  const SchoolErpMasterDetail({super.key, required this.master, this.detail});
  final Widget master;
  final Widget? detail;

  @override
  Widget build(BuildContext context) {
    if (detail == null || !SchoolErp.wide(context)) return master;
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(child: master),
      const SizedBox(width: Gsp.sp4),
      SizedBox(width: SchoolErp.panelWidth, child: detail),
    ]);
  }
}
