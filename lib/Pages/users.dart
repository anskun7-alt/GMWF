// lib/pages/users.dart — Role-Theme Aware + Full Mobile Responsive

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'dispensary/patient_detail_screen.dart';
import 'user_detail_screen.dart';
import 'register.dart';
import 'dart:async';
import '../theme/role_theme_provider.dart';
import '../theme/app_theme.dart';
import '../services/local_storage_service.dart';
import '../services/offline_auth_service.dart';
import '../services/image_upload_service.dart';
import '../widgets/global_module_wrapper.dart';
import '../widgets/app_back_button.dart';
import '../widgets/device_badge_widget.dart';
import '../utils/formatters.dart';
import '../services/user_module_access_service.dart';
import '../services/device_info_service.dart';
import '../services/finance_local_storage.dart';
import '../services/staff_patient_link_service.dart';

class UsersScreen extends StatefulWidget {
  final bool isPatientMode;
  final bool isGuardianMode;
  final String? branchId;
  final String? currentUserRole;

  const UsersScreen({
    super.key,
    this.isPatientMode = false,
    this.isGuardianMode = false,
    this.branchId,
    this.currentUserRole,
  });

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen>
    with SingleTickerProviderStateMixin {
  List<Map<String, dynamic>> _branches = [];
  TabController? _tabController;

  String? _filterStatus;
  String _searchQuery = '';
  String? _roleFilter;
  String? _genderFilter;
  String? _ageFilter;
  bool _familyView = false;
  String _selectedCategoryFilter = 'all';
  Box? _localBox;
  bool _filtersExpanded = false;
  final Set<String> _syncedBranches = {};

  @override
  void initState() {
    super.initState();
    _initAndLoad();
  }

  Future<void> _initAndLoad() async {
    await _initHive();
    await _loadBranches();
  }

  Future<void> _initHive() async => _localBox = await Hive.openBox('local');

  Future<void> _loadBranches() async {
    // 1. Instant load from local cache if available
    try {
      if (_localBox != null && _localBox!.containsKey('cached_branches_list')) {
        final cached = _localBox!.get('cached_branches_list');
        if (cached is List && cached.isNotEmpty) {
          final list = cached.map((e) => Map<String, dynamic>.from(e as Map)).toList();
          if (mounted && _branches.isEmpty) {
            setState(() {
              _branches = list;
              _tabController = TabController(length: list.length, vsync: this);
            });
          }
        }
      }
    } catch (_) {}

    // 2. Fetch fresh branches in background
    try {
      final snap = await FirebaseFirestore.instance.collection('branches').get();

      var branches = snap.docs.where((d) {
        final idLower = d.id.toLowerCase().trim();
        final nameLower = (d.data()['name'] as String? ?? '').toLowerCase().trim();
        return idLower != 'all' && idLower != 'global' && nameLower != 'all' && nameLower != 'global';
      }).map((d) {
        final data = d.data();
        return {'id': d.id, 'name': data['name'] as String? ?? d.id};
      }).toList();

      final roleLower = (widget.currentUserRole ?? '').toLowerCase().trim();
      final userBranch = (widget.branchId ?? '').toLowerCase().trim();
      final isGlobalExec = ['chairman', 'ceo', 'admin', 'administrator', 'super admin', 'global admin', 'hq manager', 'president', 'founder'].contains(roleLower) && (userBranch == 'all' || userBranch == 'global' || userBranch.isEmpty);

      if (!isGlobalExec && userBranch.isNotEmpty && userBranch != 'all' && userBranch != 'global' && userBranch != 'unknown') {
        branches = branches.where((b) {
          final bId = (b['id'] as String).toLowerCase().trim();
          return bId == userBranch || bId.contains(userBranch) || userBranch.contains(bId);
        }).toList();
      }

      branches.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));

      // Cache branches locally
      try {
        _localBox?.put('cached_branches_list', branches);
      } catch (_) {}

      if (mounted) {
        final oldLen = _tabController?.length ?? 0;
        if (oldLen != branches.length) {
          _tabController?.dispose();
          _tabController = TabController(length: branches.length, vsync: this);
        }
        setState(() {
          _branches = branches;
        });
      }
    } catch (e) {
      if (mounted && _branches.isEmpty) {
        // Fallback default branch if completely offline with no cache
        final fallbackBranch = widget.branchId ?? 'main';
        setState(() {
          _branches = [{'id': fallbackBranch, 'name': fallbackBranch.toUpperCase()}];
          _tabController = TabController(length: 1, vsync: this);
        });
      }
    }
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);

    if (_branches.isEmpty || _tabController == null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        CircularProgressIndicator(color: t.accent),
        const SizedBox(height: 16),
        Text('Loading branches…', style: TextStyle(color: t.textSecondary, fontSize: 14)),
      ]));
    }

    final isWrapped = GlobalModuleWrapper.isWrapped(context);

    return Scaffold(
      backgroundColor: t.bg,
      appBar: isWrapped
          ? null
          : AppBar(
              backgroundColor: t.bgCard,
              elevation: 0,
              surfaceTintColor: Colors.transparent,
              leading: AppBackButton(color: t.textPrimary),
              title: Text(
                widget.isPatientMode
                    ? 'Patients'
                    : (widget.isGuardianMode ? 'Guardians' : 'User Management'),
                style: TextStyle(
                  color: t.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5,
                ),
              ),
              actions: [
                if (!widget.isPatientMode && !widget.isGuardianMode) ...[
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.person_add_alt_1_rounded, size: 16),
                      label: const Text('Register User', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: t.accent,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const Register()),
                      ),
                    ),
                  ),
                ],
              ],
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(1),
                child: Divider(height: 1, color: t.bgRule),
              ),
            ),
      body: Column(children: [
        // ── Tab bar ──
        if (_branches.length > 1)
          Container(
            color: t.bgCard,
            child: TabBar(
              controller: _tabController!,
              isScrollable: true,
              labelColor: t.accent,
              unselectedLabelColor: t.textTertiary,
              labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
              unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
              indicator: UnderlineTabIndicator(
                borderSide: BorderSide(color: t.accent, width: 3),
                insets: const EdgeInsets.symmetric(horizontal: 12),
              ),
              tabAlignment: TabAlignment.start,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              tabs: _branches.map((b) => Tab(
                child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(b['name'] as String)),
              )).toList(),
            ),
          ),

        // ── Filter bar ──
        _buildFilterBar(t),

        // ── Content ──
        Expanded(
          child: TabBarView(
            controller: _tabController!,
            children: _branches.map((b) => _buildList(b['id'] as String, t)).toList(),
          ),
        ),
      ]),
    );
  }

  Future<void> _refreshData([String? branchId]) async {
    final bId = branchId ?? (_tabController != null && _branches.isNotEmpty ? _branches[_tabController!.index]['id'] as String : (widget.branchId ?? 'all'));
    try {
      if (widget.isPatientMode) {
        await _syncPatientsForBranch(bId);
      } else {
        final snap = await _loadUsersSnapshot(bId);
        if (Hive.isBoxOpen('local_users')) {
          final box = Hive.box('local_users');
          for (final doc in snap.docs) {
            final Map<String, dynamic> u = {'id': doc.id, ...doc.data() as Map<String, dynamic>};
            final cacheKey = u['email'] != null && (u['email'] as String).isNotEmpty
                ? 'user:${(u['email'] as String).toLowerCase().trim()}'
                : 'user:${doc.id}';
            await box.put(cacheKey, u);
          }
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Records refreshed successfully'), duration: Duration(seconds: 2)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Refresh failed: $e'), duration: const Duration(seconds: 2)),
        );
      }
    }
  }

  Widget _buildFilterBar(RoleThemeData t) {
    return Container(
      color: t.bgCard,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(children: [
        Row(children: [
          Expanded(
            child: Container(
              height: 42,
              decoration: BoxDecoration(
                color: t.bg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: t.bgRule),
              ),
              child: TextField(
                onChanged: (v) => setState(() => _searchQuery = v.trim().toLowerCase()),
                style: TextStyle(fontSize: 14, color: t.textPrimary),
                decoration: InputDecoration(
                  hintText: widget.isPatientMode
                      ? 'Search records…'
                      : (widget.isGuardianMode ? 'Search by username/email…' : 'Search by username…'),
                  hintStyle: TextStyle(color: t.textTertiary, fontSize: 13),
                  prefixIcon: Icon(Icons.search_rounded, color: t.accent, size: 18),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(Icons.refresh_rounded, color: t.accent),
            tooltip: 'Refresh Records',
            onPressed: () => _refreshData(),
          ),
          if (!widget.isGuardianMode) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => setState(() => _filtersExpanded = !_filtersExpanded),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                height: 42,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: _filtersExpanded ? t.accent : t.bg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _filtersExpanded ? t.accent : t.bgRule),
                ),
                child: Row(children: [
                  Icon(Icons.tune_rounded, color: _filtersExpanded ? Colors.white : t.textSecondary, size: 18),
                  const SizedBox(width: 5),
                  Text('Filters', style: TextStyle(
                      color: _filtersExpanded ? Colors.white : t.textSecondary,
                      fontSize: 13, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          ],
          if (!widget.isGuardianMode && !widget.isPatientMode && _isChairmanActor()) ...[
            const SizedBox(width: 8),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0F5132),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                elevation: 0,
              ),
              icon: const Icon(Icons.admin_panel_settings_rounded, size: 18),
              label: const Text('Access Control Matrix', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              onPressed: () => _openAccessControlMatrixSheet(context, t),
            ),
          ],
        ]),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 250),
          crossFadeState: _filtersExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          firstChild: const SizedBox.shrink(),
          secondChild: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: widget.isPatientMode ? _buildPatientFilters(t) : _buildStaffFilters(t),
          ),
        ),
      ]),
    );
  }

  Widget _buildPatientFilters(RoleThemeData t) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Status chips
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          _chip(t, 'All Status', _filterStatus == null, () => setState(() => _filterStatus = null)),
          const SizedBox(width: 6),
          _chip(t, 'Zakat', _filterStatus == 'Zakat', () => setState(() => _filterStatus = _filterStatus == 'Zakat' ? null : 'Zakat')),
          const SizedBox(width: 6),
          _chip(t, 'Non-Zakat', _filterStatus == 'Non-Zakat', () => setState(() => _filterStatus = _filterStatus == 'Non-Zakat' ? null : 'Non-Zakat')),
          const SizedBox(width: 6),
          _chip(t, 'GMWF', _filterStatus == 'GMWF', () => setState(() => _filterStatus = _filterStatus == 'GMWF' ? null : 'GMWF')),
        ]),
      ),
      const SizedBox(height: 8),
      // Gender + Age + Family in one scrollable row
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          _chip(t, 'All Gender', _genderFilter == null, () => setState(() => _genderFilter = null)),
          const SizedBox(width: 6),
          _chip(t, 'Male', _genderFilter == 'Male', () => setState(() => _genderFilter = _genderFilter == 'Male' ? null : 'Male')),
          const SizedBox(width: 6),
          _chip(t, 'Female', _genderFilter == 'Female', () => setState(() => _genderFilter = _genderFilter == 'Female' ? null : 'Female')),
          const SizedBox(width: 12),
          _chip(t, '0–18', _ageFilter == 'child', () => setState(() => _ageFilter = _ageFilter == 'child' ? null : 'child')),
          const SizedBox(width: 6),
          _chip(t, '19–60', _ageFilter == 'adult', () => setState(() => _ageFilter = _ageFilter == 'adult' ? null : 'adult')),
          const SizedBox(width: 6),
          _chip(t, '61+', _ageFilter == 'senior', () => setState(() => _ageFilter = _ageFilter == 'senior' ? null : 'senior')),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: () => setState(() => _familyView = !_familyView),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: _familyView ? t.accent : t.bg,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _familyView ? t.accent : t.bgRule),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.family_restroom_rounded, color: _familyView ? Colors.white : t.textSecondary, size: 14),
                const SizedBox(width: 5),
                Text('Family', style: TextStyle(color: _familyView ? Colors.white : t.textSecondary,
                    fontSize: 12, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
        ]),
      ),
    ]);
  }

  Widget _buildStaffFilters(RoleThemeData t) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        _chip(t, 'All Roles', _roleFilter == null, () => setState(() => _roleFilter = null)),
        const SizedBox(width: 6),
        ...{
          'doctor': 'Doctor', 'receptionist': 'Receptionist',
          'dispenser': 'Dispenser', 'supervisor': 'Supervisor',
          'food token generator': 'Food Token', 'kitchen': 'Kitchen',
        }.entries.map((e) => Padding(
          padding: const EdgeInsets.only(left: 6),
          child: _chip(t, e.value, _roleFilter == e.key,
              () => setState(() => _roleFilter = _roleFilter == e.key ? null : e.key)),
        )),
      ]),
    );
  }

  Widget _chip(RoleThemeData t, String label, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: active ? t.accent : t.bg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: active ? t.accent : t.bgRule),
        ),
        child: Text(label, style: TextStyle(
            color: active ? Colors.white : t.textSecondary,
            fontSize: 12, fontWeight: FontWeight.w600)),
      ),
    );
  }

  // ── List ──

  Future<void> _syncPatientsForBranch(String branchId) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('branches')
          .doc(branchId)
          .collection('patients')
          .get();
      final List<Map<String, dynamic>> patientsToSave = [];
      for (final doc in snap.docs) {
        final d = doc.data();
        d['patientId'] = doc.id;
        d['branchId'] = branchId;
        patientsToSave.add(d);
      }
      await LocalStorageService.saveAllLocalPatients(patientsToSave);
    } catch (e) {
      debugPrint('Sync patients failed for branch $branchId: $e');
    }
  }

  Widget _buildList(String branchId, RoleThemeData t) {
    if (widget.isPatientMode) {
      // Sync in background only once per branch per screen lifecycle
      if (!_syncedBranches.contains(branchId)) {
        _syncedBranches.add(branchId);
        _syncPatientsForBranch(branchId);
      }
      return ValueListenableBuilder<Box>(
        valueListenable: Hive.box(LocalStorageService.patientsBox).listenable(),
        builder: (context, box, _) {
          final allLocal = LocalStorageService.getAllLocalPatients(branchId: branchId);
          var filtered = allLocal.where((p) {
            if (_filterStatus != null && p['status']?.toString().toLowerCase() != _filterStatus!.toLowerCase()) {
              return false;
            }
            if (_genderFilter != null && p['gender']?.toString().toLowerCase() != _genderFilter!.toLowerCase()) {
              return false;
            }
            if (_ageFilter != null) {
              final age = (p['age'] as num?)?.toInt() ?? 0;
              if (_ageFilter == 'child' && age > 18) return false;
              if (_ageFilter == 'adult' && (age < 19 || age > 60)) return false;
              if (_ageFilter == 'senior' && age < 61) return false;
            }
            if (_searchQuery.isNotEmpty) {
              final name = (p['name'] as String?)?.toLowerCase() ?? '';
              final phone = (p['phone'] as String?)?.toLowerCase() ?? '';
              final cnic = (p['cnic'] as String?)?.toLowerCase() ?? '';
              final gcnic = (p['guardianCnic'] as String?)?.toLowerCase() ?? '';
              final uid = (p['patientId'] as String?)?.toLowerCase() ?? '';
              return name.contains(_searchQuery) || phone.contains(_searchQuery) ||
                  cnic.contains(_searchQuery) || gcnic.contains(_searchQuery) || uid.contains(_searchQuery);
            }
            return true;
          }).toList();

          filtered.sort((a, b) => (a['name'] as String? ?? '').compareTo(b['name'] as String? ?? ''));

          if (filtered.isEmpty) {
            return _emptyState(t, Icons.person_search_rounded, 'No patients found', 'Try adjusting your search or filters');
          }

          return Column(children: [
            Container(
              color: t.accentMuted.withValues(alpha: 0.3),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: t.accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.people_rounded, color: t.accent, size: 14),
                    const SizedBox(width: 5),
                    Text('${filtered.length} Patients', style: TextStyle(color: t.accent, fontWeight: FontWeight.w700, fontSize: 12)),
                  ]),
                ),
              ]),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () => _refreshData(branchId),
                child: _familyView
                    ? _buildFamilyView(filtered, branchId, t)
                    : ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                        padding: const EdgeInsets.fromLTRB(10, 8, 10, 24),
                        itemCount: filtered.length,
                        itemBuilder: (ctx, i) => _buildCard(filtered[i], branchId, t),
                      ),
              ),
            ),
          ]);
        },
      );
    }

    // Staff path (Local-first + Hive reactive updates)
    return ValueListenableBuilder<Box>(
      valueListenable: Hive.box('local_users').listenable(),
      builder: (context, box, _) {
        if (box.isEmpty && !_syncedBranches.contains('users_$branchId')) {
          _syncedBranches.add('users_$branchId');
          _loadUsersSnapshot(branchId).then((snap) {
            for (final doc in snap.docs) {
              final Map<String, dynamic> u = {'id': doc.id, ...doc.data() as Map<String, dynamic>};
              final cacheKey = u['email'] != null && (u['email'] as String).isNotEmpty
                  ? 'user:${(u['email'] as String).toLowerCase().trim()}'
                  : 'user:${doc.id}';
              box.put(cacheKey, u);
            }
          }).catchError((_) {});
        }

        final Map<String, Map<String, dynamic>> mergedMap = {};

        String getDedupKey(Map<String, dynamic> u, String defaultId) {
          final usernameLower = (u['usernameLower'] ?? u['username'])?.toString().trim().toLowerCase() ?? '';
          if (!widget.isPatientMode && usernameLower.isNotEmpty) {
            return 'user:$usernameLower';
          }
          final email = u['email']?.toString().trim().toLowerCase() ?? '';
          if (!widget.isPatientMode && email.isNotEmpty) {
            return 'email:$email';
          }
          final uid = (u['uid'] ?? u['id'] ?? u['patientId'] ?? defaultId).toString();
          return 'id:$uid';
        }

        for (final val in box.values) {
          if (val is Map) {
            final Map<String, dynamic> u = Map<String, dynamic>.from(val);
            final uid = u['uid']?.toString() ?? u['id']?.toString() ?? '';
            if (uid.isNotEmpty) {
              mergedMap[getDedupKey(u, uid)] = u;
            }
          }
        }

        var list = mergedMap.values.toList();

        if (branchId != 'all' && branchId != 'global') {
          final targetBranch = branchId.trim().toLowerCase();
          list = list.where((item) {
            final uBranch = (item['branchId'] ?? item['branch'] ?? '').toString().trim().toLowerCase();
            final uRole = (item['role'] ?? '').toString().trim().toLowerCase();

            // System & executive roles are ALWAYS visible across all branch views
            final isGlobalRole = uRole == 'chairman' ||
                uRole == 'global admin' ||
                uRole == 'admin' ||
                uRole == 'ceo' ||
                uRole == 'global accounts' ||
                uRole == 'hq manager';

            if (isGlobalRole || uBranch.isEmpty || uBranch == 'all' || uBranch == 'global') {
              return true;
            }
            return uBranch == targetBranch;
          }).toList();
        }

        if (_searchQuery.isNotEmpty) {
          list = list.where((item) {
            final username = (item['username'] as String?)?.toLowerCase() ?? '';
            final name = (item['name'] as String?)?.toLowerCase() ?? '';
            final email = (item['email'] as String?)?.toLowerCase() ?? '';
            return username.contains(_searchQuery) || name.contains(_searchQuery) || email.contains(_searchQuery);
          }).toList();
        }

        if (widget.isGuardianMode) {
          list = list.where((item) => (item['role'] as String? ?? '').toLowerCase() == 'madrassa parent').toList();
        } else {
          list = list.where((item) => (item['role'] as String? ?? '').toLowerCase() != 'madrassa parent').toList();
        }

        if (!widget.isGuardianMode && _roleFilter != null) {
          final target = _roleFilter!.toLowerCase();
          list = list.where((item) {
            final role = (item['role'] as String? ?? '').toLowerCase();
            if (target == 'dispenser') {
              return role.contains('dis') || role.contains('dispens');
            } else if (target == 'doctor') {
              return role.contains('doc');
            } else if (target == 'receptionist') {
              return role.contains('rec');
            } else if (target == 'supervisor') {
              return role.contains('sup') || role.contains('manag');
            }
            return role == target;
          }).toList();
        }

        list.sort((a, b) {
          final roleA = (a['role'] as String? ?? '').toLowerCase().trim();
          final roleB = (b['role'] as String? ?? '').toLowerCase().trim();
          final isChairmanA = roleA == 'chairman';
          final isChairmanB = roleB == 'chairman';

          if (isChairmanA && !isChairmanB) return -1;
          if (!isChairmanA && isChairmanB) return 1;

          final nameA = (a['name'] ?? a['username'] ?? '').toString().toLowerCase();
          final nameB = (b['name'] ?? b['username'] ?? '').toString().toLowerCase();
          return nameA.compareTo(nameB);
        });

        bool isUserOnline(Map<String, dynamic> data) =>
            DeviceInfoService.isUserOnline(data, thresholdMinutes: 5);

        String getDepartment(Map<String, dynamic> u) {
          final role = (u['role'] as String? ?? '').toLowerCase().trim();
          final dept = (u['department'] as String? ?? '').toLowerCase().trim();

          if (role.contains('school') || dept.contains('school')) {
            if (role.contains('guardian') || role.contains('parent')) {
              return 'school_guardian';
            }
            return 'school_faculty';
          }
          if (role == 'madrassa parent' || role == 'madrassa guardian' || role.contains('madrassa')) {
            if (role.contains('guardian') || role.contains('parent')) {
              return 'madrassa_guardian';
            }
            return 'madrassa_faculty';
          }
          if (role.contains('doc') || role.contains('dis') || role.contains('rec') || role.contains('nurse') || role.contains('sup') || role.contains('supervisor') || dept.contains('dispensary') || dept.contains('health')) {
            return 'dispensary';
          }
          if (role.contains('kitchen') || role.contains('cook') || role.contains('food') || role.contains('token') || role.contains('daster') || dept.contains('kitchen') || dept.contains('daster')) {
            return 'kitchen';
          }
          return 'office';
        }

        final onlineList = <Map<String, dynamic>>[];
        final officeList = <Map<String, dynamic>>[];
        final kitchenList = <Map<String, dynamic>>[];
        final dispensaryList = <Map<String, dynamic>>[];
        final madrassaFacultyList = <Map<String, dynamic>>[];
        final madrassaGuardianList = <Map<String, dynamic>>[];
        final schoolFacultyList = <Map<String, dynamic>>[];
        final schoolGuardianList = <Map<String, dynamic>>[];
        final revokedList = <Map<String, dynamic>>[];

        for (final item in list) {
          final status = (item['status'] ?? item['accountStatus'] ?? item['studentStatus'] ?? 'active').toString().toLowerCase().trim();
          final isPendingRestore = (item['restoreRequestStatus'] ?? '').toString().toLowerCase().trim() == 'pending' ||
              item['restoreRequested'] == true;
          final isOffboardedOrArchived = (
              status == 'inactive' ||
              status == 'suspended' ||
              status == 'terminated' ||
              status == 'resigned' ||
              status == 'retired' ||
              status == 'offboarded' ||
              status == 'revoked' ||
              status == 'archived' ||
              status == 'hifz_completed' ||
              status == 'hifz completed' ||
              status == 'left' ||
              status == 'dropped' ||
              status == 'dropped_out' ||
              item['isActive'] == false ||
              item['isRevoked'] == true ||
              item['accessRevoked'] == true ||
              isPendingRestore
          );

          if (isOffboardedOrArchived) {
            revokedList.add(item);
          } else if (isUserOnline(item)) {
            onlineList.add(item);
          } else {
            final dept = getDepartment(item);
            if (dept == 'school_faculty') {
              schoolFacultyList.add(item);
            } else if (dept == 'school_guardian') {
              schoolGuardianList.add(item);
            } else if (dept == 'madrassa_faculty') {
              madrassaFacultyList.add(item);
            } else if (dept == 'madrassa_guardian') {
              madrassaGuardianList.add(item);
            } else if (dept == 'dispensary') {
              dispensaryList.add(item);
            } else if (dept == 'kitchen') {
              kitchenList.add(item);
            } else {
              officeList.add(item);
            }
          }
        }

        // Also include offboarded HR employees from local_employees box so HQ Manager sees both in User Management
        try {
          if (!widget.isGuardianMode && Hive.isBoxOpen(LocalStorageService.employeesBox)) {
            final empBox = Hive.box(LocalStorageService.employeesBox);
            for (final val in empBox.values) {
              if (val is! Map) continue;
              final emp = Map<String, dynamic>.from(val);
              final empBranch = (emp['branchId'] ?? '').toString().trim().toLowerCase();
              if (branchId != 'all' && branchId != 'global' && empBranch.isNotEmpty && empBranch != branchId.trim().toLowerCase()) {
                continue;
              }
              final isActive = emp['isActive'] as bool? ?? true;
              final empStatus = (emp['status'] ?? emp['employeeStatus'] ?? '').toString().trim().toLowerCase();
              final isEmpOffboarded = !isActive ||
                  empStatus == 'inactive' ||
                  empStatus == 'offboarded' ||
                  empStatus == 'terminated' ||
                  empStatus == 'resigned' ||
                  empStatus == 'left' ||
                  empStatus.contains('offboard');

              if (isEmpOffboarded) {
                final empId = emp['localId'] ?? emp['id'] ?? '';
                final cleanCnic = (emp['cnic'] ?? '').toString().replaceAll(RegExp(r'\D'), '');
                final alreadyPresent = revokedList.any((r) {
                  final rEmpId = (r['linkedEmployeeId'] ?? '').toString();
                  final rCnic = (r['cnic'] ?? '').toString().replaceAll(RegExp(r'\D'), '');
                  return (empId.toString().isNotEmpty && rEmpId == empId.toString()) ||
                      (cleanCnic.isNotEmpty && rCnic == cleanCnic);
                });
                if (!alreadyPresent) {
                  final empItem = Map<String, dynamic>.from(emp);
                  empItem['isEmployeeRecord'] = true;
                  empItem['status'] = 'offboarded';
                  empItem['role'] = emp['designation'] ?? emp['role'] ?? 'Employee';
                  revokedList.add(empItem);
                }
              }
            }
          }
        } catch (_) {}

        if (list.isEmpty && revokedList.isEmpty) {
          return _emptyState(t, widget.isGuardianMode ? Icons.people_outline : Icons.manage_accounts_rounded, widget.isGuardianMode ? 'No guardians found' : 'No users found', 'Try adjusting your search query');
        }

        final listItems = <Widget>[];

        // Check for pending restore requests
        final pendingRestoreList = revokedList.where((u) {
          final s = (u['restoreRequestStatus'] ?? '').toString().toLowerCase().trim();
          return s == 'pending' || u['restoreRequested'] == true;
        }).toList();

        if (pendingRestoreList.isNotEmpty) {
          listItems.add(_buildPendingRequestsBanner(pendingRestoreList, branchId, t));
        }

        void addCategorySection(String title, int count, IconData icon, Color color, List<Map<String, dynamic>> items) {
          if (items.isEmpty) return;
          listItems.add(_buildCategoryHeader(t, title, count, icon, color));
          for (final item in items) {
            listItems.add(_buildCard(item, branchId, t));
          }
        }

        if (_selectedCategoryFilter == 'online') {
          addCategorySection('Currently Online', onlineList.length, Icons.fiber_manual_record, Colors.green, onlineList);
        } else if (_selectedCategoryFilter == 'office') {
          addCategorySection('Office & Administration', officeList.length, Icons.business_center_rounded, Colors.indigo, officeList);
        } else if (_selectedCategoryFilter == 'kitchen') {
          addCategorySection('Dasterkhawaan & Kitchen', kitchenList.length, Icons.soup_kitchen_rounded, Colors.amber.shade800, kitchenList);
        } else if (_selectedCategoryFilter == 'dispensary') {
          addCategorySection('Dispensary Department', dispensaryList.length, Icons.local_hospital_rounded, Colors.blue, dispensaryList);
        } else if (_selectedCategoryFilter == 'madrassa_faculty') {
          addCategorySection('Madrassa Faculty', madrassaFacultyList.length, Icons.school_rounded, Colors.teal, madrassaFacultyList);
        } else if (_selectedCategoryFilter == 'madrassa_guardian') {
          addCategorySection('Madrassa Guardians', madrassaGuardianList.length, Icons.family_restroom_rounded, Colors.orange, madrassaGuardianList);
        } else if (_selectedCategoryFilter == 'school_faculty') {
          addCategorySection('School Faculty', schoolFacultyList.length, Icons.account_balance_rounded, Colors.deepPurple, schoolFacultyList);
        } else if (_selectedCategoryFilter == 'school_guardian') {
          addCategorySection('School Guardians', schoolGuardianList.length, Icons.family_restroom_rounded, Colors.purpleAccent, schoolGuardianList);
        } else if (_selectedCategoryFilter == 'revoked') {
          addCategorySection('Revoked Users & Offboarded Employees', revokedList.length, Icons.no_accounts_rounded, Colors.red, revokedList);
        } else {
          addCategorySection('Currently Online', onlineList.length, Icons.fiber_manual_record, Colors.green, onlineList);
          addCategorySection('Office & Administration', officeList.length, Icons.business_center_rounded, Colors.indigo, officeList);
          addCategorySection('Dasterkhawaan & Kitchen', kitchenList.length, Icons.soup_kitchen_rounded, Colors.amber.shade800, kitchenList);
          addCategorySection('Dispensary Department', dispensaryList.length, Icons.local_hospital_rounded, Colors.blue, dispensaryList);
          if (madrassaFacultyList.isNotEmpty) addCategorySection('Madrassa Faculty', madrassaFacultyList.length, Icons.school_rounded, Colors.teal, madrassaFacultyList);
          if (madrassaGuardianList.isNotEmpty) addCategorySection('Madrassa Guardians', madrassaGuardianList.length, Icons.family_restroom_rounded, Colors.orange, madrassaGuardianList);
          if (schoolFacultyList.isNotEmpty) addCategorySection('School Faculty', schoolFacultyList.length, Icons.account_balance_rounded, Colors.deepPurple, schoolFacultyList);
          if (schoolGuardianList.isNotEmpty) addCategorySection('School Guardians', schoolGuardianList.length, Icons.family_restroom_rounded, Colors.purpleAccent, schoolGuardianList);
          addCategorySection('Revoked Users & Offboarded Employees', revokedList.length, Icons.no_accounts_rounded, Colors.red, revokedList);
        }

        return Column(children: [
          Container(
            color: t.bgCard,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _categoryChip(t, 'All (${list.length})', 'all', Icons.grid_view_rounded, t.accent),
                  const SizedBox(width: 6),
                  _categoryChip(t, 'Online (${onlineList.length})', 'online', Icons.fiber_manual_record, Colors.green),
                  const SizedBox(width: 6),
                  _categoryChip(t, 'Office (${officeList.length})', 'office', Icons.business_center_rounded, Colors.indigo),
                  const SizedBox(width: 6),
                  _categoryChip(t, 'Dasterkhawaan (${kitchenList.length})', 'kitchen', Icons.soup_kitchen_rounded, Colors.amber.shade800),
                  const SizedBox(width: 6),
                  _categoryChip(t, 'Dispensary (${dispensaryList.length})', 'dispensary', Icons.local_hospital_rounded, Colors.blue),
                  const SizedBox(width: 6),
                  // Madrassa faculty and guardians
                  if (madrassaFacultyList.isNotEmpty) ...[
                    _categoryChip(t, 'Madrassa Faculty (${madrassaFacultyList.length})', 'madrassa_faculty', Icons.school_rounded, Colors.teal),
                    const SizedBox(width: 6),
                  ],
                  if (madrassaGuardianList.isNotEmpty) ...[
                    _categoryChip(t, 'Madrassa Guardians (${madrassaGuardianList.length})', 'madrassa_guardian', Icons.family_restroom_rounded, Colors.orange),
                    const SizedBox(width: 6),
                  ],
                  // School faculty and guardians
                  if (schoolFacultyList.isNotEmpty) ...[
                    _categoryChip(t, 'School Faculty (${schoolFacultyList.length})', 'school_faculty', Icons.account_balance_rounded, Colors.deepPurple),
                    const SizedBox(width: 6),
                  ],
                  if (schoolGuardianList.isNotEmpty) ...[
                    _categoryChip(t, 'School Guardians (${schoolGuardianList.length})', 'school_guardian', Icons.family_restroom_rounded, Colors.purpleAccent),
                    const SizedBox(width: 6),
                  ],
                  _categoryChip(t, 'Revoked & Offboarded (${revokedList.length})', 'revoked', Icons.no_accounts_rounded, Colors.red),
                ],
              ),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _refreshData(branchId),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                padding: const EdgeInsets.fromLTRB(10, 4, 10, 24),
                children: listItems,
              ),
            ),
          ),
        ]);
      },
    );
  }

  Color _getStatusColor(String rawStatus) {
    final s = rawStatus.toLowerCase().trim();
    if (s == 'hifz_completed' || s == 'hifz completed') return const Color(0xFF4C4DDC);
    if (s == 'left') return Colors.redAccent;
    if (s == 'dropped' || s == 'dropped out' || s == 'dropped_out') return Colors.red;
    if (s == 'archived') return Colors.orange;
    if (s == 'active') return Colors.green;
    return Colors.red;
  }

  bool _isUserOnline(Map<String, dynamic> data) =>
      DeviceInfoService.isUserOnline(data, thresholdMinutes: 5);

  Widget _categoryChip(RoleThemeData t, String label, String catKey, IconData icon, Color color) {
    final active = _selectedCategoryFilter == catKey;
    return GestureDetector(
      onTap: () => setState(() => _selectedCategoryFilter = catKey),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active ? color : color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: active ? color : color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: active ? Colors.white : color, size: 13),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: active ? Colors.white : color,
                fontSize: 11.5,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryHeader(RoleThemeData t, String title, int count, IconData icon, Color color) {
    return Container(
      margin: const EdgeInsets.only(top: 14, bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 13,
              color: color,
            ),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$count',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(Map<String, dynamic> data, String branchId, RoleThemeData t) {
    final itemId = (data['uid'] ?? data['id'] ?? data['docId'] ?? data['patientId'] ?? '').toString();
    final profilePicUrl = data['profilePictureUrl'] as String?;
    final name = widget.isPatientMode
        ? (data['name'] ?? 'Unknown').toString()
        : resolveUserDisplayName(data, fallback: 'Unknown');
    final subtitle = widget.isPatientMode
        ? '${data['gender'] ?? 'N/A'} · ${data['age']?.toString() ?? '?'} yrs · ${data['status'] ?? ''}'
        : ((data['role'] as String? ?? 'N/A').toLowerCase() == 'madrassa parent' ? 'GUARDIAN' : (data['role'] as String? ?? 'N/A').toUpperCase());

    final initials = name.trim().isEmpty ? '?' :
        name.trim().split(' ').map((w) => w[0]).take(2).join().toUpperCase();

    final gender = (data['gender'] ?? data['patientGender'] ?? '').toString().toLowerCase();
    final isFemale = gender == 'female';
    final isMale = gender == 'male';

    final rawRole = (data['role'] as String? ?? '').toLowerCase();
    final isGuardianRole = rawRole == 'madrassa parent' || rawRole == 'madrassa guardian';
    final isOnline = _isUserOnline(data);
    final status = (data['status'] ?? data['accountStatus'] ?? 'active').toString().toLowerCase().trim();
    final isPendingRestore = (data['restoreRequestStatus'] ?? '').toString().toLowerCase().trim() == 'pending' ||
        data['restoreRequested'] == true;
    final isRevoked = status == 'inactive' ||
        status == 'suspended' ||
        status == 'terminated' ||
        status == 'resigned' ||
        status == 'retired' ||
        status == 'offboarded' ||
        status == 'revoked' ||
        data['isActive'] == false ||
        data['isRevoked'] == true ||
        data['accessRevoked'] == true ||
        isPendingRestore;

    final Map<String, dynamic>? devInfo = (data['lastDeviceInfo'] is Map)
        ? Map<String, dynamic>.from(data['lastDeviceInfo'] as Map)
        : ((data['deviceInfo'] is Map) ? Map<String, dynamic>.from(data['deviceInfo'] as Map) : null);

    final effectiveDevInfo = devInfo ?? (isOnline ? {
      'platform': 'Active Device',
      'browser': 'App/Web',
      'os': 'Online Session',
      'iconType': 'unknown',
      'isOnline': true,
    } : null);

    final isChairmanCard = rawRole == 'chairman';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        gradient: isChairmanCard
            ? const LinearGradient(
                colors: [Color(0xFF1E112A), Color(0xFF2A1706), Color(0xFF170F2A), Color(0xFF0F172A)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        color: isChairmanCard
            ? null
            : (isPendingRestore
                ? const Color(0xFFF59E0B).withValues(alpha: 0.08)
                : (isRevoked ? Colors.red.withValues(alpha: 0.05) : t.bgCard)),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isChairmanCard
              ? const Color(0xFFFBBF24)
              : (isPendingRestore
                  ? const Color(0xFFF59E0B).withValues(alpha: 0.5)
                  : (isRevoked ? Colors.red.withValues(alpha: 0.3) : t.bgRule)),
          width: isChairmanCard ? 2.0 : (isPendingRestore ? 1.2 : 0.8),
        ),
        boxShadow: [
          BoxShadow(
            color: isChairmanCard
                ? const Color(0xFFF59E0B).withValues(alpha: 0.45)
                : t.accent.withValues(alpha: 0.04),
            blurRadius: isChairmanCard ? 20 : 10,
            spreadRadius: isChairmanCard ? 1.5 : 0,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _openDetail(itemId, branchId),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              // Avatar with online badge and tap to enlarge photo
              GestureDetector(
                onTap: () => _showEnlargedPhotoDialog(context, name, profilePicUrl, (data['role'] ?? 'USER').toString(), t),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Tooltip(
                    message: 'Tap to enlarge profile photo',
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          width: 46, height: 46,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isChairmanCard
                                ? const Color(0xFF382207)
                                : (isFemale ? const Color(0xFFFCE7F3) : (isMale ? const Color(0xFFE0F2FE) : t.accentMuted)),
                            border: isChairmanCard ? Border.all(color: const Color(0xFFFBBF24), width: 2) : null,
                            image: profilePicUrl != null && profilePicUrl.trim().isNotEmpty
                                ? DecorationImage(
                                    image: (ImageUploadService.decodeBase64ToBytes(profilePicUrl) != null
                                        ? MemoryImage(ImageUploadService.decodeBase64ToBytes(profilePicUrl)!)
                                        : NetworkImage(profilePicUrl) as ImageProvider),
                                    fit: BoxFit.cover,
                                  )
                                : null,
                            boxShadow: [
                              BoxShadow(
                                color: isChairmanCard ? const Color(0xFFF59E0B).withValues(alpha: 0.35) : t.accent.withValues(alpha: 0.1),
                                blurRadius: isChairmanCard ? 8 : 4,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          alignment: Alignment.center,
                          child: (profilePicUrl == null || profilePicUrl.trim().isEmpty)
                              ? (isChairmanCard
                                  ? Text(initials, style: const TextStyle(color: Color(0xFFFBBF24), fontWeight: FontWeight.w900, fontSize: 15))
                                  : (isFemale
                                      ? const Icon(Icons.face_3_rounded, size: 24, color: Color(0xFFDB2777))
                                      : (isMale
                                          ? const Icon(Icons.face_6_rounded, size: 24, color: Color(0xFF0284C7))
                                          : Text(initials, style: TextStyle(color: t.accent, fontWeight: FontWeight.w900, fontSize: 15)))))
                              : null,
                        ),
                        if (isOnline)
                          Positioned(
                            right: -1,
                            bottom: -1,
                            child: Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                color: Colors.green,
                                shape: BoxShape.circle,
                                border: Border.all(color: isChairmanCard ? const Color(0xFF1E112A) : t.bgCard, width: 2),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              // Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w900,
                              color: isChairmanCard ? const Color(0xFFFFFBEB) : (isRevoked ? Colors.red.shade900 : t.textPrimary),
                              decoration: isRevoked ? TextDecoration.lineThrough : null,
                              height: 1.2,
                              letterSpacing: isChairmanCard ? 0.3 : 0,
                            ),
                            maxLines: 2,
                            softWrap: true,
                          ),
                        ),
                        if (isOnline) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.green.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.green.withValues(alpha: 0.4), width: 0.6),
                            ),
                            child: const Text(
                              'ONLINE',
                              style: TextStyle(color: Color(0xFF4ADE80), fontSize: 9, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                        if (widget.isPatientMode) ...[
                          Builder(builder: (_) {
                            final staffInfo = StaffPatientLinkService.getStaffInfoForPatient(
                              cnic: data['cnic']?.toString() ?? data['guardianCnic']?.toString(),
                              name: name,
                            );
                            if (staffInfo != null) {
                              return Padding(
                                padding: const EdgeInsets.only(left: 6),
                                child: StaffPatientLinkService.buildStaffBadge(
                                  staffInfo,
                                  isDark: Theme.of(context).brightness == Brightness.dark,
                                ),
                              );
                            }
                            return const SizedBox.shrink();
                          }),
                        ],
                        if (isPendingRestore) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF59E0B).withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: const Color(0xFFF59E0B), width: 0.8),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.mark_email_unread_rounded, size: 10, color: Color(0xFFFBBF24)),
                                SizedBox(width: 4),
                                Text(
                                  'RESTORE REQUESTED',
                                  style: TextStyle(color: Color(0xFFFBBF24), fontSize: 9, fontWeight: FontWeight.w900),
                                ),
                              ],
                            ),
                          ),
                        ] else if (data['isEmployeeRecord'] == true) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.purple.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.purple.withValues(alpha: 0.4), width: 0.6),
                            ),
                            child: const Text(
                              'OFFBOARDED EMPLOYEE',
                              style: TextStyle(color: Colors.purpleAccent, fontSize: 9, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ] else if (isRevoked) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.red.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.red.withValues(alpha: 0.4), width: 0.6),
                            ),
                            child: const Text(
                              'REVOKED USER',
                              style: TextStyle(color: Colors.redAccent, fontSize: 9, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ] else if (status != 'active' && status.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: _getStatusColor(status).withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              status.replaceAll('_', ' ').toUpperCase(),
                              style: TextStyle(color: _getStatusColor(status), fontSize: 9, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    if (isChairmanCard)
                      Container(
                        margin: const EdgeInsets.only(top: 3),
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF92400E), Color(0xFF451A03)],
                          ),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: const Color(0xFFFCD34D), width: 0.8),
                          boxShadow: [
                            BoxShadow(color: const Color(0xFFF59E0B).withValues(alpha: 0.35), blurRadius: 6),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('👑 ', style: TextStyle(fontSize: 10)),
                            Text(
                              'CHAIRMAN · SUPREME SYSTEM AUTHORITY',
                              style: TextStyle(
                                color: const Color(0xFFFDE68A),
                                fontSize: 9.5,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.6,
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      Text(subtitle, style: TextStyle(fontSize: 11.5, color: t.textSecondary, fontWeight: FontWeight.w500),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (effectiveDevInfo != null) ...[
                      const SizedBox(height: 4),
                      DeviceBadgeWidget(
                        deviceInfo: effectiveDevInfo,
                        compact: true,
                      ),
                    ],
                  ],
                ),
              ),
              // Action buttons: Revoke/Allow Access, Edit, and Delete
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!widget.isPatientMode && _canManageUserAccess(data)) ...[
                    if (!isGuardianRole)
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        icon: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: isPendingRestore
                                ? const Color(0xFF10B981).withValues(alpha: 0.2)
                                : (isRevoked ? Colors.green.withValues(alpha: 0.12) : Colors.red.withValues(alpha: 0.12)),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isPendingRestore
                                  ? const Color(0xFF10B981)
                                  : (isRevoked ? Colors.green.shade700 : Colors.red.shade700),
                              width: 0.8,
                            ),
                          ),
                          child: Icon(
                            isPendingRestore
                                ? Icons.check_circle_rounded
                                : (isRevoked ? Icons.lock_open_rounded : Icons.lock_person_rounded),
                            size: 16,
                            color: isPendingRestore
                                ? const Color(0xFF10B981)
                                : (isRevoked ? Colors.green.shade400 : Colors.red.shade400),
                          ),
                        ),
                        tooltip: isPendingRestore
                            ? 'Allow Access (Restore Requested)'
                            : (isRevoked ? 'Allow / Restore App Access' : 'Revoke App Access'),
                        onPressed: () => _showQuickRevokeDialog(data, branchId, t),
                      )
                    else
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        icon: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.teal.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            Icons.school_rounded,
                            size: 16,
                            color: Colors.teal,
                          ),
                        ),
                        tooltip: 'Update Student / Guardian Status',
                        onPressed: () => _showGuardianStatusDialog(data, branchId, t),
                      ),
                    const SizedBox(width: 4),

                    // Medical History Button
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      icon: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.teal.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.teal, width: 0.8),
                        ),
                        child: const Icon(Icons.medical_services_outlined, size: 16, color: Colors.teal),
                      ),
                      tooltip: 'View Medical History',
                      onPressed: () => StaffPatientLinkService.openStaffMedicalHistory(
                        context,
                        name: name,
                        cnic: data['cnic']?.toString(),
                        branchId: branchId,
                        role: data['role']?.toString(),
                      ),
                    ),
                    const SizedBox(width: 4),

                    // Edit Profile Button
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      icon: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: t.accent.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: t.accent, width: 0.8),
                        ),
                        child: Icon(Icons.edit_rounded, size: 16, color: t.accent),
                      ),
                      tooltip: 'Edit Profile & Credentials',
                      onPressed: () => _openDetail(itemId, branchId),
                    ),
                    const SizedBox(width: 4),

                    // Delete Account Button
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      icon: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.red, width: 0.8),
                        ),
                        child: const Icon(Icons.delete_forever_rounded, size: 16, color: Colors.redAccent),
                      ),
                      tooltip: 'Delete Account Permanently',
                      onPressed: () => _showQuickDeleteUserDialog(data, branchId, t),
                    ),
                  ] else
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      icon: Icon(Icons.chevron_right_rounded, color: t.textSecondary, size: 20),
                      tooltip: 'View Profile',
                      onPressed: () => _openDetail(itemId, branchId),
                    ),
                ],
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _showGuardianStatusDialog(Map<String, dynamic> data, String branchId, RoleThemeData t) async {
    final itemId = (data['uid'] ?? data['id'] ?? data['docId'] ?? '').toString();
    final currentStatus = (data['status'] ?? data['studentStatus'] ?? 'active').toString().toLowerCase().trim();

    String selectedStatus = currentStatus;
    final reasonCtrl = TextEditingController();

    final statusOptions = [
      {'key': 'active', 'label': 'Active Student / Guardian', 'color': Colors.green, 'icon': Icons.check_circle_rounded},
      {'key': 'hifz_completed', 'label': 'Hifz Completed', 'color': const Color(0xFF4C4DDC), 'icon': Icons.workspace_premium_rounded},
      {'key': 'left', 'label': 'Left Madrassa', 'color': Colors.redAccent, 'icon': Icons.exit_to_app_rounded},
      {'key': 'dropped', 'label': 'Dropped Out', 'color': Colors.red, 'icon': Icons.person_off_rounded},
      {'key': 'archived', 'label': 'Archived', 'color': Colors.orange, 'icon': Icons.archive_rounded},
    ];

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final currentOpt = statusOptions.firstWhere((o) => o['key'] == selectedStatus, orElse: () => statusOptions[0]);
          return Dialog(
            backgroundColor: t.bgCard,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: (currentOpt['color'] as Color).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(currentOpt['icon'] as IconData, color: currentOpt['color'] as Color, size: 24),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Madrassa Guardian Status',
                              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: t.textPrimary),
                            ),
                            Text(
                              'Update enrolment status for @${data['username'] ?? 'Guardian'}',
                              style: TextStyle(fontSize: 12, color: t.textTertiary),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Text('Select Student / Guardian Status', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: t.textSecondary)),
                  const SizedBox(height: 8),
                  ...statusOptions.map((opt) {
                    final isSelected = selectedStatus == opt['key'];
                    final optColor = opt['color'] as Color;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      decoration: BoxDecoration(
                        color: isSelected ? optColor.withValues(alpha: 0.1) : t.bg,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSelected ? optColor : t.bgRule,
                          width: isSelected ? 1.5 : 0.8,
                        ),
                      ),
                      child: ListTile(
                        dense: true,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        leading: Icon(opt['icon'] as IconData, color: optColor, size: 20),
                        title: Text(
                          opt['label'] as String,
                          style: TextStyle(
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                            color: isSelected ? optColor : t.textPrimary,
                            fontSize: 13.5,
                          ),
                        ),
                        trailing: isSelected ? Icon(Icons.check_circle_rounded, color: optColor, size: 18) : null,
                        onTap: () => setS(() => selectedStatus = opt['key'] as String),
                      ),
                    );
                  }),
                  const SizedBox(height: 12),
                  Text('Remarks / Reason (Optional)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: t.textSecondary)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: reasonCtrl,
                    style: TextStyle(fontSize: 13, color: t.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'e.g. Completed Hifz exam / Relocated to another city',
                      hintStyle: TextStyle(color: t.textTertiary, fontSize: 12),
                      filled: true,
                      fillColor: t.bg,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: Text('Cancel', style: TextStyle(color: t.textSecondary)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: currentOpt['color'] as Color,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: const Text('Update Status', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    if (confirm != true) return;

    final reason = reasonCtrl.text.trim();
    final isReadOnly = selectedStatus != 'active';

    final updates = <String, dynamic>{
      'status': selectedStatus,
      'studentStatus': selectedStatus,
      'accountStatus': selectedStatus,
      'isReadOnly': isReadOnly,
      'statusReason': reason.isNotEmpty ? reason : 'Status updated to $selectedStatus',
      'statusUpdatedAt': FieldValue.serverTimestamp(),
    };

    try {
      await LocalStorageService.saveUserOffline(
        uid: itemId,
        branchId: branchId,
        userData: {...data, ...updates, 'uid': itemId, 'branchId': branchId},
      );

      if (!itemId.startsWith('local-')) {
        await FirebaseFirestore.instance.collection('users').doc(itemId).set(updates, SetOptions(merge: true));
        if (branchId.isNotEmpty && branchId != 'all') {
          await FirebaseFirestore.instance.collection('branches').doc(branchId).collection('users').doc(itemId).set(updates, SetOptions(merge: true));
        }
      }

      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Guardian status updated to ${selectedStatus.replaceAll('_', ' ').toUpperCase()}'),
            backgroundColor: Colors.green.shade700,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update status: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _openDetail(String itemId, String branchId) {
    if (_localBox == null) return;
    String curRole = '';
    try {
      curRole = RoleThemeScope.dataOf(context).roleLabel;
    } catch (_) {}

    if (widget.isPatientMode) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => PatientDetailScreen(
        patientId: itemId, isOnline: true, localBox: _localBox!,
        branchId: branchId, doctorId: '', isAdmin: true,
      )));
    } else {
      final roleData = RoleThemeScope.of(context);
      Navigator.push(context, MaterialPageRoute(builder: (_) => RoleThemeScope(
        role: roleData,
        child: UserDetailScreen(
          userId: itemId, branchId: branchId, localBox: _localBox!, isOnline: true,
          currentUserRole: curRole,
        ),
      )));
    }
  }

  bool _isChairmanActor() {
    if (widget.currentUserRole != null && widget.currentUserRole!.toLowerCase().trim() == 'chairman') {
      return true;
    }
    try {
      final label = RoleThemeScope.dataOf(context).roleLabel.toLowerCase().trim();
      if (label == 'chairman') return true;
    } catch (_) {}

    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser != null) {
      final uid = currentUser.uid;
      final email = currentUser.email?.toLowerCase().trim();
      if (Hive.isBoxOpen(LocalStorageService.usersBox)) {
        final box = Hive.box(LocalStorageService.usersBox);
        final uDoc = box.get(uid) ?? box.get('user:$uid') ?? (email != null ? box.get('user:$email') : null);
        if (uDoc is Map) {
          final r = (uDoc['role'] ?? uDoc['type'] ?? uDoc['accountType'] ?? '').toString().toLowerCase().trim();
          if (r == 'chairman') return true;
        }
      }
    }

    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final r1 = (box.get('user_role') ?? box.get('role'))?.toString().toLowerCase().trim() ?? '';
        if (r1 == 'chairman') return true;

        final uMap = box.get('user_data') ?? box.get('currentUser') ?? box.get('active_user');
        if (uMap is Map) {
          final r2 = (uMap['role'] ?? uMap['type'] ?? uMap['accountType'] ?? '').toString().toLowerCase().trim();
          if (r2 == 'chairman') return true;
        }
      }
    } catch (_) {}

    try {
      final currentUid = FirebaseAuth.instance.currentUser?.uid;
      if (currentUid != null && currentUid.isNotEmpty) {
        final local = LocalStorageService.getLocalUserByUid(currentUid);
        if (local != null) {
          final r = (local['role'] ?? local['type'] ?? local['accountType'] ?? '').toString().toLowerCase().trim();
          if (r == 'chairman') return true;
        }
      }
    } catch (_) {}

    return false;
  }

  String _getActorRole() {
    if (widget.currentUserRole != null && widget.currentUserRole!.isNotEmpty) {
      return widget.currentUserRole!.toLowerCase().trim();
    }
    try {
      final label = RoleThemeScope.dataOf(context).roleLabel.toLowerCase().trim();
      if (label.isNotEmpty) return label;
    } catch (_) {}

    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser != null) {
      final uid = currentUser.uid;
      if (Hive.isBoxOpen(LocalStorageService.usersBox)) {
        final uDoc = Hive.box(LocalStorageService.usersBox).get(uid);
        if (uDoc is Map) {
          final r = (uDoc['role'] ?? '').toString().toLowerCase().trim();
          if (r.isNotEmpty) return r;
        }
      }
    }

    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final r1 = (box.get('user_role') ?? box.get('role'))?.toString().toLowerCase().trim() ?? '';
        if (r1.isNotEmpty) return r1;

        final uMap = box.get('user_data') ?? box.get('currentUser') ?? box.get('active_user');
        if (uMap is Map) {
          final r2 = (uMap['role'] ?? '').toString().toLowerCase().trim();
          if (r2.isNotEmpty) return r2;
        }
      }
    } catch (_) {}

    return 'admin';
  }

  bool _canManageUserAccess(Map<String, dynamic> targetData) {
    final targetRole = (targetData['role'] as String? ?? '').toLowerCase().trim();

    // Chairman account is 100% immutable and CANNOT be deleted, edited, suspended, or demoted by ANY user.
    if (targetRole == 'chairman') {
      return false;
    }

    final actorRole = _getActorRole();
    const allowedRoles = {'chairman', 'global admin', 'admin', 'ceo', 'hq manager', 'branch manager', 'supervisor'};
    return allowedRoles.contains(actorRole);
  }

  Future<void> _showQuickDeleteUserDialog(Map<String, dynamic> data, String branchId, RoleThemeData t) async {
    if (!_canManageUserAccess(data)) {
      final roleName = (data['role'] as String? ?? 'User').toUpperCase();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text((data['role']?.toString().toLowerCase().trim() == 'chairman')
              ? 'Access Denied: The Chairman account can NEVER be deleted or removed.'
              : 'Access Denied: You do not have permission to delete $roleName accounts.'),
          backgroundColor: Colors.red.shade800,
        ),
      );
      return;
    }

    final userName = data['name'] ?? data['username'] ?? 'User';
    final targetUid = (data['uid'] ?? data['id'] ?? data['docId'] ?? '').toString();
    final usernameLower = (data['usernameLower'] ?? data['username'] ?? '').toString().trim().toLowerCase();
    final email = (data['email'] ?? '').toString().trim().toLowerCase();

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.delete_forever_rounded, color: Colors.red, size: 28),
            const SizedBox(width: 10),
            Text('Delete Account', style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
        content: Text(
          'Are you sure you want to PERMANENTLY delete the account for "$userName"? This will remove their credentials and access completely.',
          style: TextStyle(color: t.textSecondary, fontSize: 13.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: t.textSecondary)),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.delete_forever_rounded, size: 18),
            label: const Text('Delete Permanently'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      final targetEmail = (data['email'] ?? '').toString().trim();
      final targetPass = (data['password'] ?? '').toString().trim();
      bool authDeleted = false;

      if (targetEmail.isNotEmpty && targetPass.isNotEmpty) {
        try {
          const appName = 'AdminDeleteAuthApp';
          FirebaseApp? secondaryApp;
          try {
            secondaryApp = Firebase.app(appName);
          } catch (_) {
            secondaryApp = await Firebase.initializeApp(
              name: appName,
              options: Firebase.app().options,
            );
          }

          final secondaryAuth = FirebaseAuth.instanceFor(app: secondaryApp);
          final creds = await secondaryAuth.signInWithEmailAndPassword(email: targetEmail, password: targetPass);
          final targetUser = creds.user;
          if (targetUser == null) {
            throw Exception('Firebase Auth user not found for $targetEmail.');
          }
          await targetUser.delete();
          await OfflineAuthService.clearCredentialsForUser(targetEmail);
          await secondaryAuth.signOut();
          authDeleted = true;
        } catch (e) {
          debugPrint('[UsersPage] Auth delete skipped or failed: $e');
        }
      }

      // Purge from local Hive storage boxes
      for (final boxName in [LocalStorageService.usersBox, 'local_users', 'local']) {
        if (Hive.isBoxOpen(boxName)) {
          final box = Hive.box(boxName);
          if (targetUid.isNotEmpty) await box.delete(targetUid);
          if (usernameLower.isNotEmpty) await box.delete(usernameLower);
          if (email.isNotEmpty) await box.delete(email);
          final keysToDelete = <dynamic>[];
          for (final key in box.keys) {
            final val = box.get(key);
            if (val is Map) {
              final uidVal = (val['uid'] ?? val['id'] ?? '').toString();
              final uNameVal = (val['username'] ?? '').toString().toLowerCase();
              final emailVal = (val['email'] ?? '').toString().toLowerCase();
              if ((targetUid.isNotEmpty && uidVal == targetUid) ||
                  (usernameLower.isNotEmpty && uNameVal == usernameLower) ||
                  (email.isNotEmpty && emailVal == email)) {
                keysToDelete.add(key);
              }
            }
          }
          for (final k in keysToDelete) {
            await box.delete(k);
          }
        }
      }

      await LocalStorageService.deleteUserOffline(
        uid: targetUid,
        branchId: branchId,
        email: email,
        username: usernameLower,
      );

      // Bi-directional Employee & Biometric purge
      await FinanceLocalStorage.syncBiDirectionalOffboarding(
        userId: targetUid,
        cnic: (data['cnic'] ?? data['identification'])?.toString(),
        performedBy: widget.currentUserRole ?? 'UserAdmin',
      );
      await FinanceLocalStorage.purgeEmployeeForDeletedUser(targetUid);

      // Purge from Firestore
      final firestore = FirebaseFirestore.instance;
      if (targetUid.isNotEmpty) {
        await firestore.collection('users').doc(targetUid).delete().catchError((_) {});
      }
      if (usernameLower.isNotEmpty && usernameLower != targetUid) {
        await firestore.collection('users').doc(usernameLower).delete().catchError((_) {});
      }
      if (branchId.isNotEmpty && branchId != 'all') {
        if (targetUid.isNotEmpty) {
          await firestore.collection('branches').doc(branchId).collection('users').doc(targetUid).delete().catchError((_) {});
        }
        if (usernameLower.isNotEmpty && usernameLower != targetUid) {
          await firestore.collection('branches').doc(branchId).collection('users').doc(usernameLower).delete().catchError((_) {});
        }
      }

      final deleteMessage = authDeleted
          ? 'Account "$userName" has been permanently deleted.'
          : 'Account "$userName" was removed from the app and server records. Firebase Auth cleanup was skipped because the stored password was missing or invalid.';

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(deleteMessage),
            backgroundColor: Colors.red.shade800,
          ),
        );
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error deleting account: $e'),
            backgroundColor: Colors.red.shade900,
          ),
        );
      }
    }
  }

  Widget _buildPendingRequestsBanner(List<Map<String, dynamic>> pendingList, String branchId, RoleThemeData t) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF59E0B).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.45), width: 1.2),
        boxShadow: [
          BoxShadow(color: const Color(0xFFF59E0B).withValues(alpha: 0.1), blurRadius: 10, offset: const Offset(0, 3)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color(0xFFF59E0B).withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.notifications_active_rounded, color: Color(0xFFFBBF24), size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Access Restore Requests (${pendingList.length})',
                  style: const TextStyle(
                    color: Color(0xFFFBBF24),
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFF59E0B),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'REQUIRES HQ APPROVAL',
                  style: TextStyle(color: Colors.black, fontSize: 9, fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...pendingList.map((user) {
            final uName = (user['name'] ?? user['username'] ?? 'User').toString();
            final uBranch = (user['branchId'] ?? branchId).toString();
            final uReason = (user['restoreRequestReason'] ?? 'No remarks provided').toString();
            final uRole = (user['role'] ?? 'User').toString();

            return Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: t.bgCard,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.25)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                uName,
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: t.textPrimary),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: t.accentMuted,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(uRole, style: TextStyle(fontSize: 9, color: t.accent, fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'Branch: $uBranch · "$uReason"',
                          style: TextStyle(fontSize: 11, color: t.textSecondary, fontStyle: FontStyle.italic),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: () => _allowUserAccess(user, branchId, t),
                    icon: const Icon(Icons.check_circle_rounded, size: 14),
                    label: const Text('Allow'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF10B981),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      elevation: 0,
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Future<void> _showQuickRevokeDialog(Map<String, dynamic> data, String branchId, RoleThemeData t) async {
    if (!_canManageUserAccess(data)) {
      final roleName = (data['role'] as String? ?? 'User').toUpperCase();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Access Denied: You do not have permission to alter access for $roleName accounts.'),
          backgroundColor: Colors.red.shade800,
        ),
      );
      return;
    }

    // If this is an employee record (from local_employees)
    if (data['isEmployeeRecord'] == true) {
      await _showReactivateEmployeeDialog(data, branchId, t);
      return;
    }

    final status = (data['status'] ?? data['accountStatus'] ?? 'active').toString().toLowerCase().trim();
    final isPendingRestore = (data['restoreRequestStatus'] ?? '').toString().toLowerCase().trim() == 'pending' ||
        data['restoreRequested'] == true;
    final isRevoked = status == 'inactive' ||
        status == 'suspended' ||
        status == 'terminated' ||
        status == 'resigned' ||
        status == 'retired' ||
        status == 'offboarded' ||
        status == 'revoked' ||
        data['isActive'] == false ||
        data['isRevoked'] == true ||
        data['accessRevoked'] == true ||
        isPendingRestore;

    if (isRevoked || isPendingRestore) {
      // Allow / Restore user access
      await _allowUserAccess(data, branchId, t);
    } else {
      // Explicitly REVOKE user app access (distinct from employee offboarding)
      await _showRevokeAccessDialog(data, branchId, t);
    }
  }

  /// Explicitly Revoke a User's App Access
  Future<void> _showRevokeAccessDialog(Map<String, dynamic> data, String branchId, RoleThemeData t) async {
    final uid = (data['uid'] ?? data['id'] ?? data['docId'] ?? '').toString();
    final name = (data['name'] ?? data['username'] ?? 'User').toString();
    final branch = (data['branchId'] ?? branchId).toString();
    final email = (data['email'] ?? '').toString();

    final reasonCtrl = TextEditingController();
    String selectedPredefinedReason = 'Administrative Revocation';
    final predefinedReasons = [
      'Administrative Revocation',
      'Suspicious Activity',
      'Temporary Suspension',
      'Role Reassignment',
      'Disciplinary Action',
      'Other',
    ];

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          backgroundColor: t.bgCard,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.lock_person_rounded, color: Colors.red, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Revoke App Access',
                  style: TextStyle(color: t.textPrimary, fontSize: 17, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Are you sure you want to revoke app access for @$name?', style: TextStyle(color: t.textSecondary, fontSize: 13)),
              const SizedBox(height: 14),
              Text('Reason for Revoking Access', style: TextStyle(color: t.textPrimary, fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                value: selectedPredefinedReason,
                dropdownColor: t.bgCard,
                style: TextStyle(color: t.textPrimary, fontSize: 13),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: t.bg,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.bgRule)),
                ),
                items: predefinedReasons.map((r) => DropdownMenuItem(value: r, child: Text(r))).toList(),
                onChanged: (val) {
                  if (val != null) setS(() => selectedPredefinedReason = val);
                },
              ),
              const SizedBox(height: 10),
              TextField(
                controller: reasonCtrl,
                style: TextStyle(color: t.textPrimary, fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Additional remarks (optional)...',
                  hintStyle: TextStyle(color: t.textTertiary, fontSize: 12),
                  filled: true,
                  fillColor: t.bg,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.bgRule)),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel', style: TextStyle(color: t.textSecondary)),
            ),
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.lock_person_rounded, size: 16),
              label: const Text('Revoke Access'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
      ),
    );

    if (confirm != true) return;

    final detailedReason = reasonCtrl.text.trim();
    final finalReason = detailedReason.isNotEmpty ? '$selectedPredefinedReason: $detailedReason' : selectedPredefinedReason;
    final nowIso = DateTime.now().toIso8601String();

    final updates = <String, dynamic>{
      'status': 'revoked',
      'accountStatus': 'revoked',
      'isActive': false,
      'isRevoked': true,
      'accessRevoked': true,
      'revocationReason': finalReason,
      'revokedAt': nowIso,
      'revokedBy': widget.currentUserRole ?? 'HQ Manager',
      'restoreRequested': false,
      'restoreRequestStatus': 'revoked',
      'updatedAt': nowIso,
    };

    // Update locally
    if (Hive.isBoxOpen('local_users')) {
      final box = Hive.box('local_users');
      for (final key in [uid, email]) {
        if (key.isEmpty) continue;
        final raw = box.get(key);
        if (raw is Map) {
          final u = Map<String, dynamic>.from(raw)..addAll(updates);
          await box.put(key, u);
        }
      }
      for (final k in box.keys) {
        final val = box.get(k);
        if (val is Map && (val['uid'] == uid || val['id'] == uid)) {
          final u = Map<String, dynamic>.from(val)..addAll(updates);
          await box.put(k, u);
        }
      }
      await box.flush();
    }

    // Update in Firestore
    if (uid.isNotEmpty) {
      try {
        await FirebaseFirestore.instance.collection('users').doc(uid).set({
          ...updates,
          'revokedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true)).timeout(const Duration(seconds: 4));

        if (branch.isNotEmpty && branch != 'all' && branch != 'global') {
          await FirebaseFirestore.instance.collection('branches').doc(branch).collection('users').doc(uid).set({
            ...updates,
            'revokedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true)).timeout(const Duration(seconds: 3));
        }
      } catch (_) {}
    }

    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('🔒 App access revoked for @$name'),
          backgroundColor: Colors.red.shade800,
        ),
      );
    }
  }

  /// HQ Manager / Admin Allows and Restores User App Access
  Future<void> _allowUserAccess(Map<String, dynamic> data, String branchId, RoleThemeData t) async {
    final uid = (data['uid'] ?? data['id'] ?? data['docId'] ?? '').toString();
    final name = (data['name'] ?? data['username'] ?? 'User').toString();
    final branch = (data['branchId'] ?? branchId).toString();
    final email = (data['email'] ?? '').toString();

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.check_circle_rounded, color: Colors.green, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Allow App Access',
                style: TextStyle(color: t.textPrimary, fontSize: 17, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Allow and restore app access for @$name?', style: TextStyle(color: t.textSecondary, fontSize: 13)),
            if (data['restoreRequestReason'] != null && data['restoreRequestReason'].toString().isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: t.bg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('User Note: "${data['restoreRequestReason']}"', style: TextStyle(color: t.textTertiary, fontSize: 12, fontStyle: FontStyle.italic)),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: t.textSecondary)),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.check_circle_rounded, size: 16),
            label: const Text('Allow & Restore'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final nowIso = DateTime.now().toIso8601String();
    final updates = <String, dynamic>{
      'status': 'active',
      'accountStatus': 'active',
      'isActive': true,
      'isRevoked': false,
      'accessRevoked': false,
      'restoreRequested': false,
      'restoreRequestStatus': 'approved',
      'restoredAt': nowIso,
      'restoredBy': widget.currentUserRole ?? 'HQ Manager',
      'revocationReason': null,
      'revokedAt': null,
      'updatedAt': nowIso,
    };

    // Update in local Hive
    if (Hive.isBoxOpen('local_users')) {
      final box = Hive.box('local_users');
      for (final key in [uid, email]) {
        if (key.isEmpty) continue;
        final raw = box.get(key);
        if (raw is Map) {
          final u = Map<String, dynamic>.from(raw)..addAll(updates);
          await box.put(key, u);
        }
      }
      for (final k in box.keys) {
        final val = box.get(k);
        if (val is Map && (val['uid'] == uid || val['id'] == uid)) {
          final u = Map<String, dynamic>.from(val)..addAll(updates);
          await box.put(k, u);
        }
      }
      await box.flush();
    }

    // Update in Firestore
    if (uid.isNotEmpty) {
      try {
        await FirebaseFirestore.instance.collection('users').doc(uid).set({
          ...updates,
          'restoredAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true)).timeout(const Duration(seconds: 4));

        if (branch.isNotEmpty && branch != 'all' && branch != 'global') {
          await FirebaseFirestore.instance.collection('branches').doc(branch).collection('users').doc(uid).set({
            ...updates,
            'restoredAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true)).timeout(const Duration(seconds: 3));
        }
      } catch (_) {}
    }

    // Send confirmation notification to user
    try {
      final notifId = 'restored_${uid}_${DateTime.now().millisecondsSinceEpoch}';
      final notif = {
        'id': notifId,
        'title': '🎉 Access Restored',
        'message': 'Your app access has been approved and restored by the HQ Manager. You can now log in and use the app normally.',
        'category': 'Account Alert',
        'type': 'access_restored',
        'targetUserId': uid,
        'branchId': branch,
        'timestamp': nowIso,
        'seen': false,
      };
      if (Hive.isBoxOpen(LocalStorageService.notificationsBox)) {
        await Hive.box(LocalStorageService.notificationsBox).put(notifId, notif);
      }
    } catch (_) {}

    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ Access allowed and restored for @$name'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  /// Dialog to reactivate an offboarded employee profile (HR/Payroll)
  Future<void> _showReactivateEmployeeDialog(Map<String, dynamic> data, String branchId, RoleThemeData t) async {
    final empId = (data['localId'] ?? data['id'] ?? '').toString();
    final name = (data['name'] ?? 'Employee').toString();

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.purple.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.person_add_rounded, color: Colors.purpleAccent, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Reactivate Employee',
                style: TextStyle(color: t.textPrimary, fontSize: 17, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Text('Reactivate employee record for $name? This will rehire them in Employee Management.', style: TextStyle(color: t.textSecondary, fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: t.textSecondary)),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.check_circle_rounded, size: 16),
            label: const Text('Reactivate Employee'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.purple,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      if (Hive.isBoxOpen(LocalStorageService.employeesBox)) {
        final box = Hive.box(LocalStorageService.employeesBox);
        final raw = box.get(empId);
        if (raw is Map) {
          final updated = Map<String, dynamic>.from(raw)
            ..['isActive'] = true
            ..['status'] = 'Active'
            ..['offboardingStatus'] = null
            ..['payrollStatus'] = 'Active'
            ..['updatedAt'] = DateTime.now().toIso8601String();
          await box.put(empId, updated);
          await box.flush();
        }
      }

      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Employee $name has been reactivated.'),
            backgroundColor: Colors.purple,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to reactivate employee: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Widget _emptyState(RoleThemeData t, IconData icon, String title, String subtitle, {bool isError = false}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
                color: (isError ? Colors.red : t.accent).withValues(alpha: 0.08), shape: BoxShape.circle),
            child: Icon(icon, size: 40, color: isError ? Colors.red.shade400 : t.accent.withValues(alpha: 0.5)),
          ),
          const SizedBox(height: 16),
          Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: t.textPrimary)),
          const SizedBox(height: 6),
          Text(subtitle, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: t.textSecondary)),
        ]),
      ),
    );
  }

  // ── Family view ──

  Widget _buildFamilyView(List<Map<String, dynamic>> list, String branchId, RoleThemeData t) {
    Map<String, Map<String, dynamic>> cnicToGuardian = {};
    Map<String, List<Map<String, dynamic>>> families = {};
    List<Map<String, dynamic>> adultsWithoutChildren = [];

    for (var data in list) {
      if (data['isAdult'] == true) {
        final cnic = data['cnic'] as String? ?? '';
        if (cnic.isNotEmpty) cnicToGuardian[cnic] = data;
        adultsWithoutChildren.add(data);
      } else {
        final guardianCnic = data['guardianCnic'] as String? ?? 'Unknown';
        families.putIfAbsent(guardianCnic, () => []);
        families[guardianCnic]!.add(data);
      }
    }
    for (var gc in families.keys) {
      adultsWithoutChildren.removeWhere((a) => a['cnic'] == gc);
    }

    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 24),
      children: [
        ...families.entries.map((entry) => _familyCard(
          t: t, guardianName: cnicToGuardian[entry.key]?['name'] ?? 'Unknown',
          guardianCnic: entry.key, guardian: cnicToGuardian[entry.key],
          children: entry.value, branchId: branchId,
        )),
        if (adultsWithoutChildren.isNotEmpty)
          _soloAdultsCard(adultsWithoutChildren, branchId, t),
      ],
    );
  }

  Widget _familyCard({required RoleThemeData t, required String guardianName,
      required String guardianCnic, required Map<String, dynamic>? guardian,
      required List<Map<String, dynamic>> children, required String branchId}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: t.bgCard, borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.bgRule, width: 0.8),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 3))],
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          leading: Container(padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(color: t.accentMuted, borderRadius: BorderRadius.circular(10)),
              child: Icon(Icons.family_restroom_rounded, color: t.accent, size: 20)),
          title: Text(guardianName, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: t.textPrimary)),
          subtitle: Text('${children.length} child${children.length != 1 ? 'ren' : ''}',
              style: TextStyle(fontSize: 11, color: t.textSecondary)),
          children: [
            if (guardian != null)
              _familyMemberTile(guardian, Icons.person_rounded, t.accent, branchId, t, isGuardian: true),
            ...children.map((c) => _familyMemberTile(c, Icons.child_care_rounded, Colors.orange.shade600, branchId, t)),
          ],
        ),
      ),
    );
  }

  Widget _familyMemberTile(Map<String, dynamic> data, IconData icon, Color color, String branchId, RoleThemeData t, {bool isGuardian = false}) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
          color: color.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.15))),
      child: Row(children: [
        Icon(icon, color: color, size: 16),
        const SizedBox(width: 8),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(data['name'] ?? 'N/A', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: t.textPrimary)),
          Text('${data['gender'] ?? 'N/A'} · ${data['age']?.toString() ?? '?'} yrs',
              style: TextStyle(fontSize: 11, color: t.textSecondary)),
        ])),
        GestureDetector(
          onTap: () => _openDetail(data['id'], branchId),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
            child: Text('View', style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
          ),
        ),
      ]),
    );
  }

  Widget _soloAdultsCard(List<Map<String, dynamic>> adults, String branchId, RoleThemeData t) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: t.bgCard, borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.bgRule, width: 0.8),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 3))],
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          leading: Container(padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(color: t.accentMuted, borderRadius: BorderRadius.circular(10)),
              child: Icon(Icons.person_outline_rounded, color: t.accent, size: 20)),
          title: Text('Adults without Children', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: t.textPrimary)),
          subtitle: Text('${adults.length} individual${adults.length != 1 ? 's' : ''}',
              style: TextStyle(fontSize: 11, color: t.textSecondary)),
          children: adults.map((a) => _familyMemberTile(a, Icons.person_rounded, t.accent, branchId, t)).toList(),
        ),
      ),
    );
  }

  // ── Stream ──

  Future<QuerySnapshot> _loadUsersSnapshot(String branchId) async {
    final normalizedBranch = branchId.trim().toLowerCase();
    if (normalizedBranch.isEmpty || normalizedBranch == 'all' || normalizedBranch == 'global') {
      return FirebaseFirestore.instance.collection('users').limit(200).get();
    }
    return FirebaseFirestore.instance
        .collection('branches')
        .doc(normalizedBranch)
        .collection('users')
        .limit(200)
        .get();
  }


  void _showEnlargedPhotoDialog(
    BuildContext context,
    String name,
    String? photoUrl,
    String role,
    RoleThemeData t,
  ) {
    final bytes = photoUrl != null && photoUrl.trim().isNotEmpty
        ? ImageUploadService.decodeBase64ToBytes(photoUrl)
        : null;

    showDialog(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 520),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: t.accent.withValues(alpha: 0.4), width: 1.8),
              boxShadow: [
                BoxShadow(
                  color: t.accent.withValues(alpha: 0.25),
                  blurRadius: 30,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header bar
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.account_circle_rounded, color: t.accent, size: 22),
                        const SizedBox(width: 8),
                        const Text(
                          'Profile Photo',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.3,
                          ),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.white70),
                      onPressed: () => Navigator.pop(ctx),
                      tooltip: 'Close',
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // Enlarged Avatar Container (320px x 320px)
                Container(
                  width: 320,
                  height: 320,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFFF59E0B), width: 4.0),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFF59E0B).withValues(alpha: 0.45),
                        blurRadius: 24,
                        spreadRadius: 3,
                      ),
                    ],
                  ),
                  child: ClipOval(
                    child: photoUrl != null && photoUrl.trim().isNotEmpty
                        ? (bytes != null
                            ? Image.memory(bytes, fit: BoxFit.cover, width: 320, height: 320)
                            : Image.network(photoUrl, fit: BoxFit.cover, width: 320, height: 320, errorBuilder: (_, _, _) => _buildFallbackAvatar(name, t, size: 320)))
                        : _buildFallbackAvatar(name, t, size: 320),
                  ),
                ),
                const SizedBox(height: 20),

                // User Name & Role
                Text(
                  name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: t.accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: t.accent.withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    role.toUpperCase(),
                    style: TextStyle(
                      color: t.accent,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildFallbackAvatar(String name, RoleThemeData t, {required double size}) {
    final initials = name.trim().isNotEmpty
        ? name.trim().split(' ').map((e) => e[0]).take(2).join().toUpperCase()
        : '?';
    return Container(
      width: size,
      height: size,
      color: t.accentMuted,
      alignment: Alignment.center,
      child: Text(
        initials,
        style: TextStyle(
          color: t.accent,
          fontWeight: FontWeight.w900,
          fontSize: size * 0.35,
        ),
      ),
    );
  }

  void _openAccessControlMatrixSheet(BuildContext context, RoleThemeData t) {
    if (!_isChairmanActor()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Access Denied: Only the Chairman may open and use the Master Access Control Matrix.'),
          backgroundColor: Colors.red.shade800,
        ),
      );
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.90,
          maxChildSize: 0.96,
          minChildSize: 0.5,
          builder: (sheetCtx, scrollController) {
            return _AccessControlMatrixView(
              scrollController: scrollController,
              t: t,
            );
          },
        );
      },
    );
  }
}

