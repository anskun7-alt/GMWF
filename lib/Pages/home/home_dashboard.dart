// lib/pages/home/home_dashboard.dart
//
// The redesigned dashboard (Wave 1), on gmwf_ui and its dashboard kit.
// Data is unchanged (HomeSnapshot: local first, then cloud-merged; the global
// dashboardController filter). Filtered and unfiltered views share one layout,
// and every section always shows its figures — zeros included — so the page
// keeps its shape early in the morning and on a fresh install.
//
//   greeting ··························· filters (right)
//   KPI row (8)
//   trends + period totals     | patients by category (donut + legend)
//   patients by branch (bars)  | branch performance (table)
//   best branch                | recent activity | quick actions
//   recent donations           | recent patients

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gmwf_ui/dashboard.dart';
import 'package:gmwf_ui/gmwf_ui.dart';
import 'package:intl/intl.dart';

import '../../models/module_registry.dart';
import '../../providers/branches_providers.dart' show selectedBranchTabIdProvider, branchSubDispensaryFilterProvider;
import '../../services/home_dashboard_service.dart';
import '../../services/local_storage_service.dart';
import '../../widgets/dashboard_widgets.dart'
    show BranchStats, DashboardFilter, TimeRange, dashboardController, fetchBranchStats, statsCacheGet, statsCacheKey;
import '../../widgets/home_snapshot_widgets.dart'
    show SnapshotDashboardData, HomeBranchRow, AppreciationTrophyDialog, BranchDashboardOverlay, fetchBranchDashboardOverlay;
import '../branches.dart' show Branches;
import 'home_data.dart';
import 'home_motion.dart';
import 'home_widgets.dart';

class HomeDashboard extends ConsumerStatefulWidget {
  const HomeDashboard({
    super.key,
    required this.userData,
    required this.userName,
    required this.modules,
    required this.onOpenModule,
  });

  final Map<String, dynamic> userData;
  final String userName;
  final List<AppModule> modules;

  /// Opens a module inside the shell, optionally on one of its sections.
  final void Function(AppModule module, {String? section}) onOpenModule;

  @override
  ConsumerState<HomeDashboard> createState() => _HomeDashboardState();
}

// ── Helpers ─────────────────────────────────────────────────────────────────

String _roleOf(Map<String, dynamic> d) => (d['role']?.toString() ?? '').toLowerCase().trim();
String _branchOf(Map<String, dynamic> d) => (d['branchId']?.toString() ?? '').toLowerCase().trim();
int _patients(BranchStats s) => s.zakat + s.nonZakat + s.gmwf;
int _score(BranchStats s) => s.donations + s.dispensaryRevenue + _patients(s) * 100;

/// "Karachi — Haji Camp Dispensary" → "Haji Camp".
String _short(String name) {
  final n = name.contains('—') ? name.split('—').last.trim() : name;
  return n.replaceAll(RegExp(r'\s*Dispensary$'), '');
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  return DateFormat('d MMM').format(t);
}

class _HomeDashboardState extends ConsumerState<HomeDashboard> {
  static final Set<String> _appreciationShown = {};
  final _snap = HomeSnapshot.instance;
  final Map<String, BranchDashboardOverlay> _branchOverlays = {};
  final Set<String> _loadingOverlays = {};

  String get _role => _roleOf(widget.userData);
  String get _userBranch => _branchOf(widget.userData);
  bool get _isBranchManager => _role.contains('branch manager') || _role == 'branch_manager';
  bool get _isExecutive => const ['chairman', 'ceo', 'hq manager', 'hq_manager', 'super_admin', 'admin'].contains(_role);
  bool get _branchLocked => _userBranch.isNotEmpty && _userBranch != 'all' && _userBranch != 'global' && !_isExecutive;

  @override
  void initState() {
    super.initState();
    _snap.addListener(_onData);
    _snap.ensure(widget.userData);
  }

  @override
  void didUpdateWidget(covariant HomeDashboard old) {
    super.didUpdateWidget(old);
    _snap.ensure(widget.userData);
  }

  @override
  void dispose() {
    _snap.removeListener(_onData);
    super.dispose();
  }

  void _onData() {
    if (!mounted) return;
    setState(() {});
    final d = _snap.data;
    if (d != null) _maybeShowAppreciation(d);
  }

  void _ensureBranchOverlay(String branchId) {
    if (branchId == 'all' || _branchLocked) return;
    if (_branchOverlays.containsKey(branchId) || _loadingOverlays.contains(branchId)) return;
    _loadingOverlays.add(branchId);
    fetchBranchDashboardOverlay(branchId).then((ov) {
      _loadingOverlays.remove(branchId);
      if (!mounted) return;
      setState(() => _branchOverlays[branchId] = ov);
    }).catchError((_) {
      _loadingOverlays.remove(branchId);
    });
  }

  /// statsCacheKey → the stats request for that filter (cleared on refresh).
  final Map<String, Future<BranchStats>> _statsFutures = {};

  Future<void> _refresh() async {
    clearLocalStatsCache();
    _statsFutures.clear();
    _branchOverlays.clear();
    final b = _userBranch;
    final ids = b.isNotEmpty && b != 'all' && b != 'global' ? [b] : const ['karachi', 'gujrat', 'sialkot', 'jalalpurjattan', 'rawalpindi'];
    for (final id in ids) {
      unawaited(LocalStorageService.downloadDasterkhwaanTokens(id, days: 2, force: true));
    }
    await _snap.refresh(widget.userData);
  }

