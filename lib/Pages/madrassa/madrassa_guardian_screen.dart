// lib/pages/madrassa/madrassa_guardian_screen.dart
//
// FIXES:
//  • Global-level admin/staff (non-guardian) now sees a student picker
//    dialog first when viewing the guardian portal, then renders the
//    ParentReportCard for the selected student — exactly like a guardian would see.
//  • Regular guardians continue to work as before (their linked studentIds).
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'widgets/parent_report_card.dart';
import 'madrassa_strings.dart';
import 'utils/madrassa_local_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../services/local_storage_service.dart';
import '../../services/offline_auth_service.dart';
import '../../services/image_upload_service.dart';
import '../../services/user_theme_service.dart';
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

  @override
  void initState() {
    super.initState();
    _loadLanguage();
  }

  Future<void> _loadLanguage() async {
    try {
      await MadrassaLocalStorage.ensureBoxesOpen();
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('madrassa_locale');
      if (mounted) setState(() => _langCode = saved ?? '');
    } catch (_) {
      if (mounted) setState(() => _langCode = 'en');
    }
  }

  Future<void> _selectLanguage(String code) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('madrassa_locale', code);
    } catch (_) {}
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

    // Trigger scoped download only for linked children to optimize payload & ensure privacy
    try {
      await MadrassaLocalStorage.downloadStudentsForGuardian(branchId, ids);
      final now = DateTime.now();
      MadrassaLocalStorage.downloadLogsForMonth(branchId, now.year, now.month);
      MadrassaLocalStorage.downloadHolidays(branchId);
      MadrassaLocalStorage.downloadConfig(branchId);
    } catch (_) {}

    try {
      final snaps = await Future.wait(ids.map((id) => FirebaseFirestore.instance
          .collection('branches')
          .doc(branchId)
          .collection('madrassa_students')
          .doc(id)
          .get()));
      for (final s in snaps) {
        if (s.exists && s.data() != null) {
          await MadrassaLocalStorage.cacheStudent(branchId, s.id, s.data()!);
        }
      }
      return snaps;
    } catch (e) {
      debugPrint('[MadrassaGuardianScreen] Firestore fetch failed (offline mode): $e');
      return Future.wait(ids.map((id) => FirebaseFirestore.instance
          .collection('branches')
          .doc(branchId)
          .collection('madrassa_students')
          .doc(id)
          .get(const GetOptions(source: Source.cache))));
    }
  }

  Future<void> _refreshData() async {
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
        final now = DateTime.now();
        await MadrassaLocalStorage.downloadLogsForMonth(branchId, now.year, now.month);
        await MadrassaLocalStorage.downloadHolidays(branchId);
        await MadrassaLocalStorage.downloadConfig(branchId);
      }
      await SyncService().triggerUpload();
    } catch (_) {}

    if (mounted) {
      setState(() {
        _studentsFuture = _fetchStudents(branchId, studentIds);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Text(context.t('Data updated successfully')),
            ],
          ),
          backgroundColor: const Color(0xFF0F766E),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  bool _isAdminViewing() {
    final role = (widget.userData['role'] as String? ?? '').toLowerCase();
    return role != 'madrassa guardian';
  }

  // New helper to fetch branches and show a picker when branchId is missing
  Future<void> _showBranchPickerDialog(BuildContext context) async {
    final snap = await FirebaseFirestore.instance.collection('branches').get();
    if (!mounted) return;
    final branches = snap.docs;
    if (branches.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
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
            final filtered = branches.where((doc) {
              final name = (doc.data()['name'] as String? ?? '').toLowerCase();
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
                          final doc = filtered[i];
                          final name = (doc.data()['name'] as String?) ?? 'Branch';
                          return ListTile(
                            title: Text(name),
                            onTap: () {
                              setState(() {
                                _selectedBranchId = doc.id;
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('No active students found.'))));
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
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(24), color: Colors.white),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.t('Select Student'),
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF0F6C5A)),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: searchCtrl,
                      decoration: InputDecoration(
                        hintText: context.t('Search by name or roll number...'),
                        prefixIcon: const Icon(Icons.search, color: Color(0xFF0F6C5A)),
                        filled: true,
                        fillColor: const Color(0xFFF8F9FD),
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
                                        color: const Color(0xFFF8F9FD),
                                        borderRadius: BorderRadius.circular(16),
                                        border: Border.all(color: const Color(0xFFE0E2E7)),
                                      ),
                                      child: Row(
                                        children: [
                                          CircleAvatar(
                                            radius: 22,
                                            backgroundColor: const Color(0xFF0F6C5A),
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
                                                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                                                    ),
                                                  );
                                                }
                                                return Text(
                                                  d['name']?[0] ?? '?',
                                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
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
                                                Text('Roll: ${d['rollNumber'] ?? "?"} • Guardian: ${d['guardianName'] ?? "?"}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                                              ],
                                            ),
                                          ),
                                          const Icon(Icons.chevron_right, color: Color(0xFF0F6C5A)),
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
                        icon: const Icon(Icons.logout, color: Colors.red),
                        label: Text(context.t('Logout'), style: TextStyle(color: Colors.red, fontFamily: context.isUrdu ? 'Noori' : null)),
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
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(child: CircularProgressIndicator(color: Color(0xFF0F6C5A))),
      );
    }

    // ── 2. Language not chosen yet → full-screen picker ──
    if (_langCode!.isEmpty) {
      return _LanguagePickerScreen(onSelect: _selectLanguage);
    }

    // ── 3. Language is set → render normal content ──
    return ChangeNotifierProvider(
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
          debugPrint("[Diagnostic] MadrassaGuardianScreen build - branchId: $branchId, isAdmin: $isAdmin, userData: ${widget.userData}");
          if (branchId.isEmpty && !isAdmin) return _EmptyState(onLogout: _logout, message: 'Branch missing');

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

              return _showDetailed || allDocs.length == 1
                  ? ParentReportCard(
                      branchId: branchId,
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
                    );
            },
          );
        }
      ),
    );
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
            return const Scaffold(
              body: Center(child: CircularProgressIndicator(color: Color(0xFF0F6C5A))),
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
        final bg = isDark ? const Color(0xFF0F172A) : Colors.white;
        final cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;
        final textPrimary = isDark ? Colors.white : const Color(0xFF1E293B);
        final textMuted = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
        final border = isDark ? const Color(0xFF334155) : const Color(0xFFE8EAF0);

        return Scaffold(
          backgroundColor: bg,
          body: Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 420),
              margin: const EdgeInsets.all(32),
              padding: const EdgeInsets.all(40),
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.08), blurRadius: 32, offset: const Offset(0, 8)),
                ],
                border: Border.all(color: border),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Icon
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F6C5A).withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.language_rounded, size: 38, color: Color(0xFF0F6C5A)),
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
                        backgroundColor: const Color(0xFF0F6C5A),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
                        backgroundColor: isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9),
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
        color: const Color(0xFF0F6C5A).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF0F6C5A).withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.school, size: 20, color: Color(0xFF0F6C5A)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Viewing: $studentName',
              style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF0F6C5A)),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton.icon(
            onPressed: onTap,
            icon: const Icon(Icons.swap_horiz, size: 18),
            label: const Text('Switch'),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF0F6C5A),
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
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(child: CircularProgressIndicator(color: Color(0xFF0F6C5A))),
      );
    }
    return ValueListenableBuilder(
      valueListenable: Hive.box('app_settings').listenable(keys: ['is_dark_mode']),
      builder: (context, Box box, _) {
        final isDark = box.get('is_dark_mode', defaultValue: false) == true;
        return Scaffold(
          backgroundColor: isDark ? const Color(0xFF0F172A) : Colors.white,
          body: const Center(child: CircularProgressIndicator(color: Color(0xFF0F6C5A))),
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

  @override
  Widget build(BuildContext context) {
    final branchId = widget.branchId;
    final allDocs = widget.allDocs;
    final onViewDetails = widget.onViewDetails;
    final onLogout = widget.onLogout;
    final langCode = widget.langCode;
    final onSelectLanguage = widget.onSelectLanguage;
    final userData = widget.userData;

    final title = context.t('Family Portal');
    final subtitle = context.t('Summary of children progress');

    final filteredDocs = allDocs.where((doc) {
      if (_searchQuery.isEmpty) return true;
      final d = doc.data() as Map<String, dynamic>? ?? {};
      final name = (d['name'] ?? '').toString().toLowerCase();
      final roll = (d['rollNumber'] ?? d['rollNo'] ?? '').toString().toLowerCase();
      final cls = (d['class'] ?? '').toString().toLowerCase();
      final q = _searchQuery.toLowerCase();
      return name.contains(q) || roll.contains(q) || cls.contains(q);
    }).toList();

    return ValueListenableBuilder(
      valueListenable: UserThemeService.listenable(),
      builder: (context, Box box, _) {
        final isDark = UserThemeService.isDarkMode();
        final scaffoldBg = isDark ? const Color(0xFF0F172A) : const Color(0xFFF8F9FD);
        final appBarBg = isDark ? const Color(0xFF1E293B) : const Color(0xFF0F6C5A);
        final cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;
        final textPrimary = isDark ? Colors.white : const Color(0xFF1E293B);
        final textMuted = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
        final dividerColor = isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9);
        final progressTrack = isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9);
        const accentColor = Color(0xFF0F6C5A);

        return Scaffold(
          backgroundColor: scaffoldBg,
          appBar: AppBar(
            backgroundColor: appBarBg,
            elevation: 0,
            titleSpacing: 12,
            automaticallyImplyLeading: false,
            title: Row(
              children: [
                Image.asset('assets/logo/gmwf-1.webp', height: 32),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Gulzar Madina Madrassa',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                            color: Colors.white,
                            fontFamily: context.isUrdu ? 'Noori' : null,
                          ),
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        () {
                          for (final doc in allDocs) {
                            final d = doc.data() as Map<String, dynamic>?;
                            if (d != null) {
                              final g = (d['guardianName'] ?? d['guardianFullName'] ?? d['fatherName'])?.toString().trim();
                              if (g != null && g.isNotEmpty) {
                                return context.isUrdu ? 'سرپرست: $g' : 'Guardian: $g';
                              }
                            }
                          }
                          final uName = userData?['name'] ?? userData?['username'] ?? '';
                          if (uName.toString().isNotEmpty) {
                            return context.isUrdu ? 'سرپرست: $uName' : 'Guardian: $uName';
                          }
                          return context.isUrdu ? 'پورٹل سرپرست' : 'Guardian Portal';
                        }(),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w500,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              // Refresh / Sync button
              IconButton(
                icon: const Icon(Icons.sync_rounded, color: Colors.white, size: 20),
                tooltip: context.isUrdu ? 'تازہ ترین معلومات حاصل کریں' : 'Download Latest Updates',
                onPressed: () async {
                  final sIds = allDocs.map((d) => d.id).toList();
                  await MadrassaLocalStorage.downloadStudentsForGuardian(branchId, sIds);
                  final now = DateTime.now();
                  await MadrassaLocalStorage.downloadLogsForMonth(branchId, now.year, now.month);
                  if (mounted) setState(() {});
                },
              ),
              // Dark Mode Toggle
              IconButton(
                icon: Icon(
                  isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                  color: isDark ? const Color(0xFFFDE047) : Colors.white,
                  size: 20,
                ),
                tooltip: isDark ? (context.isUrdu ? 'لائٹ موڈ' : 'Light Mode') : (context.isUrdu ? 'ڈارک موڈ' : 'Dark Mode'),
                onPressed: () async {
                  await UserThemeService.toggleDarkMode();
                },
              ),
              // Language selector
              TextButton(
                onPressed: () => onSelectLanguage(langCode == 'ur' ? 'en' : 'ur'),
                child: Text(
                  langCode == 'ur' ? 'English' : 'اردو',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontFamily: langCode != 'ur' ? 'Noori' : null,
                  ),
                ),
              ),
            ],
          ),
          body: Stack(
            fit: StackFit.expand,
            children: [
              // ── Islamic Pattern Background ──
              Positioned.fill(
                child: Opacity(
                  opacity: isDark ? 0.085 : 0.11,
                  child: Image.asset(
                    'assets/images/islamic_pattern.webp',
                    fit: BoxFit.cover,
                    repeat: ImageRepeat.repeat,
                    color: const Color(0xFFD4AF37),
                    colorBlendMode: BlendMode.srcIn,
                  ),
                ),
              ),
              Center(
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 800),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 8),
                        child: Text(
                          subtitle,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: textMuted,
                            fontFamily: context.isUrdu ? 'Noori' : null,
                          ),
                        ),
                      ),
                      if (allDocs.length > 1) ...[
                        Container(
                          margin: const EdgeInsets.only(bottom: 12, left: 8, right: 8),
                          decoration: BoxDecoration(
                            color: cardBg,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
                            boxShadow: [
                              BoxShadow(color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.03), blurRadius: 8, offset: const Offset(0, 2)),
                            ],
                          ),
                          child: TextField(
                            controller: _searchCtrl,
                            onChanged: (val) => setState(() => _searchQuery = val.trim()),
                            style: TextStyle(color: textPrimary, fontSize: 13),
                            decoration: InputDecoration(
                              hintText: context.isUrdu ? 'بچے کا نام یا رول نمبر تلاش کریں...' : 'Search student by name or roll number...',
                              hintStyle: TextStyle(color: textMuted, fontSize: 13, fontFamily: context.isUrdu ? 'Noori' : null),
                              prefixIcon: Icon(Icons.search_rounded, color: textMuted, size: 20),
                              suffixIcon: _searchQuery.isNotEmpty
                                  ? IconButton(
                                      icon: const Icon(Icons.clear_rounded, size: 18),
                                      onPressed: () {
                                        _searchCtrl.clear();
                                        setState(() => _searchQuery = '');
                                      },
                                    )
                                  : null,
                              border: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            ),
                          ),
                        ),
                      ],
                      Expanded(
                    child: ValueListenableBuilder(
                      valueListenable: Hive.box(MadrassaLocalStorage.logsBox).listenable(),
                      builder: (context, Box box, _) {
                        final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
                        final Map<String, dynamic> todayLogData = MadrassaLocalStorage.getDailyLogCached(branchId, todayStr) ?? {};
                        final logsDocs = <Map<String, dynamic>>[];
                        for (final key in box.keys) {
                          final val = box.get(key);
                          if (val is Map) {
                            final m = Map<String, dynamic>.from(val);
                            m['id'] = key.toString();
                            logsDocs.add(m);
                          }
                        }

                        return RefreshIndicator(
                          onRefresh: () async {
                            final sIds = allDocs.map((dynamic d) => (d is Map ? (d['id'] ?? d['studentId']) : d.id).toString()).toList();
                            await MadrassaLocalStorage.downloadStudentsForGuardian(branchId, sIds);
                            final now = DateTime.now();
                            await MadrassaLocalStorage.downloadLogsForMonth(branchId, now.year, now.month);
                            if (mounted) setState(() {});
                          },
                          child: ListView.separated(
                            physics: const AlwaysScrollableScrollPhysics(),
                            itemCount: filteredDocs.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 16),
                            itemBuilder: (ctx, index) {
                              final dynamic doc = filteredDocs[index];
                              final d = doc is Map ? Map<String, dynamic>.from(doc) : (doc.data() as Map<String, dynamic>? ?? {});
                              final studentId = (doc is Map ? (doc['id'] ?? doc['studentId']) : doc.id)?.toString() ?? '';
                              final name = d['name'] ?? 'Student';
                              final rollNumber = d['rollNumber'] ?? '?';
                              final className = d['class'] ?? 'Hifz';
                              final photoUrl = (d['photoBase64'] ??
                                      d['photoUrl'] ??
                                      d['photo'] ??
                                      d['image'] ??
                                      d['studentPhotoBase64'])
                                  ?.toString();

                              int maxLogLines = 0;
                              int sumSabakLogs = 0;
                              for (var logDoc in logsDocs) {
                                final map = logDoc;
                                final sLog = map[studentId] as Map<String, dynamic>?;
                                if (sLog != null) {
                                  final sL = (sLog['sabakLines'] as num?)?.toInt() ?? int.tryParse(sLog['sabakLines']?.toString() ?? '');
                                  if (sL != null && sL > 0) sumSabakLogs += sL;
                                  final cL = (sLog['currentLines'] as num?)?.toInt() ?? int.tryParse(sLog['currentLines']?.toString() ?? '');
                                  if (cL != null && cL > maxLogLines) maxLogLines = cL;
                                }
                              }
                              final currentLinesProfile = int.tryParse(d['currentLines']?.toString() ?? '0') ?? 0;
                              final currentLines = [currentLinesProfile, maxLogLines, sumSabakLogs].reduce(math.max);
                              final prevLines = int.tryParse(d['prevHifzLines']?.toString() ?? '0') ?? 0;
                              final totalMemorized = (currentLines + prevLines).clamp(0, 8640);
                              const total = 8640;
                              final pct = totalMemorized / total;

                              final todayStudentLog = todayLogData[studentId] as Map<String, dynamic>?;

                              int sabakDelta = 0;
                              bool hasSabak = false;
                              if (todayStudentLog != null) {
                                hasSabak = true;
                                if (todayStudentLog.containsKey('sabakLines') && todayStudentLog['sabakLines'] != null) {
                                  sabakDelta = (todayStudentLog['sabakLines'] as num?)?.toInt() ?? 0;
                                } else if (todayStudentLog.containsKey('currentLines')) {
                                  final todayCumulativeLines = todayStudentLog['currentLines'] as int? ?? currentLines;
                                  int prevCumulativeLines = -1;
                                  for (var logDoc in logsDocs) {
                                    if (logDoc['id'] == todayStr) continue;
                                    final map = logDoc;
                                    final sLog = map[studentId] as Map<String, dynamic>?;
                                    if (sLog != null && sLog.containsKey('currentLines')) {
                                      prevCumulativeLines = sLog['currentLines'] as int? ?? 0;
                                      break;
                                    }
                                  }
                                  if (prevCumulativeLines == -1) {
                                    prevCumulativeLines = prevLines;
                                  }
                                  sabakDelta = (todayCumulativeLines - prevCumulativeLines).clamp(0, 8640);
                                }
                              }

                              final hasTodayLog = todayStudentLog != null;
                              final attendance = todayStudentLog?['attendance']?.toString() ?? 'unknown';
                              final uniformOk = todayStudentLog?['uniform'] == true;
                              final replied = todayStudentLog?['parentReplied'] == true;
                              final sabkiPara = todayStudentLog?['sabkiPara'] as int? ?? 0;
                              final sabkiRatio = todayStudentLog?['sabkiRatio']?.toString() ?? '-';
                              final manzilPara = todayStudentLog?['manzilPara'] as int? ?? 0;
                              final manzilRatio = todayStudentLog?['manzilRatio']?.toString() ?? '-';

                              String formatRatio(String? ratio) {
                                if (ratio == '1/4') return context.t('Pao (1/4)');
                                if (ratio == '1/2') return context.t('Nisf (1/2)');
                                if (ratio == '3/4') return context.t('Salasa (3/4)');
                                if (ratio == '1') return context.t('Para (1)');
                                if (ratio == 'nahi_sunaya') return context.isUrdu ? 'نہیں سنایا' : 'Nahi Sunaya';
                                return ratio ?? '';
                              }

                              Widget buildStatusChip({
                                required IconData icon,
                                required String label,
                                required Color color,
                                required Color textColor,
                              }) {
                                return Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: color.withValues(alpha: isDark ? 0.2 : 0.1),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: color.withValues(alpha: isDark ? 0.4 : 0.2)),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(icon, size: 14, color: color),
                                      const SizedBox(width: 4),
                                      Text(
                                        label,
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: isDark ? Colors.white : textColor,
                                          fontFamily: context.isUrdu ? 'Noori' : null,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }

                              return Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: cardBg,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
                                  boxShadow: [
                                    BoxShadow(color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04), blurRadius: 8, offset: const Offset(0, 2)),
                                  ],
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      crossAxisAlignment: CrossAxisAlignment.center,
                                      children: [
                                        CircleAvatar(
                                          radius: 24,
                                          backgroundColor: accentColor.withValues(alpha: 0.1),
                                          backgroundImage: (photoUrl != null && photoUrl.isNotEmpty) ? NetworkImage(photoUrl) : null,
                                          child: (photoUrl == null || photoUrl.isEmpty)
                                              ? Text(name.isNotEmpty ? name[0] : 'S', style: const TextStyle(color: accentColor, fontWeight: FontWeight.bold, fontSize: 18))
                                              : null,
                                        ),
                                        const SizedBox(width: 16),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                name,
                                                style: TextStyle(
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.bold,
                                                  color: textPrimary,
                                                  fontFamily: context.isUrdu ? 'Noori' : null,
                                                ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                '${context.t('Roll No')}: $rollNumber  •  $className',
                                                style: TextStyle(fontSize: 12, color: textMuted),
                                              ),
                                              const SizedBox(height: 8),
                                              Row(
                                                children: [
                                                  Expanded(
                                                    child: ClipRRect(
                                                      borderRadius: BorderRadius.circular(4),
                                                      child: LinearProgressIndicator(
                                                        value: pct.clamp(0.0, 1.0),
                                                        backgroundColor: progressTrack,
                                                        color: accentColor,
                                                        minHeight: 8,
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 12),
                                                  Text(
                                                    '${(pct * 100).toStringAsFixed(1)}%',
                                                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: textPrimary),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                context.isUrdu 
                                                    ? 'کل $total میں سے لائن $totalMemorized مکمل'
                                                    : 'Line $totalMemorized of $total completed',
                                                style: TextStyle(color: textMuted, fontSize: 12, fontFamily: context.isUrdu ? 'Noori' : null),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 16),
                                        ElevatedButton(
                                          onPressed: () {
                                            final origIndex = allDocs.indexOf(doc);
                                            onViewDetails(origIndex >= 0 ? origIndex : index);
                                          },
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: accentColor,
                                            foregroundColor: Colors.white,
                                            elevation: 0,
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                          ),
                                          child: Text(context.t('View Details')),
                                        ),
                                      ],
                                    ),
                                  
                                  Divider(height: 24, color: dividerColor),
                                  Text(
                                    context.t("Today's Progress"),
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569),
                                      fontFamily: context.isUrdu ? 'Noori' : null,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  if (!hasTodayLog)
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                                      decoration: BoxDecoration(
                                        color: isDark ? const Color(0xFF334155).withValues(alpha: 0.5) : Colors.grey.shade50,
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(color: isDark ? const Color(0xFF475569) : Colors.grey.shade200),
                                      ),
                                      child: Text(
                                        context.isUrdu 
                                            ? 'آج کی کارکردگی ابھی اپ ڈیٹ نہیں ہوئی'
                                            : 'Today\'s details not updated yet by teacher',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: textMuted,
                                          fontStyle: FontStyle.italic,
                                          fontFamily: context.isUrdu ? 'Noori' : null,
                                        ),
                                      ),
                                    )
                                  else ...[
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: [
                                        if (attendance == 'present')
                                          buildStatusChip(
                                            icon: Icons.check_circle_outline,
                                            label: context.t('Present'),
                                            color: const Color(0xFF10B981),
                                            textColor: const Color(0xFF065F46),
                                          )
                                        else if (attendance == 'leave')
                                          buildStatusChip(
                                            icon: Icons.mail_outline,
                                            label: context.t('On Leave'),
                                            color: Colors.orange,
                                            textColor: Colors.orange.shade900,
                                          )
                                        else if (attendance == 'leave_requested')
                                          buildStatusChip(
                                            icon: Icons.mail_outline,
                                            label: context.t('Leave Requested'),
                                            color: Colors.amber.shade700,
                                            textColor: Colors.amber.shade900,
                                          )
                                        else
                                          buildStatusChip(
                                            icon: Icons.cancel_outlined,
                                            label: context.t('Absent'),
                                            color: const Color(0xFFEF4444),
                                            textColor: const Color(0xFF991B1B),
                                          ),
                                        
                                        if (attendance == 'present') ...[
                                          buildStatusChip(
                                            icon: Icons.menu_book,
                                            label: hasSabak && sabakDelta > 0
                                                ? (context.isUrdu ? 'سبق: +$sabakDelta لائنیں' : 'Sabak: +$sabakDelta lines')
                                                : context.t('No lines recorded'),
                                            color: const Color(0xFF0F6C5A),
                                            textColor: const Color(0xFF312E81),
                                          ),
                                          
                                          buildStatusChip(
                                            icon: Icons.repeat,
                                            label: sabkiPara > 0 && sabkiRatio != '-' && sabkiRatio != 'nahi_sunaya'
                                                ? (context.isUrdu ? 'سبقی: پارہ $sabkiPara (${formatRatio(sabkiRatio)})' : 'Sabki: Para $sabkiPara (${formatRatio(sabkiRatio)})')
                                                : (sabkiRatio == 'nahi_sunaya'
                                                    ? (context.isUrdu ? 'سبقی: نہیں سنایا' : 'Sabki: Nahi Sunaya')
                                                    : (context.isUrdu ? 'سبقی: کوئی سبق نہیں' : 'Sabki: None')),
                                            color: const Color(0xFFED6C02),
                                            textColor: const Color(0xFF7E2D11),
                                          ),
                                          
                                          buildStatusChip(
                                            icon: Icons.track_changes,
                                            label: manzilPara > 0 && manzilRatio != '-' && manzilRatio != 'nahi_sunaya'
                                                ? (context.isUrdu ? 'منزل: پارہ $manzilPara (${formatRatio(manzilRatio)})' : 'Manzil: Para $manzilPara (${formatRatio(manzilRatio)})')
                                                : (manzilRatio == 'nahi_sunaya'
                                                    ? (context.isUrdu ? 'منزل: نہیں سنایا' : 'Manzil: Nahi Sunaya')
                                                    : (context.isUrdu ? 'منزل: کوئی منزل نہیں' : 'Manzil: None')),
                                            color: const Color(0xFF9C27B0),
                                            textColor: const Color(0xFF4A0E4E),
                                          ),
                                          
                                          buildStatusChip(
                                            icon: Icons.checkroom,
                                            label: uniformOk 
                                                ? context.t('Uniform: Clean') 
                                                : context.t('Uniform: Unclean'),
                                            color: uniformOk ? Colors.blue : const Color(0xFFEF4444),
                                            textColor: uniformOk ? Colors.blue.shade900 : const Color(0xFF991B1B),
                                          ),
                                          
                                          buildStatusChip(
                                            icon: Icons.reply,
                                            label: replied 
                                                ? context.t('Reply: Sent') 
                                                : context.t('Reply: Pending'),
                                            color: replied ? Colors.green : Colors.amber.shade800,
                                            textColor: replied ? Colors.green.shade900 : Colors.amber.shade900,
                                          ),
                                        ],
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            );
                          },
                        ),
                      );
                    },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
      },
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
        backgroundColor: Colors.white,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.link_off_rounded, size: 64, color: Color(0xFF0F6C5A)),
                const SizedBox(height: 24),
                Text(
                  context.t('Account Not Linked'),
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: const Color(0xFF1E293B), fontFamily: context.isUrdu ? 'Noori' : null),
                ),
                const SizedBox(height: 8),
                Text(
                  context.t(message ?? 'Your account is not linked to any student.'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey, fontFamily: context.isUrdu ? 'Noori' : null),
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: onLogout,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0F6C5A),
                      foregroundColor: Colors.white,
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
        final bg = isDark ? const Color(0xFF0F172A) : Colors.white;
        final textPrimary = isDark ? Colors.white : const Color(0xFF1E293B);
        final textMuted = isDark ? const Color(0xFF94A3B8) : Colors.grey;

        return Scaffold(
          backgroundColor: bg,
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.link_off_rounded, size: 64, color: Color(0xFF0F6C5A)),
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
                        backgroundColor: const Color(0xFF0F6C5A),
                        foregroundColor: Colors.white,
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
          if (!snapshot.hasData) return const Scaffold(body: Center(child: CircularProgressIndicator(color: Color(0xFF0F6C5A))));
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
        final isDark = box.get('is_dark_mode', defaultValue: false) == true;
        final bg = isDark ? const Color(0xFF0F172A) : Colors.white;
        final cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;
        final textPrimary = isDark ? Colors.white : const Color(0xFF1E293B);
        final textMuted = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
        final border = isDark ? const Color(0xFF334155) : const Color(0xFFE8EAF0);

        return Scaffold(
          backgroundColor: bg,
          body: Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 420),
              margin: const EdgeInsets.all(32),
              padding: const EdgeInsets.all(40),
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.08), blurRadius: 32, offset: const Offset(0, 8)),
                ],
                border: Border.all(color: border),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F6C5A).withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.family_restroom_rounded, color: Color(0xFF0F6C5A), size: 36),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: textPrimary),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: textMuted, height: 1.5),
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: onButtonPressed,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0F6C5A),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        elevation: 0,
                      ),
                      child: Text(buttonText, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    ),
                  ),
                  if (onChangeBranch != null) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: onChangeBranch,
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          side: BorderSide(color: border),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        child: Text(
                          changeBranchText ?? 'Change Branch',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: textPrimary),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: onLogout,
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.red,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: Text(context.t('Logout'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
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
