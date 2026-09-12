import 'package:image_picker/image_picker.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:collection/collection.dart';
import '../models/madrassa_config.dart';
import '../models/madrassa_fee_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import '../utils/photo_upload_helper.dart';
import '../utils/madrassa_report_helper.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../utils/madrassa_local_storage.dart';
import '../utils/islamic_calendar_helper.dart';
import '../../../services/image_upload_service.dart';
import '../../../services/sync_service.dart';
import '../../../services/local_storage_service.dart';
import '../../../realtime/realtime_manager.dart';
import '../../../realtime/realtime_events.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/madrassa_providers.dart';
import 'dart:async';

import '../madrassa_strings.dart';
import '../../../services/user_theme_service.dart';

bool _isGlobalLevelUser(String role) {
  final r = role.toLowerCase().trim();
  return r == 'chairman' ||
      r == 'ceo' ||
      r == 'hq_manager' ||
      r == 'hq manager' ||
      r == 'superadmin' ||
      r == 'super_admin' ||
      r == 'global_admin' ||
      r == 'global admin' ||
      r == 'admin';
}

class DailyLogView extends ConsumerStatefulWidget {
  final String branchId;
  final String editorName;
  final String editorRole;
  const DailyLogView({
    super.key,
    required this.branchId,
    this.editorName = 'Unknown',
    this.editorRole = 'Madrassa Teacher',
  });

  @override
  ConsumerState<DailyLogView> createState() => _DailyLogViewState();
}

class _DailyLogViewState extends ConsumerState<DailyLogView> {
  DateTime _selectedDate = DateTime.now();
  Map<String, Map<String, dynamic>> _localChanges = {};
  bool _isSaving = false;
  final Map<String, PhotoUploadStatus> _uploadStates = {};
  bool _allPresentToggled = false;
  bool _allUniformToggled = false;
  bool _allRepliedToggled = false;
  // Student notifiers to allow isolated rebuilding of student cards
  final Map<String, ValueNotifier<Map<String, dynamic>>> _studentNotifiers = {};
  // Counter to trigger legend and save button rebuilds
  final ValueNotifier<int> _changeNotifier = ValueNotifier(0);
  final ScrollController _calendarScrollController = ScrollController();
  final ScrollController _verticalScrollController = ScrollController();
  final GlobalKey _calendarKey = GlobalKey();
  bool _hasInitialScrollDone = false;
  bool _showBackToTop = false;
  bool? _localAllowStudentLeave;

  @override
  void initState() {
    super.initState();
    _verticalScrollController.addListener(() {
      final show = _verticalScrollController.offset > 300;
      if (show != _showBackToTop) {
        setState(() {
          _showBackToTop = show;
        });
      }
    });
    _calendarScrollController.addListener(() {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToSelectedDate(animate: false);
    });

    // Initialise streams/downloads for the initially selected date
    _updateDateStreams();
  }

  @override
  void dispose() {
    _calendarScrollController.dispose();
    _verticalScrollController.dispose();
    super.dispose();
  }

  // Initialise streams/downloads for the selected date
  void _updateDateStreams() {
    MadrassaLocalStorage.downloadStudents(widget.branchId);
    MadrassaLocalStorage.downloadLogsForMonth(
        widget.branchId, _selectedDate.year, _selectedDate.month);
    MadrassaLocalStorage.downloadHolidays(widget.branchId);
  }

  bool _isFutureDate(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final compareDate = DateTime(date.year, date.month, date.day);
    return compareDate.isAfter(today);
  }

  bool _canSaveData() {
    final now = DateTime.now();
    final selY = _selectedDate.year;
    final selM = _selectedDate.month;
    final curY = now.year;
    final curM = now.month;

    final prevMonthDate = DateTime(curY, curM - 1, 1);
    final prevY = prevMonthDate.year;
    final prevM = prevMonthDate.month;

    return (selY == curY && selM == curM) || (selY == prevY && selM == prevM);
  }

  DateTime getPtmDateFor(int targetYear, int targetMonth, MadrassaConfig config) {
    final reschedule = config.auditLog.firstWhereOrNull((log) =>
        log['type'] == 'ptm_reschedule' &&
        log['year'] == targetYear &&
        log['month'] == targetMonth);
        
    if (reschedule != null) {
      final newVal = int.tryParse(reschedule['newValue']?.toString() ?? '');
      if (newVal != null && newVal > 0) {
        return DateTime(targetYear, targetMonth, newVal);
      }
    }

    if (config.ptmDay > 0) {
      return DateTime(targetYear, targetMonth, config.ptmDay);
    }

    DateTime date = DateTime(targetYear, targetMonth, 1);
    while (date.weekday != DateTime.friday) {
      date = date.add(const Duration(days: 1));
    }
    return date;
  }

  void _scrollToSelectedDate({bool animate = true}) {
    if (!_calendarScrollController.hasClients) return;
    final context = _calendarKey.currentContext;
    if (context == null) return;

    final RenderBox? renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final viewportWidth = renderBox.size.width;
    if (viewportWidth <= 0) return;

    final daysInMonth = DateTime(_selectedDate.year, _selectedDate.month + 1, 0).day;
    const itemWidth = 68.0; // 60 width + 8 horizontal margin (4 each side)
    const listPadding = 16.0; // padding at start of list

    final index = _selectedDate.day - 1;
    final itemCenter = listPadding + (index * itemWidth) + (itemWidth / 2);
    final targetOffset = itemCenter - (viewportWidth / 2);

    final maxScroll = (listPadding * 2) + (daysInMonth * itemWidth) - viewportWidth;
    final clampedOffset = targetOffset.clamp(0.0, maxScroll < 0 ? 0.0 : maxScroll);

    if (animate) {
      _calendarScrollController.animateTo(
        clampedOffset,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      _calendarScrollController.jumpTo(clampedOffset);
    }
  }

  Future<void> _saveChanges() async {
    if (_localChanges.isEmpty) return;
    setState(() => _isSaving = true);

    // Validation for sabki and manzil fields: both Para and Ratio must be provided together.
    for (var entry in _localChanges.entries) {
      final data = entry.value;
      
      // Sabki validation
      final int sabkiPara = data['sabkiPara'] is int ? data['sabkiPara'] : 0;
      final String? sabkiRatio = data['sabkiRatio']?.toString();
      final bool hasSabkiRatio = sabkiRatio != null && sabkiRatio.isNotEmpty && sabkiRatio != '-';
      
      if (hasSabkiRatio && sabkiRatio != 'nahi_sunaya' && sabkiPara == 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sabki: Para must be selected for ratio $sabkiRatio.')),
        );
        setState(() => _isSaving = false);
        return;
      }
      if (sabkiPara > 0 && !hasSabkiRatio) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sabki: Ratio must be selected for Para $sabkiPara.')),
        );
        setState(() => _isSaving = false);
        return;
      }

      // Manzil validation
      final int manzilPara = data['manzilPara'] is int ? data['manzilPara'] : 0;
      final String? manzilRatio = data['manzilRatio']?.toString();
      final bool hasManzilRatio = manzilRatio != null && manzilRatio.isNotEmpty && manzilRatio != '-';
      