// ─── Formatters ───────────────────────────────────────────────────────────────
class CNICInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    final buffer = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      buffer.write(digits[i]);
      if ((i == 4 || i == 11) && i != digits.length - 1) buffer.write('-');
    }
    return TextEditingValue(text: buffer.toString(), selection: TextSelection.collapsed(offset: buffer.length));
  }
}

// ─── Chairman Access Control Matrix View Widget ────────────────────────────────
class _AccessControlMatrixView extends StatefulWidget {
  final ScrollController scrollController;
  final RoleThemeData t;

  const _AccessControlMatrixView({
    required this.scrollController,
    required this.t,
  });

  @override
  State<_AccessControlMatrixView> createState() => _AccessControlMatrixViewState();
}

class _AccessControlMatrixViewState extends State<_AccessControlMatrixView> with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  String _query = '';
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
  }

  Future<QuerySnapshot> _loadUsersSnapshot([String branchId = 'all']) async {
    final normalizedBranch = branchId.trim().toLowerCase();
    if (normalizedBranch.isEmpty || normalizedBranch == 'all' || normalizedBranch == 'global') {
      return FirebaseFirestore.instance.collection('users').limit(200).get();
    }
    return FirebaseFirestore.instance
        .collection('branches')
        .doc(normalizedBranch)
        .collection('users')
        .limit(200)
        .get();
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    final modules = UserModuleAccessService.systemModules;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: t.accent.withValues(alpha: 0.4), width: 1.5),
      ),
      child: Column(
        children: [
          // Drag Handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 40,
              height: 4,
              decoration: BoxDecoration(color: Colors.white30, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F5132).withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.admin_panel_settings_rounded, color: Color(0xFF10B981), size: 24),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        Text('Master Access Control Matrix', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
                        Text('Chairman Authority & Module Permission Overrides', style: TextStyle(color: Colors.white60, fontSize: 11)),
                      ],
                    ),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white70),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          TabBar(
            controller: _tabCtrl,
            labelColor: const Color(0xFF10B981),
            unselectedLabelColor: Colors.white60,
            indicatorColor: const Color(0xFF10B981),
            tabs: const [
              Tab(icon: Icon(Icons.person_off_rounded, size: 18), text: 'User Module Overrides'),
              Tab(icon: Icon(Icons.table_chart_rounded, size: 18), text: 'Role Access Matrix'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabCtrl,
              children: [
                _buildUserOverridesTab(context, t, modules),
                _buildRoleMatrixTab(t),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUserOverridesTab(BuildContext context, RoleThemeData t, List<Map<String, String>> modules) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Container(
            height: 42,
            decoration: BoxDecoration(color: const Color(0xFF1E293B), borderRadius: BorderRadius.circular(12)),
            child: TextField(
              controller: _searchCtrl,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
              decoration: const InputDecoration(
                hintText: 'Search user by name, username, or role...',
                hintStyle: TextStyle(color: Colors.white54, fontSize: 12),
                prefixIcon: Icon(Icons.search, color: Colors.white54, size: 18),
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
        ),
        Expanded(
          child: FutureBuilder<QuerySnapshot>(
            future: _loadUsersSnapshot('all'),
            builder: (ctx, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final docs = snap.data!.docs;
              var users = docs.map((d) {
                final data = Map<String, dynamic>.from(d.data() as Map);
                data['id'] = d.id;
                return data;
              }).toList();

              if (_query.isNotEmpty) {
                users = users.where((u) {
                  final name = (u['name'] ?? u['username'] ?? '').toString().toLowerCase();
                  final role = (u['role'] ?? '').toString().toLowerCase();
                  return name.contains(_query) || role.contains(_query);
                }).toList();
              }

              users.sort((a, b) {
                final roleA = (a['role'] ?? '').toString().toLowerCase().trim();
                final roleB = (b['role'] ?? '').toString().toLowerCase().trim();
                if (roleA == 'chairman' && roleB != 'chairman') return -1;
                if (roleA != 'chairman' && roleB == 'chairman') return 1;
                return (a['name'] ?? a['username'] ?? '').toString().compareTo((b['name'] ?? b['username'] ?? '').toString());
              });

              return ListView.builder(
                controller: widget.scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                itemCount: users.length,
                itemBuilder: (ctx, idx) {
                  final user = users[idx];
                  final userId = (user['id'] ?? user['localId'] ?? user['username'] ?? '').toString();
                  final name = (user['name'] ?? user['username'] ?? 'User').toString();
                  final role = (user['role'] ?? 'staff').toString();
                  final isChairman = role.toLowerCase().trim() == 'chairman';

                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      gradient: isChairman
                          ? const LinearGradient(
                              colors: [Color(0xFF382207), Color(0xFF1E293B)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            )
                          : null,
                      color: isChairman ? null : const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isChairman ? const Color(0xFFF59E0B) : Colors.white10,
                        width: isChairman ? 1.8 : 1.0,
                      ),
                      boxShadow: isChairman
                          ? [
                              BoxShadow(
                                color: const Color(0xFFF59E0B).withValues(alpha: 0.3),
                                blurRadius: 14,
                                spreadRadius: 1,
                              )
                            ]
                          : null,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(14.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  CircleAvatar(
                                    backgroundColor: isChairman ? const Color(0xFFD97706) : const Color(0xFF0F5132),
                                    child: Text(name.isNotEmpty ? name[0].toUpperCase() : 'U', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                  ),
                                  const SizedBox(width: 10),
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                                      Text('Role: ${role.toUpperCase()} | Branch: ${user['branchId'] ?? 'all'}', style: const TextStyle(color: Colors.white60, fontSize: 11)),
                                    ],
                                  ),
                                ],
                              ),
                              if (isChairman)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(color: const Color(0xFFD97706).withValues(alpha: 0.2), borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFFD97706))),
                                  child: const Text('👑 Chairman (Unrestricted)', style: TextStyle(color: Color(0xFFF59E0B), fontSize: 10, fontWeight: FontWeight.bold)),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          const Divider(color: Colors.white12, height: 1),
                          const SizedBox(height: 8),
                          if (isChairman)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 6.0),
                              child: Text('The Chairman is the highest authority in GMWF and has 100% unrestricted access to all modules and finance.', style: TextStyle(color: Colors.white70, fontSize: 11, fontStyle: FontStyle.italic)),
                            )
                          else
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: modules.map((mod) {
                                final modId = mod['id']!;
                                final modName = mod['name']!;
                                final isBlocked = UserModuleAccessService.isModuleBlockedForUser(userId, modId);
                                final isAllowed = UserModuleAccessService.canUserAccessModule(userId: userId, role: role, moduleId: modId);

                                return FilterChip(
                                  selected: isAllowed,
                                  showCheckmark: false,
                                  avatar: Icon(
                                    isBlocked ? Icons.block_rounded : (isAllowed ? Icons.check_circle_rounded : Icons.lock_outline_rounded),
                                    size: 14,
                                    color: isBlocked ? Colors.redAccent : (isAllowed ? Colors.greenAccent : Colors.white54),
                                  ),
                                  label: Text(
                                    isBlocked ? '$modName (BLOCKED)' : modName,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: isBlocked ? Colors.redAccent : (isAllowed ? Colors.white : Colors.white54),
                                    ),
                                  ),
                                  selectedColor: isBlocked ? Colors.red.withValues(alpha: 0.2) : const Color(0xFF0F5132),
                                  backgroundColor: const Color(0xFF0F172A),
                                  side: BorderSide(
                                    color: isBlocked ? Colors.redAccent : (isAllowed ? const Color(0xFF10B981) : Colors.white24),
                                  ),
                                  onSelected: (val) async {
                                    final newBlocked = !isBlocked;
                                    final messenger = ScaffoldMessenger.maybeOf(context);
                                    await UserModuleAccessService.setModuleAccessForUser(
                                      userId: userId,
                                      moduleId: modId,
                                      isBlocked: newBlocked,
                                      performedBy: 'Chairman',
                                    );
                                    if (!mounted) return;
                                    setState(() {});
                                    messenger?.showSnackBar(
                                      SnackBar(
                                        content: Text(newBlocked
                                            ? 'Blocked $modName for $name'
                                            : 'Unblocked $modName for $name'),
                                        duration: const Duration(seconds: 2),
                                      ),
                                    );
                                  },
                                );
                              }).toList(),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildRoleMatrixTab(RoleThemeData t) {
    final matrix = UserModuleAccessService.getRoleDefaultsMap();

    return SingleChildScrollView(
      controller: widget.scrollController,
      padding: const EdgeInsets.all(16),
      child: Table(
        border: TableBorder.all(color: Colors.white24, borderRadius: BorderRadius.circular(10)),
        columnWidths: const {
          0: FlexColumnWidth(1.2),
          1: FlexColumnWidth(2.5),
        },
        children: [
          TableRow(
            decoration: const BoxDecoration(color: Color(0xFF1E293B)),
            children: const [
              Padding(padding: EdgeInsets.all(10), child: Text('Role Title', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12))),
              Padding(padding: EdgeInsets.all(10), child: Text('Permitted System Modules & Scope', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12))),
            ],
          ),
          ...matrix.entries.map((e) {
            return TableRow(
              children: [
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text(e.key, style: const TextStyle(color: Color(0xFF10B981), fontWeight: FontWeight.bold, fontSize: 12)),
                ),
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: e.value.map((m) {
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(4)),
                        child: Text(m, style: const TextStyle(color: Colors.white70, fontSize: 10)),
                      );
                    }).toList(),
                  ),
                ),
              ],
            );
          }),
        ],
      ),
    );
  }
}
