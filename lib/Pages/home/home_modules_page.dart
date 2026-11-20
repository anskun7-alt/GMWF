// lib/pages/home/home_modules_page.dart
//
// A category's overview page, or search results across categories.
//
//   overview:  banner (icon, name, what it covers, module count)
//              live figures for this area today (shared HomeSnapshot)
//              "Start here" — the area's main desks as large cards
//              all modules as cards
//   search:    modules grouped by category

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';

import '../../models/module_registry.dart';
import '../../widgets/dashboard_widgets.dart' show BranchStats;
import '../../widgets/home_snapshot_widgets.dart' show SnapshotDashboardData;
import 'home_data.dart';
import 'home_motion.dart';
import 'home_nav.dart';
import 'home_widgets.dart';

class HomeModulesPage extends StatefulWidget {
  const HomeModulesPage({
    super.key,
    required this.modules,
    required this.onOpenModule,
    required this.userData,
    this.category,
    this.grouped = false,
    this.emptyMessage = 'No modules',
  });

  final List<AppModule> modules;
  final void Function(AppModule) onOpenModule;
  final Map<String, dynamic> userData;

  /// Set for a category overview; null for search results.
  final ModuleCategory? category;
  final bool grouped;
  final String emptyMessage;

  @override
  State<HomeModulesPage> createState() => _HomeModulesPageState();
}

class _HomeModulesPageState extends State<HomeModulesPage> {
  final _snap = HomeSnapshot.instance;

  @override
  void initState() {
    super.initState();
    _snap.addListener(_changed);
    if (widget.category != null) _snap.ensure(widget.userData);
  }

  @override
  void dispose() {
    _snap.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    if (widget.modules.isEmpty) {
      return Center(child: HomeEmpty(widget.emptyMessage, icon: GIcons.searchOff));
    }
    return LayoutBuilder(builder: (context, box) {
      final pad = box.maxWidth < 600 ? Gsp.sp4 : Gsp.sp6;
      final width = box.maxWidth - pad * 2;
      final cat = widget.category;

      final children = <Widget>[];
      if (cat != null) {
        final start = _startHere(widget.modules);
        final rest = widget.modules.where((m) => !start.contains(m)).toList();
        children.addAll([
          _Banner(category: cat, count: widget.modules.length).enter(context),
          const SizedBox(height: Gsp.sp4),
          _LiveStrip(category: cat, data: _snap.data, width: width).enter(context, index: 1),
          const SizedBox(height: Gsp.sp6),
          _heading(context, 'START HERE', 'The main desks for ${cat.label.toLowerCase()}'),
          const SizedBox(height: Gsp.sp3),
          homeRow(width, [
            for (final (i, m) in start.indexed)
              (1, _FeatureCard(module: m, onTap: () => widget.onOpenModule(m)).enter(context, index: 2 + i)),
          ]),
          if (rest.isNotEmpty) ...[
            const SizedBox(height: Gsp.sp6),
            _heading(context, 'ALL MODULES', '${rest.length} more in ${cat.label}'),
            const SizedBox(height: Gsp.sp3),
            _grid(width, [
              for (final (j, m) in rest.indexed)
                _ModuleCard(module: m, onTap: () => widget.onOpenModule(m)).enter(context, index: 4 + j),
            ]),
          ],
        ]);
      } else {
        final groups = widget.grouped ? groupModules(widget.modules) : {widget.modules.first.category: widget.modules};
        for (final (i, e) in groups.entries.indexed) {
          if (i > 0) children.add(const SizedBox(height: Gsp.sp6));
          children.addAll([
            Row(children: [
              GModuleTile(icon: e.key.icon, color: e.key.color(c), size: 26),
              const SizedBox(width: Gsp.sp2),
              Text(e.key.label.toUpperCase(), style: GText.overline(c.textMuted)),
              const SizedBox(width: Gsp.sp2),
              Text('${e.value.length}', style: GText.caption(c.textMuted)),
            ]),
            const SizedBox(height: Gsp.sp3),
            _grid(width, [
              for (final (j, m) in e.value.indexed)
                _ModuleCard(module: m, onTap: () => widget.onOpenModule(m)).enter(context, index: j),
            ]),
          ]);
        }
      }
      return ListView(padding: EdgeInsets.fromLTRB(pad, Gsp.sp5, pad, Gsp.sp10), children: children);
    });
  }

  /// Featured modules first, else the first two of the area.
  List<AppModule> _startHere(List<AppModule> all) {
    final featured = all.where((m) => m.isFeatured).toList();
    final picks = [...featured, ...all.where((m) => !m.isFeatured)];
    return picks.take(all.length == 1 ? 1 : 2).toList();
  }

