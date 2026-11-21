// lib/pages/madrassa/widgets/parent_report_card.dart

import 'dart:async';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:gmwf/pages/home/home_module_host.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';
import '../madrassa_strings.dart';
import '../models/madrassa_config.dart';
import '../models/madrassa_fee_logic.dart';
import '../widgets/madrassa_common_widgets.dart';
import '../utils/madrassa_report_helper.dart';
import '../utils/madrassa_local_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../../services/firebase_session_guard.dart';
import '../../../services/offline_auth_service.dart';
import '../../../services/local_storage_service.dart';
import '../../../services/image_upload_service.dart';
import '../../../widgets/read_only_document_tile.dart';
import 'package:lottie/lottie.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../../widgets/appearance_dialog.dart';
import 'package:gmwf_ui/gmwf_ui.dart' as ui show GTheme, GThemeChoice;
import '../../../services/user_theme_service.dart';
import '../../../services/sync_service.dart';
import '../utils/islamic_calendar_helper.dart';
import '../../../design/design_system.dart';
import '../theme/madrassa_theme_scope.dart';
import 'madrassa_erp.dart';


Map<String, dynamic>? _asStringMap(dynamic raw) {
  if (raw == null) return null;
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) return Map<String, dynamic>.from(raw);
  return null;
}

DateTime _parseDateTime(dynamic val, [DateTime? fallback]) {
  if (val == null) return fallback ?? DateTime.now();
  if (val is Timestamp) return val.toDate();
  if (val is String) {
    return DateTime.tryParse(val) ?? fallback ?? DateTime.now();
  }
  if (val is DateTime) return val;
  return fallback ?? DateTime.now();
}

class ParentReportCard extends StatefulWidget {
  final String branchId;
  final String studentId;
  final Map<String, dynamic> studentData;
  final int? year;
  final int? month;
  final VoidCallback? onLogout;
  final List<dynamic> allDocs;
  final int selectedIndex;
  final ValueChanged<int> onStudentChanged;
  final VoidCallback? onBackToSummary;
  final bool isParentView;

  static const Color primaryColor = SoftPalette.teal600;  // Deep emerald teal
  static const Color accentColor = SoftPalette.amber300;
  static const Color surfaceColor = SoftPalette.gray100;
  static const Color cardColor = SoftPalette.gray50;
  static const Color textPrimaryColor = SoftPalette.slate800;
  static const Color textMutedColor = SoftPalette.slate550;
  static const Color errorColor = SoftPalette.red400;
  static const Color successColor = SoftPalette.green350;

  const ParentReportCard({
    super.key,
    required this.branchId,
    required this.studentId,
    required this.studentData,
    this.year,
    this.month,
    this.onLogout,
    required this.allDocs,
    required this.selectedIndex,
    required this.onStudentChanged,
    this.onBackToSummary,
    this.isParentView = false,
  });

  @override
  State<ParentReportCard> createState() => _ParentReportCardState();
}

class _ParentReportCardState extends State<ParentReportCard> {
  late int _selectedYear;
  late int _selectedMonth;
  late DateTime _selectedDate;
  int _selectedTab = 0;

  String _attendanceFilter = 'all'; // 'all', 'present', 'absent', 'leave', 'ptm', 'holiday'
  String _quranProgressFilter = 'all'; // 'all', 'sabak', 'sabki', 'manzil'
  String _feeFilter = 'all'; // 'all', 'unpaid', 'paid'

  void _changeTab(int tabIndex) {
    setState(() {
      _selectedTab = tabIndex;
      final now = DateTime.now();
      if (_selectedMonth != now.month || _selectedYear != now.year) {
        _selectedMonth = now.month;
        _selectedYear = now.year;
        _onMonthChanged();
      }
      _selectedDate = now;
    });
  }

  bool _isSyncing = false;
  DateTime? _lastSyncTime;
  static const Duration _syncCooldown = Duration(seconds: 60);

  Future<void> _syncLatestData(BuildContext context) async {
    if (_isSyncing) return;
    final now = DateTime.now();
    if (_lastSyncTime != null && now.difference(_lastSyncTime!) < _syncCooldown) {
      if (mounted) {
        AppToast.showSnackBar(context, 
          SnackBar(
            content: Text(context.isUrdu ? 'مقامی ڈیٹا پہلے ہی تازہ ترین ہے' : 'Showing up-to-date data from local storage'),
            backgroundColor: SoftPalette.teal550,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    _lastSyncTime = now;
    setState(() => _isSyncing = true);
    try {
      if (widget.branchId.isNotEmpty) {
        if (widget.studentId.isNotEmpty) {
          await MadrassaLocalStorage.downloadStudentsForGuardian(widget.branchId, [widget.studentId])
              .timeout(const Duration(seconds: 5), onTimeout: () {});
        }
        await MadrassaLocalStorage.downloadLogsForMonth(widget.branchId, _selectedYear, _selectedMonth, force: true)
            .timeout(const Duration(seconds: 5), onTimeout: () {});
        await MadrassaLocalStorage.downloadHolidays(widget.branchId, force: true)
            .timeout(const Duration(seconds: 5), onTimeout: () {});
        await MadrassaLocalStorage.downloadConfig(widget.branchId)
            .timeout(const Duration(seconds: 5), onTimeout: () {});
      }
      await SyncService().triggerUpload().timeout(const Duration(seconds: 5), onTimeout: () {});
    } catch (_) {}

    if (mounted) {
      setState(() => _isSyncing = false);
      AppToast.showSnackBar(context, 
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.cloud_done_rounded, color: SoftPalette.gray50, size: 20),
              const SizedBox(width: 8),
              Text(context.isUrdu ? 'کلاؤڈ سے تازہ ترین معلومات حاصل کر لی گئیں' : 'Latest records downloaded from Cloud'),
            ],
          ),
          backgroundColor: SoftPalette.teal550,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  final Set<String> _dismissedCongratsMonths = {};

  /// Signed-in Firebase user, or null when Firebase is not set up (offline preview / tests).
  static User? get _fbUser => Firebase.apps.isEmpty ? null : FirebaseAuth.instance.currentUser;

  String get _currentUserKey {
    final email = _fbUser?.email;
    if (email != null && email.isNotEmpty) return email;
    final gEmail = studentData['guardianEmail']?.toString();
    if (gEmail != null && gEmail.isNotEmpty) return gEmail;
    final phone = studentData['contactPhone']?.toString();
    if (phone != null && phone.isNotEmpty) return phone;
    final gName = studentData['guardianName']?.toString();
    if (gName != null && gName.isNotEmpty) return gName;
    return widget.studentId;
  }

  DateTime? get _studentJoinDate {
    final raw = studentData['joinDate'] ?? studentData['admissionDate'] ?? studentData['enrollmentDate'] ?? studentData['createdDate'] ?? studentData['createdAt'];
    if (raw == null) return null;
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    if (raw is String) {
      return DateTime.tryParse(raw);
    }
    return null;
  }

  bool get isDarkMode => UserThemeService.isDarkMode(_currentUserKey);

  // Theme colours (GMWF / Nexus / Twilight, light or dark) for every card on this screen.
  Color get cardBg => context.comfort.surface;
  Color get surfaceBg => context.comfort.background;
  Color get textPrimary => context.comfort.textPrimary;
  Color get textMuted => context.comfort.textMuted;
  Color get borderColor => context.comfort.border;
  Color get dividerColor => context.comfort.border;

  bool _isCongratsDismissedForCurrentMonth() {
    try {
      final currentMonthKey = '${widget.studentId}_${_selectedYear}_$_selectedMonth';
      if (_dismissedCongratsMonths.contains(currentMonthKey)) return true;
      if (Hive.isBoxOpen('app_settings')) {
        final val = Hive.box('app_settings').get('madrassa_congrats_dismissed_$currentMonthKey');
        if (val == true) return true;
      }
    } catch (_) {}
    return false;
  }

  void _dismissCongratsForMonth() {
    final currentMonthKey = '${widget.studentId}_${_selectedYear}_$_selectedMonth';
    setState(() {
      _dismissedCongratsMonths.add(currentMonthKey);
    });
    try {
      if (Hive.isBoxOpen('app_settings')) {
        Hive.box('app_settings').put('madrassa_congrats_dismissed_$currentMonthKey', true);
      }
    } catch (_) {}
  }

  Map<String, dynamic>? _liveStudentData;
  Map<String, dynamic> get studentData => _liveStudentData ?? widget.studentData;

  String get _effectiveBranch {
    final normWidget = MadrassaLocalStorage.normalizeBranch(widget.branchId);
    if (normWidget.isNotEmpty && normWidget != 'all' && normWidget != 'global') {
      return normWidget;
    }
    final rawStd = (studentData['branchId'] ?? studentData['branch'] ?? '').toString().trim();
    final normStd = MadrassaLocalStorage.normalizeBranch(rawStd);
    if (normStd.isNotEmpty && normStd != 'all' && normStd != 'global') {
      return normStd;
    }
    return 'gujrat';
  }

  bool get isNazraStudent =>
      (studentData['isNazra'] == true) ||
      (studentData['program']?.toString().toLowerCase() == 'nazra') ||
      (studentData['class']?.toString().toLowerCase() == 'nazra') ||
      LocalStorageService.isMadrassaNazraOnly(_effectiveBranch);

  late Stream<List<Map<String, dynamic>>> _logsStream;
  late Stream<MadrassaConfig> _configStream;
  late Stream<List<Map<String, dynamic>>> _holidaysStream;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedYear = widget.year ?? now.year;
    _selectedMonth = widget.month ?? now.month;
    _selectedDate = now;
    _initStreams();
  }

  void _initStreams() {
    final effBranch = _effectiveBranch;
    _logsStream = MadrassaLocalStorage.streamLogsForMonthCached(effBranch, _selectedYear, _selectedMonth);
    _configStream = MadrassaLocalStorage.streamConfigCached(effBranch);
    _holidaysStream = MadrassaLocalStorage.streamHolidaysCached(effBranch);

    // Refresh current month daily logs from cloud in background so parent sees latest dates
    // (the read is skipped when this phone read the month recently — see the read budget
    // in MadrassaLocalStorage). Today and tomorrow are watched live (2 documents), so a
    // teacher's leave decision or reply check still shows at once.
    if (effBranch.isNotEmpty) {
      final now = DateTime.now();
      for (final d in [now, now.add(const Duration(days: 1))]) {
        MadrassaLocalStorage.listenToLogsRealtime(effBranch, DateFormat('yyyy-MM-dd').format(d));
      }
      final isCurrent = _selectedYear == now.year && _selectedMonth == now.month;
      final cached = MadrassaLocalStorage.getLogsForMonthCached(effBranch, _selectedYear, _selectedMonth);
      if (cached.isEmpty || isCurrent) {
        MadrassaLocalStorage.downloadLogsForMonth(effBranch, _selectedYear, _selectedMonth);
      }
    }
  }

  @override
  void didUpdateWidget(covariant ParentReportCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    bool shouldReinit = false;
    if (widget.studentId != oldWidget.studentId) {
      _liveStudentData = null;
      _initStreams();
      shouldReinit = true;
    }
    if (widget.year != oldWidget.year || widget.month != oldWidget.month) {
      _selectedYear = widget.year ?? DateTime.now().year;
      _selectedMonth = widget.month ?? DateTime.now().month;
      _initStreams();
      shouldReinit = true;
    }
    if (widget.branchId != oldWidget.branchId) {
      _initStreams();
      shouldReinit = true;
    }
    if (shouldReinit) {
      setState(() {});
    }
  }

  Future<void> _submitParentReply(BuildContext context, String branchId, String dateStr, String studentId) async {
    final effBranch = _effectiveBranch;
    try {
      await MadrassaLocalStorage.saveLogRecordLocal(
        branchId: effBranch,
        dateKey: dateStr,
        logData: {
          studentId: {
            'parentReplied': true,
            'parentRepliedRequested': true,
            'timestamp': DateTime.now().toIso8601String(),
          }
        },
        editorName: 'Parent/Guardian',
        editorRole: 'guardian',
      ).timeout(const Duration(seconds: 6), onTimeout: () {});

      if (Firebase.apps.isNotEmpty) {
        if (FirebaseAuth.instance.currentUser == null) {
          await FirebaseSessionGuard.ensureSession(reason: 'direct_write');
        }
        await FirebaseFirestore.instance
            .collection('branches')
            .doc(effBranch)
            .collection('madrassa_daily_logs')
            .doc(dateStr)
            .set({
          studentId: {
            'parentReplied': true,
            'parentRepliedRequested': true,
            'timestamp': FieldValue.serverTimestamp(),
          }
        }, SetOptions(merge: true))
            .timeout(const Duration(seconds: 8))
            .catchError((err) {
          debugPrint('[ParentReportCard] Direct Firestore reply update note: $err');
        });
      }

      if (mounted) {
        setState(() {});
      }

      if (context.mounted) {
        AppFeedback.showSuccess(
          context,
          context.isUrdu 
              ? 'جواب کامیابی کے ساتھ درج کر دیا گیا ہے۔' 
              : 'Reply submitted successfully.',
          subtitle: 'Saved locally • Syncing to cloud',
        );
      }
    } catch (e) {
      if (context.mounted) {
        AppFeedback.showError(context, 'Error: $e');
      }
    }
  }

  Future<void> _showLeaveReasonDialog(BuildContext context, String branchId, String initialDateStr, String studentId) async {
    final TextEditingController reasonController = TextEditingController();
    String? reasonError;

    DateTime startDate = DateTime.tryParse(initialDateStr) ?? DateTime.now();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (startDate.isBefore(today)) startDate = today;
    DateTime endDate = startDate;

    bool isSaving = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDs) {
          final daysCount = endDate.difference(startDate).inDays + 1;
          final startFormatted = DateFormat('dd MMM yyyy').format(startDate);
          final endFormatted = DateFormat('dd MMM yyyy').format(endDate);
          final dateRangeLabel = daysCount == 1 ? startFormatted : '$startFormatted → $endFormatted ($daysCount days)';

          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Text(context.t('Request Leave'), style: TextStyle(fontWeight: FontWeight.bold, fontFamily: context.isUrdu ? 'Noori' : null)),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Select Dates Label
                  Text(
                    context.isUrdu ? 'رخصت کی تاریخ منتخب کریں' : 'Select Date(s)',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.adapt(SoftPalette.slate800), fontFamily: context.isUrdu ? 'Noori' : null),
                  ),
                  const SizedBox(height: 6),

                  // Date Selector Box
                  InkWell(
                    onTap: isSaving
                        ? null
                        : () async {
                            final pickedRange = await showDateRangePicker(
                              context: context,
                              initialDateRange: DateTimeRange(start: startDate, end: endDate),
                              firstDate: today,
                              lastDate: today.add(const Duration(days: 365)),
                              builder: (context, child) {
                                return Theme(
                                  data: Theme.of(context).copyWith(
                                    colorScheme: ColorScheme.light(
                                      primary: ParentReportCard.primaryColor,
                                      onPrimary: SoftPalette.gray50,
                                      surface: SoftPalette.gray50,
                                      onSurface: SoftPalette.slate800,
                                    ),
                                  ),
                                  child: child!,
                                );
                              },
                            );
                            if (pickedRange != null) {
                              setDs(() {
                                startDate = pickedRange.start;
                                endDate = pickedRange.end;
                              });
                            }
                          },
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: context.adapt(SoftPalette.gray50),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: context.comfort.brand, width: 1.5),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.calendar_month_rounded, color: context.comfort.brand, size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  dateRangeLabel,
                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: context.comfort.brand),
                                ),
                                Text(
                                  context.isUrdu ? 'تاریخ تبدیل کرنے کے لیے ٹیپ کریں' : 'Tap to change date or select multiple dates',
                                  style: TextStyle(fontSize: 10.5, color: context.adapt(SoftPalette.gray500)),
                                ),
                              ],
                            ),
                          ),
                          Icon(Icons.arrow_forward_ios_rounded, size: 14, color: context.adapt(SoftPalette.gray350)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Reason for Leave (MANDATORY)
                  RichText(
                    text: TextSpan(
                      children: [
                        TextSpan(
                          text: context.t('Leave Reason'),
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.adapt(SoftPalette.slate800), fontFamily: context.isUrdu ? 'Noori' : null),
                        ),
                        TextSpan(
                          text: ' * (Required)',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: context.adapt(SoftPalette.red500)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: reasonController,
                    maxLines: 3,
                    enabled: !isSaving,
                    style: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null),
                    decoration: InputDecoration(
                      hintText: context.isUrdu ? 'رخصت کی وجہ درج کریں (لازمی)' : 'Enter reason for leave (Mandatory)...',
                      hintStyle: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null, fontSize: 12.5),
                      errorText: reasonError != null ? context.t(reasonError!) : null,
                      errorStyle: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: reasonError != null ? context.adapt(SoftPalette.red500) : context.adapt(SoftPalette.slate200)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: context.adapt(SoftPalette.indigo550), width: 2),
                      ),
                    ),
                    onChanged: (v) {
                      if (reasonError != null) setDs(() => reasonError = null);
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: isSaving ? null : () => Navigator.pop(ctx),
                child: Text(context.t('Cancel'), style: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null)),
              ),
              ElevatedButton(
                onPressed: isSaving
                    ? null
                    : () async {
                        final reasonText = reasonController.text.trim();
                        if (reasonText.isEmpty) {
                          setDs(() => reasonError = 'Leave reason is required');
                          return;
                        }

                        setDs(() => isSaving = true);
                        try {
                          final effBranch = _effectiveBranch;
                          final batch = FirebaseFirestore.instance.batch();
                          int totalDays = 0;

                          final requestedAt = DateTime.now().toUtc().toIso8601String();
                          DateTime curr = startDate;
                          while (!curr.isAfter(endDate)) {
                            totalDays++;
                            final dStr = DateFormat('yyyy-MM-dd').format(curr);

                            // Save to local storage & enqueue sync
                            await MadrassaLocalStorage.saveLogRecordLocal(
                              branchId: effBranch,
                              dateKey: dStr,
                              logData: {
                                studentId: {
                                  'attendance': 'leave_requested',
                                  'isParentRequested': true,
                                  'leaveReason': reasonText,
                                  'leaveStatus': 'pending',
                                  'timestamp': requestedAt,
                                  // When it was asked: a teacher's later decision is never
                                  // undone by this copy arriving late, and a genuinely new
                                  // request after a denial has a newer timestamp.
                                  'leaveRequestedAt': requestedAt,
                                  'leaveDecidedAt': null,
                                  'leaveDecidedFor': null,
                                }
                              },
                              editorName: 'Parent/Guardian',
                              editorRole: 'guardian',
                            ).timeout(const Duration(seconds: 6), onTimeout: () {});

                            final docRef = FirebaseFirestore.instance
                                .collection('branches')
                                .doc(effBranch)
                                .collection('madrassa_daily_logs')
                                .doc(dStr);

                            batch.set(
                              docRef,
                              {
                                studentId: {
                                  'attendance': 'leave_requested',
                                  'isParentRequested': true,
                                  'leaveReason': reasonText,
                                  'leaveStatus': 'pending',
                                  'timestamp': FieldValue.serverTimestamp(),
                                  'leaveRequestedAt': requestedAt,
                                  'leaveDecidedAt': null,
                                  'leaveDecidedFor': null,
                                  'lastEditedBy': 'Parent/Guardian',
                                  'lastEditedAt': requestedAt,
                                }
                              },
                              SetOptions(merge: true),
                            );

                            curr = curr.add(const Duration(days: 1));
                          }

                          if (Firebase.apps.isNotEmpty) {
                            if (FirebaseAuth.instance.currentUser == null) {
                              await FirebaseSessionGuard.ensureSession(reason: 'direct_write');
                            }
                            await batch
                                .commit()
                                .timeout(const Duration(seconds: 8))
                                .catchError((err) {
                              debugPrint('[ParentReportCard] Direct Firestore leave batch note: $err');
                            });
                          }

                          if (mounted) {
                            setState(() {});
                          }

                          if (ctx.mounted) {
                            Navigator.pop(ctx);
                            AppFeedback.showSuccess(
                              context,
                              context.isUrdu
                                  ? 'رخصت کی درخواست ($totalDays دن) کامیابی کے ساتھ جمع ہو گئی ہے۔'
                                  : 'Leave request for $totalDays day(s) submitted successfully.',
                              subtitle: 'Saved locally • Enqueued for sync',
                            );
                          }
                        } catch (e) {
                          if (ctx.mounted) {
                            setDs(() => isSaving = false);
                            AppFeedback.showError(context, 'Error submitting leave request: $e');
                          }
                        }
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: ParentReportCard.primaryColor,
                  foregroundColor: SoftPalette.gray50,
                ),
                child: isSaving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: SoftPalette.gray50),
                      )
                    : Text(context.t('Submit'), style: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null)),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showRejoinDialog(BuildContext context) async {
    final reasonCtrl = TextEditingController();
    String? reasonError;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDs) {
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Text(context.t('Request Rejoining'), style: TextStyle(fontWeight: FontWeight.bold, fontFamily: context.isUrdu ? 'Noori' : null)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.t('Please specify the reason/notes for requesting to rejoin the Madrassa.'),
                  style: TextStyle(fontSize: 13, color: context.adapt(SoftPalette.gray350), fontFamily: context.isUrdu ? 'Noori' : null),
                ),
                const SizedBox(height: 16),
                RichText(
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: context.t('Rejoining Reason'),
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.adapt(SoftPalette.slate800), fontFamily: context.isUrdu ? 'Noori' : null),
                      ),
                      TextSpan(
                        text: ' *',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.adapt(SoftPalette.red500)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: reasonCtrl,
                  maxLines: 3,
                  style: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null),
                  decoration: InputDecoration(
                    hintText: context.t('e.g. Relocating back, student wants to resume.'),
                    hintStyle: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null),
                    errorText: reasonError != null ? context.t(reasonError!) : null,
                    errorStyle: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: reasonError != null ? context.adapt(SoftPalette.red500) : context.adapt(SoftPalette.slate200)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: context.adapt(SoftPalette.indigo550), width: 2),
                    ),
                  ),
                  onChanged: (v) {
                    if (reasonError != null) setDs(() => reasonError = null);
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(context.t('Cancel'), style: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null)),
              ),
              ElevatedButton(
                onPressed: () async {
                  if (reasonCtrl.text.trim().isEmpty) {
                    setDs(() => reasonError = 'Rejoining reason is required');
                    return;
                  }

                  final effBranch = _effectiveBranch;
                  // 1. Update student cache locally
                  final cached = MadrassaLocalStorage.getStudentCached(effBranch, widget.studentId) ?? {};
                  cached['rejoinRequestStatus'] = 'pending';
                  cached['rejoinRequestReason'] = reasonCtrl.text.trim();
                  cached['rejoinRequestDate'] = DateTime.now().toIso8601String();
                  await MadrassaLocalStorage.cacheStudent(effBranch, widget.studentId, cached);

                  // 2. Enqueue sync
                  await LocalStorageService.enqueueSync({
                    'type': 'save_madrassa_student',
                    'branchId': effBranch,
                    'studentId': widget.studentId,
                    'data': cached,
                  });
                  unawaited(SyncService().triggerUpload(urgent: true));

                  // 3. Direct Firestore update with session ensure
                  if (Firebase.apps.isNotEmpty) {
                    if (FirebaseAuth.instance.currentUser == null) {
                      await FirebaseSessionGuard.ensureSession(reason: 'direct_write');
                    }
                    await FirebaseFirestore.instance
                        .collection('branches')
                        .doc(effBranch)
                        .collection('madrassa_students')
                        .doc(widget.studentId)
                        .set({
                      'rejoinRequestStatus': 'pending',
                      'rejoinRequestReason': reasonCtrl.text.trim(),
                      'rejoinRequestDate': FieldValue.serverTimestamp(),
                    }, SetOptions(merge: true))
                        .timeout(const Duration(seconds: 8))
                        .catchError((err) {
                      debugPrint('[ParentReportCard] Rejoin update note: $err');
                    });
                  }

                  if (mounted) setState(() {});
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: ParentReportCard.primaryColor,
                  foregroundColor: SoftPalette.gray50,
                ),
                child: Text(context.t('Submit Request'), style: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null)),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showUnarchiveDialog(BuildContext context) async {
    final reasonCtrl = TextEditingController();
    String? reasonError;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDs) {
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Text(context.t('Request Unarchive'), style: TextStyle(fontWeight: FontWeight.bold, fontFamily: context.isUrdu ? 'Noori' : null)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.isUrdu
                      ? 'براہ کرم طالب علم کو دوبارہ فعال کرنے کی وجہ درج کریں۔ اس درخواست کو استاد کی منظوری درکار ہوگی۔'
                      : 'Please specify the reason for requesting to unarchive this student. This request requires teacher approval.',
                  style: TextStyle(fontSize: 13, color: context.adapt(SoftPalette.gray350), fontFamily: context.isUrdu ? 'Noori' : null),
                ),
                const SizedBox(height: 16),
                RichText(
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: context.isUrdu ? 'وجہ' : 'Reason',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.adapt(SoftPalette.slate800), fontFamily: context.isUrdu ? 'Noori' : null),
                      ),
                      TextSpan(
                        text: ' *',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.adapt(SoftPalette.red500)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: reasonCtrl,
                  maxLines: 3,
                  style: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null),
                  decoration: InputDecoration(
                    hintText: context.isUrdu ? 'مثال: طالب علم دوبارہ حاضری دینا چاہتا ہے۔' : 'e.g. Student wants to resume attendance.',
                    hintStyle: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null),
                    errorText: reasonError != null ? context.t(reasonError!) : null,
                    errorStyle: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: reasonError != null ? context.adapt(SoftPalette.red500) : context.adapt(SoftPalette.slate200)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: context.adapt(SoftPalette.indigo550), width: 2),
                    ),
                  ),
                  onChanged: (v) {
                    if (reasonError != null) setDs(() => reasonError = null);
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(context.t('Cancel'), style: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null)),
              ),
              ElevatedButton(
                onPressed: () async {
                  if (reasonCtrl.text.trim().isEmpty) {
                    setDs(() => reasonError = 'Reason is required');
                    return;
                  }

                  final effBranch = _effectiveBranch;
                  // 1. Update student cache locally
                  final cached = MadrassaLocalStorage.getStudentCached(effBranch, widget.studentId) ?? {};
                  cached['rejoinRequestStatus'] = 'pending';
                  cached['rejoinRequestReason'] = reasonCtrl.text.trim();
                  cached['rejoinRequestDate'] = DateTime.now().toIso8601String();
                  await MadrassaLocalStorage.cacheStudent(effBranch, widget.studentId, cached);

                  // 2. Enqueue sync
                  await LocalStorageService.enqueueSync({
                    'type': 'save_madrassa_student',
                    'branchId': effBranch,
                    'studentId': widget.studentId,
                    'data': cached,
                  });
                  unawaited(SyncService().triggerUpload(urgent: true));

                  // 3. Direct Firestore update with session ensure
                  if (Firebase.apps.isNotEmpty) {
                    if (FirebaseAuth.instance.currentUser == null) {
                      await FirebaseSessionGuard.ensureSession(reason: 'direct_write');
                    }
                    await FirebaseFirestore.instance
                        .collection('branches')
                        .doc(effBranch)
                        .collection('madrassa_students')
                        .doc(widget.studentId)
                        .set({
                      'rejoinRequestStatus': 'pending',
                      'rejoinRequestReason': reasonCtrl.text.trim(),
                      'rejoinRequestDate': FieldValue.serverTimestamp(),
                    }, SetOptions(merge: true))
                        .timeout(const Duration(seconds: 8))
                        .catchError((err) {
                      debugPrint('[ParentReportCard] Rejoin update note: $err');
                    });
                  }

                  if (mounted) setState(() {});
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: SoftPalette.amber300,
                  foregroundColor: SoftPalette.gray50,
                ),
                child: Text(context.t('Submit Request'), style: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null)),
              ),
            ],
          );
        },
      ),
    );
  }


