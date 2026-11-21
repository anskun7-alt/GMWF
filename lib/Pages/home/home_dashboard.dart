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

  bool _operationsYearly = false;
  final Map<String, List<HomeLineChartPoint>> _yearlyChartPointsMap = {};
  bool _loadingYearlyChart = false;

  void _ensureYearlyChartPoints(String activeBranch) {
    final cacheKey = activeBranch;
    if (_yearlyChartPointsMap.containsKey(cacheKey) || _loadingYearlyChart) return;
    setState(() => _loadingYearlyChart = true);
    final List<String> branchIds;
    if (activeBranch.isNotEmpty && activeBranch != 'all' && activeBranch != 'global') {
      branchIds = [activeBranch];
    } else {
      final b = _userBranch;
      branchIds = b.isNotEmpty && b != 'all' && b != 'global'
          ? [b]
          : const ['karachi', 'gujrat', 'sialkot', 'jalalpurjattan', 'rawalpindi'];
    }
    fetchChartPoints(branchIds, months: 12).then((loaded) {
      if (!mounted) return;
      setState(() {
        _yearlyChartPointsMap[cacheKey] = loaded;
        _loadingYearlyChart = false;
      });
    }).catchError((_) {
      if (!mounted) return;
      setState(() => _loadingYearlyChart = false);
    });
  }

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
    _yearlyChartPointsMap.clear();
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

    final educationTile = (hasMadrassa || hasSchool)
        ? _EducationKpiTile(
            madrassaStudents: madrassaPresentCount,
            madrassaTeachers: madrassaTeacherPresentCount,
            madrassaDelta: delta(madrassaPresentCount, madrassaYesterdayPresentCount),
            schoolStudents: studentPresentCount,
            schoolTeachers: teacherPresentCount,
            onTapMadrassa: _has('madrassa_attendance') ? () => _open('madrassa_attendance') : null,
            onTapSchool: _has('school_attendance') ? () => _open('school_attendance') : null,
          )
        : null;

    return [
      if (rank != null) ...[
        ManagerTrophyBanner(
          rank: rank.$1,
          branch: rank.$2,
          message: 'Yesterday your branch ranked #${rank.$1} across GMWF on patients, revenue and donations. Keep it up!',
        ).enter(context),
        const SizedBox(height: Gsp.sp4),
      ],
      _buildTopBento(
        context: context,
        width: w,
        kpis: kpis,
        best: best,
        ranked: ranked,
        totalBranches: data.branchRows.length,
        onOpenBest: best != null ? () => _openBranch(best.id) : null,
        isBranchManager: _isBranchManager,
        educationTile: educationTile,
      ),
      const SizedBox(height: Gsp.sp3),
      homeRow(w, height: 320, [
        (2, _trends(context, pts, now, activeBranch)),
        (1, _categories(context, now, range)),
      ]).enter(context, index: 8),
      const SizedBox(height: Gsp.sp3),
      homeRow(w, height: 320, [
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

  Widget _buildTopBento({
    required BuildContext context,
    required double width,
    required List<Widget> kpis,
    required HomeBranchRow? best,
    required List<HomeBranchRow> ranked,
    required int totalBranches,
    required VoidCallback? onOpenBest,
    required bool isBranchManager,
    required Widget? educationTile,
  }) {
    final topCard = best != null
        ? _TopBranchSpotlight(
            row: best,
            ranked: ranked,
            title: isBranchManager ? 'Top camp today' : 'Top branch today',
            onTap: onOpenBest ?? () {},
          )
        : _TopBranchSpotlightEmpty(
            branches: totalBranches,
            ranked: ranked,
            title: isBranchManager ? 'Top camp today' : 'Top branch today',
          );

    // Wide Bento layout (Desktop >= 1060px)
    if (width >= 1060) {
      final leftTiles = educationTile != null
          ? [
              if (kpis.isNotEmpty) kpis[0], // Patients
              if (kpis.length > 1) kpis[1], // Donations
              if (kpis.length > 2) kpis[2], // Dispensary revenue
              if (kpis.length > 3) kpis[3], // Food tokens
              if (kpis.length > 4) kpis[4], // Staff present
              educationTile,               // Campus education (Madrassa + School)
            ]
          : kpis.take(6).toList();

      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final tileW = (constraints.maxWidth - Gsp.sp4 * 2) / 3;
                return Wrap(
                  spacing: Gsp.sp4,
                  runSpacing: Gsp.sp4,
                  children: [
                    for (final (i, t) in leftTiles.indexed)
                      SizedBox(
                        width: tileW,
                        child: t.enter(context, index: i),
                      ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(width: Gsp.sp4),
          Expanded(
            flex: 1,
            child: SizedBox(
              width: double.infinity,
              height: GKpiTile.height * 2 + Gsp.sp4,
              child: topCard.enter(context, index: 6),
            ),
          ),
        ],
      );
    }

    // Tablet & mobile: vertical stack
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        topCard.enter(context, index: 0),
        const SizedBox(height: Gsp.sp4),
        homeGrid(width, [
          for (final (i, k) in kpis.indexed) k.enter(context, index: i + 1),
        ]),
      ],
    );
  }

  Widget _trends(BuildContext context, List<HomeLineChartPoint> defaultPts, BranchStats now, String activeBranch) {
    final c = context.comfort;
    final pts = _operationsYearly
        ? (_yearlyChartPointsMap[activeBranch] ?? defaultPts)
        : defaultPts;
    final monthly = pts.length >= 2 && pts.last.date.difference(pts.first.date).inDays >= (pts.length - 1) * 20;
    final spansYears = pts.length >= 2 && pts.first.date.year != pts.last.date.year;
    final fmt = DateFormat(_operationsYearly ? (spansYears ? "MMM ''yy" : 'MMM') : (monthly ? 'MMM' : 'd MMM'));
    final donations = pts.fold<int>(0, (a, p) => a + p.donations);
    final revenue = pts.fold<int>(0, (a, p) => a + p.patientsRevenue);
    final foodTokens = pts.fold<int>(0, (a, p) => a + p.foodTokens);
    final patients = pts.fold<int>(0, (a, p) => a + p.tokens);

    Widget total(String label, String value, Color dot) => Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: dot.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(Gr.r2),
              border: Border.all(color: dot.withValues(alpha: 0.2)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(width: 7, height: 7, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
                const SizedBox(width: 5),
                Flexible(child: Text(label, style: GText.caption(c.textSecondary), overflow: TextOverflow.ellipsis)),
              ]),
              const SizedBox(height: 2),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: Text(value, style: GText.h3(c.textPrimary)),
              ),
            ]),
          ),
        );

    final String subtitle;
    if (pts.isEmpty) {
      subtitle = 'No history yet';
    } else if (_operationsYearly) {
      subtitle = '12-month annual view · since ${DateFormat('MMM yyyy').format(pts.first.date)}';
    } else {
      subtitle = '${monthly ? 'Monthly' : 'Daily'} · since ${DateFormat('d MMM').format(pts.first.date)}';
    }

    return GSection(
      title: 'Operations',
      subtitle: subtitle,
      icon: GIcons.trendUp,
      iconColor: c.chart2,
      action: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: c.surfaceSunken.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: c.border.withValues(alpha: 0.8)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _operationsPill('Monthly', !_operationsYearly, () {
              if (_operationsYearly) setState(() => _operationsYearly = false);
            }, c),
            _operationsPill('Yearly', _operationsYearly, () {
              if (!_operationsYearly) {
                setState(() => _operationsYearly = true);
                _ensureYearlyChartPoints(activeBranch);
              }
            }, c),
          ],
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          total('Donations', GFormat.pkrCompact(donations), c.chart2),
          total('Dispensary', GFormat.pkrCompact(revenue), c.chart1),
          total('Food tokens', GFormat.count(foodTokens > 0 ? foodTokens : now.dasterkhwaan), c.chart4),
          total('Patients', GFormat.count(patients), c.textMuted),
        ]),
        const SizedBox(height: Gsp.sp2),
        Expanded(
          child: Container(
            padding: const EdgeInsets.fromLTRB(Gsp.sp2, Gsp.sp2, Gsp.sp3, Gsp.sp1),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: Gr.card,
              border: Border.all(color: c.border),
            ),
            child: (_loadingYearlyChart && _yearlyChartPointsMap[activeBranch] == null)
                ? const Center(child: CircularProgressIndicator.adaptive())
                : (pts.length < 2
                    ? const HomeEmpty('The chart fills in as days are recorded', icon: GIcons.chart)
                    : GLineChart(
                        xLabels: [for (final p in pts) fmt.format(p.date)],
                        format: (v) => GFormat.compact(v),
                        curved: false,
                        area: false,
                        series: [
                          GSeries('Donations', [for (final p in pts) p.donations.toDouble()], color: c.chart2),
                          GSeries('Dispensary revenue', [for (final p in pts) p.patientsRevenue.toDouble()], color: c.chart1),
                          GSeries('Food tokens', [for (final p in pts) (p.foodTokens > 0 ? p.foodTokens.toDouble() : (p.tokens * 0.4).roundToDouble())], color: c.chart4),
                        ],
                      )),
          ),
        ),
      ]),
    );
  }

  Widget _operationsPill(String label, bool active, VoidCallback onTap, GComfortColors c) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: active ? c.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: active
              ? GText.label(c.textPrimary).copyWith(fontWeight: FontWeight.w600)
              : GText.caption(c.textSecondary),
        ),
      ),
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
            child: FittedBox(
              fit: BoxFit.contain,
              child: total == 0
                  ? GProgressRing(value: 0, size: 110, stroke: 10, color: c.border, label: '0 PATIENTS')
                  : GDonutChart(
                      size: 116,
                      showLegend: false,
                      centerValue: GFormat.count(total),
                      centerLabel: 'patients',
                      data: [for (final (l, v, col) in parts) GDatum(l, v.toDouble(), color: col)],
                    ),
            ),
          ),
        ),
        const SizedBox(height: Gsp.sp2),
        for (final (l, v, col) in parts)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: col, shape: BoxShape.circle)),
              const SizedBox(width: Gsp.sp2),
              Expanded(child: Text(l, style: GText.body2(c.textSecondary))),
              Text(GFormat.count(v), style: GText.numeric(c.textPrimary)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: col.withValues(alpha: 0.12),
                  borderRadius: Gr.chip,
                ),
                child: Text(
                  total == 0 ? '0%' : GFormat.percent(v / total, digits: 0),
                  style: GText.micro(col),
                ),
              ),
            ]),
          ),
      ]),
    );
  }

  /// Clustered bars: Today vs Yesterday comparison for branches (reference design).
  Widget _branchBars(BuildContext context, List<HomeBranchRow> rows, String? highlight) {
    final c = context.comfort;
    final sorted = List<HomeBranchRow>.from(rows)..sort((a, b) => _patients(b.today).compareTo(_patients(a.today)));
    final top = sorted.map((r) => _patients(r.today)).fold<int>(0, math.max);
    return GSection(
      title: _isBranchManager ? 'Patients by camp' : 'Patients by branch',
      subtitle: 'Today · vs yesterday',
      icon: GIcons.branch,
      iconColor: c.chart1,
      child: _BranchClusteredBarsChart(
        branches: sorted,
        topMax: top,
        highlight: highlight,
        onOpenBranch: _openBranch,
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
            leading: i == 0
                ? GShine(
                    borderRadius: BorderRadius.circular(10),
                    color: Colors.white,
                    duration: const Duration(milliseconds: 600),
                    periodicInterval: const Duration(seconds: 10),
                    child: GRankBadge(i + 1, highlight: _score(r.today) > 0),
                  )
                : GRankBadge(i + 1, highlight: _score(r.today) > 0),
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

// ── Top Branch Spotlight & Clustered Bar Visuals ──────────────────────────────

class _TopBranchSpotlight extends StatelessWidget {
  const _TopBranchSpotlight({
    required this.row,
    required this.ranked,
    required this.title,
    required this.onTap,
  });

  final HomeBranchRow row;
  final List<HomeBranchRow> ranked;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final t = row.today;
    final pats = _patients(t);
    final y = _patients(row.yesterday);
    final growth = y > 0 ? (pats - y) / y : null;
    final otherBranches = ranked.where((r) => r.id != row.id).take(3).toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        final hasBoundedHeight = constraints.hasBoundedHeight;
        return Container(
          width: double.infinity,
          height: hasBoundedHeight ? double.infinity : null,
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: Gr.card,
            border: Border.all(color: c.border),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: Gr.card,
              hoverColor: c.brand.withValues(alpha: 0.04),
              splashColor: c.brand.withValues(alpha: 0.08),
              highlightColor: Colors.transparent,
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(Gsp.sp4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: c.brand.withValues(alpha: 0.08),
                            borderRadius: Gr.chip,
                            border: Border.all(color: c.brand.withValues(alpha: 0.25)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(GIcons.star, size: 12, color: c.brand),
                              const SizedBox(width: 4),
                              Text(
                                title.toUpperCase(),
                                style: GText.micro(c.brand).copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.4),
                              ),
                            ],
                          ),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: c.surfaceSunken,
                            borderRadius: Gr.chip,
                            border: Border.all(color: c.border),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('Open', style: GText.micro(c.textSecondary).copyWith(fontWeight: FontWeight.w600)),
                              const SizedBox(width: 3),
                              Icon(GIcons.forward, size: 10, color: c.textSecondary),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _short(row.name),
                      style: GText.h2(c.textPrimary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      (row.subtitle != null && row.subtitle!.isNotEmpty)
                          ? row.subtitle!
                          : (growth == null
                              ? 'Leading branch today across GMWF'
                              : '${growth >= 0 ? '+' : ''}${GFormat.percent(growth)} patients vs yesterday'),
                      style: GText.caption(c.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            decoration: BoxDecoration(
                              color: c.surfaceSunken,
                              borderRadius: BorderRadius.circular(Gr.r2),
                              border: Border.all(color: c.border),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Patients', style: GText.micro(c.textSecondary).copyWith(fontWeight: FontWeight.w600)),
                                const SizedBox(height: 1),
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(GFormat.count(pats), style: GText.numeric(c.textPrimary)),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            decoration: BoxDecoration(
                              color: c.surfaceSunken,
                              borderRadius: BorderRadius.circular(Gr.r2),
                              border: Border.all(color: c.border),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Revenue', style: GText.micro(c.textSecondary)),
                                const SizedBox(height: 1),
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(GFormat.pkrCompact(t.dispensaryRevenue), style: GText.numeric(c.textPrimary)),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            decoration: BoxDecoration(
                              color: c.surfaceSunken,
                              borderRadius: BorderRadius.circular(Gr.r2),
                              border: Border.all(color: c.border),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Donations', style: GText.micro(c.textSecondary)),
                                const SizedBox(height: 1),
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(GFormat.pkrCompact(t.donations), style: GText.numeric(c.textPrimary)),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (hasBoundedHeight) const Spacer() else const SizedBox(height: 10),
                    if (otherBranches.isNotEmpty) ...[
                      Text('OTHER ACTIVE BRANCHES', style: GText.overline(c.textMuted)),
                      const SizedBox(height: 4),
                      for (final (idx, ob) in otherBranches.indexed)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: Row(
                            children: [
                              Container(
                                width: 15,
                                height: 15,
                                decoration: BoxDecoration(
                                  color: c.surfaceSunken,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: c.border),
                                ),
                                alignment: Alignment.center,
                                child: Text('${idx + 2}', style: GText.micro(c.textSecondary)),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  _short(ob.name),
                                  style: GText.caption(c.textPrimary),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Text(
                                '${GFormat.count(_patients(ob.today))} pts',
                                style: GText.caption(c.textMuted),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TopBranchSpotlightEmpty extends StatelessWidget {
  const _TopBranchSpotlightEmpty({
    required this.branches,
    required this.ranked,
    required this.title,
  });

  final int branches;
  final List<HomeBranchRow> ranked;
  final String title;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 540;
        final hasBoundedHeight = constraints.hasBoundedHeight;

        Widget content;
        if (isWide) {
          // Horizontal / Wide layout for tablet/full-width
          content = Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Left branding & info
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: c.brand.withValues(alpha: 0.08),
                            borderRadius: Gr.chip,
                            border: Border.all(color: c.brand.withValues(alpha: 0.25)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(GIcons.star, size: 12, color: c.brand),
                              const SizedBox(width: 4),
                              Text(
                                title.toUpperCase(),
                                style: GText.micro(c.brand).copyWith(
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: c.success,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          'Awaiting check-in',
                          style: GText.micro(c.textMuted).copyWith(fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: c.surfaceSunken,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: c.border),
                          ),
                          alignment: Alignment.center,
                          child: GLogo(GBrand.gmwf, size: 32),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Ready for today’s ranking',
                                style: GText.h2(c.textPrimary),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '$branches branches open for activity · updates automatically live',
                                style: GText.caption(c.textSecondary),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Gsp.sp4),
              // Right placeholder podium preview
              Expanded(
                flex: 2,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: c.surfaceSunken,
                    borderRadius: BorderRadius.circular(Gr.r2),
                    border: Border.all(color: c.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Icon(GIcons.chart, size: 13, color: c.brand),
                          const SizedBox(width: 6),
                          Text(
                            'LEADERBOARD STANDBY',
                            style: GText.overline(c.brand).copyWith(letterSpacing: 0.6),
                          ),
                          const Spacer(),
                          Text(
                            'Day #1 Rank',
                            style: GText.micro(c.textMuted),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Updates with first patient or donation recorded across any branch.',
                        style: GText.caption(c.textMuted),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          for (int i = 1; i <= 3; i++) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: c.surface,
                                borderRadius: Gr.chip,
                                border: Border.all(color: c.border),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '#$i',
                                    style: GText.micro(c.textMuted).copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Open',
                                    style: GText.micro(c.textMuted),
                                  ),
                                ],
                              ),
                            ),
                            if (i < 3) const SizedBox(width: 6),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        } else {
          // Narrow layout (e.g. desktop flex-1 bento column or mobile)
          content = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: hasBoundedHeight ? MainAxisAlignment.spaceBetween : MainAxisAlignment.start,
            children: [
              // Top badge & status
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: c.brand.withValues(alpha: 0.08),
                      borderRadius: Gr.chip,
                      border: Border.all(color: c.brand.withValues(alpha: 0.25)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(GIcons.star, size: 12, color: c.brand),
                        const SizedBox(width: 4),
                        Text(
                          title.toUpperCase(),
                          style: GText.micro(c.brand).copyWith(
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: c.surfaceSunken,
                      borderRadius: Gr.chip,
                      border: Border.all(color: c.border),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: c.success,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Standby',
                          style: GText.micro(c.textMuted).copyWith(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (!hasBoundedHeight) const SizedBox(height: 14),
              // Center hero & text
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: c.surfaceSunken,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: c.border),
                    ),
                    alignment: Alignment.center,
                    child: GLogo(GBrand.gmwf, size: 28),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Ready for today’s ranking',
                    style: GText.h3(c.textPrimary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$branches branches are open for activity',
                    style: GText.caption(c.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
              if (!hasBoundedHeight) const SizedBox(height: 14),
              // Bottom status bar
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: c.surfaceSunken,
                  borderRadius: BorderRadius.circular(Gr.r2),
                  border: Border.all(color: c.border),
                ),
                child: Row(
                  children: [
                    Icon(GIcons.trendUp, size: 13, color: c.brand),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        'Updates with first patient or donation',
                        style: GText.caption(c.textMuted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        }

        return Container(
          width: double.infinity,
          height: hasBoundedHeight ? double.infinity : null,
          padding: const EdgeInsets.all(Gsp.sp4),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: Gr.card,
            border: Border.all(color: c.border),
          ),
          child: content,
        );
      },
    );
  }
}

class _EducationKpiTile extends StatelessWidget {
  const _EducationKpiTile({
    required this.madrassaStudents,
    required this.madrassaTeachers,
    required this.madrassaDelta,
    required this.schoolStudents,
    required this.schoolTeachers,
    required this.onTapMadrassa,
    required this.onTapSchool,
  });

  final int madrassaStudents;
  final int madrassaTeachers;
  final double? madrassaDelta;
  final int schoolStudents;
  final int schoolTeachers;
  final VoidCallback? onTapMadrassa;
  final VoidCallback? onTapSchool;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    return Container(
      height: GKpiTile.height,
      padding: const EdgeInsets.fromLTRB(Gsp.sp4, Gsp.sp3, Gsp.sp4, Gsp.sp3),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: Gr.card,
        border: Border.all(color: c.border),
        boxShadow: GShadow.s1(context.isDarkTheme),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GModuleTile(icon: GIcons.madrassa, color: c.success, size: 24),
              const SizedBox(width: 6),
              Expanded(
                child: Text('Campus education', style: GText.label(c.textSecondary), maxLines: 1),
              ),
              Icon(GIcons.chevronRight, size: 14, color: c.textMuted),
            ],
          ),
          const Spacer(),
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: onTapMadrassa,
                  borderRadius: BorderRadius.circular(Gr.r2),
                  hoverColor: c.success.withValues(alpha: 0.04),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text('MADRASSA', style: GText.overline(c.textMuted)),
                          if (madrassaDelta != null) ...[
                            const SizedBox(width: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(
                                color: (madrassaDelta! >= 0 ? c.successBg : c.dangerBg),
                                borderRadius: Gr.chip,
                              ),
                              child: Text(
                                '${madrassaDelta! >= 0 ? '+' : ''}${GFormat.percent(madrassaDelta!, digits: 0)}',
                                style: GText.micro(madrassaDelta! >= 0 ? c.success : c.danger),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 1),
                      Text(GFormat.count(madrassaStudents), style: GText.h2(c.textPrimary)),
                      Text('${GFormat.count(madrassaTeachers)} teachers', style: GText.caption(c.textMuted)),
                    ],
                  ),
                ),
              ),
              Container(width: 1, height: 42, color: c.border),
              const SizedBox(width: 10),
              Expanded(
                child: InkWell(
                  onTap: onTapSchool,
                  borderRadius: BorderRadius.circular(Gr.r2),
                  hoverColor: c.brand.withValues(alpha: 0.04),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('SCHOOL', style: GText.overline(c.textMuted)),
                      const SizedBox(height: 1),
                      Text(GFormat.count(schoolStudents), style: GText.h2(c.textPrimary)),
                      Text('${GFormat.count(schoolTeachers)} faculty', style: GText.caption(c.textMuted)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BranchClusteredBarsChart extends StatelessWidget {
  const _BranchClusteredBarsChart({
    required this.branches,
    required this.topMax,
    required this.highlight,
    required this.onOpenBranch,
  });

  final List<HomeBranchRow> branches;
  final int topMax;
  final String? highlight;
  final void Function(String) onOpenBranch;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final maxVal = math.max(topMax, 1);
    final displayed = branches.take(4).toList();

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: c.surfaceSunken.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: c.border.withValues(alpha: 0.6)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 7, height: 7, decoration: BoxDecoration(color: c.chart1, shape: BoxShape.circle)),
                  const SizedBox(width: 5),
                  Text('Today', style: GText.micro(c.textSecondary)),
                  const SizedBox(width: 10),
                  Container(width: 7, height: 7, decoration: BoxDecoration(color: c.borderStrong, shape: BoxShape.circle)),
                  const SizedBox(width: 5),
                  Text('Yesterday', style: GText.micro(c.textMuted)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              return Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _DashedGridPainter(color: c.border.withValues(alpha: 0.45)),
                    ),
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (final b in displayed)
                        Expanded(
                          child: InkWell(
                            onTap: () => onOpenBranch(b.id),
                            borderRadius: BorderRadius.circular(Gr.r2),
                            hoverColor: c.brand.withValues(alpha: 0.04),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      _SingleBar(
                                        value: _patients(b.today),
                                        max: maxVal,
                                        maxHeight: box.maxHeight - 28,
                                        color: b.id == highlight ? c.accent : c.chart1,
                                      ),
                                      const SizedBox(width: 4),
                                      _SingleBar(
                                        value: _patients(b.yesterday),
                                        max: maxVal,
                                        maxHeight: box.maxHeight - 28,
                                        color: c.borderStrong.withValues(alpha: 0.8),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _short(b.name),
                                    style: GText.caption(c.textSecondary),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SingleBar extends StatelessWidget {
  const _SingleBar({
    required this.value,
    required this.max,
    required this.maxHeight,
    required this.color,
  });

  final int value;
  final int max;
  final double maxHeight;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final h = (value / max).clamp(0.04, 1.0) * (maxHeight - 16);
    return Tooltip(
      message: '$value patients',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (value > 0)
            Text('$value', style: GText.micro(c.textPrimary))
          else
            const SizedBox(height: 12),
          const SizedBox(height: 2),
          Container(
            width: 14,
            height: h,
            decoration: BoxDecoration(
              color: color,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
            ),
          ),
        ],
      ),
    );
  }
}

class _DashedGridPainter extends CustomPainter {
  _DashedGridPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = size.height - 20 - (size.height - 30) * i / 3;
      var x = 0.0;
      while (x < size.width) {
        canvas.drawLine(Offset(x, y), Offset(math.min(x + 4, size.width), y), paint);
        x += 8;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedGridPainter old) => old.color != color;
}
