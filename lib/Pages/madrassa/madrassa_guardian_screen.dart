// lib/pages/madrassa/madrassa_guardian_screen.dart
//
// FIXES:
//  • Global-level admin/staff (non-guardian) now sees a student picker
//    dialog first when viewing the guardian portal, then renders the
//    ParentReportCard for the selected student — exactly like a guardian would see.
//  • Regular guardians continue to work as before (their linked studentIds).
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:math' as math;
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:gmwf/design/tokens/comfort_colors.dart';
import 'package:flutter/material.dart';
import 'package:gmwf/pages/home/home_module_host.dart';
import 'package:gmwf/design/components/decorative_image.dart';
import 'package:gmwf/design/components/app_toast.dart';
import 'package:intl/intl.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'widgets/parent_report_card.dart';
import 'widgets/madrassa_erp.dart';
import 'theme/madrassa_theme_scope.dart';
import 'madrassa_strings.dart';
import 'utils/madrassa_local_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../widgets/appearance_dialog.dart';
import '../../services/firebase_session_guard.dart';
import '../../services/local_storage_service.dart';
import '../../services/offline_auth_service.dart';
import '../../services/image_upload_service.dart';
import '../../services/user_theme_service.dart';
import '../../services/user_language_service.dart';
import '../../services/sync_service.dart';
import '../../theme/role_theme_provider.dart';
import '../login_page.dart';

class MadrassaGuardianScreen extends StatefulWidget {
  final Map<String, dynamic> userData;
  const MadrassaGuardianScreen({super.key, required this.userData});

  @override
  State<MadrassaGuardianScreen> createState() =>
      _MadrassaGuardianScreenState();
}

class _MadrassaGuardianScreenState extends State<MadrassaGuardianScreen> {
  int _selectedIndex = 0;

  /// null = still loading from prefs, '' = not set yet, 'en'/'ur' = chosen
  String? _langCode;

  // For admin preview — the student they picked from the dialog
  String? _adminPreviewStudentId;
  Map<String, dynamic>? _adminPreviewStudentData;

  // Added: selected branch for global/HQ accounts
  String? _selectedBranchId;
  String? _selectedBranchName;

  // Prevent repeated dialog triggers (existing flag)
  bool _dialogShown = false;

  // Prevent repeated dialog triggers
  // (kept from earlier definition)
  // Cache the last branchId to invalidate student future when branch changes
  String? _lastBranchId;
  // Prevent the language provider sync from running on every rebuild
  bool _providerSynced = false;
  // Cache the students future so it isn't recreated on every rebuild
  Future<List<DocumentSnapshot>>? _studentsFuture;

  bool _autoBranchDialogTriggered = false;
  bool _autoStudentDialogTriggered = false;
  bool _showDetailed = false;

  static const Duration _guardianRefreshCooldown = Duration(seconds: 30);
  static DateTime? _lastGuardianRefreshTime;

  @override
  void initState() {
    super.initState();
    _loadLanguage();
  }

  Future<void> _loadLanguage() async {
    try {
      await MadrassaLocalStorage.ensureBoxesOpen();
      FirebaseSessionGuard.start();
      final rawBranch = (widget.userData['branchId'] ?? '').toString().trim();
      final normBranch = MadrassaLocalStorage.normalizeBranch(rawBranch);
      final syncBranch = (normBranch.isEmpty || normBranch == 'all') ? 'gujrat' : normBranch;
      SyncService().start(syncBranch);
      final saved = UserLanguageService.getLanguage();
      if (mounted) setState(() => _langCode = saved);
    } catch (_) {
      if (mounted) setState(() => _langCode = 'en');
    }
  }

  Future<void> _selectLanguage(String code) async {
    await UserLanguageService.setLanguage(code);
    if (mounted) {
      setState(() {
        _langCode = code;
        _providerSynced = false;
      });
      // Also update the Provider if it exists in the tree
      try {
        Provider.of<MadrassaLanguageProvider>(context, listen: false).setLanguage(code);
      } catch (_) {}
    }
  }