Future<void> _showChangePasswordDialog(BuildContext context) async {
    final oldPwCtrl = TextEditingController();
    final newPwCtrl = TextEditingController();
    final confirmPwCtrl = TextEditingController();
    
    String? oldPwError;
    String? newPwError;
    String? confirmPwError;
    bool isSaving = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDs) {
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            title: Text(
              context.t('Change Password'),
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontFamily: context.isUrdu ? 'Noori' : null,
              ),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PasswordField(
                    controller: oldPwCtrl,
                    label: context.t('Old Password'),
                    icon: Icons.lock_open_rounded,
                    isRequired: true,
                    errorText: oldPwError,
                    onChanged: (v) {
                      if (oldPwError != null) setDs(() => oldPwError = null);
                    },
                  ),
                  const SizedBox(height: 12),
                  PasswordField(
                    controller: newPwCtrl,
                    label: context.t('New Password'),
                    icon: Icons.lock_outline_rounded,
                    isRequired: true,
                    errorText: newPwError,
                    onChanged: (v) {
                      if (newPwError != null) setDs(() => newPwError = null);
                    },
                  ),
                  const SizedBox(height: 12),
                  PasswordField(
                    controller: confirmPwCtrl,
                    label: context.t('Confirm Password'),
                    icon: Icons.lock_outline_rounded,
                    isRequired: true,
                    errorText: confirmPwError,
                    onChanged: (v) {
                      if (confirmPwError != null) setDs(() => confirmPwError = null);
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: isSaving ? null : () => Navigator.pop(ctx),
                child: Text(
                  context.t('Cancel'),
                  style: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null),
                ),
              ),
              ElevatedButton(
                onPressed: isSaving
                    ? null
                    : () async {
                        final navigator = Navigator.of(ctx);
                        final successMsg = context.t('Password changed successfully!');
                        final incorrectPwMsg = context.t('Incorrect old password');
                        final failedMsg = context.t('Failed to change password');

                        bool isValid = true;
                        if (oldPwCtrl.text.trim().isEmpty) {
                          oldPwError = context.t('Old password is required');
                          isValid = false;
                        }
                        if (newPwCtrl.text.trim().isEmpty) {
                          newPwError = context.t('New password is required');
                          isValid = false;
                        } else if (newPwCtrl.text.trim().length < 6) {
                          newPwError = context.t('Password must be at least 6 characters');
                          isValid = false;
                        }
                        if (confirmPwCtrl.text.trim().isEmpty) {
                          confirmPwError = context.t('Confirm password is required');
                          isValid = false;
                        } else if (newPwCtrl.text.trim() != confirmPwCtrl.text.trim()) {
                          confirmPwError = context.t('Passwords do not match');
                          isValid = false;
                        }

                        if (!isValid) {
                          setDs(() {});
                          return;
                        }

                        setDs(() => isSaving = true);
                        try {
                          final currentUser = FirebaseAuth.instance.currentUser;
                          if (currentUser == null) {
                            throw Exception(context.t('No active login session found'));
                          }
                          final email = currentUser.email;
                          if (email == null || email.isEmpty) {
                            throw Exception(context.t('User email is not set'));
                          }

                          // Re-authenticate
                          final cred = EmailAuthProvider.credential(
                            email: email,
                            password: oldPwCtrl.text.trim(),
                          );
                          await currentUser.reauthenticateWithCredential(cred).timeout(const Duration(seconds: 5));

                          // Update Auth Password
                          await currentUser.updatePassword(newPwCtrl.text.trim()).timeout(const Duration(seconds: 5));

                          // Update offline auth cache password
                          await OfflineAuthService.updateCachedPassword(
                            newPwCtrl.text.trim(),
                            usernameOrEmail: email,
                          );

                          // Update Firestore documents copy in background with timeout
                          final uid = currentUser.uid;
                          final updates = {
                            'password': newPwCtrl.text.trim(),
                            'passwordHash': LocalStorageService.hashPassword(newPwCtrl.text.trim()),
                            'lastUpdatedAt': FieldValue.serverTimestamp(),
                          };
                          unawaited(
                            FirebaseFirestore.instance.collection('users').doc(uid).set(updates, SetOptions(merge: true))
                                .timeout(const Duration(seconds: 4))
                                .catchError((_) {})
                          );
                          unawaited(
                            FirebaseFirestore.instance
                                .collection('branches')
                                .doc(widget.branchId)
                                .collection('users')
                                .doc(uid)
                                .set(updates, SetOptions(merge: true))
                                .timeout(const Duration(seconds: 4))
                                .catchError((_) {})
                          );

                          if (ctx.mounted) {
                            navigator.pop();
                            AppToast.fromSnackBar(
                              SnackBar(
                                content: Text(successMsg),
                                backgroundColor: SoftPalette.green400,
                              ),
                            );
                          }
                        } on FirebaseAuthException catch (e) {
                          setDs(() => isSaving = false);
                          if (e.code == 'wrong-password') {
                            oldPwError = incorrectPwMsg;
                          } else {
                            AppToast.fromSnackBar(
                              SnackBar(
                                content: Text(e.message ?? failedMsg),
                                backgroundColor: SoftPalette.red400,
                              ),
                            );
                          }
                          setDs(() {});
                        } catch (e) {
                          setDs(() => isSaving = false);
                          AppToast.fromSnackBar(
                            SnackBar(
                              content: Text('Error: $e'),
                              backgroundColor: SoftPalette.red400,
                            ),
                          );
                        }
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: ParentReportCard.primaryColor,
                  foregroundColor: SoftPalette.gray50,
                ),
                child: isSaving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: SoftPalette.gray50),
                      )
                    : Text(
                        context.t('Confirm'),
                        style: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showSendReplyDialog(BuildContext context, String dateStr) async {
    final replyCtrl = TextEditingController();
    bool isSaving = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDs) {
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            title: Row(
              children: [
                Icon(Icons.reply_rounded, color: context.comfort.brand),
                const SizedBox(width: 8),
                Text(
                  context.isUrdu ? 'استاد کو جواب بھیجیں' : 'Reply to Teacher',
                  style: TextStyle(fontWeight: FontWeight.bold, fontFamily: context.isUrdu ? 'Noori' : null),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.isUrdu ? '$dateStr کی حاضری کا جواب:' : 'Send a response for $dateStr:',
                  style: TextStyle(fontSize: 12, color: context.adapt(SoftPalette.gray500), fontFamily: context.isUrdu ? 'Noori' : null),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: replyCtrl,
                  maxLines: 3,
                  decoration: InputDecoration(
                    hintText: context.isUrdu ? 'اپنا پیغام یہاں درج کریں...' : 'Enter your reply message here...',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: isSaving ? null : () => Navigator.pop(ctx),
                child: Text(context.t('Cancel'), style: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null)),
              ),
              ElevatedButton(
                onPressed: isSaving
                    ? null
                    : () async {
                        final text = replyCtrl.text.trim();
                        if (text.isEmpty) return;
                        setDs(() => isSaving = true);
                        try {
                          final effBranch = _effectiveBranch;
                          final replyData = {
                            widget.studentId: {
                              'parentReplied': true,
                              'parentRepliedRequested': true,
                              'parentReplyText': text,
                              'parentReplyMessage': text,
                              'parentReplyTime': DateTime.now().toIso8601String(),
                            }
                          };

                          // 1. Immediately save to Local Hive & broadcast/enqueue sync
                          await MadrassaLocalStorage.saveLogRecordLocal(
                            branchId: effBranch,
                            dateKey: dateStr,
                            logData: replyData,
                            editorName: 'Parent/Guardian',
                            editorRole: 'guardian',
                          ).timeout(const Duration(seconds: 6), onTimeout: () {
                            debugPrint('[ParentReportCard] Local log save timeout note');
                          });

                          // 2. Direct Firestore update for cloud instant reflection
                          if (Firebase.apps.isNotEmpty) {
                            if (FirebaseAuth.instance.currentUser == null) {
                              await FirebaseSessionGuard.ensureSession(reason: 'direct_write');
                            }
                            await FirebaseFirestore.instance
                                .collection('branches')
                                .doc(effBranch)
                                .collection('madrassa_daily_logs')
                                .doc(dateStr)
                                .set({
                              widget.studentId: {
                                'parentReplied': true,
                                'parentRepliedRequested': true,
                                'parentReplyText': text,
                                'parentReplyMessage': text,
                                'parentReplyTime': FieldValue.serverTimestamp(),
                              }
                            }, SetOptions(merge: true))
                                .timeout(const Duration(seconds: 8))
                                .catchError((err) {
                              debugPrint('[ParentReportCard] Direct Firestore reply update note: $err');
                            });
                          }

                          if (mounted) {
                            setState(() {});
                          }

                          if (ctx.mounted) {
                            Navigator.pop(ctx);
                            AppFeedback.showSuccess(
                              context,
                              context.isUrdu ? 'جواب کامیابی سے بھیج دیا گیا!' : 'Reply sent successfully!',
                              subtitle: 'Saved locally • Syncing to cloud',
                            );
                          }
                        } catch (e) {
                          setDs(() => isSaving = false);
                          if (ctx.mounted) {
                            AppFeedback.showError(context, 'Error: $e');
                          }
                        }
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: ParentReportCard.primaryColor,
                  foregroundColor: SoftPalette.gray50,
                ),
                child: isSaving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: SoftPalette.gray50))
                    : Text(context.isUrdu ? 'بھیجیں' : 'Send Reply', style: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null)),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildParentReplyStatusRow(BuildContext context, String dateStr, Map<String, dynamic>? statusData) {
    final hasReplied = statusData?['parentReplied'] == true;
    final replyText = statusData?['parentReplyText']?.toString() ?? statusData?['parentReplyMessage']?.toString();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? SoftPalette.slate800 : SoftPalette.gray50;
    final textPrimary = isDark ? SoftPalette.gray50 : SoftPalette.slate800;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  hasReplied ? Icons.check_circle_rounded : Icons.pending_actions_rounded,
                  size: 16,
                  color: hasReplied ? SoftPalette.green400 : SoftPalette.red500,
                ),
                const SizedBox(width: 6),
                Text(
                  hasReplied
                      ? (context.isUrdu ? 'جواب: بھیج دیا گیا' : 'Parent Reply: Sent')
                      : (context.isUrdu ? 'جواب: زیر التواء (Pending)' : 'Parent Reply: Pending'),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: hasReplied ? SoftPalette.green400 : SoftPalette.red500,
                    fontFamily: context.isUrdu ? 'Noori' : null,
                  ),
                ),
              ],
            ),
            if (widget.isParentView && !hasReplied && (studentData['status']?.toString() ?? 'active') == 'active')
              ElevatedButton.icon(
                onPressed: () => _showSendReplyDialog(context, dateStr),
                icon: const Icon(Icons.reply_rounded, size: 14),
                label: Text(
                  context.isUrdu ? 'جواب دیں' : 'Reply to Teacher',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, fontFamily: context.isUrdu ? 'Noori' : null),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: ParentReportCard.primaryColor,
                  foregroundColor: SoftPalette.gray50,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
          ],
        ),
        if (hasReplied && replyText != null && replyText.isNotEmpty) ...[
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: SoftPalette.green400.withValues(alpha: 0.4)),
            ),
            child: Text(
              '"$replyText"',
              style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: textPrimary, fontFamily: context.isUrdu ? 'Noori' : null),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _showEditGuardianInfoDialog(BuildContext context) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    final nameCtrl = TextEditingController(text: studentData['guardianName']?.toString() ?? '');
    final phoneCtrl = TextEditingController(text: studentData['contactPhone']?.toString() ?? '');
    final cnicCtrl = TextEditingController(text: studentData['guardianCnic']?.toString() ?? '');
    final emailCtrl = TextEditingController(text: currentUser?.email ?? studentData['guardianEmail']?.toString() ?? '');
    final newPwCtrl = TextEditingController();
    final currentPwCtrl = TextEditingController();

    String? currentPwError;
    String? newPwError;
    String? emailError;
    bool isSaving = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDs) {
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            title: Row(
              children: [
                Icon(Icons.edit_note_rounded, color: context.comfort.brand),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.t('Edit Account Details'),
                    style: TextStyle(fontWeight: FontWeight.bold, fontFamily: context.isUrdu ? 'Noori' : null),
                  ),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.t('Update your account, contact, and security details below:'),
                    style: TextStyle(fontSize: 12, color: context.adapt(SoftPalette.gray500), fontFamily: context.isUrdu ? 'Noori' : null),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: nameCtrl,
                    decoration: InputDecoration(
                      labelText: context.t('Guardian Name'),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      prefixIcon: const Icon(Icons.person_outline),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: phoneCtrl,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(
                      labelText: context.t('Phone Number / Username'),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      prefixIcon: const Icon(Icons.phone_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: cnicCtrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: context.t('Guardian CNIC'),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      prefixIcon: const Icon(Icons.credit_card_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(
                      labelText: context.t('Email / Username'),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      prefixIcon: const Icon(Icons.email_outlined),
                      errorText: emailError,
                    ),
                    onChanged: (v) {
                      if (emailError != null) setDs(() => emailError = null);
                    },
                  ),
                  const SizedBox(height: 12),
                  PasswordField(
                    controller: newPwCtrl,
                    label: context.t('New Password (Optional)'),
                    icon: Icons.lock_outline_rounded,
                    isRequired: false,
                    errorText: newPwError,
                    onChanged: (v) {
                      if (newPwError != null) setDs(() => newPwError = null);
                    },
                  ),
                  const SizedBox(height: 16),
                  const Divider(),
                  const SizedBox(height: 8),
                  PasswordField(
                    controller: currentPwCtrl,
                    label: context.t('Current Password (Required)'),
                    icon: Icons.lock_open_rounded,
                    isRequired: true,
                    errorText: currentPwError,
                    onChanged: (v) {
                      if (currentPwError != null) setDs(() => currentPwError = null);
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: isSaving ? null : () => Navigator.pop(ctx),
                child: Text(context.t('Cancel'), style: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null)),
              ),
              ElevatedButton(
                onPressed: isSaving
                    ? null
                    : () async {
                        final currentPw = currentPwCtrl.text.trim();
                        if (currentPw.isEmpty) {
                          setDs(() => currentPwError = context.t('Current password is required to save changes'));
                          return;
                        }

                        if (newPwCtrl.text.trim().isNotEmpty && newPwCtrl.text.trim().length < 6) {
                          setDs(() => newPwError = context.t('Password must be at least 6 characters'));
                          return;
                        }

                        setDs(() => isSaving = true);
                        try {
                          final user = FirebaseAuth.instance.currentUser;
                          final oldEmail = user?.email ?? '';
                          final newEmail = emailCtrl.text.trim();
                          final newPw = newPwCtrl.text.trim();

                          if (user != null && oldEmail.isNotEmpty) {
                            // Re-authenticate with current password
                            final cred = EmailAuthProvider.credential(
                              email: oldEmail,
                              password: currentPw,
                            );
                            await user.reauthenticateWithCredential(cred);

                            // Update Email if changed
                            if (newEmail.isNotEmpty && newEmail != oldEmail) {
                              await user.verifyBeforeUpdateEmail(newEmail);
                            }

                            // Update Display Name
                            if (nameCtrl.text.trim().isNotEmpty) {
                              await user.updateDisplayName(nameCtrl.text.trim());
                            }

                            // Update Password if provided
                            if (newPw.isNotEmpty) {
                              await user.updatePassword(newPw);
                              await OfflineAuthService.updateCachedPassword(
                                newPw,
                                usernameOrEmail: newEmail.isNotEmpty ? newEmail : oldEmail,
                              );
                            }
                          }

                          final studentUpdates = <String, dynamic>{
                            'guardianName': nameCtrl.text.trim(),
                            'contactPhone': phoneCtrl.text.trim(),
                            'guardianCnic': cnicCtrl.text.trim(),
                            if (newEmail.isNotEmpty) 'guardianEmail': newEmail,
                            'lastUpdatedAt': FieldValue.serverTimestamp(),
                          };

                          // Update student in local cache and enqueue sync
                          final cached = MadrassaLocalStorage.getStudentCached(widget.branchId, widget.studentId) ?? {};
                          cached.addAll(studentUpdates);
                          await MadrassaLocalStorage.cacheStudent(widget.branchId, widget.studentId, cached);
                          await LocalStorageService.enqueueSync({
                            'type': 'save_madrassa_student',
                            'branchId': widget.branchId,
                            'studentId': widget.studentId,
                            'data': cached,
                          });
                          unawaited(SyncService().triggerUpload());

                          unawaited(
                            FirebaseFirestore.instance
                                .collection('branches')
                                .doc(widget.branchId)
                                .collection('madrassa_students')
                                .doc(widget.studentId)
                                .update(studentUpdates)
                                .timeout(const Duration(seconds: 4))
                                .catchError((_) {})
                          );

                          // Also update user document if authenticated
                          if (user != null) {
                            final userUpdates = <String, dynamic>{
                              'name': nameCtrl.text.trim(),
                              'phone': phoneCtrl.text.trim(),
                              'cnic': cnicCtrl.text.trim(),
                              if (newEmail.isNotEmpty) 'email': newEmail,
                              if (newPw.isNotEmpty) 'password': newPw,
                              if (newPw.isNotEmpty) 'passwordHash': LocalStorageService.hashPassword(newPw),
                              'lastUpdatedAt': DateTime.now().toIso8601String(),
                            };
                            await LocalStorageService.enqueueSync({
                              'type': 'save_user',
                              'uid': user.uid,
                              'branchId': widget.branchId,
                              'data': userUpdates,
                            });
                            unawaited(SyncService().triggerUpload());

                            final fsUserUpdates = Map<String, dynamic>.from(userUpdates)
                              ..['lastUpdatedAt'] = FieldValue.serverTimestamp();
                            unawaited(
                              FirebaseFirestore.instance.collection('users').doc(user.uid).set(fsUserUpdates, SetOptions(merge: true))
                                  .timeout(const Duration(seconds: 4))
                                  .catchError((_) {})
                            );
                            unawaited(
                              FirebaseFirestore.instance
                                  .collection('branches')
                                  .doc(widget.branchId)
                                  .collection('users')
                                  .doc(user.uid)
                                  .set(fsUserUpdates, SetOptions(merge: true))
                                  .timeout(const Duration(seconds: 4))
                                  .catchError((_) {})
                            );
                          }

                          if (ctx.mounted) {
                            Navigator.pop(ctx);
                            AppToast.showSnackBar(context, 
                              SnackBar(
                                content: Text(context.isUrdu ? 'معلومات کامیابی سے اپ ڈیٹ ہو گئیں!' : 'Account details updated successfully!'),
                                backgroundColor: SoftPalette.green400,
                              ),
                            );
                          }
                        } on FirebaseAuthException catch (e) {
                          setDs(() => isSaving = false);
                          if (e.code == 'wrong-password' || e.code == 'invalid-credential') {
                            setDs(() => currentPwError = context.t('Incorrect current password'));
                          } else {
                            if (ctx.mounted) {
                              AppToast.showSnackBar(context, 
                                SnackBar(content: Text(e.message ?? 'Failed to update account'), backgroundColor: SoftPalette.red400),
                              );
                            }
                          }
                        } catch (e) {
                          setDs(() => isSaving = false);
                          if (ctx.mounted) {
                            AppToast.showSnackBar(context, 
                              SnackBar(content: Text('Error: $e'), backgroundColor: SoftPalette.red400),
                            );
                          }
                        }
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: ParentReportCard.primaryColor,
                  foregroundColor: SoftPalette.gray50,
                ),
                child: isSaving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: SoftPalette.gray50))
                    : Text(context.t('Save Changes'), style: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null)),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _claimPtmJoin(BuildContext context) async {
    final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final effBranch = _effectiveBranch;
    try {
      await MadrassaLocalStorage.saveLogRecordLocal(
        branchId: effBranch,
        dateKey: todayStr,
        logData: {
          widget.studentId: {
            'ptmRequestStatus': 'claimed',
            'timestamp': DateTime.now().toIso8601String(),
          }
        },
        editorName: 'Parent/Guardian',
        editorRole: 'guardian',
      ).timeout(const Duration(seconds: 6), onTimeout: () {});

      if (Firebase.apps.isNotEmpty) {
        if (FirebaseAuth.instance.currentUser == null) {
          await FirebaseSessionGuard.ensureSession(reason: 'direct_write');
        }
        await FirebaseFirestore.instance
            .collection('branches')
            .doc(effBranch)
            .collection('madrassa_daily_logs')
            .doc(todayStr)
            .set({
          widget.studentId: {
            'ptmRequestStatus': 'claimed',
            'timestamp': FieldValue.serverTimestamp(),
          }
        }, SetOptions(merge: true))
            .timeout(const Duration(seconds: 8))
            .catchError((err) {
          debugPrint('[ParentReportCard] Claim PTM join note: $err');
        });
      }

      if (mounted) setState(() {});

      if (context.mounted) {
        AppToast.showSnackBar(context, 
          SnackBar(
            content: Text(context.isUrdu 
                ? 'پی ٹی ایم میں شرکت کا دعویٰ بھیج دیا گیا ہے۔ استاد کی منظوری کا انتظار کریں۔' 
                : 'PTM attendance claim submitted. Waiting for teacher approval.'),
            backgroundColor: SoftPalette.green400,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        AppToast.showSnackBar(context, 
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _showReplyTextDialog(BuildContext context, String todayStr) async {
    final replyCtrl = TextEditingController();
    String? replyError;
    bool isSaving = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDs) {
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Text(context.t('Reply to Teacher'), style: TextStyle(fontWeight: FontWeight.bold, fontFamily: context.isUrdu ? 'Noori' : null)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.t('Please enter your reply/comments for the teacher.'),
                  style: TextStyle(fontSize: 12, color: context.adapt(SoftPalette.gray350), fontFamily: context.isUrdu ? 'Noori' : null),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: replyCtrl,
                  maxLines: 3,
                  style: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null),
                  decoration: InputDecoration(
                    hintText: context.t('Enter your reply here...'),
                    errorText: replyError != null ? context.t(replyError!) : null,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onChanged: (v) {
                    if (replyError != null) setDs(() => replyError = null);
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: isSaving ? null : () => Navigator.pop(ctx),
                child: Text(context.t('Cancel'), style: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null)),
              ),
              ElevatedButton(
                onPressed: isSaving
                    ? null
                    : () async {
                        if (replyCtrl.text.trim().isEmpty) {
                          setDs(() => replyError = 'Reply cannot be empty');
                          return;
                        }
                        setDs(() => isSaving = true);
                        try {
                          final effBranch = _effectiveBranch;
                          final text = replyCtrl.text.trim();
                          await MadrassaLocalStorage.saveLogRecordLocal(
                            branchId: effBranch,
                            dateKey: todayStr,
                            logData: {
                              widget.studentId: {
                                'parentReplied': true,
                                'parentRepliedRequested': true,
                                'parentReplyText': text,
                                'parentReplyMessage': text,
                                'parentReplyTime': DateTime.now().toIso8601String(),
                              }
                            },
                            editorName: 'Parent/Guardian',
                            editorRole: 'guardian',
                          ).timeout(const Duration(seconds: 6), onTimeout: () {});

                          if (Firebase.apps.isNotEmpty) {
                            if (FirebaseAuth.instance.currentUser == null) {
                              await FirebaseSessionGuard.ensureSession(reason: 'direct_write');
                            }
                            await FirebaseFirestore.instance
                                .collection('branches')
                                .doc(effBranch)
                                .collection('madrassa_daily_logs')
                                .doc(todayStr)
                                .set({
                              widget.studentId: {
                                'parentReplied': true,
                                'parentRepliedRequested': true,
                                'parentReplyText': text,
                                'parentReplyMessage': text,
                                'parentReplyTime': FieldValue.serverTimestamp(),
                              }
                            }, SetOptions(merge: true))
                                .timeout(const Duration(seconds: 8))
                                .catchError((err) {
                              debugPrint('[ParentReportCard] Reply text note: $err');
                            });
                          }

                          if (mounted) setState(() {});
                          if (ctx.mounted) {
                            Navigator.pop(ctx);
                            AppFeedback.showSuccess(
                              context,
                              context.isUrdu ? 'استاد کو جواب کامیابی سے بھیج دیا گیا!' : 'Reply submitted successfully!',
                              subtitle: 'Saved locally • Syncing to cloud',
                            );
                          }
                        } catch (e) {
                          if (ctx.mounted) {
                            setDs(() => isSaving = false);
                            AppFeedback.showError(context, 'Error submitting reply: $e');
                          }
                        }
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: ParentReportCard.primaryColor,
                  foregroundColor: SoftPalette.gray50,
                ),
                child: isSaving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: SoftPalette.gray50))
                    : Text(context.t('Submit'), style: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null)),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showHifzTargetCongratulationsDialog(BuildContext context, String studentName) {
    showDialog(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 460),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [SoftPalette.emerald700, SoftPalette.teal550, SoftPalette.teal700],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: SoftPalette.amber200, width: 2),
              boxShadow: [
                BoxShadow(
                  color: SoftPalette.amber200.withValues(alpha: 0.35),
                  blurRadius: 30,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Top Trophy & Celebration Animation Badge
                Container(
                  width: 90,
                  height: 90,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      colors: [SoftPalette.yellow150, SoftPalette.amber300, SoftPalette.amber400],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: SoftPalette.amber200.withValues(alpha: 0.6),
                        blurRadius: 20,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: const Center(
                    child: Icon(Icons.emoji_events_rounded, size: 54, color: SoftPalette.orange700),
                  ),
                ),
                const SizedBox(height: 16),

                // Party emoji banner
                const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('🎉', style: TextStyle(fontSize: 22)),
                    SizedBox(width: 6),
                    Text('⭐', style: TextStyle(fontSize: 20)),
                    SizedBox(width: 6),
                    Text('🏆', style: TextStyle(fontSize: 24)),
                    SizedBox(width: 6),
                    Text('⭐', style: TextStyle(fontSize: 20)),
                    SizedBox(width: 6),
                    Text('🎉', style: TextStyle(fontSize: 22)),
                  ],
                ),
                const SizedBox(height: 10),

                // Main Title
                Text(
                  context.isUrdu ? 'ماشاءاللہ! مبارک ہو!' : 'MashaAllah! Congratulations!',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: SoftPalette.yellow150,
                    fontFamily: context.isUrdu ? 'Noori' : null,
                  ),
                ),
                const SizedBox(height: 8),

                // Student Name Banner
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: SoftPalette.gray50.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: SoftPalette.amber200.withValues(alpha: 0.4)),
                  ),
                  child: Text(
                    studentName.isNotEmpty ? studentName : context.t('Student'),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: SoftPalette.gray50,
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                // Congratulatory Body Text
                Text(
                  context.isUrdu
                      ? (isNazraStudent
                          ? 'طالب علم نے ناظرہ قرآن مجید کا ہدف شاندار انداز میں مکمل کر لیا ہے اور ادارہ کی جانب سے خصوصی اعزاز کا حقدار بن گیا ہے!'
                          : 'طالب علم نے 2 سال کے اندر قرآن مجید کے حفظ کا ہدف شاندار انداز میں مکمل کر لیا ہے اور ادارہ کی جانب سے خصوصی اعزازی گفٹ اور نقد انعام (PKR) کا حقدار بن گیا ہے!')
                      : (isNazraStudent
                          ? 'The student has successfully completed the full Nazra Quran reading target and has achieved special honor!'
                          : 'The student has successfully completed the Quran Hifz Target within the record 2-year goal and has won the prestigious Honor Trophy & Cash Reward (PKR)!'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13.5,
                    color: SoftPalette.slate100,
                    height: 1.45,
                    fontFamily: context.isUrdu ? 'Noori' : null,
                  ),
                ),
                const SizedBox(height: 20),

                // Prize Highlights Card
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: SoftPalette.teal800,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: SoftPalette.amber200.withValues(alpha: 0.6)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      Column(
                        children: [
                          const Icon(Icons.workspace_premium_rounded, color: SoftPalette.yellow150, size: 28),
                          const SizedBox(height: 4),
                          Text(
                            context.isUrdu ? 'اعزازی شیلڈ' : 'Honor Trophy',
                            style: TextStyle(fontSize: 11, color: SoftPalette.yellow150, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      Container(height: 36, width: 1, color: SoftPalette.amber200.withValues(alpha: 0.3)),
                      Column(
                        children: [
                          const Icon(Icons.payments_rounded, color: SoftPalette.green300, size: 28),
                          const SizedBox(height: 4),
                          Text(
                            context.isUrdu ? 'نقد انعام (PKR)' : 'Cash Award (PKR)',
                            style: TextStyle(fontSize: 11, color: SoftPalette.green300, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      Container(height: 36, width: 1, color: SoftPalette.amber200.withValues(alpha: 0.3)),
                      Column(
                        children: [
                          const Icon(Icons.card_membership_rounded, color: SoftPalette.cyan200, size: 28),
                          const SizedBox(height: 4),
                          Text(
                            isNazraStudent
                                ? (context.isUrdu ? 'ناظرہ سرٹیفکیٹ' : 'Nazra Certificate')
                                : (context.isUrdu ? 'حفظ سرٹیفکیٹ' : 'Hifz Certificate'),
                            style: TextStyle(fontSize: 11, color: SoftPalette.cyan200, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),

                // Close / Celebrate Button
                ElevatedButton.icon(
                  onPressed: () => Navigator.pop(ctx),
                  icon: const Icon(Icons.celebration_rounded, color: SoftPalette.slate900, size: 18),
                  label: Text(
                    context.isUrdu ? 'شاندار! الحمد للہ' : 'Alhamdulillah! Celebrate',
                    style: const TextStyle(
                      color: SoftPalette.slate900,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: SoftPalette.amber200,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    elevation: 4,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildQuickActions({
    required BuildContext context,
    required Map<String, dynamic> selectedDateLog,
    required String currentStatus,
    required bool isPtmToday,
    required bool needsReply,
  }) {
    final selectedDateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);
    final selectedAtt = selectedDateLog['attendance']?.toString().toLowerCase().trim() ?? '';
    final rawLeaveStatus = selectedDateLog['leaveStatus']?.toString().toLowerCase().trim();
    final leaveStatus = rawLeaveStatus == 'declined'
        ? 'denied'
        : ((rawLeaveStatus == null || rawLeaveStatus.isEmpty)
            ? (selectedAtt == 'leave' ? 'approved' : 'pending')
            : rawLeaveStatus);
    final hasRequestedLeave = selectedAtt == 'leave_requested' || selectedAtt == 'leave';
    final selectedDateReplied = selectedDateLog['parentReplied'] == true;
    final ptmRequestStatus = selectedDateLog['ptmRequestStatus'];
    final ptmJoined = selectedDateLog['ptm'] == true;
    final ptmMissed = selectedDateLog['ptm'] == false;

    final primaryActions = <Widget>[];
    final secondaryActions = <Widget>[];

    // Disable all interactive actions for hifz_completed or archived students
    final studentStatus = (studentData['status']?.toString() ?? 'active').toLowerCase().trim();
    final bool isReadOnly = studentStatus == 'hifz_completed' ||
        studentStatus == 'nazra_completed' ||
        studentStatus == 'archived' ||
        studentStatus == 'left' ||
        studentStatus == 'dropped' ||
        studentStatus == 'dropped_out' ||
        studentStatus == 'inactive';

    if (!isReadOnly && widget.isParentView && currentStatus != 'present' && currentStatus != 'leave' && !hasRequestedLeave) {
      primaryActions.add(
        _quickActionButton(
          label: context.t('Request Leave'),
          icon: Icons.email_rounded,
          color: SoftPalette.amber300,
          onTap: () {
            final now = DateTime.now();
            final today = DateTime(now.year, now.month, now.day);
            final target = _selectedDate.isBefore(today) ? today : _selectedDate;
            _showLeaveReasonDialog(context, widget.branchId, DateFormat('yyyy-MM-dd').format(target), widget.studentId);
          },
        ),
      );
    } else if (selectedAtt == 'leave_requested' && leaveStatus == 'pending') {
      primaryActions.add(
        _quickActionStatus(
          label: context.t('Leave Pending Approval'),
          icon: Icons.hourglass_empty_rounded,
          color: SoftPalette.orange350,
        ),
      );
    } else if (selectedAtt == 'leave' && leaveStatus == 'approved') {
      primaryActions.add(
        _quickActionStatus(
          label: context.isUrdu ? 'رخصت منظور شدہ' : 'Leave Approved',
          icon: Icons.check_circle_rounded,
          color: SoftPalette.green400,
        ),
      );
    }

    if (!isReadOnly && widget.isParentView && !selectedDateReplied) {
      primaryActions.add(
        _quickActionButton(
          label: context.isUrdu ? 'استاد کو جواب دیں' : 'Reply to Teacher',
          icon: Icons.reply_rounded,
          color: SoftPalette.indigo550,
          onTap: () => _showSendReplyDialog(context, selectedDateStr),
        ),
      );
    } else if (selectedDateReplied) {
      primaryActions.add(
        _quickActionStatus(
          label: context.isUrdu ? 'جواب بھیج دیا گیا' : 'Reply Sent',
          icon: Icons.check_circle_rounded,
          color: SoftPalette.green400,
        ),
      );
    }

    if (!isReadOnly && isPtmToday) {
      if (!ptmJoined && !ptmMissed && ptmRequestStatus == null) {
        secondaryActions.add(
          _quickActionButton(
            label: context.t('Claim PTM Join'),
            icon: Icons.people_rounded,
            color: SoftPalette.teal500,
            onTap: () => _claimPtmJoin(context),
          ),
        );
      } else if (ptmRequestStatus == 'claimed') {
        secondaryActions.add(
          _quickActionStatus(
            label: context.t('PTM Claim Pending'),
            icon: Icons.hourglass_empty_rounded,
            color: SoftPalette.teal550,
          ),
        );
      } else if (ptmJoined) {
        secondaryActions.add(
          _quickActionStatus(
            label: context.t('PTM Joined'),
            icon: Icons.check_circle_rounded,
            color: SoftPalette.green400,
          ),
        );
      } else if (ptmMissed) {
        secondaryActions.add(
          _quickActionStatus(
            label: context.t('PTM Missed'),
            icon: Icons.cancel_rounded,
            color: SoftPalette.red400,
          ),
        );
      }
    }

    final bool isMobile = GBreakpoint.isMobile(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: borderColor),
        boxShadow: [
          BoxShadow(color: isDarkMode ? SoftPalette.gray900A26 : SoftPalette.gray900.withOpacity(0.02), blurRadius: 10, offset: const Offset(0, 4))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle(label: context.t('Quick Actions'), icon: Icons.bolt),
          const SizedBox(height: 12),
          if (primaryActions.isNotEmpty) ...[
            _buildActionGroup(primaryActions, isMobile),
            if (secondaryActions.isNotEmpty) const SizedBox(height: 8),
          ],
          if (secondaryActions.isNotEmpty) _buildActionGroup(secondaryActions, isMobile),
        ],
      ),
    );
  }

  Widget _buildActionGroup(List<Widget> actions, bool isMobile) {
    if (actions.isEmpty) return const SizedBox();
    if (isMobile) {
      return Column(
        children: actions.map((a) => Padding(
          padding: const EdgeInsets.only(bottom: 8.0),
          child: a,
        )).toList(),
      );
    }

    if (actions.length == 1) {
      return actions.first;
    }

    return Row(
      children: actions.map((a) => Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6.0),
          child: a,
        ),
      )).toList(),
    );
  }

  Widget _quickActionButton({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.25), width: 1.5),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13, fontFamily: context.isUrdu ? 'Noori' : null),
            ),
          ],
        ),
      ),
    );
  }

  Widget _quickActionStatus({
    required String label,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.12)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12, fontFamily: context.isUrdu ? 'Noori' : null),
          ),
        ],
      ),
    );
  }

  void _updateSelectedDateForNewMonth() {
    final now = DateTime.now();
    if (_selectedYear == now.year && _selectedMonth == now.month) {
      _selectedDate = now;
    } else {
      _selectedDate = DateTime(_selectedYear, _selectedMonth, 1);
    }
  }

  void _onMonthChanged() {
    _updateSelectedDateForNewMonth();
    _logsStream = MadrassaLocalStorage.streamLogsForMonthCached(widget.branchId, _selectedYear, _selectedMonth);
    final now = DateTime.now();
    final isCurrent = _selectedYear == now.year && _selectedMonth == now.month;
    final cached = MadrassaLocalStorage.getLogsForMonthCached(widget.branchId, _selectedYear, _selectedMonth);
    if ((cached.isEmpty || isCurrent) && widget.branchId.isNotEmpty) {
      MadrassaLocalStorage.downloadLogsForMonth(widget.branchId, _selectedYear, _selectedMonth);
    }
  }

  String _formatRemainingTime(double days) {
    if (days.isInfinite || days.isNaN || days <= 0) {
      return context.isUrdu ? 'رخصت / بغیر رفتار کے' : 'Paused (On Leave)';
    }
    final int totalDays = days.round();
    int years = totalDays ~/ 365;
    int months = (totalDays % 365) ~/ 30;
    int remainingDays = (totalDays % 365) % 30;

    if (months == 12) {
      years += 1;
      months = 0;
    }

    if (context.isUrdu) {
      final parts = <String>[];
      if (years > 0) parts.add('$years سال');
      if (months > 0) parts.add('$months مہینے');
      if (years == 0 && months == 0) parts.add('$remainingDays دن');
      return parts.join('، ');
    } else {
      final parts = <String>[];
      if (years > 0) parts.add('$years ${years == 1 ? "year" : "years"}');
      if (months > 0) parts.add('$months ${months == 1 ? "month" : "months"}');
      if (years == 0 && months == 0) parts.add('$remainingDays ${remainingDays == 1 ? "day" : "days"}');
      return parts.join(', ');
    }
  }

  String _formatDuration(DateTime start, DateTime end) {
    int years = end.year - start.year;
    int months = end.month - start.month;
    int days = end.day - start.day;

    if (days < 0) {
      months -= 1;
      final prevMonth = DateTime(end.year, end.month, 0);
      days += prevMonth.day;
    }
    if (months < 0) {
      years -= 1;
      months += 12;
    }

    if (context.isUrdu) {
      final parts = <String>[];
      if (years > 0) parts.add('$years سال');
      if (months > 0) parts.add('$months مہینے');
      if (days > 0 || parts.isEmpty) parts.add('$days دن');
      return parts.join('، ');
    } else {
      final parts = <String>[];
      if (years > 0) parts.add('$years ${years == 1 ? "year" : "years"}');
      if (months > 0) parts.add('$months ${months == 1 ? "month" : "months"}');
      if (days > 0 || parts.isEmpty) parts.add('$days ${days == 1 ? "day" : "days"}');
      return parts.join(', ');
    }
  }

  String _formatMonthYear(DateTime date) {
    if (context.isUrdu) {
      final monthsUr = {
        1: 'جنوری',
        2: 'فروری',
        3: 'مارچ',
        4: 'اپریل',
        5: 'مئی',
        6: 'جون',
        7: 'جولائی',
        8: 'اگست',
        9: 'ستمبر',
        10: 'اکتوبر',
        11: 'نومبر',
        12: 'دسمبر',
      };
      return '${monthsUr[date.month]} ${date.year}';
    }
    return DateFormat('MMMM yyyy').format(date);
  }

  String _formatMonth(DateTime date) {
    if (context.isUrdu) {
      final monthsUr = {
        1: 'جنوری',
        2: 'فروری',
        3: 'مارچ',
        4: 'اپریل',
        5: 'مئی',
        6: 'جون',
        7: 'جولائی',
        8: 'اگست',
        9: 'ستمبر',
        10: 'اکتوبر',
        11: 'نومبر',
        12: 'دسمبر',
      };
      return monthsUr[date.month] ?? '';
    }
    return DateFormat('MMMM').format(date);
  }

  Widget _buildCongratulatoryCard({
    required DateTime joinDate,
    required DateTime completionDate,
    required String studentName,
    VoidCallback? onDismiss,
  }) {
    final durationStr = _formatDuration(joinDate, completionDate);
    final joinDateStr = context.isUrdu 
        ? DateFormat('dd-MM-yyyy').format(joinDate)
        : DateFormat('MMMM d, yyyy').format(joinDate);
    final compDateStr = context.isUrdu
        ? DateFormat('dd-MM-yyyy').format(completionDate)
        : DateFormat('MMMM d, yyyy').format(completionDate);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [SoftPalette.emerald700, SoftPalette.blue500], // Emerald to Royal Blue
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: SoftPalette.emerald700.withValues(alpha: 0.3),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
        border: Border.all(color: SoftPalette.gray50.withValues(alpha: 0.2), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: SoftPalette.gray50.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.stars_rounded,
                  color: SoftPalette.amber200,
                  size: 32,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Alhamdulillah! 🎉',
                      style: TextStyle(
                        color: SoftPalette.amber200,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                        fontFamily: context.isUrdu ? 'Noori' : null,
                      ),
                    ),
                    Text(
                      isNazraStudent
                          ? (context.isUrdu ? 'ناظرہ قرآن کریم کامیابی سے مکمل' : 'Nazra Completed Successfully')
                          : context.t('Hifz Completed Successfully'),
                      style: TextStyle(
                        color: SoftPalette.gray50A70,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        fontFamily: context.isUrdu ? 'Noori' : null,
                      ),
                    ),
                  ],
                ),
              ),
              if (onDismiss != null)
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: SoftPalette.gray50A70, size: 22),
                  tooltip: context.isUrdu ? 'پیغام بند کریں' : 'Close message for this month',
                  onPressed: onDismiss,
                ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            context.isUrdu
                ? (isNazraStudent
                    ? 'محترم والدین، ہم آپ کو اور آپ کے خاندان کو دلی مبارکباد پیش کرتے ہیں! اللہ تعالیٰ کے فضل و کرم سے، $studentName نے ناظرہ قرآن پاک (8,640 لائنیں) مکمل کر لیا ہے۔'
                    : 'محترم والدین، ہم آپ کو اور آپ کے خاندان کو دلی مبارکباد پیش کرتے ہیں! اللہ تعالیٰ کے فضل و کرم سے، $studentName نے قرآن پاک کا حفظ (8,640 لائنیں) مکمل کر لیا ہے۔')
                : (isNazraStudent
                    ? 'Dear Parents, we offer our warmest congratulations to you and your family! By the grace of Almighty Allah, $studentName has completed the full Nazra reading of the Holy Quran Majeed (8,640 lines).'
                    : 'Dear Parents, we offer our warmest congratulations to you and your family! By the grace of Almighty Allah, $studentName has completed the memorization of the Holy Quran Majeed (8,640 lines).'),
            style: TextStyle(
              color: SoftPalette.gray50,
              fontSize: 14,
              height: 1.5,
              fontWeight: FontWeight.w500,
              fontFamily: context.isUrdu ? 'Noori' : null,
            ),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: SoftPalette.gray50.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      context.t('Time Taken:'),
                      style: TextStyle(
                        color: SoftPalette.gray50A70,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        fontFamily: context.isUrdu ? 'Noori' : null,
                      ),
                    ),
                    Text(
                      durationStr,
                      style: TextStyle(
                        color: SoftPalette.gray50,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        fontFamily: context.isUrdu ? 'Noori' : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      isNazraStudent
                          ? (context.isUrdu ? 'ناظرہ کا آغاز:' : 'Started Nazra:')
                          : context.t('Started Hifz:'),
                      style: TextStyle(
                        color: SoftPalette.gray50A70,
                        fontSize: 12,
                        fontFamily: context.isUrdu ? 'Noori' : null,
                      ),
                    ),
                    Text(
                      joinDateStr,
                      style: TextStyle(
                        color: SoftPalette.gray50,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        fontFamily: context.isUrdu ? 'Noori' : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      isNazraStudent
                          ? (context.isUrdu ? 'ناظرہ کی تکمیل:' : 'Completed Nazra:')
                          : context.t('Completed Hifz:'),
                      style: TextStyle(
                        color: SoftPalette.gray50A70,
                        fontSize: 12,
                        fontFamily: context.isUrdu ? 'Noori' : null,
                      ),
                    ),
                    Text(
                      compDateStr,
                      style: TextStyle(
                        color: SoftPalette.gray50,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        fontFamily: context.isUrdu ? 'Noori' : null,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: ElevatedButton.icon(
              onPressed: () => _showHifzTargetCongratulationsDialog(context, studentName),
              icon: const Icon(Icons.emoji_events_rounded, color: SoftPalette.orange700, size: 18),
              label: Text(
                context.isUrdu ? '🏆 اعزازی ٹرافی اور جشن دیکھیں' : '🏆 View Grand Honor Trophy & Celebration',
                style: const TextStyle(
                  color: SoftPalette.orange700,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: SoftPalette.yellow150,
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildForecastTile({
    required IconData icon,
    required String label,
    required String value,
    required String sub,
    required Color color,
    bool isLongValue = false,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: context.adapt(SoftPalette.gray500)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: isLongValue ? 15 : 18, 
              fontWeight: FontWeight.bold, 
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            sub,
            style: TextStyle(fontSize: 10, color: context.adapt(SoftPalette.gray900A87), fontWeight: FontWeight.w500),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        children: [
          Icon(icon, size: 18, color: context.comfort.brand),
          const SizedBox(width: 12),
          Text(
            '$label: ',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: textPrimary, fontFamily: context.isUrdu ? 'Noori' : null),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(fontSize: 13, color: textMuted, fontFamily: context.isUrdu ? 'Noori' : null),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusChip(String status) {
    Color color;
    String label;

    switch (status) {
      case 'active':
        color = ParentReportCard.successColor;
        label = 'Active';
        break;
      case 'left':
        color = ParentReportCard.errorColor;
        label = 'Left';
        break;
      case 'archived':
        color = SoftPalette.amber300;
        label = 'Archived';
        break;
      case 'hifz_completed':
        color = context.comfort.brand;
        label = 'Hifz Completed';
        break;
      case 'nazra_completed':
        color = isDarkMode ? SoftPalette.teal300 : SoftPalette.teal500;
        label = 'Nazra Completed';
        break;
      default:
        color = context.adapt(SoftPalette.gray350);
        label = status.toUpperCase();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDarkMode ? 0.18 : 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: isDarkMode ? 0.35 : 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            context.t(label),
            style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: 13, fontFamily: context.isUrdu ? 'Noori' : null),
          ),
        ],
      ),
    );
  }

  Widget _buildRejoinUI(String status, String? rejoinRequestStatus, String? rejoinReason, DateTime? rejoinDate) {
    // ── Archived students: show unarchive request ──
    if (status == 'archived') {
      if (rejoinRequestStatus == 'pending') {
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDarkMode ? SoftPalette.amber800 : SoftPalette.yellow50,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: isDarkMode ? SoftPalette.orange400.withValues(alpha: 0.4) : SoftPalette.yellow150),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.hourglass_empty_rounded, color: context.adapt(SoftPalette.orange350), size: 18),
                  const SizedBox(width: 8),
                  Text(
                    context.t('Unarchive Request Pending'),
                    style: TextStyle(fontWeight: FontWeight.bold, color: isDarkMode ? SoftPalette.amber200 : SoftPalette.orange350, fontFamily: context.isUrdu ? 'Noori' : null),
                  ),
                ],
              ),
              if (rejoinReason != null && rejoinReason.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  context.isUrdu
                      ? 'وجہ: "$rejoinReason"'
                      : 'Reason: "$rejoinReason"',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: isDarkMode ? SoftPalette.yellow150 : SoftPalette.orange350, fontFamily: context.isUrdu ? 'Noori' : null),
                ),
              ],
              if (rejoinDate != null) ...[
                const SizedBox(height: 4),
                Text(
                  context.isUrdu
                      ? 'درخواست کی تاریخ: ${DateFormat('yyyy-MM-dd HH:mm').format(rejoinDate)}'
                      : 'Requested on: ${DateFormat('yyyy-MM-dd HH:mm').format(rejoinDate)}',
                  style: TextStyle(fontSize: 10, color: isDarkMode ? SoftPalette.yellow200 : SoftPalette.amber300, fontFamily: context.isUrdu ? 'Noori' : null),
                ),
              ],
            ],
          ),
        );
      }
      return SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: () => _showUnarchiveDialog(context),
          icon: const Icon(Icons.unarchive_rounded, color: SoftPalette.gray50),
          label: Text(context.t('Request Unarchive'), style: TextStyle(color: SoftPalette.gray50, fontFamily: context.isUrdu ? 'Noori' : null)),
          style: ElevatedButton.styleFrom(
            backgroundColor: SoftPalette.amber300,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
        ),
      );
    }

    // ── Hifz / Nazra completed: no rejoin action ──
    if (status == 'hifz_completed' || status == 'nazra_completed') return const SizedBox();

    if (status != 'left') return const SizedBox();

    if (rejoinRequestStatus == 'pending') {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDarkMode ? SoftPalette.amber800 : SoftPalette.yellow50,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: isDarkMode ? SoftPalette.orange400.withValues(alpha: 0.4) : SoftPalette.yellow150),
        ),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.hourglass_empty_rounded, color: isDarkMode ? SoftPalette.amber200 : SoftPalette.orange350, size: 18),
                const SizedBox(width: 8),
                Text(
                  context.t('Rejoin Request Pending'),
                  style: TextStyle(fontWeight: FontWeight.bold, color: isDarkMode ? SoftPalette.amber200 : SoftPalette.orange350, fontFamily: context.isUrdu ? 'Noori' : null),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              context.isUrdu 
                  ? 'وجہ: "${rejoinReason ?? 'وجہ درج نہیں ہے'}"'
                  : 'Reason: "${rejoinReason ?? 'No reason specified'}"',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: isDarkMode ? SoftPalette.yellow150 : SoftPalette.orange350, fontFamily: context.isUrdu ? 'Noori' : null),
            ),
            if (rejoinDate != null) ...[
              const SizedBox(height: 4),
              Text(
                context.isUrdu
                    ? 'درخواست کی تاریخ: ${DateFormat('yyyy-MM-dd HH:mm').format(rejoinDate)}'
                    : 'Requested on: ${DateFormat('yyyy-MM-dd HH:mm').format(rejoinDate)}',
                style: TextStyle(fontSize: 10, color: isDarkMode ? SoftPalette.yellow200 : SoftPalette.amber300, fontFamily: context.isUrdu ? 'Noori' : null),
              ),
            ],
          ],
        ),
      );
    } else {
      return SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: () => _showRejoinDialog(context),
          icon: const Icon(Icons.keyboard_return_rounded, color: SoftPalette.gray50),
          label: Text(context.t('Request Rejoining'), style: TextStyle(color: SoftPalette.gray50, fontFamily: context.isUrdu ? 'Noori' : null)),
          style: ElevatedButton.styleFrom(
            backgroundColor: ParentReportCard.primaryColor,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
        ),
      );
    }
  }

  Widget _buildTimeline(List<Map<String, dynamic>> auditList) {
    if (auditList.isEmpty) {
      return Center(
        child: Text(
          context.t('No history records found.'),
          style: TextStyle(color: textMuted, fontFamily: context.isUrdu ? 'Noori' : null),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.t('Status History Timeline'),
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: textPrimary,
            fontFamily: context.isUrdu ? 'Noori' : null,
          ),
        ),
        const SizedBox(height: 16),
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: auditList.length,
          itemBuilder: (context, idx) {
            final log = auditList[idx];
            final logStatus = log['status'] ?? 'unknown';
            final logType = log['type'] ?? 'info';
            final logDate = _parseDateTime(log['date']);
            final logReason = log['reason'] ?? '';

            Color dotColor = context.adapt(SoftPalette.gray350);
            IconData icon = Icons.circle;
            if (logStatus == 'active' || logType == 'enrollment' || logType == 'rejoin_approval') {
              dotColor = ParentReportCard.successColor;
              icon = Icons.check_circle_outline;
            } else if (logStatus == 'left' || logType == 'rejoin_rejection') {
              dotColor = ParentReportCard.errorColor;
              icon = Icons.error_outline;
            } else if (logStatus == 'archived') {
              dotColor = SoftPalette.amber300;
              icon = Icons.archive_outlined;
            } else if (logStatus == 'hifz_completed') {
              dotColor = context.comfort.brand;
              icon = Icons.stars_outlined;
            } else if (logStatus == 'nazra_completed') {
              dotColor = isDarkMode ? SoftPalette.teal300 : SoftPalette.teal500;
              icon = Icons.menu_book_rounded;
            }

            String displayStatus = context.t(logStatus);
            if (displayStatus == logStatus) {
              displayStatus = logStatus.toUpperCase();
            }
            String displayType = context.t(logType);
            if (displayType == logType) {
              displayType = logType.replaceAll('_', ' ');
            }

            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Column(
                    children: [
                      Icon(icon, color: dotColor, size: 20),
                      if (idx < auditList.length - 1)
                        Expanded(
                          child: Container(
                            width: 2,
                            color: borderColor,
                            margin: const EdgeInsets.symmetric(vertical: 4),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '$displayStatus ($displayType)',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              color: dotColor,
                              fontFamily: context.isUrdu ? 'Noori' : null,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            logReason,
                            style: TextStyle(
                              fontSize: 12,
                              color: textPrimary,
                              fontFamily: context.isUrdu ? 'Noori' : null,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            context.isUrdu
                                ? DateFormat('dd-MM-yyyy, hh:mm a').format(logDate)
                                : DateFormat('dd MMMM yyyy, hh:mm a').format(logDate),
                            style: TextStyle(
                              color: textMuted,
                              fontSize: 10,
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
        ),
      ],
    );
  }

  Widget _buildMonthSelector() {
    final date = DateTime(_selectedYear, _selectedMonth);
    final c = context.comfort;
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.chevron_left_rounded, color: c.textSecondary),
            onPressed: () {
              setState(() {
                if (_selectedMonth == 1) {
                  _selectedMonth = 12;
                  _selectedYear--;
                } else {
                  _selectedMonth--;
                }
                _onMonthChanged();
              });
            },
          ),
          Row(
            children: [
              Icon(Icons.calendar_month_rounded, size: 18, color: c.brand),
              const SizedBox(width: 8),
              Text(
                _formatMonthYear(date),
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: c.textPrimary,
                  fontFamily: context.isUrdu ? 'Noori' : null,
                ),
              ),
            ],
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.chevron_right_rounded, color: c.textSecondary),
            onPressed: () {
              setState(() {
                if (_selectedMonth == 12) {
                  _selectedMonth = 1;
                  _selectedYear++;
                } else {
                  _selectedMonth++;
                }
                _onMonthChanged();
              });
            },
          ),
        ],
      ),
    );
  }



  String _logDocId(dynamic l) {
    if (l is Map) return (l['id'] ?? l['dateKey'] ?? l['date'] ?? '').toString();
    if (l is QueryDocumentSnapshot) return l.id;
    return '';
  }

  static Map<String, dynamic>? _asStringMap(dynamic raw) {
    if (raw == null) return null;
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return null;
  }

  Map<String, dynamic>? _logDocData(dynamic l) {
    if (l is Map) return Map<String, dynamic>.from(l);
    if (l is QueryDocumentSnapshot) return l.data() as Map<String, dynamic>?;
    return null;
  }

  int getLinesCompletedOnDate(DateTime targetDate, List<dynamic> allLogs, String studentId) {
    final targetStr = DateFormat('yyyy-MM-dd').format(targetDate);
    final sorted = [...allLogs]..sort((a, b) => _logDocId(a).compareTo(_logDocId(b))); // oldest first
    
    int targetIndex = sorted.indexWhere((l) => _logDocId(l) == targetStr);
    if (targetIndex == -1) return 0;
    
    final targetLog = _logDocData(sorted[targetIndex]);
    final sLog = _asStringMap(targetLog?[studentId]);
    if (sLog == null) return 0;

    if (sLog.containsKey('sabakLines') && sLog['sabakLines'] != null) {
      final explicit = (sLog['sabakLines'] as num?)?.toInt() ?? int.tryParse(sLog['sabakLines']?.toString() ?? '');
      if (explicit != null) return explicit;
    }
    
    final targetLines = (sLog['currentLines'] as num?)?.toInt() ?? int.tryParse(sLog['currentLines']?.toString() ?? '');
    if (targetLines == null) return 0;

    if (targetLines <= 50) {
      return targetLines;
    }
    
    int prevLines = -1;
    for (int i = targetIndex - 1; i >= 0; i--) {
      final log = _logDocData(sorted[i]);
      final lines = (log?[studentId]?['currentLines'] as num?)?.toInt() ?? int.tryParse(log?[studentId]?['currentLines']?.toString() ?? '');
      if (lines != null) {
        prevLines = lines;
        break;
      }
    }
    
    if (prevLines == -1) {
      prevLines = 0;
    }
    
    return (targetLines - prevLines).clamp(0, 9999);
  }

  Widget _buildDailyDetailsCard(List<dynamic> allLogs, List<Map<String, dynamic>> holidaysData, MadrassaConfig config) {
    final joinDate = _studentJoinDate;
    
    final selectedZero = DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day);
    final joinZero = joinDate != null ? DateTime(joinDate.year, joinDate.month, joinDate.day) : null;
    final now = DateTime.now();
    final nowZero = DateTime(now.year, now.month, now.day);
    final isSelectedToday = _selectedDate.year == now.year && _selectedDate.month == now.month && _selectedDate.day == now.day;
    final todayStr = DateFormat('yyyy-MM-dd').format(now);
    
    final dateStrFormatted = context.isUrdu
        ? '${_selectedDate.day} ${_formatMonth(_selectedDate)} ${_selectedDate.year}'
        : DateFormat('d MMMM yyyy').format(_selectedDate);

    final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);
    Map<String, dynamic>? statusData;
    final cached = MadrassaLocalStorage.getDailyLogCached(widget.branchId, dateStr);
    final cachedLog = (cached != null && cached[widget.studentId] is Map)
        ? Map<String, dynamic>.from(cached[widget.studentId] as Map)
        : <String, dynamic>{};

    Map<String, dynamic> firestoreLog = {};
    try {
      final doc = allLogs.firstWhere((l) => _logDocId(l) == dateStr, orElse: () => <String, dynamic>{});
      final rawData = _logDocData(doc);
      if (rawData != null && rawData[widget.studentId] is Map) {
        firestoreLog = Map<String, dynamic>.from(rawData[widget.studentId] as Map);
      }
    } catch (_) {}

    if (firestoreLog.isNotEmpty || cachedLog.isNotEmpty) {
      statusData = {
        ...firestoreLog,
        ...cachedLog,
      };
    }

    final ptmDate = config.getPtmDate();
    final isSelectedPtm = _selectedDate.year == ptmDate.year &&
        _selectedDate.month == ptmDate.month &&
        _selectedDate.day == ptmDate.day;
    final isSelectedPast = _selectedDate.isBefore(nowZero);

    Widget? ptmBanner;
    if (isSelectedPtm) {
      final ptmAttended = statusData?['ptm'] == true;
      final isFutureOrToday = !isSelectedPast;
      
      Color bannerColor;
      IconData bannerIcon;
      String bannerTitle;
      String bannerSubtitle;
      
      if (isFutureOrToday) {
        bannerColor = ParentReportCard.accentColor;
        bannerIcon = Icons.people_rounded;
        bannerTitle = context.isUrdu ? 'پی ٹی ایم میٹنگ (آج/عنقریب)' : 'PTM Meeting (Today/Upcoming)';
        bannerSubtitle = context.isUrdu 
            ? 'سرپرست اور اساتذہ کی میٹنگ شیڈول ہے۔' 
            : 'Scheduled Parent Teacher Meeting.';
      } else {
        if (ptmAttended) {
          bannerColor = context.adapt(SoftPalette.emerald750);
          bannerIcon = Icons.people_rounded;
          bannerTitle = context.isUrdu ? 'پی ٹی ایم: شامل ہوئے' : 'PTM: Joined';
          bannerSubtitle = context.isUrdu 
              ? 'آپ کامیابی کے ساتھ میٹنگ میں شامل ہوئے تھے۔' 
              : 'You successfully attended this meeting.';
        } else {
          bannerColor = context.adapt(SoftPalette.red500);
          bannerIcon = Icons.people_outline_rounded;
          bannerTitle = context.isUrdu ? 'پی ٹی ایم: شامل نہیں ہوئے' : 'PTM: Missed';
          bannerSubtitle = context.isUrdu 
              ? 'آپ اس میٹنگ میں شامل نہیں ہو سکے۔' 
              : 'You missed this meeting.';
        }
      }
      
      ptmBanner = Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: bannerColor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: bannerColor.withValues(alpha: 0.25), width: 1.5),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: bannerColor.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(bannerIcon, color: bannerColor, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    bannerTitle,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: bannerColor,
                      fontFamily: context.isUrdu ? 'Noori' : null,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    bannerSubtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: bannerColor.withValues(alpha: 0.8),
                      fontWeight: FontWeight.w500,
                      fontFamily: context.isUrdu ? 'Noori' : null,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    
    Widget content;
    
    if (joinZero != null && selectedZero.isBefore(joinZero)) {
      content = Column(
        children: [
          if (ptmBanner != null) ptmBanner,
          _buildStatusInfoRow(
            icon: Icons.info_outline_rounded,
            color: context.adapt(SoftPalette.slate500),
            title: context.isUrdu ? '$dateStrFormatted کا کوئی ریکارڈ نہیں' : "No data for $dateStrFormatted",
            subtitle: context.t("Student was not enrolled in the Madrassa yet."),
          ),
        ],
      );
    } else if (selectedZero.isAfter(nowZero)) {
      content = Column(
        children: [
          if (ptmBanner != null) ptmBanner,
          _buildStatusInfoRow(
            icon: Icons.hourglass_empty_rounded,
            color: SoftPalette.blue400,
            title: context.isUrdu ? '$dateStrFormatted کا کوئی ریکارڈ نہیں' : "No data for $dateStrFormatted",
            subtitle: context.t("This is a future date."),
          ),
        ],
      );
    } else if (_selectedDate.weekday == DateTime.sunday) {
      content = Column(
        children: [
          if (ptmBanner != null) ptmBanner,
          _buildStatusInfoRow(
            icon: Icons.weekend_rounded,
            color: context.adapt(SoftPalette.gray350),
            title: context.isUrdu ? 'اتوار ($dateStrFormatted)' : "Sunday ($dateStrFormatted)",
            subtitle: context.t("Madrassa is closed on Sundays."),
          ),
        ],
      );
    } else {
      Map<String, dynamic>? holidayDoc;
      for (final h in holidaysData) {
        final hDate = h['date'] as DateTime?;
        if (hDate != null && hDate.year == _selectedDate.year && hDate.month == _selectedDate.month && hDate.day == _selectedDate.day) {
          holidayDoc = h;
          break;
        }
      }
      final islamicEvent = IslamicCalendarHelper.getIslamicEvent(_selectedDate);
      if (holidayDoc != null || (islamicEvent != null && islamicEvent.isOfficialHoliday)) {
        final holidayName = holidayDoc != null
            ? holidayDoc['name']?.toString() ?? 'Holiday'
            : (context.isUrdu ? islamicEvent!.titleUr : islamicEvent!.titleEn);
        final holidayDesc = holidayDoc != null
            ? (context.isUrdu ? 'مدرسہ بند ہے: ${holidayDoc['name']}. خوشی سے چھٹی منائیں!' : "Madrassa Closed: ${holidayDoc['name']}. Enjoy your holiday!")
            : (context.isUrdu ? '${islamicEvent!.descriptionUr} - مبارک ہو!' : '${islamicEvent!.descriptionEn} - Mubarak!');
        content = Column(
          children: [
            if (ptmBanner != null) ptmBanner,
            _buildStatusInfoRow(
              icon: islamicEvent != null ? Icons.nightlight_round : Icons.flag_rounded,
              color: islamicEvent != null ? SoftPalette.yellow300 : SoftPalette.green400,
              title: context.isUrdu ? 'تعطیل: $holidayName' : "Holiday: $holidayName",
              subtitle: holidayDesc,
            ),
          ],
        );
      } else {
        if (statusData == null) {
          content = Column(
            children: [
              if (ptmBanner != null) ptmBanner,
              _buildStatusInfoRow(
                icon: Icons.warning_amber_rounded,
                color: SoftPalette.amber300,
                title: context.isUrdu ? '$dateStrFormatted کا کوئی ریکارڈ نہیں' : "No data for $dateStrFormatted",
                subtitle: context.t("No records found for this active day."),
              ),
            ],
          );
        } else {
          final att = statusData['attendance']?.toString() ?? 'absent';

          final leaveReason = statusData['leaveReason']?.toString() ?? '';
          final rawLeaveStatus = statusData['leaveStatus']?.toString().toLowerCase().trim();
          final leaveStatus = rawLeaveStatus == 'declined'
              ? 'denied'
              : ((rawLeaveStatus == null || rawLeaveStatus.isEmpty)
                  ? (att == 'leave' ? 'approved' : 'pending')
                  : rawLeaveStatus);
          final currentLines = (statusData['currentLines'] as num?)?.toInt() ?? int.tryParse(statusData['currentLines']?.toString() ?? '') ?? 0;
          
          final linesRead = getLinesCompletedOnDate(_selectedDate, allLogs, widget.studentId);
          
          final int sabkiParaVal = statusData['sabkiPara'] is int ? statusData['sabkiPara'] as int : (int.tryParse(statusData['sabkiPara']?.toString() ?? '') ?? 0);
          final String? sabkiRatioVal = statusData['sabkiRatio']?.toString();
          final int manzilParaVal = statusData['manzilPara'] is int ? statusData['manzilPara'] as int : (int.tryParse(statusData['manzilPara']?.toString() ?? '') ?? 0);
          final String? manzilRatioVal = statusData['manzilRatio']?.toString();

          String formatRatio(String? ratio) {
            if (ratio == '1/4') return context.isUrdu ? 'پاؤ (1/4)' : 'Pao (1/4)';
            if (ratio == '1/2') return context.isUrdu ? 'نصف (1/2)' : 'Nisf (1/2)';
            if (ratio == '3/4') return context.isUrdu ? 'ثلاثہ (3/4)' : 'Salasa (3/4)';
            if (ratio == '1') return context.isUrdu ? 'پارہ (1)' : 'Para (1)';
            if (ratio == 'nahi_sunaya') return context.isUrdu ? 'نہیں سنایا' : 'Nahi Sunaya';
            return ratio ?? '';
          }

          String sabkiText = context.t('No test today');
          if (sabkiParaVal > 0 && sabkiRatioVal != null && sabkiRatioVal.isNotEmpty && sabkiRatioVal != '-') {
            sabkiText = context.isUrdu
                ? 'پارہ $sabkiParaVal • ${formatRatio(sabkiRatioVal)}'
                : 'Para $sabkiParaVal • ${formatRatio(sabkiRatioVal)}';
          } else if (sabkiRatioVal == 'nahi_sunaya') {
            sabkiText = context.isUrdu ? 'نہیں سنایا' : 'Nahi Sunaya';
          }

          String manzilText = context.t('No test today');
          if (manzilParaVal > 0 && manzilRatioVal != null && manzilRatioVal.isNotEmpty && manzilRatioVal != '-') {
            manzilText = context.isUrdu
                ? 'پارہ $manzilParaVal • ${formatRatio(manzilRatioVal)}'
                : 'Para $manzilParaVal • ${formatRatio(manzilRatioVal)}';
          } else if (manzilRatioVal == 'nahi_sunaya') {
            manzilText = context.isUrdu ? 'نہیں سنایا' : 'Nahi Sunaya';
          }

          final int rukuParaVal = statusData['rukuPara'] is int ? statusData['rukuPara'] as int : (int.tryParse(statusData['rukuPara']?.toString() ?? '') ?? 0);
          final rukuVal = statusData['ruku']?.toString();
          final qaidaSabakVal = statusData['qaidaSabak']?.toString();
          final isQaidaDone = studentData['qaidaCompleted'] == true ||
              studentData['qaidaSabak'] == 'completed' ||
              qaidaSabakVal == 'completed';

          String rukuText = context.t('No test today');
          if (rukuVal == 'nahi_sunaya') {
            rukuText = context.isUrdu ? 'نہیں سنایا' : 'Nahi Sunaya';
          } else if (rukuVal != null && rukuVal.isNotEmpty && rukuVal != '-') {
            if (rukuParaVal > 0) {
              rukuText = context.isUrdu ? 'پارہ $rukuParaVal • $rukuVal رُكوع' : 'Para $rukuParaVal • $rukuVal Ruku';
            } else {
              rukuText = context.isUrdu ? '$rukuVal رُكوع' : '$rukuVal Ruku';
            }
          }

          String qaidaText = isQaidaDone
              ? (context.isUrdu ? 'قاعدہ مکمل ✅' : 'Qaida Completed ✅')
              : (qaidaSabakVal != null && qaidaSabakVal.isNotEmpty && qaidaSabakVal != '-'
                  ? (context.isUrdu ? 'سبق نمبر $qaidaSabakVal / ۲۱' : 'Lesson $qaidaSabakVal / 21')
                  : (context.isUrdu ? 'جاری' : 'In Progress'));

          content = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (ptmBanner != null) ...[
                ptmBanner,
                const SizedBox(height: 12),
              ],
              if (att == 'present') ...[
                // Lesson Progress Section for Present days
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: context.comfort.brand.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: context.comfort.brand.withValues(alpha: 0.12)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: context.comfort.brand.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.menu_book_rounded, color: context.comfort.brand, size: 22),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              context.t("Lesson Progress"),
                              style: TextStyle(fontSize: 12, color: context.comfort.textMuted, fontWeight: FontWeight.bold, fontFamily: context.isUrdu ? 'Noori' : null),
                            ),
                            const SizedBox(height: 8),
                            // Sabak
                            Row(
                              children: [
                                Text(
                                  isNazraStudent
                                      ? (context.isUrdu ? 'سبق (ناظرہ): ' : 'Sabak (Nazra): ')
                                      : '${context.t('Sabak')}: ',
                                  style: TextStyle(fontSize: 13, color: context.comfort.textMuted, fontWeight: FontWeight.bold, fontFamily: context.isUrdu ? 'Noori' : null),
                                ),
                                Expanded(
                                  child: Text(
                                    linesRead > 0
                                        ? (context.isUrdu ? "$linesRead لائنیں" : "$linesRead lines")
                                        : context.t("No lines recorded"),
                                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: context.comfort.brand, fontFamily: context.isUrdu ? 'Noori' : null),
                                  ),
                                ),
                              ],
                            ),
                            if (!isNazraStudent) ...[
                              const SizedBox(height: 6),
                              // Sabki
                              Row(
                                children: [
                                  Text(
                                    '${context.t('Sabki')}: ',
                                    style: TextStyle(fontSize: 13, color: context.comfort.textMuted, fontWeight: FontWeight.bold, fontFamily: context.isUrdu ? 'Noori' : null),
                                  ),
                                  Expanded(
                                    child: Text(
                                      sabkiText,
                                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: context.adapt(SoftPalette.orange400), fontFamily: context.isUrdu ? 'Noori' : null),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              // Manzil
                              Row(
                                children: [
                                  Text(
                                    '${context.t('Manzil')}: ',
                                    style: TextStyle(fontSize: 13, color: context.comfort.textMuted, fontWeight: FontWeight.bold, fontFamily: context.isUrdu ? 'Noori' : null),
                                  ),
                                  Expanded(
                                    child: Text(
                                      manzilText,
                                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: context.adapt(SoftPalette.indigo550), fontFamily: context.isUrdu ? 'Noori' : null),
                                    ),
                                  ),
                                ],
                              ),
                            ] else ...[
                              const SizedBox(height: 6),
                              // Ruku (replaces Sabki for Nazra)
                              Row(
                                children: [
                                  Text(
                                    context.isUrdu ? 'رُكوع: ' : 'Ruku (رُكوع): ',
                                    style: TextStyle(fontSize: 13, color: context.comfort.textMuted, fontWeight: FontWeight.bold, fontFamily: context.isUrdu ? 'Noori' : null),
                                  ),
                                  Expanded(
                                    child: Text(
                                      rukuText,
                                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: context.adapt(SoftPalette.orange400), fontFamily: context.isUrdu ? 'Noori' : null),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              // Qaida Sabak (replaces Manzil for Nazra)
                              Row(
                                children: [
                                  Text(
                                    context.isUrdu ? 'قاعدہ سبق: ' : 'Qaida Sabak: ',
                                    style: TextStyle(fontSize: 13, color: context.comfort.textMuted, fontWeight: FontWeight.bold, fontFamily: context.isUrdu ? 'Noori' : null),
                                  ),
                                  Expanded(
                                    child: Text(
                                      qaidaText,
                                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: isQaidaDone ? context.adapt(SoftPalette.green400) : context.adapt(SoftPalette.indigo550), fontFamily: context.isUrdu ? 'Noori' : null),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                            const SizedBox(height: 10),
                            const Divider(),
                            const SizedBox(height: 6),
                            Text(
                              context.isUrdu ? "مجموعی: لائن $currentLines" : "Cumulative: Line $currentLines",
                              style: TextStyle(fontSize: 11, color: context.comfort.textMuted, fontFamily: context.isUrdu ? 'Noori' : null),
                            ),
                            const SizedBox(height: 12),
                            Divider(color: context.comfort.brand.withValues(alpha: 0.15)),
                            const SizedBox(height: 8),
                            _buildParentReplyStatusRow(context, dateStr, statusData),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ] else if (att == 'leave' || att == 'leave_requested') ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: context.adapt(SoftPalette.amber100m),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: context.adapt(SoftPalette.amber200)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            (att == 'leave_requested' && leaveStatus == 'pending')
                                ? Icons.hourglass_empty_rounded
                                : Icons.event_busy_rounded,
                            color: context.adapt(SoftPalette.amber300),
                            size: 22,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            (att == 'leave_requested' && leaveStatus == 'pending')
                                ? (context.isUrdu ? 'رخصت کی درخواست زیر التوا ہے' : 'Leave Request Pending')
                                : (context.isUrdu ? 'طالب علم رخصت پر تھا' : 'Student was on Leave'),
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: context.adapt(SoftPalette.orange400), fontFamily: context.isUrdu ? 'Noori' : null),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (leaveReason.isNotEmpty) ...[
                        Text(context.t("Leave Reason:"), style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: context.adapt(SoftPalette.gray550), fontFamily: context.isUrdu ? 'Noori' : null)),
                        const SizedBox(height: 4),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: context.adapt(SoftPalette.gray50),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: context.adapt(SoftPalette.amber150)),
                          ),
                          child: Text(
                            leaveReason,
                            style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: context.adapt(SoftPalette.gray700), fontFamily: context.isUrdu ? 'Noori' : null),
                          ),
                        ),
                        const SizedBox(height: 10),
                      ],
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Text(context.t("Approval Status: "), style: TextStyle(fontSize: 12, color: context.adapt(SoftPalette.gray550), fontFamily: context.isUrdu ? 'Noori' : null)),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: (leaveStatus == 'approved' ? SoftPalette.green400 : (leaveStatus == 'denied' ? SoftPalette.red400 : SoftPalette.amber200)).withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  context.t(leaveStatus).toUpperCase(),
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: leaveStatus == 'approved' ? SoftPalette.green400 : (leaveStatus == 'denied' ? SoftPalette.red400 : SoftPalette.orange350),
                                    fontFamily: context.isUrdu ? 'Noori' : null,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (statusData?['isParentRequested'] == true)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: SoftPalette.amber300.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                context.isUrdu ? 'والدین کی درخواست' : 'Parent Requested',
                                style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: SoftPalette.orange400, fontFamily: context.isUrdu ? 'Noori' : null),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Divider(color: context.adapt(SoftPalette.amber200)),
                      const SizedBox(height: 8),
                      _buildParentReplyStatusRow(context, dateStr, statusData),
                    ],
                  ),
                ),
              ] else ...[
                // ABSENT CARD
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: isDarkMode ? SoftPalette.red900 : SoftPalette.pink100m,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: SoftPalette.red500.withValues(alpha: isDarkMode ? 0.4 : 0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.cancel_rounded, color: context.adapt(SoftPalette.red500), size: 22),
                          const SizedBox(width: 10),
                          Text(
                            context.isUrdu ? 'طالب علم غیر حاضر تھا (Absent)' : 'Student Marked ABSENT',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: context.adapt(SoftPalette.red500), fontFamily: context.isUrdu ? 'Noori' : null),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        leaveStatus == 'denied'
                            ? (context.isUrdu
                                ? 'رخصت کی درخواست مسترد کر دی گئی تھی۔ طالب علم غیر حاضر شمار ہوگا۔'
                                : 'Leave request was denied. Student is marked absent on this date.')
                            : (context.isUrdu ? 'طالب علم اس تاریخ کو مدرسہ میں غیر حاضر تھا۔' : 'Child did not attend Madrassa on this date.'),
                        style: TextStyle(fontSize: 12, color: isDarkMode ? SoftPalette.red300 : SoftPalette.red550, fontFamily: context.isUrdu ? 'Noori' : null),
                      ),
                      const SizedBox(height: 12),
                      Divider(color: context.adapt(SoftPalette.red500).withValues(alpha: 0.3)),
                      const SizedBox(height: 8),
                      _buildParentReplyStatusRow(context, dateStr, statusData),
                    ],
                  ),
                ),
              ],
            ],
          );
        }
      }
    }
    
    final hijri = IslamicCalendarHelper.fromGregorian(_selectedDate).format(isUrdu: context.isUrdu);
    final dayText = context.isUrdu ? '${_selectedDate.day} ${_formatMonth(_selectedDate)}' : DateFormat('EEE d MMM').format(_selectedDate);
    return MadrassaCard(
      icon: Icons.event_note_rounded,
      title: context.t('Daily Details'),
      subtitle: '$dayText  ·  $hijri',
      child: content,
    );
  }

  Widget _buildStatusInfoRow({required IconData icon, required Color color, required String title, required String subtitle}) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.1), shape: BoxShape.circle),
          child: Icon(icon, color: color, size: 24),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color, fontFamily: context.isUrdu ? 'Noori' : null)),
              const SizedBox(height: 2),
              Text(subtitle, style: TextStyle(fontSize: 12, color: context.adapt(SoftPalette.gray350), fontFamily: context.isUrdu ? 'Noori' : null)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildReminders({
    required bool isPtm,
    required bool needsReply,
    required String leaveStatus,
    required String attendanceStatus,
    required List<Map<String, dynamic>> holidaysData,
    String? dateStr,
  }) {
    final now = DateTime.now();
    final todayZero = DateTime(now.year, now.month, now.day);
    final tomorrowZero = todayZero.add(const Duration(days: 1));

    // 1. Holiday detection for today, tomorrow, or upcoming 7 days
    Map<String, dynamic>? todayHoliday;
    Map<String, dynamic>? tomorrowHoliday;
    final upcomingHolidays = <Map<String, dynamic>>[];

    for (final h in holidaysData) {
      final rawDate = h['date'];
      final hDate = rawDate is DateTime ? rawDate : _parseDateTime(rawDate);
      final hZero = DateTime(hDate.year, hDate.month, hDate.day);
      if (hZero == todayZero) {
        todayHoliday = h;
      } else if (hZero == tomorrowZero) {
        tomorrowHoliday = h;
      } else if (hZero.isAfter(tomorrowZero) && hZero.isBefore(todayZero.add(const Duration(days: 7)))) {
        upcomingHolidays.add({...h, 'dateTime': hDate});
      }
    }

    final reminders = <Widget>[];

    // Today's Holiday Announcement
    if (todayHoliday != null) {
      final holidayName = todayHoliday['name']?.toString() ?? 'Holiday';
      reminders.add(_reminderCard(
        title: context.isUrdu ? 'آج مدرسہ بند ہے (تعطیل)' : 'Madrassa Closed Today',
        body: context.isUrdu
            ? 'مدرسہ آج "$holidayName" کے باعث بند رہے گا۔'
            : 'Madrassa is closed today due to "$holidayName".',
        icon: Icons.beach_access_rounded,
        color: SoftPalette.teal500,
        isUrgent: true,
      ));
    }

    // Tomorrow's Holiday Notice
    if (tomorrowHoliday != null) {
      final holidayName = tomorrowHoliday['name']?.toString() ?? 'Holiday';
      reminders.add(_reminderCard(
        title: context.isUrdu ? 'کل تعطیل کا پیشگی نوٹس' : 'Holiday Notice (Tomorrow)',
        body: context.isUrdu
            ? 'مدرسہ کل "$holidayName" کے باعث بند رہے گا۔'
            : 'Madrassa will remain closed tomorrow due to "$holidayName".',
        icon: Icons.event_busy_rounded,
        color: SoftPalette.orange400,
        isUrgent: true,
      ));
    }

    // Upcoming Holidays in next 7 days
    for (final h in upcomingHolidays) {
      final holidayName = h['name']?.toString() ?? 'Holiday';
      final hDate = h['dateTime'] as DateTime;
      final dateFormatted = context.isUrdu
          ? '${hDate.day} ${_formatMonth(hDate)}'
          : DateFormat('EEEE, d MMM').format(hDate);
      reminders.add(_reminderCard(
        title: context.isUrdu ? 'تعطیل کا پیشگی نوٹس' : 'Upcoming Holiday Notice',
        body: context.isUrdu
            ? 'مدرسہ $dateFormatted کو "$holidayName" کے باعث بند رہے گا۔'
            : 'Madrassa will be closed on $dateFormatted due to "$holidayName".',
        icon: Icons.campaign_rounded,
        color: SoftPalette.sky500,
      ));
    }

    // PTM Meeting Reminder
    if (isPtm) {
      reminders.add(_reminderCard(
        title: context.isUrdu ? 'آج سرپرست اساتذہ میٹنگ (PTM)' : 'Parent-Teacher Meeting Today',
        body: context.isUrdu
            ? 'آج پی ٹی ایم ہے۔ اپنے بچے کی حفظ و تعلیم کی پیشرفت کے لیے مدرسہ ضرور تشریف لائیں۔'
            : 'Today is PTM day. Please visit the Madrassa to discuss your child\'s Quranic progress.',
        icon: Icons.groups_rounded,
        color: SoftPalette.orange400,
        isUrgent: true,
      ));
    }

    // Parent Reply Needed
    if (needsReply) {
      reminders.add(_reminderCard(
        title: context.isUrdu ? 'استاد کے پیغام کا جواب درکار ہے' : 'Teacher Message Reply Needed',
        body: context.isUrdu
            ? 'بچے کی روزانہ کی پڑھائی اور حاضری پر استاد کو جوابی تاثرات بھیجیں۔'
            : 'Please send your reply/feedback to the teacher\'s daily report message.',
        icon: Icons.mark_chat_unread_rounded,
        color: SoftPalette.violet550,
        actionLabel: context.isUrdu ? 'جواب دیں' : 'Reply Now',
        onAction: dateStr != null ? () => _showSendReplyDialog(context, dateStr) : null,
      ));
    }

    // Leave Denied — only warn "Marked absent" when the student really is absent
    // (not if the teacher later marked them present or granted leave).
    final normLeaveStatus = leaveStatus.toLowerCase().trim();
    final normAttStatus = attendanceStatus.toLowerCase().trim();
    if ((normLeaveStatus == 'denied' || normLeaveStatus == 'declined') &&
        normAttStatus != 'present' &&
        normAttStatus != 'leave') {
      reminders.add(_reminderCard(
        title: context.isUrdu ? 'درخواست رخصت مسترد' : 'Leave Request Denied',
        body: context.isUrdu
            ? '${studentData['name'] ?? 'طالب علم'} کی رخصت کی درخواست منظور نہیں ہو سکی۔ وہ غائب شمار ہوں گے۔'
            : 'Your leave request for ${studentData['name'] ?? 'the student'} was not approved. Marked absent.',
        icon: Icons.error_outline_rounded,
        color: SoftPalette.red500,
      ));
    }

    if (reminders.isEmpty) return const SizedBox.shrink();

    return Column(
      children: reminders,
    );
  }

  Widget _reminderCard({
    required String title,
    required String body,
    required IconData icon,
    required Color color,
    bool isUrgent = false,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    // Theme tone instead of the caller's fixed palette colour: red-ish means a
    // problem, urgent means needs action, anything else is information.
    final c = context.comfort;
    final hsv = HSVColor.fromColor(color);
    final redHue = hsv.hue < 20 || hsv.hue > 340;
    final tone = redHue ? c.danger : (isUrgent ? c.warning : c.brand);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: MadrassaCard(
        tone: tone,
        icon: icon,
        title: title,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text(body, style: TextStyle(fontSize: 13, height: 1.45, color: c.textSecondary, fontFamily: context.isUrdu ? 'Noori' : null)),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: tone, foregroundColor: c.onBrand, visualDensity: VisualDensity.compact),
                onPressed: onAction,
                icon: const Icon(Icons.reply_rounded, size: 16),
                label: Text(actionLabel, style: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null)),
              ),
            ),
          ],
        ]),
      ),
    );
  }

  String _requestStatusFilter = 'all';

  void _showEnlargedPhotoDialog(BuildContext context, String? photoUrl, String name) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.topRight,
              child: IconButton(
                icon: const Icon(Icons.close, color: SoftPalette.gray50, size: 30),
                onPressed: () => Navigator.pop(ctx),
              ),
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: () {
                final str = photoUrl?.toString().trim();
                final bytes = ImageUploadService.decodeBase64ToBytes(str);
                if (bytes != null) {
                  return Image.memory(bytes, fit: BoxFit.contain, width: 300, height: 300);
                } else if (str != null && str.startsWith('http')) {
                  return Image.network(str, fit: BoxFit.contain, width: 300, height: 300);
                }
                return Container(
                  width: 250,
                  height: 250,
                  color: SoftPalette.teal550,
                  alignment: Alignment.center,
                  child: Text(
                    name.isNotEmpty ? name[0] : '?',
                    style: const TextStyle(color: SoftPalette.gray50, fontSize: 80, fontWeight: FontWeight.bold),
                  ),
                );
              }(),
            ),
            const SizedBox(height: 12),
            Text(
              name,
              style: const TextStyle(color: SoftPalette.gray50, fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }

  void _showDownloadReportDialog(
    BuildContext context,
    MadrassaConfig displayConfig,
    Map<String, dynamic> studentData,
    List<dynamic> monthLogs,
    List<DateTime> holidays,
  ) {
    int selectedYear = _selectedYear;
    int selectedMonth = _selectedMonth;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: Row(
                children: [
                  Icon(Icons.picture_as_pdf_rounded, color: context.adapt(SoftPalette.teal550)),
                  const SizedBox(width: 10),
                  Text(
                    context.isUrdu ? 'رپورٹ ڈاؤن لوڈ کریں' : 'Download Monthly Report',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, fontFamily: context.isUrdu ? 'Noori' : null),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    context.isUrdu ? 'براہ کرم جس مہینے کی رپورٹ چاہتے ہیں وہ منتخب کریں:' : 'Select the month for your download:',
                    style: TextStyle(fontSize: 13, color: context.adapt(SoftPalette.gray350)),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      DropdownButton<int>(
                        value: selectedMonth,
                        items: List.generate(12, (index) {
                          final m = index + 1;
                          final monthName = DateFormat('MMMM').format(DateTime(selectedYear, m));
                          return DropdownMenuItem(value: m, child: Text(monthName));
                        }),
                        onChanged: (val) {
                          if (val != null) setDialogState(() => selectedMonth = val);
                        },
                      ),
                      const SizedBox(width: 16),
                      DropdownButton<int>(
                        value: selectedYear,
                        items: [DateTime.now().year - 1, DateTime.now().year, DateTime.now().year + 1].map((y) {
                          return DropdownMenuItem(value: y, child: Text('$y'));
                        }).toList(),
                        onChanged: (val) {
                          if (val != null) setDialogState(() => selectedYear = val);
                        },
                      ),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(context.isUrdu ? 'منسوخ' : 'Cancel'),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: SoftPalette.teal550,
                    foregroundColor: SoftPalette.gray50,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () {
                    Navigator.pop(ctx);
                    AppToast.showSnackBar(context, 
                      SnackBar(content: Text(context.t('Preparing your PDF report...')), backgroundColor: SoftPalette.teal550),
                    );
                    MadrassaReportHelper.exportIndividualPdf(
                      config: displayConfig,
                      studentId: widget.studentId,
                      studentData: studentData,
                      logs: monthLogs,
                      holidays: holidays,
                    );
                  },
                  icon: const Icon(Icons.picture_as_pdf_rounded, size: 18),
                  label: const Text('PDF Download'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Map<String, dynamic> _calculateEstimationData(List<dynamic> allLogs) {
    int sumOfSabakLines = 0;
    int maxLogCurrentLines = 0;
    for (final doc in allLogs) {
      final rawData = _logDocData(doc);
      final studentLog = _asStringMap(rawData?[widget.studentId]);
      if (studentLog != null) {
        final sLines = (studentLog['sabakLines'] as num?)?.toInt() ?? int.tryParse(studentLog['sabakLines']?.toString() ?? '');
        if (sLines != null && sLines > 0) {
          sumOfSabakLines += sLines;
        }
        final cLines = (studentLog['currentLines'] as num?)?.toInt() ?? int.tryParse(studentLog['currentLines']?.toString() ?? '');
        if (cLines != null && cLines > maxLogCurrentLines) {
          maxLogCurrentLines = cLines;
        }
      }
    }

    final studentCurrentLines = (studentData['currentLines'] as num?)?.toInt() ?? 0;
    final prevLines = int.tryParse(studentData['prevHifzLines']?.toString() ?? '0') ?? 0;

    final effectiveCurrentLines = [studentCurrentLines, maxLogCurrentLines, sumOfSabakLines].reduce(math.max);
    final totalMemorized = (effectiveCurrentLines + prevLines).clamp(0, 8640);

    final dynamic joinField = studentData['joinDate'];
    DateTime? joinDate;
    if (joinField is Timestamp) {
      joinDate = joinField.toDate();
    } else if (joinField is String) {
      joinDate = DateTime.tryParse(joinField);
    }
    final daysSinceJoin = (joinDate != null) ? DateTime.now().difference(joinDate).inDays : 0;
    final overallAvg = daysSinceJoin > 0 ? totalMemorized / daysSinceJoin : 0.0;

    final studentStatus = (studentData['status']?.toString() ?? 'active').toLowerCase().trim();
    final bool isStatusOnLeave = studentStatus == 'leave' ||
        studentStatus == 'on_leave' ||
        studentStatus == 'archived' ||
        studentStatus == 'left' ||
        studentStatus == 'dropped' ||
        studentStatus == 'inactive';

    double recentDailyRate = 0.0;
    bool hasActiveRecentPace = false;
    try {
      final logsList = <MapEntry<DateTime, int>>[];
      for (final doc in allLogs) {
        final date = DateTime.tryParse(_logDocId(doc));
        if (date == null) continue;
        final rawData = _logDocData(doc);
        final studentLog = _asStringMap(rawData?[widget.studentId]);
        if (studentLog != null) {
          final lines = (studentLog['currentLines'] as num?)?.toInt();
          if (lines != null && lines > 0) {
            logsList.add(MapEntry(date, lines));
          }
        }
      }

      if (logsList.length >= 2) {
        logsList.sort((a, b) => a.key.compareTo(b.key));
        final latest = logsList.last;
        MapEntry<DateTime, int>? bestRef;
        for (int i = logsList.length - 2; i >= 0; i--) {
          final ref = logsList[i];
          final daysDiff = latest.key.difference(ref.key).inDays;
          if (daysDiff >= 7 && daysDiff <= 45) {
            bestRef = ref;
            if (daysDiff >= 14) break;
          }
        }
        if (bestRef == null) {
          for (final ref in logsList) {
            if (ref.key != latest.key) {
              bestRef = ref;
              break;
            }
          }
        }
        if (bestRef != null) {
          final daysDiff = latest.key.difference(bestRef.key).inDays;
          final linesDiff = latest.value - bestRef.value;
          if (daysDiff > 0 && linesDiff >= 0) {
            final pace = linesDiff / daysDiff;
            if (pace >= 0.3) {
              recentDailyRate = pace;
              hasActiveRecentPace = true;
            }
          }
        }
      }
    } catch (_) {}

    final remainingLines = (8640 - totalMemorized).clamp(0, 8640);
    final double effectiveRate = isStatusOnLeave ? 0.0 : (hasActiveRecentPace ? recentDailyRate : overallAvg);
    final bool isPaused = isStatusOnLeave;
    final bool isLowPace = !isPaused && effectiveRate < 1.0;

    final int? estimatedDays = (!isPaused && effectiveRate >= 0.1 && remainingLines > 0)
        ? (remainingLines / effectiveRate).ceil()
        : null;

    String estCompletionStr;
    if (isPaused) {
      estCompletionStr = context.isUrdu ? 'رخصت (رفتار رکی ہوئی ہے)' : 'Paused (On Leave)';
    } else if (isLowPace) {
      estCompletionStr = context.isUrdu ? 'ابتدائی رفتار' : 'Building Pace';
    } else if (estimatedDays != null) {
      final completionDate = DateTime.now().add(Duration(days: estimatedDays.clamp(1, 1095)));
      estCompletionStr = DateFormat('MMM yyyy').format(completionDate);
    } else {
      estCompletionStr = '—';
    }

    final double paceWeekly = effectiveRate * 7;
    final double daysRemainingDouble = (estimatedDays ?? 0).toDouble();

    return {
      'totalMemorized': totalMemorized,
      'recentDailyRate': effectiveRate,
      'remainingLines': remainingLines,
      'estimatedDays': estimatedDays,
      'estCompletionStr': estCompletionStr,
      'paceWeekly': paceWeekly,
      'daysRemaining': daysRemainingDouble,
      'overallAvg': overallAvg,
      'isPaused': isPaused,
      'isLowPace': isLowPace,
    };
  }

  void _showAccountMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: borderColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Icon(Icons.settings_rounded, color: isDarkMode ? SoftPalette.teal300 : SoftPalette.teal550),
                  const SizedBox(width: 12),
                  Text(
                    context.isUrdu ? 'اکاؤنٹس اور خصوصیات' : 'Accounts & Settings',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                      color: textPrimary,
                      fontFamily: context.isUrdu ? 'Noori' : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (widget.allDocs.length > 1) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    context.isUrdu ? 'طالب علم منتخب کریں:' : 'Switch Student:',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: textMuted),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 44,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: widget.allDocs.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (ctx, i) {
                      final doc = widget.allDocs[i];
                      final d = doc is Map ? Map<String, dynamic>.from(doc) : (doc is DocumentSnapshot ? (doc.data() as Map<String, dynamic>?) ?? {} : <String, dynamic>{});
                      final selected = i == widget.selectedIndex;
                      return ChoiceChip(
                        selected: selected,
                        selectedColor: isDarkMode ? SoftPalette.teal600 : SoftPalette.teal550,
                        backgroundColor: isDarkMode ? SoftPalette.slate800 : null,
                        side: BorderSide(color: isDarkMode ? borderColor : SoftPalette.gray150),
                        label: Text(
                          d['name'] ?? 'Student ${i + 1}',
                          style: TextStyle(color: selected ? SoftPalette.gray50 : textPrimary),
                        ),
                        onSelected: (_) {
                          Navigator.pop(ctx);
                          widget.onStudentChanged(i);
                        },
                      );
                    },
                  ),
                ),
                Divider(height: 24, color: dividerColor),
              ],
              ListTile(
                leading: Icon(Icons.edit_note_rounded, color: isDarkMode ? SoftPalette.teal300 : SoftPalette.teal550),
                title: Text(context.t('Edit Account Details'), style: TextStyle(color: textPrimary)),
                onTap: () {
                  Navigator.pop(ctx);
                  _showEditGuardianInfoDialog(context);
                },
              ),
              ListTile(
                leading: Icon(Icons.lock_reset_rounded, color: isDarkMode ? SoftPalette.teal300 : SoftPalette.teal550),
                title: Text(context.t('Change Password'), style: TextStyle(color: textPrimary)),
                onTap: () {
                  Navigator.pop(ctx);
                  _showChangePasswordDialog(context);
                },
              ),
              ListTile(
                leading: Icon(Icons.language_rounded, color: isDarkMode ? SoftPalette.teal300 : SoftPalette.teal550),
                title: Text(context.isUrdu ? 'English میں تبدیل کریں' : 'اردو میں تبدیل کریں', style: TextStyle(color: textPrimary)),
                onTap: () {
                  Navigator.pop(ctx);
                  final newLang = context.isUrdu ? 'en' : 'ur';
                  try {
                    Provider.of<MadrassaLanguageProvider>(context, listen: false).setLanguage(newLang);
                  } catch (_) {}
                },
              ),
              if (widget.onLogout != null) ...[
                Divider(color: dividerColor),
                ListTile(
                  leading: const Icon(Icons.logout_rounded, color: SoftPalette.red400),
                  title: Text(context.t('Logout'), style: const TextStyle(color: SoftPalette.red400, fontWeight: FontWeight.bold)),
                  onTap: () {
                    Navigator.pop(ctx);
                    widget.onLogout!();
                  },
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  // ── New Helper Methods for Redesigned Layout ──────────────────────────────

  Widget _buildHeroBanner({
    required bool isDesktop,
    bool isAccountView = false,
    MadrassaConfig? displayConfig,
    List<dynamic>? monthLogs,
    List<DateTime>? holidays,
  }) {
    final c = context.comfort;
    final name = (studentData['name'] ?? studentData['fullName'] ?? 'Student').toString().trim();
    final photoUrl = (studentData['photoBase64'] ??
            studentData['photoUrl'] ??
            studentData['photo'] ??
            studentData['image'] ??
            studentData['studentPhotoBase64'])
        ?.toString();
    final rollNo = (studentData['rollNo'] ?? studentData['roll'] ?? '').toString().trim();
    final guardianDisplay = (studentData['guardianName'] ??
            studentData['guardianFullName'] ??
            studentData['fatherName'] ??
            studentData['guardianEmail'] ??
            '')
        .toString()
        .trim();

    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(horizontal: isDesktop ? 16 : 14, vertical: isDesktop ? 14 : 12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: MadrassaErp.cardRadius,
        border: Border.all(color: c.border, width: 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          GestureDetector(
            onTap: () => _showEnlargedPhotoDialog(context, photoUrl, name),
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.brandSoft,
                border: Border.all(color: c.border, width: 1.5),
              ),
              child: ClipOval(
                child: () {
                  final str = photoUrl?.toString().trim();
                  final bytes = ImageUploadService.decodeBase64ToBytes(str);
                  if (bytes != null) {
                    return Image.memory(
                      bytes,
                      fit: BoxFit.cover,
                      width: 48,
                      height: 48,
                      errorBuilder: (_, __, ___) => Container(
                        color: c.brandSoft,
                        alignment: Alignment.center,
                        child: Text(
                          name.isNotEmpty ? name[0] : '?',
                          style: TextStyle(color: c.brand, fontSize: 20, fontWeight: FontWeight.bold),
                        ),
                      ),
                    );
                  } else if (str != null && str.startsWith('http')) {
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        Container(
                          color: c.brandSoft,
                          alignment: Alignment.center,
                          child: Text(
                            name.isNotEmpty ? name[0] : '?',
                            style: TextStyle(color: c.brand, fontSize: 20, fontWeight: FontWeight.bold),
                          ),
                        ),
                        Image.network(
                          str,
                          fit: BoxFit.cover,
                          width: 48,
                          height: 48,
                          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                        ),
                      ],
                    );
                  }
                  return Container(
                    color: c.brandSoft,
                    alignment: Alignment.center,
                    child: Text(
                      name.isNotEmpty ? name[0] : '?',
                      style: TextStyle(color: c.brand, fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                  );
                }(),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        style: TextStyle(
                          color: c.textPrimary,
                          fontSize: isDesktop ? 17 : 15,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.2,
                          fontFamily: context.isUrdu ? 'Noori' : null,
                          fontFamilyFallback: const ['Noori'],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (rollNo.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: c.surfaceSunken,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: c.border),
                        ),
                        child: Text(
                          '#$rollNo',
                          style: TextStyle(
                            fontSize: 11,
                            color: c.textSecondary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 5),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: c.brandSoft,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: c.brand.withValues(alpha: 0.25)),
                      ),
                      child: Text(
                        isNazraStudent ? (context.isUrdu ? '📖 ناظرہ' : '📖 Nazra') : (context.isUrdu ? '🕋 حفظ' : '🕋 Hifz'),
                        style: TextStyle(
                          fontSize: 11,
                          color: c.brand,
                          fontWeight: FontWeight.bold,
                          fontFamily: context.isUrdu ? 'Noori' : null,
                          fontFamilyFallback: const ['Noori'],
                        ),
                      ),
                    ),
                    if (guardianDisplay.isNotEmpty) ...[
                      Text(
                        '·',
                        style: TextStyle(color: c.textMuted, fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.person_outline_rounded, size: 14, color: c.textMuted),
                          const SizedBox(width: 4),
                          Text(
                            context.isUrdu ? 'سرپرست: $guardianDisplay' : 'Guardian: $guardianDisplay',
                            style: TextStyle(
                              fontSize: 12,
                              color: c.textSecondary,
                              fontWeight: FontWeight.w500,
                              fontFamily: context.isUrdu ? 'Noori' : null,
                              fontFamilyFallback: const ['Noori'],
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (isAccountView) ...[
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: c.brandSoft,
                foregroundColor: c.brand,
                elevation: 0,
                shadowColor: Colors.transparent,
                side: BorderSide(color: c.brand.withValues(alpha: 0.35)),
                padding: EdgeInsets.symmetric(horizontal: isDesktop ? 14 : 10, vertical: isDesktop ? 10 : 8),
                shape: RoundedRectangleBorder(borderRadius: MadrassaErp.radius),
              ),
              onPressed: () => _showEditGuardianInfoDialog(context),
              icon: Icon(Icons.edit_note_rounded, size: 17, color: c.brand),
              label: Text(
                context.isUrdu ? 'پروفائل' : 'Edit Profile',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  color: c.brand,
                  fontFamily: context.isUrdu ? 'Noori' : null,
                  fontFamilyFallback: const ['Noori'],
                ),
              ),
            ),
          ] else ...[
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: c.surfaceSunken,
                foregroundColor: c.textPrimary,
                elevation: 0,
                shadowColor: Colors.transparent,
                side: BorderSide(color: c.border),
                padding: EdgeInsets.symmetric(horizontal: isDesktop ? 12 : 9, vertical: isDesktop ? 9 : 7),
                shape: RoundedRectangleBorder(borderRadius: MadrassaErp.radius),
              ),
              onPressed: () {
                _showDownloadReportDialog(
                  context,
                  displayConfig ?? MadrassaConfig(id: widget.branchId, year: _selectedYear, month: _selectedMonth),
                  studentData,
                  monthLogs ?? [],
                  holidays ?? [],
                );
              },
              icon: Icon(Icons.file_download_rounded, size: 17, color: c.textSecondary),
              label: Text(
                context.isUrdu ? 'رپورٹ' : 'Report',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: c.textPrimary,
                  fontFamily: context.isUrdu ? 'Noori' : null,
                  fontFamilyFallback: const ['Noori'],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _headerBadge({required IconData icon, required Color iconColor, required String label}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: SoftPalette.gray50.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SoftPalette.teal550.withValues(alpha: 0.2)),
        boxShadow: const [
          BoxShadow(color: SoftPalette.slate800A6, blurRadius: 4, offset: Offset(0, 2)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: iconColor, size: 12),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(color: SoftPalette.teal750m, fontSize: 11, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _heroChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: SoftPalette.gray50.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label, style: const TextStyle(color: SoftPalette.gray50, fontSize: 11, fontWeight: FontWeight.bold)),
    );
  }

  Widget _buildNearingCompletionBanner(int currentTotalLines, String studentName) {
    final remaining = 8640 - currentTotalLines;
    if (currentTotalLines < 8000 || currentTotalLines >= 8640) return const SizedBox();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [SoftPalette.amber350, SoftPalette.amber300],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: SoftPalette.amber350.withValues(alpha: 0.3), blurRadius: 16, offset: const Offset(0, 6)),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: SoftPalette.gray50.withValues(alpha: 0.25),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.auto_awesome, color: SoftPalette.gray50, size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'MashaAllah! 🌟',
                  style: TextStyle(color: SoftPalette.gray50, fontSize: 16, fontWeight: FontWeight.bold, fontFamily: context.isUrdu ? 'Noori' : null),
                ),
                const SizedBox(height: 4),
                Text(
                  context.isUrdu
                      ? (isNazraStudent
                          ? '$studentName ناظرہ مکمل ہونے کے قریب ہیں — صرف $remaining لائنیں باقی ہیں!'
                          : '$studentName حفظ مکمل ہونے کے قریب ہیں — صرف $remaining لائنیں باقی ہیں!')
                      : (isNazraStudent
                          ? '$studentName is nearing Nazra completion — only $remaining lines remaining!'
                          : '$studentName is nearing Hifz completion — only $remaining lines remaining!'),
                  style: TextStyle(color: SoftPalette.gray50.withValues(alpha: 0.9), fontSize: 13, fontWeight: FontWeight.w500, fontFamily: context.isUrdu ? 'Noori' : null),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusPills({
    required String currentStatus,
    required bool uniformOk,
    required bool replied,
    required bool ptmJoined,
    required bool ptmClaimed,
    required bool isPtmToday,
    required bool hasPtmStatus,
    bool isLate = false,
    String? arrivalTime,
    bool isBeforeJoin = false,
    bool forceSquare = false,
    bool isToday = false,
    bool isHoliday = false,
    bool isPast = false,
  }) {
    final neutralColor = isDarkMode ? SoftPalette.slate550 : SoftPalette.gray300;

    String attValue;
    Color attColor;
    if (isBeforeJoin) {
      attValue = '—';
      attColor = neutralColor;
    } else if (isHoliday) {
      attValue = context.isUrdu ? 'تعطیل' : 'Holiday';
      attColor = SoftPalette.teal500; // Teal
    } else if (currentStatus == 'present') {
      if (isLate) {
        attValue = (arrivalTime != null && arrivalTime.isNotEmpty)
            ? (context.isUrdu ? 'حاضر (تاخیر - $arrivalTime)' : 'Present (Late - $arrivalTime)')
            : (context.isUrdu ? 'حاضر (تاخیر)' : 'Present (Late)');
        attColor = SoftPalette.amber400;
      } else {
        attValue = context.t('Present');
        attColor = ParentReportCard.successColor;
      }
    } else if (currentStatus == 'leave') {
      attValue = context.t('Leave');
      attColor = SoftPalette.amber300;
    } else if (currentStatus == 'leave_requested') {
      attValue = context.isUrdu ? 'رخصت زیر التوا' : 'Leave Pending';
      attColor = SoftPalette.orange350;
    } else if (currentStatus == 'absent') {
      attValue = context.t('Absent');
      attColor = ParentReportCard.errorColor;
    } else if (isToday || !isPast) {
      attValue = context.isUrdu ? 'زیر انتظار' : 'Pending';
      attColor = isDarkMode ? SoftPalette.amber200 : SoftPalette.amber300;
    } else {
      attValue = context.t('Absent');
      attColor = ParentReportCard.errorColor;
    }

    final attCard = _statusPill(
      icon: Icons.check_circle_outline_rounded,
      label: context.t('Attendance'),
      value: attValue,
      color: attColor,
      onTap: () => _changeTab(1),
    );

    String uniformValue;
    Color uniformColor;
    if (isBeforeJoin || isHoliday) {
      uniformValue = '—';
      uniformColor = neutralColor;
    } else if (currentStatus == 'leave' || currentStatus == 'leave_requested') {
      uniformValue = context.t('Leave');
      uniformColor = SoftPalette.amber300;
    } else if (currentStatus == 'present') {
      uniformValue = uniformOk ? context.t('Clean') : context.t('Unclean');
      uniformColor = uniformOk ? SoftPalette.blue400 : ParentReportCard.errorColor;
    } else if (isToday || !isPast) {
      uniformValue = context.isUrdu ? 'زیر انتظار' : 'Pending';
      uniformColor = isDarkMode ? SoftPalette.amber200 : SoftPalette.amber300;
    } else {
      uniformValue = context.t('Absent');
      uniformColor = ParentReportCard.errorColor;
    }

    final uniformCard = _statusPill(
      icon: Icons.checkroom_rounded,
      label: context.t('Cleanliness'),
      value: uniformValue,
      color: uniformColor,
      onTap: () => _changeTab(1),
    );

    final replyCard = isBeforeJoin
        ? _statusPill(
            icon: Icons.remove_circle_outline_rounded,
            label: context.t('Reply'),
            value: '—',
            color: neutralColor,
            onTap: () => _changeTab(1),
          )
        : _statusPill(
            icon: Icons.mail_rounded,
            label: context.t('Reply'),
            value: replied ? context.t('Sent') : context.t('Pending'),
            color: replied ? SoftPalette.green400 : ParentReportCard.errorColor,
            onTap: () => _changeTab(1),
          );

    final String ptmValue;
    final Color ptmColor;
    if (isBeforeJoin) {
      ptmValue = '—';
      ptmColor = neutralColor;
    } else if (ptmJoined) {
      ptmValue = context.t('Joined');
      ptmColor = ParentReportCard.primaryColor;
    } else if (ptmClaimed) {
      ptmValue = context.t('Claim Pending');
      ptmColor = SoftPalette.teal550;
    } else if (isPtmToday) {
      ptmValue = context.t('Today');
      ptmColor = SoftPalette.amber300;
    } else if (hasPtmStatus) {
      ptmValue = context.t('Missed');
      ptmColor = ParentReportCard.errorColor;
    } else {
      ptmValue = context.t('Scheduled');
      ptmColor = ParentReportCard.primaryColor;
    }

    final ptmCard = _statusPill(
      icon: Icons.people_rounded,
      label: 'PTM',
      value: ptmValue,
      color: ptmColor,
      onTap: () => _changeTab(1),
    );

    final bool isMobile = GBreakpoint.isMobile(context);

    if (forceSquare || isMobile) {
      return Column(
        children: [
          Row(
            children: [
              Expanded(child: attCard),
              Expanded(child: uniformCard),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: replyCard),
              Expanded(child: ptmCard),
            ],
          ),
        ],
      );
    } else {
      return Row(
        children: [
          Expanded(child: attCard),
          Expanded(child: uniformCard),
          Expanded(child: replyCard),
          Expanded(child: ptmCard),
        ],
      );
    }
  }

  Widget _statusPill({required IconData icon, required String label, required String value, required Color color, VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        margin: const EdgeInsets.all(4),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: isDarkMode ? 0.35 : 0.25), width: 1.2),
          boxShadow: [BoxShadow(color: SoftPalette.gray900.withValues(alpha: isDarkMode ? 0.2 : 0.03), blurRadius: 8, offset: const Offset(0, 2))],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: textMuted, fontWeight: FontWeight.bold, fontFamily: context.isUrdu ? 'Noori' : null),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.bold, fontFamily: context.isUrdu ? 'Noori' : null),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTeacherMessageCard({required bool needsReply, required String branchId, required String studentId, required String dateStr}) {
    if (!needsReply) return const SizedBox();
    final cardBgColor = isDarkMode ? SoftPalette.indigo800 : SoftPalette.violet550.withValues(alpha: 0.08);
    final borderColor = isDarkMode ? SoftPalette.violet700 : SoftPalette.violet550.withValues(alpha: 0.15);
    final titleColor = isDarkMode ? SoftPalette.violet350 : SoftPalette.violet550;
    final subtitleColor = isDarkMode ? SoftPalette.violet300 : SoftPalette.violet550.withValues(alpha: 0.8);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardBgColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.chat_rounded, color: titleColor, size: 20),
              const SizedBox(width: 10),
              Text(context.t('Teacher Message'), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: titleColor, fontFamily: context.isUrdu ? 'Noori' : null)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            context.isUrdu ? 'براہ کرم آج کی حاضری کے حوالے سے جواب دیں۔' : 'Please reply regarding today\'s attendance status.',
            style: TextStyle(fontSize: 13, color: subtitleColor, fontFamily: context.isUrdu ? 'Noori' : null),
          ),
          const SizedBox(height: 12),
          InkWell(
            onTap: () => _showSendReplyDialog(context, dateStr),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: SoftPalette.violet550,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(context.isUrdu ? 'ابھی جواب دیں' : 'Reply Now', style: const TextStyle(color: SoftPalette.gray50, fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(width: 6),
                  const Icon(Icons.arrow_forward_rounded, color: SoftPalette.gray50, size: 16),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFeeSummaryCompact({required double due, required double totalSavings, required double baseFee, required Map<String, dynamic> fee}) {
    final c = context.comfort;
    final urdu = context.isUrdu;
    String rs(double v) => urdu ? 'روپے ${v.toStringAsFixed(0)}' : 'Rs ${v.toStringAsFixed(0)}';

    final attSavings = (fee['attSavings'] as num?)?.toDouble() ?? 0.0;
    final uniSavings = (fee['uniSavings'] as num?)?.toDouble() ?? 0.0;
    final msgSavings = (fee['msgSavings'] as num?)?.toDouble() ?? 0.0;
    final ptmSavings = (fee['ptmSavings'] as num?)?.toDouble() ?? 0.0;
    final proRatedBaseFee = (fee['proRatedBaseFee'] as num?)?.toDouble() ?? 0.0;
    final isProRated = proRatedBaseFee > 0 && proRatedBaseFee < baseFee;
    final monthText = DateFormat('MMMM yyyy').format(DateTime(_selectedYear, _selectedMonth));

    final payment = MadrassaLocalStorage.getFeePaymentCached(widget.branchId, _selectedYear, _selectedMonth, widget.studentId);
    final status = payment?['status']?.toString().toLowerCase();
    final amountPaid = (payment?['amountPaid'] as num?)?.toDouble() ?? 0.0;
    final discount = (payment?['discount'] as num?)?.toDouble() ?? 0.0;
    final balance = (payment?['balanceDue'] as num?)?.toDouble() ??
        ((status == 'paid' || due <= 0) ? 0.0 : (due - amountPaid - discount).clamp(0.0, double.infinity));
    final isPaid = status == 'paid' || (payment != null && balance <= 0) || due <= 0;
    final isPartial = !isPaid && (status == 'partial' || amountPaid > 0 || discount > 0);

    final Color tone = isPaid ? c.success : (isPartial ? c.warning : c.danger);
    final String statusText = due <= 0
        ? (urdu ? 'معاف' : 'Waived')
        : isPaid
            ? (urdu ? 'ادا شدہ' : 'Paid')
            : (isPartial ? (urdu ? 'جزوی ادا' : 'Part paid') : (urdu ? 'باقی' : 'Unpaid'));

    final String tip;
    if (due <= 0) {
      tip = urdu ? 'ماشاء اللہ! اس مہینے فیس مکمل معاف ہے۔' : 'MashaAllah! The fee is fully waived this month.';
    } else if (totalSavings > 0) {
      tip = urdu
          ? 'آپ نے ${rs(totalSavings)} بچائے۔ حاضری، یونیفارم اور جواب سے مزید بچت ہوتی ہے۔'
          : 'You saved ${rs(totalSavings)}. Attendance, uniform and replies save more.';
    } else {
      tip = urdu ? 'روزانہ حاضری، صاف یونیفارم اور جواب سے فیس کم ہوتی ہے۔' : 'Daily attendance, a clean uniform and replies lower the fee.';
    }

    Widget row(String label, String value, {Color? color, bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      fontSize: 13,
                      color: bold ? c.textPrimary : c.textSecondary,
                      fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
                      fontFamily: urdu ? 'Noori' : null)),
            ),
            Text(value,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
                    color: color ?? c.textPrimary,
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
        );

    return MadrassaCard(
      icon: Icons.account_balance_wallet_rounded,
      title: urdu ? 'فیس' : 'Fees',
      subtitle: monthText,
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: tone.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
        child: Text(statusText, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: tone, fontFamily: urdu ? 'Noori' : null)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(urdu ? 'باقی رقم' : 'Still to pay', style: TextStyle(fontSize: 12, color: c.textMuted, fontFamily: urdu ? 'Noori' : null)),
              Text(rs(balance),
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: tone, fontFeatures: const [FontFeature.tabularFigures()])),
            ]),
          ),
          if (totalSavings > 0)
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(urdu ? 'بچت' : 'Saved', style: TextStyle(fontSize: 12, color: c.textMuted, fontFamily: urdu ? 'Noori' : null)),
              Text(rs(totalSavings), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.success)),
            ]),
        ]),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(color: c.surfaceSunken, borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            Icon(due <= 0 ? Icons.celebration_rounded : Icons.lightbulb_outline_rounded, size: 16, color: c.brand),
            const SizedBox(width: 8),
            Expanded(child: Text(tip, style: TextStyle(fontSize: 12.5, color: c.textSecondary, fontFamily: urdu ? 'Noori' : null))),
          ]),
        ),
        const SizedBox(height: 10),
        row(context.t('Standard Monthly Base Fee'), rs(baseFee), bold: true),
        if (isProRated) row(urdu ? 'داخلے کے دن سے فیس' : 'Fee from joining date', rs(proRatedBaseFee)),
        row(context.t('Attendance Reward'), '− ${rs(attSavings)}', color: c.success),
        row(context.t('Uniform Cleanliness Reward'), '− ${rs(uniSavings)}', color: c.success),
        row(context.t('Teacher Reply Response Reward'), '− ${rs(msgSavings)}', color: c.success),
        row(context.t('PTM Meeting Reward'), '− ${rs(ptmSavings)}', color: c.success),
        if (amountPaid > 0) row(urdu ? 'ادا کر دیا' : 'Paid', '− ${rs(amountPaid)}', color: c.success),
        if (discount > 0) row(urdu ? 'خصوصی رعایت' : 'Special concession', '− ${rs(discount)}', color: c.success),
        Divider(height: 16, color: c.border),
        row(urdu ? 'اس مہینے کی فیس' : 'Fee for this month', rs(due), bold: true),
      ]),
    );
  }

  Widget _buildQuranProgressCard({
    required int currentTotalLines,
    required int monthGain,
    required double paceWeekly,
    required double overallPace,
    required double daysRemaining,
    required String estCompletionStr,
    required Map<String, dynamic> selectedDateLog,
  }) {
    final c = context.comfort;
    final urdu = context.isUrdu;
    final currentPara = math.min(30, (currentTotalLines / 288).floor() + 1);
    final linesInPara = currentTotalLines % 288;
    final pageInPara = math.min(16, (linesInPara / 18).floor() + 1);
    final pct = ((currentTotalLines / 8640) * 100).clamp(0.0, 100.0);
    final onLeave = selectedDateLog['attendance'] == 'leave' || selectedDateLog['attendance'] == 'leave_requested';

    final paceValue = onLeave
        ? (urdu ? 'رکی ہوئی' : 'Paused')
        : (paceWeekly > 0
            ? (urdu ? '${paceWeekly.toStringAsFixed(1)} لائنیں / ہفتہ' : '${paceWeekly.toStringAsFixed(1)} lines / week')
            : (urdu ? 'ابھی شروع' : 'Just starting'));
    final paceNote = onLeave
        ? (urdu ? 'رخصت پر' : 'On leave')
        : (overallPace > 0 ? (urdu ? 'اوسط ${overallPace.toStringAsFixed(1)} لائنیں روزانہ' : 'Avg ${overallPace.toStringAsFixed(1)} lines a day') : null);
    final String etaValue;
    if (onLeave) {
      etaValue = urdu ? 'رکی ہوئی' : 'Paused';
    } else if (daysRemaining <= 0 || overallPace < 0.1) {
      etaValue = urdu ? 'ابھی معلوم نہیں' : 'Not known yet';
    } else if (daysRemaining < 365) {
      etaValue = urdu ? '${(daysRemaining / 30).toStringAsFixed(1)} مہینے' : '${(daysRemaining / 30).toStringAsFixed(1)} months';
    } else {
      final yrs = math.min(3.0, daysRemaining / 365);
      etaValue = urdu ? '${yrs.toStringAsFixed(1)} سال' : '${yrs.toStringAsFixed(1)} years';
    }

    return MadrassaCard(
      icon: Icons.menu_book_rounded,
      title: urdu ? 'قرآن مجید' : 'Quran Majeed',
      subtitle: isNazraStudent ? (urdu ? 'ناظرہ کی پیش رفت' : 'Nazra progress') : (urdu ? 'حفظ کی پیش رفت' : 'Hifz progress'),
      onTap: () => _changeTab(2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          SizedBox(
            width: 64,
            height: 64,
            child: Stack(alignment: Alignment.center, children: [
              SizedBox(
                width: 64,
                height: 64,
                child: CircularProgressIndicator(value: pct / 100, strokeWidth: 6, backgroundColor: c.surfaceSunken, color: c.brand),
              ),
              Text('${pct.toStringAsFixed(0)}%', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: c.textPrimary)),
            ]),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                urdu ? '$currentTotalLines / 8640 لائنیں' : '$currentTotalLines / 8640 lines',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: c.textPrimary, fontFamily: urdu ? 'Noori' : null),
              ),
              Text(
                urdu ? 'پارہ $currentPara  ·  صفحہ $pageInPara' : 'Para $currentPara  ·  Page $pageInPara',
                style: TextStyle(fontSize: 12.5, color: c.textMuted, fontFamily: urdu ? 'Noori' : null),
              ),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: c.successBg, borderRadius: BorderRadius.circular(10)),
                child: Text(
                  urdu ? '+$monthGain لائنیں اس مہینے' : '+$monthGain lines this month',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.success, fontFamily: urdu ? 'Noori' : null),
                ),
              ),
            ]),
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: MadrassaMetric(icon: Icons.speed_rounded, label: context.t('Weekly Pace'), value: paceValue, note: paceNote)),
          const SizedBox(width: 8),
          Expanded(
            child: MadrassaMetric(
              icon: Icons.flag_rounded,
              label: context.t('Est. Completion'),
              value: etaValue,
              note: onLeave ? null : estCompletionStr,
            ),
          ),
        ]),
      ]),
    );
  }

  // ── Parents' home (reimagined 2026-11-21) ─────────────────────────────────
  // Same look as the teacher screens: theme colours (GMWF / Nexus / Twilight,
  // light or dark), flat bordered cards, small radius, no heavy gradients.
  // A parent sees at once how the child did today and what to do next.

  BoxDecoration _homeCard(BuildContext context) {
    final c = context.comfort;
    return BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.border));
  }

  Widget _homeTitle(BuildContext context, String text, {IconData? icon, Widget? trailing}) {
    final c = context.comfort;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        if (icon != null) ...[Icon(icon, size: 18, color: c.brand), const SizedBox(width: 8)],
        Expanded(
          child: Text(text,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c.textPrimary, fontFamily: context.isUrdu ? 'Noori' : null)),
        ),
        ?trailing,
      ]),
    );
  }

  Widget _homeAvatar(BuildContext context, Map<String, dynamic> data, double size) {
    final c = context.comfort;
    final name = (data['name'] ?? data['fullName'] ?? '').toString();
    final raw = (data['photoBase64'] ?? data['photoUrl'] ?? data['photo'] ?? data['image'] ?? data['studentPhotoBase64'])?.toString().trim();
    final bytes = ImageUploadService.decodeBase64ToBytes(raw);
    final urduName = RegExp(r'[\u0600-\u06FF]').hasMatch(name);
    final letter = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.brandSoft, shape: BoxShape.circle),
      // A Nastaliq letter sits low in a circle: Urdu names get a person icon.
      child: urduName || name.isEmpty
          ? Icon(Icons.person_rounded, size: size * 0.55, color: c.brand)
          : Text(name.characters.first,
          textAlign: TextAlign.center,
          strutStyle: StrutStyle(fontSize: size * 0.42, height: 1, forceStrutHeight: true),
          style: TextStyle(color: c.brand, fontWeight: FontWeight.w700, fontSize: size * 0.42, height: 1, fontFamilyFallback: const ['Noori'])),
    );
    if (bytes != null) {
      return ClipOval(child: Image.memory(bytes, width: size, height: size, fit: BoxFit.cover, cacheWidth: (size * 3).round(), errorBuilder: (_, _, _) => letter));
    }
    if (raw != null && raw.startsWith('http')) {
      return ClipOval(child: Image.network(raw, width: size, height: size, fit: BoxFit.cover, errorBuilder: (_, _, _) => letter));
    }
    return letter;
  }

  /// Child header: photo, name, program and roll, the child switcher (when there
  /// are several children) and the monthly report button.
  Widget _buildParentHeader(
    BuildContext context, {
    required MadrassaConfig displayConfig,
    required List<dynamic> monthLogs,
    required List<DateTime> holidays,
  }) {
    final c = context.comfort;
    final urdu = context.isUrdu;
    final name = (studentData['name'] ?? studentData['fullName'] ?? '').toString();
    final roll = (studentData['rollNumber'] ?? studentData['rollNo'] ?? '').toString().trim();
    final session = (studentData['session'] ?? '').toString().toLowerCase();
    final sessionText = session == 'evening' ? (urdu ? 'شام' : 'Evening') : (session == 'night' ? (urdu ? 'رات' : 'Night') : (urdu ? 'صبح' : 'Morning'));
    final sub = [
      isNazraStudent ? (urdu ? 'ناظرہ' : 'Nazra') : (urdu ? 'حفظ' : 'Hifz'),
      if (roll.isNotEmpty) '${urdu ? 'رول' : 'Roll'} $roll',
      sessionText,
    ].join('  ·  ');

    Map<String, dynamic> docData(dynamic d) =>
        d is Map ? Map<String, dynamic>.from(d) : (d is DocumentSnapshot ? (d.data() as Map<String, dynamic>?) ?? {} : <String, dynamic>{});

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: _homeCard(context),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          GestureDetector(
            onTap: () => _showEnlargedPhotoDialog(context, (studentData['photoBase64'] ?? studentData['photoUrl'])?.toString(), name),
            child: _homeAvatar(context, studentData, 52),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  strutStyle: const StrutStyle(fontSize: 17, height: 1.4, forceStrutHeight: true),
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: c.textPrimary, fontFamilyFallback: const ['Noori'])),
              const SizedBox(height: 2),
              Text(sub, style: TextStyle(fontSize: 12, color: c.textMuted, fontFamily: urdu ? 'Noori' : null)),
            ]),
          ),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: c.brand,
              side: BorderSide(color: c.border),
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            onPressed: () => _showDownloadReportDialog(context, displayConfig, studentData, monthLogs, holidays),
            icon: const Icon(Icons.download_rounded, size: 16),
            label: Text(urdu ? 'رپورٹ' : 'Report', style: TextStyle(fontFamily: urdu ? 'Noori' : null)),
          ),
        ]),
        if (widget.allDocs.length > 1) ...[
          const SizedBox(height: 10),
          SizedBox(
            height: 36,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: widget.allDocs.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final d = docData(widget.allDocs[i]);
                final on = i == widget.selectedIndex;
                return InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: on ? null : () => widget.onStudentChanged(i),
                  child: Container(
                    padding: const EdgeInsetsDirectional.fromSTEB(4, 4, 12, 4),
                    decoration: BoxDecoration(
                      color: on ? c.brandSoft : c.surface,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: on ? c.brand : c.border),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      _homeAvatar(context, d, 26),
                      const SizedBox(width: 6),
                      Text((d['name'] ?? '').toString(),
                          style: TextStyle(
                              fontSize: 13, fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                              color: on ? c.brand : c.textSecondary, fontFamilyFallback: const ['Noori'])),
                    ]),
                  ),
                );
              },
            ),
          ),
        ],
      ]),
    );
  }

  String _ratioText(String? r) {
    final urdu = context.isUrdu;
    switch (r) {
      case '1/4':
        return urdu ? 'پاؤ' : 'Pao';
      case '1/2':
        return urdu ? 'نصف' : 'Nisf';
      case '3/4':
        return urdu ? 'ثلاثہ' : 'Salasa';
      case '1':
        return urdu ? 'پورا پارہ' : 'Full para';
      case 'nahi_sunaya':
        return urdu ? 'نہیں سنایا' : 'Not heard';
    }
    return '';
  }

  /// The day at a glance: attendance, the marks, today's lesson and the actions
  /// a parent may need (reply, request leave, PTM).
  Widget _buildTodayCard(
    BuildContext context, {
    required Map<String, dynamic> log,
    required bool isHoliday,
    required bool isBeforeJoin,
    required bool isFuture,
    required bool isPtmDay,
  }) {
    final c = context.comfort;
    final urdu = context.isUrdu;
    final isToday = DateUtils.isSameDay(_selectedDate, DateTime.now());
    final dateText = isToday
        ? (urdu ? 'آج' : 'Today')
        : DateFormat(urdu ? 'd MMM' : 'EEE d MMM').format(_selectedDate);
    final att = (log['attendance'] ?? '').toString().toLowerCase().trim();
    final late = log['isLate'] == true || log['timing'] == 'late';
    final arrival = log['arrivalTime']?.toString();
    final rawLeave = (log['leaveStatus'] ?? '').toString().toLowerCase().trim();
    final leavePending = att == 'leave_requested' && (rawLeave.isEmpty || rawLeave == 'pending');
    final leaveDenied = rawLeave == 'denied' || rawLeave == 'declined';
    final replied = log['parentReplied'] == true;
    final uniform = log['uniform'] == true || log['uniform'] == 'leave';
    final isSunday = _selectedDate.weekday == DateTime.sunday;

    final studentStatus = (studentData['status']?.toString() ?? 'active').toLowerCase().trim();
    final readOnly = !const {'active', ''}.contains(studentStatus);

    // 1. The main line
    late final IconData mainIcon;
    late final Color mainColor;
    late final String mainText;
    String? mainSub;
    if (isBeforeJoin) {
      mainIcon = Icons.info_outline_rounded;
      mainColor = c.textMuted;
      mainText = urdu ? 'اس دن داخلہ نہیں ہوا تھا' : 'Not enrolled yet on this day';
    } else if (isHoliday || isSunday) {
      mainIcon = Icons.beach_access_rounded;
      mainColor = c.info;
      mainText = urdu ? 'چھٹی' : 'Holiday';
      mainSub = isSunday ? (urdu ? 'اتوار' : 'Sunday') : null;
    } else if (att == 'present') {
      mainIcon = Icons.check_circle_rounded;
      mainColor = late ? c.warning : c.success;
      mainText = late ? (urdu ? 'حاضر — دیر سے آئے' : 'Present — came late') : (urdu ? 'حاضر — وقت پر' : 'Present — on time');
      mainSub = late && arrival != null && arrival.isNotEmpty ? (urdu ? 'آمد: $arrival' : 'Arrived $arrival') : null;
    } else if (att == 'leave') {
      mainIcon = Icons.event_available_rounded;
      mainColor = c.info;
      mainText = urdu ? 'رخصت (منظور شدہ)' : 'On leave (approved)';
    } else if (leavePending) {
      mainIcon = Icons.hourglass_top_rounded;
      mainColor = c.warning;
      mainText = urdu ? 'رخصت کی درخواست — منظوری کا انتظار' : 'Leave requested — waiting for the teacher';
    } else if (att == 'absent') {
      mainIcon = Icons.cancel_rounded;
      mainColor = c.danger;
      mainText = leaveDenied ? (urdu ? 'غیر حاضر — رخصت منظور نہیں ہوئی' : 'Absent — leave not approved') : (urdu ? 'غیر حاضر' : 'Absent');
    } else if (isFuture) {
      mainIcon = Icons.schedule_rounded;
      mainColor = c.textMuted;
      mainText = urdu ? 'آنے والا دن' : 'Upcoming day';
    } else {
      mainIcon = Icons.schedule_rounded;
      mainColor = c.textMuted;
      mainText = urdu ? 'ابھی حاضری نہیں لگی' : 'Attendance not marked yet';
    }

    Widget chip(IconData icon, String text, Color color, {bool on = true}) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: on ? color.withValues(alpha: 0.12) : c.surfaceSunken,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 15, color: on ? color : c.textMuted),
            const SizedBox(width: 6),
            Text(text, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: on ? color : c.textMuted, fontFamily: urdu ? 'Noori' : null)),
          ]),
        );

    // 2. Today's lesson
    final lessonLines = <String>[];
    if (att == 'present') {
      final sabak = (log['sabakLines'] as num?)?.toInt() ?? int.tryParse(log['sabakLines']?.toString() ?? '') ?? 0;
      if (sabak > 0) lessonLines.add(urdu ? 'سبق: $sabak لائنیں' : 'Sabak: $sabak lines');
      if (isNazraStudent) {
        final rp = int.tryParse(log['rukuPara']?.toString() ?? '') ?? 0;
        final r = log['ruku']?.toString();
        if (rp > 0 && r != null && r != '-') lessonLines.add(urdu ? 'رکوع: پارہ $rp، $r' : 'Ruku: Para $rp, $r');
        final q = log['qaidaSabak']?.toString();
        if (q != null && q.isNotEmpty && q != '-' && q != '0') {
          lessonLines.add(q == 'completed' ? (urdu ? 'قاعدہ مکمل' : 'Qaida complete') : (urdu ? 'قاعدہ: تختی $q' : 'Qaida: lesson $q'));
        }
      } else {
        for (final (label, pk, rk) in [
          (urdu ? 'سبقی' : 'Sabqi', 'sabkiPara', 'sabkiRatio'),
          (urdu ? 'منزل' : 'Manzil', 'manzilPara', 'manzilRatio'),
        ]) {
          final p = int.tryParse(log[pk]?.toString() ?? '') ?? 0;
          final r = log[rk]?.toString();
          if (r == 'nahi_sunaya') {
            lessonLines.add('$label: ${_ratioText(r)}');
          } else if (p > 0) {
            lessonLines.add('$label: ${urdu ? 'پارہ' : 'Para'} $p ${_ratioText(r)}');
          }
        }
      }
    }

    // 3. Actions
    final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);
    final canAct = !readOnly && widget.isParentView && !isBeforeJoin;
    final actions = <Widget>[
      if (canAct && !replied && (att == 'present' || att == 'absent'))
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: c.brand, foregroundColor: c.onBrand),
          onPressed: () => _showSendReplyDialog(context, dateStr),
          icon: const Icon(Icons.reply_rounded, size: 18),
          label: Text(urdu ? 'استاد کو جواب دیں' : 'Reply to teacher', style: TextStyle(fontFamily: urdu ? 'Noori' : null)),
        ),
      if (canAct && att != 'present' && att != 'leave' && att != 'leave_requested' && !isHoliday && !isSunday)
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: c.brand, side: BorderSide(color: c.brand.withValues(alpha: 0.5))),
          onPressed: () {
            final now = DateTime.now();
            final today = DateTime(now.year, now.month, now.day);
            final target = _selectedDate.isBefore(today) ? today : _selectedDate;
            _showLeaveReasonDialog(context, widget.branchId, DateFormat('yyyy-MM-dd').format(target), widget.studentId);
          },
          icon: const Icon(Icons.event_busy_rounded, size: 18),
          label: Text(urdu ? 'رخصت کی درخواست' : 'Request leave', style: TextStyle(fontFamily: urdu ? 'Noori' : null)),
        ),
      if (canAct && isPtmDay && log['ptm'] == null && log['ptmRequestStatus'] == null)
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: c.info, side: BorderSide(color: c.info.withValues(alpha: 0.5))),
          onPressed: () => _claimPtmJoin(context),
          icon: const Icon(Icons.people_rounded, size: 18),
          label: Text(urdu ? 'پی ٹی ایم میں شرکت کی' : 'I attended the PTM', style: TextStyle(fontFamily: urdu ? 'Noori' : null)),
        ),
    ];

    final showMarks = att == 'present' || att == 'absent';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _homeCard(context),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _homeTitle(context, dateText, icon: Icons.today_rounded, trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            tooltip: urdu ? 'پچھلا دن' : 'Previous day',
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _selectedDate = _selectedDate.subtract(const Duration(days: 1))),
            icon: Icon(Icons.chevron_left_rounded, color: c.textSecondary),
          ),
          IconButton(
            tooltip: urdu ? 'اگلا دن' : 'Next day',
            visualDensity: VisualDensity.compact,
            onPressed: isToday ? null : () => setState(() => _selectedDate = _selectedDate.add(const Duration(days: 1))),
            icon: Icon(Icons.chevron_right_rounded, color: isToday ? c.textMuted.withValues(alpha: 0.3) : c.textSecondary),
          ),
        ])),
        Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: mainColor.withValues(alpha: 0.14), shape: BoxShape.circle),
            child: Icon(mainIcon, color: mainColor, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(mainText, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.textPrimary, fontFamily: urdu ? 'Noori' : null)),
              if (mainSub != null) Text(mainSub, style: TextStyle(fontSize: 12.5, color: c.textMuted, fontFamily: urdu ? 'Noori' : null)),
            ]),
          ),
        ]),
        if (showMarks) ...[
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (att == 'present')
              chip(Icons.checkroom_rounded, uniform ? (urdu ? 'یونیفارم صاف' : 'Uniform clean') : (urdu ? 'یونیفارم صاف نہیں' : 'Uniform not clean'),
                  uniform ? c.success : c.danger),
            chip(Icons.chat_rounded, replied ? (urdu ? 'جواب بھیج دیا' : 'Reply sent') : (urdu ? 'جواب باقی ہے' : 'Reply pending'),
                replied ? c.success : c.warning),
            if (isPtmDay)
              chip(Icons.people_rounded,
                  log['ptm'] == true ? (urdu ? 'پی ٹی ایم: شریک' : 'PTM: attended') : (urdu ? 'آج پی ٹی ایم ہے' : 'PTM today'),
                  c.info),
          ]),
        ],
        if (lessonLines.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: c.surfaceSunken, borderRadius: BorderRadius.circular(10)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.menu_book_rounded, size: 18, color: c.brand),
              const SizedBox(width: 10),
              Expanded(
                child: Text(lessonLines.join('\n'),
                    style: TextStyle(fontSize: 13.5, height: 1.5, color: c.textPrimary, fontFamily: urdu ? 'Noori' : null)),
              ),
            ]),
          ),
        ],
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: actions),
        ],
      ]),
    );
  }

  Widget _buildDashboardTab({
    required bool isDesktop,
    required bool isTablet,
    required Map<String, dynamic> todaySLog,
    required Map<String, dynamic> selectedDateLog,
    required bool isPtmForSelectedDate,
    required String currentStatus,
    required String leaveStatus,
    required bool isPtmToday,
    required bool needsReply,
    required List<dynamic> allLogs,
    required List<dynamic> monthLogs,
    required List<Map<String, dynamic>> holidaysData,
    required MadrassaConfig config,
    required double due,
    required double totalSavings,
    required double proRatedBaseFee,
    required int currentTotalLines,
    required int monthGain,
    required String estCompletionStr,
    required double paceWeekly,
    required double overallPace,
    required double daysRemaining,
    required Map<String, dynamic> fee,
    required Widget? congratsCard,
    required Widget nearingBanner,
  }) {
    final selectedDateStatus = selectedDateLog['attendance']?.toString() ?? 'unknown';
    final selectedDateIsLate = selectedDateLog['isLate'] == true || selectedDateLog['timing'] == 'late';
    final selectedDateArrivalTime = selectedDateLog['arrivalTime']?.toString();
    final rawSelectedLeaveStatus = selectedDateLog['leaveStatus']?.toString().toLowerCase().trim();
    final selectedDateLeaveStatus = rawSelectedLeaveStatus == 'declined'
        ? 'denied'
        : ((rawSelectedLeaveStatus == null || rawSelectedLeaveStatus.isEmpty)
            ? (selectedDateStatus == 'leave' ? 'approved' : 'pending')
            : rawSelectedLeaveStatus);
    final selectedDateUniform = selectedDateLog['uniform'] == true;
    final selectedDateReplied = selectedDateLog['parentReplied'] == true;
    
    // Check if PTM joined or claimed in selected date or anywhere in allLogs for the month
    final monthPtmJoined = allLogs.any((l) {
      final map = _logDocData(l);
      final studentLog = _asStringMap(map?[widget.studentId]);
      if (studentLog == null) return false;
      final p = studentLog['ptm'];
      final s = studentLog['ptmRequestStatus']?.toString().toLowerCase();
      return p == true || s == 'approved';
    });
    final selectedDatePtmClaimed = selectedDateLog['ptmRequestStatus'] == 'claimed';
    final selectedDatePtmJoined = selectedDateLog['ptm'] == true ||
        selectedDateLog['ptmRequestStatus'] == 'approved' ||
        selectedDateLog['ptmJoined'] == true ||
        studentData['ptmJoined'] == true ||
        monthPtmJoined;

    final selectedDatePtmRecorded = selectedDateLog.containsKey('ptm');
    final selectedDateNeedsReply = selectedDateLog['parentReplied'] != true && (selectedDateStatus == 'absent' || selectedDateStatus == 'present');
    final selectedDateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);
    final isSelectedToday = _selectedDate.year == DateTime.now().year && _selectedDate.month == DateTime.now().month && _selectedDate.day == DateTime.now().day;

    final heroBanner = _buildHeroBanner(
      isDesktop: isDesktop || isTablet,
      displayConfig: config,
      monthLogs: monthLogs,
      holidays: holidaysData.map((h) => h['date'] as DateTime).toList(),
    );

    final rawFeeSummary = _buildFeeSummaryCompact(due: due, totalSavings: totalSavings, baseFee: proRatedBaseFee, fee: fee);
    final feeSummary = InkWell(
      onTap: () => _changeTab(3),
      borderRadius: BorderRadius.circular(20),
      child: Column(
        children: [
          rawFeeSummary,
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(
                context.isUrdu ? 'مکمل فیس کی تفصیلات دیکھیں ←' : 'View Detailed Fee Statement →',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.comfort.brand, fontFamily: context.isUrdu ? 'Noori' : null),
              ),
            ],
          ),
        ],
      ),
    );

    final teacherMessage = isSelectedToday 
        ? _buildTeacherMessageCard(needsReply: selectedDateNeedsReply && !selectedDateReplied, branchId: widget.branchId, studentId: widget.studentId, dateStr: selectedDateStr)
        : const SizedBox();

    final joinDateVal = _studentJoinDate;
    final isSelectedBeforeJoin = joinDateVal != null && DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day).isBefore(DateTime(joinDateVal.year, joinDateVal.month, joinDateVal.day));

    final selectedDateIsHoliday = holidaysData.any((h) {
      final rawDate = h['date'];
      final hDate = rawDate is DateTime ? rawDate : _parseDateTime(rawDate);
      return hDate.year == _selectedDate.year && hDate.month == _selectedDate.month && hDate.day == _selectedDate.day;
    });
    final nowZero = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
    final selectedZero = DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day);
    final isSelectedPast = selectedZero.isBefore(nowZero);

    final statusPills = _buildStatusPills(
      currentStatus: selectedDateStatus,
      uniformOk: selectedDateUniform,
      replied: selectedDateReplied,
      ptmJoined: selectedDatePtmJoined,
      ptmClaimed: selectedDatePtmClaimed,
      isPtmToday: isPtmForSelectedDate,
      hasPtmStatus: selectedDatePtmRecorded,
      isLate: selectedDateIsLate,
      arrivalTime: selectedDateArrivalTime,
      isBeforeJoin: isSelectedBeforeJoin,
      isToday: isSelectedToday,
      isHoliday: selectedDateIsHoliday,
      isPast: isSelectedPast,
    );

    final rawMonthGainWidget = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ParentReportCard.accentColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ParentReportCard.accentColor.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          const Icon(Icons.trending_up, color: ParentReportCard.accentColor),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              context.isUrdu
                  ? (isNazraStudent ? 'اس مہینے کی پیش رفت: +$monthGain لائنیں ناظرہ پڑھیں' : 'اس مہینے کی پیش رفت: +$monthGain لائنیں حفظ کیں')
                  : (isNazraStudent ? 'Progress this month: +$monthGain lines read' : 'Progress this month: +$monthGain lines memorized'),
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: context.comfort.brand, fontFamily: context.isUrdu ? 'Noori' : null),
            ),
          ),
        ],
      ),
    );

    final rawForecastWidget = Row(
      children: [
        Expanded(
          child: _buildForecastTile(
            icon: Icons.speed_rounded,
            label: context.t('Weekly Pace'),
            value: context.isUrdu ? '${paceWeekly.toStringAsFixed(1)} لائنیں' : '${paceWeekly.toStringAsFixed(1)} lines',
            sub: context.isUrdu ? '${overallPace.toStringAsFixed(1)} لائنیں/دن' : '${overallPace.toStringAsFixed(1)} lines/day',
            color: context.comfort.brand,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildForecastTile(
            icon: Icons.event_repeat_rounded,
            label: context.t('Est. Completion'),
            value: overallPace > 0 
                ? (context.isUrdu 
                    ? (daysRemaining < 365 ? '${(daysRemaining / 30).toStringAsFixed(1)} مہینے' : '${(daysRemaining / 365).toStringAsFixed(1)} سال')
                    : (daysRemaining < 365 ? '${(daysRemaining / 30).toStringAsFixed(1)} mos' : '${(daysRemaining / 365).toStringAsFixed(1)} yrs'))
                : '—',
            sub: estCompletionStr,
            color: ParentReportCard.accentColor,
            isLongValue: true,
          ),
        ),
      ],
    );



    final noticesList = config.auditLog.where((l) => l['type'] == 'ptm_reschedule' && l['month'] == config.month && l['year'] == config.year).toList();

    final showDeniedReminder =
        (selectedDateLeaveStatus == 'denied' || selectedDateLeaveStatus == 'declined') &&
            selectedDateStatus != 'present' &&
            selectedDateStatus != 'leave';

    final remindersWidget = _buildReminders(
      isPtm: isPtmForSelectedDate,
      needsReply: false, // the Today card has the reply button; no second prompt
      leaveStatus: selectedDateLeaveStatus,
      attendanceStatus: selectedDateStatus,
      holidaysData: holidaysData,
      dateStr: selectedDateStr,
    );

    final bool hasActiveReminders = isPtmForSelectedDate ||
        showDeniedReminder ||
        holidaysData.any((h) {
          final rawDate = h['date'];
          final hDate = rawDate is DateTime ? rawDate : _parseDateTime(rawDate);
          final nowZ = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
          final hZero = DateTime(hDate.year, hDate.month, hDate.day);
          return hZero.isAtSameMomentAs(nowZ) ||
              hZero.isAtSameMomentAs(nowZ.add(const Duration(days: 1))) ||
              (hZero.isAfter(nowZ) && hZero.isBefore(nowZ.add(const Duration(days: 7))));
        });

    final newsWidget = (hasActiveReminders || noticesList.isNotEmpty)
        ? Container(
            width: double.infinity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (hasActiveReminders) ...[
                  _SectionTitle(label: context.t('Reminders & Announcements'), icon: Icons.campaign_rounded),
                  const SizedBox(height: 12),
                  remindersWidget,
                ],
                if (noticesList.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _SectionTitle(label: context.t('Recent Notices'), icon: Icons.campaign_rounded),
                  const SizedBox(height: 12),
                  ...noticesList.map((log) {
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: context.adapt(SoftPalette.yellow50),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: context.adapt(SoftPalette.yellow150)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.event_repeat_rounded, color: context.adapt(SoftPalette.amber200)),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  context.isUrdu ? 'پی ٹی ایم دوبارہ شیڈول: ${log['oldValue']} → ${log['newValue']}' : 'PTM Rescheduled: ${log['oldValue']} → ${log['newValue']}',
                                  style: TextStyle(fontWeight: FontWeight.bold, color: context.adapt(SoftPalette.orange350), fontFamily: context.isUrdu ? 'Noori' : null),
                                ),
                                Text(
                                  context.t('Parent Teacher Meeting date has been updated.'),
                                  style: TextStyle(fontSize: 12, color: context.adapt(SoftPalette.amber300), fontWeight: FontWeight.bold, fontFamily: context.isUrdu ? 'Noori' : null),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ],
            ),
          )
        : const SizedBox.shrink();

    final quickActions = _buildQuickActions(
      context: context,
      selectedDateLog: selectedDateLog,
      currentStatus: selectedDateStatus,
      isPtmToday: isPtmForSelectedDate,
      needsReply: selectedDateNeedsReply && !selectedDateReplied,
    );

    final embeddedQuranCard = _buildQuranProgressCard(
      currentTotalLines: currentTotalLines,
      monthGain: monthGain,
      paceWeekly: paceWeekly,
      overallPace: overallPace,
      daysRemaining: daysRemaining,
      estCompletionStr: estCompletionStr,
      selectedDateLog: selectedDateLog,
    );

    final embeddedCalendarCard = Container(
      padding: const EdgeInsets.all(14),
      decoration: _homeCard(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _SectionTitle(label: context.t('Attendance Calendar'), icon: Icons.calendar_month),
              TextButton.icon(
                onPressed: () => _changeTab(1),
                icon: Icon(Icons.arrow_forward_rounded, size: 16, color: isDarkMode ? SoftPalette.teal300 : null),
                label: Text(context.isUrdu ? 'تفصیل' : 'Details', style: TextStyle(color: isDarkMode ? SoftPalette.teal300 : null, fontFamily: context.isUrdu ? 'Noori' : null)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildMonthSelector(),
          const SizedBox(height: 12),
          _AttendanceCalendar(
            studentId: widget.studentId,
            logs: allLogs,
            year: _selectedYear,
            month: _selectedMonth,
            config: config,
            selectedDate: _selectedDate,
            onDateSelected: (d) => setState(() => _selectedDate = d),
            holidaysData: holidaysData,
            joinDate: _studentJoinDate,
            branchId: widget.branchId,
            framed: false,
          ),
        ],
      ),
    );

    final clickableQuranCard = InkWell(
      onTap: () => _changeTab(2),
      borderRadius: BorderRadius.circular(24),
      child: embeddedQuranCard,
    );

    final clickableFeeSummary = InkWell(
      onTap: () => _changeTab(3),
      borderRadius: BorderRadius.circular(20),
      child: feeSummary,
    );

    // Reimagined home: header → today → reminders → calendar → Quran → fees →
    // day details. One column on phones, columns on wider screens.
    final header = _buildParentHeader(
      context,
      displayConfig: config,
      monthLogs: monthLogs,
      holidays: holidaysData.map((h) => h['date'] as DateTime).toList(),
    );
    final today = _buildTodayCard(
      context,
      log: selectedDateLog,
      isHoliday: selectedDateIsHoliday,
      isBeforeJoin: isSelectedBeforeJoin,
      isFuture: selectedZero.isAfter(nowZero),
      isPtmDay: isPtmForSelectedDate,
    );
    final details = _buildDailyDetailsCard(allLogs, holidaysData, config);
    final fees = (config.enableFees && !isNazraStudent) ? clickableFeeSummary : null;
    const gap = SizedBox(height: 12);

    if (isDesktop || isTablet) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        header,
        gap,
        nearingBanner,
        ?congratsCard,
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            flex: 5,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              today,
              gap,
              newsWidget,
              gap,
              details,
            ]),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 5,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              embeddedCalendarCard,
              gap,
              clickableQuranCard,
              if (fees != null) ...[gap, fees],
            ]),
          ),
        ]),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      header,
      gap,
      today,
      gap,
      newsWidget,
      gap,
      embeddedCalendarCard,
      gap,
      clickableQuranCard,
      if (fees != null) ...[gap, fees],
      gap,
      details,
      nearingBanner,
      ?congratsCard,
    ]);
  }
  Widget _buildCombinedProgressTab({
    required bool isDesktop,
    required bool isTablet,
    required List<dynamic> allLogs,
    required List<Map<String, dynamic>> holidaysData,
    required MadrassaConfig config,
    required MadrassaConfig displayConfig,
    required int currentTotalLines,
    required int monthGain,
    required double paceWeekly,
    required double overallPace,
    required double daysRemaining,
    required String estCompletionStr,
    required Widget? congratsCard,
    required Widget nearingBanner,
  }) {
    const total = 8640;
    final pct = (currentTotalLines / total * 100).toStringAsFixed(1);
    final remainingLines = (total - currentTotalLines).clamp(0, total);

    // ── 2-Year Hifz Honor Gift Goal Calculation ──
    final joinDate = _parseDateTime(studentData['joinDate'], DateTime.now().subtract(const Duration(days: 1)));
    final deadline2Years = joinDate.add(const Duration(days: 730)); // 2 years = 730 days
    final now = DateTime.now();
    final daysLeftForGiftGoal = deadline2Years.difference(now).inDays;
    
    final linesRemainingForGift = (total - currentTotalLines).clamp(0, total);
    
    double requiredDailyForGift = 0.0;
    if (linesRemainingForGift > 0 && daysLeftForGiftGoal > 0) {
      requiredDailyForGift = linesRemainingForGift / daysLeftForGiftGoal;
    }
    final requiredWeeklyForGift = requiredDailyForGift * 7;
    
    final bool isCompletedHifz = linesRemainingForGift == 0;
    final bool isOnTrackForGift = (overallPace >= requiredDailyForGift) || isCompletedHifz;

    final giftGoalCard = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isOnTrackForGift
              ? [SoftPalette.green700, SoftPalette.green550]
              : [SoftPalette.orange700, SoftPalette.red600],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: (isOnTrackForGift ? SoftPalette.green550 : SoftPalette.red600).withValues(alpha: 0.25),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: SoftPalette.gray50.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                child: const Text('🎁', style: TextStyle(fontSize: 22)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isNazraStudent
                          ? (context.isUrdu ? 'ناظرہ تکمیل ہدف (Goal)' : 'Nazra Completion Goal')
                          : (context.isUrdu ? '2 سالہ حفظ اونر گفٹ ہدف (Gift Goal)' : '2-Year Hifz Honor Gift & Goal'),
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: SoftPalette.gray50,
                        fontFamily: context.isUrdu ? 'Noori' : null,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isNazraStudent
                          ? (context.isUrdu
                              ? 'قرآن پاک کا مکمل ناظرہ کرنے والے طلبا کے لیے خصوصی ہدف اور رہنمائی!'
                              : 'Target and tracking for students completing full Nazra Quran reading!')
                          : (context.isUrdu 
                              ? 'شمولیت کے 2 سال کے اندر حفظ مکمل کرنے والے طلبا کے لیے خاص انعام!' 
                              : 'Special prize & honor gift for completing Hifz within 2 years of joining!'),
                      style: TextStyle(fontSize: 11, color: SoftPalette.gray50A70, fontFamily: context.isUrdu ? 'Noori' : null),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Divider(color: SoftPalette.gray50A24),
          const SizedBox(height: 16),
          // Metrics Row
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: SoftPalette.gray50.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: [
                      Text(
                        context.isUrdu ? 'باقی دن' : 'Days Remaining',
                        style: TextStyle(fontSize: 10, color: SoftPalette.gray50A70, fontWeight: FontWeight.bold, fontFamily: context.isUrdu ? 'Noori' : null),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        daysLeftForGiftGoal > 0 ? '$daysLeftForGiftGoal ${context.isUrdu ? "دن" : "days"}' : (context.isUrdu ? 'مکمل' : 'Passed'),
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: SoftPalette.gray50),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: SoftPalette.gray50.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: [
                      Text(
                        context.isUrdu ? 'مطلوبہ روزانہ رفتار' : 'Required Daily Pace',
                        style: TextStyle(fontSize: 10, color: SoftPalette.gray50A70, fontWeight: FontWeight.bold, fontFamily: context.isUrdu ? 'Noori' : null),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isCompletedHifz ? '0' : '${requiredDailyForGift.toStringAsFixed(1)} ${context.isUrdu ? "لائنیں" : "lines/day"}',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: SoftPalette.yellow200),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: SoftPalette.gray50.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: [
                      Text(
                        context.isUrdu ? 'مطلوبہ ہفتہ وار' : 'Required Weekly',
                        style: TextStyle(fontSize: 10, color: SoftPalette.gray50A70, fontWeight: FontWeight.bold, fontFamily: context.isUrdu ? 'Noori' : null),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isCompletedHifz ? '0' : '${requiredWeeklyForGift.toStringAsFixed(0)} ${context.isUrdu ? "لائنیں" : "lines/wk"}',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: SoftPalette.gray50),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Status Message Banner (Interactive Celebration Dialog Trigger)
          InkWell(
            onTap: () => _showHifzTargetCongratulationsDialog(context, (studentData['name'] ?? studentData['fullName'] ?? 'Student').toString()),
            borderRadius: BorderRadius.circular(16),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: SoftPalette.gray50,
                borderRadius: BorderRadius.circular(16),
                boxShadow: isCompletedHifz
                    ? [
                        BoxShadow(
                          color: SoftPalette.amber200.withValues(alpha: 0.5),
                          blurRadius: 10,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
              child: Row(
                children: [
                  Icon(
                    isOnTrackForGift ? Icons.emoji_events_rounded : Icons.track_changes_rounded,
                    color: isOnTrackForGift ? SoftPalette.amber350 : SoftPalette.orange400,
                    size: 24,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isCompletedHifz
                              ? (isNazraStudent
                                  ? (context.isUrdu ? '🎉 مبارک ہو! ناظرہ قرآن مکمل ہو گیا!' : '🎉 Congratulations! Nazra Completed!')
                                  : (context.isUrdu ? '🎉 مبارک ہو! 2 سال کے اندر حفظ مکمل ہو گیا!' : '🎉 Congratulations! Hifz Completed within 2 Years!'))
                              : (isOnTrackForGift
                                  ? (isNazraStudent
                                      ? (context.isUrdu ? '🏆 تکمیل کے راستے پر ہیں!' : '🏆 On Track to Complete Nazra!')
                                      : (context.isUrdu ? '🏆 انعام کا ہدف حاصل کرنے کے راستے پر ہیں!' : '🏆 On Track to Win the 2-Year Honor Gift!'))
                                  : (isNazraStudent
                                      ? (context.isUrdu ? '🎯 ناظرہ ہدف حاصل کرنے کے لیے رفتار بڑھائیں' : '🎯 Target Needed to Complete Nazra')
                                      : (context.isUrdu ? '🎯 گفٹ ہدف حاصل کرنے کے لیے رفتار بڑھائیں' : '🎯 Target Needed to Win the Honor Gift'))),
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: isOnTrackForGift ? SoftPalette.green700 : SoftPalette.orange700,
                            fontFamily: context.isUrdu ? 'Noori' : null,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          isCompletedHifz
                              ? (isNazraStudent
                                  ? (context.isUrdu ? 'طالب علم نے ناظرہ مکمل کر لیا ہے۔ مبارکبادی سرٹیفکیٹ دیکھنے کے لیے یہاں دبائیں۔' : 'Student has completed full Nazra! Tap to view celebration.')
                                  : (context.isUrdu ? 'طالب علم شاندار نقد انعام (PKR) کا حقدار ہے۔ مبارکبادی سرٹیفکیٹ دیکھنے کے لیے یہاں دبائیں۔' : 'Student has won the Grand Honor Prize & Cash Award (PKR)! Tap to view celebration.'))
                              : (isOnTrackForGift
                                  ? (context.isUrdu 
                                      ? 'موجودہ رفتار (${overallPace.toStringAsFixed(1)} لائنیں/دن) مطلوبہ رفتار سے بہتر ہے۔ شاندار! تفصیلات کے لیے دبائیں۔' 
                                      : 'Current pace (${overallPace.toStringAsFixed(1)} lines/day) meets required target (${requiredDailyForGift.toStringAsFixed(1)} lines/day)! Tap for details.')
                                  : (isNazraStudent
                                      ? (context.isUrdu
                                          ? 'ناظرہ مکمل کرنے کے لیے روزانہ ${requiredDailyForGift.toStringAsFixed(1)} لائنیں (${requiredWeeklyForGift.toStringAsFixed(0)} لائنیں/ہفتہ) پڑھنا لازمی ہے۔'
                                          : 'Need ${requiredDailyForGift.toStringAsFixed(1)} lines/day (${requiredWeeklyForGift.toStringAsFixed(0)} lines/week) over the next $daysLeftForGiftGoal days to complete Nazra!')
                                      : (context.isUrdu
                                          ? 'انعام جیتنے کے لیے روزانہ ${requiredDailyForGift.toStringAsFixed(1)} لائنیں (${requiredWeeklyForGift.toStringAsFixed(0)} لائنیں/ہفتہ) حفظ کرنا لازمی ہے۔'
                                          : 'Need ${requiredDailyForGift.toStringAsFixed(1)} lines/day (${requiredWeeklyForGift.toStringAsFixed(0)} lines/week) over the next $daysLeftForGiftGoal days to win the gift!'))),
                          style: TextStyle(
                            fontSize: 11,
                            color: SoftPalette.gray700,
                            fontFamily: context.isUrdu ? 'Noori' : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: SoftPalette.orange400),
                ],
              ),
            ),
          ),
        ],
      ),
    );

    final calendarWidget = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(label: context.t('Attendance Calendar'), icon: Icons.calendar_month),
        const SizedBox(height: 12),
        const _CalendarLegend(),
        const SizedBox(height: 16),
        _AttendanceCalendar(
          studentId: widget.studentId,
          logs: allLogs,
          year: _selectedYear,
          month: _selectedMonth,
          config: displayConfig,
          selectedDate: _selectedDate,
          holidaysData: holidaysData,
          joinDate: _studentJoinDate,
          branchId: widget.branchId,
          onDateSelected: (date) {
            setState(() {
              _selectedDate = date;
            });
          },
        ),
      ],
    );

    final monthSelector = _buildMonthSelector();

    final progressCard = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: ParentReportCard.primaryColor,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(color: SoftPalette.gray900.withValues(alpha: 0.08), blurRadius: 16, offset: const Offset(0, 6))
        ],
      ),
      child: Column(
        children: [
          Text(
            isNazraStudent
                ? (context.isUrdu ? 'قرآن مجید ناظرہ کی مجموعی پیشرفت' : 'Overall Quran Majeed Nazra Progress')
                : context.t('Overall Quran Majeed Memorization Progress'),
            style: TextStyle(color: SoftPalette.gray50A70, fontSize: 13, fontWeight: FontWeight.w500, fontFamily: context.isUrdu ? 'Noori' : null),
          ),
          const SizedBox(height: 20),
          Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 120,
                height: 120,
                child: CircularProgressIndicator(
                  value: (currentTotalLines / total).clamp(0.0, 1.0),
                  strokeWidth: 10,
                  color: ParentReportCard.accentColor,
                  backgroundColor: SoftPalette.gray50A12,
                ),
              ),
              Text(
                '$pct%',
                style: const TextStyle(color: SoftPalette.gray50, fontSize: 22, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            context.isUrdu ? 'کل $total میں سے لائن $currentTotalLines مکمل' : 'Line $currentTotalLines of $total completed',
            style: TextStyle(color: SoftPalette.gray50, fontSize: 16, fontWeight: FontWeight.bold, fontFamily: context.isUrdu ? 'Noori' : null),
          ),
          const SizedBox(height: 4),
          Text(
            context.isUrdu ? '$remainingLines لائنیں باقی ہیں' : '$remainingLines lines remaining',
            style: TextStyle(color: SoftPalette.gray50.withOpacity(0.7), fontSize: 13, fontFamily: context.isUrdu ? 'Noori' : null),
          ),
        ],
      ),
    );

    final monthGainWidget = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ParentReportCard.accentColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ParentReportCard.accentColor.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          const Icon(Icons.trending_up, color: ParentReportCard.accentColor),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              context.isUrdu
                  ? (isNazraStudent ? 'اس مہینے کی پیش رفت: +$monthGain لائنیں ناظرہ پڑھیں' : 'اس مہینے کی پیش رفت: +$monthGain لائنیں حفظ کیں')
                  : (isNazraStudent ? 'Progress this month: +$monthGain lines read' : 'Progress this month: +$monthGain lines memorized'),
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: context.comfort.brand, fontFamily: context.isUrdu ? 'Noori' : null),
            ),
          ),
        ],
      ),
    );

    if (isDesktop || isTablet) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isNazraStudent
                ? (context.isUrdu ? 'قرآن مجید ناظرہ کی پیشرفت اور ہدف' : 'Quran Majeed Nazra Progress & Reading Goal')
                : context.t('Quran Majeed Hifz Progress & Gift Goal'),
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: textPrimary, fontFamily: context.isUrdu ? 'Noori' : null),
          ),
          const SizedBox(height: 24),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 5,
                child: Column(
                  children: [
                    progressCard,
                    const SizedBox(height: 16),
                    monthGainWidget,
                    const SizedBox(height: 16),
                    nearingBanner,
                    if (congratsCard != null) congratsCard,
                  ],
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                flex: 5,
                child: Column(
                  children: [
                    giftGoalCard,
                  ],
                ),
              ),
            ],
          ),
        ],
      );
    } else {
      return Column(
        children: [
          progressCard,
          const SizedBox(height: 16),
          giftGoalCard,
          const SizedBox(height: 16),
          monthGainWidget,
          const SizedBox(height: 16),
          nearingBanner,
          if (congratsCard != null) congratsCard,
        ],
      );
    }
  }

  Widget _buildFeesTab({
    required bool isDesktop,
    required bool isTablet,
    required double due,
    required double totalSavings,
    required double proRatedBaseFee,
    required Widget monthSelector,
    required Widget headerRow,
    required Widget amountDueCard,
    required Widget savingsGrid,
    required Widget visualFlowCard,
    required Map<String, dynamic> fee,
    required List<dynamic> monthLogs,
    required List<DateTime> holidays,
    required MadrassaConfig displayConfig,
  }) {
    final feeSummary = _buildFeeSummaryCompact(due: due, totalSavings: totalSavings, baseFee: proRatedBaseFee, fee: fee);

    final ledgerCard = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: borderColor),
        boxShadow: [
          BoxShadow(color: isDarkMode ? SoftPalette.gray900A26 : SoftPalette.slate800A8, blurRadius: 20, offset: const Offset(0, 8)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.list_alt_rounded, color: isDarkMode ? SoftPalette.teal300 : SoftPalette.emerald600),
              const SizedBox(width: 10),
              Text(
                context.isUrdu ? 'روزانہ کی حاضری اور بچت کی تفصیل' : 'Daily Attendance & Savings Ledger',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: isDarkMode ? SoftPalette.teal300 : SoftPalette.emerald600,
                  fontFamily: context.isUrdu ? 'Noori' : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            context.isUrdu 
                ? 'طالب علم کے ہر دن کے لیے حاضری، یونیفارم کی صفائی اور جوابات کی مکمل تفصیل:'
                : 'Day-by-day record of child attendance, uniform cleanliness, replies & rewards:',
            style: TextStyle(fontSize: 12, color: textMuted),
          ),
          const SizedBox(height: 16),
          _buildDailySavingsLedger(
            monthLogs: monthLogs,
            holidays: holidays,
            displayConfig: displayConfig,
          ),
        ],
      ),
    );

    if (isDesktop || isTablet) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                context.t('Fee Statement & Breakdown'),
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: textPrimary, fontFamily: context.isUrdu ? 'Noori' : null),
              ),
              SizedBox(width: 300, child: monthSelector),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  children: [
                    feeSummary,
                    const SizedBox(height: 16),
                    headerRow,
                  ],
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  children: [
                    visualFlowCard,
                    const SizedBox(height: 16),
                    ledgerCard,
                  ],
                ),
              ),
            ],
          ),
        ],
      );
    } else {
      return Column(
        children: [
          monthSelector,
          const SizedBox(height: 16),
          feeSummary,
          const SizedBox(height: 16),
          headerRow,
          const SizedBox(height: 16),
          visualFlowCard,
          const SizedBox(height: 20),
          ledgerCard,
        ],
      );
    }
  }

  Widget _buildDailySavingsLedger({
    required List<dynamic> monthLogs,
    required List<DateTime> holidays,
    required MadrassaConfig displayConfig,
  }) {
    final int daysInMonth = DateTime(_selectedYear, _selectedMonth + 1, 0).day;
    final List<Widget> rows = [];

    for (int day = daysInMonth; day >= 1; day--) {
      final date = DateTime(_selectedYear, _selectedMonth, day);
      
      if (date.weekday == DateTime.sunday) continue;
      
      final isHoliday = holidays.any((h) => h.year == date.year && h.month == date.month && h.day == date.day);
      if (isHoliday) continue;

      final joinDateVal = MadrassaFeeLogic.parseStudentJoinDate(studentData);
      if (joinDateVal != null) {
        final dateOnly = DateTime(date.year, date.month, date.day);
        final joinOnly = DateTime(joinDateVal.year, joinDateVal.month, joinDateVal.day);
        if (dateOnly.isBefore(joinOnly)) {
          continue;
        }
      }

      final dateStr = DateFormat('yyyy-MM-dd').format(date);
      
      dynamic doc;
      for (final l in monthLogs) {
        if (_logDocId(l) == dateStr) {
          doc = l;
          break;
        }
      }

      final logData = _logDocData(doc);
      final cached = MadrassaLocalStorage.getDailyLogCached(widget.branchId, dateStr);
      final cachedLog = (cached != null && cached[widget.studentId] is Map)
          ? Map<String, dynamic>.from(cached[widget.studentId] as Map)
          : <String, dynamic>{};
      final firestoreLog = (logData != null && logData[widget.studentId] is Map)
          ? Map<String, dynamic>.from(logData[widget.studentId] as Map)
          : <String, dynamic>{};

      final sLog = (firestoreLog.isNotEmpty || cachedLog.isNotEmpty)
          ? <String, dynamic>{...firestoreLog, ...cachedLog}
          : null;

      final now = DateTime.now();
      final todayOnly = DateTime(now.year, now.month, now.day);
      final dateOnly = DateTime(date.year, date.month, date.day);
      final isFuture = dateOnly.isAfter(todayOnly);

      String attText = '';
      Color attColor = context.adapt(SoftPalette.gray350);
      IconData attIcon = Icons.help_outline_rounded;
      
      String uniText = '';
      Color uniColor = context.adapt(SoftPalette.gray350);
      IconData uniIcon = Icons.help_outline_rounded;

      String replyText = '';
      Color replyColor = context.adapt(SoftPalette.gray350);
      IconData replyIcon = Icons.help_outline_rounded;

      double dailyEarned = 0.0;

      final workingDaysCount = MadrassaFeeLogic.getWorkingDaysCount(_selectedYear, _selectedMonth, holidays);
      final double dailyAttReward = workingDaysCount > 0 ? displayConfig.attendanceMaxDeduction / workingDaysCount : 0.0;
      final double dailyUniReward = workingDaysCount > 0 ? displayConfig.uniformMaxDeduction / workingDaysCount : 0.0;
      final double dailyMsgReward = workingDaysCount > 0 ? displayConfig.messageTotalDeduction / workingDaysCount : 0.0;

      if (isFuture) {
        attText = context.isUrdu ? 'مستقبل' : 'Future';
        attColor = context.adapt(SoftPalette.slate500);
        attIcon = Icons.schedule_rounded;

        uniText = '—';
        uniColor = context.adapt(SoftPalette.gray350);
        uniIcon = Icons.remove;

        replyText = '—';
        replyColor = context.adapt(SoftPalette.gray350);
        replyIcon = Icons.remove;
      } else {
        final att = sLog?['attendance']?.toString();
        if (att == 'present') {
          attText = context.isUrdu ? 'حاضر' : 'Present';
          attColor = SoftPalette.green400;
          attIcon = Icons.check_circle_rounded;
          dailyEarned += dailyAttReward;
        } else if (att == 'leave') {
          attText = context.isUrdu ? 'رخصت' : 'Leave';
          attColor = SoftPalette.amber300;
          attIcon = Icons.offline_pin_rounded;
          dailyEarned += dailyAttReward;
        } else {
          attText = context.isUrdu ? 'غیر حاضر' : 'Absent';
          attColor = SoftPalette.red400;
          attIcon = Icons.cancel_rounded;
        }

        final isClean = sLog?['uniform'] == true;
        if (att == 'present') {
          if (isClean) {
            uniText = context.isUrdu ? 'صاف' : 'Clean';
            uniColor = SoftPalette.blue400;
            uniIcon = Icons.dry_cleaning_rounded;
            dailyEarned += dailyUniReward;
          } else {
            uniText = context.isUrdu ? 'غیر صاف' : 'Dirty';
            uniColor = SoftPalette.red400;
            uniIcon = Icons.warning_amber_rounded;
          }
        } else if (att == 'leave') {
          uniText = context.isUrdu ? 'رخصت' : 'Leave';
          uniColor = SoftPalette.amber300;
          uniIcon = Icons.offline_pin_rounded;
          dailyEarned += dailyUniReward;
        } else {
          uniText = context.isUrdu ? 'غیر حاضر' : 'Absent';
          uniColor = SoftPalette.red400;
          uniIcon = Icons.cancel_rounded;
        }

        final replied = sLog?['parentReplied'] == true;
        if (replied) {
          replyText = context.isUrdu ? 'جواب دیا' : 'Replied';
          replyColor = SoftPalette.violet500;
          replyIcon = Icons.chat_bubble_rounded;
          dailyEarned += dailyMsgReward;
        } else {
          replyText = context.isUrdu ? 'کوئی جواب نہیں' : 'No Reply';
          replyColor = SoftPalette.red400;
          replyIcon = Icons.speaker_notes_off_rounded;
        }
      }

      rows.add(
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: isDarkMode ? SoftPalette.slate900 : SoftPalette.gray50,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      DateFormat(context.isUrdu ? 'dd MMM' : 'dd MMMM').format(date),
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: isDarkMode ? SoftPalette.teal300 : SoftPalette.emerald600),
                    ),
                    Text(
                      DateFormat('EEEE').format(date),
                      style: TextStyle(fontSize: 10, color: textMuted),
                    ),
                  ],
                ),
              ),
              Expanded(
                flex: 3,
                child: Row(
                  children: [
                    Icon(attIcon, color: attColor, size: 16),
                    const SizedBox(width: 4),
                    Text(
                      attText,
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: attColor, fontFamily: context.isUrdu ? 'Noori' : null),
                    ),
                  ],
                ),
              ),
              Expanded(
                flex: 3,
                child: Row(
                  children: [
                    Icon(uniIcon, color: uniColor, size: 16),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        uniText,
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: uniColor, fontFamily: context.isUrdu ? 'Noori' : null),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                flex: 3,
                child: Row(
                  children: [
                    Icon(replyIcon, color: replyColor, size: 16),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        replyText,
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: replyColor, fontFamily: context.isUrdu ? 'Noori' : null),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              if (displayConfig.enableFees)
                Expanded(
                  flex: 2,
                  child: Text(
                    isFuture ? '—' : '+Rs. ${dailyEarned.toStringAsFixed(0)}',
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: dailyEarned > 0 ? SoftPalette.green400 : SoftPalette.red400,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    if (rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Text(
            context.isUrdu ? 'اس مہینے کے لیے کوئی فعال تعلیمی دن نہیں ہے' : 'No active working days for this month.',
            style: TextStyle(color: textMuted, fontSize: 13),
          ),
        ),
      );
    }

    return Container(
      constraints: const BoxConstraints(maxHeight: 400),
      child: ListView(
        shrinkWrap: true,
        physics: const BouncingScrollPhysics(),
        children: rows,
      ),
    );
  }

  Widget _buildFlowStep({
    required String title,
    required String subtitle,
    required String amount,
    required Color color,
    required IconData icon,
    bool isFinal = false,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isFinal ? color.withOpacity(isDarkMode ? 0.15 : 0.08) : (isDarkMode ? SoftPalette.slate900 : Colors.transparent),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isFinal ? color.withOpacity(isDarkMode ? 0.35 : 0.2) : borderColor),
      ),
      child: Row(
        children: [
          Icon(icon, color: isFinal ? color : textMuted),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: isFinal ? color : textPrimary, fontFamily: context.isUrdu ? 'Noori' : null)),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(fontSize: 11, color: textMuted, fontFamily: context.isUrdu ? 'Noori' : null)),
              ],
            ),
          ),
          Text(
            amount,
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: color, fontFamily: context.isUrdu ? 'Noori' : null),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountTab({
    required bool isDesktop,
    required bool isTablet,
    required String status,
    required String? rejoinRequestStatus,
    required String? rejoinReason,
    required DateTime? rejoinDate,
    required List<Map<String, dynamic>> auditList,
  }) {
    final identityHero = _buildHeroBanner(
      isDesktop: isDesktop || isTablet,
      isAccountView: true,
    );

    final studentInfoCard = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: MadrassaErp.cardRadius,
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.badge_outlined, color: isDarkMode ? SoftPalette.teal300 : SoftPalette.green700),
              const SizedBox(width: 12),
              Text(
                context.t('Personal Information'),
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: textPrimary, fontFamily: context.isUrdu ? 'Noori' : null),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Divider(color: dividerColor),
          const SizedBox(height: 12),
          _buildDetailRow(
            Icons.menu_book_rounded,
            context.isUrdu ? 'پروگرام (Program)' : 'Program',
            isNazraStudent
                ? (context.isUrdu ? '📖 ناظرہ (Nazra)' : '📖 Nazra')
                : (context.isUrdu ? '🕋 حفظ (Hifz)' : '🕋 Hifz'),
          ),
          if (studentData['session'] != null)
            _buildDetailRow(
              Icons.schedule_rounded,
              context.isUrdu ? 'شفٹ / سیشن' : 'Shift / Session',
              studentData['session'].toString() == 'morning'
                  ? (context.isUrdu ? '☀️ صبح (Morning)' : '☀️ Morning')
                  : (studentData['session'].toString() == 'evening'
                      ? (context.isUrdu ? '🌅 شام (Evening)' : '🌅 Evening')
                      : (studentData['session'].toString() == 'night'
                          ? (context.isUrdu ? '🌙 رات (Night)' : '🌙 Night')
                          : studentData['session'].toString())),
            ),
          if (studentData['gender'] != null)
            _buildDetailRow(
              Icons.person_outline_rounded,
              context.isUrdu ? 'جنس (Gender)' : 'Gender',
              studentData['gender'].toString().toLowerCase() == 'female'
                  ? (context.isUrdu ? '👧 لڑکی (Girl)' : '👧 Girl')
                  : (context.isUrdu ? '👦 لڑکا (Boy)' : '👦 Boy'),
            ),
          _buildDetailRow(Icons.credit_card, context.t('Student CNIC'), studentData['studentCnic'] ?? context.t('Not Provided')),
          _buildDetailRow(
            Icons.calendar_today,
            context.t('Join Date'),
            studentData['joinDate'] != null
                ? (context.isUrdu 
                    ? DateFormat('dd-MM-yyyy').format(_parseDateTime(studentData['joinDate']))
                    : DateFormat('dd MMMM yyyy').format(_parseDateTime(studentData['joinDate'])))
                : context.t('Not Provided'),
          ),
          if (!isNazraStudent && studentData['hasPrevMadrassa'] == true) ...[
            _buildDetailRow(Icons.school, context.t('Prev Madrassa'), studentData['prevMadrassaName'] ?? context.t('Not Provided')),
            _buildDetailRow(Icons.auto_stories, context.t('Prev Hifz Lines'), context.isUrdu ? '${studentData['prevHifzLines'] ?? 0} لائنیں' : '${studentData['prevHifzLines'] ?? 0} lines'),
          ],
        ],
      ),
    );

    final guardianInfoCard = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: MadrassaErp.cardRadius,
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(Icons.family_restroom, color: isDarkMode ? SoftPalette.teal300 : SoftPalette.green700),
                  const SizedBox(width: 12),
                  Text(
                    context.t('Guardian Details'),
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: textPrimary, fontFamily: context.isUrdu ? 'Noori' : null),
                  ),
                ],
              ),
              InkWell(
                onTap: () => _showEditGuardianInfoDialog(context),
                borderRadius: MadrassaErp.radius,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: (isDarkMode ? SoftPalette.teal300 : SoftPalette.green700).withValues(alpha: isDarkMode ? 0.15 : 0.08),
                    borderRadius: MadrassaErp.radius,
                    border: Border.all(color: (isDarkMode ? SoftPalette.teal300 : SoftPalette.green700).withValues(alpha: isDarkMode ? 0.35 : 0.2)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.edit_rounded, size: 14, color: isDarkMode ? SoftPalette.teal300 : SoftPalette.green700),
                      const SizedBox(width: 4),
                      Text(
                        context.isUrdu ? 'ترمیم کریں' : 'Edit',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isDarkMode ? SoftPalette.teal300 : SoftPalette.green700, fontFamily: context.isUrdu ? 'Noori' : null),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Divider(color: dividerColor),
          const SizedBox(height: 12),
          _buildDetailRow(Icons.person_outline, context.t('Guardian Name'), studentData['guardianName'] ?? context.t('Not Provided')),
          _buildDetailRow(Icons.credit_card_outlined, context.t('Guardian CNIC'), studentData['guardianCnic'] ?? context.t('Not Provided')),
          _buildDetailRow(Icons.phone_outlined, context.t('Phone'), studentData['contactPhone'] ?? context.t('Not Provided')),
        ],
      ),
    );

    final String? bFormUrl = studentData['bFormUrl'] ?? studentData['bFormBase64'];
    final String? guardianCnicUrl = studentData['guardianCnicUrl'] ?? studentData['guardianCnicBase64'];

    final documentsCard = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: MadrassaErp.cardRadius,
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.folder_shared_outlined, color: isDarkMode ? SoftPalette.teal300 : SoftPalette.green700),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  context.t('Student & Guardian Documents'),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: textPrimary,
                    fontFamily: context.isUrdu ? 'Noori' : null,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: isDarkMode ? SoftPalette.slate700 : SoftPalette.gray100,
                  borderRadius: MadrassaErp.radius,
                ),
                child: Text(
                  'Read Only',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: isDarkMode ? SoftPalette.slate350 : SoftPalette.gray350),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Divider(color: dividerColor),
          const SizedBox(height: 12),
          ReadOnlyDocumentTile(
            label: context.t('Guardian CNIC Document'),
            icon: Icons.badge_outlined,
            documentUri: guardianCnicUrl,
          ),
          const SizedBox(height: 12),
          ReadOnlyDocumentTile(
            label: context.t('B-Form / Birth Certificate'),
            icon: Icons.assignment_ind_outlined,
            documentUri: bFormUrl,
          ),
        ],
      ),
    );

    final currentThemeChoice = UserThemeService.getThemeChoice(_currentUserKey);

    final themeSelectionCard = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: MadrassaErp.cardRadius,
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.palette_outlined, color: isDarkMode ? SoftPalette.teal300 : SoftPalette.green700),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  context.isUrdu ? 'تھیم اور ظاہری شکل' : 'Theme & Appearance',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: textPrimary,
                    fontFamily: context.isUrdu ? 'Noori' : null,
                  ),
                ),
              ),
              InkWell(
                onTap: () => AppearanceDialog.show(context, userKey: _currentUserKey),
                borderRadius: MadrassaErp.radius,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: (isDarkMode ? SoftPalette.teal300 : SoftPalette.green700).withValues(alpha: isDarkMode ? 0.15 : 0.08),
                    borderRadius: MadrassaErp.radius,
                    border: Border.all(color: (isDarkMode ? SoftPalette.teal300 : SoftPalette.green700).withValues(alpha: isDarkMode ? 0.35 : 0.2)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.tune_rounded, size: 14, color: isDarkMode ? SoftPalette.teal300 : SoftPalette.green700),
                      const SizedBox(width: 4),
                      Text(
                        context.isUrdu ? 'ترمیم' : 'Customize',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: isDarkMode ? SoftPalette.teal300 : SoftPalette.green700,
                          fontFamily: context.isUrdu ? 'Noori' : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Divider(color: dividerColor),
          const SizedBox(height: 12),
          Text(
            context.isUrdu ? 'تھیم منتخب کریں (3 تھیمز دستیاب ہیں):' : 'Select Theme (3 themes available):',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: textMuted,
              fontFamily: context.isUrdu ? 'Noori' : null,
            ),
          ),
          const SizedBox(height: 10),
          for (final choice in ui.GThemeChoice.values)
            Builder(builder: (ctx) {
              final selected = choice == currentThemeChoice;
              final b = isDarkMode ? Brightness.dark : Brightness.light;
              final c = ui.GTheme.colors(b, family: choice.family);
              final label = choice.label;
              final subtitle = context.isUrdu
                  ? (choice == ui.GThemeChoice.gmwf
                      ? 'زمرد اور سنہرا (اصل تھیم)'
                      : (choice == ui.GThemeChoice.nexus
                          ? 'سرمئی اور نیلا'
                          : 'جامنی اور بنفشی'))
                  : (choice == ui.GThemeChoice.gmwf
                      ? 'Emerald & Gold (Default)'
                      : (choice == ui.GThemeChoice.nexus
                          ? 'Graphite & Cobalt Blue'
                          : 'Plum & Violet'));
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: InkWell(
                  borderRadius: MadrassaErp.radius,
                  onTap: () async {
                    await UserThemeService.setThemeChoice(choice, explicitUserKey: _currentUserKey);
                    if (mounted) setState(() {});
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      borderRadius: MadrassaErp.radius,
                      color: selected
                          ? c.brand.withValues(alpha: isDarkMode ? 0.16 : 0.08)
                          : (isDarkMode ? SoftPalette.slate800 : SoftPalette.gray50),
                      border: Border.all(
                        color: selected ? c.brand : borderColor,
                        width: selected ? 1.6 : 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        for (final s in [c.background, c.surface, c.brand, c.accent])
                          Container(
                            width: 14,
                            height: 14,
                            margin: const EdgeInsetsDirectional.only(end: 5),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: s,
                              border: Border.all(color: dividerColor),
                            ),
                          ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                label,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: textPrimary,
                                ),
                              ),
                              Text(
                                subtitle,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: textMuted,
                                  fontFamily: context.isUrdu ? 'Noori' : null,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (selected)
                          Icon(Icons.check_circle_rounded, size: 20, color: c.brand),
                      ],
                    ),
                  ),
                ),
              );
            }),
        ],
      ),
    );

    final languageInfoCard = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: MadrassaErp.cardRadius,
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.language, color: isDarkMode ? SoftPalette.teal300 : SoftPalette.green700),
              const SizedBox(width: 12),
              Text(
                context.t('Change Language'),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: textPrimary,
                  fontFamily: context.isUrdu ? 'Noori' : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Divider(color: dividerColor),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  context.t('Select Language'),
                  style: TextStyle(
                    fontSize: 14,
                    color: textPrimary,
                    fontFamily: context.isUrdu ? 'Noori' : null,
                  ),
                ),
              ),
              DropdownButton<String>(
                value: context.languageCode,
                dropdownColor: cardBg,
                underline: const SizedBox(),
                items: const [
                  DropdownMenuItem(value: 'en', child: Text('English')),
                  DropdownMenuItem(value: 'ur', child: Text('اردو', style: TextStyle(fontFamily: 'Noori'))),
                ],
                onChanged: (val) {
                  if (val != null) {
                    Provider.of<MadrassaLanguageProvider>(context, listen: false).setLanguage(val);
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );

    final changePasswordCard = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: MadrassaErp.cardRadius,
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lock_reset_rounded, color: isDarkMode ? SoftPalette.teal300 : SoftPalette.green700),
              const SizedBox(width: 12),
              Text(
                context.t('Change Password'),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: textPrimary,
                  fontFamily: context.isUrdu ? 'Noori' : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Divider(color: dividerColor),
          const SizedBox(height: 12),
          Text(
            context.t('Update your account password for security.'),
            style: TextStyle(
              fontSize: 13,
              color: textMuted,
              fontFamily: context.isUrdu ? 'Noori' : null,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => _showChangePasswordDialog(context),
              icon: const Icon(Icons.password_rounded, size: 18),
              label: Text(
                context.t('Change Password'),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontFamily: context.isUrdu ? 'Noori' : null,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: isDarkMode ? SoftPalette.teal600 : SoftPalette.green700,
                foregroundColor: SoftPalette.gray50,
                padding: const EdgeInsets.symmetric(vertical: 14),
                elevation: 0,
                shape: const RoundedRectangleBorder(borderRadius: MadrassaErp.radius),
              ),
            ),
          ),
        ],
      ),
    );

    final rejoinWidget = _buildRejoinUI(status, rejoinRequestStatus, rejoinReason, rejoinDate);

    final timelineWidget = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: MadrassaErp.cardRadius,
        border: Border.all(color: borderColor),
      ),
      child: _buildTimeline(auditList),
    );

    Widget? logoutBtn;
    if (widget.onLogout != null) {
      logoutBtn = SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: widget.onLogout,
          icon: const Icon(Icons.logout_rounded, color: ParentReportCard.errorColor),
          label: Text(context.t('Log Out Account'), style: TextStyle(color: ParentReportCard.errorColor, fontWeight: FontWeight.bold, fontFamily: context.isUrdu ? 'Noori' : null)),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: ParentReportCard.errorColor),
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: const RoundedRectangleBorder(borderRadius: MadrassaErp.radius),
          ),
        ),
      );
    }

    if (isTablet || isDesktop) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          identityHero,
          const SizedBox(height: 20),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  children: [
                    if (status == 'left') ...[
                      rejoinWidget,
                      const SizedBox(height: 16),
                    ],
                    studentInfoCard,
                    const SizedBox(height: 16),
                    guardianInfoCard,
                    const SizedBox(height: 16),
                    documentsCard,
                  ],
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  children: [
                    themeSelectionCard,
                    const SizedBox(height: 16),
                    languageInfoCard,
                    const SizedBox(height: 16),
                    changePasswordCard,
                    const SizedBox(height: 16),
                    timelineWidget,
                    if (logoutBtn != null) ...[
                      const SizedBox(height: 24),
                      logoutBtn,
                    ],
                  ],
                ),
              ),
            ],
          ),
        ],
      );
    } else {
      return Column(
        children: [
          identityHero,
          const SizedBox(height: 16),
          if (status == 'left') ...[
            rejoinWidget,
            const SizedBox(height: 16),
          ],
          studentInfoCard,
          const SizedBox(height: 16),
          guardianInfoCard,
          const SizedBox(height: 16),
          documentsCard,
          const SizedBox(height: 16),
          themeSelectionCard,
          const SizedBox(height: 16),
          languageInfoCard,
          const SizedBox(height: 16),
          changePasswordCard,
          const SizedBox(height: 24),
          timelineWidget,
          if (logoutBtn != null) ...[
            const SizedBox(height: 24),
            logoutBtn,
          ],
        ],
      );
    }
  }

  Widget _buildTabContent(
    int selectedTab, {
    required bool isDesktop,
    required bool isTablet,
    required Map<String, dynamic> todaySLog,
    required Map<String, dynamic> selectedDateLog,
    required bool isPtmForSelectedDate,
    required String currentStatus,
    required String leaveStatus,
    required bool isPtmToday,
    required bool needsReply,
    required List<dynamic> allLogs,
    required List<Map<String, dynamic>> holidaysData,
    required MadrassaConfig config,
    required MadrassaConfig displayConfig,
    required List<dynamic> monthLogs,
    required List<DateTime> holidays,
    required Map<String, dynamic> fee,
    required int currentTotalLines,
    required double paceWeekly,
    required double overallPace,
    required double daysRemaining,
    required String estCompletionStr,
    required String status,
    required String? rejoinRequestStatus,
    required String? rejoinReason,
    required DateTime? rejoinDate,
    required List<Map<String, dynamic>> auditList,
  }) {
    // ── Shared computed data (Student Management Estimation Logic) ──
    const total = 8640;
    final remainingLines = (total - currentTotalLines).clamp(0, total);
    final joinDate = _parseDateTime(studentData['joinDate'], DateTime.now().subtract(const Duration(days: 1)));
    final daysEnrolled = DateTime.now().difference(joinDate).inDays.clamp(1, 99999);
    final prevHifzLines = int.tryParse(studentData['prevHifzLines']?.toString() ?? '0') ?? 0;
    final totalMemorized = currentTotalLines;
    final avgPerDay = daysEnrolled > 0 ? totalMemorized / daysEnrolled : 0.0;

    // Month gain calculation
    final selectedMonthStart = DateTime(_selectedYear, _selectedMonth, 1);
    final monthKeyStr = DateFormat('yyyy-MM').format(DateTime(_selectedYear, _selectedMonth));
    final monthLogsFiltered = allLogs.where((l) => _logDocId(l).startsWith(monthKeyStr)).toList();

    int prevMonthLines = -1;
    final sortedAllDescLogs = [...allLogs]..sort((a, b) => _logDocId(b).compareTo(_logDocId(a)));
    for (var logDoc in sortedAllDescLogs) {
      final logDate = DateTime.tryParse(_logDocId(logDoc));
      if (logDate != null && logDate.isBefore(selectedMonthStart)) {
        final logMap = _logDocData(logDoc);
        final lines = (logMap?[widget.studentId]?['currentLines'] as num?)?.toInt() ?? int.tryParse(logMap?[widget.studentId]?['currentLines']?.toString() ?? '');
        if (lines != null && lines > 0) {
          prevMonthLines = lines;
          break;
        }
      }
    }

    int monthGain = 0;
    if (monthLogsFiltered.isNotEmpty) {
      int monthSabakSum = 0;
      for (final doc in monthLogsFiltered) {
        final logMap = _logDocData(doc);
        final sLog = _asStringMap(logMap?[widget.studentId]);
        if (sLog != null) {
          final sLines = (sLog['sabakLines'] as num?)?.toInt() ?? int.tryParse(sLog['sabakLines']?.toString() ?? '');
          if (sLines != null && sLines > 0) {
            monthSabakSum += sLines;
          } else {
            final cLines = (sLog['currentLines'] as num?)?.toInt() ?? int.tryParse(sLog['currentLines']?.toString() ?? '');
            if (cLines != null && cLines > 0 && cLines <= 50) {
              monthSabakSum += cLines;
            }
          }
        }
      }

      final sortedMonthAsc = [...monthLogsFiltered]..sort((a, b) => _logDocId(a).compareTo(_logDocId(b)));

      final firstMap = _logDocData(sortedMonthAsc.first);
      final firstLogLines = (firstMap?[widget.studentId]?['currentLines'] as num?)?.toInt() ?? int.tryParse(firstMap?[widget.studentId]?['currentLines']?.toString() ?? '');

      final lastMap = _logDocData(sortedMonthAsc.last);
      final lastLogLines = (lastMap?[widget.studentId]?['currentLines'] as num?)?.toInt() ?? int.tryParse(lastMap?[widget.studentId]?['currentLines']?.toString() ?? '');

      final int studentCurrentLines = (studentData['currentLines'] as num?)?.toInt() ?? (int.tryParse(studentData['currentLines']?.toString() ?? '') ?? 0);
      final int endLines = (lastLogLines != null) ? lastLogLines : studentCurrentLines;

      int startLines = -1;
      if (prevMonthLines != -1) {
        startLines = prevMonthLines;
      } else if (firstLogLines != null) {
        startLines = firstLogLines;
      }

      int deltaLines = 0;
      if (startLines != -1 && endLines >= startLines) {
        deltaLines = (endLines - startLines).clamp(0, 8640);
      }

      monthGain = math.max(monthSabakSum, deltaLines).clamp(0, 8640);
    }

    final isHifzCompleted = currentTotalLines >= 8640 || studentData['status'] == 'hifz_completed';
    Widget? congratsCard;
    if (isHifzCompleted && !_isCongratsDismissedForCurrentMonth()) {
      DateTime completionDate = DateTime.now();
      if (studentData['hifzCompletionDate'] != null) {
        completionDate = _parseDateTime(studentData['hifzCompletionDate']);
      } else {
        DateTime? earliest;
        for (var logDoc in allLogs) {
          final d = DateTime.tryParse(_logDocId(logDoc));
          if (d != null) {
            final log = _logDocData(logDoc);
            final lines = (log?[widget.studentId]?['currentLines'] as num?)?.toInt() ?? int.tryParse(log?[widget.studentId]?['currentLines']?.toString() ?? '');
            if (lines != null && lines >= 8640 && (earliest == null || d.isBefore(earliest))) { earliest = d; }
          }
        }
        if (earliest != null) completionDate = earliest;
      }
      congratsCard = _buildCongratulatoryCard(
        joinDate: joinDate,
        completionDate: completionDate,
        studentName: (studentData['name'] ?? studentData['fullName'] ?? 'the student').toString(),
        onDismiss: _dismissCongratsForMonth,
      );
    }
    final nearingBanner = _buildNearingCompletionBanner(currentTotalLines, studentData['name'] ?? '');

    // Fee data
    final due = (fee['amountDue'] as num?)?.toDouble() ?? 0.0;
    final attSavings = (fee['attSavings'] as num?)?.toDouble() ?? 0.0;
    final uniSavings = (fee['uniSavings'] as num?)?.toDouble() ?? 0.0;
    final msgSavings = (fee['msgSavings'] as num?)?.toDouble() ?? 0.0;
    final ptmSavings = (fee['ptmSavings'] as num?)?.toDouble() ?? 0.0;
    final proRatedBaseFee = (fee['proRatedBaseFee'] as num?)?.toDouble() ?? 0.0;
    final totalSavings = (fee['totalSavings'] as num?)?.toDouble() ?? 0.0;
    final activeWorkingDays = (fee['activeWorkingDays'] as num?)?.toInt() ?? 0;
    final joinDateVal = MadrassaFeeLogic.parseStudentJoinDate(studentData);
    final isProRated = proRatedBaseFee < displayConfig.baseFee;
    final joinDateStr = joinDateVal != null
        ? (context.isUrdu ? DateFormat('dd-MM-yyyy').format(joinDateVal) : DateFormat('dd MMMM yyyy').format(joinDateVal))
        : '';

    // Payment status for this month
    final currentMonthPayment = MadrassaLocalStorage.getFeePaymentCached(widget.branchId, _selectedYear, _selectedMonth, widget.studentId);
    final currentPaymentStatus = currentMonthPayment?['status']?.toString() ?? (due <= 0 ? 'paid' : 'unpaid');
    final currentAmountPaid = (currentMonthPayment?['amountPaid'] as num?)?.toDouble() ?? (currentPaymentStatus == 'paid' ? due : 0.0);
    final isCurrentMonthPaid = currentPaymentStatus == 'paid';

    // Calculate total historical pending unpaid dues from student join date
    double totalHistoricalPendingDues = 0.0;
    int unpaidMonthsCount = 0;
    if (joinDateVal != null && displayConfig.enableFees) {
      final startMonth = DateTime(joinDateVal.year, joinDateVal.month, 1);
      final endMonth = DateTime(DateTime.now().year, DateTime.now().month, 1);
      DateTime iter = DateTime(endMonth.year, endMonth.month, 1);
      while (!iter.isBefore(startMonth)) {
        final y = iter.year;
        final m = iter.month;
        final pRec = MadrassaLocalStorage.getFeePaymentCached(widget.branchId, y, m, widget.studentId);
        final mConf = displayConfig.copyWith(year: y, month: m);
        final mWorkingDays = MadrassaFeeLogic.getWorkingDaysCount(y, m, holidays);
        final mLogs = MadrassaLocalStorage.getLogsForMonthCached(widget.branchId, y, m);
        final mFee = MadrassaFeeLogic.calculateStudentFee(
          studentId: widget.studentId,
          studentData: studentData,
          logs: mLogs,
          config: mConf,
          totalWorkingDays: mWorkingDays,
          holidays: holidays,
        );
        final mDue = ((mFee['amountDue'] as num?) ?? 0.0).toDouble();
        final mStatus = pRec?['status']?.toString() ?? (mDue <= 0 ? 'paid' : 'unpaid');
        final activeDays = (mFee['activeWorkingDays'] as num?)?.toInt() ?? 0;
        if (activeDays > 0 && mStatus != 'paid' && mDue > 0) {
          totalHistoricalPendingDues += mDue;
          unpaidMonthsCount++;
        }
        if (iter.month == 1) {
          iter = DateTime(iter.year - 1, 12, 1);
        } else {
          iter = DateTime(iter.year, iter.month - 1, 1);
        }
      }
    }

    // Fee widgets (for tabs 0 and 3)
    Widget buildFeeMonthSelector() => _buildMonthSelector();

    Widget buildAmountDueCard() => Column(
      children: [
        if (totalHistoricalPendingDues > 0) ...[
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: isDarkMode ? SoftPalette.orange800.withValues(alpha: 0.6) : SoftPalette.yellow50,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: isDarkMode ? SoftPalette.orange500 : SoftPalette.yellow200, width: 1.2),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: isDarkMode ? SoftPalette.amber200 : SoftPalette.orange350, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.isUrdu ? 'کل بقایا واجب الادا فیس' : 'Total Outstanding Pending Dues',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                          color: isDarkMode ? SoftPalette.amber200 : SoftPalette.orange350,
                          fontFamily: context.isUrdu ? 'Noori' : null,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        context.isUrdu
                            ? 'روپے ${totalHistoricalPendingDues.toStringAsFixed(0)} ($unpaidMonthsCount غیر ادا شدہ ماہ)'
                            : 'Rs. ${totalHistoricalPendingDues.toStringAsFixed(0)} ($unpaidMonthsCount Unpaid Month(s))',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: isDarkMode ? SoftPalette.yellow150 : SoftPalette.orange350,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: isCurrentMonthPaid
                ? (isDarkMode ? SoftPalette.emerald750 : ParentReportCard.successColor.withValues(alpha: 0.08))
                : (due > 0
                    ? (isDarkMode ? SoftPalette.red800 : ParentReportCard.errorColor.withValues(alpha: 0.08))
                    : (isDarkMode ? SoftPalette.emerald750 : ParentReportCard.successColor.withValues(alpha: 0.08))),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: isCurrentMonthPaid
                  ? (isDarkMode ? SoftPalette.green300.withValues(alpha: 0.4) : ParentReportCard.successColor.withValues(alpha: 0.3))
                  : (due > 0
                      ? (isDarkMode ? SoftPalette.red350.withValues(alpha: 0.3) : ParentReportCard.errorColor.withValues(alpha: 0.2))
                      : (isDarkMode ? SoftPalette.green300.withValues(alpha: 0.3) : ParentReportCard.successColor.withValues(alpha: 0.2))),
              width: 1.5,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  context.t('Amount Due'),
                  style: TextStyle(
                    color: isCurrentMonthPaid
                        ? (isDarkMode ? SoftPalette.green300 : ParentReportCard.successColor)
                        : (due > 0 ? (isDarkMode ? SoftPalette.red350 : ParentReportCard.errorColor) : (isDarkMode ? SoftPalette.green300 : ParentReportCard.successColor)),
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    fontFamily: context.isUrdu ? 'Noori' : null,
                  ),
                ),
                const SizedBox(height: 4),
                Text(_formatMonthYear(DateTime(_selectedYear, _selectedMonth)), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: textPrimary, fontFamily: context.isUrdu ? 'Noori' : null)),
              ]),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: isCurrentMonthPaid
                          ? (isDarkMode ? SoftPalette.emerald600 : SoftPalette.emerald100)
                          : (due <= 0
                              ? (isDarkMode ? SoftPalette.emerald600 : SoftPalette.emerald100)
                              : (isDarkMode ? SoftPalette.red700 : SoftPalette.red150m)),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isCurrentMonthPaid || due <= 0 ? Icons.check_circle_rounded : Icons.pending_actions_rounded,
                          size: 13,
                          color: isCurrentMonthPaid || due <= 0
                              ? (isDarkMode ? SoftPalette.emerald300 : SoftPalette.emerald550)
                              : (isDarkMode ? SoftPalette.red350 : SoftPalette.red550),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          isCurrentMonthPaid
                              ? (context.isUrdu ? 'ادا شدہ (PAID)' : 'PAID')
                              : (due <= 0 ? (context.isUrdu ? 'معاف شدہ' : 'WAIVED') : (context.isUrdu ? 'غیر ادا شدہ (UNPAID)' : 'UNPAID')),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: isCurrentMonthPaid || due <= 0
                                ? (isDarkMode ? SoftPalette.emerald300 : SoftPalette.emerald550)
                                : (isDarkMode ? SoftPalette.red350 : SoftPalette.red550),
                            fontFamily: context.isUrdu ? 'Noori' : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    isCurrentMonthPaid
                        ? (context.isUrdu ? 'روپے ${currentAmountPaid.toStringAsFixed(0)}' : 'Rs. ${currentAmountPaid.toStringAsFixed(0)}')
                        : (context.isUrdu ? 'روپے ${due.toStringAsFixed(0)}' : 'Rs. ${due.toStringAsFixed(0)}'),
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: isCurrentMonthPaid || due <= 0
                          ? (isDarkMode ? SoftPalette.green300 : ParentReportCard.successColor)
                          : (isDarkMode ? SoftPalette.red350 : ParentReportCard.errorColor),
                      fontFamily: context.isUrdu ? 'Noori' : null,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );

    Widget buildSavingsTile(String label, double amount, Color color, IconData icon) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDarkMode ? SoftPalette.slate900 : color.withOpacity(0.06),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: isDarkMode ? borderColor : color.withOpacity(0.12)),
        ),
        child: Row(children: [
          Icon(icon, size: 20, color: color), const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(context.t(label), style: TextStyle(fontSize: 11, color: textMuted, fontWeight: FontWeight.bold, fontFamily: context.isUrdu ? 'Noori' : null)),
            const SizedBox(height: 4),
            Text(context.isUrdu ? 'روپے ${amount.toStringAsFixed(0)}-' : '-Rs. ${amount.toStringAsFixed(0)}', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color, fontFamily: context.isUrdu ? 'Noori' : null)),
          ])),
        ]),
      );
    }

    Widget buildSavingsGrid() => Column(children: [
      Row(children: [
        Expanded(child: buildSavingsTile('Attendance', attSavings, SoftPalette.green400, Icons.calendar_today)),
        const SizedBox(width: 12),
        Expanded(child: buildSavingsTile('Uniform', uniSavings, SoftPalette.blue400, Icons.checkroom)),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: buildSavingsTile('Teacher Response', msgSavings, SoftPalette.purple550, Icons.chat_bubble_outline)),
        const SizedBox(width: 12),
        Expanded(child: buildSavingsTile('PTM Meeting', ptmSavings, SoftPalette.amber300, Icons.people_outline)),
      ]),
    ]);

    Widget buildVisualFlowCard() => Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: borderColor),
        boxShadow: [BoxShadow(color: isDarkMode ? SoftPalette.gray900A26 : SoftPalette.gray900.withOpacity(0.02), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(context.t('Fee Calculation Flow'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: textPrimary, fontFamily: context.isUrdu ? 'Noori' : null)),
        const SizedBox(height: 20),
        _buildFlowStep(title: context.t('Pro-rated Base Fee'), subtitle: context.isUrdu ? 'سرگرم داخلہ: $activeWorkingDays تعلیمی دن' : 'Active enrollment: $activeWorkingDays working days', amount: context.isUrdu ? 'روپے ${proRatedBaseFee.toStringAsFixed(0)}' : 'Rs. ${proRatedBaseFee.toStringAsFixed(0)}', color: textPrimary, icon: Icons.account_balance),
        if (isProRated && joinDateVal != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDarkMode ? SoftPalette.amber800 : SoftPalette.yellow50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: isDarkMode ? SoftPalette.orange400.withOpacity(0.3) : SoftPalette.yellow150),
            ),
            child: Row(children: [
              Icon(Icons.info_outline, size: 16, color: isDarkMode ? SoftPalette.amber200 : SoftPalette.orange350), const SizedBox(width: 8),
              Expanded(child: Text(context.isUrdu ? 'بنیادی فیس (عام طور پر روپے ${displayConfig.baseFee.toStringAsFixed(0)}) تناسب کی بنیاد پر ہے کیونکہ طالب علم کی شمولیت کی تاریخ $joinDateStr ہے۔' : 'Base fee (Rs. ${displayConfig.baseFee.toStringAsFixed(0)} standard) is pro-rated because the student joined on $joinDateStr.', style: TextStyle(fontSize: 11, color: isDarkMode ? SoftPalette.yellow150 : SoftPalette.orange350, fontWeight: FontWeight.bold, fontFamily: context.isUrdu ? 'Noori' : null))),
            ]),
          ),
        ],
        Center(child: Padding(padding: const EdgeInsets.symmetric(vertical: 8.0), child: Icon(Icons.remove_circle_outline, color: isDarkMode ? SoftPalette.red350 : ParentReportCard.errorColor, size: 20))),
        _buildFlowStep(title: context.t('Total Savings / Deductions'), subtitle: context.t('Combined rewards for attendance, behavior & PTM'), amount: context.isUrdu ? 'روپے ${totalSavings.toStringAsFixed(0)}-' : '-Rs. ${totalSavings.toStringAsFixed(0)}', color: SoftPalette.green400, icon: Icons.savings_outlined),
        Center(child: Padding(padding: const EdgeInsets.symmetric(vertical: 8.0), child: Icon(Icons.drag_handle, color: textMuted, size: 20))),
        _buildFlowStep(
          title: context.t('Final Net Amount Due'),
          subtitle: context.isUrdu ? 'مہینہ برائے ${_formatMonth(DateTime(_selectedYear, _selectedMonth))} جمع کرائی گئی' : 'Submitted for the month of ${DateFormat('MMMM').format(DateTime(_selectedYear, _selectedMonth))}',
          amount: context.isUrdu ? 'روپے ${due.toStringAsFixed(0)}' : 'Rs. ${due.toStringAsFixed(0)}',
          color: due > 0 ? (isDarkMode ? SoftPalette.red350 : ParentReportCard.errorColor) : (isDarkMode ? SoftPalette.green300 : ParentReportCard.successColor),
          icon: Icons.receipt,
          isFinal: true,
        ),
      ]),
    );

    Widget buildHeaderRow() => Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(context.t('Monthly Statement'), style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: textPrimary, fontFamily: context.isUrdu ? 'Noori' : null)),
        ExportButton(
          onExcel: () {
            AppToast.showSnackBar(context, SnackBar(content: Text(context.t('Preparing your Excel report...')), backgroundColor: ParentReportCard.primaryColor));
            MadrassaReportHelper.exportIndividualExcel(config: displayConfig, studentId: widget.studentId, studentData: studentData, logs: monthLogs, holidays: holidays);
          },
          onPdf: () {
            AppToast.showSnackBar(context, SnackBar(content: Text(context.t('Preparing your PDF report...')), backgroundColor: ParentReportCard.primaryColor));
            MadrassaReportHelper.exportIndividualPdf(config: displayConfig, studentId: widget.studentId, studentData: studentData, logs: monthLogs, holidays: holidays);
          },
          isSmall: true,
        ),
      ],
    );

    // Slim page header for the inner pages: back arrow + page title (no big button).
    Widget buildBackBar(String pageTitle) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          IconButton(
            tooltip: context.isUrdu ? 'واپس' : 'Back',
            onPressed: () => setState(() => _selectedTab = 0),
            icon: Icon(Icons.arrow_back_rounded, color: context.comfort.textPrimary),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              pageTitle,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: context.comfort.textPrimary,
                fontFamily: context.isUrdu ? 'Noori' : null,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );

    switch (selectedTab) {
      case 0:
        return _buildDashboardTab(
          isDesktop: isDesktop,
          isTablet: isTablet,
          todaySLog: todaySLog,
          selectedDateLog: selectedDateLog,
          isPtmForSelectedDate: isPtmForSelectedDate,
          currentStatus: currentStatus,
          leaveStatus: leaveStatus,
          isPtmToday: isPtmToday,
          needsReply: needsReply,
          allLogs: allLogs,
          monthLogs: monthLogsFiltered,
          holidaysData: holidaysData,
          config: displayConfig,
          due: due,
          totalSavings: totalSavings,
          proRatedBaseFee: proRatedBaseFee,
          currentTotalLines: currentTotalLines,
          monthGain: monthGain,
          estCompletionStr: estCompletionStr,
          paceWeekly: paceWeekly,
          overallPace: overallPace,
          daysRemaining: daysRemaining,
          fee: fee,
          congratsCard: congratsCard,
          nearingBanner: nearingBanner,
        );
      case 1:
        // Tab 1: Attendance with Per-Tab Data Filter
        final ptmDate1 = displayConfig.getPtmDate();
        final daysInMonth1 = DateTime(_selectedYear, _selectedMonth + 1, 0).day;
        int presentCount1 = 0;
        int absentCount1 = 0;
        int leaveCount1 = 0;
        int holidayCount1 = 0;
        final List<Map<String, dynamic>> monthDaysList1 = [];

        for (int d = 1; d <= daysInMonth1; d++) {
          final date = DateTime(_selectedYear, _selectedMonth, d);
          final dateStr = DateFormat('yyyy-MM-dd').format(date);
          final isPtm = date.year == ptmDate1.year && date.month == ptmDate1.month && date.day == ptmDate1.day;
          final isPast = date.isBefore(DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day));
          final isToday = d == DateTime.now().day && _selectedMonth == DateTime.now().month && _selectedYear == DateTime.now().year;
          final isSunday = date.weekday == DateTime.sunday;
          final isBeforeJoin = _studentJoinDate != null && DateTime(date.year, date.month, date.day).isBefore(DateTime(_studentJoinDate!.year, _studentJoinDate!.month, _studentJoinDate!.day));

          Map<String, dynamic>? holidayDoc;
          for (final h in holidaysData) {
            final hDate = h['date'] as DateTime?;
            if (hDate != null && hDate.year == date.year && hDate.month == date.month && hDate.day == date.day) {
              holidayDoc = h;
              break;
            }
          }
          final islamicEvent = IslamicCalendarHelper.getIslamicEvent(date);
          final isIslamicHoliday = islamicEvent != null && islamicEvent.isOfficialHoliday;
          final isHoliday = holidayDoc != null || isIslamicHoliday;

          Map<String, dynamic>? statusData;
          try {
            final doc = allLogs.firstWhere((l) => _logDocId(l) == dateStr, orElse: () => null);
            if (doc != null) {
              final rawData = _logDocData(doc);
              if (rawData != null && rawData[widget.studentId] is Map) {
                statusData = Map<String, dynamic>.from(rawData[widget.studentId] as Map);
              }
            }
          } catch (_) {}

          final att = statusData?['attendance']?.toString();
          String statusType = 'unmarked';
          if (isBeforeJoin) {
            statusType = 'before_join';
          } else if (isHoliday) {
            statusType = 'holiday';
            holidayCount1++;
          } else if (att == 'present') {
            statusType = 'present';
            presentCount1++;
          } else if (att == 'leave' || att == 'leave_requested') {
            statusType = 'leave';
            leaveCount1++;
          } else if (att == 'absent' || (isPast && !isSunday)) {
            statusType = 'absent';
            absentCount1++;
          } else if (isSunday) {
            statusType = 'sunday';
          }

          monthDaysList1.add({
            'day': d,
            'date': date,
            'dateStr': dateStr,
            'statusType': statusType,
            'statusData': statusData,
            'isPtm': isPtm,
            'isToday': isToday,
            'holidayName': holidayDoc != null ? (holidayDoc['name']?.toString() ?? 'Holiday') : (islamicEvent != null ? (context.isUrdu ? islamicEvent.titleUr : islamicEvent.titleEn) : null),
          });
        }

        final filteredDaysList1 = monthDaysList1.where((m) {
          if (_attendanceFilter == 'all') return true;
          if (_attendanceFilter == 'present') return m['statusType'] == 'present';
          if (_attendanceFilter == 'absent') return m['statusType'] == 'absent';
          if (_attendanceFilter == 'leave') return m['statusType'] == 'leave';
          if (_attendanceFilter == 'ptm') return m['isPtm'] == true;
          if (_attendanceFilter == 'holidays') return m['statusType'] == 'holiday';
          return true;
        }).toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            buildBackBar(context.isUrdu ? 'حاضری' : 'Attendance'),
            Row(
              children: [
                Expanded(child: _buildMonthSelector()),
                const SizedBox(width: 12),
                ExportButton(
                  onExcel: () {
                    AppToast.showSnackBar(context, SnackBar(content: Text(context.t('Preparing your Excel report...')), backgroundColor: ParentReportCard.primaryColor));
                    MadrassaReportHelper.exportIndividualExcel(config: displayConfig, studentId: widget.studentId, studentData: studentData, logs: monthLogs, holidays: holidays);
                  },
                  onPdf: () {
                    AppToast.showSnackBar(context, SnackBar(content: Text(context.t('Preparing your PDF report...')), backgroundColor: ParentReportCard.primaryColor));
                    MadrassaReportHelper.exportIndividualPdf(config: displayConfig, studentId: widget.studentId, studentData: studentData, logs: monthLogs, holidays: holidays);
                  },
                  isSmall: true,
                ),
              ],
            ),
            const SizedBox(height: 14),
            // Filter Bar
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildTabFilterChip('all', context.isUrdu ? 'مکمل کیلنڈر' : 'All Calendar', _attendanceFilter == 'all', (val) => setState(() => _attendanceFilter = val)),
                  const SizedBox(width: 8),
                  _buildTabFilterChip('present', context.isUrdu ? 'حاضر ($presentCount1)' : 'Present ($presentCount1)', _attendanceFilter == 'present', (val) => setState(() => _attendanceFilter = val), activeColor: ParentReportCard.successColor),
                  const SizedBox(width: 8),
                  _buildTabFilterChip('absent', context.isUrdu ? 'غیر حاضر ($absentCount1)' : 'Absent ($absentCount1)', _attendanceFilter == 'absent', (val) => setState(() => _attendanceFilter = val), activeColor: ParentReportCard.errorColor),
                  const SizedBox(width: 8),
                  _buildTabFilterChip('leave', context.isUrdu ? 'رخصت ($leaveCount1)' : 'Leave ($leaveCount1)', _attendanceFilter == 'leave', (val) => setState(() => _attendanceFilter = val), activeColor: SoftPalette.amber300),
                  const SizedBox(width: 8),
                  _buildTabFilterChip('ptm', context.isUrdu ? 'پی ٹی ایم' : 'PTM', _attendanceFilter == 'ptm', (val) => setState(() => _attendanceFilter = val), activeColor: SoftPalette.teal600),
                  const SizedBox(width: 8),
                  _buildTabFilterChip('holidays', context.isUrdu ? 'تعطیلات ($holidayCount1)' : 'Holidays ($holidayCount1)', _attendanceFilter == 'holidays', (val) => setState(() => _attendanceFilter = val), activeColor: SoftPalette.teal500),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (_attendanceFilter == 'all') ...[
              _AttendanceCalendar(
                studentId: widget.studentId,
                logs: allLogs,
                year: _selectedYear,
                month: _selectedMonth,
                config: config,
                selectedDate: _selectedDate,
                onDateSelected: (d) => setState(() => _selectedDate = d),
                holidaysData: holidaysData,
                joinDate: _studentJoinDate,
              ),
              const SizedBox(height: 16),
              _buildDailyDetailsCard(allLogs, holidaysData, config),
            ] else ...[
              if (filteredDaysList1.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(32),
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: borderColor),
                  ),
                  child: Column(
                    children: [
                      Icon(Icons.filter_list_off_rounded, size: 48, color: textMuted),
                      const SizedBox(height: 12),
                      Text(
                        context.isUrdu ? 'اس فلٹر کے تحت کوئی دن نہیں ملا' : 'No records match this filter for this month.',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: textMuted, fontFamily: context.isUrdu ? 'Noori' : null),
                      ),
                    ],
                  ),
                )
              else
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: filteredDaysList1.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (ctx, i) {
                    final item = filteredDaysList1[i];
                    final date = item['date'] as DateTime;
                    final isSelected = date.year == _selectedDate.year && date.month == _selectedDate.month && date.day == _selectedDate.day;
                    final statusType = item['statusType'] as String;
                    final isPtm = item['isPtm'] == true;
                    final holidayName = item['holidayName'] as String?;

                    Color badgeColor;
                    String badgeText;
                    IconData badgeIcon;
                    if (statusType == 'present') {
                      badgeColor = ParentReportCard.successColor;
                      badgeText = context.isUrdu ? 'حاضر' : 'Present';
                      badgeIcon = Icons.check_circle_rounded;
                    } else if (statusType == 'leave') {
                      badgeColor = SoftPalette.amber300;
                      badgeText = context.isUrdu ? 'رخصت' : 'Leave';
                      badgeIcon = Icons.event_busy_rounded;
                    } else if (statusType == 'holiday') {
                      badgeColor = SoftPalette.teal500;
                      badgeText = holidayName ?? (context.isUrdu ? 'تعطیل' : 'Holiday');
                      badgeIcon = Icons.beach_access_rounded;
                    } else if (isPtm) {
                      badgeColor = SoftPalette.teal600;
                      badgeText = context.isUrdu ? 'پی ٹی ایم میٹنگ' : 'PTM Meeting';
                      badgeIcon = Icons.people_rounded;
                    } else {
                      badgeColor = ParentReportCard.errorColor;
                      badgeText = context.isUrdu ? 'غیر حاضر' : 'Absent';
                      badgeIcon = Icons.cancel_rounded;
                    }

                    return InkWell(
                      onTap: () {
                        setState(() {
                          _selectedDate = date;
                          _attendanceFilter = 'all';
                        });
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          color: cardBg,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: isSelected ? context.comfort.brand : badgeColor.withValues(alpha: isDarkMode ? 0.35 : 0.25), width: isSelected ? 2 : 1),
                          boxShadow: [BoxShadow(color: isDarkMode ? SoftPalette.gray900A26 : SoftPalette.gray900.withValues(alpha: 0.02), blurRadius: 6, offset: const Offset(0, 2))],
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(color: badgeColor.withValues(alpha: isDarkMode ? 0.2 : 0.1), shape: BoxShape.circle),
                              child: Icon(badgeIcon, color: badgeColor, size: 20),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    DateFormat(context.isUrdu ? 'd MMMM yyyy' : 'EEEE, d MMMM yyyy').format(date),
                                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: textPrimary, fontFamily: context.isUrdu ? 'Noori' : null),
                                  ),
                                  Text(
                                    '🌙 ${IslamicCalendarHelper.fromGregorian(date).format(isUrdu: context.isUrdu)}',
                                    style: TextStyle(fontSize: 11, color: context.adapt(SoftPalette.yellow300), fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: badgeColor.withValues(alpha: isDarkMode ? 0.2 : 0.1),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                badgeText,
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: badgeColor, fontFamily: context.isUrdu ? 'Noori' : null),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(Icons.arrow_forward_ios_rounded, size: 14, color: textMuted),
                          ],
                        ),
                      ),
                    );
                  },
                ),
            ],
          ],
        );
      case 2:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            buildBackBar(isNazraStudent
                ? (context.isUrdu ? 'قرآن مجید ناظرہ کی پیشرفت' : 'Quran Majeed Nazra Progress')
                : context.t('Quran Majeed Hifz Progress')),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildTabFilterChip('all', context.isUrdu ? 'تمام پیش رفت' : 'Overall Progress', _quranProgressFilter == 'all', (val) => setState(() => _quranProgressFilter = val)),
                  const SizedBox(width: 8),
                  _buildTabFilterChip('sabak', isNazraStudent ? (context.isUrdu ? 'سبق (ناظرہ)' : 'Sabak (Nazra)') : (context.isUrdu ? 'سبق ریکارڈز' : 'Sabak Progress'), _quranProgressFilter == 'sabak', (val) => setState(() => _quranProgressFilter = val), activeColor: ParentReportCard.primaryColor),
                  if (!isNazraStudent) ...[
                    const SizedBox(width: 8),
                    _buildTabFilterChip('sabki', context.isUrdu ? 'سبقی دہرائی' : 'Sabki Revision', _quranProgressFilter == 'sabki', (val) => setState(() => _quranProgressFilter = val), activeColor: SoftPalette.orange400),
                    const SizedBox(width: 8),
                    _buildTabFilterChip('manzil', context.isUrdu ? 'منزل دہرائی' : 'Manzil Revision', _quranProgressFilter == 'manzil', (val) => setState(() => _quranProgressFilter = val), activeColor: SoftPalette.indigo550),
                  ] else ...[
                    const SizedBox(width: 8),
                    _buildTabFilterChip('ruku', context.isUrdu ? 'رُكوع' : 'Ruku', _quranProgressFilter == 'ruku', (val) => setState(() => _quranProgressFilter = val), activeColor: SoftPalette.orange400),
                    const SizedBox(width: 8),
                    _buildTabFilterChip('qaida', context.isUrdu ? 'قاعدہ سبق' : 'Qaida Sabak', _quranProgressFilter == 'qaida', (val) => setState(() => _quranProgressFilter = val), activeColor: SoftPalette.indigo550),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            _buildQuranProgressCard(
              currentTotalLines: currentTotalLines,
              monthGain: monthGain,
              paceWeekly: paceWeekly,
              overallPace: overallPace,
              daysRemaining: daysRemaining,
              estCompletionStr: estCompletionStr,
              selectedDateLog: selectedDateLog,
            ),
            const SizedBox(height: 16),
            _buildCombinedProgressTab(
              isDesktop: isDesktop,
              isTablet: isTablet,
              allLogs: allLogs,
              holidaysData: holidaysData,
              config: config,
              displayConfig: displayConfig,
              currentTotalLines: currentTotalLines,
              monthGain: monthGain,
              paceWeekly: paceWeekly,
              overallPace: overallPace,
              daysRemaining: daysRemaining,
              estCompletionStr: estCompletionStr,
              congratsCard: congratsCard,
              nearingBanner: nearingBanner,
            ),
          ],
        );
      case 3:
        if (!displayConfig.enableFees || isNazraStudent) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32.0),
              child: Text(
                isNazraStudent
                    ? (context.isUrdu ? 'ناظرہ کے طلبا کے لیے کوئی فیس لاگو نہیں ہے۔' : 'Fee is not applicable for Nazra students.')
                    : (context.isUrdu ? 'اس برانچ کے لیے فیس کا نظام فعال نہیں ہے۔' : 'Fee system is disabled for this branch.'),
                style: TextStyle(fontSize: 14, color: textMuted, fontWeight: FontWeight.bold),
              ),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            buildBackBar(context.t('Fee Statement & Breakdown')),
            _buildFeesTab(
              isDesktop: isDesktop,
              isTablet: isTablet,
              due: due,
              totalSavings: totalSavings,
              proRatedBaseFee: proRatedBaseFee,
              monthSelector: buildFeeMonthSelector(),
              headerRow: buildHeaderRow(),
              amountDueCard: buildAmountDueCard(),
              savingsGrid: buildSavingsGrid(),
              visualFlowCard: buildVisualFlowCard(),
              fee: fee,
              monthLogs: monthLogs,
              holidays: holidays,
              displayConfig: displayConfig,
            ),
          ],
        );
      case 4:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            buildBackBar(context.t('Account & Guardian Profile')),
            _buildAccountTab(
              isDesktop: isDesktop,
              isTablet: isTablet,
              status: status,
              rejoinRequestStatus: rejoinRequestStatus,
              rejoinReason: rejoinReason,
              rejoinDate: rejoinDate,
              auditList: auditList,
            ),
          ],
        );
      case 5:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            buildBackBar(context.isUrdu ? 'رخصت اور جوابات کی درخواستیں' : 'Leave & Reply Requests'),
            _buildRequestsTab(
              allLogs: allLogs,
              isParentView: widget.isParentView,
              studentId: widget.studentId,
              branchId: widget.branchId,
            ),
          ],
        );
      default:
        return const SizedBox();
    }
  }

  Future<void> _approveLeaveRequest(String branchId, String dateStr, String targetStudentId) async {
    final effBranch = _effectiveBranch;
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final existingDay = MadrassaLocalStorage.getDailyLogCached(effBranch, dateStr);
    final existingStudent = existingDay?[targetStudentId] is Map ? existingDay![targetStudentId] as Map : null;
    final reqAt = existingStudent?['leaveRequestedAt'] ?? existingStudent?['timestamp'];
    final decidedBy = FirebaseAuth.instance.currentUser?.displayName ??
        FirebaseAuth.instance.currentUser?.email ??
        'Teacher';
    await MadrassaLocalStorage.saveLogRecordLocal(
      branchId: effBranch,
      dateKey: dateStr,
      logData: {
        targetStudentId: {
          'attendance': 'leave',
          'leaveStatus': 'approved',
          'isParentRequested': false,
          'leaveDecidedAt': nowIso,
          'leaveDecidedBy': decidedBy,
          if (reqAt != null) 'leaveDecidedFor': reqAt,
          'leaveApprovedBy': decidedBy,
          'leaveApprovalTime': nowIso,
          'uniform': 'leave',
          'isLate': false,
          'timing': 'on_time',
          'arrivalTime': null,
        }
      },
      editorName: decidedBy,
      editorRole: 'teacher',
    ).timeout(const Duration(seconds: 6), onTimeout: () {});
    if (mounted) setState(() {});
  }

  Future<void> _denyLeaveRequest(String branchId, String dateStr, String targetStudentId) async {
    final effBranch = _effectiveBranch;
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final existingDay = MadrassaLocalStorage.getDailyLogCached(effBranch, dateStr);
    final existingStudent = existingDay?[targetStudentId] is Map ? existingDay![targetStudentId] as Map : null;
    final reqAt = existingStudent?['leaveRequestedAt'] ?? existingStudent?['timestamp'];
    final decidedBy = FirebaseAuth.instance.currentUser?.displayName ??
        FirebaseAuth.instance.currentUser?.email ??
        'Teacher';
    await MadrassaLocalStorage.saveLogRecordLocal(
      branchId: effBranch,
      dateKey: dateStr,
      logData: {
        targetStudentId: {
          'attendance': 'absent',
          'leaveStatus': 'denied',
          'isParentRequested': false,
          'leaveDecidedAt': nowIso,
          'leaveDecidedBy': decidedBy,
          if (reqAt != null) 'leaveDecidedFor': reqAt,
          'leaveDeniedBy': decidedBy,
          'leaveDenialTime': nowIso,
          'uniform': false,
          'isLate': false,
          'timing': 'on_time',
          'arrivalTime': null,
        }
      },
      editorName: decidedBy,
      editorRole: 'teacher',
    ).timeout(const Duration(seconds: 6), onTimeout: () {});
    if (mounted) setState(() {});
  }

  Widget _buildRequestsTab({
    required List<dynamic> allLogs,
    required bool isParentView,
    required String studentId,
    required String branchId,
  }) {
    final List<Map<String, dynamic>> requestsList = [];

    for (final logDoc in allLogs) {
      final dateStr = _logDocId(logDoc);
      final rawData = _logDocData(logDoc);
      if (rawData == null) continue;

      rawData.forEach((stId, val) {
        if (val is Map) {
          final studentDataMap = Map<String, dynamic>.from(val);
          final attendance = studentDataMap['attendance']?.toString().toLowerCase().trim();
          final rawStatus = studentDataMap['leaveStatus']?.toString().toLowerCase().trim();
          String leaveStatus;
          if (rawStatus == 'declined') {
            leaveStatus = 'denied';
          } else if (rawStatus == null || rawStatus.isEmpty) {
            leaveStatus = attendance == 'leave'
                ? 'approved'
                : (attendance == 'present' ? 'cancelled' : 'pending');
          } else if (rawStatus == 'pending' && attendance == 'present') {
            leaveStatus = 'cancelled';
          } else {
            leaveStatus = rawStatus;
          }
          final hasLeaveRequest = attendance == 'leave_requested' || attendance == 'leave' || studentDataMap.containsKey('leaveReason');
          final parentReplied = studentDataMap['parentReplied'] == true || studentDataMap.containsKey('parentReplyText') || studentDataMap.containsKey('parentReplyMessage');

          if (isParentView && stId != studentId) return;

          final studentName = stId == widget.studentId
              ? (studentData['name'] ?? 'Student')
              : (studentDataMap['name'] ?? 'Student ($stId)');

          if (hasLeaveRequest) {
            final ts = studentDataMap['leaveRequestedAt'] ?? studentDataMap['timestamp'];
            final reqDate = ts != null
                ? _parseDateTime(ts, DateTime.tryParse(dateStr) ?? DateTime.now())
                : (DateTime.tryParse(dateStr) ?? DateTime.now());

            requestsList.add({
              'id': '${dateStr}_leave_$stId',
              'type': 'leave',
              'dateStr': dateStr,
              'date': reqDate,
              'studentId': stId,
              'studentName': studentName,
              'reason': studentDataMap['leaveReason'] ?? (context.isUrdu ? 'رخصت کی درخواست' : 'Leave Request'),
              'status': leaveStatus,
            });
          }

          if (parentReplied) {
            DateTime reqDate;
            final ts = studentDataMap['parentReplyTime'] ?? studentDataMap['timestamp'];
            if (ts is Timestamp) {
              reqDate = ts.toDate();
            } else {
              reqDate = DateTime.tryParse(dateStr) ?? DateTime.now();
            }

            requestsList.add({
              'id': '${dateStr}_reply_$stId',
              'type': 'reply',
              'dateStr': dateStr,
              'date': reqDate,
              'studentId': stId,
              'studentName': studentName,
              'reason': studentDataMap['parentReplyText'] ?? studentDataMap['parentReplyMessage'] ?? (context.isUrdu ? 'استاد کو جواب بھیجا گیا' : 'Reply sent to teacher'),
              'status': 'approved',
            });
          }
        }
      });
    }

    requestsList.sort((a, b) => (b['date'] as DateTime).compareTo(a['date'] as DateTime));

    final filtered = requestsList.where((r) {
      if (_requestStatusFilter == 'all') return true;
      return r['status'] == _requestStatusFilter;
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _filterChip('all', context.isUrdu ? 'تمام (${requestsList.length})' : 'All (${requestsList.length})'),
              const SizedBox(width: 8),
              _filterChip('pending', context.isUrdu ? 'زیر التوا (Pending)' : 'Pending'),
              const SizedBox(width: 8),
              _filterChip('approved', context.isUrdu ? 'منظور شدہ (Approved)' : 'Approved'),
              const SizedBox(width: 8),
              _filterChip('denied', context.isUrdu ? 'مسترد شدہ (Denied)' : 'Denied'),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (filtered.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: borderColor),
            ),
            child: Column(
              children: [
                Icon(Icons.inbox_rounded, size: 48, color: textMuted),
                const SizedBox(height: 12),
                Text(
                  context.isUrdu ? 'کوئی درخواست نہیں ملی' : 'No requests found',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: textMuted, fontFamily: context.isUrdu ? 'Noori' : null),
                ),
              ],
            ),
          )
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: filtered.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (ctx, i) {
              final req = filtered[i];
              final isLeave = req['type'] == 'leave';
              final status = req['status'] as String;
              final reqDate = req['date'] as DateTime;
              final dateFormatted = DateFormat('dd MMM yyyy, hh:mm a').format(reqDate);

              Color statusColor;
              String statusLabel;
              if (status == 'approved') {
                statusColor = ParentReportCard.successColor;
                statusLabel = context.isUrdu ? 'منظور شدہ' : 'Approved';
              } else if (status == 'denied' || status == 'declined') {
                statusColor = ParentReportCard.errorColor;
                statusLabel = context.isUrdu ? 'مسترد' : 'Denied';
              } else if (status == 'cancelled') {
                statusColor = SoftPalette.slate550;
                statusLabel = context.isUrdu ? 'منسوخ (حاضر)' : 'Cancelled (Present)';
              } else {
                statusColor = SoftPalette.amber300;
                statusLabel = context.isUrdu ? 'زیر التوا' : 'Pending';
              }

              return Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: statusColor.withValues(alpha: isDarkMode ? 0.4 : 0.3)),
                  boxShadow: [
                    BoxShadow(color: isDarkMode ? SoftPalette.gray900A26 : SoftPalette.gray900.withValues(alpha: 0.02), blurRadius: 8, offset: const Offset(0, 2)),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: isDarkMode ? 0.2 : 0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            isLeave ? Icons.email_rounded : Icons.reply_rounded,
                            color: statusColor,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isLeave
                                    ? (context.isUrdu ? 'رخصت کی درخواست' : 'Leave Request')
                                    : (context.isUrdu ? 'جواب کی تصدیق' : 'Reply Verification'),
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                  color: textPrimary,
                                  fontFamily: context.isUrdu ? 'Noori' : null,
                                ),
                              ),
                              Text(
                                '${req['studentName']} • ${req['dateStr']}',
                                style: TextStyle(fontSize: 12, color: textMuted),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: isDarkMode ? 0.2 : 0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            statusLabel,
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: statusColor),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      req['reason'],
                      style: TextStyle(
                        fontSize: 13,
                        color: textPrimary,
                        fontFamily: context.isUrdu ? 'Noori' : null,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          dateFormatted,
                          style: TextStyle(fontSize: 11, color: textMuted),
                        ),
                        if (!isParentView && status == 'pending' && isLeave)
                          Row(
                            children: [
                              TextButton.icon(
                                onPressed: () => _approveLeaveRequest(branchId, req['dateStr'], req['studentId']),
                                icon: const Icon(Icons.check, size: 14, color: SoftPalette.green400),
                                label: Text(context.isUrdu ? 'منظور کریں' : 'Approve', style: const TextStyle(color: SoftPalette.green400, fontSize: 12)),
                              ),
                              TextButton.icon(
                                onPressed: () => _denyLeaveRequest(branchId, req['dateStr'], req['studentId']),
                                icon: const Icon(Icons.close, size: 14, color: SoftPalette.red400),
                                label: Text(context.isUrdu ? 'مسترد کریں' : 'Deny', style: const TextStyle(color: SoftPalette.red400, fontSize: 12)),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _filterChip(String filterVal, String label) => _buildTabFilterChip(
        filterVal,
        label,
        _requestStatusFilter == filterVal,
        (v) => setState(() => _requestStatusFilter = v),
      );

  /// One chip style for every filter row: calm outline when off, soft brand
  /// tint with brand text when on (no solid green / red / amber blocks).
  Widget _buildTabFilterChip(String filterVal, String label, bool isSelected, ValueChanged<String> onSelected, {Color? activeColor}) {
    final c = context.comfort;
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => onSelected(filterVal),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected ? c.brandSoft : c.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: isSelected ? c.brand.withValues(alpha: 0.6) : c.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (isSelected) ...[Icon(Icons.check_rounded, size: 15, color: c.brand), const SizedBox(width: 4)],
          Text(
            label,
            style: TextStyle(
              color: isSelected ? c.brand : c.textSecondary,
              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
              fontSize: 12.5,
              fontFamily: context.isUrdu ? 'Noori' : null,
            ),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 1. Get live cached student data from local Hive
    final cachedStudent = MadrassaLocalStorage.getStudentCached(widget.branchId, widget.studentId);
    if (cachedStudent != null) {
      _liveStudentData = cachedStudent;
    }

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _logsStream,
      builder: (context, logSnap) {
        if (logSnap.hasError) return _ErrorView('Logs Error: ${logSnap.error}');
        
        return StreamBuilder<MadrassaConfig>(
          stream: _configStream,
          builder: (context, configSnap) {
            if (configSnap.hasError) {
              debugPrint('[ParentReportCard] Config error handled gracefully: ${configSnap.error}');
            }
            
            return StreamBuilder<List<Map<String, dynamic>>>(
              stream: _holidaysStream,
              builder: (context, holidaySnap) {
                if (holidaySnap.hasError) return _ErrorView('Holidays Error: ${holidaySnap.error}');

                if (logSnap.connectionState == ConnectionState.waiting ||
                    (configSnap.connectionState == ConnectionState.waiting && !configSnap.hasData && !configSnap.hasError) ||
                    holidaySnap.connectionState == ConnectionState.waiting) {
                  return ColoredBox(
                    color: context.adapt(ParentReportCard.surfaceColor),
                    child: Center(child: CircularProgressIndicator(color: ParentReportCard.primaryColor)),
                  );
                }

                if (!logSnap.hasData || (!configSnap.hasData && !configSnap.hasError) || !holidaySnap.hasData) {
                  return const _ErrorView('Waiting for data...');
                }

                final now = DateTime.now();
                final allLogs = logSnap.data ?? [];
                final config = configSnap.data ?? MadrassaConfig(id: 'current', year: now.year, month: now.month);
                
                final currentYear = _selectedYear;
                final currentMonth = _selectedMonth;
                final holidays = (holidaySnap.data ?? [])
                    .map((d) => _parseDateTime(d['date']))
                    .toList();
                final workingDays = MadrassaFeeLogic.getWorkingDaysCount(currentYear, currentMonth, holidays);
                final monthLogs = allLogs;

                final isFeeEnabled = (config.enableFees != false) && LocalStorageService.isMadrassaFeeEnabled(widget.branchId);

                final displayConfig = MadrassaConfig(
                  id: config.id,
                  year: currentYear,
                  month: currentMonth,
                  ptmDay: config.ptmDay,
                  baseFee: config.baseFee,
                  ptmDeduction: config.ptmDeduction,
                  messageTotalDeduction: config.messageTotalDeduction,
                  attendanceMaxDeduction: config.attendanceMaxDeduction,
                  uniformMaxDeduction: config.uniformMaxDeduction,
                  enableFees: isFeeEnabled,
                  auditLog: config.auditLog,
                );

                final fee = MadrassaFeeLogic.calculateStudentFee(
                  studentId: widget.studentId,
                  studentData: studentData,
                  logs: monthLogs,
                  config: displayConfig,
                  totalWorkingDays: workingDays,
                  holidays: holidays,
                );


                final estData = _calculateEstimationData(allLogs);
                final int currentTotalLines = estData['totalMemorized'] as int;
                final double paceWeekly = estData['paceWeekly'] as double;
                final double overallPace = estData['recentDailyRate'] as double;
                final double daysRemaining = estData['daysRemaining'] as double;
                final String estCompletionStr = estData['estCompletionStr'] as String;

                final status = studentData['status'] ?? 'active';
                final rejoinRequestStatus = studentData['rejoinRequestStatus'];
                final rejoinReason = studentData['rejoinRequestReason'];
                final rejoinDate = studentData['rejoinRequestDate'] != null ? _parseDateTime(studentData['rejoinRequestDate']) : null;

                final todayStr = DateFormat('yyyy-MM-dd').format(now);
                final cachedToday = MadrassaLocalStorage.getDailyLogCached(_effectiveBranch, todayStr);
                final cachedTodayLog = (cachedToday != null && cachedToday[widget.studentId] is Map)
                    ? Map<String, dynamic>.from(cachedToday[widget.studentId] as Map)
                    : <String, dynamic>{};

                Map<String, dynamic> firestoreTodayLog = {};
                try {
                  final todayDoc = allLogs.firstWhere((l) => _logDocId(l) == todayStr, orElse: () => <String, dynamic>{});
                  final tData = _logDocData(todayDoc);
                  if (tData != null && tData[widget.studentId] is Map) {
                    firestoreTodayLog = Map<String, dynamic>.from(tData[widget.studentId] as Map);
                  }
                } catch (_) {}

                final Map<String, dynamic> todaySLog = {
                  ...firestoreTodayLog,
                  ...cachedTodayLog,
                };
                final currentStatus = todaySLog['attendance']?.toString() ?? 'unknown';

                final ptmDate = displayConfig.getPtmDate();
                final isPtmToday = now.year == ptmDate.year && now.month == ptmDate.month && now.day == ptmDate.day;

                final selectedDateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);
                final cachedSelected = MadrassaLocalStorage.getDailyLogCached(_effectiveBranch, selectedDateStr);
                final cachedSelectedLog = (cachedSelected != null && cachedSelected[widget.studentId] is Map)
                    ? Map<String, dynamic>.from(cachedSelected[widget.studentId] as Map)
                    : <String, dynamic>{};

                Map<String, dynamic> firestoreSelectedLog = {};
                try {
                  final selDoc = allLogs.firstWhere((l) => _logDocId(l) == selectedDateStr, orElse: () => <String, dynamic>{});
                  final sData = _logDocData(selDoc);
                  if (sData != null && sData[widget.studentId] is Map) {
                    firestoreSelectedLog = Map<String, dynamic>.from(sData[widget.studentId] as Map);
                  }
                } catch (_) {}

                final Map<String, dynamic> selectedDateLog = {
                  ...firestoreSelectedLog,
                  ...cachedSelectedLog,
                };

                final isPtmForSelectedDate = _selectedDate.year == ptmDate.year &&
                    _selectedDate.month == ptmDate.month &&
                    _selectedDate.day == ptmDate.day;
                final selectedDateParentReplied = selectedDateLog['parentReplied'] == true;
                final needsReply = status == 'active' && !selectedDateParentReplied;
                final rawTodayLeaveStatus = todaySLog['leaveStatus']?.toString().toLowerCase().trim();
                final leaveStatus = rawTodayLeaveStatus == 'declined'
                    ? 'denied'
                    : ((rawTodayLeaveStatus == null || rawTodayLeaveStatus.isEmpty)
                        ? (currentStatus == 'leave' ? 'approved' : 'pending')
                        : rawTodayLeaveStatus);

                final holidaysData = (holidaySnap.data ?? []).map((d) {
                  final date = _parseDateTime(d['date']);
                  final name = d is Map && d.containsKey('name') ? d['name']?.toString() ?? 'Holiday' : 'Holiday';
                  return {'date': date, 'name': name};
                }).toList();

                final rawAudit = studentData['auditLog'];
                final auditListRaw = rawAudit is List ? rawAudit : [];
                final auditList = List<Map<String, dynamic>>.from(
                  auditListRaw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)),
                );

                final currentUser = _fbUser;
                final guardianUsername = currentUser?.email ??
                    studentData['guardianEmail']?.toString() ??
                    studentData['contactPhone']?.toString() ??
                    studentData['guardianName']?.toString() ?? '';

                final userThemeKey = guardianUsername.isNotEmpty ? guardianUsername : widget.studentId;

                return ValueListenableBuilder(
                  valueListenable: UserThemeService.listenable(userThemeKey),
                  builder: (context, Box box, _) {
                    final isDark = UserThemeService.isDarkMode(userThemeKey);
                    final scaffoldBg = isDark ? SoftPalette.slate900 : ParentReportCard.surfaceColor;
                    final appBarBg = context.comfort.surface;
                    final barFg = context.comfort.textPrimary;

                    // Inside the executive shell its header already shows the
                    // title, sync and dark mode. Keep only what is unique here
                    // (back to family, child switcher, Accounts) in a slim bar.
                    final hosted = HomeModuleHost.isModuleRoot(context);

                    return MadrassaThemeScope(userKey: userThemeKey, child: _urduSafe(Builder(builder: (context) {
                    // Read inside the theme scope so the chosen theme / dark mode applies.
                    final appBarBg = context.comfort.surface;
                    final barFg = context.comfort.textPrimary;
                    final scaffoldBg = context.comfort.background;
                    return Scaffold(
                      backgroundColor: scaffoldBg,
                      appBar: AppBar(
                        backgroundColor: appBarBg,
                        elevation: 0,
                        toolbarHeight: hosted ? 44 : null,
                        automaticallyImplyLeading: false,
                        iconTheme: IconThemeData(color: context.comfort.textSecondary),
                        surfaceTintColor: Colors.transparent,
                        shape: Border(bottom: BorderSide(color: context.comfort.border)),
                        leading: widget.onBackToSummary != null
                            ? IconButton(
                                icon: Icon(Icons.arrow_back, color: barFg),
                                tooltip: context.t('Back to Family Summary'),
                                onPressed: widget.onBackToSummary,
                              )
                            : hosted
                                ? null
                                : Padding(
                                    padding: const EdgeInsets.all(8.0),
                                    child: Image.asset('assets/logo/gmwf-1.webp', fit: BoxFit.contain),
                                  ),
                        title: hosted && widget.allDocs.length <= 1
                            ? null
                            : widget.allDocs.length <= 1
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      context.isUrdu ? 'گلزار مدینہ مدرسہ' : 'Gulzar Madina Madrassa',
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.bold,
                                        color: barFg,
                                        fontFamily: context.isUrdu ? 'Noori' : null,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    () {
                                      final g = (widget.studentData['guardianName'] ?? widget.studentData['guardianFullName'] ?? widget.studentData['fatherName'])?.toString().trim();
                                      if (g != null && g.isNotEmpty) {
                                        return context.isUrdu ? 'سرپرست: $g' : 'Guardian: $g';
                                      }
                                      if (guardianUsername.isNotEmpty) {
                                        return context.isUrdu ? 'سرپرست: $guardianUsername' : 'Guardian: $guardianUsername';
                                      }
                                      return context.isUrdu ? 'پورٹل سرپرست' : 'Guardian Portal';
                                    }(),
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: context.comfort.textMuted,
                                      fontWeight: FontWeight.w500,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              )
                            : DropdownButtonHideUnderline(
                                child: DropdownButton<int>(
                                  value: widget.selectedIndex,
                                  dropdownColor: context.comfort.surfaceRaised,
                                  icon: Icon(Icons.arrow_drop_down, color: barFg),
                                  isExpanded: true,
                                  style: TextStyle(color: barFg, fontWeight: FontWeight.bold, fontSize: 15),
                                  selectedItemBuilder: (BuildContext context) {
                                    return widget.allDocs.map<Widget>((doc) {
                                      final d = doc is Map ? Map<String, dynamic>.from(doc) : (doc is DocumentSnapshot ? (doc.data() as Map<String, dynamic>?) ?? {} : <String, dynamic>{});
                                      final name = d['name'] ?? 'Student';
                                      return Text(
                                        name,
                                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: barFg, fontFamily: context.isUrdu ? 'Noori' : null, fontFamilyFallback: const ['Noori']),
                                        overflow: TextOverflow.ellipsis,
                                      );
                                    }).toList();
                                  },
                                  items: List.generate(widget.allDocs.length, (index) {
                                    final d = widget.allDocs[index];
                                    final dData = d is Map ? Map<String, dynamic>.from(d) : (d is DocumentSnapshot ? (d.data() as Map<String, dynamic>?) ?? {} : <String, dynamic>{});
                                    final name = dData['name'] ?? 'Student';
                                    return DropdownMenuItem<int>(
                                      value: index,
                                      child: Text(name, style: TextStyle(color: barFg, fontFamilyFallback: const ['Noori'])),
                                    );
                                  }),
                                  onChanged: (val) {
                                    if (val != null) {
                                      widget.onStudentChanged(val);
                                    }
                                  },
                                ),
                              ),
                        actions: [
                          // One ⋮ menu: refresh, language, theme, account, sign out.
                          _parentMenu(context, userThemeKey: userThemeKey),
                          const SizedBox(width: 4),
                        ],
                      ),
                      body: _parentBody(
                        context,
                        isDark: isDark,
                        todaySLog: todaySLog,
                        selectedDateLog: selectedDateLog,
                        isPtmForSelectedDate: isPtmForSelectedDate,
                        currentStatus: currentStatus,
                        leaveStatus: leaveStatus,
                        isPtmToday: isPtmToday,
                        needsReply: needsReply,
                        allLogs: allLogs,
                        holidaysData: holidaysData,
                        config: config,
                        displayConfig: displayConfig,
                        monthLogs: monthLogs,
                        holidays: holidays,
                        fee: fee,
                        currentTotalLines: currentTotalLines,
                        paceWeekly: paceWeekly,
                        overallPace: overallPace,
                        daysRemaining: daysRemaining,
                        estCompletionStr: estCompletionStr,
                        status: status,
                        rejoinRequestStatus: rejoinRequestStatus,
                        rejoinReason: rejoinReason,
                        rejoinDate: rejoinDate,
                        auditList: auditList,
                      ),
                    );
                    })));
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  /// The parents' one ⋮ menu: refresh, language, theme, account, sign out.
  Widget _parentMenu(BuildContext context, {required String userThemeKey}) {
    final urdu = context.isUrdu;
    PopupMenuItem<String> item(String v, IconData icon, String text, {Color? color, bool checked = false}) => PopupMenuItem<String>(
          value: v,
          height: 42,
          child: Row(children: [
            Icon(icon, size: 18, color: color ?? context.comfort.brand),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: TextStyle(fontSize: 13.5, color: color, fontFamily: urdu ? 'Noori' : null))),
            if (checked) Icon(Icons.check_rounded, size: 18, color: context.comfort.brand),
          ]),
        );
    return PopupMenuButton<String>(
      tooltip: urdu ? 'مزید' : 'Menu',
      icon: _isSyncing
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.more_vert_rounded),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      onSelected: (v) async {
        if (v == 'refresh') {
          await _syncLatestData(context);
        } else if (v.startsWith('lang:')) {
          try {
            await Provider.of<MadrassaLanguageProvider>(context, listen: false).setLanguage(v.substring(5));
          } catch (_) {}
        } else if (v == 'appearance') {
          await AppearanceDialog.show(context, userKey: userThemeKey);
        } else if (v == 'account') {
          setState(() => _selectedTab = _selectedTab == 4 ? 0 : 4);
        } else if (v == 'logout') {
          widget.onLogout?.call();
        }
      },
      itemBuilder: (_) => [
        item('refresh', Icons.sync_rounded, urdu ? 'تازہ معلومات لائیں' : 'Refresh data'),
        const PopupMenuDivider(),
        item('lang:ur', Icons.translate_rounded, 'اردو', checked: urdu),
        item('lang:en', Icons.translate_rounded, 'English', checked: !urdu),
        item('appearance', Icons.palette_outlined, urdu ? 'تھیم اور ظاہری شکل' : 'Theme & Appearance'),
        const PopupMenuDivider(),
        item('account', _selectedTab == 4 ? Icons.home_rounded : Icons.account_circle_rounded,
            _selectedTab == 4 ? (urdu ? 'ہوم' : 'Home') : (urdu ? 'میرا اکاؤنٹ' : 'My account')),
        if (widget.onLogout != null)
          item('logout', Icons.logout_rounded, urdu ? 'لاگ آؤٹ' : 'Sign out', color: context.adapt(SoftPalette.red500)),
      ],
    );
  }

  Widget _parentBody(
    BuildContext context, {
    required bool isDark,
    required Map<String, dynamic> todaySLog,
    required Map<String, dynamic> selectedDateLog,
    required bool isPtmForSelectedDate,
    required String currentStatus,
    required String leaveStatus,
    required bool isPtmToday,
    required bool needsReply,
    required List<dynamic> allLogs,
    required List<Map<String, dynamic>> holidaysData,
    required MadrassaConfig config,
    required MadrassaConfig displayConfig,
    required List<dynamic> monthLogs,
    required List<DateTime> holidays,
    required Map<String, dynamic> fee,
    required int currentTotalLines,
    required double paceWeekly,
    required double overallPace,
    required double daysRemaining,
    required String estCompletionStr,
    required String status,
    required String? rejoinRequestStatus,
    required String? rejoinReason,
    required DateTime? rejoinDate,
    required List<Map<String, dynamic>> auditList,
  }) {
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          // ── Islamic Pattern Background ──
                          Positioned.fill(
                            child: Opacity(
                              opacity: isDark ? 0.085 : 0.11,
                              child: GDecorativeImage.asset(
                                'assets/images/islamic_pattern.webp',
                                fit: BoxFit.cover,
                                repeat: ImageRepeat.repeat,
                                color: SoftPalette.yellow300,
                                colorBlendMode: BlendMode.srcIn,
                              ),
                            ),
                          ),
                          LayoutBuilder(
                            builder: (context, constraints) {
                              final isDesktop = constraints.maxWidth > 900;
                              final isTablet = constraints.maxWidth >= 600 && constraints.maxWidth <= 900;

                              return RefreshIndicator(
                                onRefresh: () => _syncLatestData(context),
                                color: ParentReportCard.primaryColor,
                                child: SingleChildScrollView(
                                  physics: const AlwaysScrollableScrollPhysics(),
                                  padding: EdgeInsets.symmetric(
                                    horizontal: isDesktop ? 32 : (isTablet ? 24 : 16),
                                    vertical: 20,
                                  ),
                                  child: Center(
                                    child: Container(
                                      constraints: const BoxConstraints(maxWidth: 1200),
                                    child: _buildTabContent(
                                      _selectedTab,
                                      isDesktop: isDesktop,
                                      isTablet: isTablet,
                                      todaySLog: todaySLog,
                                      selectedDateLog: selectedDateLog,
                                      isPtmForSelectedDate: isPtmForSelectedDate,
                                      currentStatus: currentStatus,
                                      leaveStatus: leaveStatus,
                                      isPtmToday: isPtmToday,
                                      needsReply: needsReply,
                                      allLogs: allLogs,
                                      holidaysData: holidaysData,
                                      config: config,
                                      displayConfig: displayConfig,
                                      monthLogs: monthLogs,
                                      holidays: holidays,
                                      fee: fee,
                                      currentTotalLines: currentTotalLines,
                                      paceWeekly: paceWeekly,
                                      overallPace: overallPace,
                                      daysRemaining: daysRemaining,
                                      estCompletionStr: estCompletionStr,
                                      status: status,
                                      rejoinRequestStatus: rejoinRequestStatus,
                                      rejoinReason: rejoinReason,
                                      rejoinDate: rejoinDate,
                                      auditList: auditList,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                          ),
                        ],
                      );
  }
}

/// The UI font has no Urdu letters: every text on this screen falls back to
/// Noori Nastaliq for them (also titles and buttons, which take theme styles).
Widget _urduSafe(Widget child) => Builder(builder: (context) {
      final theme = Theme.of(context);
      return Theme(
        data: theme.copyWith(textTheme: theme.textTheme.apply(fontFamilyFallback: const ['Noori'])),
        child: DefaultTextStyle.merge(style: const TextStyle(fontFamilyFallback: ['Noori']), child: child),
      );
    });

class _ErrorView extends StatelessWidget {
  final String message;
  const _ErrorView(this.message);
  @override
  Widget build(BuildContext context) => Scaffold(body: Center(child: Text(message, style: const TextStyle(color: ParentReportCard.errorColor))));
}

class _SectionTitle extends StatelessWidget {
  final String label;
  final IconData icon;
  const _SectionTitle({required this.label, required this.icon});
  @override
  Widget build(BuildContext context) {
    final isDark = UserThemeService.isDarkMode();
    return Row(
      children: [
        Icon(icon, size: 20, color: isDark ? SoftPalette.teal300 : ParentReportCard.primaryColor),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 16,
            color: isDark ? SoftPalette.gray50 : ParentReportCard.textPrimaryColor,
            fontFamily: context.isUrdu ? 'Noori' : null,
          ),
        ),
      ],
    );
  }
}



class _QuranAnimationIcon extends StatelessWidget {
  final double size;
  const _QuranAnimationIcon({this.size = 110});

  @override
  Widget build(BuildContext context) {
    final isDark = UserThemeService.isDarkMode();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: isDark ? SoftPalette.slate750 : ParentReportCard.accentColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(size >= 60 ? 24 : 14),
        border: Border.all(color: (isDark ? SoftPalette.teal300 : ParentReportCard.accentColor).withValues(alpha: 0.35), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: (isDark ? SoftPalette.teal300 : ParentReportCard.accentColor).withValues(alpha: 0.18),
            blurRadius: 16,
            spreadRadius: 2,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size >= 60 ? 22 : 12),
        child: Lottie.asset(
          'assets/animations/lesson.json',
          width: size,
          height: size,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) {
            return Center(
              child: Icon(
                Icons.menu_book_rounded,
                color: isDark ? SoftPalette.teal300 : ParentReportCard.accentColor,
                size: size * 0.5,
              ),
            );
          },
        ),
      ),
    );
  }
}



class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool isActive, isSelected;
  final VoidCallback onTap;
  const _ActionButton({required this.label, required this.icon, required this.color, required this.isActive, required this.isSelected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = UserThemeService.isDarkMode();
    return InkWell(
      onTap: isActive ? onTap : null,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: isSelected ? color : (isActive ? color.withValues(alpha: isDark ? 0.15 : 0.1) : (isDark ? SoftPalette.slate800 : SoftPalette.gray100)),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: isSelected ? color : (isActive ? color.withValues(alpha: isDark ? 0.3 : 0.2) : (isDark ? SoftPalette.slate700 : SoftPalette.gray100))),
        ),
        child: Row(
          children: [
            Icon(icon, color: isSelected ? SoftPalette.gray50 : (isActive ? color : context.adapt(SoftPalette.gray350))),
            const SizedBox(width: 16),
            Text(label, style: TextStyle(fontWeight: FontWeight.bold, color: isSelected ? SoftPalette.gray50 : (isActive ? color : context.adapt(SoftPalette.gray350)))),
          ],
        ),
      ),
    );
  }
}