      if (hasManzilRatio && manzilRatio != 'nahi_sunaya' && manzilPara == 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Manzil: Para must be selected for ratio $manzilRatio.')),
        );
        setState(() => _isSaving = false);
        return;
      }
      if (manzilPara > 0 && !hasManzilRatio) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Manzil: Ratio must be selected for Para $manzilPara.')),
        );
        setState(() => _isSaving = false);
        return;
      }
    }

    try {
      final String dateKey = DateFormat('yyyy-MM-dd').format(_selectedDate);

      // Save locally (updates cached student currentLines, enqueues sync tasks, enqueues audit logs)
      await MadrassaLocalStorage.saveLogRecordLocal(
        branchId: widget.branchId,
        dateKey: dateKey,
        logData: _localChanges,
        editorName: widget.editorName,
        editorRole: widget.editorRole,
      );

      // Write audit log entry in background
      unawaited(MadrassaAuditService.logAction(
        branchId: widget.branchId,
        editor: widget.editorName.isNotEmpty && widget.editorName != 'Unknown' ? widget.editorName : 'Teacher',
        role: widget.editorRole,
        type: 'daily_log_edit',
        message: 'Updated daily log attendance & lesson records for $dateKey (${_localChanges.length} students)',
      ));

      // Trigger background upload if online
      SyncService().triggerUpload();

      setState(() {
  _localChanges = {};
  _isSaving = false;
  _allPresentToggled = false;
  _allUniformToggled = false;
  _allRepliedToggled = false;
  _studentNotifiers.clear();
});
_changeNotifier.value++;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l.savedSuccess)),
        );
      }
    } catch (e) {
      setState(() => _isSaving = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }





  Map<String, dynamic> _safeMap(dynamic val) {
    if (val is Map) {
      return Map<String, dynamic>.from(val);
    }
    return {};
  }

  // Update local changes silently (isolated rebuilds)
  void _updateLocalSilent(String sId, String key, dynamic value) {
    if (!_localChanges.containsKey(sId)) {
      final dateKey = DateFormat('yyyy-MM-dd').format(_selectedDate);
      final logData = ref.read(madrassaDailyLogProvider((branchId: widget.branchId, dateKey: dateKey))).value ?? {};
      final dbLog = _safeMap(logData[sId]);
      _localChanges[sId] = Map<String, dynamic>.from(dbLog);
    }
    _localChanges[sId]![key] = value;
    if (_studentNotifiers.containsKey(sId)) {
      _studentNotifiers[sId]!.value =
          Map<String, dynamic>.from(_localChanges[sId]!);
    }
    _changeNotifier.value++;
  }

  void _updateSabakLines(String sId, int newSabak) {
    final dateKey = DateFormat('yyyy-MM-dd').format(_selectedDate);
    final logData = ref.read(madrassaDailyLogProvider((branchId: widget.branchId, dateKey: dateKey))).value ?? {};
    final dbLog = _safeMap(logData[sId]);
    final currentLocal = _localChanges[sId] ?? dbLog;

    final studentCache = MadrassaLocalStorage.getStudentCached(widget.branchId, sId);
    final initialCurrentLines = (studentCache?['currentLines'] as num?)?.toInt() ?? 0;

    int existingCurrent = (currentLocal['currentLines'] as num?)?.toInt() ?? initialCurrentLines;
    int existingSabak = (currentLocal['sabakLines'] as num?)?.toInt() ?? 0;
    int baseLines = existingCurrent - existingSabak;
    if (baseLines < 0) baseLines = 0;

    int sabakLines;
    int currentLines;

    if (newSabak <= 50) {
      sabakLines = newSabak;
      currentLines = (baseLines + sabakLines).clamp(0, 8640);
    } else {
      currentLines = newSabak.clamp(0, 8640);
      sabakLines = (currentLines - baseLines).clamp(0, 8640);
    }

    _updateLocalSilent(sId, 'sabakLines', sabakLines);
    _updateLocalSilent(sId, 'currentLines', currentLines);
  }

  void _updateAttendanceSilent(String sId, String value) {
    _updateLocalSilent(sId, 'attendance', value);
    if (value == 'leave') {
      _updateLocalSilent(sId, 'uniform', 'leave');
    } else if (value == 'absent') {
      _updateLocalSilent(sId, 'uniform', false);
    }
  }

  void _showPtmClaimsPopup(BuildContext context, List<Map<String, dynamic>> claims) {
    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: Row(
                children: [
                  const Icon(Icons.people_rounded, color: Colors.blue),
                  const SizedBox(width: 8),
                  Text(
                    context.isUrdu ? 'پی ٹی ایم حاضری کے دعوے' : 'PTM Attendance Claims',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: claims.isEmpty
                    ? Center(
                        child: Text(
                          context.isUrdu ? 'کوئی دعوے زیر التوا نہیں ہیں' : 'No claims pending',
                          style: const TextStyle(color: Colors.grey),
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: claims.length,
                        separatorBuilder: (_, __) => const Divider(),
                        itemBuilder: (context, index) {
                          final claim = claims[index];
                          final sId = claim['id'];
                          final name = claim['name'];
                          final roll = claim['rollNumber'];
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8.0),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                                      Text('Roll: $roll', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                                    ],
                                  ),
                                ),
                                ElevatedButton(
                                  onPressed: () {
                                    _updateLocalSilent(sId, 'ptm', true);
                                    _updateLocalSilent(sId, 'ptmRequestStatus', 'approved');
                                    setDialogState(() {
                                      claims.removeAt(index);
                                    });
                                    if (claims.isEmpty) {
                                      Navigator.pop(ctx);
                                    }
                                  },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.green,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    minimumSize: Size.zero,
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  child: const Text('Approve'),
                                ),
                                const SizedBox(width: 8),
                                ElevatedButton(
                                  onPressed: () {
                                    _updateLocalSilent(sId, 'ptm', false);
                                    _updateLocalSilent(sId, 'ptmRequestStatus', 'rejected');
                                    setDialogState(() {
                                      claims.removeAt(index);
                                    });
                                    if (claims.isEmpty) {
                                      Navigator.pop(ctx);
                                    }
                                  },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.red,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    minimumSize: Size.zero,
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  child: const Text('Decline'),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Close'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width > 900;
    
    final configAsyncValue = ref.watch(madrassaConfigProvider(widget.branchId));
    final holidaysAsyncValue = ref.watch(madrassaHolidaysProvider(widget.branchId));
    final dateKey = DateFormat('yyyy-MM-dd').format(_selectedDate);
    final filteredStudentsAsyncValue = ref.watch(madrassaFilteredStudentsProvider((branchId: widget.branchId, selectedDate: _selectedDate)));
    final logAsyncValue = ref.watch(madrassaDailyLogProvider((branchId: widget.branchId, dateKey: dateKey)));

    return configAsyncValue.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, st) => Scaffold(body: Center(child: Text('Error loading config: $e'))),
      data: (config) {
        final effectiveAllowLeave = _localAllowStudentLeave ?? config.allowStudentLeave;
        final ptmDate = getPtmDateFor(_selectedDate.year, _selectedDate.month, config);
        final isPtmDay = _selectedDate.year == ptmDate.year && _selectedDate.month == ptmDate.month && _selectedDate.day == ptmDate.day;
        final isReadOnly = !_canSaveData();

        // Read holidays from cache
        final cachedHolidays = holidaysAsyncValue.value ?? [];
        String? holidayName;
        for (final h in cachedHolidays) {
          final dateVal = h['date'];
          DateTime? d;
          if (dateVal is String) {
            d = DateTime.tryParse(dateVal);
          } else if (dateVal is Timestamp) {
            d = dateVal.toDate();
          }
          if (d != null && d.year == _selectedDate.year && d.month == _selectedDate.month && d.day == _selectedDate.day) {
            holidayName = h['name'] as String? ?? 'Holiday';
            break;
          }
        }
        final islamicEvent = IslamicCalendarHelper.getIslamicEvent(_selectedDate);
        final isIslamicHoliday = islamicEvent != null && islamicEvent.isOfficialHoliday;
        if (holidayName == null && isIslamicHoliday) {
          holidayName = context.isUrdu ? islamicEvent.titleUr : islamicEvent.titleEn;
        }
        final isHoliday = holidayName != null;
        final isSunday = _selectedDate.weekday == DateTime.sunday;
        final isDark = Theme.of(context).brightness == Brightness.dark || UserThemeService.isDarkMode(widget.editorName);

        return Scaffold(
          backgroundColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8F9FD),
          floatingActionButton: ValueListenableBuilder<int>(
            valueListenable: _changeNotifier,
            builder: (context, _, __) {
              return _buildFabArea(isDesktop) ?? const SizedBox.shrink();
            },
          ),
          body: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: IgnorePointer(
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
              ),
              RefreshIndicator(
                onRefresh: () async {
                  final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);
                  await MadrassaLocalStorage.downloadLogsForMonth(widget.branchId, _selectedDate.year, _selectedDate.month);
                  await MadrassaLocalStorage.downloadStudents(widget.branchId, force: true);
                  ref.invalidate(madrassaDailyLogProvider((branchId: widget.branchId, dateKey: dateStr)));
                  ref.invalidate(madrassaFilteredStudentsProvider((branchId: widget.branchId, selectedDate: _selectedDate)));
                  if (mounted) setState(() {});
                },
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  key: const PageStorageKey('daily_log_scroll'),
                  controller: _verticalScrollController,
                  slivers: [
              SliverToBoxAdapter(
                child: _buildHeader(config),
              ),
              // Holiday summary for the selected month
              SliverToBoxAdapter(
                child: _buildHorizontalCalendar(config, cachedHolidays),
              ),
              // Pending PTM claims notification banner
              ValueListenableBuilder<int>(
                valueListenable: _changeNotifier,
                builder: (context, _, __) {
                  final logData = logAsyncValue.value ?? {};
                  final pendingPtmClaims = <Map<String, dynamic>>[];
                  final studentsList = filteredStudentsAsyncValue.value ?? [];
                  for (final s in studentsList) {
                    final sId = s['id'] ?? '';
                    final sLog = _localChanges[sId] ?? _safeMap(logData[sId]);
                    if (sLog['ptmRequestStatus'] == 'claimed') {
                      pendingPtmClaims.add({
                        'id': sId,
                        'name': s['name'] ?? 'Student',
                        'rollNumber': s['rollNumber'] ?? '?',
                        'log': sLog,
                      });
                    }
                  }

                  if (pendingPtmClaims.isEmpty || isReadOnly) {
                    return const SliverToBoxAdapter(child: SizedBox.shrink());
                  }

                  return SliverToBoxAdapter(
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.blue.shade200),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.people_rounded, color: Colors.blue.shade900),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  context.isUrdu 
                                      ? 'پی ٹی ایم کی حاضری کے دعوے زیر التوا ہیں'
                                      : 'Pending PTM Attendance Claims',
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.blue.shade900),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  context.isUrdu
                                      ? '${pendingPtmClaims.length} طلباء نے پی ٹی ایم میں شرکت کا دعویٰ کیا ہے۔ جائزہ لینے کے لیے کلک کریں۔'
                                      : '${pendingPtmClaims.length} student(s) claimed PTM attendance. Tap to review.',
                                  style: TextStyle(fontSize: 12, color: Colors.blue.shade800),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          ElevatedButton(
                            onPressed: () {
                              _showPtmClaimsPopup(context, pendingPtmClaims);
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue.shade700,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            child: Text(context.isUrdu ? 'جائزہ لیں' : 'Review'),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              if (isReadOnly)
                SliverToBoxAdapter(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.amber.shade200),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, color: Colors.amber.shade900),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            context.isUrdu
                                ? 'صرف پڑھنے کی حد: آپ صرف موجودہ یا پچھلے مہینے کا ڈیٹا تبدیل اور محفوظ کر سکتے ہیں۔'
                                : 'Read-Only Mode: You can only edit and save daily log data for the current or previous month.',
                            style: context.urduStyle(
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: Colors.amber.shade900,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (isHoliday)
                SliverToBoxAdapter(
                  child: Container(
                    height: MediaQuery.of(context).size.height - 250,
                    alignment: Alignment.center,
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(24),
                            decoration: BoxDecoration(
                              color: islamicEvent != null
                                  ? const Color(0xFFD4AF37).withValues(alpha: 0.15)
                                  : Colors.green.shade50,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: islamicEvent != null
                                    ? const Color(0xFFD4AF37).withValues(alpha: 0.4)
                                    : Colors.green.shade200,
                                width: 2,
                              ),
                            ),
                            child: islamicEvent != null
                                ? Text(islamicEvent.emoji, style: const TextStyle(fontSize: 52))
                                : Icon(Icons.flag_rounded, size: 64, color: Colors.green.shade700),
                          ),
                          const SizedBox(height: 24),
                          Text(
                            holidayName!,
                            textAlign: TextAlign.center,
                            style: context.urduStyle(
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: islamicEvent != null
                                    ? (isDark ? const Color(0xFFFDE047) : const Color(0xFF92400E))
                                    : const Color(0xFF1B5E20),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            islamicEvent != null
                                ? (context.isUrdu
                                    ? '${islamicEvent.descriptionUr} - مبارک ہو!'
                                    : '${islamicEvent.descriptionEn} - Mubarak!')
                                : DateFormat('EEEE, MMMM d, yyyy').format(_selectedDate),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: islamicEvent != null
                                  ? (isDark ? const Color(0xFFFBBF24) : const Color(0xFFB45309))
                                  : Colors.grey,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.green.shade100.withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              () {
                                final now = DateTime.now();
                                final isToday = _selectedDate.year == now.year &&
                                    _selectedDate.month == now.month &&
                                    _selectedDate.day == now.day;
                                if (isToday) {
                                  return context.isUrdu
                                      ? 'آج مدرسہ بند ہے'
                                      : 'Madrassa is Closed Today';
                                } else {
                                  return context.isUrdu
                                      ? 'اس دن مدرسہ بند ہے'
                                      : 'Madrassa is Closed on this Day';
                                }
                              }(),
                              style: context.urduStyle(
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.green.shade900,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else if (isSunday)
                SliverToBoxAdapter(
                  child: Container(
                    height: MediaQuery.of(context).size.height - 250,
                    alignment: Alignment.center,
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(24),
                            decoration: BoxDecoration(
                              color: Colors.blue.shade50,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.blue.shade200, width: 2),
                            ),
                            child: Icon(Icons.weekend_rounded, size: 64, color: Colors.blue.shade700),
                          ),
                          const SizedBox(height: 24),
                          Text(
                            context.isUrdu ? 'اتوار کی چھٹی' : 'Weekly Holiday (Sunday)',
                            style: context.urduStyle(
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF0D47A1),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            DateFormat('EEEE, MMMM d, yyyy').format(_selectedDate),
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else if (_isFutureDate(_selectedDate))
                SliverToBoxAdapter(
                  child: Container(
                    height: MediaQuery.of(context).size.height - 250,
                    alignment: Alignment.center,
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            isPtmDay ? Icons.people_outline : Icons.calendar_today_outlined,
                            size: 64,
                            color: isPtmDay ? Colors.orange : Colors.grey.shade400,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            isPtmDay
                                ? (context.isUrdu ? 'پی ٹی ایم میٹنگ شیڈول ہے' : 'PTM Meeting Scheduled')
                                : context.l.futureDateTitle,
                            style: context.urduStyle(
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: isPtmDay ? Colors.orange.shade800 : Colors.grey,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 32.0),
                            child: Text(
                              isPtmDay
                                  ? (context.isUrdu
                                      ? 'اس تاریخ کو پیرنٹ ٹیچر میٹنگ (PTM) شیڈول ہے۔'
                                      : 'At this date, the Parent Teacher Meeting is scheduled.')
                                  : context.l.futureDateSubtitle,
                              textAlign: TextAlign.center,
                              style: context.urduStyle(
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: Colors.grey,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else
                filteredStudentsAsyncValue.when(
                  loading: () => const SliverToBoxAdapter(
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (e, st) => SliverToBoxAdapter(
                    child: Center(child: Text('Error: $e')),
                  ),
                  data: (students) {
                    return logAsyncValue.when(
                      loading: () => const SliverToBoxAdapter(
                        child: Center(child: CircularProgressIndicator()),
                      ),
                      error: (e, st) => SliverToBoxAdapter(
                        child: Center(child: Text('Error: $e')),
                      ),
                      data: (logData) {
                        final double paddingVal = MediaQuery.of(context).size.width < 600 ? 16 : 24;

                        return SliverPadding(
                          padding: EdgeInsets.symmetric(horizontal: paddingVal),
                          sliver: SliverList(
                            key: const PageStorageKey('daily_log_student_list'),
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                if (index == 0) {
                                  return Column(
                                    children: [
                                      if (isReadOnly)
                                        Container(
                                          margin: const EdgeInsets.only(bottom: 8),
                                          padding: const EdgeInsets.all(8),
                                          width: double.infinity,
                                          alignment: Alignment.center,
                                          decoration: BoxDecoration(
                                            color: Colors.amber.shade50,
                                            borderRadius: BorderRadius.circular(8),
                                            border: Border.all(color: Colors.amber.shade200),
                                          ),
                                          child: Text(
                                            context.isUrdu ? 'صرف پڑھنے کی اجازت ہے (پرانی تاریخ)' : 'Read Only Mode (Past Date)',
                                            style: TextStyle(color: Colors.amber.shade900, fontSize: 12, fontWeight: FontWeight.bold),
                                          ),
                                        ),
                                      ValueListenableBuilder<int>(
                                        valueListenable: _changeNotifier,
                                        builder: (context, _, __) =>
                                            _buildStatusLegend(context, config, students, logData),
                                      ),
                                    ],
                                  );
                                }
                                final s = students[index - 1];
                                final sId = s['id'] ?? '';
                                final sLog = _localChanges[sId] ?? _safeMap(logData[sId]);
                                final notifier = _studentNotifiers.putIfAbsent(
                                    sId, () => ValueNotifier(sLog));
                                return _StudentLogCard(
                                  key: ValueKey('${sId}_${_selectedDate.toIso8601String()}'),
                                  student: s,
                                  logNotifier: notifier,
                                  isPtmDay: isPtmDay,
                                  isReadOnly: isReadOnly,
                                  branchId: widget.branchId,
                                  allowStudentLeave: effectiveAllowLeave,
                                  editorRole: widget.editorRole,
                                  uploadStatus: _uploadStates[sId],
                                  onUpdateLocal: _updateLocalSilent,
                                  onUpdateSabak: _updateSabakLines,
                                  onPickPhoto: _pickAndUploadPhoto,
                                  onSendWhatsApp: _sendDailyWhatsApp,
                                  onShowCustomLines: _showCustomLinesDialog,
                                  buildParaDropdown: _buildParaDropdown,
                                  buildRatioDropdown: _buildRatioDropdown,
                                );
                              },
                              childCount: students.length + 1,
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              const SliverToBoxAdapter(
                child: SizedBox(height: 80),
              ),
            ],
          ),
        ),
        ],
      ),
    );
      },
    );
  }



  // Builds the status legend based on students and log data


  Widget _buildHeader(MadrassaConfig config) {
    final ptmDate = getPtmDateFor(_selectedDate.year, _selectedDate.month, config);
    final workingDays = MadrassaFeeLogic.getWorkingDaysCount(_selectedDate.year, _selectedDate.month);
    final isMobile = MediaQuery.of(context).size.width < 600;
    final effectiveAllowLeave = _localAllowStudentLeave ?? config.allowStudentLeave;
    final isDark = Theme.of(context).brightness == Brightness.dark || UserThemeService.isDarkMode(widget.editorName);

    final controlsRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton.icon(
          icon: const Icon(Icons.today, size: 16, color: Color(0xFF008080)),
          label: Text(
            context.isUrdu ? 'آج' : 'Today',
            style: const TextStyle(
              color: Color(0xFF008080),
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: () {
            setState(() {
              _selectedDate = DateTime.now();
              _localChanges.clear();
              _studentNotifiers.clear();
            });
            _changeNotifier.value++;
            _updateDateStreams();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _scrollToSelectedDate(animate: true);
            });
          },
        ),
        const SizedBox(width: 4),
        IconButton(
          icon: const Icon(Icons.arrow_back_ios, size: 16, color: Color(0xFF008080)),
          tooltip: 'Previous Month',
          padding: const EdgeInsets.all(6),
          constraints: const BoxConstraints(),
          onPressed: () {
            setState(() {
              final prevMonth = DateTime(_selectedDate.year, _selectedDate.month - 1, 1);
              final lastDayOfPrevMonth = DateTime(prevMonth.year, prevMonth.month + 1, 0).day;
              final targetDay = _selectedDate.day.clamp(1, lastDayOfPrevMonth);
              _selectedDate = DateTime(prevMonth.year, prevMonth.month, targetDay);
              _localChanges.clear();
              _studentNotifiers.clear();
            });
            _changeNotifier.value++;
            _updateDateStreams();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _scrollToSelectedDate(animate: true);
            });
          },
        ),
        const SizedBox(width: 4),
        IconButton(
          icon: const Icon(Icons.arrow_forward_ios, size: 16, color: Color(0xFF008080)),
          tooltip: 'Next Month',
          padding: const EdgeInsets.all(6),
          constraints: const BoxConstraints(),
          onPressed: () {
            setState(() {
              final nextMonth = DateTime(_selectedDate.year, _selectedDate.month + 1, 1);
              final lastDayOfNextMonth = DateTime(nextMonth.year, nextMonth.month + 1, 0).day;
              final targetDay = _selectedDate.day.clamp(1, lastDayOfNextMonth);
              _selectedDate = DateTime(nextMonth.year, nextMonth.month, targetDay);
              _localChanges.clear();
              _studentNotifiers.clear();
            });
            _changeNotifier.value++;
            _updateDateStreams();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _scrollToSelectedDate(animate: true);
            });
          },
        ),
      ],
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(isMobile ? 16 : 24, isMobile ? 16 : 24, isMobile ? 16 : 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      DateFormat('MMMM yyyy').format(_selectedDate),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: isMobile ? 18 : 22,
                        color: isDark ? Colors.white : const Color(0xFF1A1C1E),
                      ),
                    ),
                    Text(
                      context.l.dailyLog,
                      style: context.urduStyle(
                        style: TextStyle(
                          fontSize: isMobile ? 12 : 13,
                          fontWeight: FontWeight.w600,
                          color: isDark ? const Color(0xFF818CF8) : const Color(0xFF4C4DDC),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              controlsRow,
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '$workingDays working days • Sundays excluded • PTM: ${DateFormat('EEE, MMM d').format(ptmDate)}',
            style: TextStyle(
              fontSize: isMobile ? 12 : 13,
              color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600,
            ),
          ),
          if (_isGlobalLevelUser(widget.editorRole)) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: effectiveAllowLeave ? const Color(0xFFFFF8E1) : const Color(0xFFE0F2F1),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: effectiveAllowLeave ? Colors.amber.shade400 : const Color(0xFF008080),
                  width: 1.5,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    effectiveAllowLeave ? Icons.event_available_rounded : Icons.event_busy_rounded,
                    color: effectiveAllowLeave ? Colors.amber.shade900 : const Color(0xFF008080),
                    size: 26,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E293B),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                context.isUrdu ? '👑 صرف گلوبل لیول یوزرز' : '👑 Global Users Only (Chairman, CEO, HQ Manager, Admin)',
                                style: const TextStyle(color: Colors.amber, fontSize: 10, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          effectiveAllowLeave
                              ? (context.isUrdu ? 'طلباء کی رخصت (L) تمام یوزرز کے لیے آن ہے' : 'Student Leave Allowed (Visible to ALL Users)')
                              : (context.isUrdu ? 'طلباء کی رخصت (L) تمام یوزرز کے لیے بند ہے' : 'Student Leave Stopped (Hidden from ALL Users)'),
                          style: context.urduStyle(
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              color: effectiveAllowLeave ? Colors.amber.shade900 : const Color(0xFF004D40),
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          effectiveAllowLeave
                              ? (context.isUrdu
                                  ? 'رخصت بند کرنے کے لیے کلک کریں۔ یہ تمام اساتذہ، پرنسپل اور گلوبل یوزرز سے بٹن چھپا دے گا۔'
                                  : 'Click to STOP leave. This will hide the Leave (L) button for ALL users.')
                              : (context.isUrdu
                                  ? 'رخصت کھولنی کے لیے کلک کریں۔ یہ تمام اساتذہ، پرنسپل اور گلوبل یوزرز کے لیے بٹن ظاہر کر دے گا۔'
                                  : 'Click to ALLOW leave. This will display the Leave (L) button for ALL users.'),
                          style: context.urduStyle(
                            style: TextStyle(
                              fontSize: 12,
                              color: effectiveAllowLeave ? Colors.amber.shade900 : Colors.grey.shade700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: effectiveAllowLeave ? const Color(0xFFD32F2F) : const Color(0xFF008080),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                    icon: Icon(
                      effectiveAllowLeave ? Icons.block : Icons.check_circle_outline,
                      size: 18,
                    ),
                    label: Text(
                      effectiveAllowLeave
                          ? (context.isUrdu ? 'رخصت بند کریں' : 'Stop Leave')
                          : (context.isUrdu ? 'اجازت رخصت دیں' : 'Allow Leave'),
                      style: context.urduStyle(
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ),
                    onPressed: () async {
                      final newAllowState = !effectiveAllowLeave;
                      setState(() {
                        _localAllowStudentLeave = newAllowState;
                      });
                      unawaited(
                        FirebaseFirestore.instance
                            .collection('branches')
                            .doc(widget.branchId)
                            .collection('madrassa_config')
                            .doc('current')
                            .set({'allowStudentLeave': newAllowState}, SetOptions(merge: true))
                            .timeout(const Duration(seconds: 4))
                            .catchError((err) {
                              debugPrint('[DailyLogView] Update allowStudentLeave error: $err');
                            })
                      );

                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            duration: const Duration(seconds: 2),
                            backgroundColor: newAllowState ? const Color(0xFF2E7D32) : const Color(0xFFC62828),
                            content: Text(
                              newAllowState
                                  ? (context.isUrdu
                                      ? 'رخصت کا بٹن تمام اساتذہ اور تمام یوزرز کے لیے آن ہو گیا ہے۔'
                                      : 'Leave (L) button is now VISIBLE to ALL users.')
                                  : (context.isUrdu
                                      ? 'رخصت کا بٹن تمام اساتذہ اور تمام یوزرز کے لیے بند کر دیا گیا ہے۔'
                                      : 'Leave (L) button is now HIDDEN from ALL users.'),
                            ),
                          ),
                        );
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHorizontalCalendar(MadrassaConfig config, List<Map<String, dynamic>> holidays) {
    final daysInMonth = DateTime(_selectedDate.year, _selectedDate.month + 1, 0).day;
    final now = DateTime.now();

    if (!_hasInitialScrollDone) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_calendarScrollController.hasClients) {
          _scrollToSelectedDate(animate: false);
          _hasInitialScrollDone = true;
        }
      });
    }

    final showLeftGrey = !_calendarScrollController.hasClients || _calendarScrollController.offset <= 0;
    final showRightGrey = !_calendarScrollController.hasClients || 
        (_calendarScrollController.position.hasContentDimensions &&
         _calendarScrollController.offset >= _calendarScrollController.position.maxScrollExtent);
    final leftColor = showLeftGrey ? Colors.grey : const Color(0xFF008080);
    final rightColor = showRightGrey ? Colors.grey : const Color(0xFF008080);

    return Row(
      children: [
        IconButton(
          icon: Icon(Icons.chevron_left, color: leftColor),
          onPressed: showLeftGrey
              ? null
              : () {
                  if (_calendarScrollController.hasClients) {
                    final target = (_calendarScrollController.offset - 204.0).clamp(0.0, _calendarScrollController.position.maxScrollExtent);
                    _calendarScrollController.animateTo(
                      target,
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                    );
                  }
                },
        ),
        Expanded(
          child: SizedBox(
            key: _calendarKey,
            height: 100,
            child: Listener(
              onPointerSignal: (pointerSignal) {
                if (pointerSignal is PointerScrollEvent && _calendarScrollController.hasClients) {
                  final newOffset = _calendarScrollController.offset + pointerSignal.scrollDelta.dy;
                  _calendarScrollController.jumpTo(
                    newOffset.clamp(
                      0.0,
                      _calendarScrollController.position.maxScrollExtent,
                    ),
                  );
                }
              },
              child: ListView.builder(
                controller: _calendarScrollController,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: daysInMonth,
                itemBuilder: (context, i) {
                  final date = DateTime(_selectedDate.year, _selectedDate.month, i + 1);
                  final isSelected = date.day == _selectedDate.day;
                  final isSunday = date.weekday == DateTime.sunday;
                  final ptmDateForCell = getPtmDateFor(date.year, date.month, config);
                  final isPtm = date.year == ptmDateForCell.year && date.month == ptmDateForCell.month && date.day == ptmDateForCell.day;
                  final isToday = date.year == now.year && date.month == now.month && date.day == now.day;

                  String? holidayName;
                  for (var h in holidays) {
                    final dateVal = h['date'];
                    DateTime? hDate;
                    if (dateVal is String) {
                      hDate = DateTime.tryParse(dateVal);
                    } else if (dateVal is Timestamp) {
                      hDate = dateVal.toDate();
                    }
                    if (hDate != null && hDate.year == date.year && hDate.month == date.month && hDate.day == date.day) {
                      holidayName = h['name'] as String? ?? 'Holiday';
                      break;
                    }
                  }
                  final cellIslamicEvent = IslamicCalendarHelper.getIslamicEvent(date);
                  final isIslamicHoliday = cellIslamicEvent != null && cellIslamicEvent.isOfficialHoliday;
                  final isSpecialEvent = cellIslamicEvent != null && !cellIslamicEvent.isOfficialHoliday;
                  if (holidayName == null && (isIslamicHoliday || isSpecialEvent)) {
                    holidayName = context.isUrdu ? cellIslamicEvent!.titleUr : cellIslamicEvent!.titleEn;
                  }
                  final isHoliday = holidayName != null;

                  final isDarkCalendar = Theme.of(context).brightness == Brightness.dark || UserThemeService.isDarkMode(widget.editorName);
                  Color cardColor = isDarkCalendar ? const Color(0xFF1E293B) : Colors.white;
                  if (isSelected) {
                    cardColor = isHoliday
                        ? (cellIslamicEvent != null ? const Color(0xFFD4AF37) : const Color(0xFF2E7D32))
                        : const Color(0xFF4C4DDC);
                  } else if (isHoliday) {
                    cardColor = cellIslamicEvent != null
                        ? (isDarkCalendar ? const Color(0xFF3B2E10) : const Color(0xFFFEF3C7))
                        : (isDarkCalendar ? const Color(0xFF1B3D2F) : const Color(0xFFE8F5E9));
                  }

                  Border border;
                  if (isSelected) {
                    border = Border.all(color: cardColor, width: 1.0);
                  } else if (isToday) {
                    border = Border.all(color: const Color(0xFF008080), width: 2.0);
                  } else if (isHoliday) {
                    border = Border.all(
                      color: cellIslamicEvent != null ? const Color(0xFFD4AF37) : const Color(0xFF81C784),
                      width: 1.0,
                    );
                  } else {
                    border = Border.all(color: isDarkCalendar ? const Color(0xFF334155) : const Color(0xFFE0E2E7), width: 1.0);
                  }

                  Color dayAbbrevColor = isSelected
                      ? Colors.white70
                      : (isHoliday
                          ? (cellIslamicEvent != null
                              ? (isDarkCalendar ? const Color(0xFFFBBF24) : const Color(0xFFB45309))
                              : (isDarkCalendar ? const Color(0xFF81C784) : const Color(0xFF2E7D32)))
                          : (isDarkCalendar ? const Color(0xFF94A3B8) : Colors.grey));
                  Color dayNumColor = isSelected
                      ? Colors.white
                      : (isHoliday
                          ? (cellIslamicEvent != null
                              ? (isDarkCalendar ? const Color(0xFFFDE047) : const Color(0xFF92400E))
                              : (isDarkCalendar ? const Color(0xFFA7F3D0) : const Color(0xFF1B5E20)))
                          : (isDarkCalendar ? Colors.white : const Color(0xFF1A1C1E)));

                  return GestureDetector(
                    onTap: isSunday ? null : () {
  setState(() {
    _selectedDate = date;
    _localChanges.clear();
    _allPresentToggled = false;
    _allUniformToggled = false;
    _allRepliedToggled = false;
    _studentNotifiers.clear();
  });
  _changeNotifier.value++;
  _updateDateStreams(); // this calls _subscribeToLog() which resets _logNotifier
  WidgetsBinding.instance.addPostFrameCallback((_) {
    _scrollToSelectedDate(animate: true);
  });
},
                    child: Opacity(
                      opacity: isSunday ? 0.3 : 1.0,
                      child: Container(
                        width: 60,
                        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                        decoration: BoxDecoration(
                          color: cardColor,
                          borderRadius: BorderRadius.circular(12),
                          border: border,
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              DateFormat('E').format(date).toUpperCase(),
                              style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: dayAbbrevColor),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${date.day}',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: dayNumColor),
                            ),
                            if (isHoliday)
                              Padding(
                                padding: const EdgeInsets.only(top: 2, left: 2, right: 2),
                                child: Text(
                                  cellIslamicEvent != null ? '${cellIslamicEvent.emoji} $holidayName' : holidayName,
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 8,
                                    fontWeight: FontWeight.w900,
                                    color: isSelected
                                        ? Colors.white
                                        : (cellIslamicEvent != null
                                            ? (isDarkCalendar ? const Color(0xFFFBBF24) : const Color(0xFFB45309))
                                            : const Color(0xFF2E7D32)),
                                  ),
                                ),
                              )
                            else if (isPtm)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  'PTM',
                                  style: TextStyle(fontSize: 8, fontWeight: FontWeight.w900, color: isSelected ? Colors.white : const Color(0xFFD32F2F)),
                                ),
                              ),
                            if (isToday)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Container(
                                  width: 5,
                                  height: 5,
                                  decoration: BoxDecoration(
                                    color: isSelected ? Colors.white : (isHoliday ? const Color(0xFF2E7D32) : const Color(0xFF008080)),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        IconButton(
          icon: Icon(Icons.chevron_right, color: rightColor),
          onPressed: showRightGrey
              ? null
              : () {
                  if (_calendarScrollController.hasClients) {
                    final target = (_calendarScrollController.offset + 204.0).clamp(0.0, _calendarScrollController.position.maxScrollExtent);
                    _calendarScrollController.animateTo(
                      target,
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                    );
                  }
                },
        ),
      ],
    );
  }

  Widget _buildStatusLegend(BuildContext context, MadrassaConfig config, List<Map<String, dynamic>> students, Map<String, dynamic> logData) {
    final isDesktop = MediaQuery.of(context).size.width > 900;
    final isMobile = MediaQuery.of(context).size.width < 600;
    final isReadOnly = !_canSaveData();
    int present = 0, leave = 0, absent = 0, replied = 0;
    for (var s in students) {
      final sId = s['id'] ?? '';
      final log = _localChanges[sId] ?? _safeMap(logData[sId]);
      final att = log['attendance'] ?? 'absent';
      if (att == 'present') {
        present++;
      } else if (att == 'leave') {
        leave++;
      } else {
        absent++;
      }
      if (log['parentReplied'] == true) replied++;
    }

    final dateText = DateFormat('EEEE, MMMM d, yyyy').format(_selectedDate);
    final hijriDate = IslamicCalendarHelper.fromGregorian(_selectedDate);
    final hijriText = hijriDate.format(isUrdu: context.isUrdu);
    final fullDateHeading = '$dateText  •  🌙 $hijriText';

    final isDarkStats = Theme.of(context).brightness == Brightness.dark || UserThemeService.isDarkMode(widget.editorName);
    final dateTextColor = isDarkStats ? Colors.white : const Color(0xFF1A1C1E);

    // Date & stats section
    Widget dateAndStatsWidget;
    if (isMobile) {
      dateAndStatsWidget = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            fullDateHeading,
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: dateTextColor),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            children: [
              _statText('${context.l.present}: $present', const Color(0xFF4CAF50)),
              _statText('${context.l.leave}: $leave', const Color(0xFFF5A623)),
              _statText('${context.l.absent}: $absent', const Color(0xFFE53935)),
              _statText(context.isUrdu ? 'جوابات: $replied' : 'Replied: $replied', const Color(0xFFFFA726)),
            ],
          ),
        ],
      );
    } else {
      dateAndStatsWidget = Row(
        children: [
          Expanded(
            child: Text(
              fullDateHeading,
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: dateTextColor),
            ),
          ),
          _statText('${context.l.present}: $present', const Color(0xFF4CAF50)),
          const SizedBox(width: 12),
          _statText('${context.l.leave}: $leave', const Color(0xFFF5A623)),
          const SizedBox(width: 12),
          _statText('${context.l.absent}: $absent', const Color(0xFFE53935)),
          const SizedBox(width: 12),
          _statText(context.isUrdu ? 'جوابات: $replied' : 'Replied: $replied', const Color(0xFFFFA726)),
        ],
      );
    }

    // Actions & Legends section
    Widget actionsAndLegendsWidget;
    if (isDesktop) {
      actionsAndLegendsWidget = Row(
        children: [
          _efficiencyButton(
            label: context.l.allPresent,
            icon: Icons.done_all,
            color: const Color(0xFF4CAF50),
            isSelected: _allPresentToggled,
            onTap: isReadOnly ? null : () {
              setState(() {
                _allPresentToggled = !_allPresentToggled;
                for (var s in students) {
                  final sId = s['id'] ?? '';
                  final log = _safeMap(logData[sId]);
                  final currentAtt = _localChanges[sId]?['attendance'] ?? log['attendance'];
                  if (currentAtt != 'leave') {
                    _updateAttendanceSilent(sId, _allPresentToggled ? 'present' : 'absent');
                  }
                }
              });
            },
          ),
          const SizedBox(width: 8),
          _efficiencyButton(
            label: context.l.allUniform,
            icon: Icons.check_circle_outline,
            color: const Color(0xFF5B9BD5),
            isSelected: _allUniformToggled,
            onTap: isReadOnly ? null : () {
              setState(() {
                _allUniformToggled = !_allUniformToggled;
                for (var s in students) {
                  final sId = s['id'] ?? '';
                  final log = _safeMap(logData[sId]);
                  final currentAtt = _localChanges[sId]?['attendance'] ?? log['attendance'];
                  if (currentAtt == 'present') {
                    _updateLocalSilent(sId, 'uniform', _allUniformToggled);
                  }
                }
              });
            },
          ),
          const SizedBox(width: 8),
          _efficiencyButton(
            label: context.isUrdu ? 'سب نے جواب دیا' : 'All Replied',
            icon: Icons.message_outlined,
            color: const Color(0xFFFFA726),
            isSelected: _allRepliedToggled,
            onTap: isReadOnly ? null : () {
              setState(() {
                _allRepliedToggled = !_allRepliedToggled;
                for (var s in students) {
                  final sId = s['id'] ?? '';
                  _updateLocalSilent(sId, 'parentReplied', _allRepliedToggled);
                }
              });
            },
          ),
          const SizedBox(width: 16),
          ElevatedButton.icon(
            onPressed: _localChanges.isEmpty || _isSaving || isReadOnly ? null : _saveChanges,
            icon: _isSaving
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 1.5),
                  )
                : const Icon(Icons.save, size: 16),
            label: Text(context.l.saveChanges, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF008080), // Teal
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: () => _showDailyReportDialog(config, students, logData),
            icon: const FaIcon(FontAwesomeIcons.whatsapp, color: Color(0xFF25D366), size: 16),
            label: Text(
              context.isUrdu ? 'روزانہ گروپ رپورٹ' : 'Daily Group Report',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF008080)),
            ),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Color(0xFF008080)),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
      );
    } else {
      actionsAndLegendsWidget = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _efficiencyButton(
                label: context.l.allPresent,
                icon: Icons.done_all,
                color: const Color(0xFF4CAF50),
                isSelected: _allPresentToggled,
                onTap: isReadOnly ? null : () {
                  setState(() {
                    _allPresentToggled = !_allPresentToggled;
                    for (var s in students) {
                      final sId = s['id'] ?? '';
                      final log = _safeMap(logData[sId]);
                      final currentAtt = _localChanges[sId]?['attendance'] ?? log['attendance'];
                      if (currentAtt != 'leave') {
                        _updateAttendanceSilent(sId, _allPresentToggled ? 'present' : 'absent');
                      }
                    }
                  });
                },
              ),
              _efficiencyButton(
                label: context.l.allUniform,
                icon: Icons.check_circle_outline,
                color: const Color(0xFF5B9BD5),
                isSelected: _allUniformToggled,
                onTap: isReadOnly ? null : () {
                  setState(() {
                    _allUniformToggled = !_allUniformToggled;
                    for (var s in students) {
                      final sId = s['id'] ?? '';
                      final log = _safeMap(logData[sId]);
                      final currentAtt = _localChanges[sId]?['attendance'] ?? log['attendance'];
                      if (currentAtt == 'present') {
                        _updateLocalSilent(sId, 'uniform', _allUniformToggled);
                      }
                    }
                  });
                },
              ),
              _efficiencyButton(
                label: context.isUrdu ? 'سب نے جواب دیا' : 'All Replied',
                icon: Icons.message_outlined,
                color: const Color(0xFFFFA726),
                isSelected: _allRepliedToggled,
                onTap: isReadOnly ? null : () {
                  setState(() {
                    _allRepliedToggled = !_allRepliedToggled;
                    for (var s in students) {
                      final sId = s['id'] ?? '';
                      _updateLocalSilent(sId, 'parentReplied', _allRepliedToggled);
                    }
                  });
                },
              ),
              _efficiencyButton(
                label: context.isUrdu ? 'روزانہ گروپ رپورٹ' : 'Daily Group Report',
                icon: Icons.share_outlined,
                color: const Color(0xFF008080),
                isSelected: false,
                onTap: () => _showDailyReportDialog(config, students, logData),
              ),
            ],
          ),
        ],
      );
    }

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: 0,
        vertical: isMobile ? 12 : 24,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          dateAndStatsWidget,
          SizedBox(height: isMobile ? 12 : 16),
          actionsAndLegendsWidget,
        ],
      ),
    );
  }

  Widget _efficiencyButton({
    required String label,
    required IconData icon,
    required Color color,
    required bool isSelected,
    required VoidCallback? onTap,
  }) {
    final isDisabled = onTap == null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isDisabled 
              ? Colors.grey.shade200 
              : (isSelected ? color : color.withValues(alpha: 0.05)),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isDisabled 
                ? Colors.grey.shade300 
                : (isSelected ? color : color.withValues(alpha: 0.2)),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: isDisabled ? Colors.grey : (isSelected ? Colors.white : color)),
            const SizedBox(width: 8),
            Text(
              label,
              style: context.urduStyle(
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: isDisabled ? Colors.grey : (isSelected ? Colors.white : color),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statText(String label, Color color) {
    return Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 14));
  }



  Widget _buildParaDropdown(BuildContext context, int? selectedValue, bool isEnabled, ValueChanged<int?>? onChanged) {
    final isDark = Theme.of(context).brightness == Brightness.dark || UserThemeService.isDarkMode(widget.editorName);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      height: 36,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F172A) : Colors.white,
        border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE0E2E7)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: (selectedValue == null || selectedValue == 0) ? null : selectedValue,
          hint: Text('-', style: TextStyle(color: isDark ? const Color(0xFF64748B) : Colors.grey.shade400, fontSize: 12)),
          icon: const Icon(Icons.arrow_drop_down, size: 16, color: Color(0xFF008080)),
          isDense: true,
          isExpanded: true,
          dropdownColor: isDark ? const Color(0xFF1E293B) : Colors.white,
          style: TextStyle(fontSize: 12, color: isDark ? Colors.white : Colors.black, fontWeight: FontWeight.bold),
          items: [
            for (int i = 1; i <= 30; i++)
              DropdownMenuItem(
                value: i,
                child: Text('$i', style: TextStyle(fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black)),
              ),
          ],
          onChanged: isEnabled ? onChanged : null,
        ),
      ),
    );
  }

  Widget _buildRatioDropdown(BuildContext context, String? selectedValue, bool isEnabled, ValueChanged<String?>? onChanged) {
    final isDark = Theme.of(context).brightness == Brightness.dark || UserThemeService.isDarkMode(widget.editorName);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      height: 36,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F172A) : Colors.white,
        border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE0E2E7)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: (selectedValue == null || selectedValue.isEmpty || selectedValue == '-') ? null : selectedValue,
          hint: Text('-', style: TextStyle(color: isDark ? const Color(0xFF64748B) : Colors.grey.shade400, fontSize: 12)),
          icon: const Icon(Icons.arrow_drop_down, size: 16, color: Color(0xFF008080)),
          isDense: true,
          isExpanded: true,
          dropdownColor: isDark ? const Color(0xFF1E293B) : Colors.white,
          style: TextStyle(fontSize: 12, color: isDark ? Colors.white : Colors.black, fontWeight: FontWeight.bold),
          items: [
            DropdownMenuItem(value: '1/4', child: Text(context.isUrdu ? 'پاؤ' : 'Pao', style: TextStyle(color: isDark ? Colors.white : Colors.black))),
            DropdownMenuItem(value: '1/2', child: Text(context.isUrdu ? 'نصف' : 'Nisf', style: TextStyle(color: isDark ? Colors.white : Colors.black))),
            DropdownMenuItem(value: '3/4', child: Text(context.isUrdu ? 'ثلاثہ' : 'Salasa', style: TextStyle(color: isDark ? Colors.white : Colors.black))),
            DropdownMenuItem(value: '1', child: Text(context.isUrdu ? 'پارہ' : 'Para', style: TextStyle(color: isDark ? Colors.white : Colors.black))),
            DropdownMenuItem(value: 'nahi_sunaya', child: Text(context.isUrdu ? 'نہیں سنایا' : 'Nahi Sunaya', style: TextStyle(color: isDark ? Colors.white : Colors.black))),
          ],
          onChanged: isEnabled ? onChanged : null,
        ),
      ),
    );
  }



  Future<void> _pickAndUploadPhoto(String studentId) async {
    final ImageSource? source = await showModalBottomSheet<ImageSource>(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                context.isUrdu ? 'طالب علم کی تصویر منتخب کریں' : 'Update Student Photo',
                style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined, color: Color(0xFF008080)),
              title: Text(
                context.isUrdu ? 'کیمرہ سے تصویر لیں' : 'Take Photo with Camera',
                style: context.urduStyle(),
              ),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined, color: Color(0xFF008080)),
              title: Text(
                context.isUrdu ? 'گیلری سے منتخب کریں' : 'Choose from Gallery',
                style: context.urduStyle(),
              ),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (source == null) return;

    try {
      if (!mounted) return;
      setState(() => _uploadStates[studentId] = PhotoUploadStatus.uploading);

      final b64 = await ImageUploadService.pickAndProcessImage(source: source);
      if (b64 == null || b64.isEmpty) {
        if (mounted) setState(() => _uploadStates[studentId] = PhotoUploadStatus.idle);
        return;
      }

      final studentCache = MadrassaLocalStorage.getStudentCached(widget.branchId, studentId) ?? <String, dynamic>{'id': studentId};
      studentCache['photoUrl'] = b64;
      studentCache['photoBase64'] = b64;
      studentCache['studentPhotoBase64'] = b64;
      await MadrassaLocalStorage.cacheStudent(widget.branchId, studentId, studentCache);

      // Broadcast via LAN
      try {
        RealtimeManager().sendMessage(RealtimeEvents.payload(
          type: RealtimeEvents.saveMadrassaStudent,
          data: studentCache,
          branchId: widget.branchId,
        ));
      } catch (_) {}

      // Always enqueue sync
      await LocalStorageService.enqueueSync({
        'type': 'save_madrassa_student',
        'branchId': widget.branchId,
        'studentId': studentId,
        'data': studentCache,
      });
      unawaited(SyncService().triggerUpload());

      if (mounted) {
        setState(() {
          _uploadStates[studentId] = PhotoUploadStatus.success;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.isUrdu ? 'تصویر کامیابی کے ساتھ اپ ڈیٹ ہو گئی' : 'Student photo updated successfully!',
              style: context.urduStyle(),
            ),
            backgroundColor: const Color(0xFF008080),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _uploadStates[studentId] = PhotoUploadStatus.error);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update photo: $e'), backgroundColor: Colors.red),
      );
    }
  }

  void _showCustomLinesDialog(BuildContext context, String studentId, int currentLines) {
    final textCtrl = TextEditingController(text: currentLines.toString());
    // Auto-select text so user can just type a number to replace it immediately.
    textCtrl.selection = TextSelection(baseOffset: 0, extentOffset: textCtrl.text.length);

    showDialog(
      context: context,
      builder: (dContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            context.isUrdu ? 'سبق کی لائنیں درج کریں' : 'Enter Custom Sabak Lines',
            style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          content: TextField(
            controller: textCtrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              hintText: 'e.g. 15',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFF008080), width: 2),
              ),
            ),
            onSubmitted: (val) {
              final newLines = int.tryParse(val.trim());
              if (newLines != null && newLines >= 0) {
                final clamped = newLines.clamp(0, 8640);
                if (newLines > 8640) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(context.isUrdu ? 'زیادہ سے زیادہ 8640 لائنیں (حفظ مکمل)' : 'Maximum 8640 lines (Hifz complete)'), backgroundColor: Colors.orange),
                  );
                }
                _updateSabakLines(studentId, clamped);
                Navigator.of(dContext).pop();
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dContext).pop(),
              child: Text(
                context.l.cancel,
                style: context.urduStyle(style: const TextStyle(color: Colors.grey)),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF008080),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () {
                final newLines = int.tryParse(textCtrl.text.trim());
                if (newLines != null && newLines >= 0) {
                  final clamped = newLines.clamp(0, 8640);
                  if (newLines > 8640) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(context.isUrdu ? 'زیادہ سے زیادہ 8640 لائنیں (حفظ مکمل)' : 'Maximum 8640 lines (Hifz complete)'), backgroundColor: Colors.orange),
                    );
                  }
                  _updateSabakLines(studentId, clamped);
                  Navigator.of(dContext).pop();
                }
              },
              child: Text(
                context.l.save,
                style: context.urduStyle(),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _sendDailyWhatsApp(Map<String, dynamic> s, Map<String, dynamic> log) async {
    final studentData = s;
    final sId = s['id'] ?? '';

    // Get parent phone
    final String rawPhone = studentData['contactPhone']?.toString() ?? studentData['phone']?.toString() ?? '';
    if (rawPhone.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Error: Parent contact phone number not provided.')),
      );
      return;
    }

    // Clean phone number
    String phone = rawPhone.replaceAll(RegExp(r'[^0-9+]'), '');
    if (phone.startsWith('0')) {
      phone = '92${phone.substring(1)}';
    }
    phone = phone.replaceAll('+', '');
    if (!phone.startsWith('92') && phone.length == 10) {
      phone = '92$phone';
    }

    // Load actual log data combining local changes and DB log
    final currentLog = _localChanges[sId] ?? log;
    final att = currentLog['attendance']?.toString() ?? 'absent';
    final uni = currentLog['uniform'] == true;
    
    final int lines = currentLog['currentLines'] is int ? currentLog['currentLines'] as int : (int.tryParse(currentLog['currentLines']?.toString() ?? '') ?? 0);
    final int sabkiParaVal = currentLog['sabkiPara'] is int ? currentLog['sabkiPara'] as int : (int.tryParse(currentLog['sabkiPara']?.toString() ?? '') ?? 0);
    final String? sabkiRatioVal = currentLog['sabkiRatio']?.toString();
    final int manzilParaVal = currentLog['manzilPara'] is int ? currentLog['manzilPara'] as int : (int.tryParse(currentLog['manzilPara']?.toString() ?? '') ?? 0);
    final String? manzilRatioVal = currentLog['manzilRatio']?.toString();

    String formatRatio(String? ratio) {
      if (ratio == '1/4') return '1/4';
      if (ratio == '1/2') return '1/2';
      if (ratio == '3/4') return '3/4';
      if (ratio == '1') return '1';
      if (ratio == 'nahi_sunaya') return ' نہیں سنایا';
      return ratio ?? '-';
    }

    // Attendance label formatting
    String attTextEn = 'Absent';
    String attTextUr = 'غیر حاضر';
    if (att == 'present') {
      attTextEn = 'Present';
      attTextUr = 'حاضر';
    } else if (att == 'leave') {
      attTextEn = 'On Leave';
      attTextUr = 'رخصت';
    }

    final dateStr = DateFormat('dd-MM-yyyy').format(_selectedDate);
    final studentName = studentData['name'] ?? '—';
    final rollNumber = studentData['rollNumber'] ?? '?';

    // Format Sabak/Sabki/Manzil strings for message
    String sabakMsg = 'Lines: $lines';
    
    String sabkiMsg = 'No test today';
    if (sabkiParaVal > 0 && sabkiRatioVal != null && sabkiRatioVal.isNotEmpty && sabkiRatioVal != '-') {
      sabkiMsg = 'Para $sabkiParaVal (${formatRatio(sabkiRatioVal)})';
    } else if (sabkiRatioVal == 'nahi_sunaya') {
      sabkiMsg = 'نہیں سنایا';
    }

    String manzilMsg = 'No test today';
    if (manzilParaVal > 0 && manzilRatioVal != null && manzilRatioVal.isNotEmpty && manzilRatioVal != '-') {
      manzilMsg = 'Para $manzilParaVal (${formatRatio(manzilRatioVal)})';
    } else if (manzilRatioVal == 'nahi_sunaya') {
      manzilMsg = 'نہیں سنایا';
    }

    final String uniformMsg = uni ? 'Clean / صاف' : 'Incomplete / Not Clean / نامکمل یا صاف نہیں';

    final String message = 
        '*Gulzar Madina Welfare Foundation (Madrassa)*\n'
        '*Daily Progress Report | روزانہ کارکردگی رپورٹ*\n'
        '--------------------------------------------\n'
        '*Date / تاریخ:* $dateStr\n'
        '*Student / طالب علم:*          $studentName (Roll: $rollNumber)\n'
        '*Attendance / حاضری:*     $attTextEn / $attTextUr\n'
        '${att == 'present' ? '*Uniform / لباس:*               $uniformMsg\n' : ''}'
        '\n'
        '${att == 'present' ? '*Daily Progress / روزانہ کارکردگی:*\n'
        '• *Sabak:* $sabakMsg\n'
        '• *Sabki:* $sabkiMsg\n'
        '• *Manzil:* $manzilMsg\n' : ''}'
        '--------------------------------------------\n'
        'JazakAllah Khair! / جزاک اللہ خیر!';

    final waUri = Uri.parse('https://wa.me/$phone?text=${Uri.encodeComponent(message)}');

    try {
      final success = await launchUrl(waUri, mode: LaunchMode.externalApplication);
      if (!success) {
        throw 'Could not launch URL';
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not launch WhatsApp.')),
        );
      }
    }
  }

  String _generateDailyReportText(List<Map<String, dynamic>> students, Map<String, dynamic> logData) {
    int total = students.length;
    int present = 0;
    int leave = 0;
    int absent = 0;

    final List<String> studentLines = [];

    String formatRatio(String? ratio) {
      if (ratio == '1/4') return '1/4';
      if (ratio == '1/2') return '1/2';
      if (ratio == '3/4') return '3/4';
      if (ratio == '1') return '1';
      if (ratio == 'nahi_sunaya') return 'نہیں سنایا';
      return ratio ?? '-';
    }

    for (int i = 0; i < students.length; i++) {
      final s = students[i];
      final sId = s['id'] ?? '';
      final log = _localChanges[sId] ?? _safeMap(logData[sId]);
      final att = log['attendance'] ?? 'absent';
      final uni = log['uniform'] == true;
      final name = s['name'] ?? '—';
      final roll = s['rollNumber'] ?? '?';

      String attText = 'Absent / غیر حاضر';
      if (att == 'present') {
        present++;
        attText = 'Present / حاضر';
      } else if (att == 'leave') {
        leave++;
        attText = 'On Leave / رخصت';
      } else {
        absent++;
      }

      var details = '';
      if (att == 'present') {
        final int lines = (log.containsKey('sabakLines') && log['sabakLines'] != null)
            ? ((log['sabakLines'] as num?)?.toInt() ?? 0)
            : ((log.containsKey('currentLines') && log['currentLines'] != null)
                ? ((log['currentLines'] as num?)?.toInt() ?? 0)
                : 0);
        final int sabkiParaVal = log['sabkiPara'] is int ? log['sabkiPara'] as int : (int.tryParse(log['sabkiPara']?.toString() ?? '') ?? 0);
        final String? sabkiRatioVal = log['sabkiRatio']?.toString();
        final int manzilParaVal = log['manzilPara'] is int ? log['manzilPara'] as int : (int.tryParse(log['manzilPara']?.toString() ?? '') ?? 0);
        final String? manzilRatioVal = log['manzilRatio']?.toString();

        final String uniformMsg = uni ? 'Clean / صاف' : 'Not Clean / صاف نہیں';
        
        List<String> progressParts = [];
        if (lines > 0) {
          progressParts.add('Sabak: $lines lines');
        }
        if (sabkiParaVal > 0 && sabkiRatioVal != null && sabkiRatioVal.isNotEmpty && sabkiRatioVal != '-') {
          progressParts.add('Sabki: Para $sabkiParaVal (${formatRatio(sabkiRatioVal)})');
        } else if (sabkiRatioVal == 'nahi_sunaya') {
          progressParts.add('Sabki: نہیں سنایا');
        }
        if (manzilParaVal > 0 && manzilRatioVal != null && manzilRatioVal.isNotEmpty && manzilRatioVal != '-') {
          progressParts.add('Manzil: Para $manzilParaVal (${formatRatio(manzilRatioVal)})');
        } else if (manzilRatioVal == 'nahi_sunaya') {
          progressParts.add('Manzil: نہیں سنایا');
        }

        final progressStr = progressParts.isNotEmpty ? ' | ' + progressParts.join(' | ') : '';
        details = '\n   • Uniform: $uniformMsg$progressStr';
      }

      final parentReplied = log['parentReplied'] == true;
      final replyText = parentReplied ? (context.isUrdu ? 'جواب: ہاں' : 'Reply: Yes') : (context.isUrdu ? 'جواب: نہیں' : 'Reply: No');

      studentLines.add('${i + 1}. *$name* (Roll: $roll) - $attText | $replyText$details');
    }

    final dateStr = DateFormat('dd-MM-yyyy').format(_selectedDate);

    final String message = 
        '*Gulzar Madina Welfare Foundation (Madrassa)*\n'
        '*Daily Progress Report | روزانہ کارکردگی رپورٹ*\n'
        '--------------------------------------------\n'
        '*Date / تاریخ:* $dateStr\n'
        '*Total Students / کل طلباء:* $total\n'
        '*Present / حاضر:* $present  |  *Leave / رخصت:* $leave  |  *Absent / غیر حاضر:* $absent\n'
        '--------------------------------------------\n'
        '${studentLines.join("\n")}\n'
        '--------------------------------------------\n'
        'JazakAllah Khair! / جزاک اللہ خیر!';

    return message;
  }

  void _showDailyReportDialog(MadrassaConfig config, List<Map<String, dynamic>> students, Map<String, dynamic> logData) {
    final reportText = _generateDailyReportText(students, logData);

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: [
              const Icon(Icons.share, color: Color(0xFF008080)),
              const SizedBox(width: 10),
              Text(
                context.isUrdu ? 'روزانہ رپورٹ شیئر کریں' : 'Share Daily Report',
                style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              ),
            ],
          ),
          content: SizedBox(
            width: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  context.isUrdu 
                      ? 'رپورٹ کا ٹیکسٹ نیچے پیش نظارہ میں دیکھیں۔ آپ اسے کاپی کر سکتے ہیں یا واٹس ایپ پر براہ راست بھیج سکتے ہیں، یا پی ڈی ایف ڈاؤن لوڈ کر سکتے ہیں۔'
                      : 'Preview the report text below. You can copy it, send it directly to WhatsApp, or download/share the PDF.',
                  style: context.urduStyle(style: const TextStyle(fontSize: 13, color: Colors.grey)),
                ),
                const SizedBox(height: 12),
                Container(
                  height: 200,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      reportText,
                      style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actionsAlignment: MainAxisAlignment.spaceBetween,
          actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          actions: [
            OutlinedButton.icon(
              onPressed: () async {
                Navigator.of(ctx).pop();
                final Map<String, dynamic> compiledLogData = {};
                for (final s in students) {
                  final sId = s['id'] ?? '';
                  compiledLogData[sId] = _localChanges[sId] ?? _safeMap(logData[sId]);
                }
                try {
                  await MadrassaReportHelper.exportDailyPdf(
                    config: config,
                    selectedDate: _selectedDate,
                    students: students,
                    logData: compiledLogData,
                  );
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Error generating PDF: $e')),
                    );
                  }
                }
              },
              icon: const Icon(Icons.picture_as_pdf, color: Colors.red),
              label: Text(
                context.isUrdu ? 'پی ڈی ایف رپورٹ' : 'PDF Report',
                style: context.urduStyle(style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.red),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: context.isUrdu ? 'ٹیکسٹ کاپی کریں' : 'Copy Text',
                  icon: const Icon(Icons.copy, color: Color(0xFF008080)),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: reportText));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(context.isUrdu ? 'ٹیکسٹ کاپی ہو گیا!' : 'Copied to clipboard!')),
                    );
                  },
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () async {
                    Navigator.of(ctx).pop();
                    final waUri = Uri.parse('https://api.whatsapp.com/send?text=${Uri.encodeComponent(reportText)}');
                    try {
                      final success = await launchUrl(waUri, mode: LaunchMode.externalApplication);
                      if (!success) {
                        throw 'Could not launch URL';
                      }
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Could not launch WhatsApp.')),
                        );
                      }
                    }
                  },
                  icon: const FaIcon(FontAwesomeIcons.whatsapp, color: Colors.white, size: 16),
                  label: Text(
                    context.isUrdu ? 'واٹس ایپ پر بھیجیں' : 'Send WhatsApp',
                    style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF25D366),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }



  Widget? _buildFabArea(bool isDesktop) {
    final showSave = _localChanges.isNotEmpty && !isDesktop;
    final showTop = _showBackToTop;

    if (!showSave && !showTop) return null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showTop) ...[
            FloatingActionButton(
              heroTag: 'btn_back_to_top',
              mini: true,
              backgroundColor: const Color(0xFF008080).withValues(alpha: 0.8),
              foregroundColor: Colors.white,
              onPressed: () {
                _verticalScrollController.animateTo(
                  0,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                );
              },
              child: const Icon(Icons.arrow_upward),
            ),
            const SizedBox(width: 12),
          ],
          if (showSave)
            ElevatedButton.icon(
              onPressed: _isSaving || !_canSaveData() ? null : _saveChanges,
              icon: _isSaving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                    )
                  : const Icon(Icons.save),
              label: Text(context.l.saveChanges),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF008080), // Teal
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
        ],
      ),
    );
  }
}