  Future<void> _logout() async {
    try {
      await OfflineAuthService.clearCachedUserData();
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginPage()),
          (r) => false,
        );
      }
    } catch (e) {
      // Removed debugPrint for dead code audit
    }
  }

  Future<List<DocumentSnapshot>> _fetchStudents(
      String branchId, List<String> ids) async {
    if (ids.isEmpty) return [];

    // Auto-resolve branch if branchId is empty, 'all', or 'global'
    String effectiveBranch = MadrassaLocalStorage.normalizeBranch(branchId);
    if (effectiveBranch.isEmpty || effectiveBranch == 'all' || effectiveBranch == 'global') {
      // 1. Check local Hive cached branches
      for (final b in LocalStorageService.getLocalBranchesList()) {
        final bId = MadrassaLocalStorage.normalizeBranch((b['id'] ?? '').toString());
        if (bId.isNotEmpty && bId != 'all' && bId != 'global') {
          for (final id in ids) {
            if (MadrassaLocalStorage.getStudentCached(bId, id) != null) {
              effectiveBranch = bId;
              break;
            }
          }
        }
        if (effectiveBranch.isNotEmpty && effectiveBranch != 'all' && effectiveBranch != 'global') break;
      }

      // 2. If still unresolved, query Firestore collectionGroup
      if (effectiveBranch.isEmpty || effectiveBranch == 'all' || effectiveBranch == 'global') {
        try {
          final groupSnap = await FirebaseFirestore.instance
              .collectionGroup('madrassa_students')
              .where(FieldPath.documentId, isEqualTo: ids.first)
              .limit(1)
              .get()
              .timeout(const Duration(seconds: 6));
          if (groupSnap.docs.isNotEmpty) {
            final parentBranch = groupSnap.docs.first.reference.parent.parent?.id;
            if (parentBranch != null && parentBranch.isNotEmpty) {
              effectiveBranch = MadrassaLocalStorage.normalizeBranch(parentBranch);
            }
          }
        } catch (_) {}
      }

      // 3. Fallback to default branch if known (e.g. gujrat)
      if (effectiveBranch.isEmpty || effectiveBranch == 'all' || effectiveBranch == 'global') {
        effectiveBranch = 'gujrat';
      }
    }

    SyncService().start(effectiveBranch);

    final now = DateTime.now();
    final allStudentsCached = ids.every((id) => MadrassaLocalStorage.getStudentCached(effectiveBranch, id) != null);

    // If any linked student is missing from local Hive, download scoped records
    if (!allStudentsCached) {
      try {
        await MadrassaLocalStorage.downloadStudentsForGuardian(effectiveBranch, ids)
            .timeout(const Duration(seconds: 8), onTimeout: () {});
        await Future.wait([
          MadrassaLocalStorage.downloadLogsForMonth(effectiveBranch, now.year, now.month),
          MadrassaLocalStorage.downloadHolidays(effectiveBranch),
          MadrassaLocalStorage.downloadConfig(effectiveBranch),
        ]).timeout(const Duration(seconds: 8), onTimeout: () => []);
      } catch (_) {}
    } else {
      // Hive already has all linked student records.
      // Only do a low-priority background refresh if 30 minutes have elapsed.
      if (_lastGuardianRefreshTime == null || now.difference(_lastGuardianRefreshTime!) > const Duration(minutes: 30)) {
        _lastGuardianRefreshTime = now;
        Future.wait([
          MadrassaLocalStorage.downloadLogsForMonth(effectiveBranch, now.year, now.month),
          MadrassaLocalStorage.downloadConfig(effectiveBranch),
        ]).catchError((_) => <void>[]);
      }
    }

    final candidateBranches = effectiveBranch == 'gujrat'
        ? const ['karachi', 'saddar', 'jalalpurjattan', 'sialkot', 'rawalpindi', 'grt']
        : const ['gujrat', 'karachi', 'saddar', 'jalalpurjattan', 'sialkot', 'rawalpindi', 'grt'];

    Future<DocumentSnapshot?> fetchFromServer(String id) async {
      try {
        final serverDoc = await FirebaseFirestore.instance
            .collection('branches')
            .doc(effectiveBranch)
            .collection('madrassa_students')
            .doc(id)
            .get()
            .timeout(const Duration(seconds: 8));
        if (serverDoc.exists) return serverDoc;
      } catch (_) {}
      for (final altBranch in candidateBranches) {
        try {
          final altDoc = await FirebaseFirestore.instance
              .collection('branches')
              .doc(altBranch)
              .collection('madrassa_students')
              .doc(id)
              .get()
              .timeout(const Duration(seconds: 5));
          if (altDoc.exists) return altDoc;
        } catch (_) {}
      }
      return null;
    }

    try {
      // Fetch each student doc from cache first, falling back to server if not in cache!
      final snaps = await Future.wait(ids.map((id) async {
        DocumentSnapshot? doc;
        try {
          final cachedDoc = await FirebaseFirestore.instance
              .collection('branches')
              .doc(effectiveBranch)
              .collection('madrassa_students')
              .doc(id)
              .get(const GetOptions(source: Source.cache));
          if (cachedDoc.exists) doc = cachedDoc;
        } catch (_) {}

        if (doc == null || !doc.exists) {
          for (final altBranch in candidateBranches) {
            try {
              final altDoc = await FirebaseFirestore.instance
                  .collection('branches')
                  .doc(altBranch)
                  .collection('madrassa_students')
                  .doc(id)
                  .get(const GetOptions(source: Source.cache));
              if (altDoc.exists) {
                doc = altDoc;
                break;
              }
            } catch (_) {}
          }
        }

        if (doc == null || !doc.exists) {
          final serverDoc = await fetchFromServer(id);
          if (serverDoc != null) doc = serverDoc;
        }

        return doc ??
            await FirebaseFirestore.instance
                .collection('branches')
                .doc(effectiveBranch)
                .collection('madrassa_students')
                .doc(id)
                .get();
      }));
      return snaps;
    } catch (e) {
      debugPrint('[MadrassaGuardianScreen] Firestore cache fetch fallback: $e');
      try {
        final snaps = <DocumentSnapshot>[];
        for (final id in ids) {
          final doc = await fetchFromServer(id);
          if (doc != null) snaps.add(doc);
        }
        return snaps;
      } catch (_) {
        return [];
      }
    }
  }

  Future<void> _refreshData() async {
    final now = DateTime.now();
    if (_lastGuardianRefreshTime != null && now.difference(_lastGuardianRefreshTime!) < _guardianRefreshCooldown) {
      if (mounted) {
        AppToast.showSnackBar(context, 
          SnackBar(
            content: Text(context.t('Showing up-to-date data from local storage')),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    _lastGuardianRefreshTime = now;

    final branchId = widget.userData['branchId'] as String? ?? '';
    final dynamic rawIds = widget.userData['studentIds'] ?? widget.userData['studentId'];
    final List<String> studentIds = [];
    if (rawIds is List) {
      for (final id in rawIds) {
        final s = id?.toString().trim() ?? '';
        if (s.isNotEmpty) studentIds.add(s);
      }
    } else if (rawIds is String && rawIds.trim().isNotEmpty) {
      studentIds.add(rawIds.trim());
    }

    try {
      if (branchId.isNotEmpty) {
        if (studentIds.isNotEmpty) {
          await MadrassaLocalStorage.downloadStudentsForGuardian(branchId, studentIds);
        } else {
          await MadrassaLocalStorage.downloadStudents(branchId);
        }
        final nowDt = DateTime.now();
        await MadrassaLocalStorage.downloadLogsForMonth(branchId, nowDt.year, nowDt.month);
        await MadrassaLocalStorage.downloadHolidays(branchId);
        await MadrassaLocalStorage.downloadConfig(branchId);
      }
      await SyncService().triggerUpload();
    } catch (_) {}

    if (mounted) {
      setState(() {
        _studentsFuture = _fetchStudents(branchId, studentIds);
      });
      AppToast.showSnackBar(context, 
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle_rounded, color: SoftPalette.gray50, size: 20),
              const SizedBox(width: 8),
              Text(context.t('Data updated successfully')),
            ],
          ),
          backgroundColor: SoftPalette.teal550,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  bool _isAdminViewing() {
    final role = (widget.userData['role'] as String? ?? '').toLowerCase().trim();
    final isGuardian = role == 'madrassa guardian' ||
        role == 'madrassa parent' ||
        role == 'guardian' ||
        role == 'parent' ||
        role == 'school guardian' ||
        role == 'school parent' ||
        role.contains('guardian') ||
        role.contains('parent');
    return !isGuardian;
  }

  // Helper to fetch branches and show a picker when branchId is missing
  Future<void> _showBranchPickerDialog(BuildContext context) async {
    final localBranches = LocalStorageService.getLocalBranchesList();
    List<Map<String, String>> branches = [];

    if (localBranches.isNotEmpty) {
      branches = localBranches.map((b) => {
        'id': b['id'].toString(),
        'name': b['name'].toString(),
      }).toList();
    } else {
      try {
        final snap = await FirebaseFirestore.instance.collection('branches').get();
        branches = snap.docs.map((d) => {
          'id': d.id,
          'name': (d.data()['name'] as String?) ?? d.id,
        }).toList();
      } catch (_) {}
    }

    if (!mounted) return;
    if (branches.isEmpty) {
      AppToast.showSnackBar(context, 
        SnackBar(content: Text(context.t('No branches available.'))),
      );
      return;
    }
    final searchCtrl = TextEditingController();
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setStateDialog) {
            final query = searchCtrl.text.toLowerCase().trim();
            final filtered = branches.where((b) {
              final name = (b['name'] ?? '').toLowerCase();
              return name.contains(query);
            }).toList();
            return Dialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              child: Container(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: searchCtrl,
                      decoration: InputDecoration(
                        hintText: context.t('Search branches...'),
                        prefixIcon: const Icon(Icons.search),
                      ),
                      onChanged: (_) => setStateDialog(() {}),
                    ),
                    const SizedBox(height: 16),
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (_, i) {
                          final bMap = filtered[i];
                          final id = bMap['id'] ?? '';
                          final name = bMap['name'] ?? 'Branch';
                          return ListTile(
                            title: Text(name),
                            onTap: () {
                              setState(() {
                                _selectedBranchId = id;
                                _selectedBranchName = name;
                                _studentsFuture = null;
                                _lastBranchId = null;
                                _autoStudentDialogTriggered = false;
                              });
                              Navigator.pop(ctx);
                            },
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: Text(context.t('Cancel')),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showStudentPickerDialog(BuildContext context, String branchId) async {
    List<Map<String, dynamic>> localList = MadrassaLocalStorage.getAllStudentsCached(branchId);
    if (localList.isEmpty) {
      await MadrassaLocalStorage.downloadStudents(branchId);
      localList = MadrassaLocalStorage.getAllStudentsCached(branchId);
    } else {
      // Background refresh to keep cache updated without blocking UI
      MadrassaLocalStorage.downloadStudents(branchId);
    }

    if (!mounted) return;

    final allStudents = List<Map<String, dynamic>>.from(localList)
      ..sort((a, b) {
        final aVal = int.tryParse(a['rollNumber']?.toString() ?? '') ?? 999999;
        final bVal = int.tryParse(b['rollNumber']?.toString() ?? '') ?? 999999;
        return aVal.compareTo(bVal);
      });

    if (allStudents.isEmpty) {
      if (!mounted) return;
      AppToast.showSnackBar(context, SnackBar(content: Text(context.t('No active students found.'))));
      return;
    }

    final searchCtrl = TextEditingController();

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setStateDialog) {
            final query = searchCtrl.text.toLowerCase().trim();
            final filteredStudents = allStudents.where((d) {
              final name = (d['name'] as String? ?? '').toLowerCase();
              final rollNumber = (d['rollNumber'] as String? ?? '').toLowerCase();
              return name.contains(query) || rollNumber.contains(query);
            }).toList();

            return Dialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(24), color: ctx.adapt(SoftPalette.gray50)),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.t('Select Student'),
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: ctx.adapt(SoftPalette.teal600)),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: searchCtrl,
                      decoration: InputDecoration(
                        hintText: context.t('Search by name or roll number...'),
                        prefixIcon: Icon(Icons.search, color: ctx.adapt(SoftPalette.teal600)),
                        filled: true,
                        fillColor: ctx.adapt(SoftPalette.gray50),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                      ),
                      onChanged: (_) => setStateDialog(() {}),
                    ),
                    const SizedBox(height: 16),
                    Flexible(
                      child: SizedBox(
                        width: double.maxFinite,
                        child: filteredStudents.isEmpty
                            ? Padding(
                                padding: const EdgeInsets.all(24),
                                child: Center(child: Text(context.t('No matching students found.'))),
                              )
                            : ListView.separated(
                                shrinkWrap: true,
                                itemCount: filteredStudents.length,
                                separatorBuilder: (_, _) => const SizedBox(height: 8),
                                itemBuilder: (_, i) {
                                  final d = filteredStudents[i];
                                  final sId = d['id'] ?? d['docId'] ?? d['studentId'] ?? '';
                                  final photoUrl = (d['photoBase64'] ??
                                          d['photoUrl'] ??
                                          d['photo'] ??
                                          d['image'] ??
                                          d['studentPhotoBase64'])
                                      ?.toString();
                                  final photoStr = photoUrl?.trim();
                                  final bytes = ImageUploadService.decodeBase64ToBytes(photoStr);

                                  return InkWell(
                                    onTap: () {
                                      setState(() {
                                        _adminPreviewStudentId = sId;
                                        _adminPreviewStudentData = d;
                                      });
                                      Navigator.pop(ctx);
                                    },
                                    borderRadius: BorderRadius.circular(16),
                                    child: Container(
                                      padding: const EdgeInsets.all(16),
                                      decoration: BoxDecoration(
                                        color: ctx.adapt(SoftPalette.gray50),
                                        borderRadius: BorderRadius.circular(16),
                                        border: Border.all(color: ctx.adapt(SoftPalette.slate150)),
                                      ),
                                      child: Row(
                                        children: [
                                          CircleAvatar(
                                            radius: 22,
                                            backgroundColor: SoftPalette.teal600,
                                            child: ClipOval(
                                              child: () {
                                                if (bytes != null) {
                                                  return Image.memory(bytes, fit: BoxFit.cover, width: 44, height: 44);
                                                } else if (photoStr != null && photoStr.startsWith('http')) {
                                                  return Image.network(
                                                    photoStr,
                                                    fit: BoxFit.cover,
                                                    width: 44,
                                                    height: 44,
                                                    errorBuilder: (_, __, ___) => Text(
                                                      d['name']?[0] ?? '?',
                                                      style: const TextStyle(color: SoftPalette.gray50, fontWeight: FontWeight.bold, fontSize: 16),
                                                    ),
                                                  );
                                                }
                                                return Text(
                                                  d['name']?[0] ?? '?',
                                                  style: const TextStyle(color: SoftPalette.gray50, fontWeight: FontWeight.bold, fontSize: 16),
                                                );
                                              }(),
                                            ),
                                          ),
                                          const SizedBox(width: 16),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(d['name'] ?? '', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                                                Text('Roll: ${d['rollNumber'] ?? "?"} • Guardian: ${d['guardianName'] ?? "?"}', style: TextStyle(fontSize: 11, color: ctx.adapt(SoftPalette.gray350))),
                                              ],
                                            ),
                                          ),
                                          Icon(Icons.chevron_right, color: ctx.adapt(SoftPalette.teal600)),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: TextButton.icon(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _logout();
                        },
                        icon: Icon(Icons.logout, color: ctx.adapt(SoftPalette.red400)),
                        label: Text(context.t('Logout'), style: TextStyle(color: ctx.adapt(SoftPalette.red400), fontFamily: context.isUrdu ? 'Noori' : null)),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // ── 1. Still loading pref from SharedPreferences ──
    if (_langCode == null) {
      return Scaffold(
        backgroundColor: context.adapt(SoftPalette.gray50),
        body: Center(child: CircularProgressIndicator(color: context.adapt(SoftPalette.teal600))),
      );
    }

    // ── 2. Language not chosen yet → full-screen picker ──
    if (_langCode!.isEmpty) {
      return _LanguagePickerScreen(onSelect: _selectLanguage);
    }

    // ── 3. Language is set → render normal content ──
    // Theme (GMWF by default, the user's Settings choice) above the whole portal,
    // so every page and card reads the same colours.
    final uKey = (widget.userData['username'] ?? widget.userData['uid'] ?? widget.userData['id'] ?? widget.userData['email'])?.toString();
    return MadrassaThemeScope(
      userKey: uKey,
      role: widget.userData['role']?.toString(),
      child: ChangeNotifierProvider(
      create: (_) => MadrassaLanguageProvider(),
      child: Builder(
        builder: (context) {
          // Sync provider with chosen language (only once, not on every rebuild)
          if (!_providerSynced) {
            _providerSynced = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                try {
                  final provider = Provider.of<MadrassaLanguageProvider>(context, listen: false);
                  if (provider.languageCode != _langCode) {
                    provider.setLanguage(_langCode!);
                  }
                } catch (_) {}
              }
            });
          }

           final branchId = widget.userData['branchId'] as String? ?? '';
           final isAdmin = _isAdminViewing();
           // Invalidate cached students future if branchId changed
           if (branchId != _lastBranchId) {
             _studentsFuture = null;
             _lastBranchId = branchId;
           }
          // If not admin, _fetchStudents auto-resolves branch from the student records if branchId is empty or 'all'
          // if (branchId.isEmpty && !isAdmin) return _EmptyState(onLogout: _logout, message: 'Branch missing');

          if (isAdmin) {
            final effectiveBranchId = (branchId.isNotEmpty && branchId != 'all') ? branchId : (_selectedBranchId ?? '');
            debugPrint("[Diagnostic] MadrassaGuardianScreen Admin - effectiveBranchId: $effectiveBranchId, previewStudentId: $_adminPreviewStudentId, dialogShown: $_dialogShown");
            if (effectiveBranchId.isEmpty) {
              if (!_autoBranchDialogTriggered) {
                _autoBranchDialogTriggered = true;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _showBranchPickerDialog(context);
                });
              }
              return _AdminSelectionPlaceholder(
                title: context.t('Select Branch'),
                subtitle: context.t('Please select a branch to preview the Guardian Portal.'),
                buttonText: context.t('Select Branch'),
                onButtonPressed: () => _showBranchPickerDialog(context),
                onLogout: _logout,
              );
            }

            if (_adminPreviewStudentId == null) {
              if (!_autoStudentDialogTriggered) {
                _autoStudentDialogTriggered = true;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _showStudentPickerDialog(context, effectiveBranchId);
                });
              }
              return _AdminSelectionPlaceholder(
                title: context.t('Select Student'),
                subtitle: '${context.t('Branch')}: ${branchId != 'all' && branchId.isNotEmpty ? branchId : (_selectedBranchName ?? '')}\n${context.t('Please select a student to preview their report card.')}',
                buttonText: context.t('Select Student'),
                onButtonPressed: () => _showStudentPickerDialog(context, effectiveBranchId),
                onLogout: _logout,
                onChangeBranch: (branchId == 'all' || branchId.isEmpty)
                    ? () {
                        setState(() {
                          _selectedBranchId = null;
                          _selectedBranchName = null;
                          _autoBranchDialogTriggered = false;
                          _autoStudentDialogTriggered = false;
                        });
                      }
                    : null,
                changeBranchText: context.t('Change Branch'),
              );
            }
            return Stack(
              children: [
                ParentReportCard(
                  branchId: effectiveBranchId,
                  studentId: _adminPreviewStudentId!,
                  studentData: _adminPreviewStudentData!,
                  allDocs: const [],
                  selectedIndex: 0,
                  onStudentChanged: (_) {},
                  onBackToSummary: null,
                  onLogout: null,
                  isParentView: false,
                ),
                Positioned(
                  top: MediaQuery.of(context).padding.top + 8,
                  left: 12,
                  child: _AdminStudentSwitchButton(
                    onTap: () {
                      _dialogShown = false;
                      _autoStudentDialogTriggered = false;
                      setState(() => _adminPreviewStudentId = null);
                    },
                    studentName: _adminPreviewStudentData?['name'] ?? '',
                  ),
                ),
              ],
            );
          }
          // ── Regular guardian path ──
          final dynamic rawIds = widget.userData['studentIds'] ?? widget.userData['studentId'];
          final Set<String> uniqueIds = {};
          final List<String> studentIds = [];
          if (rawIds is List) {
            for (final id in rawIds) {
              final s = id?.toString().trim() ?? '';
              if (s.isNotEmpty && uniqueIds.add(s)) {
                studentIds.add(s);
              }
            }
          } else if (rawIds is String && rawIds.trim().isNotEmpty) {
            studentIds.add(rawIds.trim());
          }

          debugPrint("[Diagnostic] MadrassaGuardianScreen Guardian - branchId: $branchId, studentIds: $studentIds");
          if (studentIds.isEmpty) return _EmptyState(onLogout: _logout);

          return FutureBuilder<List<DocumentSnapshot>>(
            future: _studentsFuture ??= _fetchStudents(branchId, studentIds),
            builder: (context, allSnap) {
              debugPrint("[Diagnostic] MadrassaGuardianScreen fetchStudents - connectionState: ${allSnap.connectionState}, hasData: ${allSnap.hasData}, hasError: ${allSnap.hasError}, error: ${allSnap.error}");
              if (allSnap.connectionState == ConnectionState.waiting) return _LoadingScreen();
              if (allSnap.hasError) return _EmptyState(onLogout: _logout, message: 'Error loading data');
              final Map<String, DocumentSnapshot> uniqueDocs = {};
              for (final doc in allSnap.data ?? []) {
                if (doc.exists && !uniqueDocs.containsKey(doc.id)) {
                  uniqueDocs[doc.id] = doc;
                }
              }
              final allDocs = uniqueDocs.values.toList();
              if (allDocs.isEmpty) return _EmptyState(onLogout: _logout);

              final selectedDoc = _selectedIndex < allDocs.length ? allDocs[_selectedIndex] : allDocs.first;
              if (!selectedDoc.exists) return _EmptyState(onLogout: _logout);
              final studentData = selectedDoc.data() as Map<String, dynamic>;

              final rawStudentBranch = (studentData['branchId']?.toString().trim().isNotEmpty == true)
                  ? studentData['branchId'].toString().trim()
                  : (branchId.isNotEmpty ? branchId : 'gujrat');
              final normStudentBranch = MadrassaLocalStorage.normalizeBranch(rawStudentBranch);
              final studentBranch = (normStudentBranch.isEmpty || normStudentBranch == 'all') ? 'gujrat' : normStudentBranch;

              return RefreshIndicator(
                onRefresh: _refreshData,
                child: _showDetailed || allDocs.length == 1
                    ? ParentReportCard(
                        branchId: studentBranch,
                        studentId: selectedDoc.id,
                        studentData: studentData,
                        allDocs: allDocs,
                        selectedIndex: _selectedIndex,
                        onStudentChanged: (i) => setState(() => _selectedIndex = i),
                        onBackToSummary: allDocs.length > 1 ? () => setState(() => _showDetailed = false) : null,
                        onLogout: _logout,
                        isParentView: true,
                      )
                    : _FamilySummaryView(
                        branchId: branchId,
                        allDocs: allDocs,
                        onViewDetails: (index) {
                          setState(() {
                            _selectedIndex = index;
                            _showDetailed = true;
                          });
                        },
                        onLogout: _logout,
                        langCode: _langCode,
                        onSelectLanguage: _selectLanguage,
                        userData: widget.userData,
                      ),
              );
            },
          );
        }
      ),
    ));
  }
}

// ── Full-screen language picker ───────────────────────────────────────────────
class _LanguagePickerScreen extends StatelessWidget {
  final Future<void> Function(String) onSelect;
  const _LanguagePickerScreen({required this.onSelect});

  @override
  Widget build(BuildContext context) {
    if (!Hive.isBoxOpen('app_settings')) {
      return FutureBuilder<Box>(
        future: LocalStorageService.ensureBoxOpen('app_settings'),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Scaffold(
              body: Center(child: CircularProgressIndicator(color: context.adapt(SoftPalette.teal600))),
            );
          }
          return _buildPickerContent(context, snapshot.data!);
        },
      );
    }
    return _buildPickerContent(context, Hive.box('app_settings'));
  }

  Widget _buildPickerContent(BuildContext context, Box appSettingsBox) {
    return ValueListenableBuilder(
      valueListenable: appSettingsBox.listenable(keys: ['is_dark_mode']),
      builder: (context, Box box, _) {
        final isDark = box.get('is_dark_mode', defaultValue: false) == true;
        final brand = Theme.of(context).colorScheme.primary;
        final bg = Theme.of(context).scaffoldBackgroundColor;
        final cardBg = Theme.of(context).cardColor;
        final textPrimary = isDark ? SoftPalette.gray50 : SoftPalette.slate800;
        final textMuted = isDark ? SoftPalette.slate350 : SoftPalette.slate550;
        final border = Theme.of(context).dividerColor.withValues(alpha: isDark ? 0.5 : 0.7);

        return Scaffold(
          backgroundColor: bg,
          body: Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 420),
              margin: const EdgeInsets.all(32),
              padding: const EdgeInsets.all(36),
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: border),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Icon
                  Container(
                    width: 68,
                    height: 68,
                    decoration: BoxDecoration(
                      color: brand.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.language_rounded, size: 34, color: brand),
                  ),
                  const SizedBox(height: 24),
                  // App Title
                  Text(
                    'Gulzar Madina Madrassa',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: textPrimary,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Select your preferred language\nاپنی زبان منتخب کریں',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13.5,
                      color: textMuted,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 32),
                  // English button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => onSelect('en'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: brand,
                        foregroundColor: SoftPalette.gray50,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        elevation: 0,
                      ),
                      child: const Text('English', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Urdu button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => onSelect('ur'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isDark ? SoftPalette.slate700 : SoftPalette.slate100,
                        foregroundColor: textPrimary,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        elevation: 0,
                      ),
                      child: const Text('اردو', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, fontFamily: 'Noori')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AdminStudentSwitchButton extends StatelessWidget {
  final VoidCallback onTap;
  final String studentName;
  const _AdminStudentSwitchButton({required this.onTap, required this.studentName});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: context.adapt(SoftPalette.teal600).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.adapt(SoftPalette.teal600).withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.school, size: 20, color: context.adapt(SoftPalette.teal600)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Viewing: $studentName',
              style: TextStyle(fontWeight: FontWeight.w600, color: context.adapt(SoftPalette.teal600)),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton.icon(
            onPressed: onTap,
            icon: const Icon(Icons.swap_horiz, size: 18),
            label: const Text('Switch'),
            style: TextButton.styleFrom(
              foregroundColor: context.adapt(SoftPalette.teal600),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
          ),
        ],
      ),
    );
  }
}