  // ── Ranking (existing rule: donations + revenue + patients × 100) ─────────

  List<HomeBranchRow> _ranked(List<HomeBranchRow> rows, {bool yesterday = false}) {
    BranchStats s(HomeBranchRow r) => yesterday ? r.yesterday : r.today;
    return List<HomeBranchRow>.from(rows)
      ..sort((a, b) {
        final d = _score(s(b)).compareTo(_score(s(a)));
        return d != 0 ? d : a.name.compareTo(b.name);
      });
  }

  bool _isMine(HomeBranchRow r) {
    final id = r.id.toLowerCase();
    final mine = _userBranch;
    final name = widget.userName.toLowerCase();
    return (mine.isNotEmpty && (id == mine || id.contains(mine) || mine.contains(id))) ||
        (name.contains('kapaya') && (id.contains('karachi') || id.contains('saddar') || id.contains('kapaya')));
  }

  (int, String)? _managerRank(SnapshotDashboardData d) {
    if (!_isBranchManager) return null;
    final rows = _ranked(d.branchRows, yesterday: true).where((r) => _score(r.yesterday) > 0).take(3).toList();
    for (final (i, r) in rows.indexed) {
      if (_isMine(r)) return (i + 1, r.name);
    }
    return null;
  }

  void _maybeShowAppreciation(SnapshotDashboardData d) {
    final rank = _managerRank(d);
    if (rank == null) return;
    final key = '${widget.userData['id'] ?? widget.userData['userId'] ?? widget.userData['username'] ?? _userBranch}_${DateFormat('yyyyMMdd').format(DateTime.now())}';
    if (!_appreciationShown.add(key)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (_) => AppreciationTrophyDialog(rank: rank.$1, branchName: rank.$2, isDark: context.isDarkTheme),
      );
    });
  }

  // ── Navigation (same targets as the old home) ─────────────────────────────

  /// Opens a tile's target inside the shell. Sectioned screens (Madrassa,
  /// School, Finance) open on the right section via the sidebar's sections.
  void _open(String id) {
    final (mainId, section) = switch (id) {
      'employees' || 'employee_attendance' => ('employees', null),
      'madrassa_attendance' => ('madrassa', 'daily'),
      'madrassa_students' => ('madrassa', 'students'),
      'madrassa_teachers' => ('madrassa', 'teachers'),
      'school_attendance' => ('school_module', 'attendance'),
      'school_teacher_attendance' => ('school_module', 'faculty_attendance'),
      _ => (id, null),
    };
    AppModule? find(String x) => widget.modules.where((m) => m.id == x).firstOrNull;
    final base = find(mainId) ??
        (mainId == 'patients_registration' ? find('patient_register_standalone') : null) ??
        (mainId == 'school_module' ? (find('school_attendance') ?? find('school_teacher_attendance')) : null) ??
        ModuleRegistry.allModules.where((m) => m.id == mainId).firstOrNull;
    if (base == null) return;
    widget.onOpenModule(base, section: section);
  }

  void _openBranch(String rawId) {
    final norm = rawId.toLowerCase().trim().replaceAll(' ', '_').replaceAll('-', '_');
    final target = norm.startsWith('karachi') ? 'karachi' : norm;
    final allowed = _isExecutive || !_branchLocked || _userBranch == target || _userBranch.startsWith(target) || target.startsWith(_userBranch);
    if (!allowed) {
      AppFeedback.warning(context, 'Access is limited to your branch (${RecentActivityService.resolveBranchName(_userBranch)}).');
      return;
    }
    ref.read(selectedBranchTabIdProvider.notifier).state = target.contains('jalal') ? 'jalalpur_jattan' : target;
    ref.read(branchSubDispensaryFilterProvider.notifier).state = switch (norm) {
      'karachi_saddar' => 'saddar',
      'karachi_haji' => 'haji_camp',
      _ => null,
    };
    final name = RecentActivityService.resolveBranchName(target);
    widget.onOpenModule(AppModule(
      id: 'branches',
      title: 'Branches – $name',
      description: 'Performance and dispensary details for $name',
      icon: GIcons.branch,
      category: ModuleCategory.dispensary,
      builder: (_, _) => Branches(
        branchId: _isExecutive ? null : (_userBranch.isNotEmpty ? _userBranch : target),
        initialBranchId: target,
        isManager: false,
      ),
    ));
  }

  bool _has(String id) => switch (id) {
        'employees' => widget.modules.any((m) => m.id == 'employees' || m.id == 'finance'),
        'madrassa_attendance' || 'madrassa_students' => widget.modules.any((m) => m.id == 'madrassa'),
        'school_attendance' => widget.modules.any((m) => m.category == ModuleCategory.school),
        'patients_registration' => widget.modules.any((m) => m.id == 'patients_registration' || m.id == 'patient_register_standalone'),
        _ => widget.modules.any((m) => m.id == id),
      };

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DashboardFilter>(
      valueListenable: dashboardController,
      builder: (context, filter, _) => LayoutBuilder(builder: (context, box) {
        final pad = box.maxWidth < 600 ? Gsp.sp4 : Gsp.sp6;
        final width = box.maxWidth - pad * 2;
        final data = _snap.data;
        return RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            padding: EdgeInsets.fromLTRB(pad, Gsp.sp5, pad, Gsp.sp10),
            children: [
              _header(context, width, filter, data),
              const SizedBox(height: Gsp.sp5),
              if (data == null)
                _snap.error != null ? _errorState(context) : _skeleton(context, width)
              else
                _content(context, width, data, filter),
            ],
          ),
        );
      }),
    );
  }

  // ── Header: greeting left, filters right ──────────────────────────────────

  static const _ranges = [
    (TimeRange.today, 'Today'),
    (TimeRange.yesterday, 'Yesterday'),
    (TimeRange.week, '7 days'),
    (TimeRange.month, '30 days'),
    (TimeRange.thisMonth, 'This month'),
  ];

  String _rangeLabel(TimeRange r) => _ranges.where((e) => e.$1 == r).firstOrNull?.$2 ?? 'Custom range';

  String get _greeting {
    final h = DateTime.now().hour;
    return h < 12 ? 'Good morning' : h < 17 ? 'Good afternoon' : 'Good evening';
  }

  Widget _header(BuildContext context, double width, DashboardFilter filter, SnapshotDashboardData? data) {
    final c = context.comfort;
    final scope = filter.branchId != 'all' && filter.branchId.isNotEmpty
        ? RecentActivityService.resolveBranchName(filter.branchId)
        : _branchLocked
            ? RecentActivityService.resolveBranchName(_userBranch)
            : 'All branches';
    final first = widget.userName.trim().split(RegExp(r'\s+')).first;

    final greeting = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text('Assalam-o-Alaikum, $first', style: GText.h2(c.textPrimary), maxLines: 1, overflow: TextOverflow.ellipsis),
      const SizedBox(height: 2),
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 7, height: 7, decoration: BoxDecoration(color: _snap.refreshing ? c.warning : c.success, shape: BoxShape.circle)),
        const SizedBox(width: Gsp.sp2),
        Flexible(
          child: Text(
            '$_greeting · ${DateFormat('EEE, d MMM').format(DateTime.now())} · $scope · updated ${DateFormat('h:mm a').format(_snap.updatedAt)}',
            style: GText.caption(c.textSecondary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ]),
    ]);

    final branches = <(String, String)>[
      if (data != null && !_branchLocked)
        for (final r in data.branchRows) (r.id, r.name),
    ];
    final selectedBranch = branches.any((b) => b.$1 == filter.branchId) ? filter.branchId : null;
    final small = GText.label(c.textPrimary);

    final controls = Wrap(
      alignment: WrapAlignment.end,
      spacing: Gsp.sp2,
      runSpacing: Gsp.sp2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SegmentedButton<TimeRange>(
          showSelectedIcon: false,
          style: ButtonStyle(
            visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
            textStyle: WidgetStatePropertyAll(small),
            padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: Gsp.sp3)),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          segments: [for (final (r, l) in _ranges) ButtonSegment(value: r, label: Text(l, maxLines: 1, softWrap: false))],
          selected: {_ranges.any((e) => e.$1 == filter.timeRange) ? filter.timeRange : TimeRange.today},
          onSelectionChanged: (s) => dashboardController.setTimeRange(s.first),
        ),
        if (branches.isNotEmpty)
          Container(
            height: 36,
            padding: const EdgeInsets.only(left: Gsp.sp3, right: Gsp.sp2),
            decoration: BoxDecoration(color: c.surface, borderRadius: Gr.button, border: Border.all(color: c.borderStrong)),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String?>(
                value: selectedBranch,
                isDense: true,
                icon: Icon(GIcons.chevronDown, size: GIconSize.sm, color: c.textSecondary),
                style: small,
                dropdownColor: c.surfaceRaised,
                borderRadius: Gr.input,
                items: [
                  DropdownMenuItem<String?>(
                    value: null,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(GIcons.branch, size: GIconSize.sm, color: c.textMuted),
                      const SizedBox(width: Gsp.sp2),
                      const Text('All branches'),
                    ]),
                  ),
                  for (final (id, name) in branches) DropdownMenuItem<String?>(value: id, child: Text(name)),
                ],
                onChanged: (v) => dashboardController.setBranch(v ?? 'all'),
              ),
            ),
          ),
        SizedBox(
          height: 36,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              textStyle: small,
              padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3),
              visualDensity: VisualDensity.compact,
            ),
            onPressed: _snap.refreshing ? null : _refresh,
            icon: _snap.refreshing
                ? SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: c.textSecondary))
                : const Icon(GIcons.refresh, size: GIconSize.sm),
            label: Text(_snap.refreshing ? 'Syncing' : 'Refresh'),
          ),
        ),
      ],
    );

    if (width < 1000) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        greeting,
        const SizedBox(height: Gsp.sp3),
        Align(alignment: AlignmentDirectional.centerEnd, child: controls),
      ]);
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      Expanded(child: greeting),
      const SizedBox(width: Gsp.sp4),
      controls,
    ]);
  }

  // ── Content ───────────────────────────────────────────────────────────────

  Widget _content(BuildContext context, double width, SnapshotDashboardData data, DashboardFilter filter) {
    final branch = filter.branchId.isEmpty ? 'all' : filter.branchId;
    if (branch != 'all' && !_branchLocked) {
      _ensureBranchOverlay(branch);
    }
    final overlay = (branch != 'all' && !_branchLocked) ? _branchOverlays[branch] : null;
    final activeBranch = _branchLocked ? _userBranch : branch;
    final row = branch == 'all' ? null : data.branchRows.where((r) => r.id == branch).firstOrNull;
    final isToday = filter.timeRange == TimeRange.today && filter.patientType == null && !filter.multiDayMedicineOnly;

    Widget body(BranchStats now, BranchStats? prev) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _sections(
            context,
            width,
            data,
            now,
            prev,
            filter,
            highlight: row?.id,
            activeBranch: activeBranch,
            overlay: overlay,
          ),
        );

    if (isToday && (branch == 'all' || row != null)) {
      return body(row?.today ?? data.todayCombined, row?.yesterday ?? data.yesterdayCombined);
    }
    final key = statsCacheKey(branch, filter);
    // One request per filter: a FutureBuilder given a new future on every
    // rebuild re-ran the (possibly 30-day) stats scan each time the snapshot ticked.
    final future = _statsFutures.putIfAbsent(key, () {
      final f = fetchBranchStats(branch, filter: filter);
      // A failed request is forgotten so the next rebuild retries it.
      f.then((_) {}, onError: (Object _) => _statsFutures.remove(key));
      return f;
    });
    return FutureBuilder<BranchStats>(
      key: ValueKey(key),
      initialData: statsCacheGet(key),
      future: future,
      builder: (context, snap) {
        final s = snap.data;
        if (s == null) return snap.hasError ? _errorState(context) : _skeleton(context, width);
        return body(s, null);
      },
    );
  }

  List<Widget> _sections(
    BuildContext context,
    double w,
    SnapshotDashboardData data,
    BranchStats now,
    BranchStats? prev,
    DashboardFilter filter, {
    String? highlight,
    required String activeBranch,
    BranchDashboardOverlay? overlay,
  }) {
    final c = context.comfort;
    final ranked = _ranked(data.branchRows);
    final best = ranked.isNotEmpty && _score(ranked.first.today) > 0 ? ranked.first : null;
    final rank = _managerRank(data);
    final range = _rangeLabel(filter.timeRange);
    final today = filter.timeRange == TimeRange.today;

    final hasDispensary = LocalStorageService.hasBranchFacility(activeBranch, 'dispensary');
    final hasDasterkhwaan = LocalStorageService.hasBranchFacility(activeBranch, 'dasterkhwaan');
    final hasMadrassa = LocalStorageService.hasBranchFacility(activeBranch, 'madrassa');
    final hasSchool = LocalStorageService.hasBranchFacility(activeBranch, 'school');

    final empPresentCount = overlay?.auxCounts['emp'] ?? data.empPresentCount;
    final studentPresentCount = overlay?.auxCounts['students'] ?? data.studentPresentCount;
    final teacherPresentCount = overlay?.auxCounts['teachers'] ?? data.teacherPresentCount;
    final madrassaPresentCount = overlay?.auxCounts['madrassa'] ?? data.madrassaPresentCount;
    final madrassaYesterdayPresentCount = overlay?.auxCounts['madrassa_yesterday'] ?? data.madrassaYesterdayPresentCount;
    final madrassaTeacherPresentCount = overlay?.auxCounts['madrassa_teachers'] ?? data.madrassaTeacherPresentCount;
    final madrassaTeacherYesterdayPresentCount = overlay?.auxCounts['madrassa_teachers_yesterday'] ?? data.madrassaTeacherYesterdayPresentCount;

    final pts = overlay?.chartPoints ?? data.chartPoints;
    final recentActivities = overlay?.recentActivities ?? data.recentActivities;
    List<double>? spark(num Function(HomeLineChartPoint) f) => pts.length < 2 ? null : [for (final p in pts) f(p).toDouble()];

    // Today's trend only once there is something today; before that, show
    // yesterday's figure instead of a misleading "-100%".
    double? delta(num a, num? b) => (b == null || b == 0 || a == 0) ? null : (a - b) / b;
    String foot(num a, num? b, String Function(num) fmt, String fallback) =>
        (prev != null && a == 0 && (b ?? 0) > 0) ? 'Yesterday ${fmt(b!)}' : fallback;
    final attendanceFoot = today ? null : 'Attendance is today’s';

    final kpis = <Widget>[
      if (hasDispensary)
        GKpiTile(
          label: 'Patients',
          value: GFormat.count(_patients(now)),
          icon: GIcons.patient,
          color: c.chart1,
          delta: delta(_patients(now), prev == null ? null : _patients(prev)),
          caption: foot(_patients(now), prev == null ? null : _patients(prev), GFormat.count, '${GFormat.count(now.dispensed)} dispensed · $range'),
          spark: spark((p) => p.tokens),
          onTap: () => _openBranch(highlight ?? (_branchLocked ? _userBranch : (best?.id ?? 'karachi'))),
        ),
      GKpiTile(
        label: 'Donations',
        value: GFormat.pkrCompact(now.donations),
        icon: GIcons.donation,
        color: c.chart2,
        delta: delta(now.donations, prev?.donations),
        caption: foot(now.donations, prev?.donations, GFormat.pkrCompact, range),
        spark: spark((p) => p.donations),
        onTap: _has('donations') ? () => _open('donations') : null,
      ),
      if (hasDispensary)
        GKpiTile(
          label: 'Dispensary revenue',
          value: GFormat.pkrCompact(now.dispensaryRevenue),
          icon: GIcons.pharmacy,
          color: c.chart3,
          delta: delta(now.dispensaryRevenue, prev?.dispensaryRevenue),
          caption: foot(now.dispensaryRevenue, prev?.dispensaryRevenue, GFormat.pkrCompact, range),
          spark: spark((p) => p.patientsRevenue),
          onTap: () => _openBranch(highlight ?? (_branchLocked ? _userBranch : (best?.id ?? 'karachi'))),
        ),
      if (hasDasterkhwaan)
        GKpiTile(
          label: 'Food tokens',
          value: GFormat.count(now.dasterkhwaan),
          icon: GIcons.food,
          color: c.chart4,
          delta: delta(now.dasterkhwaan, prev?.dasterkhwaan),
          caption: '${GFormat.count(now.dasterkhwaanServed)} meals served',
          onTap: _has('office_boy')
              ? () => _open('office_boy')
              : (_has('kitchen')
                  ? () => _open('kitchen')
                  : (_has('dasterkhwaan_food_log') ? () => _open('dasterkhwaan_food_log') : null)),
        ),
      GKpiTile(
        label: 'Staff present',
        value: GFormat.count(empPresentCount),
        icon: GIcons.attendance,
        color: c.info,
        spark: spark((p) => p.employeesPresent),
        caption: attendanceFoot ?? 'Biometric and manual check-ins',
        onTap: _has('employees') ? () => _open('employees') : null,
      ),
      if (hasMadrassa)
        GKpiTile(
          label: 'Madrassa students',
          value: GFormat.count(madrassaPresentCount),
          icon: GIcons.madrassa,
          color: c.success,
          delta: delta(madrassaPresentCount, madrassaYesterdayPresentCount),
          caption: attendanceFoot ??
              (madrassaYesterdayPresentCount > 0 ? 'Yesterday $madrassaYesterdayPresentCount' : 'Present today'),
          onTap: _has('madrassa_attendance') ? () => _open('madrassa_attendance') : null,
        ),
      if (hasMadrassa)
        GKpiTile(
          label: 'Madrassa teachers',
          value: GFormat.count(madrassaTeacherPresentCount),
          icon: GIcons.teacher,
          color: c.accent,
          delta: delta(madrassaTeacherPresentCount, madrassaTeacherYesterdayPresentCount),
          caption: attendanceFoot ??
              (madrassaTeacherYesterdayPresentCount > 0 ? 'Yesterday $madrassaTeacherYesterdayPresentCount' : 'Present today'),
          onTap: _has('madrassa_attendance') ? () => _open('madrassa_teachers') : null,
        ),
      if (hasSchool)
        GKpiTile(
          label: 'School students',
          value: GFormat.count(studentPresentCount),
          icon: GIcons.student,
          color: c.brand,
          caption: '${GFormat.count(teacherPresentCount)} faculty present',
          onTap: _has('school_attendance') ? () => _open('school_attendance') : null,
        ),
    ];

    return [
      if (rank != null) ...[
        ManagerTrophyBanner(
          rank: rank.$1,
          branch: rank.$2,
          message: 'Yesterday your branch ranked #${rank.$1} across GMWF on patients, revenue and donations. Keep it up!',
        ).enter(context),
        const SizedBox(height: Gsp.sp4),
      ],
      homeGrid(w, [for (final (i, k) in kpis.indexed) k.enter(context, index: i)]),
      const SizedBox(height: Gsp.sp3),
      homeRow(w, height: 290, [
        (2, _trends(context, pts)),
        (1, _categories(context, now, range)),
      ]).enter(context, index: 8),
      const SizedBox(height: Gsp.sp3),
      homeRow(w, height: 300, [
        (2, _branchBars(context, data.branchRows, highlight)),
        (3, GSection(
          title: _isBranchManager ? 'Camps' : 'Branch performance',
          subtitle: 'Today, ranked · tap a row to open',
          icon: GIcons.chart,
          iconColor: c.brand,
          child: _branchList(context, ranked, highlight),
        )),
      ]).enter(context, index: 9),
      const SizedBox(height: Gsp.sp3),
      homeRow(w, height: 280, [
        (1, best != null
            ? _Spotlight(row: best, title: _isBranchManager ? 'Top camp today' : 'Best branch today', onTap: () => _openBranch(best.id))
            : _SpotlightEmpty(branches: data.branchRows.length)),
        (1, _activity(context, recentActivities)),
        (1, _quickActions(context, now, activeBranch)),
      ]).enter(context, index: 10),
      const SizedBox(height: Gsp.sp3),
      homeRow(w, height: 270, [
        (1, _recentList(context, recentActivities, donations: true)),
        (1, _recentList(context, recentActivities, donations: false)),
      ]).enter(context, index: 11),
    ];
  }

  // ── Sections ──────────────────────────────────────────────────────────────

  Widget _trends(BuildContext context, List<HomeLineChartPoint> pts) {
    final c = context.comfort;
    final monthly = pts.length >= 2 && pts.last.date.difference(pts.first.date).inDays >= (pts.length - 1) * 20;
    final fmt = DateFormat(monthly ? 'MMM' : 'd MMM');
    final donations = pts.fold<int>(0, (a, p) => a + p.donations);
    final revenue = pts.fold<int>(0, (a, p) => a + p.patientsRevenue);
    final patients = pts.fold<int>(0, (a, p) => a + p.tokens);

    Widget total(String label, String value, Color dot) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: dot, borderRadius: BorderRadius.circular(2))),
              const SizedBox(width: Gsp.sp2),
              Flexible(child: Text(label, style: GText.caption(c.textMuted), overflow: TextOverflow.ellipsis)),
            ]),
            const SizedBox(height: 2),
            Text(value, style: GText.h3(c.textPrimary)),
          ]),
        );

    return GSection(
      title: 'Donations and dispensary revenue',
      subtitle: pts.isEmpty ? 'No history yet' : '${monthly ? 'Monthly' : 'Daily'} · since ${DateFormat('d MMM').format(pts.first.date)}',
      icon: GIcons.trendUp,
      iconColor: c.chart2,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          total('Donations', GFormat.pkrCompact(donations), c.chart2),
          total('Dispensary revenue', GFormat.pkrCompact(revenue), c.chart1),
          total('Patients', GFormat.count(patients), c.textMuted),
        ]),
        const SizedBox(height: Gsp.sp3),
        Expanded(
          child: Container(
            padding: const EdgeInsets.fromLTRB(Gsp.sp2, Gsp.sp3, Gsp.sp3, Gsp.sp2),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: Gr.card,
              border: Border.all(color: c.border),
            ),
            child: pts.length < 2
                ? const HomeEmpty('The chart fills in as days are recorded', icon: GIcons.chart)
                // The chart adds a legend row (≈ 36px with its gap) under its plot;
                // size the plot to what is left so nothing overflows at any text scale.
                : LayoutBuilder(
                    builder: (context, box) => ClipRect(
                      child: GLineChart(
                        height: math.max(80, box.maxHeight - 36 * MediaQuery.textScalerOf(context).scale(1)),
                        xLabels: [for (final p in pts) fmt.format(p.date)],
                        format: (v) => GFormat.compact(v),
                        series: [
                          GSeries('Donations', [for (final p in pts) p.donations.toDouble()], color: c.chart2),
                          GSeries('Dispensary revenue', [for (final p in pts) p.patientsRevenue.toDouble()], color: c.chart1),
                        ],
                      ),
                    ),
                  ),
          ),
        ),
      ]),
    );
  }

  Widget _categories(BuildContext context, BranchStats s, String range) {
    final c = context.comfort;
    final total = _patients(s);
    final parts = [
      ('Zakat', s.zakat, c.chart1),
      ('Non-Zakat', s.nonZakat, c.chart2),
      ('GMWF', s.gmwf, c.chart3),
    ];
    return GSection(
      title: 'Patients by category',
      subtitle: range,
      icon: GIcons.patient,
      iconColor: c.chart1,
      child: Column(children: [
        Expanded(
          child: Center(
            child: total == 0
                ? GProgressRing(value: 0, size: 132, stroke: 12, color: c.border, label: '0 PATIENTS')
                : GDonutChart(
                    size: 140,
                    showLegend: false,
                    centerValue: GFormat.count(total),
                    centerLabel: 'patients',
                    data: [for (final (l, v, col) in parts) GDatum(l, v.toDouble(), color: col)],
                  ),
          ),
        ),
        const SizedBox(height: Gsp.sp3),
        for (final (l, v, col) in parts)
          Padding(
            padding: const EdgeInsets.only(top: Gsp.sp2),
            child: Row(children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: col, shape: BoxShape.circle)),
              const SizedBox(width: Gsp.sp2),
              Expanded(child: Text(l, style: GText.body2(c.textSecondary))),
              Text(GFormat.count(v), style: GText.numeric(c.textPrimary)),
              SizedBox(
                width: 44,
                child: Text(total == 0 ? '—' : GFormat.percent(v / total), style: GText.caption(c.textMuted), textAlign: TextAlign.right),
              ),
            ]),
          ),
      ]),
    );
  }

  /// Horizontal bars: every branch is always listed, zeros included.
  Widget _branchBars(BuildContext context, List<HomeBranchRow> rows, String? highlight) {
    final c = context.comfort;
    final sorted = List<HomeBranchRow>.from(rows)..sort((a, b) => _patients(b.today).compareTo(_patients(a.today)));
    final top = sorted.map((r) => _patients(r.today)).fold<int>(0, math.max);
    return GSection(
      title: _isBranchManager ? 'Patients by camp' : 'Patients by branch',
      subtitle: 'Today · vs yesterday',
      icon: GIcons.branch,
      iconColor: c.chart1,
      child: GDataList(
        columns: const [
          GDataColumn('Branch', flex: 4),
          GDataColumn.numeric('Today', flex: 2),
          GDataColumn.numeric('Yesterday', flex: 2),
          GDataColumn('Share', flex: 3, hideBelow: 380),
        ],
        empty: const HomeEmpty('No branches yet'),
        rows: [
          for (final r in sorted)
            GDataRow(
              selected: r.id == highlight,
              onTap: () => _openBranch(r.id),
              cells: [
                GCell.title(_short(r.name), mark: GTrendMark(now: _patients(r.today), before: _patients(r.yesterday))),
                GCell.number(GFormat.count(_patients(r.today))),
                GCell.number(GFormat.count(_patients(r.yesterday)), muted: true),
                GCell.progress(top == 0 ? 0 : _patients(r.today) / top, color: r.id == highlight ? c.accent : c.chart1),
              ],
            ),
        ],
      ),
    );
  }

  /// Branch performance, ranked (the reference list design: GDataList).
  Widget _branchList(BuildContext context, List<HomeBranchRow> ranked, String? highlight) {
    final c = context.comfort;
    final maxScore = ranked.map((r) => _score(r.today)).fold<int>(0, math.max);
    return GDataList(
      columns: const [
        GDataColumn('Branch', flex: 4),
        GDataColumn.numeric('Patients', flex: 2),
        GDataColumn.numeric('Revenue', flex: 3, hideBelow: 520),
        GDataColumn.numeric('Donations', flex: 3),
        GDataColumn('Share', flex: 3, hideBelow: 620),
      ],
      empty: const HomeEmpty('No branches yet'),
      rows: [
        for (final (i, r) in ranked.indexed)
          GDataRow(
            leading: GRankBadge(i + 1, highlight: _score(r.today) > 0),
            selected: r.id == highlight,
            onTap: () => _openBranch(r.id),
            cells: [
              GCell.title(_short(r.name), subtitle: r.subtitle, mark: GTrendMark(now: _patients(r.today), before: _patients(r.yesterday))),
              GCell.number(GFormat.count(_patients(r.today))),
              GCell.number(GFormat.pkrCompact(r.today.dispensaryRevenue), muted: true),
              GCell.number(GFormat.pkrCompact(r.today.donations), muted: true),
              GCell.progress(maxScore == 0 ? 0 : _score(r.today) / maxScore, color: i == 0 ? c.accent : c.brand),
            ],
          ),
      ],
    );
  }

  Widget _activity(BuildContext context, List<RecentActivity> items) {
    final c = context.comfort;
    return GSection(
      title: 'Recent activity',
      subtitle: 'Latest clinic and branch events',
      icon: GIcons.history,
      iconColor: c.info,
      child: GDataList(
        leadingWidth: 42,
        columns: const [GDataColumn('Event', flex: 6), GDataColumn.numeric('When', flex: 1)],
        empty: const HomeEmpty('Tokens and donations appear here as they happen'),
        rows: [
          for (final a in items.take(10))
            GDataRow(
              leading: GModuleTile(
                icon: a.type == 'donation' ? GIcons.donation : GIcons.token,
                color: a.type == 'donation' ? c.chart2 : c.chart1,
                size: 30,
              ),
              cells: [
                GCell.title(a.title, subtitle: [a.branchName, a.subtitle].where((s) => s.trim().isNotEmpty).join(' · ')),
                GCell.text(_ago(a.timestamp)),
              ],
            ),
        ],
      ),
    );
  }

  Widget _quickActions(BuildContext context, BranchStats now, String activeBranch) {
    final c = context.comfort;
    final hasDispensary = LocalStorageService.hasBranchFacility(activeBranch, 'dispensary');
    final hasDasterkhwaan = LocalStorageService.hasBranchFacility(activeBranch, 'dasterkhwaan');
    final hasMadrassa = LocalStorageService.hasBranchFacility(activeBranch, 'madrassa');
    final hasSchool = LocalStorageService.hasBranchFacility(activeBranch, 'school');
    final all = <(String, String, IconData, Color)>[
      if (hasDispensary) ('patients_registration', 'Add patient', GIcons.registerPatient, c.chart1),
      ('donations', 'Record donation', GIcons.donation, c.chart2),
      if (hasDasterkhwaan) ('office_boy', now.dasterkhwaan > 0 ? 'Food tokens · ${now.dasterkhwaan}' : 'Food tokens', GIcons.food, c.chart4),
      ('employees', 'Staff attendance', GIcons.attendance, c.info),
      if (hasMadrassa) ('madrassa_attendance', 'Madrassa log', GIcons.madrassa, c.success),
      if (hasSchool) ('school_attendance', 'School attendance', GIcons.student, c.brand),
      if (hasDispensary) ('inventory', 'Med inventory', GIcons.inventory, c.chart3),
      ('finance', 'Finance', GIcons.money, c.accent),
      ('branches', 'Branches', GIcons.branch, c.textSecondary),
    ];
    final actions = [
      for (final (id, label, icon, color) in all)
        if (_has(id)) (id, label, icon, color),
    ].take(8).toList();

    return GSection(
      title: 'Quick actions',
      subtitle: 'Shortcuts for your role',
      icon: GIcons.flow,
      iconColor: c.accent,
      child: GDataList(
        leadingWidth: 40,
        showHeader: false,
        columns: const [GDataColumn('Action', flex: 1)],
        empty: const HomeEmpty('No shortcuts for your role'),
        rows: [
          for (final (id, label, icon, color) in actions)
            GDataRow(
              leading: GModuleTile(icon: icon, color: color, size: 28),
              trailing: Icon(GIcons.chevronRight, size: GIconSize.sm, color: c.textMuted),
              onTap: () => _open(id),
              cells: [GCell.title(label)],
            ),
        ],
      ),
    );
  }

  Widget _recentList(BuildContext context, List<RecentActivity> all, {required bool donations}) {
    final c = context.comfort;
    final items = all.where((a) => donations ? a.type == 'donation' : a.type != 'donation').take(10).toList();
    final viewAll = donations ? 'donations' : 'patients_list';
    return GSection(
      title: donations ? 'Recent donations' : 'Recent patients',
      subtitle: donations ? 'Latest receipts across your branches' : 'Latest tokens issued',
      icon: donations ? GIcons.receipt : GIcons.token,
      iconColor: donations ? c.chart2 : c.chart1,
      action: _has(viewAll)
          ? TextButton(
              style: TextButton.styleFrom(textStyle: GText.label(c.brand), visualDensity: VisualDensity.compact),
              onPressed: () => _open(viewAll),
              child: const Text('View all'),
            )
          : null,
      child: GDataList(
        columns: [
          GDataColumn(donations ? 'Donor' : 'Patient', flex: 5),
          if (donations) const GDataColumn.numeric('Amount', flex: 3),
          const GDataColumn('Status', flex: 2, hideBelow: 420),
          const GDataColumn.numeric('When', flex: 2),
        ],
        empty: HomeEmpty(donations ? 'No donations recorded yet' : 'No patients yet', icon: donations ? GIcons.donation : GIcons.patient),
        rows: [
          for (final a in items)
            GDataRow(cells: [
              GCell.title(a.title, subtitle: [a.branchName, a.subtitle].where((s) => s.trim().isNotEmpty).join(' · ')),
              if (donations) GCell.number(a.amount != null && a.amount! > 0 ? GFormat.pkr(a.amount!) : '—'),
              GCell.text((a.status ?? '').isEmpty ? '—' : a.status!),
              GCell.text(_ago(a.timestamp)),
            ]),
        ],
      ),
    );
  }

  // ── States ────────────────────────────────────────────────────────────────

  Widget _errorState(BuildContext context) {
    final c = context.comfort;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gsp.sp10),
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(GIcons.error, size: GIconSize.xxl, color: c.danger),
          const SizedBox(height: Gsp.sp3),
          Text('The dashboard could not load', style: GText.h3(c.textPrimary)),
          const SizedBox(height: Gsp.sp1),
          Text('${_snap.error}', style: GText.caption(c.textSecondary), textAlign: TextAlign.center),
          const SizedBox(height: Gsp.sp4),
          FilledButton.icon(onPressed: _refresh, icon: const Icon(GIcons.refresh), label: const Text('Retry')),
        ]),
      ),
    );
  }

  Widget _skeleton(BuildContext context, double width) {
    final c = context.comfort;
    Widget block([double? h]) => Container(
          height: h,
          decoration: BoxDecoration(color: c.surfaceSunken, borderRadius: Gr.card, border: Border.all(color: c.border)),
        );
    final shimmer = homeMotionOff(context);
    Widget content = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      homeGrid(width, List.generate(8, (_) => block(GKpiTile.height))),
      const SizedBox(height: Gsp.sp4),
      homeRow(width, height: 360, [(2, block(360)), (1, block(360))]),
      const SizedBox(height: Gsp.sp4),
      homeRow(width, height: 380, [(2, block(380)), (3, block(380))]),
    ]);
    if (!shimmer) content = content.loadingShimmer(context);
    return content;
  }
}