class SegmentedAttendanceToggle extends StatelessWidget {
  final String value; // 'present', 'leave', 'absent'
  final ValueChanged<String>? onChanged;
  final bool showLabel;
  final bool allowStudentLeave;
  final bool isGlobalUser;

  const SegmentedAttendanceToggle({
    super.key,
    required this.value,
    this.onChanged,
    this.showLabel = true,
    this.allowStudentLeave = false,
    this.isGlobalUser = false,
  });

  @override
  Widget build(BuildContext context) {
    final bool canUseLeave = allowStudentLeave;
    final bool showLeaveSegment = allowStudentLeave || value == 'leave' || value == 'leave_requested';

    Widget toggle = Container(
      height: 36,
      decoration: BoxDecoration(
        color: const Color(0xFFEDF0F5),
        borderRadius: BorderRadius.circular(18),
      ),
      padding: const EdgeInsets.all(3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildSegment(
            context: context,
            label: 'P',
            isSelected: value == 'present',
            activeColor: const Color(0xFF10B981), // Emerald green
            onTap: onChanged == null ? null : () => onChanged!('present'),
          ),
          if (showLeaveSegment) ...[
            const SizedBox(width: 4),
            _buildSegment(
              context: context,
              label: 'L',
              isSelected: value == 'leave' || value == 'leave_requested',
              activeColor: const Color(0xFFF59E0B), // Orange/yellow
              onTap: (onChanged == null || !canUseLeave) ? null : () => onChanged!('leave'),
            ),
          ],
          const SizedBox(width: 4),
          _buildSegment(
            context: context,
            label: 'A',
            isSelected: value == 'absent',
            activeColor: const Color(0xFFEF4444), // Red
            onTap: onChanged == null ? null : () => onChanged!('absent'),
          ),
        ],
      ),
    );