class _CalendarLegend extends StatelessWidget {
  const _CalendarLegend();

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final urdu = context.isUrdu;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Refined non-neon theme colours for both light and dark modes.
    final presentBg = isDark ? const Color(0xFF142B24) : c.successBg;
    final presentBorder = isDark ? const Color(0xFF234B3D) : c.success.withValues(alpha: 0.4);
    final presentFg = isDark ? const Color(0xFFCBD5E1) : c.success;

    final absentBg = isDark ? const Color(0xFF2C191B) : c.dangerBg;
    final absentBorder = isDark ? const Color(0xFF4A2529) : c.danger.withValues(alpha: 0.4);
    final absentFg = isDark ? const Color(0xFFFCA5A5) : c.danger;

    final leaveBg = isDark ? const Color(0xFF152338) : c.infoBg;
    final leaveBorder = isDark ? const Color(0xFF223859) : c.info.withValues(alpha: 0.4);
    final leaveFg = isDark ? const Color(0xFF93C5FD) : c.info;

    final holidayBg = isDark ? const Color(0xFF2A2318) : c.brandSoft;
    final holidayBorder = isDark ? const Color(0xFF483A24) : c.brand.withValues(alpha: 0.4);
    final holidayFg = isDark ? const Color(0xFFFDE68A) : c.brand;

