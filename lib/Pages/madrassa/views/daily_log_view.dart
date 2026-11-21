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
import '../../../services/camp_session_service.dart';
import '../../../realtime/realtime_manager.dart';
import '../../../realtime/realtime_events.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/madrassa_providers.dart';
import 'dart:async';

import '../madrassa_strings.dart';
import 'package:gmwf_ui/gmwf_ui.dart' show GIcons;
import '../../../design/design_system.dart';
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
  String _selectedSessionFilter = 'all';
  String _selectedProgramFilter = 'all'; // 'all', 'hifz', 'nazra'
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
  String get _effectiveBranch => MadrassaLocalStorage.normalizeBranch(widget.branchId);

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
  // Runs on every date tap; without a throttle each tap re-read the whole
  // students collection (~150+ reads) and the same month's logs again.
  static final Map<String, DateTime> _lastDownloadAt = {};

  static bool _downloadDue(String key, Duration every) {
    final last = _lastDownloadAt[key];
    if (last != null && DateTime.now().difference(last) < every) return false;
    _lastDownloadAt[key] = DateTime.now();
    return true;
  }

  void _updateDateStreams() {
    final b = _effectiveBranch;
    if (_downloadDue('students|$b', const Duration(minutes: 10))) {
      MadrassaLocalStorage.downloadStudents(b);
    }
    final y = _selectedDate.year, m = _selectedDate.month;
    if (_downloadDue('logs|$b|$y-$m', const Duration(minutes: 2))) {
      MadrassaLocalStorage.downloadLogsForMonth(b, y, m);
    }
    if (_downloadDue('holidays|$b', const Duration(minutes: 30))) {
      MadrassaLocalStorage.downloadHolidays(b);
    }
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
        AppToast.showSnackBar(context, 
          SnackBar(content: Text('Sabki: Para must be selected for ratio $sabkiRatio.')),
        );
        setState(() => _isSaving = false);
        return;
      }
      if (sabkiPara > 0 && !hasSabkiRatio) {
        AppToast.showSnackBar(context, 
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
        AppToast.showSnackBar(context, 
          SnackBar(content: Text('Manzil: Para must be selected for ratio $manzilRatio.')),
        );
        setState(() => _isSaving = false);
        return;
      }
      if (manzilPara > 0 && !hasManzilRatio) {
        AppToast.showSnackBar(context, 
          SnackBar(content: Text('Manzil: Ratio must be selected for Para $manzilPara.')),
        );
        setState(() => _isSaving = false);
        return;
      }

      // Ruku validation
      final int rukuPara = data['rukuPara'] is int ? data['rukuPara'] : (int.tryParse(data['rukuPara']?.toString() ?? '') ?? 0);
      final String? rukuVal = data['ruku']?.toString();
      final bool hasRuku = rukuVal != null && rukuVal.isNotEmpty && rukuVal != '-';
      if (hasRuku && rukuVal != 'nahi_sunaya' && rukuPara == 0) {
        AppToast.showSnackBar(context, 
          SnackBar(content: Text('Ruku: Para must be selected for $rukuVal Ruku.')),
        );
        setState(() => _isSaving = false);
        return;
      }
      if (rukuPara > 0 && !hasRuku) {
        AppToast.showSnackBar(context, 
          SnackBar(content: Text('Ruku: Please select Ruku count for Para $rukuPara.')),
        );
        setState(() => _isSaving = false);
        return;
      }
    }

    try {
      final String dateKey = DateFormat('yyyy-MM-dd').format(_selectedDate);

      // Save locally (updates cached student currentLines, enqueues sync tasks, enqueues audit logs)
      await MadrassaLocalStorage.saveLogRecordLocal(
        branchId: _effectiveBranch,
        dateKey: dateKey,
        logData: _localChanges,
        editorName: widget.editorName,
        editorRole: widget.editorRole,
      );

      // If any Nazra student had Qaida completed or reverted, ensure student profile is updated
      for (var entry in _localChanges.entries) {
        final sId = entry.key;
        final data = entry.value;
        if (data['qaidaSabak'] == 'completed' || data['qaidaCompleted'] == true) {
          final cached = MadrassaLocalStorage.getStudentCached(_effectiveBranch, sId);
          if (cached != null && cached['qaidaCompleted'] != true) {
            cached['qaidaCompleted'] = true;
            cached['qaidaSabak'] = 'completed';
            await MadrassaLocalStorage.cacheStudent(_effectiveBranch, sId, cached);
            final compacted = MadrassaLocalStorage.compactMediaForCloud(Map<String, dynamic>.from(cached));
            await LocalStorageService.enqueueSync({
              'type': 'save_madrassa_student',
              'branchId': _effectiveBranch,
              'studentId': sId,
              'data': compacted,
            });
          }
        } else if (data['qaidaCompleted'] == false || (data.containsKey('qaidaSabak') && data['qaidaSabak'] != 'completed' && data['qaidaSabak'] != null && data['qaidaSabak'] != '-')) {
          final cached = MadrassaLocalStorage.getStudentCached(_effectiveBranch, sId);
          if (cached != null && (cached['qaidaCompleted'] == true || cached['qaidaSabak'] == 'completed')) {
            cached['qaidaCompleted'] = false;
            cached['qaidaSabak'] = data['qaidaSabak'] ?? '21';
            await MadrassaLocalStorage.cacheStudent(_effectiveBranch, sId, cached);
            final compacted = MadrassaLocalStorage.compactMediaForCloud(Map<String, dynamic>.from(cached));
            await LocalStorageService.enqueueSync({
              'type': 'save_madrassa_student',
              'branchId': _effectiveBranch,
              'studentId': sId,
              'data': compacted,
            });
          }
        }
      }

      // Write audit log entry in background
      unawaited(MadrassaAuditService.logAction(
        branchId: _effectiveBranch,
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
        AppToast.showSnackBar(context, 
          SnackBar(content: Text(context.l.savedSuccess)),
        );
      }
    } catch (e) {
      setState(() => _isSaving = false);
      if (mounted) {
        AppToast.showSnackBar(context, 
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
      final logData = ref.read(madrassaDailyLogProvider((branchId: _effectiveBranch, dateKey: dateKey))).value ?? {};
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
    final logData = ref.read(madrassaDailyLogProvider((branchId: _effectiveBranch, dateKey: dateKey))).value ?? {};
    final dbLog = _safeMap(logData[sId]);
    final currentLocal = _localChanges[sId] ?? dbLog;

    final studentCache = MadrassaLocalStorage.getStudentCached(_effectiveBranch, sId);
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

  void _decideLeaveSilent(String sId, {required bool approve}) {
    final dateKey = DateFormat('yyyy-MM-dd').format(_selectedDate);
    final logData = ref.read(madrassaDailyLogProvider((branchId: _effectiveBranch, dateKey: dateKey))).value ?? {};
    final current = _localChanges[sId] ?? _safeMap(logData[sId]);
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final reqAt = current['leaveRequestedAt'] ?? current['timestamp'];

    _updateLocalSilent(sId, 'attendance', approve ? 'leave' : 'absent');
    _updateLocalSilent(sId, 'leaveStatus', approve ? 'approved' : 'denied');
    _updateLocalSilent(sId, 'isParentRequested', false);
    _updateLocalSilent(sId, 'leaveDecidedAt', nowIso);
    _updateLocalSilent(sId, 'leaveDecidedBy', widget.editorName);
    if (reqAt != null) {
      _updateLocalSilent(sId, 'leaveDecidedFor', reqAt);
    }
    _updateLocalSilent(sId, 'uniform', approve ? 'leave' : false);
    _updateLocalSilent(sId, 'isLate', false);
    _updateLocalSilent(sId, 'timing', 'on_time');
    _updateLocalSilent(sId, 'arrivalTime', null);
  }

  void _updateAttendanceSilent(String sId, String value) {
    final dateKey = DateFormat('yyyy-MM-dd').format(_selectedDate);
    final logData = ref.read(madrassaDailyLogProvider((branchId: _effectiveBranch, dateKey: dateKey))).value ?? {};
    final current = _localChanges[sId] ?? _safeMap(logData[sId]);
    final prevAtt = (current['attendance'] ?? '').toString().toLowerCase().trim();
    final prevLeaveStatus = (current['leaveStatus'] ?? '').toString().toLowerCase().trim();
    final hadPendingOrApprovedLeave = prevAtt == 'leave_requested' ||
        prevAtt == 'leave' ||
        current['isParentRequested'] == true ||
        prevLeaveStatus == 'pending' ||
        prevLeaveStatus == 'approved';
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final reqAt = current['leaveRequestedAt'] ?? current['timestamp'];

    _updateLocalSilent(sId, 'attendance', value);
    if (value == 'leave') {
      _updateLocalSilent(sId, 'uniform', 'leave');
      _updateLocalSilent(sId, 'isLate', false);
      _updateLocalSilent(sId, 'timing', 'on_time');
      _updateLocalSilent(sId, 'arrivalTime', null);
      _updateLocalSilent(sId, 'leaveStatus', 'approved');
      _updateLocalSilent(sId, 'isParentRequested', false);
      _updateLocalSilent(sId, 'leaveDecidedAt', nowIso);
      _updateLocalSilent(sId, 'leaveDecidedBy', widget.editorName);
      if (reqAt != null) {
        _updateLocalSilent(sId, 'leaveDecidedFor', reqAt);
      }
    } else if (value == 'absent') {
      _updateLocalSilent(sId, 'uniform', false);
      _updateLocalSilent(sId, 'isLate', false);
      _updateLocalSilent(sId, 'timing', 'on_time');
      _updateLocalSilent(sId, 'arrivalTime', null);
      if (hadPendingOrApprovedLeave) {
        _updateLocalSilent(sId, 'leaveStatus', 'denied');
        _updateLocalSilent(sId, 'isParentRequested', false);
        _updateLocalSilent(sId, 'leaveDecidedAt', nowIso);
        _updateLocalSilent(sId, 'leaveDecidedBy', widget.editorName);
        if (reqAt != null) {
          _updateLocalSilent(sId, 'leaveDecidedFor', reqAt);
        }
      }
    } else if (value == 'present') {
      if (hadPendingOrApprovedLeave) {
        _updateLocalSilent(sId, 'leaveStatus', 'cancelled');
        _updateLocalSilent(sId, 'isParentRequested', false);
        _updateLocalSilent(sId, 'leaveDecidedAt', nowIso);
        _updateLocalSilent(sId, 'leaveDecidedBy', widget.editorName);
        if (reqAt != null) {
          _updateLocalSilent(sId, 'leaveDecidedFor', reqAt);
        }
      }
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
                  Icon(Icons.people_rounded, color: context.adapt(SoftPalette.blue400)),
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
                          style: TextStyle(color: context.adapt(SoftPalette.gray350)),
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
                                      Text('Roll: $roll', style: TextStyle(color: context.adapt(SoftPalette.gray350), fontSize: 12)),
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
                                    backgroundColor: SoftPalette.green400,
                                    foregroundColor: SoftPalette.gray50,
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
                                    backgroundColor: SoftPalette.red400,
                                    foregroundColor: SoftPalette.gray50,
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
    final isDesktop = GBreakpoint.isDesktop(context);
    
    final configAsyncValue = ref.watch(madrassaConfigProvider(_effectiveBranch));
    final holidaysAsyncValue = ref.watch(madrassaHolidaysProvider(_effectiveBranch));
    final dateKey = DateFormat('yyyy-MM-dd').format(_selectedDate);
    final filteredStudentsAsyncValue = ref.watch(madrassaFilteredStudentsProvider((branchId: _effectiveBranch, selectedDate: _selectedDate)));
    final logAsyncValue = ref.watch(madrassaDailyLogProvider((branchId: _effectiveBranch, dateKey: dateKey)));

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
          backgroundColor: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
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
                    child: GDecorativeImage.asset(
                      'assets/images/islamic_pattern.webp',
                      fit: BoxFit.cover,
                      repeat: ImageRepeat.repeat,
                      color: SoftPalette.yellow300,
                      colorBlendMode: BlendMode.srcIn,
                    ),
                  ),
                ),
              ),
              RefreshIndicator(
                onRefresh: () async {
                  final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);
                  await MadrassaLocalStorage.downloadLogsForMonth(_effectiveBranch, _selectedDate.year, _selectedDate.month);
                  await MadrassaLocalStorage.downloadStudents(_effectiveBranch, force: false);
                  ref.invalidate(madrassaDailyLogProvider((branchId: _effectiveBranch, dateKey: dateStr)));
                  ref.invalidate(madrassaFilteredStudentsProvider((branchId: _effectiveBranch, selectedDate: _selectedDate)));
                  if (mounted) setState(() => _studentNotifiers.clear());
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
                        color: context.adapt(SoftPalette.slate100),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: context.adapt(SoftPalette.sky300)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.people_rounded, color: context.adapt(SoftPalette.blue600)),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  context.isUrdu 
                                      ? 'پی ٹی ایم کی حاضری کے دعوے زیر التوا ہیں'
                                      : 'Pending PTM Attendance Claims',
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: context.adapt(SoftPalette.blue600)),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  context.isUrdu
                                      ? '${pendingPtmClaims.length} طلباء نے پی ٹی ایم میں شرکت کا دعویٰ کیا ہے۔ جائزہ لینے کے لیے کلک کریں۔'
                                      : '${pendingPtmClaims.length} student(s) claimed PTM attendance. Tap to review.',
                                  style: TextStyle(fontSize: 12, color: context.adapt(SoftPalette.blue550)),
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
                              backgroundColor: SoftPalette.blue500,
                              foregroundColor: SoftPalette.gray50,
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
                      color: context.adapt(SoftPalette.yellow50),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: context.adapt(SoftPalette.yellow150)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, color: context.adapt(SoftPalette.orange350)),
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
                                color: context.adapt(SoftPalette.orange350),
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
                                  ? context.adapt(SoftPalette.yellow300).withValues(alpha: 0.15)
                                  : context.adapt(SoftPalette.green100m),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: islamicEvent != null
                                    ? context.adapt(SoftPalette.yellow300).withValues(alpha: 0.4)
                                    : context.adapt(SoftPalette.green300),
                                width: 2,
                              ),
                            ),
                            child: islamicEvent != null
                                ? Text(islamicEvent.emoji, style: const TextStyle(fontSize: 52))
                                : Icon(Icons.flag_rounded, size: 64, color: context.adapt(SoftPalette.green500)),
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
                                    ? (isDark ? SoftPalette.yellow150 : SoftPalette.orange600)
                                    : SoftPalette.green600,
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
                                  ? (isDark ? SoftPalette.amber200 : SoftPalette.orange500)
                                  : SoftPalette.gray350,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            decoration: BoxDecoration(
                              color: context.adapt(SoftPalette.green200).withValues(alpha: 0.5),
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
                                  color: context.adapt(SoftPalette.green600),
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
                              color: context.adapt(SoftPalette.slate100),
                              shape: BoxShape.circle,
                              border: Border.all(color: context.adapt(SoftPalette.sky300), width: 2),
                            ),
                            child: Icon(Icons.weekend_rounded, size: 64, color: context.adapt(SoftPalette.blue500)),
                          ),
                          const SizedBox(height: 24),
                          Text(
                            context.isUrdu ? 'اتوار کی چھٹی' : 'Weekly Holiday (Sunday)',
                            style: context.urduStyle(
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: context.adapt(SoftPalette.blue600),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            DateFormat('EEEE, MMMM d, yyyy').format(_selectedDate),
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              color: context.adapt(SoftPalette.gray350),
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
                            color: isPtmDay ? context.adapt(SoftPalette.amber300) : context.adapt(SoftPalette.gray300),
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
                                color: isPtmDay ? context.adapt(SoftPalette.orange400) : context.adapt(SoftPalette.gray350),
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
                                style: TextStyle(
                                  fontSize: 14,
                                  color: context.adapt(SoftPalette.gray350),
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
                        final double paddingVal = GBreakpoint.isMobile(context) ? Gsp.s16 : Gsp.s24;
                        final isNazraOnly = LocalStorageService.isMadrassaNazraOnly(_effectiveBranch);
                        final branchSessions = CampSessionService.getMadrassaSessions(_effectiveBranch);

                        final displayedStudents = students.where((s) {
                          if (_selectedSessionFilter != 'all') {
                            final sSess = (s['session'] ?? 'morning').toString().toLowerCase().trim();
                            if (sSess != _selectedSessionFilter) return false;
                          }
                          final isStudentNazra = isNazraOnly ||
                              (s['isNazra'] == true) ||
                              (s['program']?.toString().toLowerCase() == 'nazra') ||
                              (s['class']?.toString().toLowerCase() == 'nazra');
                          if (_selectedProgramFilter == 'hifz') {
                            if (isStudentNazra) return false;
                          } else if (_selectedProgramFilter == 'nazra') {
                            if (!isStudentNazra) return false;
                          }
                          return true;
                        }).toList();

                        final nazraCount = students.where((s) => isNazraOnly ||
                            (s['isNazra'] == true) ||
                            (s['program']?.toString().toLowerCase() == 'nazra') ||
                            (s['class']?.toString().toLowerCase() == 'nazra')).length;
                        final hifzCount = students.length - nazraCount;

                        return SliverPadding(
                          padding: EdgeInsets.symmetric(horizontal: paddingVal),
                          sliver: SliverList(
                            key: const PageStorageKey('daily_log_student_list'),
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                if (index == 0) {
                                  return Column(
                                    children: [
                                      if (isNazraOnly)
                                        Container(
                                          margin: const EdgeInsets.only(bottom: 8),
                                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                          decoration: BoxDecoration(
                                            color: context.adapt(SoftPalette.teal500).withValues(alpha: 0.12),
                                            borderRadius: BorderRadius.circular(10),
                                            border: Border.all(color: context.adapt(SoftPalette.teal500).withValues(alpha: 0.3)),
                                          ),
                                          child: Row(
                                            children: [
                                              Icon(Icons.menu_book_rounded, color: context.adapt(SoftPalette.teal500), size: 18),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: Text(
                                                  context.isUrdu
                                                      ? 'صرف ناظرہ سسٹم: حاضری، یونیفارم اور سبق لاگ فعال ہے۔ سبقی/منزل سسٹم بند ہے۔'
                                                      : 'Only Nazra System Active: Tracking Attendance, Uniform & Sabak. Sabqi/Manzil disabled.',
                                                  style: context.urduStyle(
                                                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.adapt(SoftPalette.teal500)),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      // Program Filter Bar (Hifz / Nazra)
                                      if (!isNazraOnly)
                                        Container(
                                          margin: const EdgeInsets.only(bottom: 8),
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                          decoration: BoxDecoration(
                                            color: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
                                            borderRadius: BorderRadius.circular(12),
                                            border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.slate150),
                                          ),
                                          child: Row(
                                            children: [
                                              Icon(Icons.category_rounded, size: 16, color: isDark ? SoftPalette.slate350 : SoftPalette.slate550),
                                              const SizedBox(width: 8),
                                              Text(
                                                context.isUrdu ? 'پروگرام / کلاس:' : 'Program:',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.bold,
                                                  color: isDark ? SoftPalette.gray50A70 : SoftPalette.slate600,
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: SingleChildScrollView(
                                                  scrollDirection: Axis.horizontal,
                                                  child: Row(
                                                    children: [
                                                      ChoiceChip(
                                                        label: Text('All (${students.length})'),
                                                        selected: _selectedProgramFilter == 'all',
                                                        onSelected: (val) {
                                                          if (val) setState(() => _selectedProgramFilter = 'all');
                                                        },
                                                        selectedColor: SoftPalette.teal550,
                                                        labelStyle: TextStyle(
                                                          fontSize: 11,
                                                          fontWeight: FontWeight.bold,
                                                          color: _selectedProgramFilter == 'all' ? SoftPalette.gray50 : null,
                                                        ),
                                                      ),
                                                      const SizedBox(width: 6),
                                                      ChoiceChip(
                                                        label: Text('🕋 Hifz ($hifzCount)'),
                                                        selected: _selectedProgramFilter == 'hifz',
                                                        onSelected: (val) {
                                                          if (val) setState(() => _selectedProgramFilter = 'hifz');
                                                        },
                                                        selectedColor: SoftPalette.violet550,
                                                        labelStyle: TextStyle(
                                                          fontSize: 11,
                                                          fontWeight: FontWeight.bold,
                                                          color: _selectedProgramFilter == 'hifz' ? SoftPalette.gray50 : null,
                                                        ),
                                                      ),
                                                      const SizedBox(width: 6),
                                                      ChoiceChip(
                                                        label: Text('📖 Nazra ($nazraCount)'),
                                                        selected: _selectedProgramFilter == 'nazra',
                                                        onSelected: (val) {
                                                          if (val) setState(() => _selectedProgramFilter = 'nazra');
                                                        },
                                                        selectedColor: SoftPalette.teal500,
                                                        labelStyle: TextStyle(
                                                          fontSize: 11,
                                                          fontWeight: FontWeight.bold,
                                                          color: _selectedProgramFilter == 'nazra' ? SoftPalette.gray50 : null,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      // Session Filter Bar
                                      if (branchSessions.length > 1 || students.any((st) => st['session'] != null))
                                        Container(
                                          margin: const EdgeInsets.only(bottom: 10),
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                          decoration: BoxDecoration(
                                            color: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
                                            borderRadius: BorderRadius.circular(12),
                                            border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.slate150),
                                          ),
                                          child: Row(
                                            children: [
                                              Icon(Icons.filter_list_rounded, size: 16, color: isDark ? SoftPalette.slate350 : SoftPalette.slate550),
                                              const SizedBox(width: 8),
                                              Text(
                                                context.isUrdu ? 'شفٹ / سیشن:' : 'Session:',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.bold,
                                                  color: isDark ? SoftPalette.gray50A70 : SoftPalette.slate600,
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: SingleChildScrollView(
                                                  scrollDirection: Axis.horizontal,
                                                  child: Row(
                                                    children: [
                                                      ChoiceChip(
                                                        label: Text('All (${students.length})'),
                                                        selected: _selectedSessionFilter == 'all',
                                                        onSelected: (val) {
                                                          if (val) setState(() => _selectedSessionFilter = 'all');
                                                        },
                                                        selectedColor: SoftPalette.teal550,
                                                        labelStyle: TextStyle(
                                                          fontSize: 11,
                                                          fontWeight: FontWeight.bold,
                                                          color: _selectedSessionFilter == 'all' ? SoftPalette.gray50 : null,
                                                        ),
                                                      ),
                                                      const SizedBox(width: 6),
                                                      ...['morning', 'evening', 'night'].where((s) => branchSessions.contains(s) || students.any((st) => (st['session'] ?? 'morning') == s)).map((s) {
                                                        final count = students.where((st) => (st['session'] ?? 'morning') == s).length;
                                                        final label = s == 'morning'
                                                            ? '☀️ Morning ($count)'
                                                            : (s == 'evening' ? '🌅 Evening ($count)' : '🌙 Night ($count)');
                                                        final isSelected = _selectedSessionFilter == s;
                                                        return Padding(
                                                          padding: const EdgeInsets.only(right: 6),
                                                          child: ChoiceChip(
                                                            label: Text(label),
                                                            selected: isSelected,
                                                            onSelected: (val) {
                                                              if (val) setState(() => _selectedSessionFilter = s);
                                                            },
                                                            selectedColor: SoftPalette.teal550,
                                                            labelStyle: TextStyle(
                                                              fontSize: 11,
                                                              fontWeight: FontWeight.bold,
                                                              color: isSelected ? SoftPalette.gray50 : null,
                                                            ),
                                                          ),
                                                        );
                                                      }),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      if (isReadOnly)
                                        Container(
                                          margin: const EdgeInsets.only(bottom: 8),
                                          padding: const EdgeInsets.all(8),
                                          width: double.infinity,
                                          alignment: Alignment.center,
                                          decoration: BoxDecoration(
                                            color: context.adapt(SoftPalette.yellow50),
                                            borderRadius: BorderRadius.circular(8),
                                            border: Border.all(color: context.adapt(SoftPalette.yellow150)),
                                          ),
                                          child: Text(
                                            context.isUrdu ? 'صرف پڑھنے کی اجازت ہے (پرانی تاریخ)' : 'Read Only Mode (Past Date)',
                                            style: TextStyle(color: context.adapt(SoftPalette.orange350), fontSize: 12, fontWeight: FontWeight.bold),
                                          ),
                                        ),
                                      ValueListenableBuilder<int>(
                                        valueListenable: _changeNotifier,
                                        builder: (context, _, __) =>
                                            _buildStatusLegend(context, config, displayedStudents, logData),
                                      ),
                                    ],
                                  );
                                }
                                final s = displayedStudents[index - 1];
                                final sId = s['id'] ?? '';
                                final sLog = _localChanges[sId] ?? _safeMap(logData[sId]);
                                // Marks saved on another device arrive in logData after this
                                // screen was built. Refresh the card with them unless this user
                                // has unsaved edits for the student (those are never overwritten).
                                var notifier = _studentNotifiers[sId];
                                if (notifier == null ||
                                    (!_localChanges.containsKey(sId) &&
                                        !const DeepCollectionEquality().equals(notifier.value, sLog))) {
                                  notifier = ValueNotifier(sLog);
                                  _studentNotifiers[sId] = notifier;
                                }
                                return _StudentLogCard(
                                  key: ValueKey('${sId}_${_selectedDate.toIso8601String()}'),
                                  student: s,
                                  logNotifier: notifier,
                                  isPtmDay: isPtmDay,
                                  isReadOnly: isReadOnly,
                                  branchId: _effectiveBranch,
                                  allowStudentLeave: effectiveAllowLeave,
                                  editorRole: widget.editorRole,
                                  uploadStatus: _uploadStates[sId],
                                  onUpdateLocal: _updateLocalSilent,
                                  onUpdateAttendance: _updateAttendanceSilent,
                                  onDecideLeave: _decideLeaveSilent,
                                  onUpdateSabak: _updateSabakLines,
                                  onPickPhoto: _pickAndUploadPhoto,
                                  onSendWhatsApp: _sendDailyWhatsApp,
                                  onShowCustomLines: _showCustomLinesDialog,
                                  buildParaDropdown: _buildParaDropdown,
                                  buildRatioDropdown: _buildRatioDropdown,
                                );
                              },
                              childCount: displayedStudents.length + 1,
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
    final isMobile = GBreakpoint.isMobile(context);
    final effectiveAllowLeave = _localAllowStudentLeave ?? config.allowStudentLeave;
    final isDark = Theme.of(context).brightness == Brightness.dark || UserThemeService.isDarkMode(widget.editorName);

    final controlsRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton.icon(
          icon: Icon(Icons.today, size: 16, color: context.adapt(SoftPalette.teal550)),
          label: Text(
            context.isUrdu ? 'آج' : 'Today',
            style: TextStyle(
              color: context.adapt(SoftPalette.teal550),
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
          icon: Icon(Icons.arrow_back_ios, size: 16, color: context.adapt(SoftPalette.teal550)),
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
          icon: Icon(Icons.arrow_forward_ios, size: 16, color: context.adapt(SoftPalette.teal550)),
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
                        color: isDark ? SoftPalette.gray50 : SoftPalette.gray900,
                      ),
                    ),
                    Text(
                      context.l.dailyLog,
                      style: context.urduStyle(
                        style: TextStyle(
                          fontSize: isMobile ? 12 : 13,
                          fontWeight: FontWeight.w600,
                          color: isDark ? SoftPalette.indigo400 : SoftPalette.indigo550,
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
              color: isDark ? SoftPalette.slate350 : SoftPalette.gray500,
            ),
          ),
          if (_isGlobalLevelUser(widget.editorRole)) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: effectiveAllowLeave ? context.adapt(SoftPalette.yellow50) : context.adapt(SoftPalette.teal100m),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: effectiveAllowLeave ? context.adapt(SoftPalette.yellow200) : context.adapt(SoftPalette.teal550),
                  width: 1.5,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    effectiveAllowLeave ? Icons.event_available_rounded : Icons.event_busy_rounded,
                    color: effectiveAllowLeave ? context.adapt(SoftPalette.orange350) : context.adapt(SoftPalette.teal550),
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
                                color: SoftPalette.slate800,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                context.isUrdu ? '👑 صرف گلوبل لیول یوزرز' : '👑 Global Users Only (Chairman, CEO, HQ Manager, Admin)',
                                style: const TextStyle(color: SoftPalette.amber200, fontSize: 10, fontWeight: FontWeight.bold),
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
                              color: effectiveAllowLeave ? context.adapt(SoftPalette.orange350) : context.adapt(SoftPalette.teal700),
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
                              color: effectiveAllowLeave ? context.adapt(SoftPalette.orange350) : context.adapt(SoftPalette.gray550),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: effectiveAllowLeave ? SoftPalette.red500 : SoftPalette.teal550,
                      foregroundColor: SoftPalette.gray50,
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
                            .doc(_effectiveBranch)
                            .collection('madrassa_config')
                            .doc('current')
                            .set({'allowStudentLeave': newAllowState}, SetOptions(merge: true))
                            .timeout(const Duration(seconds: 4))
                            .catchError((err) {
                              debugPrint('[DailyLogView] Update allowStudentLeave error: $err');
                            })
                      );

                      if (mounted) {
                        AppToast.showSnackBar(context, 
                          SnackBar(
                            duration: const Duration(seconds: 2),
                            backgroundColor: newAllowState ? SoftPalette.green550 : SoftPalette.red550,
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
    final leftColor = showLeftGrey ? context.adapt(SoftPalette.gray350) : context.adapt(SoftPalette.teal550);
    final rightColor = showRightGrey ? context.adapt(SoftPalette.gray350) : context.adapt(SoftPalette.teal550);

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
                  Color cardColor = isDarkCalendar ? SoftPalette.slate800 : SoftPalette.gray50;
                  if (isSelected) {
                    cardColor = isHoliday
                        ? (cellIslamicEvent != null ? SoftPalette.yellow300 : SoftPalette.green550)
                        : SoftPalette.indigo550;
                  } else if (isHoliday) {
                    cardColor = cellIslamicEvent != null
                        ? (isDarkCalendar ? SoftPalette.amber750m : SoftPalette.yellow100)
                        : (isDarkCalendar ? SoftPalette.emerald750 : SoftPalette.green100m);
                  }

                  Border border;
                  if (isSelected) {
                    border = Border.all(color: cardColor, width: 1.0);
                  } else if (isToday) {
                    border = Border.all(color: context.adapt(SoftPalette.teal550), width: 2.0);
                  } else if (isHoliday) {
                    border = Border.all(
                      color: cellIslamicEvent != null ? context.adapt(SoftPalette.yellow300) : context.adapt(SoftPalette.green300),
                      width: 1.0,
                    );
                  } else {
                    border = Border.all(color: isDarkCalendar ? SoftPalette.slate700 : SoftPalette.slate150, width: 1.0);
                  }

                  Color dayAbbrevColor = isSelected
                      ? SoftPalette.gray50A70
                      : (isHoliday
                          ? (cellIslamicEvent != null
                              ? (isDarkCalendar ? SoftPalette.amber200 : SoftPalette.orange500)
                              : (isDarkCalendar ? SoftPalette.green300 : SoftPalette.green550))
                          : (isDarkCalendar ? SoftPalette.slate350 : SoftPalette.gray350));
                  Color dayNumColor = isSelected
                      ? SoftPalette.gray50
                      : (isHoliday
                          ? (cellIslamicEvent != null
                              ? (isDarkCalendar ? SoftPalette.yellow150 : SoftPalette.orange600)
                              : (isDarkCalendar ? SoftPalette.emerald150 : SoftPalette.green600))
                          : (isDarkCalendar ? SoftPalette.gray50 : SoftPalette.gray900));

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
                                        ? SoftPalette.gray50
                                        : (cellIslamicEvent != null
                                            ? (isDarkCalendar ? SoftPalette.amber200 : SoftPalette.orange500)
                                            : SoftPalette.green550),
                                  ),
                                ),
                              )
                            else if (isPtm)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  'PTM',
                                  style: TextStyle(fontSize: 8, fontWeight: FontWeight.w900, color: isSelected ? SoftPalette.gray50 : context.adapt(SoftPalette.red500)),
                                ),
                              ),
                            if (isToday)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Container(
                                  width: 5,
                                  height: 5,
                                  decoration: BoxDecoration(
                                    color: isSelected ? SoftPalette.gray50 : (isHoliday ? context.adapt(SoftPalette.green550) : context.adapt(SoftPalette.teal550)),
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
    final isDesktop = GBreakpoint.isDesktop(context);
    final isMobile = GBreakpoint.isMobile(context);
    final isReadOnly = !_canSaveData();
    int present = 0, leave = 0, absent = 0, replied = 0, lateCount = 0;
    for (var s in students) {
      final sId = s['id'] ?? '';
      final log = _localChanges[sId] ?? _safeMap(logData[sId]);
      final att = log['attendance'] ?? 'absent';
      if (att == 'present') {
        present++;
        if (log['isLate'] == true || log['timing'] == 'late') {
          lateCount++;
        }
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
    final dateTextColor = isDarkStats ? SoftPalette.gray50 : SoftPalette.gray900;

    // Date & stats section
    final statsRow = _buildAttendanceStatsRow(
      context,
      present: present,
      lateCount: lateCount,
      leave: leave,
      absent: absent,
      replied: replied,
    );

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
          statsRow,
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
          statsRow,
        ],
      );
    }

    // Actions & Legends section
    final c = context.comfort;
    Widget actionsAndLegendsWidget;
    if (isDesktop) {
      actionsAndLegendsWidget = Row(
        children: [
          _efficiencyButton(
            label: context.l.allPresent,
            icon: GIcons.checkCircle,
            color: c.success,
            isSelected: _allPresentToggled,
            onTap: isReadOnly ? null : () {
              setState(() {
                _allPresentToggled = !_allPresentToggled;
                for (var s in students) {
                  final sId = s['id'] ?? '';
                  final log = _safeMap(logData[sId]);
                  final currentAtt = _localChanges[sId]?['attendance'] ?? log['attendance'];
                  if (currentAtt != 'leave' && currentAtt != 'leave_requested') {
                    _updateAttendanceSilent(sId, _allPresentToggled ? 'present' : 'absent');
                  }
                }
              });
            },
          ),
          const SizedBox(width: 8),
          _efficiencyButton(
            label: context.l.allUniform,
            icon: GIcons.check,
            color: c.info,
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
            icon: GIcons.whatsapp,
            color: c.warning,
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
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(color: c.onBrand, strokeWidth: 1.5),
                  )
                : const Icon(GIcons.save, size: 16),
            label: Text(context.l.saveChanges, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(
              backgroundColor: c.brand,
              foregroundColor: c.onBrand,
              disabledBackgroundColor: c.surfaceSunken,
              disabledForegroundColor: c.textMuted,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: () => _showDailyReportDialog(config, students, logData),
            icon: FaIcon(FontAwesomeIcons.whatsapp, color: c.success, size: 16),
            label: Text(
              context.isUrdu ? 'روزانہ گروپ رپورٹ' : 'Daily Group Report',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: c.textPrimary),
            ),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: c.border),
              backgroundColor: c.surface,
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
                icon: GIcons.checkCircle,
                color: c.success,
                isSelected: _allPresentToggled,
                onTap: isReadOnly ? null : () {
                  setState(() {
                    _allPresentToggled = !_allPresentToggled;
                    for (var s in students) {
                      final sId = s['id'] ?? '';
                      final log = _safeMap(logData[sId]);
                      final currentAtt = _localChanges[sId]?['attendance'] ?? log['attendance'];
                      if (currentAtt != 'leave' && currentAtt != 'leave_requested') {
                        _updateAttendanceSilent(sId, _allPresentToggled ? 'present' : 'absent');
                      }
                    }
                  });
                },
              ),
              _efficiencyButton(
                label: context.l.allUniform,
                icon: GIcons.check,
                color: c.info,
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
                icon: GIcons.whatsapp,
                color: c.warning,
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
                icon: GIcons.share,
                color: c.brand,
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
    final c = context.comfort;
    final isDisabled = onTap == null;
    final bg = isDisabled
        ? c.surfaceSunken
        : (isSelected ? color : color.withValues(alpha: 0.08));
    final border = isDisabled
        ? c.border
        : (isSelected ? color : color.withValues(alpha: 0.25));
    final fg = isDisabled
        ? c.textMuted
        : (isSelected ? SoftPalette.gray50 : color);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: fg),
            const SizedBox(width: 8),
            Text(
              label,
              style: context.urduStyle(
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.bold,
                  color: fg,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAttendanceStatsRow(
    BuildContext context, {
    required int present,
    required int lateCount,
    required int leave,
    required int absent,
    required int replied,
  }) {
    final c = context.comfort;
    final isUrdu = context.isUrdu;

    Widget presentWidget;
    if (lateCount > 0) {
      final lateLabel = isUrdu ? ' ($lateCount ${context.l.late})' : ' ($lateCount ${context.l.late})';
      presentWidget = Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '${context.l.present}: $present',
              style: TextStyle(color: c.success, fontWeight: FontWeight.bold, fontSize: 14),
            ),
            TextSpan(
              text: lateLabel,
              style: TextStyle(color: c.warning, fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ],
        ),
      );
    } else {
      presentWidget = _statText('${context.l.present}: $present', c.success);
    }

    return Wrap(
      spacing: 12,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        presentWidget,
        _statText('${context.l.leave}: $leave', c.warning),
        _statText('${context.l.absent}: $absent', c.danger),
        _statText(isUrdu ? 'جوابات: $replied' : 'Replied: $replied', c.info),
      ],
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
        color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
        border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.slate150),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: (selectedValue == null || selectedValue == 0) ? null : selectedValue,
          hint: Text('-', style: TextStyle(color: isDark ? SoftPalette.slate550 : SoftPalette.gray300, fontSize: 12)),
          icon: Icon(Icons.arrow_drop_down, size: 16, color: context.adapt(SoftPalette.teal550)),
          isDense: true,
          isExpanded: true,
          dropdownColor: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
          style: TextStyle(fontSize: 12, color: isDark ? SoftPalette.gray50 : SoftPalette.gray900, fontWeight: FontWeight.bold),
          items: [
            for (int i = 1; i <= 30; i++)
              DropdownMenuItem(
                value: i,
                child: Text('$i', style: TextStyle(fontWeight: FontWeight.bold, color: isDark ? SoftPalette.gray50 : SoftPalette.gray900)),
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
        color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
        border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.slate150),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: (selectedValue == null || selectedValue.isEmpty || selectedValue == '-') ? null : selectedValue,
          hint: Text('-', style: TextStyle(color: isDark ? SoftPalette.slate550 : SoftPalette.gray300, fontSize: 12)),
          icon: Icon(Icons.arrow_drop_down, size: 16, color: context.adapt(SoftPalette.teal550)),
          isDense: true,
          isExpanded: true,
          dropdownColor: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
          style: TextStyle(fontSize: 12, color: isDark ? SoftPalette.gray50 : SoftPalette.gray900, fontWeight: FontWeight.bold),
          items: [
            DropdownMenuItem(value: '1/4', child: Text(context.isUrdu ? 'پاؤ' : 'Pao', style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900))),
            DropdownMenuItem(value: '1/2', child: Text(context.isUrdu ? 'نصف' : 'Nisf', style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900))),
            DropdownMenuItem(value: '3/4', child: Text(context.isUrdu ? 'ثلاثہ' : 'Salasa', style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900))),
            DropdownMenuItem(value: '1', child: Text(context.isUrdu ? 'پارہ' : 'Para', style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900))),
            DropdownMenuItem(value: 'nahi_sunaya', child: Text(context.isUrdu ? 'نہیں سنایا' : 'Nahi Sunaya', style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900))),
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
              leading: Icon(Icons.camera_alt_outlined, color: ctx.adapt(SoftPalette.teal550)),
              title: Text(
                context.isUrdu ? 'کیمرہ سے تصویر لیں' : 'Take Photo with Camera',
                style: context.urduStyle(),
              ),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: Icon(Icons.photo_library_outlined, color: ctx.adapt(SoftPalette.teal550)),
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

      final studentCache = MadrassaLocalStorage.getStudentCached(_effectiveBranch, studentId) ?? <String, dynamic>{'id': studentId};
      studentCache['photoUrl'] = b64;
      studentCache['photoBase64'] = b64;
      studentCache['studentPhotoBase64'] = b64;
      await MadrassaLocalStorage.cacheStudent(_effectiveBranch, studentId, studentCache);

      // Broadcast via LAN
      try {
        RealtimeManager().sendMessage(RealtimeEvents.payload(
          type: RealtimeEvents.saveMadrassaStudent,
          data: studentCache,
          branchId: _effectiveBranch,
        ));
      } catch (_) {}

      // Always enqueue sync
      await LocalStorageService.enqueueSync({
        'type': 'save_madrassa_student',
        'branchId': _effectiveBranch,
        'studentId': studentId,
        'data': studentCache,
      });
      unawaited(SyncService().triggerUpload());

      if (mounted) {
        setState(() {
          _uploadStates[studentId] = PhotoUploadStatus.success;
        });
        AppToast.showSnackBar(context, 
          SnackBar(
            content: Text(
              context.isUrdu ? 'تصویر کامیابی کے ساتھ اپ ڈیٹ ہو گئی' : 'Student photo updated successfully!',
              style: context.urduStyle(),
            ),
            backgroundColor: SoftPalette.teal550,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _uploadStates[studentId] = PhotoUploadStatus.error);
      AppToast.showSnackBar(context, 
        SnackBar(content: Text('Failed to update photo: $e'), backgroundColor: SoftPalette.red400),
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
                borderSide: BorderSide(color: dContext.adapt(SoftPalette.teal550), width: 2),
              ),
            ),
            onSubmitted: (val) {
              final newLines = int.tryParse(val.trim());
              if (newLines != null && newLines >= 0) {
                final clamped = newLines.clamp(0, 8640);
                if (newLines > 8640) {
                  AppToast.showSnackBar(context, 
                    SnackBar(content: Text(context.isUrdu ? 'زیادہ سے زیادہ 8640 لائنیں (حفظ مکمل)' : 'Maximum 8640 lines (Hifz complete)'), backgroundColor: SoftPalette.amber300),
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
                style: context.urduStyle(style: TextStyle(color: dContext.adapt(SoftPalette.gray350))),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: SoftPalette.teal550,
                foregroundColor: SoftPalette.gray50,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () {
                final newLines = int.tryParse(textCtrl.text.trim());
                if (newLines != null && newLines >= 0) {
                  final clamped = newLines.clamp(0, 8640);
                  if (newLines > 8640) {
                    AppToast.showSnackBar(context, 
                      SnackBar(content: Text(context.isUrdu ? 'زیادہ سے زیادہ 8640 لائنیں (حفظ مکمل)' : 'Maximum 8640 lines (Hifz complete)'), backgroundColor: SoftPalette.amber300),
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
      AppToast.showSnackBar(context, 
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
      final isLate = currentLog['isLate'] == true || currentLog['timing'] == 'late';
      final arrivalTime = currentLog['arrivalTime']?.toString();
      if (isLate) {
        if (arrivalTime != null && arrivalTime.isNotEmpty) {
          attTextEn = 'Present (Late - $arrivalTime)';
          attTextUr = 'حاضر (دیر سے آمد - $arrivalTime)';
        } else {
          attTextEn = 'Present (Late)';
          attTextUr = 'حاضر (دیر سے آمد)';
        }
      } else {
        attTextEn = 'Present (On Time)';
        attTextUr = 'حاضر (بروقت)';
      }
    } else if (att == 'leave') {
      attTextEn = 'On Leave';
      attTextUr = 'رخصت';
    }

    final dateStr = DateFormat('dd-MM-yyyy').format(_selectedDate);
    final studentName = studentData['name'] ?? '—';
    final rollNumber = studentData['rollNumber'] ?? '?';

    // Check student program
    final isNazraOnly = LocalStorageService.isMadrassaNazraOnly(_effectiveBranch);
    final isStudentNazra = isNazraOnly ||
        (studentData['isNazra'] == true) ||
        (studentData['program']?.toString().toLowerCase() == 'nazra') ||
        (studentData['class']?.toString().toLowerCase() == 'nazra');
    final bool logQaidaCompExplicit = currentLog['qaidaCompleted'] == true;
    final bool logQaidaReverted = currentLog['qaidaCompleted'] == false;
    final bool isQaidaCompleted = !logQaidaReverted && (
        studentData['qaidaCompleted'] == true ||
        logQaidaCompExplicit ||
        currentLog['qaidaSabak'] == 'completed'
    );
    final int rukuParaVal = currentLog['rukuPara'] is int ? currentLog['rukuPara'] as int : (int.tryParse(currentLog['rukuPara']?.toString() ?? '') ?? 0);
    final rukuVal = currentLog['ruku']?.toString();
    final qaidaVal = currentLog['qaidaSabak']?.toString();

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

    String rukuMsg = 'No test today';
    if (rukuVal != null && rukuVal.isNotEmpty && rukuVal != '-') {
      if (rukuVal == 'nahi_sunaya') {
        rukuMsg = 'نہیں سنایا';
      } else if (rukuParaVal > 0) {
        rukuMsg = 'Para $rukuParaVal ($rukuVal Ruku) / پارہ $rukuParaVal ($rukuVal رُكوع)';
      } else {
        rukuMsg = '$rukuVal Ruku / رُكوع';
      }
    }

    String qaidaMsg = isQaidaCompleted
        ? 'Completed / مکمل ✅'
        : ((qaidaVal != null && qaidaVal.isNotEmpty && qaidaVal != '-')
            ? (qaidaVal == 'completed' ? 'Completed / مکمل ✅' : 'Lesson $qaidaVal / سبق $qaidaVal')
            : 'No lesson recorded');

    final String uniformMsg = uni ? 'Clean / صاف' : 'Incomplete / Not Clean / نامکمل یا صاف نہیں';

    final String progressContent = isStudentNazra
        ? '• *Sabak:* $sabakMsg\n• *Ruku / رُكوع:* $rukuMsg\n• *Qaida / قاعدہ:* $qaidaMsg\n'
        : '• *Sabak:* $sabakMsg\n• *Sabki:* $sabkiMsg\n• *Manzil:* $manzilMsg\n';

    final String message = 
        '*Gulzar Madina Welfare Foundation (Madrassa)*\n'
        '*Daily Progress Report | روزانہ کارکردگی رپورٹ*\n'
        '--------------------------------------------\n'
        '*Date / تاریخ:* $dateStr\n'
        '*Student / طالب علم:*          $studentName (Roll: $rollNumber)\n'
        '*Attendance / حاضری:*     $attTextEn / $attTextUr\n'
        '${att == 'present' ? '*Uniform / لباس:*               $uniformMsg\n' : ''}'
        '\n'
        '${att == 'present' ? '*Daily Progress / روزانہ کارکردگی:*\n$progressContent' : ''}'
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
        AppToast.showSnackBar(context, 
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

      final isNazraOnly = LocalStorageService.isMadrassaNazraOnly(_effectiveBranch);
      final isNazraStudent = isNazraOnly ||
          (s['isNazra'] == true) ||
          (s['program']?.toString().toLowerCase() == 'nazra') ||
          (s['class']?.toString().toLowerCase() == 'nazra');

      String attText = 'Absent / غیر حاضر';
      if (att == 'present') {
        present++;
        final isLate = log['isLate'] == true || log['timing'] == 'late';
        final arrivalTime = log['arrivalTime']?.toString();
        if (isLate) {
          attText = (arrivalTime != null && arrivalTime.isNotEmpty)
              ? 'Present (Late - $arrivalTime) / حاضر (دیر سے آمد - $arrivalTime)'
              : 'Present (Late) / حاضر (دیر سے آمد)';
        } else {
          attText = 'Present (On Time) / حاضر (بروقت)';
        }
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

        if (isNazraStudent) {
          final int rukuPara = log['rukuPara'] is int ? log['rukuPara'] as int : (int.tryParse(log['rukuPara']?.toString() ?? '') ?? 0);
          final ruku = log['ruku']?.toString();
          if (ruku != null && ruku.isNotEmpty && ruku != '-') {
            if (ruku == 'nahi_sunaya') {
              progressParts.add('Ruku: نہیں سنایا');
            } else if (rukuPara > 0) {
              progressParts.add('Ruku: Para $rukuPara ($ruku)');
            } else {
              progressParts.add('Ruku: $ruku');
            }
          }
          final bool isQComp = s['qaidaCompleted'] == true || log['qaidaCompleted'] == true || log['qaidaSabak'] == 'completed';
          if (isQComp) {
            progressParts.add('Qaida: Completed / مکمل ✅');
          } else if (log['qaidaSabak'] != null && log['qaidaSabak'].toString().isNotEmpty && log['qaidaSabak'].toString() != '-') {
            progressParts.add('Qaida: Lesson ${log['qaidaSabak']}');
          }
        } else {
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
              Icon(Icons.share, color: ctx.adapt(SoftPalette.teal550)),
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
                  style: context.urduStyle(style: TextStyle(fontSize: 13, color: ctx.adapt(SoftPalette.gray350))),
                ),
                const SizedBox(height: 12),
                Container(
                  height: 200,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: ctx.adapt(SoftPalette.gray100),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: ctx.adapt(SoftPalette.gray150)),
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
                    AppToast.showSnackBar(context, 
                      SnackBar(content: Text('Error generating PDF: $e')),
                    );
                  }
                }
              },
              icon: Icon(Icons.picture_as_pdf, color: ctx.adapt(SoftPalette.red400)),
              label: Text(
                context.isUrdu ? 'پی ڈی ایف رپورٹ' : 'PDF Report',
                style: context.urduStyle(style: TextStyle(color: ctx.adapt(SoftPalette.red400), fontWeight: FontWeight.bold)),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: ctx.adapt(SoftPalette.red400)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: context.isUrdu ? 'ٹیکسٹ کاپی کریں' : 'Copy Text',
                  icon: Icon(Icons.copy, color: ctx.adapt(SoftPalette.teal550)),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: reportText));
                    AppToast.showSnackBar(context, 
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
                        AppToast.showSnackBar(context, 
                          const SnackBar(content: Text('Could not launch WhatsApp.')),
                        );
                      }
                    }
                  },
                  icon: const FaIcon(FontAwesomeIcons.whatsapp, color: SoftPalette.gray50, size: 16),
                  label: Text(
                    context.isUrdu ? 'واٹس ایپ پر بھیجیں' : 'Send WhatsApp',
                    style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: SoftPalette.green350,
                    foregroundColor: SoftPalette.gray50,
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
              backgroundColor: SoftPalette.teal550.withValues(alpha: 0.8),
              foregroundColor: SoftPalette.gray50,
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
                      child: CircularProgressIndicator(color: SoftPalette.gray50, strokeWidth: 2),
                    )
                  : const Icon(Icons.save),
              label: Text(context.l.saveChanges),
              style: ElevatedButton.styleFrom(
                backgroundColor: SoftPalette.teal550, // Teal
                foregroundColor: SoftPalette.gray50,
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
        color: context.adapt(SoftPalette.slate100),
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
            activeColor: SoftPalette.emerald350, // Emerald green
            onTap: onChanged == null ? null : () => onChanged!('present'),
          ),
          if (showLeaveSegment) ...[
            const SizedBox(width: 4),
            _buildSegment(
              context: context,
              label: 'L',
              isSelected: value == 'leave' || value == 'leave_requested',
              activeColor: SoftPalette.amber300, // Orange/yellow
              onTap: (onChanged == null || !canUseLeave) ? null : () => onChanged!('leave'),
            ),
          ],
          const SizedBox(width: 4),
          _buildSegment(
            context: context,
            label: 'A',
            isSelected: value == 'absent',
            activeColor: SoftPalette.red400, // Red
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
              style: TextStyle(
                fontSize: 10,
                color: context.adapt(SoftPalette.slate400),
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
            color: isSelected ? SoftPalette.gray50 : context.adapt(SoftPalette.slate550),
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

class SegmentedTimingToggle extends StatelessWidget {
  final bool isLate;
  final String? arrivalTime;
  final bool isEnabled;
  final ValueChanged<bool>? onChanged;
  final VoidCallback? onPickTime;
  final bool showLabel;
  final bool isCompact;

  const SegmentedTimingToggle({
    super.key,
    required this.isLate,
    this.arrivalTime,
    this.isEnabled = true,
    this.onChanged,
    this.onPickTime,
    this.showLabel = true,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    final isUrdu = context.isUrdu;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final height = isCompact ? 30.0 : 36.0;
    final borderRadius = BorderRadius.circular(height / 2);
    final itemPadding = isCompact
        ? const EdgeInsets.symmetric(horizontal: 8, vertical: 2)
        : const EdgeInsets.symmetric(horizontal: 10, vertical: 4);
    final fontSize = isCompact ? 10.5 : 11.5;
    final iconSize = isCompact ? 11.0 : 13.0;

    Widget toggle = Tooltip(
      message: isEnabled
          ? ''
          : (isUrdu ? 'صرف حاضر طلباء کے لیے دستیاب ہے' : 'Only available when student is marked Present'),
      child: Opacity(
        opacity: isEnabled ? 1.0 : 0.42,
        child: Container(
          height: height,
          decoration: BoxDecoration(
            color: context.adapt(SoftPalette.slate100),
            borderRadius: borderRadius,
            border: Border.all(
              color: isDark ? SoftPalette.slate700 : SoftPalette.slate200,
              width: 0.8,
            ),
          ),
          padding: const EdgeInsets.all(2.5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildSegment(
                context: context,
                label: context.l.onTime,
                icon: Icons.check_circle_outline_rounded,
                isSelected: !isLate,
                activeColor: SoftPalette.emerald350,
                isEnabled: isEnabled,
                padding: itemPadding,
                fontSize: fontSize,
                iconSize: iconSize,
                borderRadius: borderRadius,
                onTap: (isEnabled && onChanged != null) ? () => onChanged!(false) : null,
              ),
              const SizedBox(width: 3),
              _buildSegment(
                context: context,
                label: context.l.late,
                icon: Icons.access_time_rounded,
                isSelected: isLate,
                activeColor: SoftPalette.amber400,
                isEnabled: isEnabled,
                padding: itemPadding,
                fontSize: fontSize,
                iconSize: iconSize,
                borderRadius: borderRadius,
                onTap: (isEnabled && onChanged != null) ? () => onChanged!(true) : null,
              ),
            ],
          ),
        ),
      ),
    );

    final bool hasTime = isLate && arrivalTime != null && arrivalTime!.isNotEmpty;

    Widget timeChip = Tooltip(
      message: isUrdu ? 'آمد کا وقت تبدیل کریں' : 'Click to change arrival time',
      child: InkWell(
        onTap: isEnabled ? onPickTime : null,
        borderRadius: borderRadius,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height: height,
          padding: isCompact
              ? const EdgeInsets.symmetric(horizontal: 7, vertical: 2)
              : const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          decoration: BoxDecoration(
            color: context.adapt(SoftPalette.amber300).withValues(alpha: 0.12),
            borderRadius: borderRadius,
            border: Border.all(
              color: context.adapt(SoftPalette.amber300).withValues(alpha: 0.6),
              width: 0.8,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.access_time_filled_rounded, size: iconSize, color: context.adapt(SoftPalette.amber400)),
              const SizedBox(width: 4),
              Text(
                arrivalTime ?? '',
                style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: FontWeight.bold,
                  color: context.adapt(SoftPalette.amber400),
                ),
              ),
              if (onPickTime != null && isEnabled) ...[
                const SizedBox(width: 3),
                Icon(Icons.edit_rounded, size: iconSize - 1, color: context.adapt(SoftPalette.amber400)),
              ],
            ],
          ),
        ),
      ),
    );

    Widget toggleWithTime = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        toggle,
        if (hasTime && showLabel) ...[
          const SizedBox(width: 6),
          timeChip,
        ],
      ],
    );

    if (showLabel) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            context.l.timing,
            style: context.urduStyle(
              style: TextStyle(
                fontSize: 10,
                color: context.adapt(SoftPalette.slate400),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 2),
          toggleWithTime,
        ],
      );
    }

    return toggle;
  }

  Widget _buildSegment({
    required BuildContext context,
    required String label,
    required IconData icon,
    required bool isSelected,
    required Color activeColor,
    required bool isEnabled,
    required EdgeInsets padding,
    required double fontSize,
    required double iconSize,
    required BorderRadius borderRadius,
    required VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeInOut,
        padding: padding,
        decoration: BoxDecoration(
          color: isSelected ? activeColor : Colors.transparent,
          borderRadius: borderRadius,
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: activeColor.withValues(alpha: 0.3),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  )
                ]
              : null,
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: iconSize,
              color: isSelected
                  ? SoftPalette.gray50
                  : context.adapt(SoftPalette.slate550),
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: context.urduStyle(
                style: TextStyle(
                  color: isSelected ? SoftPalette.gray50 : context.adapt(SoftPalette.slate550),
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                  fontSize: fontSize,
                ),
              ),
            ),
          ],
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
  final Function(String sId, String newAtt) onUpdateAttendance;
  final void Function(String sId, {required bool approve}) onDecideLeave;
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
    required this.onUpdateAttendance,
    required this.onDecideLeave,
    this.onUpdateSabak,
    required this.onPickPhoto,
    required this.onSendWhatsApp,
    required this.onShowCustomLines,
    required this.buildParaDropdown,
    required this.buildRatioDropdown,
  });

  Future<void> _selectArrivalTime(BuildContext context, String sId, String? currentArrivalTime) async {
    final initial = _parseTimeOfDay(currentArrivalTime);
    final picked = await showTimePicker(
      context: context,
      initialTime: initial,
      helpText: context.isUrdu ? 'طالب علم کی آمد کا وقت' : 'Student Arrival Time',
      cancelText: context.isUrdu ? 'منسوخ' : 'Cancel',
      confirmText: context.isUrdu ? 'محفوظ کریں' : 'Set Time',
    );
    if (picked != null) {
      final now = DateTime.now();
      final dt = DateTime(now.year, now.month, now.day, picked.hour, picked.minute);
      final formatted = DateFormat('hh:mm a').format(dt);
      onUpdateLocal(sId, 'arrivalTime', formatted);
      onUpdateLocal(sId, 'isLate', true);
      onUpdateLocal(sId, 'timing', 'late');
    }
  }

  static TimeOfDay _parseTimeOfDay(String? timeStr) {
    if (timeStr == null || timeStr.trim().isEmpty) return TimeOfDay.now();
    try {
      final dt = DateFormat('hh:mm a').parse(timeStr.trim());
      return TimeOfDay(hour: dt.hour, minute: dt.minute);
    } catch (_) {
      try {
        final parts = timeStr.trim().split(':');
        if (parts.length >= 2) {
          final h = int.tryParse(parts[0]) ?? 12;
          final m = int.tryParse(parts[1].split(' ')[0]) ?? 0;
          final isPm = timeStr.toLowerCase().contains('pm');
          return TimeOfDay(hour: isPm && h < 12 ? h + 12 : h, minute: m);
        }
      } catch (_) {}
      return TimeOfDay.now();
    }
  }

  Widget _actionButton(String label, Color color, VoidCallback onTap) {
    return ElevatedButton(
      onPressed: onTap,
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: SoftPalette.gray50,
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
          color: active ? color : (isDark ? SoftPalette.slate700 : SoftPalette.gray150),
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: active ? SoftPalette.gray50 : (isDark ? SoftPalette.slate350 : SoftPalette.gray350),
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  Widget _switchCol(BuildContext context, String label, bool val, ValueChanged<bool>? onChanged, {Color? activeColor, Color? trackColor, bool isDark = false}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: context.urduStyle(style: TextStyle(fontSize: 10, color: isDark ? SoftPalette.slate350 : SoftPalette.slate400, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 2),
        Transform.scale(
          scale: 0.88,
          child: Switch(
            value: val,
            onChanged: onChanged,
            activeThumbColor: activeColor ?? SoftPalette.sky400,
            activeTrackColor: trackColor ?? (activeColor ?? SoftPalette.sky400).withValues(alpha: 0.4),
            inactiveThumbColor: isDark ? SoftPalette.slate550 : SoftPalette.gray300,
            inactiveTrackColor: isDark ? SoftPalette.slate700 : SoftPalette.gray150,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
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
          style: context.urduStyle(style: TextStyle(fontSize: 11, color: isDark ? SoftPalette.slate350 : SoftPalette.slate600, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            IconButton(
              icon: Icon(Icons.remove_circle_outline, color: context.adapt(SoftPalette.red500), size: 20),
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
                    color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                    border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.slate150),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '$lines',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: isDark ? SoftPalette.gray50 : SoftPalette.gray900),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: Icon(Icons.add_circle_outline, color: (isReadOnly || lines >= 8640) ? context.adapt(SoftPalette.gray350) : context.adapt(SoftPalette.green550), size: 20),
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
          style: context.urduStyle(style: TextStyle(fontSize: 11, color: isDark ? SoftPalette.slate350 : SoftPalette.slate600, fontWeight: FontWeight.bold)),
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
          style: context.urduStyle(style: TextStyle(fontSize: 11, color: isDark ? SoftPalette.slate350 : SoftPalette.slate600, fontWeight: FontWeight.bold)),
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

  Widget _buildRukuField(BuildContext context, String sId, int rukuPara, dynamic currentRuku, {bool isDark = false}) {
    final rukuStr = (currentRuku == null || currentRuku.toString() == '0' || currentRuku.toString() == '-')
        ? null
        : currentRuku.toString();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.isUrdu ? 'رُكوع (پارہ / رُكوع)' : 'Ruku (Para / Ruku)',
          style: context.urduStyle(
            style: TextStyle(
              fontSize: 11,
              color: isDark ? SoftPalette.slate350 : SoftPalette.slate600,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              flex: 5,
              child: buildParaDropdown(context, rukuPara, !isReadOnly, isReadOnly ? null : (val) {
                onUpdateLocal(sId, 'rukuPara', val ?? 0);
              }),
            ),
            const SizedBox(width: 6),
            Expanded(
              flex: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                height: 36,
                decoration: BoxDecoration(
                  color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                  border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.slate150),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: rukuStr,
                    hint: Text(
                      '-',
                      style: TextStyle(color: isDark ? SoftPalette.slate550 : SoftPalette.gray300, fontSize: 12),
                    ),
                    icon: Icon(Icons.arrow_drop_down, size: 16, color: context.adapt(SoftPalette.teal550)),
                    isDense: true,
                    isExpanded: true,
                    dropdownColor: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
                    style: TextStyle(fontSize: 12, color: isDark ? SoftPalette.gray50 : SoftPalette.gray900, fontWeight: FontWeight.bold),
                    items: [
                      DropdownMenuItem<String>(
                        value: null,
                        child: Text(
                          '-',
                          style: TextStyle(color: isDark ? SoftPalette.slate550 : SoftPalette.gray350),
                        ),
                      ),
                      DropdownMenuItem<String>(
                        value: 'nahi_sunaya',
                        child: Text(
                          context.isUrdu ? 'نہیں سنایا' : 'Nahi Sunaya',
                          style: TextStyle(color: context.adapt(SoftPalette.red500)),
                        ),
                      ),
                      for (int i = 1; i <= 40; i++)
                        DropdownMenuItem<String>(
                          value: '$i',
                          child: Text(
                            context.isUrdu ? '$i رُكوع' : '$i Ruku',
                            style: TextStyle(fontWeight: FontWeight.bold, color: isDark ? SoftPalette.gray50 : SoftPalette.slate900),
                          ),
                        ),
                    ],
                    onChanged: isReadOnly
                        ? null
                        : (val) {
                            onUpdateLocal(sId, 'ruku', val ?? '-');
                          },
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _showRevertQaidaDialog(BuildContext context, String sId) async {
    String selectedLesson = '21';
    final studentName = student['name'] ?? 'Student';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            final isUrdu = ctx.isUrdu;
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: dialogCtx.adapt(SoftPalette.amber200).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.undo_rounded, color: dialogCtx.adapt(SoftPalette.orange350), size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      isUrdu ? 'قاعدہ تکمیل منسوخ کریں' : 'Revert Qaida Completion',
                      style: ctx.urduStyle(style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isUrdu
                        ? 'کیا آپ $studentName کے لیے قاعدہ کی تکمیل منسوخ کرنا چاہتے ہیں؟ موجودہ تختی / سبق منتخب کریں:'
                        : 'Revert Qaida completion for $studentName back to active learning. Select the current lesson:',
                    style: ctx.urduStyle(style: TextStyle(fontSize: 13, color: dialogCtx.adapt(SoftPalette.gray900A87))),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    isUrdu ? 'سبق / تختی:' : 'Qaida Lesson (1–21):',
                    style: ctx.urduStyle(style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: dialogCtx.adapt(SoftPalette.gray350))),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      border: Border.all(color: dialogCtx.adapt(SoftPalette.gray150)),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: selectedLesson,
                        isExpanded: true,
                        items: [
                          for (int i = 21; i >= 1; i--)
                            DropdownMenuItem<String>(
                              value: '$i',
                              child: Text(
                                isUrdu ? 'سبق $i (تختی $i)' : 'Lesson $i',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                            ),
                        ],
                        onChanged: (val) {
                          if (val != null) {
                            setDialogState(() {
                              selectedLesson = val;
                            });
                          }
                        },
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(isUrdu ? 'منسوخ' : 'Cancel'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: SoftPalette.orange350,
                    foregroundColor: SoftPalette.gray50,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(isUrdu ? 'منسوخ اور محفوظ کریں' : 'Revert & Continue'),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirmed == true) {
      onUpdateLocal(sId, 'qaidaCompleted', false);
      onUpdateLocal(sId, 'qaidaSabak', selectedLesson);
      student['qaidaCompleted'] = false;
      student['qaidaSabak'] = selectedLesson;

      final cached = MadrassaLocalStorage.getStudentCached(branchId, sId);
      if (cached != null) {
        cached['qaidaCompleted'] = false;
        cached['qaidaSabak'] = selectedLesson;
        await MadrassaLocalStorage.cacheStudent(branchId, sId, cached);
        await LocalStorageService.enqueueSync({
          'type': 'save_madrassa_student',
          'branchId': branchId,
          'studentId': sId,
          'data': cached,
        });
        unawaited(SyncService().triggerUpload());
      }

      unawaited(MadrassaAuditService.logAction(
        branchId: branchId,
        editor: 'Teacher',
        role: editorRole,
        type: 'qaida_reverted',
        message: 'Reverted Qaida completed for $studentName to Lesson $selectedLesson',
        studentId: sId,
        studentName: studentName,
      ));

      if (context.mounted) {
        AppToast.showSnackBar(context, 
          SnackBar(
            content: Text(
              context.isUrdu
                  ? '$studentName کے لیے قاعدہ تکمیل منسوخ ہو گئی (سبق $selectedLesson)'
                  : 'Qaida completed reverted for $studentName (Lesson $selectedLesson)',
            ),
            backgroundColor: SoftPalette.orange350,
          ),
        );
      }
    }
  }

  Widget _buildQaidaField(BuildContext context, String sId, bool isQaidaCompleted, dynamic currentQaidaSabak, {bool isDark = false}) {
    if (isQaidaCompleted) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                context.isUrdu ? 'قاعدہ سبق' : 'Qaida Sabak',
                style: context.urduStyle(
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? SoftPalette.slate350 : SoftPalette.slate600,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (!isReadOnly)
                InkWell(
                  onTap: () => _showRevertQaidaDialog(context, sId),
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.undo_rounded, size: 11, color: context.adapt(SoftPalette.orange350)),
                        const SizedBox(width: 2),
                        Text(
                          context.isUrdu ? 'واپس کریں' : 'Revert',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: context.adapt(SoftPalette.orange350),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: isDark ? SoftPalette.emerald700.withValues(alpha: 0.3) : SoftPalette.emerald50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: context.adapt(SoftPalette.emerald350).withValues(alpha: 0.5)),
            ),
            child: Row(
              children: [
                Icon(Icons.check_circle_rounded, color: context.adapt(SoftPalette.emerald350), size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    context.isUrdu ? 'قاعدہ مکمل ✅' : 'Qaida Completed ✅',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      color: context.adapt(SoftPalette.emerald500),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (!isReadOnly)
                  Tooltip(
                    message: context.isUrdu ? 'قاعدہ تکمیل منسوخ کریں' : 'Revert accidental Qaida completion',
                    child: InkWell(
                      onTap: () => _showRevertQaidaDialog(context, sId),
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                        decoration: BoxDecoration(
                          color: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: context.adapt(SoftPalette.amber300).withValues(alpha: 0.5)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.undo_rounded, size: 12, color: context.adapt(SoftPalette.orange350)),
                            const SizedBox(width: 3),
                            Text(
                              context.isUrdu ? 'منسوخ' : 'Revert',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.bold,
                                color: context.adapt(SoftPalette.orange350),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    }

    final currentVal = (currentQaidaSabak == null || currentQaidaSabak.toString() == '0' || currentQaidaSabak.toString() == '-')
        ? null
        : currentQaidaSabak.toString();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.isUrdu ? 'قاعدہ سبق (تختی ۱ تا ۲۱)' : 'Qaida Sabak (1–21)',
          style: context.urduStyle(
            style: TextStyle(
              fontSize: 11,
              color: isDark ? SoftPalette.slate350 : SoftPalette.slate600,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          height: 36,
          decoration: BoxDecoration(
            color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
            border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.slate150),
            borderRadius: BorderRadius.circular(8),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: (currentVal == 'completed') ? null : currentVal,
              hint: Text(
                context.isUrdu ? 'سبق منتخب کریں' : 'Select Lesson',
                style: TextStyle(color: isDark ? SoftPalette.slate550 : SoftPalette.gray300, fontSize: 12),
              ),
              icon: Icon(Icons.arrow_drop_down, size: 16, color: context.adapt(SoftPalette.teal550)),
              isDense: true,
              isExpanded: true,
              dropdownColor: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
              style: TextStyle(fontSize: 12, color: isDark ? SoftPalette.gray50 : SoftPalette.gray900, fontWeight: FontWeight.bold),
              items: [
                DropdownMenuItem<String>(
                  value: null,
                  child: Text(
                    context.isUrdu ? '— کوئی سبق نہیں —' : '— No Lesson —',
                    style: TextStyle(color: isDark ? SoftPalette.slate550 : SoftPalette.gray350),
                  ),
                ),
                for (int i = 1; i <= 21; i++)
                  DropdownMenuItem<String>(
                    value: '$i',
                    child: Text(
                      context.isUrdu ? 'سبق $i (تختی $i)' : 'Lesson $i',
                      style: TextStyle(fontWeight: FontWeight.bold, color: isDark ? SoftPalette.gray50 : SoftPalette.slate900),
                    ),
                  ),
                DropdownMenuItem<String>(
                  value: 'completed',
                  child: Row(
                    children: [
                      Icon(Icons.verified_rounded, color: context.adapt(SoftPalette.emerald350), size: 16),
                      const SizedBox(width: 6),
                      Text(
                        context.isUrdu ? '🏆 مکمل (Completed)' : '🏆 Completed',
                        style: TextStyle(fontWeight: FontWeight.bold, color: context.adapt(SoftPalette.emerald500)),
                      ),
                    ],
                  ),
                ),
              ],
              onChanged: isReadOnly ? null : (val) {
                if (val == 'completed') {
                  onUpdateLocal(sId, 'qaidaSabak', 'completed');
                  onUpdateLocal(sId, 'qaidaCompleted', true);
                  final cached = MadrassaLocalStorage.getStudentCached(branchId, sId);
                  if (cached != null) {
                    cached['qaidaCompleted'] = true;
                    cached['qaidaSabak'] = 'completed';
                    MadrassaLocalStorage.cacheStudent(branchId, sId, cached);
                    LocalStorageService.enqueueSync({
                      'type': 'save_madrassa_student',
                      'branchId': branchId,
                      'studentId': sId,
                      'data': cached,
                    });
                    unawaited(SyncService().triggerUpload());
                  }
                  student['qaidaCompleted'] = true;
                  student['qaidaSabak'] = 'completed';
                } else {
                  onUpdateLocal(sId, 'qaidaSabak', val ?? '-');
                  onUpdateLocal(sId, 'qaidaCompleted', false);
                  student['qaidaCompleted'] = false;
                  student['qaidaSabak'] = val ?? '-';
                  final cached = MadrassaLocalStorage.getStudentCached(branchId, sId);
                  if (cached != null && (cached['qaidaCompleted'] == true || cached['qaidaSabak'] == 'completed')) {
                    cached['qaidaCompleted'] = false;
                    cached['qaidaSabak'] = val ?? '21';
                    MadrassaLocalStorage.cacheStudent(branchId, sId, cached);
                    LocalStorageService.enqueueSync({
                      'type': 'save_madrassa_student',
                      'branchId': branchId,
                      'studentId': sId,
                      'data': cached,
                    });
                    unawaited(SyncService().triggerUpload());
                  }
                }
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLogAvatarFallback(BuildContext context, String name) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: context.adapt(SoftPalette.teal100m),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        name.isNotEmpty ? name[0].toUpperCase() : '?',
        style: TextStyle(color: context.adapt(SoftPalette.teal550), fontWeight: FontWeight.bold, fontSize: 13),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = GBreakpoint.isMobile(context);

    return ValueListenableBuilder<Map<String, dynamic>>(
      valueListenable: logNotifier,
      builder: (context, log, child) {
        final theme = Theme.of(context);
        final isDark = theme.brightness == Brightness.dark || UserThemeService.isDarkMode(editorRole);
        final cardBg = isDark ? SoftPalette.slate800 : SoftPalette.gray50;
        final borderColor = isDark ? SoftPalette.slate700 : SoftPalette.slate150;
        final textPrimary = isDark ? SoftPalette.gray50 : SoftPalette.gray900;
        final textMuted = isDark ? SoftPalette.slate350 : SoftPalette.gray350;

        final studentData = student;
        final sId = student['id'] ?? '';

        final name = studentData['name'] ?? '—';
        final rollNumber = studentData['rollNumber']?.toString() ?? '?';
        final photoUrl = studentData['photoUrl'] ??
            studentData['photo_url'] ??
            studentData['photoBase64'] ??
            studentData['studentPhotoBase64'] ??
            studentData['avatarUrl'] ??
            studentData['imageUrl'] ??
            studentData['profileImage'];

        final att = log['attendance'] ?? 'absent';
        final uni = log['uniform'] ?? false;
        final msg = log['parentReplied'] ?? false;
        final isLate = log['isLate'] == true || log['timing'] == 'late';
        final arrivalTime = log['arrivalTime']?.toString();
        final rawLeaveStatus = log['leaveStatus']?.toString().toLowerCase().trim();
        final leaveStatus = rawLeaveStatus == 'declined'
            ? 'denied'
            : ((rawLeaveStatus == null || rawLeaveStatus.isEmpty)
                ? (att == 'leave' ? 'approved' : 'pending')
                : rawLeaveStatus);
        final isLeaveDecided = leaveStatus == 'approved' ||
            leaveStatus == 'denied' ||
            leaveStatus == 'cancelled';
        final isParentRequested = !isLeaveDecided &&
            (log['isParentRequested'] == true ||
                att == 'leave_requested' ||
                (leaveStatus == 'pending' &&
                    log['leaveReason'] != null &&
                    log['leaveReason'].toString().trim().isNotEmpty));
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
        final int rukuPara = log['rukuPara'] is int ? log['rukuPara'] as int : (int.tryParse(log['rukuPara']?.toString() ?? '') ?? 0);
        final dynamic rukuVal = log['ruku'];
        final bool logQaidaCompExplicit = log['qaidaCompleted'] == true;
        final bool logQaidaReverted = log['qaidaCompleted'] == false;
        final bool isQaidaCompleted = !logQaidaReverted && (
            studentData['qaidaCompleted'] == true ||
            logQaidaCompExplicit ||
            log['qaidaSabak'] == 'completed'
        );
        final dynamic qaidaSabakVal = log['qaidaSabak'] ??
            (studentData['qaidaSabak'] == 'completed' ? '21' : studentData['qaidaSabak']);

        Widget avatarWidget;
        if (uploadStatus == PhotoUploadStatus.uploading) {
          avatarWidget = SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(strokeWidth: 2, color: context.adapt(SoftPalette.teal550)),
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
                errorBuilder: (_, __, ___) => _buildLogAvatarFallback(context, name),
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
                errorBuilder: (_, __, ___) => _buildLogAvatarFallback(context, name),
              ),
            );
          } else {
            avatarWidget = _buildLogAvatarFallback(context, name);
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
                          icon: const Icon(Icons.close, color: SoftPalette.gray50, size: 28),
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
                          foregroundColor: SoftPalette.gray50,
                          backgroundColor: SoftPalette.gray900.withValues(alpha: 0.5),
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
              color: context.adapt(SoftPalette.green100m),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: context.adapt(SoftPalette.green550), width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.stars_rounded, color: context.adapt(SoftPalette.amber200), size: 12),
                const SizedBox(width: 3),
                Text(
                  context.isUrdu ? 'حفظ مکمل! 🎉' : 'Hifz Complete! 🎉',
                  style: TextStyle(color: context.adapt(SoftPalette.green550), fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          );
        } else if (lines >= 8000) {
          hifzBadge = Container(
            margin: const EdgeInsets.only(left: 6, right: 6),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: context.adapt(SoftPalette.amber100m),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: context.adapt(SoftPalette.amber300), width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.auto_awesome, color: context.adapt(SoftPalette.amber300), size: 12),
                const SizedBox(width: 3),
                Text(
                  context.isUrdu ? 'حفظ مکمل ہونے والا ہے! 🌟' : 'Nearing Hifz! 🌟',
                  style: TextStyle(color: context.adapt(SoftPalette.amber300), fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          );
        }

        final isNazraOnly = LocalStorageService.isMadrassaNazraOnly(branchId);
        final isStudentNazra = isNazraOnly ||
            (student['isNazra'] == true) ||
            (student['program']?.toString().toLowerCase() == 'nazra') ||
            (student['class']?.toString().toLowerCase() == 'nazra');
        final genderStr = (student['gender'] ?? '').toString().toLowerCase().trim();
        final isFemale = genderStr == 'female' || genderStr == 'girl';
        final sessionStr = (student['session'] ?? 'morning').toString().toLowerCase().trim();

        final List<Widget> badgeWidgets = [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4.5, vertical: 1.5),
            decoration: BoxDecoration(
              color: isFemale ? context.adapt(SoftPalette.red500).withValues(alpha: 0.12) : context.adapt(SoftPalette.blue400).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              isFemale ? '👧 Girl' : '👦 Boy',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.bold,
                color: isFemale ? context.adapt(SoftPalette.pink550) : context.adapt(SoftPalette.blue500),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4.5, vertical: 1.5),
            decoration: BoxDecoration(
              color: context.adapt(SoftPalette.teal550).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              sessionStr == 'morning'
                  ? '☀️ M'
                  : (sessionStr == 'evening' ? '🌅 E' : '🌙 N'),
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.bold,
                color: context.adapt(SoftPalette.teal550),
              ),
            ),
          ),
          if (!isNazraOnly)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4.5, vertical: 1.5),
              decoration: BoxDecoration(
                color: isStudentNazra
                    ? context.adapt(SoftPalette.teal500).withValues(alpha: 0.12)
                    : context.adapt(SoftPalette.violet550).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                isStudentNazra ? '📖 Nazra' : '🕋 Hifz',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: isStudentNazra ? context.adapt(SoftPalette.teal550) : context.adapt(SoftPalette.violet550),
                ),
              ),
            ),
          if (isStudentNazra && isQaidaCompleted)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4.5, vertical: 1.5),
              decoration: BoxDecoration(
                color: context.adapt(SoftPalette.emerald350).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '✅ قاعدہ مکمل',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: context.adapt(SoftPalette.emerald500),
                ),
              ),
            ),
          if (hifzBadge != null && !isStudentNazra) hifzBadge,
          if (att == 'present' && isLate)
            Tooltip(
              message: context.isUrdu ? 'آمد کا وقت تبدیل کریں' : 'Click to change arrival time',
              child: InkWell(
                onTap: isReadOnly ? null : () => _selectArrivalTime(context, sId, arrivalTime),
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4.5, vertical: 1.5),
                  decoration: BoxDecoration(
                    color: context.comfort.warning.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: context.comfort.warning.withValues(alpha: 0.4), width: 0.8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(GIcons.time, size: 9, color: context.comfort.warning),
                      const SizedBox(width: 2.5),
                      Text(
                        (arrivalTime != null && arrivalTime.isNotEmpty)
                            ? (context.isUrdu ? 'تاخیر ($arrivalTime)' : 'Late ($arrivalTime)')
                            : (context.isUrdu ? 'تاخیر' : 'Late'),
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: context.comfort.warning,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ];

        Widget genderSessionBadges = Wrap(
          spacing: 4,
          runSpacing: 3,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: badgeWidgets,
        );

        Widget topRow = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 30,
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  rollNumber,
                  style: TextStyle(color: textMuted, fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ),
            ),
            avatarWidget,
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    style: context.urduStyle(
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: textPrimary,
                      ),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  genderSessionBadges,
                ],
              ),
            ),
            const SizedBox(width: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: FaIcon(FontAwesomeIcons.whatsapp, color: context.adapt(SoftPalette.green350), size: 19),
                  onPressed: () => onSendWhatsApp(student, log),
                  tooltip: 'Send WhatsApp report',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                ),
                if (isPtmDay) ...[
                  const SizedBox(width: 6),
                  _attButton('J', log['ptm'] == true, SoftPalette.green550, isReadOnly ? () {} : () => onUpdateLocal(sId, 'ptm', true), isDark: isDark),
                  const SizedBox(width: 4),
                  _attButton('M', log['ptm'] == false, SoftPalette.red500, isReadOnly ? () {} : () => onUpdateLocal(sId, 'ptm', false), isDark: isDark),
                ],
              ],
            ),
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
                    color: context.adapt(SoftPalette.yellow50),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: context.adapt(SoftPalette.yellow200)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              context.isUrdu ? 'رخصت کی درخواست' : 'Leave Request',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: context.adapt(SoftPalette.orange350), fontFamily: context.isUrdu ? 'Noori' : null),
                            ),
                            if (log['leaveReason'] != null && log['leaveReason'].toString().isNotEmpty)
                              Text(
                                log['leaveReason'].toString(),
                                style: TextStyle(fontSize: 11, color: context.adapt(SoftPalette.gray900A87)),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      _actionButton(context.isUrdu ? 'منظور' : 'Approve', SoftPalette.green400, isReadOnly ? () {} : () {
                        onDecideLeave(sId, approve: true);
                      }),
                      const SizedBox(width: 6),
                      _actionButton(context.isUrdu ? 'مسترد' : 'Deny', SoftPalette.red400, isReadOnly ? () {} : () {
                        onDecideLeave(sId, approve: false);
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
                onChanged: isReadOnly ? null : (newAtt) => onUpdateAttendance(sId, newAtt),
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
                activeColor: SoftPalette.amber300,
                trackColor: SoftPalette.amber200,
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
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      Text(
                        name,
                        style: context.urduStyle(
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: textPrimary),
                        ),
                      ),
                      ...badgeWidgets,
                    ],
                  ),
                  if ((isParentRequested || att == 'leave_requested') && leaveStatus == 'pending')
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: context.adapt(SoftPalette.yellow50),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: context.adapt(SoftPalette.yellow200)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.event_note_rounded, size: 14, color: context.adapt(SoftPalette.orange350)),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  'Parent Requested Leave: "${log['leaveReason'] ?? "No reason"}"',
                                  style: TextStyle(fontSize: 11.5, color: context.adapt(SoftPalette.orange350), fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              _actionButton('Allow Leave', SoftPalette.green400, isReadOnly ? () {} : () {
                                onDecideLeave(sId, approve: true);
                              }),
                              const SizedBox(width: 8),
                              _actionButton('Decline', SoftPalette.red400, isReadOnly ? () {} : () {
                                onDecideLeave(sId, approve: false);
                              }),
                            ],
                          ),
                        ],
                      ),
                    ),
                  if (leaveStatus == 'approved' && att == 'leave')
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: context.adapt(SoftPalette.green100m),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: context.adapt(SoftPalette.green300)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.check_circle_rounded, size: 14, color: context.adapt(SoftPalette.green550)),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              'Leave Approved: "${log['leaveReason'] ?? "Granted"}"',
                              style: TextStyle(fontSize: 11, color: context.adapt(SoftPalette.green600), fontWeight: FontWeight.bold),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if ((leaveStatus == 'declined' || leaveStatus == 'denied') &&
                      att != 'present' && att != 'late')
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: context.adapt(SoftPalette.pink100m),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: context.adapt(SoftPalette.red300)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.cancel_rounded, size: 14, color: context.adapt(SoftPalette.red550)),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              'Leave Request Declined',
                              style: TextStyle(fontSize: 11, color: context.adapt(SoftPalette.red550), fontWeight: FontWeight.bold),
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
                        color: context.adapt(SoftPalette.purple150m),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: context.adapt(SoftPalette.purple350)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.reply_rounded, size: 14, color: context.adapt(SoftPalette.violet700)),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  parentMsgText != null && parentMsgText.trim().isNotEmpty
                                      ? 'Parent Reply: "$parentMsgText"'
                                      : 'Parent requested reply verification',
                                  style: TextStyle(fontSize: 11.5, color: context.adapt(SoftPalette.violet700), fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              _actionButton('Approve Reply', SoftPalette.purple550, isReadOnly ? () {} : () {
                                onUpdateLocal(sId, 'parentReplied', true);
                                onUpdateLocal(sId, 'parentRepliedRequested', false);
                              }),
                              const SizedBox(width: 8),
                              _actionButton('Deny', SoftPalette.red400, isReadOnly ? () {} : () {
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
                        color: context.adapt(SoftPalette.green100m),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: context.adapt(SoftPalette.green300)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.check_circle_outline_rounded, size: 14, color: context.adapt(SoftPalette.green550)),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              parentMsgText != null && parentMsgText.trim().isNotEmpty
                                  ? 'Parent Reply: "$parentMsgText"'
                                  : 'Parent Reply: Approved',
                              style: TextStyle(fontSize: 11, color: context.adapt(SoftPalette.green600), fontWeight: FontWeight.bold),
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
                        color: context.adapt(SoftPalette.slate100),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: context.adapt(SoftPalette.slate200)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.people_rounded, size: 14, color: context.adapt(SoftPalette.blue600)),
                          const SizedBox(width: 6),
                          Text(
                            'Parent claimed PTM attendance',
                            style: TextStyle(fontSize: 11, color: context.adapt(SoftPalette.blue600), fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(width: 8),
                          _actionButton('Approve', SoftPalette.green400, isReadOnly ? () {} : () {
                            onUpdateLocal(sId, 'ptm', true);
                            onUpdateLocal(sId, 'ptmRequestStatus', 'approved');
                          }),
                          const SizedBox(width: 6),
                          _actionButton('Decline', SoftPalette.red400, isReadOnly ? () {} : () {
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
                  _actionButton('Approve', SoftPalette.green400, isReadOnly ? () {} : () {
                    onDecideLeave(sId, approve: true);
                  }),
                  const SizedBox(width: 8),
                  _actionButton('Deny', SoftPalette.red400, isReadOnly ? () {} : () {
                    onDecideLeave(sId, approve: false);
                  }),
                ],
              )
            else ...[
              SegmentedAttendanceToggle(
                value: att,
                allowStudentLeave: allowStudentLeave,
                isGlobalUser: _isGlobalLevelUser(editorRole),
                onChanged: isReadOnly ? null : (newAtt) => onUpdateAttendance(sId, newAtt),
                showLabel: true,
              ),
              const SizedBox(width: 14),
              SegmentedTimingToggle(
                isLate: isLate,
                arrivalTime: arrivalTime,
                isEnabled: att == 'present' && !isReadOnly,
                showLabel: true,
                onChanged: (val) {
                  onUpdateLocal(sId, 'isLate', val);
                  onUpdateLocal(sId, 'timing', val ? 'late' : 'on_time');
                  if (val) {
                    final existingTime = log['arrivalTime']?.toString();
                    if (existingTime == null || existingTime.isEmpty) {
                      final nowTime = DateFormat('hh:mm a').format(DateTime.now());
                      onUpdateLocal(sId, 'arrivalTime', nowTime);
                    }
                  } else {
                    onUpdateLocal(sId, 'arrivalTime', null);
                  }
                },
                onPickTime: isReadOnly ? null : () => _selectArrivalTime(context, sId, arrivalTime),
              ),
            ],
            const SizedBox(width: 18),
            _switchCol(
              context,
              context.l.uniform,
              (att == 'leave' || uni == true || uni == 'leave'),
              (att == 'present' && !isReadOnly) ? (v) => onUpdateLocal(sId, 'uniform', v) : null,
            ),
            const SizedBox(width: 18),
            _switchCol(
              context,
              context.l.parentReplied,
              msg,
              isReadOnly ? null : (v) => onUpdateLocal(sId, 'parentReplied', v),
              activeColor: SoftPalette.amber300,
              trackColor: SoftPalette.amber200,
            ),
            const SizedBox(width: 18),
            IconButton(
              icon: FaIcon(FontAwesomeIcons.whatsapp, color: context.adapt(SoftPalette.green350), size: 20),
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
                    style: context.urduStyle(style: TextStyle(fontSize: 10, color: context.adapt(SoftPalette.slate400), fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      _attButton('J', log['ptm'] == true, SoftPalette.green550, isReadOnly ? () {} : () => onUpdateLocal(sId, 'ptm', true)),
                      const SizedBox(width: 4),
                      _attButton('M', log['ptm'] == false, SoftPalette.red500, isReadOnly ? () {} : () => onUpdateLocal(sId, 'ptm', false)),
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
              color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.gray150),
            ),
            child: isMobile
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSabakField(context, sId, lines, isDark: isDark),
                      if (!isStudentNazra) ...[
                        const SizedBox(height: 12),
                        _buildSabkiField(context, sabkiPara, sabkiRatio, isDark: isDark),
                        const SizedBox(height: 12),
                        _buildManzilField(context, manzilPara, manzilRatio, isDark: isDark),
                      ] else ...[
                        const SizedBox(height: 12),
                        _buildRukuField(context, sId, rukuPara, rukuVal, isDark: isDark),
                        const SizedBox(height: 12),
                        _buildQaidaField(context, sId, isQaidaCompleted, qaidaSabakVal, isDark: isDark),
                      ],
                    ],
                  )
                : (isStudentNazra
                    ? Row(
                        children: [
                          Expanded(child: _buildSabakField(context, sId, lines, isDark: isDark)),
                          const SizedBox(width: 16),
                          Expanded(child: _buildRukuField(context, sId, rukuPara, rukuVal, isDark: isDark)),
                          const SizedBox(width: 16),
                          Expanded(child: _buildQaidaField(context, sId, isQaidaCompleted, qaidaSabakVal, isDark: isDark)),
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
                      )),
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
                color: SoftPalette.gray900.withValues(alpha: isDark ? 0.25 : 0.02),
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
                            decoration: BoxDecoration(color: context.adapt(SoftPalette.yellow50), borderRadius: BorderRadius.circular(4)),
                            width: double.infinity,
                            child: Text(
                              'Parent requested a leave: ${log['leaveReason'] ?? "No reason"}',
                              style: TextStyle(fontSize: 11, color: context.adapt(SoftPalette.orange350), fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                        if (parentRepliedRequested && msg != true) ...[
                          Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: context.adapt(SoftPalette.purple150m),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: context.adapt(SoftPalette.purple350)),
                            ),
                            width: double.infinity,
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Parent requested reply verification',
                                    style: TextStyle(fontSize: 11, color: context.adapt(SoftPalette.violet700), fontWeight: FontWeight.bold),
                                  ),
                                ),
                                _actionButton('Approve Reply', SoftPalette.purple550, isReadOnly ? () {} : () {
                                  onUpdateLocal(sId, 'parentReplied', true);
                                  onUpdateLocal(sId, 'parentRepliedRequested', false);
                                }),
                                const SizedBox(width: 8),
                                _actionButton('Deny', SoftPalette.red400, isReadOnly ? () {} : () {
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
                              color: context.adapt(SoftPalette.slate100),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: context.adapt(SoftPalette.sky300)),
                            ),
                            width: double.infinity,
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    context.isUrdu ? 'والدین نے پی ٹی ایم میں شرکت کا دعویٰ کیا ہے' : 'Parent claimed PTM attendance',
                                    style: TextStyle(fontSize: 11, color: context.adapt(SoftPalette.blue600), fontWeight: FontWeight.bold, fontFamily: context.isUrdu ? 'Noori' : null),
                                  ),
                                ),
                                _actionButton('Approve', SoftPalette.green400, isReadOnly ? () {} : () {
                                  onUpdateLocal(sId, 'ptm', true);
                                  onUpdateLocal(sId, 'ptmRequestStatus', 'approved');
                                }),
                                const SizedBox(width: 8),
                                _actionButton('Decline', SoftPalette.red400, isReadOnly ? () {} : () {
                                  onUpdateLocal(sId, 'ptm', false);
                                  onUpdateLocal(sId, 'ptmRequestStatus', 'rejected');
                                }),
                              ],
                            ),
                          ),
                        ],
                        middleRow,
                        if (att == 'present') ...[
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: isDark ? SoftPalette.slate900.withValues(alpha: 0.6) : SoftPalette.slate100,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: isDark ? SoftPalette.slate700 : SoftPalette.slate200,
                                width: 0.8,
                              ),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.access_time_rounded,
                                          size: 15,
                                          color: isDark ? SoftPalette.slate400 : SoftPalette.slate600,
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          context.l.timing,
                                          style: context.urduStyle(
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                              color: isDark ? SoftPalette.slate350 : SoftPalette.slate700,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    SegmentedTimingToggle(
                                      isLate: isLate,
                                      arrivalTime: arrivalTime,
                                      isEnabled: !isReadOnly,
                                      showLabel: false,
                                      isCompact: true,
                                      onChanged: (val) {
                                        onUpdateLocal(sId, 'isLate', val);
                                        onUpdateLocal(sId, 'timing', val ? 'late' : 'on_time');
                                        if (val) {
                                          final existingTime = log['arrivalTime']?.toString();
                                          if (existingTime == null || existingTime.isEmpty) {
                                            final nowTime = DateFormat('hh:mm a').format(DateTime.now());
                                            onUpdateLocal(sId, 'arrivalTime', nowTime);
                                          }
                                        } else {
                                          onUpdateLocal(sId, 'arrivalTime', null);
                                        }
                                      },
                                      onPickTime: isReadOnly ? null : () => _selectArrivalTime(context, sId, arrivalTime),
                                    ),
                                  ],
                                ),
                                if (isLate && arrivalTime != null && arrivalTime.isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  InkWell(
                                    onTap: isReadOnly ? null : () => _selectArrivalTime(context, sId, arrivalTime),
                                    borderRadius: BorderRadius.circular(8),
                                    child: Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                      decoration: BoxDecoration(
                                        color: context.comfort.warning.withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: context.comfort.warning.withValues(alpha: 0.4),
                                          width: 0.8,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(GIcons.time, size: 13, color: context.comfort.warning),
                                              const SizedBox(width: 5),
                                              Text(
                                                context.isUrdu ? 'آمد کا وقت: $arrivalTime' : 'Arrival: $arrivalTime',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.bold,
                                                  color: context.comfort.warning,
                                                ),
                                              ),
                                            ],
                                          ),
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                context.isUrdu ? 'تبدیل کریں' : 'Change',
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.w600,
                                                  color: context.comfort.warning,
                                                ),
                                              ),
                                              const SizedBox(width: 2),
                                              Icon(GIcons.edit, size: 11, color: context.comfort.warning),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
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