class _LoadingScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    if (!Hive.isBoxOpen('app_settings')) {
      return Scaffold(
        backgroundColor: context.adapt(SoftPalette.gray50),
        body: Center(child: CircularProgressIndicator(color: context.adapt(SoftPalette.teal600))),
      );
    }
    return ValueListenableBuilder(
      valueListenable: Hive.box('app_settings').listenable(keys: ['is_dark_mode']),
      builder: (context, Box box, _) {
        final isDark = box.get('is_dark_mode', defaultValue: false) == true;
        return Scaffold(
          backgroundColor: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
          body: Center(child: CircularProgressIndicator(color: context.adapt(SoftPalette.teal600))),
        );
      },
    );
  }
}

class _FamilySummaryView extends StatefulWidget {
  final String branchId;
  final List<DocumentSnapshot> allDocs;
  final ValueChanged<int> onViewDetails;
  final VoidCallback onLogout;
  final String? langCode;
  final Function(String) onSelectLanguage;

  final Map<String, dynamic>? userData;

  const _FamilySummaryView({
    required this.branchId,
    required this.allDocs,
    required this.onViewDetails,
    required this.onLogout,
    required this.langCode,
    required this.onSelectLanguage,
    this.userData,
  });

  @override
  State<_FamilySummaryView> createState() => _FamilySummaryViewState();
}