    final islamicBg = isDark ? const Color(0xFF2D2416) : c.warningBg;
    final islamicBorder = isDark ? const Color(0xFF4E3D1F) : c.warning.withValues(alpha: 0.4);
    final islamicFg = isDark ? const Color(0xFFFDE68A) : c.warning;

    final ptmPresentDot = isDark ? const Color(0xFF4ADE80) : c.success;
    final ptmMissedDot = isDark ? const Color(0xFFF87171) : c.danger;

    final items = <(Color, Color, Color, String, bool)>[
      (presentBg, presentBorder, presentFg, urdu ? 'حاضر' : 'Present', false),
      (absentBg, absentBorder, absentFg, urdu ? 'غیر حاضر' : 'Absent', false),
      (leaveBg, leaveBorder, leaveFg, urdu ? 'رخصت' : 'Leave', false),
      (holidayBg, holidayBorder, holidayFg, urdu ? 'چھٹی' : 'Holiday', false),
      (islamicBg, islamicBorder, islamicFg, urdu ? 'اسلامی تہوار' : 'Islamic holiday', false),
      (ptmPresentDot, ptmPresentDot, ptmPresentDot, urdu ? 'پی ٹی ایم: شریک' : 'PTM attended', true),
      (ptmMissedDot, ptmMissedDot, ptmMissedDot, urdu ? 'پی ٹی ایم: غیر حاضر' : 'PTM missed', true),
    ];
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        for (final (bg, borderCol, fg, label, isDot) in items)
          Row(mainAxisSize: MainAxisSize.min, children: [
            isDot
                ? Container(width: 7, height: 7, decoration: BoxDecoration(color: fg, shape: BoxShape.circle))
                : Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4), border: Border.all(color: borderCol)),
                  ),
            const SizedBox(width: 5),
            Text(label, style: TextStyle(fontSize: 11.5, color: c.textSecondary, fontFamily: urdu ? 'Noori' : null)),
          ]),
      ],
    );
  }
}