  Widget _heading(BuildContext context, String title, String sub) {
    final c = context.comfort;
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Text(title, style: GText.overline(c.textMuted)),
      const SizedBox(width: Gsp.sp3),
      Flexible(child: Text(sub, style: GText.caption(c.textMuted), overflow: TextOverflow.ellipsis)),
    ]);
  }

  Widget _grid(double width, List<Widget> cards) {
    final cols = (width / 300).floor().clamp(1, 4);
    final w = (width - Gsp.sp4 * (cols - 1)) / cols;
    return Wrap(spacing: Gsp.sp4, runSpacing: Gsp.sp4, children: [for (final card in cards) SizedBox(width: w, child: card)]);
  }
}

// ── Banner ──────────────────────────────────────────────────────────────────

class _Banner extends StatelessWidget {
  const _Banner({required this.category, required this.count});

  final ModuleCategory category;
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final col = category.color(c);
    return Container(
      padding: const EdgeInsets.all(Gsp.sp5),
      decoration: BoxDecoration(
        borderRadius: Gr.card,
        border: Border.all(color: col.withValues(alpha: 0.25)),
        gradient: LinearGradient(
          begin: AlignmentDirectional.centerStart,
          end: AlignmentDirectional.centerEnd,
          colors: [GColor.tint(col, c.surface, context.isDarkTheme ? 0.20 : 0.10), c.surface],
        ),
      ),
      child: Row(children: [
        GModuleTile(icon: category.icon, color: col, size: 56),
        const SizedBox(width: Gsp.sp4),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(category.label, style: GText.h2(c.textPrimary)),
            const SizedBox(height: 2),
            Text(category.blurb, style: GText.body2(c.textSecondary)),
          ]),
        ),
        const SizedBox(width: Gsp.sp3),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3, vertical: Gsp.sp1),
          decoration: BoxDecoration(color: c.surface, borderRadius: Gr.chip, border: Border.all(color: c.border)),
          child: Text('$count module${count == 1 ? '' : 's'}', style: GText.label(c.textSecondary)),
        ),
      ]),
    );
  }
}

// ── Live figures for the area ───────────────────────────────────────────────

class _LiveStrip extends StatelessWidget {
  const _LiveStrip({required this.category, required this.data, required this.width});

  final ModuleCategory category;
  final SnapshotDashboardData? data;
  final double width;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final d = data;
    final t = d?.todayCombined ?? const BranchStats();
    final y = d?.yesterdayCombined ?? const BranchStats();
    int pats(BranchStats s) => s.zakat + s.nonZakat + s.gmwf;
    double? delta(num a, num b) => (b == 0 || a == 0) ? null : (a - b) / b;
    String dash(String v) => d == null ? '—' : v;

    final List<GKpiTile> tiles = switch (category) {
      ModuleCategory.office => [
          GKpiTile(label: 'Donations today', value: dash(GFormat.pkrCompact(t.donations)), icon: GIcons.donation, color: c.chart2,
              delta: delta(t.donations, y.donations), caption: 'Yesterday ${GFormat.pkrCompact(y.donations)}'),
          GKpiTile(label: 'Staff present', value: dash(GFormat.count(d?.empPresentCount ?? 0)), icon: GIcons.attendance, color: c.info,
              caption: 'Biometric and manual check-ins'),
          GKpiTile(label: 'Total revenue today', value: dash(GFormat.pkrCompact(t.totalRevenue)), icon: GIcons.money, color: c.accent,
              caption: 'Dispensary, food and donations'),
          GKpiTile(label: 'Branches', value: dash(GFormat.count(d?.branchRows.length ?? 0)), icon: GIcons.branch, color: c.brand,
              caption: '${d?.onlineUsersCount ?? 0} users online'),
        ],
      ModuleCategory.dispensary => [
          GKpiTile(label: 'Patients today', value: dash(GFormat.count(pats(t))), icon: GIcons.patient, color: c.chart1,
              delta: delta(pats(t), pats(y)), caption: 'Yesterday ${GFormat.count(pats(y))}'),
          GKpiTile(label: 'Prescriptions dispensed', value: dash(GFormat.count(t.dispensed)), icon: GIcons.pharmacy, color: c.chart3,
              caption: '${GFormat.count(t.prescribed)} prescribed'),
          GKpiTile(label: 'Dispensary revenue', value: dash(GFormat.pkrCompact(t.dispensaryRevenue)), icon: GIcons.money, color: c.chart2,
              delta: delta(t.dispensaryRevenue, y.dispensaryRevenue), caption: 'Yesterday ${GFormat.pkrCompact(y.dispensaryRevenue)}'),
          GKpiTile(label: 'Zakat · Non-Zakat · GMWF', value: dash('${t.zakat} · ${t.nonZakat} · ${t.gmwf}'), icon: GIcons.token, color: c.brand,
              caption: 'Today by category'),
        ],
      ModuleCategory.dasterkhwaan => [
          GKpiTile(label: 'Food tokens today', value: dash(GFormat.count(t.dasterkhwaan)), icon: GIcons.token, color: c.chart4,
              delta: delta(t.dasterkhwaan, y.dasterkhwaan), caption: 'Yesterday ${GFormat.count(y.dasterkhwaan)}'),
          GKpiTile(label: 'Meals served', value: dash(GFormat.count(t.dasterkhwaanServed)), icon: GIcons.kitchen, color: c.success,
              caption: 'From the kitchen'),
          GKpiTile(label: 'Waiting to be served', value: dash(GFormat.count(t.dasterkhwaanPending)), icon: GIcons.waiting, color: c.warning,
              caption: 'Tokens not yet served'),
          GKpiTile(label: 'Served rate', value: dash(t.dasterkhwaan == 0 ? '—' : GFormat.percent(t.dasterkhwaanServed / t.dasterkhwaan)),
              icon: GIcons.checkCircle, color: c.brand, caption: 'Served ÷ issued today'),
        ],
      ModuleCategory.madrassa => [
          GKpiTile(label: 'Students present', value: dash(GFormat.count(d?.madrassaPresentCount ?? 0)), icon: GIcons.madrassa, color: c.success,
              delta: delta(d?.madrassaPresentCount ?? 0, d?.madrassaYesterdayPresentCount ?? 0),
              caption: 'Yesterday ${d?.madrassaYesterdayPresentCount ?? 0}'),
          GKpiTile(label: 'Teachers present', value: dash(GFormat.count(d?.madrassaTeacherPresentCount ?? 0)), icon: GIcons.teacher, color: c.accent,
              delta: delta(d?.madrassaTeacherPresentCount ?? 0, d?.madrassaTeacherYesterdayPresentCount ?? 0),
              caption: 'Yesterday ${d?.madrassaTeacherYesterdayPresentCount ?? 0}'),
        ],
      ModuleCategory.school => [
          GKpiTile(label: 'Students present', value: dash(GFormat.count(d?.studentPresentCount ?? 0)), icon: GIcons.student, color: c.info,
              caption: 'Across campuses today'),
          GKpiTile(label: 'Faculty present', value: dash(GFormat.count(d?.teacherPresentCount ?? 0)), icon: GIcons.teacher, color: c.brand,
              caption: 'Teachers checked in today'),
        ],
    };
    return homeGrid(width, tiles, min: 220);
  }
}