// ── Best branch ─────────────────────────────────────────────────────────────

class _Spotlight extends StatelessWidget {
  const _Spotlight({required this.row, required this.title, required this.onTap});

  final HomeBranchRow row;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final t = row.today;
    final pats = _patients(t);
    final y = _patients(row.yesterday);
    final growth = y > 0 ? (pats - y) / y : null;
    Widget stat(String label, String value) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            FittedBox(fit: BoxFit.scaleDown, alignment: AlignmentDirectional.centerStart, child: Text(value, style: GText.statLg(c.sidebarTextActive))),
            Text(label, style: GText.caption(c.sidebarText)),
          ]),
        );
    return Material(
      color: Colors.transparent,
      borderRadius: Gr.card,
      child: InkWell(
        borderRadius: Gr.card,
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(Gsp.sp5),
          decoration: BoxDecoration(gradient: GColor.heroGradient(c), borderRadius: Gr.card),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: Gsp.sp2, vertical: 3),
                decoration: BoxDecoration(color: c.sidebarActiveLine.withValues(alpha: 0.16), borderRadius: Gr.chip),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(GIcons.star, size: 13, color: c.sidebarActiveLine),
                  const SizedBox(width: 4),
                  Text(title.toUpperCase(), style: GText.overline(c.sidebarActiveLine)),
                ]),
              ),
            ]),
            const Spacer(),
            Text(_short(row.name), style: GText.h2(c.sidebarTextActive), maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Text(
              growth == null ? 'Leading today across GMWF' : '${growth >= 0 ? '+' : ''}${GFormat.percent(growth)} patients vs yesterday',
              style: GText.caption(c.sidebarText),
            ),
            const SizedBox(height: Gsp.sp5),
            Row(children: [
              stat('patients', GFormat.count(pats)),
              stat('revenue', GFormat.compact(t.dispensaryRevenue)),
              stat('donations', GFormat.compact(t.donations)),
            ]),
            const Spacer(),
            Row(children: [
              Text('Open branch', style: GText.label(c.sidebarActiveLine)),
              const SizedBox(width: Gsp.sp1),
              Icon(GIcons.forward, size: GIconSize.sm, color: c.sidebarActiveLine),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _SpotlightEmpty extends StatelessWidget {
  const _SpotlightEmpty({required this.branches});
  final int branches;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    return Container(
      padding: const EdgeInsets.all(Gsp.sp5),
      decoration: BoxDecoration(gradient: GColor.heroGradient(c), borderRadius: Gr.card),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('BEST BRANCH TODAY', style: GText.overline(c.sidebarActiveLine)),
        const Spacer(),
        GLogo(GBrand.gmwf, size: 48),
        const SizedBox(height: Gsp.sp3),
        Text('The race starts with the first token', style: GText.h3(c.sidebarTextActive)),
        const SizedBox(height: 2),
        Text('$branches branches are open for today’s ranking', style: GText.caption(c.sidebarText)),
        const Spacer(),
      ]),
    );
  }
}