class _AttendanceCalendar extends StatelessWidget {
  final String studentId;
  final List<dynamic> logs;
  final int year;
  final int month;
  final MadrassaConfig config;
  final DateTime selectedDate;
  final ValueChanged<DateTime> onDateSelected;
  final List<Map<String, dynamic>> holidaysData;
  final DateTime? joinDate;
  final String? branchId;

  /// False inside a card that already has a frame (no box inside a box).
  final bool framed;

  const _AttendanceCalendar({
    super.key,
    this.framed = true,
    required this.studentId,
    required this.logs,
    required this.year,
    required this.month,
    required this.config,
    required this.selectedDate,
    required this.onDateSelected,
    required this.holidaysData,
    this.joinDate,
    this.branchId,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark || UserThemeService.isDarkMode();
    final now = DateTime.now();
    final firstDay = DateTime(year, month, 1);
    final daysInMonth = DateTime(year, month + 1, 0).day;
    final firstWeekday = firstDay.weekday; 
    const dayHeaders = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    final ptmDate = config.getPtmDate();

    final activeHijri = IslamicCalendarHelper.fromGregorian(selectedDate);
    final hijriDateStr = activeHijri.format(isUrdu: context.isUrdu);

    final c = context.comfort;
    return Container(
      padding: framed ? const EdgeInsets.all(12) : EdgeInsets.zero,
      decoration: framed
          ? BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: c.border),
            )
          : null,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(color: c.surfaceSunken, borderRadius: BorderRadius.circular(14)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.nightlight_round, size: 14, color: c.textMuted),
                const SizedBox(width: 6),
                Text(
                  hijriDateStr,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.textSecondary, fontFamily: context.isUrdu ? 'Noori' : null),
                ),
              ],
            ),
          ),
          Row(
            children: dayHeaders
                .map((d) => Expanded(child: Center(child: Text(d, style: TextStyle(fontSize: 11, color: c.textMuted, fontWeight: FontWeight.w700)))))
                .toList(),
          ),
          const SizedBox(height: 8),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
              childAspectRatio: 1,
            ),
            itemCount: daysInMonth + (firstWeekday - 1),
            itemBuilder: (context, index) {
              if (index < firstWeekday - 1) return const SizedBox();
              final day = index - (firstWeekday - 2);
              final date = DateTime(year, month, day);
              final dateStr = DateFormat('yyyy-MM-dd').format(date);
              final isPtm = date.year == ptmDate.year && date.month == ptmDate.month && date.day == ptmDate.day;
              final isPast = date.isBefore(DateTime(now.year, now.month, now.day));
              final isToday = day == now.day && month == now.month && year == now.year;
              final isSelectedDate = day == selectedDate.day && month == selectedDate.month && year == selectedDate.year;

              final isBeforeJoin = joinDate != null && DateTime(date.year, date.month, date.day).isBefore(DateTime(joinDate!.year, joinDate!.month, joinDate!.day));

              Map<String, dynamic>? holidayDoc;
              for (final h in holidaysData) {
                final hDate = h['date'] as DateTime?;
                if (hDate != null && hDate.year == date.year && hDate.month == date.month && hDate.day == date.day) {
                  holidayDoc = h;
                  break;
                }
              }
              final islamicEvent = IslamicCalendarHelper.getIslamicEvent(date);
              final isIslamicHoliday = islamicEvent != null && islamicEvent.isOfficialHoliday;
              final isHoliday = holidayDoc != null || isIslamicHoliday;

              Map<String, dynamic>? statusData;
              try {
                Map<String, dynamic>? doc;
                for (final l in logs) {
                  final lid = (l is Map ? (l['id'] ?? l['date']) : (l is QueryDocumentSnapshot ? l.id : null))?.toString();
                  if (lid == dateStr) {
                    doc = l is Map ? Map<String, dynamic>.from(l) : (l is QueryDocumentSnapshot ? l.data() as Map<String, dynamic>? : null);
                    break;
                  }
                }
                final logStudentMap = (doc != null && doc[studentId] is Map)
                    ? Map<String, dynamic>.from(doc[studentId] as Map)
                    : <String, dynamic>{};
                final cached = (branchId != null && branchId!.isNotEmpty)
                    ? MadrassaLocalStorage.getDailyLogCached(branchId!, dateStr)
                    : null;
                final cachedMap = (cached != null && cached[studentId] is Map)
                    ? Map<String, dynamic>.from(cached[studentId] as Map)
                    : <String, dynamic>{};
                if (logStudentMap.isNotEmpty || cachedMap.isNotEmpty) {
                  statusData = {...logStudentMap, ...cachedMap};
                }
              } catch (_) {}

              final c = context.comfort;
              final ptmAttended = statusData?['ptm'] == true;
              final isSunday = date.weekday == DateTime.sunday;
              final att = statusData?['attendance']?.toString().toLowerCase().trim();
              final leaveStatus = statusData?['leaveStatus']?.toString().toLowerCase().trim();
              final isLeave = att == 'leave' ||
                  att == 'leave_requested' ||
                  ((att == null || att.isEmpty) &&
                      (leaveStatus == 'approved' ||
                          (statusData?['isParentRequested'] == true &&
                              leaveStatus != 'denied' &&
                              leaveStatus != 'declined' &&
                              leaveStatus != 'cancelled')));

              // Calm, elegant theme colours without any harsh neon glare in dark mode.
              Color bg = c.surfaceSunken;
              Color fg = c.textMuted;
              Color? cellBorder;
              String? hint;

              if (isBeforeJoin) {
                bg = Colors.transparent;
                fg = c.textMuted.withValues(alpha: 0.4);
              } else if (isHoliday) {
                final islamicOnly = isIslamicHoliday && holidayDoc == null;
                bg = isDark
                    ? (islamicOnly ? const Color(0xFF2D2416) : const Color(0xFF2A2318))
                    : (islamicOnly ? c.warningBg : c.brandSoft);
                cellBorder = isDark
                    ? (islamicOnly ? const Color(0xFF4E3D1F) : const Color(0xFF483A24))
                    : null;
                fg = isDark
                    ? const Color(0xFFFDE68A)
                    : (islamicOnly ? c.warning : c.brand);
                hint = islamicOnly
                    ? (context.isUrdu ? islamicEvent.titleUr : islamicEvent.titleEn)
                    : (holidayDoc?['name']?.toString() ?? (context.isUrdu ? 'چھٹی' : 'Holiday'));
              } else if (att == 'present') {
                bg = isDark ? const Color(0xFF142B24) : c.successBg;
                cellBorder = isDark ? const Color(0xFF234B3D) : null;
                fg = isDark ? const Color(0xFFE2E8F0) : c.success;
              } else if (isLeave) {
                bg = isDark ? const Color(0xFF152338) : c.infoBg;
                cellBorder = isDark ? const Color(0xFF223859) : null;
                fg = isDark ? const Color(0xFF93C5FD) : c.info;
              } else if (att == 'absent' || (isPast && !isSunday)) {
                bg = isDark ? const Color(0xFF2C191B) : c.dangerBg;
                cellBorder = isDark ? const Color(0xFF4A2529) : null;
                fg = isDark ? const Color(0xFFFCA5A5) : c.danger;
              } else if (isSunday) {
                bg = Colors.transparent;
                fg = c.textMuted;
              }

              Color? dot;
              if (isPtm && !isBeforeJoin) {
                dot = isPast
                    ? (ptmAttended
                        ? (isDark ? const Color(0xFF4ADE80) : c.success)
                        : (isDark ? const Color(0xFFF87171) : c.danger))
                    : (isDark ? const Color(0xFF60A5FA) : c.info);
                hint = isPast
                    ? (ptmAttended ? (context.isUrdu ? 'پی ٹی ایم: شریک' : 'PTM: attended') : (context.isUrdu ? 'پی ٹی ایم: شریک نہیں' : 'PTM: missed'))
                    : (context.isUrdu ? 'پی ٹی ایم' : 'PTM');
              }

              final cell = Container(
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(8),
                  border: isSelectedDate
                      ? Border.all(color: isDark ? const Color(0xFFE2E8F0) : c.brand, width: 1.8)
                      : (isToday
                          ? Border.all(color: (isDark ? const Color(0xFF94A3B8) : c.brand).withValues(alpha: 0.6), width: 1.2)
                          : (cellBorder != null ? Border.all(color: cellBorder, width: 1) : null)),
                ),
                child: Stack(alignment: Alignment.center, children: [
                  Text(
                    '$day',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: isSelectedDate || isToday ? FontWeight.w700 : FontWeight.w500,
                      color: fg,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (dot != null)
                    Positioned(bottom: 4, child: Container(width: 5, height: 5, decoration: BoxDecoration(color: dot, shape: BoxShape.circle))),
                  if (isHoliday && dot == null)
                    Positioned(top: 3, right: 3, child: Icon(Icons.flag_rounded, size: 9, color: fg)),
                ]),
              );
              return GestureDetector(
                onTap: () => onDateSelected(date),
                child: hint == null ? cell : Tooltip(message: hint, child: cell),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _PulsingPtmCell extends StatefulWidget {
  final int day;
  final Color textCol;
  final bool isSelected;
  const _PulsingPtmCell({required this.day, required this.textCol, required this.isSelected});
  @override
  State<_PulsingPtmCell> createState() => _PulsingPtmCellState();
}

class _PulsingPtmCellState extends State<_PulsingPtmCell> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));
    // Eye comfort: a steady highlight instead of a flashing one.
    if (GDecor.reduceMotion) {
      _controller.value = 0.5;
    } else {
      _controller.repeat(reverse: true);
    }
  }
  @override
  void dispose() { _controller.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: LinearGradient(
              colors: [
                ParentReportCard.primaryColor.withValues(alpha: 0.05 + (0.1 * _controller.value)),
                ParentReportCard.primaryColor.withValues(alpha: 0.1 + (0.2 * _controller.value)),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            border: Border.all(
              color: widget.isSelected
                  ? ParentReportCard.accentColor
                  : ParentReportCard.primaryColor.withValues(alpha: 0.2 + (0.4 * _controller.value)),
              width: widget.isSelected ? 2.5 : (1 + _controller.value),
            ),
            boxShadow: [BoxShadow(color: ParentReportCard.primaryColor.withValues(alpha: 0.1 * _controller.value), blurRadius: 8, spreadRadius: 2)],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 4),
              Text('${widget.day}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: widget.textCol)),
              const SizedBox(height: 4),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  margin: const EdgeInsets.only(bottom: 2),
                  decoration: BoxDecoration(
                    color: ParentReportCard.accentColor,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    context.isUrdu ? 'پی ٹی ایم' : 'PTM',
                    style: const TextStyle(fontSize: 7.5, fontWeight: FontWeight.bold, color: SoftPalette.gray50),
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