// ── Cards ───────────────────────────────────────────────────────────────────

/// Large "start here" card with an open button.
class _FeatureCard extends StatefulWidget {
  const _FeatureCard({required this.module, required this.onTap});

  final AppModule module;
  final VoidCallback onTap;

  @override
  State<_FeatureCard> createState() => _FeatureCardState();
}

class _FeatureCardState extends State<_FeatureCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final m = widget.module;
    final col = m.category.color(c);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: GMotion.fast,
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: Gr.card,
          border: Border.all(color: _hover ? col.withValues(alpha: 0.55) : c.border),
          boxShadow: _hover ? GShadow.s2(context.isDarkTheme) : GShadow.s1(context.isDarkTheme),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: Gr.card,
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.all(Gsp.sp5),
              child: Row(children: [
                GModuleTile(icon: moduleIcon(m), color: col, size: 52),
                const SizedBox(width: Gsp.sp4),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(m.title, style: GText.h3(c.textPrimary), maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(m.description, style: GText.body2(c.textSecondary), maxLines: 2, overflow: TextOverflow.ellipsis),
                  ]),
                ),
                const SizedBox(width: Gsp.sp3),
                FilledButton.tonalIcon(
                  onPressed: widget.onTap,
                  style: FilledButton.styleFrom(textStyle: GText.label(c.textPrimary), visualDensity: VisualDensity.compact),
                  icon: const Icon(GIcons.openExternal, size: GIconSize.sm),
                  label: const Text('Open'),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _ModuleCard extends StatefulWidget {
  const _ModuleCard({required this.module, required this.onTap});

  final AppModule module;
  final VoidCallback onTap;

  @override
  State<_ModuleCard> createState() => _ModuleCardState();
}

class _ModuleCardState extends State<_ModuleCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final m = widget.module;
    final col = m.category.color(c);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: GMotion.fast,
        height: 92,
        transform: Matrix4.translationValues(0, _hover ? -2 : 0, 0),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: Gr.card,
          border: Border.all(color: _hover ? col.withValues(alpha: 0.55) : c.border),
          boxShadow: _hover ? GShadow.s2(context.isDarkTheme) : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: Gr.card,
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.all(Gsp.sp4),
              child: Row(children: [
                GModuleTile(icon: moduleIcon(m), color: col, size: 40),
                const SizedBox(width: Gsp.sp3),
                Expanded(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(m.title, style: GText.body2Bold(c.textPrimary), maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(m.description, style: GText.caption(c.textSecondary), maxLines: 2, overflow: TextOverflow.ellipsis),
                  ]),
                ),
                const SizedBox(width: Gsp.sp2),
                Icon(GIcons.chevronRight, size: GIconSize.md, color: _hover ? col : c.textMuted),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