class _FamilySummaryViewState extends State<_FamilySummaryView> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // Reimagined 2026-11-21: same look as the teacher screens (theme colours,
  // flat bordered rows). One row per child with today's status; tap to open.
  @override
  Widget build(BuildContext context) {
    final uKey = (widget.userData?['username'] ?? widget.userData?['uid'] ?? widget.userData?['id'] ?? widget.userData?['email'])?.toString();
    return MadrassaThemeScope(
      userKey: uKey,
      role: widget.userData?['role']?.toString(),
      child: Builder(builder: (context) {
        final theme = Theme.of(context);
        return Theme(
          data: theme.copyWith(textTheme: theme.textTheme.apply(fontFamilyFallback: const ['Noori'])),
          child: DefaultTextStyle.merge(
            style: const TextStyle(fontFamilyFallback: ['Noori']),
            child: _buildFamily(context),
          ),
        );
      }),
    );
  }

  String _guardianLine(BuildContext context) {
    final urdu = context.isUrdu;
    for (final doc in widget.allDocs) {
      final d = doc.data() as Map<String, dynamic>?;
      final g = (d?['guardianName'] ?? d?['guardianFullName'] ?? d?['fatherName'])?.toString().trim();
      if (g != null && g.isNotEmpty) return urdu ? 'سرپرست: $g' : 'Guardian: $g';
    }
    final uName = (widget.userData?['name'] ?? widget.userData?['username'] ?? '').toString();
    if (uName.isNotEmpty) return urdu ? 'سرپرست: $uName' : 'Guardian: $uName';
    return urdu ? 'سرپرست پورٹل' : 'Guardian Portal';
  }

  Future<void> _refresh() async {
    final sIds = widget.allDocs.map((d) => d.id).toList();
    await MadrassaLocalStorage.downloadStudentsForGuardian(widget.branchId, sIds);
    final now = DateTime.now();
    await MadrassaLocalStorage.downloadLogsForMonth(widget.branchId, now.year, now.month, force: true);
    if (mounted) setState(() {});
  }

  Widget _avatar(BuildContext context, Map<String, dynamic> d, double size) {
    final c = context.comfort;
    final name = (d['name'] ?? '').toString();
    final raw = (d['photoBase64'] ?? d['photoUrl'] ?? d['studentPhotoBase64'] ?? d['photo'])?.toString().trim();
    final bytes = ImageUploadService.decodeBase64ToBytes(raw);
    final letter = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.brandSoft, shape: BoxShape.circle),
      child: (name.isEmpty || RegExp(r'[\u0600-\u06FF]').hasMatch(name))
          ? Icon(Icons.person_rounded, size: size * 0.55, color: c.brand)
          : Text(name.characters.first, style: TextStyle(color: c.brand, fontWeight: FontWeight.w700, fontSize: size * 0.42)),
    );
    if (bytes != null) {
      return ClipOval(child: Image.memory(bytes, width: size, height: size, fit: BoxFit.cover, cacheWidth: (size * 3).round(), errorBuilder: (_, _, _) => letter));
    }
    if (raw != null && raw.startsWith('http')) {
      return ClipOval(child: Image.network(raw, width: size, height: size, fit: BoxFit.cover, errorBuilder: (_, _, _) => letter));
    }
    return letter;
  }

  Widget _buildFamily(BuildContext context) {
    final c = context.comfort;
    final urdu = context.isUrdu;
    final hosted = HomeModuleHost.isModuleRoot(context);
    final uKey = (widget.userData?['username'] ?? widget.userData?['uid'] ?? widget.userData?['id'] ?? widget.userData?['email'])?.toString();
    final now = DateTime.now();
    final todayKey = DateFormat('yyyy-MM-dd').format(now);

    final q = _searchQuery.toLowerCase();
    final docs = [
      for (final (i, doc) in widget.allDocs.indexed)
        if (q.isEmpty ||
            '${(doc.data() as Map?)?['name'] ?? ''} ${(doc.data() as Map?)?['rollNumber'] ?? ''}'.toLowerCase().contains(q))
          (i, doc),
    ];

    final menu = PopupMenuButton<String>(
      tooltip: urdu ? 'مزید' : 'Menu',
      icon: Icon(Icons.more_vert_rounded, color: c.textSecondary),
      onSelected: (v) async {
        if (v == 'refresh') {
          await _refresh();
        } else if (v.startsWith('lang:')) {
          widget.onSelectLanguage(v.substring(5));
        } else if (v == 'appearance') {
          await AppearanceDialog.show(context, userKey: uKey);
          if (mounted) setState(() {});
        } else if (v == 'logout') {
          widget.onLogout();
        }
      },
      itemBuilder: (_) {
        PopupMenuItem<String> item(String v, IconData icon, String t, {Color? color, bool checked = false}) => PopupMenuItem<String>(
              value: v,
              height: 42,
              child: Row(children: [
                Icon(icon, size: 18, color: color ?? c.brand),
                const SizedBox(width: 10),
                Expanded(child: Text(t, style: TextStyle(color: color, fontSize: 13.5))),
                if (checked) Icon(Icons.check_rounded, size: 18, color: c.brand),
              ]),
            );
        return [
          item('refresh', Icons.sync_rounded, urdu ? 'تازہ معلومات لائیں' : 'Refresh data'),
          const PopupMenuDivider(),
          item('lang:ur', Icons.translate_rounded, 'اردو', checked: widget.langCode == 'ur'),
          item('lang:en', Icons.translate_rounded, 'English', checked: widget.langCode != 'ur'),
          item('appearance', Icons.palette_outlined, urdu ? 'تھیم اور ظاہری شکل' : 'Theme & Appearance'),
          const PopupMenuDivider(),
          item('logout', Icons.logout_rounded, urdu ? 'لاگ آؤٹ' : 'Sign out', color: c.danger),
        ];
      },
    );

    Widget statusChip(IconData icon, String text, Color color) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
          ]),
        );

    Widget childRow(int index, DocumentSnapshot doc) {
      final d = (doc.data() as Map<String, dynamic>?) ?? {};
      final name = (d['name'] ?? '').toString();
      final rawB = (d['branchId'] ?? widget.branchId).toString();
      final b = MadrassaLocalStorage.normalizeBranch(rawB.isEmpty ? widget.branchId : rawB);
      final todayLog = MadrassaLocalStorage.getDailyLogCached(b, todayKey)?[doc.id];
      final log = todayLog is Map ? Map<String, dynamic>.from(todayLog) : <String, dynamic>{};
      final att = (log['attendance'] ?? '').toString();
      final late = log['isLate'] == true || log['timing'] == 'late';
      final replied = log['parentReplied'] == true;
      final nazra = d['isNazra'] == true || d['program']?.toString().toLowerCase() == 'nazra';
      final roll = (d['rollNumber'] ?? d['rollNo'] ?? '').toString();

      // This month's attendance
      int present = 0, marked = 0;
      for (final day in MadrassaLocalStorage.getLogsForMonthCached(b, now.year, now.month)) {
        final e = day[doc.id];
        if (e is! Map) continue;
        final a = (e['attendance'] ?? '').toString();
        if (a.isEmpty) continue;
        marked++;
        if (a == 'present' || a == 'leave') present++;
      }
      final pct = marked == 0 ? null : (present * 100 / marked).round();

      final Widget status;
      if (now.weekday == DateTime.sunday) {
        status = statusChip(Icons.beach_access_rounded, urdu ? 'آج چھٹی' : 'Holiday today', c.info);
      } else if (att == 'present') {
        status = statusChip(Icons.check_circle_rounded, late ? (urdu ? 'حاضر، دیر سے' : 'Present, late') : (urdu ? 'آج حاضر' : 'Present today'),
            late ? c.warning : c.success);
      } else if (att == 'absent') {
        status = statusChip(Icons.cancel_rounded, urdu ? 'آج غیر حاضر' : 'Absent today', c.danger);
      } else if (att == 'leave') {
        status = statusChip(Icons.event_available_rounded, urdu ? 'رخصت پر' : 'On leave', c.info);
      } else if (att == 'leave_requested') {
        status = statusChip(Icons.hourglass_top_rounded, urdu ? 'رخصت زیر غور' : 'Leave requested', c.warning);
      } else {
        status = statusChip(Icons.schedule_rounded, urdu ? 'حاضری باقی' : 'Not marked yet', c.textMuted);
      }

      return InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => widget.onViewDetails(index),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.border)),
          child: Row(children: [
            _avatar(context, d, 52),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    strutStyle: const StrutStyle(fontSize: 16, height: 1.4, forceStrutHeight: true),
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.textPrimary)),
                Text(
                  [
                    nazra ? (urdu ? 'ناظرہ' : 'Nazra') : (urdu ? 'حفظ' : 'Hifz'),
                    if (roll.isNotEmpty) '${urdu ? 'رول' : 'Roll'} $roll',
                    if (pct != null) urdu ? 'اس مہینے حاضری $pct٪' : 'Attendance this month $pct%',
                  ].join('  ·  '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: c.textMuted),
                ),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  status,
                  if ((att == 'present' || att == 'absent') && !replied)
                    statusChip(Icons.chat_rounded, urdu ? 'استاد کو جواب باقی' : 'Reply to teacher', c.brand),
                ]),
              ]),
            ),
            Icon(Icons.chevron_right_rounded, color: c.textMuted),
          ]),
        ),
      );
    }

    return Scaffold(
      backgroundColor: c.background,
      appBar: hosted
          ? null
          : AppBar(
              backgroundColor: c.surface,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              titleSpacing: 12,
              automaticallyImplyLeading: false,
              shape: Border(bottom: BorderSide(color: c.border)),
              title: Row(children: [
                Image.asset('assets/logo/gmwf-1.webp', height: 32),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(urdu ? 'گلزار مدینہ مدرسہ' : 'Gulzar Madina Madrassa',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c.textPrimary)),
                    Text(_guardianLine(context), overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: c.textMuted)),
                  ]),
                ),
              ]),
              actions: [menu, const SizedBox(width: 4)],
            ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                  child: Text(urdu ? 'آپ کے بچے' : 'Your children',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: c.textPrimary)),
                ),
                if (widget.allDocs.length > 4) ...[
                  TextField(
                    controller: _searchCtrl,
                    onChanged: (v) => setState(() => _searchQuery = v),
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                      hintText: urdu ? 'نام یا رول نمبر تلاش کریں' : 'Search name or roll no.',
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                for (final (i, doc) in docs) ...[childRow(i, doc), const SizedBox(height: 10)],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onLogout;
  final String? message;
  const _EmptyState({required this.onLogout, this.message});

  @override
  Widget build(BuildContext context) {
    if (!Hive.isBoxOpen('app_settings')) {
      return Scaffold(
        backgroundColor: context.adapt(SoftPalette.gray50),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.link_off_rounded, size: 64, color: context.adapt(SoftPalette.teal600)),
                const SizedBox(height: 24),
                Text(
                  context.t('Account Not Linked'),
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: context.adapt(SoftPalette.slate800), fontFamily: context.isUrdu ? 'Noori' : null),
                ),
                const SizedBox(height: 8),
                Text(
                  context.t(message ?? 'Your account is not linked to any student.'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.adapt(SoftPalette.gray350), fontFamily: context.isUrdu ? 'Noori' : null),
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: onLogout,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: SoftPalette.teal600,
                      foregroundColor: SoftPalette.gray50,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(context.t('Back to Login'), style: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null)),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return ValueListenableBuilder(
      valueListenable: Hive.box('app_settings').listenable(keys: ['is_dark_mode']),
      builder: (context, Box box, _) {
        final isDark = box.get('is_dark_mode', defaultValue: false) == true;
        final bg = isDark ? SoftPalette.slate900 : SoftPalette.gray50;
        final textPrimary = isDark ? SoftPalette.gray50 : SoftPalette.slate800;
        final textMuted = isDark ? SoftPalette.slate350 : SoftPalette.gray350;

        return Scaffold(
          backgroundColor: bg,
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.link_off_rounded, size: 64, color: context.adapt(SoftPalette.teal600)),
                  const SizedBox(height: 24),
                  Text(
                    context.t('Account Not Linked'),
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: textPrimary, fontFamily: context.isUrdu ? 'Noori' : null),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    context.t(message ?? 'Your account is not linked to any student.'),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: textMuted, fontFamily: context.isUrdu ? 'Noori' : null),
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: onLogout,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: SoftPalette.teal600,
                        foregroundColor: SoftPalette.gray50,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text(context.t('Back to Login'), style: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AdminSelectionPlaceholder extends StatelessWidget {
  final String title;
  final String subtitle;
  final String buttonText;
  final VoidCallback onButtonPressed;
  final VoidCallback onLogout;
  final VoidCallback? onChangeBranch;
  final String? changeBranchText;

  const _AdminSelectionPlaceholder({
    required this.title,
    required this.subtitle,
    required this.buttonText,
    required this.onButtonPressed,
    required this.onLogout,
    this.onChangeBranch,
    this.changeBranchText,
  });

  @override
  Widget build(BuildContext context) {
    if (!Hive.isBoxOpen('app_settings')) {
      return FutureBuilder<Box>(
        future: LocalStorageService.ensureBoxOpen('app_settings'),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return Scaffold(body: Center(child: CircularProgressIndicator(color: context.adapt(SoftPalette.teal600))));
          return _buildPlaceholderContent(context, snapshot.data!);
        },
      );
    }
    return _buildPlaceholderContent(context, Hive.box('app_settings'));
  }

  Widget _buildPlaceholderContent(BuildContext context, Box appSettingsBox) {
    return ValueListenableBuilder(
      valueListenable: appSettingsBox.listenable(keys: ['is_dark_mode']),
      builder: (context, Box box, _) {
        final c = context.comfort;

        return Scaffold(
          backgroundColor: c.surfaceSunken,
          body: Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 420),
              margin: const EdgeInsets.all(32),
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: MadrassaErp.cardRadius,
                border: Border.all(color: c.border),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: c.brandSoft,
                      borderRadius: MadrassaErp.radius,
                    ),
                    child: Icon(Icons.family_restroom_rounded, color: c.brand, size: 32),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: c.textPrimary),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: c.textMuted, height: 1.5),
                  ),
                  const SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: onButtonPressed,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: c.brand,
                        foregroundColor: c.onBrand,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: const RoundedRectangleBorder(borderRadius: MadrassaErp.radius),
                        elevation: 0,
                      ),
                      child: Text(buttonText, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                    ),
                  ),
                  if (onChangeBranch != null) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: onChangeBranch,
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          side: BorderSide(color: c.border),
                          shape: const RoundedRectangleBorder(borderRadius: MadrassaErp.radius),
                        ),
                        child: Text(
                          changeBranchText ?? 'Change Branch',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c.textPrimary),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: onLogout,
                      style: TextButton.styleFrom(
                        foregroundColor: c.danger,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: Text(context.t('Logout'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