    if (showLabel) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            context.l.attendance,
            style: context.urduStyle(
              style: const TextStyle(
                fontSize: 10,
                color: Color(0xFF78909C),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 2),
          toggle,
        ],
      );
    }
    return toggle;
  }

  Widget _buildSegment({
    required BuildContext context,
    required String label,
    required bool isSelected,
    required Color activeColor,
    required VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        width: 32,
        height: 30,
        decoration: BoxDecoration(
          color: isSelected ? activeColor : Colors.transparent,
          borderRadius: BorderRadius.circular(15),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : const Color(0xFF64748B),
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

class _StudentLogCard extends StatelessWidget {
  final Map<String, dynamic> student;
  final ValueNotifier<Map<String, dynamic>> logNotifier;
  final bool isPtmDay;
  final bool isReadOnly;
  final String branchId;
  final bool allowStudentLeave;
  final String editorRole;
  final PhotoUploadStatus? uploadStatus;
  final Function(String sId, String key, dynamic value) onUpdateLocal;
  final Function(String sId, int newSabak)? onUpdateSabak;
  final Function(String sId) onPickPhoto;
  final Function(Map<String, dynamic> s, Map<String, dynamic> log) onSendWhatsApp;
  final Function(BuildContext context, String sId, int currentLines) onShowCustomLines;
  final Widget Function(BuildContext context, int? selectedValue, bool isEnabled, ValueChanged<int?>? onChanged) buildParaDropdown;
  final Widget Function(BuildContext context, String? selectedValue, bool isEnabled, ValueChanged<String?>? onChanged) buildRatioDropdown;

  const _StudentLogCard({
    super.key,
    required this.student,
    required this.logNotifier,
    required this.isPtmDay,
    required this.isReadOnly,
    required this.branchId,
    this.allowStudentLeave = false,
    this.editorRole = 'Madrassa Teacher',
    this.uploadStatus,
    required this.onUpdateLocal,
    this.onUpdateSabak,
    required this.onPickPhoto,
    required this.onSendWhatsApp,
    required this.onShowCustomLines,
    required this.buildParaDropdown,
    required this.buildRatioDropdown,
  });

  Widget _actionButton(String label, Color color, VoidCallback onTap) {
    return ElevatedButton(
      onPressed: onTap,
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
    );
  }

  Widget _attButton(String label, bool active, Color color, VoidCallback onTap, {bool isDark = false}) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: active ? color : (isDark ? const Color(0xFF334155) : const Color(0xFFE8EAED)),
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: active ? Colors.white : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF9E9E9E)),
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  Widget _switchCol(BuildContext context, String label, bool val, ValueChanged<bool>? onChanged, {Color? activeColor, Color? trackColor, bool isDark = false}) {
    return Column(
      children: [
        Text(
          label,
          style: context.urduStyle(style: TextStyle(fontSize: 10, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78909C), fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 2),
        Switch(
          value: val,
          onChanged: onChanged,
          activeColor: activeColor ?? const Color(0xFF5B9BD5),
          activeTrackColor: trackColor ?? (activeColor ?? const Color(0xFF5B9BD5)).withValues(alpha: 0.4),
          inactiveThumbColor: isDark ? const Color(0xFF64748B) : const Color(0xFFBDBDBD),
          inactiveTrackColor: isDark ? const Color(0xFF334155) : const Color(0xFFE0E0E0),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ],
    );
  }

  Widget _buildSabakField(BuildContext context, String sId, int lines, {bool isDark = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.isUrdu ? 'سبق (لائنیں)' : 'Sabak (Lines)',
          style: context.urduStyle(style: TextStyle(fontSize: 11, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF495057), fontWeight: FontWeight.bold)),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.remove_circle_outline, color: Color(0xFFE53935), size: 20),
              onPressed: (isReadOnly || lines == 0)
                  ? null
                  : () {
                      if (onUpdateSabak != null) {
                        onUpdateSabak!(sId, lines - 1);
                      } else {
                        onUpdateLocal(sId, 'currentLines', lines - 1);
                      }
                    },
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: GestureDetector(
                onTap: isReadOnly ? null : () => onShowCustomLines(context, sId, lines),
                child: Container(
                  height: 36,
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF0F172A) : Colors.white,
                    border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE0E2E7)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '$lines',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: Icon(Icons.add_circle_outline, color: (isReadOnly || lines >= 8640) ? Colors.grey : const Color(0xFF2E7D32), size: 20),
              onPressed: (isReadOnly || lines >= 8640)
                  ? null
                  : () {
                      if (onUpdateSabak != null) {
                        onUpdateSabak!(sId, (lines + 1).clamp(0, 8640));
                      } else {
                        onUpdateLocal(sId, 'currentLines', (lines + 1).clamp(0, 8640));
                      }
                    },
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSabkiField(BuildContext context, int sabkiPara, String? sabkiRatio, {bool isDark = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.isUrdu ? 'سبکی (پارہ / تناسب)' : 'Sabki (Para / Ratio)',
          style: context.urduStyle(style: TextStyle(fontSize: 11, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF495057), fontWeight: FontWeight.bold)),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              flex: 5,
               child: buildParaDropdown(context, sabkiPara, !isReadOnly, isReadOnly ? null : (val) {
                onUpdateLocal(student['id'] ?? '', 'sabkiPara', val ?? 0);
              }),
            ),
            const SizedBox(width: 6),
            Expanded(
              flex: 6,
              child: buildRatioDropdown(context, sabkiRatio, !isReadOnly, isReadOnly ? null : (val) {
                onUpdateLocal(student['id'] ?? '', 'sabkiRatio', val ?? '-');
              }),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildManzilField(BuildContext context, int manzilPara, String? manzilRatio, {bool isDark = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.isUrdu ? 'منزل (پارہ / تناسب)' : 'Manzil (Para / Ratio)',
          style: context.urduStyle(style: TextStyle(fontSize: 11, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF495057), fontWeight: FontWeight.bold)),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              flex: 5,
              child: buildParaDropdown(context, manzilPara, !isReadOnly, isReadOnly ? null : (val) {
                onUpdateLocal(student['id'] ?? '', 'manzilPara', val ?? 0);
              }),
            ),
            const SizedBox(width: 6),
            Expanded(
              flex: 6,
              child: buildRatioDropdown(context, manzilRatio, !isReadOnly, isReadOnly ? null : (val) {
                onUpdateLocal(student['id'] ?? '', 'manzilRatio', val ?? '-');
              }),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildLogAvatarFallback(String name) {
    return Container(
      width: 32,
      height: 32,
      decoration: const BoxDecoration(
        color: Color(0xFFE0F2F1),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        name.isNotEmpty ? name[0].toUpperCase() : '?',
        style: const TextStyle(color: Color(0xFF008080), fontWeight: FontWeight.bold, fontSize: 13),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;

    return ValueListenableBuilder<Map<String, dynamic>>(
      valueListenable: logNotifier,
      builder: (context, log, child) {
        final theme = Theme.of(context);
        final isDark = theme.brightness == Brightness.dark || UserThemeService.isDarkMode(editorRole);
        final cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;
        final borderColor = isDark ? const Color(0xFF334155) : const Color(0xFFE0E2E7);
        final textPrimary = isDark ? Colors.white : const Color(0xFF1A1C1E);
        final textMuted = isDark ? const Color(0xFF94A3B8) : Colors.grey;

        final studentData = student;
        final sId = student['id'] ?? '';

        final name = studentData['name'] ?? '—';
        final rollNumber = studentData['rollNumber']?.toString() ?? '?';
        final photoUrl = studentData['photoUrl'] ?? studentData['photo_url'];

        final att = log['attendance'] ?? 'absent';
        final uni = log['uniform'] ?? false;
        final msg = log['parentReplied'] ?? false;
        final leaveStatus = log['leaveStatus'] ?? 'pending';
        final isParentRequested = log['isParentRequested'] == true ||
            att == 'leave_requested' ||
            (leaveStatus == 'pending' && log['leaveReason'] != null && log['leaveReason'].toString().isNotEmpty);
        final parentRepliedRequested = log['parentRepliedRequested'] == true;
        final String? parentMsgText = log['parentReplyText']?.toString() ?? log['parentReplyMessage']?.toString();
        final bool hasPendingReply = parentRepliedRequested ||
            (msg != true && (parentMsgText != null && parentMsgText.trim().isNotEmpty));

        final int lines = (log.containsKey('sabakLines') && log['sabakLines'] != null)
            ? ((log['sabakLines'] as num?)?.toInt() ?? 0)
            : ((log.containsKey('currentLines') && log['currentLines'] != null)
                ? ((log['currentLines'] as num?)?.toInt() ?? 0)
                : 0);
        final int sabkiPara = log['sabkiPara'] is int ? log['sabkiPara'] as int : (int.tryParse(log['sabkiPara']?.toString() ?? '') ?? 0);
        final String? sabkiRatio = log['sabkiRatio']?.toString();
        final int manzilPara = log['manzilPara'] is int ? log['manzilPara'] as int : (int.tryParse(log['manzilPara']?.toString() ?? '') ?? 0);
        final String? manzilRatio = log['manzilRatio']?.toString();

        Widget avatarWidget;
        if (uploadStatus == PhotoUploadStatus.uploading) {
          avatarWidget = const SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF008080)),
          );
        } else {
          final str = photoUrl?.toString().trim();
          final bytes = ImageUploadService.decodeBase64ToBytes(str);
          if (bytes != null) {
            avatarWidget = ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.memory(
                bytes,
                width: 32,
                height: 32,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _buildLogAvatarFallback(name),
              ),
            );
          } else if (str != null && str.startsWith('http')) {
            avatarWidget = ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.network(
                str,
                width: 32,
                height: 32,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _buildLogAvatarFallback(name),
              ),
            );
          } else {
            avatarWidget = _buildLogAvatarFallback(name);
          }
        }

        avatarWidget = GestureDetector(
          onTap: () {
            if (photoUrl != null && photoUrl.toString().trim().isNotEmpty) {
              final str = photoUrl.toString().trim();
              final bytes = ImageUploadService.decodeBase64ToBytes(str);
              showDialog(
                context: context,
                builder: (context) => Dialog(
                  backgroundColor: Colors.transparent,
                  insetPadding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Align(
                        alignment: Alignment.topRight,
                        child: IconButton(
                          icon: const Icon(Icons.close, color: Colors.white, size: 28),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: InteractiveViewer(
                          maxScale: 4.0,
                          child: bytes != null
                              ? Image.memory(bytes, fit: BoxFit.contain, width: 300, height: 300)
                              : Image.network(str, fit: BoxFit.contain, width: 300, height: 300),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                          backgroundColor: Colors.black.withValues(alpha: 0.5),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        ),
                        onPressed: () {
                          Navigator.of(context).pop();
                          onPickPhoto(sId);
                        },
                        icon: const Icon(Icons.edit, size: 18),
                        label: const Text('Change Photo'),
                      ),
                    ],
                  ),
                ),
              );
            } else {
              onPickPhoto(sId);
            }
          },
          child: avatarWidget,
        );

        Widget? hifzBadge;
        if (lines >= 8640) {
          hifzBadge = Container(
            margin: const EdgeInsets.only(left: 6, right: 6),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFFE8F5E9),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFF2E7D32), width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.stars_rounded, color: Colors.amber, size: 12),
                const SizedBox(width: 3),
                Text(
                  context.isUrdu ? 'حفظ مکمل! 🎉' : 'Hifz Complete! 🎉',
                  style: const TextStyle(color: Color(0xFF2E7D32), fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          );
        } else if (lines >= 8000) {
          hifzBadge = Container(
            margin: const EdgeInsets.only(left: 6, right: 6),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF3E0),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.orange, width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.auto_awesome, color: Colors.orange, size: 12),
                const SizedBox(width: 3),
                Text(
                  context.isUrdu ? 'حفظ مکمل ہونے والا ہے! 🌟' : 'Nearing Hifz! 🌟',
                  style: const TextStyle(color: Colors.orange, fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          );
        }

        Widget topRow = Row(
          children: [
            SizedBox(
              width: 32,
              child: Text(
                rollNumber,
                style: TextStyle(color: textMuted, fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ),
            avatarWidget,
            const SizedBox(width: 8),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      name,
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: textPrimary),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (hifzBadge != null) hifzBadge,
                ],
              ),
            ),
            IconButton(
              icon: const FaIcon(FontAwesomeIcons.whatsapp, color: Color(0xFF25D366), size: 20),
              onPressed: () => onSendWhatsApp(student, log),
              tooltip: 'Send WhatsApp report',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            if (isPtmDay) ...[
              const SizedBox(width: 8),
              _attButton('J', log['ptm'] == true, const Color(0xFF2E7D32), isReadOnly ? () {} : () => onUpdateLocal(sId, 'ptm', true), isDark: isDark),
              const SizedBox(width: 4),
              _attButton('M', log['ptm'] == false, const Color(0xFFD32F2F), isReadOnly ? () {} : () => onUpdateLocal(sId, 'ptm', false), isDark: isDark),
            ],
          ],
        );

        Widget middleRow = Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            if (isParentRequested && leaveStatus == 'pending')
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF8E1),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.amber.shade300),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              context.isUrdu ? 'رخصت کی درخواست' : 'Leave Request',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.amber.shade900, fontFamily: context.isUrdu ? 'Noori' : null),
                            ),
                            if (log['leaveReason'] != null && log['leaveReason'].toString().isNotEmpty)
                              Text(
                                log['leaveReason'].toString(),
                                style: const TextStyle(fontSize: 11, color: Colors.black87),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      _actionButton(context.isUrdu ? 'منظور' : 'Approve', Colors.green, () {
                        onUpdateLocal(sId, 'attendance', 'leave');
                        onUpdateLocal(sId, 'leaveStatus', 'approved');
                        onUpdateLocal(sId, 'uniform', 'leave');
                      }),
                      const SizedBox(width: 6),
                      _actionButton(context.isUrdu ? 'مسترد' : 'Deny', Colors.red, () {
                        onUpdateLocal(sId, 'attendance', 'absent');
                        onUpdateLocal(sId, 'leaveStatus', 'denied');
                      }),
                    ],
                  ),
                ),
              )
            else ...[
              SegmentedAttendanceToggle(
                value: att,
                allowStudentLeave: allowStudentLeave,
                isGlobalUser: _isGlobalLevelUser(editorRole),
                onChanged: isReadOnly ? null : (newAtt) {
                  onUpdateLocal(sId, 'attendance', newAtt);
                  if (newAtt == 'leave') {
                    onUpdateLocal(sId, 'uniform', 'leave');
                  } else if (newAtt == 'absent') {
                    onUpdateLocal(sId, 'uniform', false);
                  }
                },
                showLabel: false,
              ),
              _switchCol(
                context,
                context.l.uniform,
                (att == 'leave' || uni == true || uni == 'leave'),
                (att == 'present' && !isReadOnly) ? (v) => onUpdateLocal(sId, 'uniform', v) : null,
                isDark: isDark,
              ),
              _switchCol(
                context,
                context.l.parentReplied,
                msg,
                isReadOnly ? null : (v) => onUpdateLocal(sId, 'parentReplied', v),
                activeColor: const Color(0xFFFFA726),
                trackColor: const Color(0xFFFFCC80),
                isDark: isDark,
              ),
            ]
          ],
        );

        Widget desktopRow = Row(
          children: [
            SizedBox(
              width: 40,
              child: Text(
                rollNumber,
                style: TextStyle(color: textMuted, fontWeight: FontWeight.bold),
              ),
            ),
            avatarWidget,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: textPrimary),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (hifzBadge != null) hifzBadge,
                    ],
                  ),
                  if ((isParentRequested || att == 'leave_requested') && leaveStatus == 'pending')
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade50,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.amber.shade300),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.event_note_rounded, size: 14, color: Colors.amber.shade900),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  'Parent Requested Leave: "${log['leaveReason'] ?? "No reason"}"',
                                  style: TextStyle(fontSize: 11.5, color: Colors.amber.shade900, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              _actionButton('Allow Leave', Colors.green, isReadOnly ? () {} : () {
                                onUpdateLocal(sId, 'attendance', 'leave');
                                onUpdateLocal(sId, 'leaveStatus', 'approved');
                                onUpdateLocal(sId, 'isParentRequested', false);
                              }),
                              const SizedBox(width: 8),
                              _actionButton('Decline', Colors.red, isReadOnly ? () {} : () {
                                onUpdateLocal(sId, 'leaveStatus', 'declined');
                                onUpdateLocal(sId, 'isParentRequested', false);
                              }),
                            ],
                          ),
                        ],
                      ),
                    ),
                  if (leaveStatus == 'approved')
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.green.shade50,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.green.shade200),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.check_circle_rounded, size: 14, color: Colors.green.shade800),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              'Leave Approved: "${log['leaveReason'] ?? "Granted"}"',
                              style: TextStyle(fontSize: 11, color: Colors.green.shade900, fontWeight: FontWeight.bold),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (leaveStatus == 'declined')
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.red.shade200),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.cancel_rounded, size: 14, color: Colors.red.shade800),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              'Leave Request Declined',
                              style: TextStyle(fontSize: 11, color: Colors.red.shade900, fontWeight: FontWeight.bold),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (hasPendingReply && msg != true)
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.purple.shade50,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.purple.shade200),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.reply_rounded, size: 14, color: Colors.purple.shade900),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  parentMsgText != null && parentMsgText.trim().isNotEmpty
                                      ? 'Parent Reply: "$parentMsgText"'
                                      : 'Parent requested reply verification',
                                  style: TextStyle(fontSize: 11.5, color: Colors.purple.shade900, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              _actionButton('Approve Reply', Colors.purple, isReadOnly ? () {} : () {
                                onUpdateLocal(sId, 'parentReplied', true);
                                onUpdateLocal(sId, 'parentRepliedRequested', false);
                              }),
                              const SizedBox(width: 8),
                              _actionButton('Deny', Colors.red, isReadOnly ? () {} : () {
                                onUpdateLocal(sId, 'parentRepliedRequested', false);
                              }),
                            ],
                          ),
                        ],
                      ),
                    ),
                  if (msg == true)
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.green.shade50,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.green.shade200),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.check_circle_outline_rounded, size: 14, color: Colors.green.shade800),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              parentMsgText != null && parentMsgText.trim().isNotEmpty
                                  ? 'Parent Reply: "$parentMsgText"'
                                  : 'Parent Reply: Approved',
                              style: TextStyle(fontSize: 11, color: Colors.green.shade900, fontWeight: FontWeight.bold),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (log['ptmRequestStatus'] == 'claimed')
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.blue.shade100),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.people_rounded, size: 14, color: Colors.blue.shade900),
                          const SizedBox(width: 6),
                          Text(
                            'Parent claimed PTM attendance',
                            style: TextStyle(fontSize: 11, color: Colors.blue.shade900, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(width: 8),
                          _actionButton('Approve', Colors.green, isReadOnly ? () {} : () {
                            onUpdateLocal(sId, 'ptm', true);
                            onUpdateLocal(sId, 'ptmRequestStatus', 'approved');
                          }),
                          const SizedBox(width: 6),
                          _actionButton('Decline', Colors.red, isReadOnly ? () {} : () {
                            onUpdateLocal(sId, 'ptm', false);
                            onUpdateLocal(sId, 'ptmRequestStatus', 'rejected');
                          }),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (isParentRequested && leaveStatus == 'pending')
              Row(
                children: [
                  _actionButton('Approve', Colors.green, isReadOnly ? () {} : () {
                    onUpdateLocal(sId, 'attendance', 'leave');
                    onUpdateLocal(sId, 'leaveStatus', 'approved');
                    onUpdateLocal(sId, 'uniform', 'leave');
                  }),
                  const SizedBox(width: 8),
                  _actionButton('Deny', Colors.red, isReadOnly ? () {} : () {
                    onUpdateLocal(sId, 'attendance', 'absent');
                    onUpdateLocal(sId, 'leaveStatus', 'denied');
                  }),
                ],
              )
            else
              SegmentedAttendanceToggle(
                value: att,
                allowStudentLeave: allowStudentLeave,
                isGlobalUser: _isGlobalLevelUser(editorRole),
                onChanged: isReadOnly ? null : (newAtt) {
                  onUpdateLocal(sId, 'attendance', newAtt);
                  if (newAtt == 'leave') {
                    onUpdateLocal(sId, 'uniform', 'leave');
                  } else if (newAtt == 'absent') {
                    onUpdateLocal(sId, 'uniform', false);
                  }
                },
                showLabel: true,
              ),
            const SizedBox(width: 24),
            _switchCol(
              context,
              context.l.uniform,
              (att == 'leave' || uni == true || uni == 'leave'),
              (att == 'present' && !isReadOnly) ? (v) => onUpdateLocal(sId, 'uniform', v) : null,
            ),
            const SizedBox(width: 24),
            _switchCol(
              context,
              context.l.parentReplied,
              msg,
              isReadOnly ? null : (v) => onUpdateLocal(sId, 'parentReplied', v),
              activeColor: const Color(0xFFFFA726),
              trackColor: const Color(0xFFFFCC80),
            ),
            const SizedBox(width: 24),
            IconButton(
              icon: const FaIcon(FontAwesomeIcons.whatsapp, color: Color(0xFF25D366), size: 20),
              onPressed: () => onSendWhatsApp(student, log),
              tooltip: 'Send WhatsApp report',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            if (isPtmDay) ...[
              const SizedBox(width: 24),
              Column(
                children: [
                  Text(
                    context.l.ptm,
                    style: context.urduStyle(style: const TextStyle(fontSize: 10, color: Color(0xFF78909C), fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      _attButton('J', log['ptm'] == true, const Color(0xFF2E7D32), isReadOnly ? () {} : () => onUpdateLocal(sId, 'ptm', true)),
                      const SizedBox(width: 4),
                      _attButton('M', log['ptm'] == false, const Color(0xFFD32F2F), isReadOnly ? () {} : () => onUpdateLocal(sId, 'ptm', false)),
                    ],
                  ),
                ],
              ),
            ],
          ],
        );

        Widget progressSection = const SizedBox.shrink();
        if (att == 'present') {
          progressSection = Container(
            margin: const EdgeInsets.only(top: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8F9FA),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE9ECEF)),
            ),
            child: isMobile
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSabakField(context, sId, lines, isDark: isDark),
                      const SizedBox(height: 12),
                      _buildSabkiField(context, sabkiPara, sabkiRatio, isDark: isDark),
                      const SizedBox(height: 12),
                      _buildManzilField(context, manzilPara, manzilRatio, isDark: isDark),
                    ],
                  )
                : Row(
                    children: [
                      Expanded(child: _buildSabakField(context, sId, lines, isDark: isDark)),
                      const SizedBox(width: 16),
                      Expanded(child: _buildSabkiField(context, sabkiPara, sabkiRatio, isDark: isDark)),
                      const SizedBox(width: 16),
                      Expanded(child: _buildManzilField(context, manzilPara, manzilRatio, isDark: isDark)),
                    ],
                  ),
          );
        }

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderColor),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.02),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            children: [
              isMobile
                  ? Column(
                      children: [
                        topRow,
                        const SizedBox(height: 8),
                        if (isParentRequested && leaveStatus == 'pending') ...[
                          Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(color: Colors.amber.shade50, borderRadius: BorderRadius.circular(4)),
                            width: double.infinity,
                            child: Text(
                              'Parent requested a leave: ${log['leaveReason'] ?? "No reason"}',
                              style: TextStyle(fontSize: 11, color: Colors.amber.shade900, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                        if (parentRepliedRequested && msg != true) ...[
                          Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.purple.shade50,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.purple.shade200),
                            ),
                            width: double.infinity,
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Parent requested reply verification',
                                    style: TextStyle(fontSize: 11, color: Colors.purple.shade900, fontWeight: FontWeight.bold),
                                  ),
                                ),
                                _actionButton('Approve Reply', Colors.purple, isReadOnly ? () {} : () {
                                  onUpdateLocal(sId, 'parentReplied', true);
                                  onUpdateLocal(sId, 'parentRepliedRequested', false);
                                }),
                                const SizedBox(width: 8),
                                _actionButton('Deny', Colors.red, isReadOnly ? () {} : () {
                                  onUpdateLocal(sId, 'parentRepliedRequested', false);
                                }),
                              ],
                            ),
                          ),
                        ],
                        if (log['ptmRequestStatus'] == 'claimed') ...[
                          Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.blue.shade50,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.blue.shade200),
                            ),
                            width: double.infinity,
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    context.isUrdu ? 'والدین نے پی ٹی ایم میں شرکت کا دعویٰ کیا ہے' : 'Parent claimed PTM attendance',
                                    style: TextStyle(fontSize: 11, color: Colors.blue.shade900, fontWeight: FontWeight.bold, fontFamily: context.isUrdu ? 'Noori' : null),
                                  ),
                                ),
                                _actionButton('Approve', Colors.green, isReadOnly ? () {} : () {
                                  onUpdateLocal(sId, 'ptm', true);
                                  onUpdateLocal(sId, 'ptmRequestStatus', 'approved');
                                }),
                                const SizedBox(width: 8),
                                _actionButton('Decline', Colors.red, isReadOnly ? () {} : () {
                                  onUpdateLocal(sId, 'ptm', false);
                                  onUpdateLocal(sId, 'ptmRequestStatus', 'rejected');
                                }),
                              ],
                            ),
                          ),
                        ],
                        middleRow,
                      ],
                    )
                  : desktopRow,
              progressSection,
            ],
          ),
        );
      },
    );
  }
}