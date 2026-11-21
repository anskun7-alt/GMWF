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
import 'package:gmwf_ui/gmwf_ui.dart' as ui show GComfortColors;
import '../widgets/madrassa_erp.dart';
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
  // Bumped on every edit, decision and save: the register rebuilds from it.
  final ValueNotifier<int> _changeNotifier = ValueNotifier(0);
  bool? _localAllowStudentLeave;
  String get _effectiveBranch => MadrassaLocalStorage.normalizeBranch(widget.branchId);

  @override
  void initState() {
    super.initState();
    // Initialise streams/downloads for the initially selected date
    _updateDateStreams();
    // Leave requests are listed for last, this and next month: fetch next month's
    // days too (guardians ask ahead of time).
    final now = DateTime.now();
    final next = DateTime(now.year, now.month + 1, 1);
    if (_downloadDue('logs|$_effectiveBranch|${next.year}-${next.month}', const Duration(minutes: 2))) {
      MadrassaLocalStorage.downloadLogsForMonth(_effectiveBranch, next.year, next.month);
    }
  }

  Widget? _publishedSlot;

  @override
  void dispose() {
    // Take our controls out of the hub bar (only if they are still ours).
    if (_publishedSlot != null && identical(MadrassaHubSlot.toolbar.value, _publishedSlot)) {
      MadrassaHubSlot.toolbar.value = null;
    }
    _searchCtrl.dispose();
    _changeNotifier.dispose();
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

  Future<void> _saveChanges() async {
    if (_localChanges.isEmpty) return;
    setState(() => _isSaving = true);

    // Para and amount go together for Sabqi, Manzil and Ruku. Only the pairs edited
    // now are checked, against what the screen shows (saved value + this edit).
    final logData = _currentDbLog();
    String nameOf(String sId) {
      final cached = MadrassaLocalStorage.getStudentCached(_effectiveBranch, sId);
      final n = (cached?['name'] ?? '').toString();
      return n.isEmpty ? sId : n;
    }

    String? problem;
    for (final entry in _localChanges.entries) {
      final delta = entry.value;
      final v = _viewOf(entry.key, logData);
      for (final (label, paraKey, ratioKey) in const [
        ('Sabqi', 'sabkiPara', 'sabkiRatio'),
        ('Manzil', 'manzilPara', 'manzilRatio'),
        ('Ruku', 'rukuPara', 'ruku'),
      ]) {
        if (!delta.containsKey(paraKey) && !delta.containsKey(ratioKey)) continue;
        final para = _asInt(v[paraKey]);
        final ratio = v[ratioKey]?.toString();
        final hasRatio = ratio != null && ratio.isNotEmpty && ratio != '-' && ratio != '0';
        if (hasRatio && ratio != 'nahi_sunaya' && para == 0) {
          problem = '$label (${nameOf(entry.key)}): choose the Para too.';
        } else if (para > 0 && !hasRatio) {
          problem = '$label (${nameOf(entry.key)}): choose how much was heard for Para $para.';
        }
        if (problem != null) break;
      }
      if (problem != null) break;
    }
    if (problem != null) {
      AppToast.showSnackBar(context, SnackBar(content: Text(problem)));
      setState(() => _isSaving = false);
      return;
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

      if (!mounted) return;
      setState(() {
        _localChanges = {};
        _isSaving = false;
        _allPresentToggled = false;
        _allUniformToggled = false;
        _allRepliedToggled = false;
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

  // Records ONE changed field. Unsaved edits hold only the fields this user
  // changed: they used to start as a copy of the student's whole saved entry, so
  // "Save" (and "All present" / "All replied", which touch every student) sent
  // this PC's older Sabak/Sabqi/Manzil back to the cloud over another PC's entry.
  void _updateLocalSilent(String sId, String key, dynamic value) {
    (_localChanges[sId] ??= <String, dynamic>{})[key] = value;
    _changeNotifier.value++;
  }

  void _updateSabakLines(String sId, int newSabak) {
    final currentLocal = _viewOf(sId);

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

  /// Approve / deny from the student editor: saved at once, like the bell.
  void _decideLeaveSilent(String sId, {required bool approve}) {
    final student = MadrassaLocalStorage.getStudentCached(_effectiveBranch, sId) ?? <String, dynamic>{'id': sId};
    unawaited(_decideLeaveNow(
      _LeaveRequest(dateKey: _dateKey, studentId: sId, student: student, log: _viewOf(sId)),
      approve: approve,
    ));
  }

  void _updateAttendanceSilent(String sId, String value) {
    final current = _viewOf(sId);
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
                        separatorBuilder: (_, _) => const Divider(),
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

  // ── Register (redesign 2026-11-21) ─────────────────────────────────────────
  // One dense table row per student instead of one big card each. The full
  // editor (Qaida, Ruku, photo, PTM claim, parent reply…) opens for a row in a
  // side panel, dialog or bottom sheet. Leave requests come in through the bell.

  String? _selectedStudentId;
  String _searchText = '';
  String _statusFilter = 'all';
  final TextEditingController _searchCtrl = TextEditingController();
  final Set<String> _seenRequestIds = {};
  bool _requestsPrimed = false;

  String get _dateKey => DateFormat('yyyy-MM-dd').format(_selectedDate);

  // Notifications (leave requests: badge, dots, request chip) use the theme's
  // amber accent, not the warning colour; the bell itself stays neutral.
  ui.GComfortColors get _ds =>
      Theme.of(context).extension<ui.GComfortColors>() ??
      (Theme.of(context).brightness == Brightness.dark ? ui.GComfortColors.dark : ui.GComfortColors.light);
  Color get _amber => _ds.accent;
  Color get _amberText => Theme.of(context).brightness == Brightness.dark ? _ds.accent : _ds.accentStrong;

  Map<String, dynamic> _currentDbLog() =>
      ref.read(madrassaDailyLogProvider((branchId: _effectiveBranch, dateKey: _dateKey))).value ?? {};

  /// What the screen shows for a student: the saved entry with this user's
  /// unsaved edits on top.
  Map<String, dynamic> _viewOf(String sId, [Map<String, dynamic>? logData]) {
    final db = _safeMap((logData ?? _currentDbLog())[sId]);
    final local = _localChanges[sId];
    return local == null ? db : {...db, ...local};
  }

  static bool _isNazraStudent(Map<String, dynamic> s, bool nazraOnly) =>
      nazraOnly ||
      s['isNazra'] == true ||
      s['program']?.toString().toLowerCase() == 'nazra' ||
      s['class']?.toString().toLowerCase() == 'nazra';

  static const _decidedLeaveStates = {'approved', 'denied', 'declined', 'cancelled'};

  /// A guardian's leave request nobody has answered yet.
  static bool _isPendingLeave(Map log) {
    final status = (log['leaveStatus'] ?? '').toString().toLowerCase().trim();
    if (_decidedLeaveStates.contains(status)) return false;
    final reason = (log['leaveReason'] ?? '').toString().trim();
    return ((log['isParentRequested'] == true || log['attendance'] == 'leave_requested') &&
            (status.isEmpty || status == 'pending')) ||
        (status == 'pending' && reason.isNotEmpty);
  }

  static int _asInt(dynamic v) => v is num ? v.toInt() : (int.tryParse(v?.toString() ?? '') ?? 0);

  String _ratioLabel(String? r) {
    final urdu = context.isUrdu;
    switch (r) {
      case '1/4':
        return urdu ? 'پاؤ' : 'Pao';
      case '1/2':
        return urdu ? 'نصف' : 'Nisf';
      case '3/4':
        return urdu ? 'ثلاثہ' : 'Salasa';
      case '1':
        return urdu ? 'پارہ' : 'Para';
      case 'nahi_sunaya':
        return urdu ? 'نہیں سنایا' : 'Not heard';
    }
    return '';
  }

  String _sessionLabel(String s) {
    final urdu = context.isUrdu;
    switch (s) {
      case 'evening':
        return urdu ? 'شام' : 'Evening';
      case 'night':
        return urdu ? 'رات' : 'Night';
      default:
        return urdu ? 'صبح' : 'Morning';
    }
  }

  // ── Navigation ─────────────────────────────────────────────────────────────

  Future<bool> _confirmDiscard() async {
    if (_localChanges.isEmpty) return true;
    final c = context.comfort;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => _urduSafe(AlertDialog(
        title: Text(context.isUrdu ? 'محفوظ نہ کی گئی تبدیلیاں' : 'Unsaved changes', style: GText.h3(c.textPrimary)),
        content: Text(
          context.isUrdu
              ? '${_localChanges.length} طلباء کی تبدیلیاں محفوظ نہیں ہوئیں۔ چھوڑ دیں؟'
              : 'Changes for ${_localChanges.length} student(s) are not saved. Discard them?',
          style: GText.body2(c.textSecondary),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(context.isUrdu ? 'واپس' : 'Keep editing')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: c.danger, foregroundColor: c.onBrand),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(context.isUrdu ? 'چھوڑ دیں' : 'Discard'),
          ),
        ],
      )),
    );
    return ok == true;
  }

  Future<void> _goToDate(DateTime d) async {
    final target = DateTime(d.year, d.month, d.day);
    if (target == DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day)) return;
    if (!await _confirmDiscard()) return;
    if (!mounted) return;
    setState(() {
      _selectedDate = target;
      _localChanges = {};
      _selectedStudentId = null;
      _allPresentToggled = false;
      _allUniformToggled = false;
      _allRepliedToggled = false;
    });
    _changeNotifier.value++;
    _updateDateStreams();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(now.year - 3),
      lastDate: DateTime(now.year + 1, 12, 31),
    );
    if (picked != null) await _goToDate(picked);
  }

  // ── Leave requests (notifications) ────────────────────────────────────────

  List<_LeaveRequest> _collectLeaveRequests(List<Map<String, dynamic>> allStudents) {
    final now = DateTime.now();
    final byId = {for (final s in allStudents) (s['id'] ?? '').toString(): s};
    final out = <_LeaveRequest>[];
    final seen = <String>{};
    for (final offset in const [-1, 0, 1]) {
      final m = DateTime(now.year, now.month + offset, 1);
      final logs = ref
              .watch(madrassaMonthlyLogsProvider((branchId: _effectiveBranch, year: m.year, month: m.month)))
              .value ??
          const <Map<String, dynamic>>[];
      for (final day in logs) {
        final dateKey = (day['dateKey'] ?? day['id'] ?? '').toString();
        if (dateKey.isEmpty) continue;
        day.forEach((sId, entry) {
          if (entry is! Map || !_isPendingLeave(entry)) return;
          final student = byId[sId];
          if (student == null) return;
          final id = '$dateKey|$sId';
          if (!seen.add(id)) return;
          out.add(_LeaveRequest(
            dateKey: dateKey,
            studentId: sId,
            student: student,
            log: Map<String, dynamic>.from(entry),
          ));
        });
      }
    }
    out.sort((a, b) {
      final d = a.dateKey.compareTo(b.dateKey);
      if (d != 0) return d;
      return _asInt(a.student['rollNumber']).compareTo(_asInt(b.student['rollNumber']));
    });
    return out;
  }

  /// Shows a short notice when a new request arrives while the screen is open.
  void _announceNewRequests(List<_LeaveRequest> requests) {
    final ids = requests.map((r) => r.id).toSet();
    if (!_requestsPrimed) {
      _requestsPrimed = true;
      _seenRequestIds.addAll(ids);
      return;
    }
    final fresh = requests.where((r) => !_seenRequestIds.contains(r.id)).toList();
    _seenRequestIds
      ..removeWhere((id) => !ids.contains(id))
      ..addAll(ids);
    if (fresh.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final first = fresh.first;
      final name = (first.student['name'] ?? '').toString();
      AppToast.showSnackBar(
        context,
        SnackBar(
          content: Text(
            fresh.length == 1
                ? (context.isUrdu ? 'رخصت کی نئی درخواست: $name' : 'New leave request: $name')
                : (context.isUrdu ? '${fresh.length} نئی رخصت کی درخواستیں' : '${fresh.length} new leave requests'),
          ),
          action: SnackBarAction(
            label: context.isUrdu ? 'دیکھیں' : 'Open',
            onPressed: () => fresh.length == 1 ? _openLeaveRequest(first) : _showLeaveInbox(requests),
          ),
        ),
      );
    });
  }

  String _friendlyDate(String dateKey) {
    final d = DateTime.tryParse(dateKey);
    if (d == null) return dateKey;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = DateTime(d.year, d.month, d.day).difference(today).inDays;
    final urdu = context.isUrdu;
    final base = DateFormat('EEE d MMM').format(d);
    if (diff == 0) return '${urdu ? 'آج' : 'Today'} · $base';
    if (diff == 1) return '${urdu ? 'کل (آنے والا)' : 'Tomorrow'} · $base';
    if (diff == -1) return '${urdu ? 'کل (گزرا)' : 'Yesterday'} · $base';
    return base;
  }

  Future<void> _showLeaveInbox(List<_LeaveRequest> requests) async {
    final c = context.comfort;
    final urdu = context.isUrdu;
    final picked = await showDialog<_LeaveRequest>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(Gsp.sp4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Gr.r5)),
        child: _urduSafe(ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(Gsp.sp4, Gsp.sp3, Gsp.sp2, Gsp.sp3),
              child: Row(children: [
                Icon(GIcons.notifications, size: 20, color: _amber),
                const SizedBox(width: Gsp.sp2),
                Expanded(
                  child: Text(urdu ? 'رخصت کی درخواستیں' : 'Leave requests', style: GText.body1Bold(c.textPrimary)),
                ),
                if (requests.length > 1)
                  TextButton.icon(
                    style: TextButton.styleFrom(foregroundColor: c.success, visualDensity: VisualDensity.compact),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _approveAllLeaves(requests);
                    },
                    icon: const Icon(GIcons.checkCircle, size: 16),
                    label: Text(urdu ? 'سب منظور' : 'Approve all (${requests.length})'),
                  )
                else
                  Text('${requests.length}', style: GText.label(c.textMuted)),
                IconButton(tooltip: urdu ? 'بند کریں' : 'Close', onPressed: () => Navigator.pop(ctx), icon: const Icon(GIcons.close)),
              ]),
            ),
            Divider(height: 1, color: c.border),
            if (requests.isEmpty)
              Padding(
                padding: const EdgeInsets.all(Gsp.sp6),
                child: AppEmptyState(
                  icon: GIcons.checkCircle,
                  title: urdu ? 'کوئی درخواست باقی نہیں' : 'No requests waiting',
                  subtitle: urdu ? 'والدین کی نئی درخواستیں یہاں آئیں گی۔' : 'New requests from parents show up here.',
                  compact: true,
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: requests.length,
                  separatorBuilder: (_, _) => Divider(height: 1, color: c.border),
                  itemBuilder: (_, i) {
                    final r = requests[i];
                    final name = (r.student['name'] ?? '—').toString();
                    final reason = (r.log['leaveReason'] ?? '').toString().trim();
                    return InkWell(
                      onTap: () => Navigator.pop(ctx, r),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: Gsp.sp4, vertical: Gsp.sp2 + 2),
                        child: Row(children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(color: _amber, shape: BoxShape.circle),
                          ),
                          const SizedBox(width: Gsp.sp3),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              MadrassaUrduAwareText(name, color: c.textPrimary),
                              Row(children: [
                                Text(_friendlyDate(r.dateKey), style: GText.caption(c.textMuted)),
                                if (reason.isNotEmpty) ...[
                                  Text('  ·  ', style: GText.caption(c.textMuted)),
                                  Flexible(child: MadrassaUrduAwareText(reason, color: c.textMuted, size: 12, bold: false)),
                                ],
                              ]),
                            ]),
                          ),
                          Icon(GIcons.chevronRight, size: 18, color: c.textMuted),
                        ]),
                      ),
                    );
                  },
                ),
              ),
          ]),
        )),
      ),
    );
    if (picked != null && mounted) await _openLeaveRequest(picked);
  }

  Future<void> _openLeaveRequest(_LeaveRequest r) async {
    final c = context.comfort;
    final urdu = context.isUrdu;
    final name = (r.student['name'] ?? '—').toString();
    final reason = (r.log['leaveReason'] ?? '').toString().trim();
    final requestedAt = DateTime.tryParse((r.log['leaveRequestedAt'] ?? r.log['timestamp'] ?? '').toString());
    final roll = r.student['rollNumber']?.toString() ?? '—';
    final program = _isNazraStudent(r.student, LocalStorageService.isMadrassaNazraOnly(_effectiveBranch))
        ? (urdu ? 'ناظرہ' : 'Nazra')
        : (urdu ? 'حفظ' : 'Hifz');

    Widget fact(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: Gsp.sp1),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 110, child: Text(label, style: GText.caption(c.textMuted))),
            Expanded(
              child: MadrassaErp.isUrduText(value)
                  ? Text(value, style: GText.body2(c.textPrimary).copyWith(fontFamily: 'Noori', fontSize: 15, height: 1.6))
                  : Text(value.isEmpty ? '—' : value, style: GText.body2(c.textPrimary)),
            ),
          ]),
        );

    final decision = await showDialog<bool>(
      context: context,
      builder: (ctx) => _urduSafe(AlertDialog(
        titlePadding: const EdgeInsetsDirectional.fromSTEB(Gsp.sp5, Gsp.sp4, Gsp.sp3, 0),
        title: Row(children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(color: _amber.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(Gr.r2)),
            child: Icon(GIcons.event, size: 18, color: _amber),
          ),
          const SizedBox(width: Gsp.sp3),
          Expanded(child: Text(urdu ? 'رخصت کی درخواست' : 'Leave request', style: GText.h3(c.textPrimary))),
        ]),
        content: SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            MadrassaUrduAwareText(name, color: c.textPrimary, size: 16),
            Text('${urdu ? 'رول' : 'Roll'} $roll · $program', style: GText.caption(c.textMuted)),
            const SizedBox(height: Gsp.sp3),
            fact(urdu ? 'تاریخ' : 'Date', _friendlyDate(r.dateKey)),
            fact(urdu ? 'وجہ' : 'Reason', reason),
            if (requestedAt != null)
              fact(urdu ? 'درخواست کا وقت' : 'Requested', DateFormat('d MMM, hh:mm a').format(requestedAt.toLocal())),
            const SizedBox(height: Gsp.sp2),
            Text(
              urdu
                  ? 'منظوری پر اس دن حاضری میں L لگ جائے گا، مسترد کرنے پر A۔'
                  : 'Approve marks the day as Leave (L); Deny marks it Absent (A).',
              style: GText.caption(c.textMuted),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(urdu ? 'بعد میں' : 'Later')),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: c.danger, side: BorderSide(color: c.danger.withValues(alpha: 0.5))),
            onPressed: () => Navigator.pop(ctx, false),
            icon: const Icon(GIcons.cancel, size: 16),
            label: Text(urdu ? 'مسترد' : 'Deny'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: c.success, foregroundColor: c.onBrand),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(GIcons.checkCircle, size: 16),
            label: Text(urdu ? 'منظور' : 'Approve'),
          ),
        ],
      )),
    );
    if (decision != null && mounted) await _decideLeaveNow(r, approve: decision);
  }

  /// Approves every waiting request after one confirmation.
  Future<void> _approveAllLeaves(List<_LeaveRequest> requests) async {
    if (requests.isEmpty) return;
    final c = context.comfort;
    final urdu = context.isUrdu;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => _urduSafe(AlertDialog(
        title: Text(urdu ? 'سب منظور کریں؟' : 'Approve all leave requests?', style: GText.h3(c.textPrimary)),
        content: SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(
              urdu
                  ? '${requests.length} درخواستیں منظور ہوں گی اور ان دنوں میں L لگ جائے گا:'
                  : '${requests.length} request(s) will be approved and marked Leave (L):',
              style: GText.body2(c.textSecondary),
            ),
            const SizedBox(height: Gsp.sp2),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: ListView(shrinkWrap: true, children: [
                for (final r in requests)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(children: [
                      Expanded(child: MadrassaUrduAwareText((r.student['name'] ?? '—').toString(), color: c.textPrimary, size: 13)),
                      Text(_friendlyDate(r.dateKey), style: GText.caption(c.textMuted)),
                    ]),
                  ),
              ]),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(urdu ? 'واپس' : 'Cancel')),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: c.success, foregroundColor: c.onBrand),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(GIcons.checkCircle, size: 16),
            label: Text(urdu ? 'سب منظور' : 'Approve all (${requests.length})'),
          ),
        ],
      )),
    );
    if (ok != true || !mounted) return;
    var done = 0;
    for (final r in List<_LeaveRequest>.from(requests)) {
      if (await _decideLeaveNow(r, approve: true, quiet: true)) done++;
    }
    if (!mounted) return;
    AppToast.showSnackBar(
      context,
      SnackBar(content: Text(urdu ? '$done رخصتیں منظور ہو گئیں' : '$done leave request(s) approved')),
    );
  }

  /// Saves a leave decision at once (any date), so it does not wait for "Save".
  Future<bool> _decideLeaveNow(_LeaveRequest r, {required bool approve, bool quiet = false}) async {
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final reqAt = r.log['leaveRequestedAt'] ?? r.log['timestamp'];
    final payload = <String, dynamic>{
      'attendance': approve ? 'leave' : 'absent',
      'leaveStatus': approve ? 'approved' : 'denied',
      'isParentRequested': false,
      'leaveDecidedAt': nowIso,
      'leaveDecidedBy': widget.editorName,
      'leaveDecidedFor': ?reqAt,
      'uniform': approve ? 'leave' : false,
      'isLate': false,
      'timing': 'on_time',
      'arrivalTime': null,
    };
    try {
      await MadrassaLocalStorage.saveLogRecordLocal(
        branchId: _effectiveBranch,
        dateKey: r.dateKey,
        logData: {r.studentId: payload},
        editorName: widget.editorName,
        editorRole: widget.editorRole,
      );
      // An unsaved edit of the same fields on screen would hide the decision.
      if (r.dateKey == _dateKey) {
        final local = _localChanges[r.studentId];
        if (local != null) {
          local.removeWhere((k, _) => payload.containsKey(k));
          if (local.isEmpty) _localChanges.remove(r.studentId);
        }
      }
      _seenRequestIds.remove(r.id);
      _changeNotifier.value++;
      if (!mounted || quiet) return true;
      final name = (r.student['name'] ?? '').toString();
      AppToast.showSnackBar(
        context,
        SnackBar(
          content: Text(approve
              ? (context.isUrdu ? 'رخصت منظور: $name' : 'Leave approved: $name')
              : (context.isUrdu ? 'رخصت مسترد: $name' : 'Leave denied: $name')),
        ),
      );
      return true;
    } catch (e) {
      if (mounted) AppToast.showSnackBar(context, SnackBar(content: Text('Error: $e')));
      return false;
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final configAsync = ref.watch(madrassaConfigProvider(_effectiveBranch));
    final holidays = ref.watch(madrassaHolidaysProvider(_effectiveBranch)).value ?? const <Map<String, dynamic>>[];
    final studentsAsync = ref.watch(madrassaFilteredStudentsProvider((branchId: _effectiveBranch, selectedDate: _selectedDate)));
    final logAsync = ref.watch(madrassaDailyLogProvider((branchId: _effectiveBranch, dateKey: _dateKey)));
    final allStudents = ref.watch(madrassaStudentsProvider(_effectiveBranch)).value ?? const <Map<String, dynamic>>[];
    final requests = _collectLeaveRequests(allStudents);
    _announceNewRequests(requests);

    return Scaffold(
      backgroundColor: c.background,
      body: configAsync.when(
        skipLoadingOnReload: true,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error loading config: $e', style: GText.body2(c.danger))),
        data: (config) => ValueListenableBuilder<int>(
          valueListenable: _changeNotifier,
          builder: (context, _, _) =>
              _urduSafe(_buildRegisterPage(context, config, holidays, studentsAsync, logAsync, requests)),
        ),
      ),
    );
  }

  /// The UI font has no Urdu letters: any Urdu text under [child] falls back to
  /// Noori Nastaliq instead of showing empty boxes. (Text styles inherit this
  /// fallback; dialogs are new routes, so their parts are wrapped too.)
  static Widget _urduSafe(Widget child) => Builder(builder: (context) {
        final theme = Theme.of(context);
        return Theme(
          // Dialog titles and button labels take their style from the theme.
          data: theme.copyWith(textTheme: theme.textTheme.apply(fontFamilyFallback: const ['Noori'])),
          child: DefaultTextStyle.merge(style: const TextStyle(fontFamilyFallback: ['Noori']), child: child),
        );
      });

  Widget _buildRegisterPage(
    BuildContext context,
    MadrassaConfig config,
    List<Map<String, dynamic>> holidays,
    AsyncValue<List<Map<String, dynamic>>> studentsAsync,
    AsyncValue<Map<String, dynamic>> logAsync,
    List<_LeaveRequest> requests,
  ) {
    final c = context.comfort;
    final urdu = context.isUrdu;
    final narrow = MadrassaErp.narrow(context);
    final pad = narrow ? Gsp.sp3 : Gsp.sp5;
    final isReadOnly = !_canSaveData();
    final allowLeave = _localAllowStudentLeave ?? config.allowStudentLeave;
    final ptmDate = getPtmDateFor(_selectedDate.year, _selectedDate.month, config);
    final isPtmDay = DateUtils.isSameDay(_selectedDate, ptmDate);
    final workingDays = MadrassaFeeLogic.getWorkingDaysCount(_selectedDate.year, _selectedDate.month);
    final hijri = IslamicCalendarHelper.fromGregorian(_selectedDate).format(isUrdu: urdu);
    final nazraOnly = LocalStorageService.isMadrassaNazraOnly(_effectiveBranch);

    // Closed days
    String? holidayName;
    for (final h in holidays) {
      final v = h['date'];
      final d = v is String ? DateTime.tryParse(v) : (v is Timestamp ? v.toDate() : null);
      if (d != null && DateUtils.isSameDay(d, _selectedDate)) {
        holidayName = (h['name'] as String?) ?? (urdu ? 'چھٹی' : 'Holiday');
        break;
      }
    }
    final islamicEvent = IslamicCalendarHelper.getIslamicEvent(_selectedDate);
    if (holidayName == null && islamicEvent != null && islamicEvent.isOfficialHoliday) {
      holidayName = urdu ? islamicEvent.titleUr : islamicEvent.titleEn;
    }
    final isSunday = _selectedDate.weekday == DateTime.sunday;
    final isFuture = _isFutureDate(_selectedDate);

    // Students and filters
    final students = studentsAsync.value ?? const <Map<String, dynamic>>[];
    final logData = logAsync.value ?? const <String, dynamic>{};
    final loading = (studentsAsync.isLoading && studentsAsync.value == null) || (logAsync.isLoading && logAsync.value == null);
    final branchSessions = CampSessionService.getMadrassaSessions(_effectiveBranch);
    final sessions = ['morning', 'evening', 'night']
        .where((s) => branchSessions.contains(s) || students.any((st) => (st['session'] ?? 'morning') == s))
        .toList();

    final scoped = students.where((s) {
      if (_selectedSessionFilter != 'all' &&
          (s['session'] ?? 'morning').toString().toLowerCase().trim() != _selectedSessionFilter) {
        return false;
      }
      final nazra = _isNazraStudent(s, nazraOnly);
      if (_selectedProgramFilter == 'hifz' && nazra) return false;
      if (_selectedProgramFilter == 'nazra' && !nazra) return false;
      return true;
    }).toList();

    final q = _searchText.trim().toLowerCase();
    final shown = scoped.where((s) {
      if (q.isNotEmpty) {
        final hay = '${s['name'] ?? ''} ${s['rollNumber'] ?? ''} ${s['fatherName'] ?? ''}'.toLowerCase();
        if (!hay.contains(q)) return false;
      }
      if (_statusFilter == 'all') return true;
      final v = _viewOf((s['id'] ?? '').toString(), logData);
      final att = (v['attendance'] ?? 'absent').toString();
      switch (_statusFilter) {
        case 'present':
          return att == 'present';
        case 'late':
          return att == 'present' && (v['isLate'] == true || v['timing'] == 'late');
        case 'leave':
          return att == 'leave';
        case 'absent':
          return att != 'present' && att != 'leave' && !_isPendingLeave(v);
        case 'requests':
          return _isPendingLeave(v);
        case 'unsaved':
          return _localChanges.containsKey((s['id'] ?? '').toString());
      }
      return true;
    }).toList();

    // Stats
    int present = 0, late = 0, leave = 0, absent = 0, replied = 0;
    for (final s in scoped) {
      final v = _viewOf((s['id'] ?? '').toString(), logData);
      final att = (v['attendance'] ?? 'absent').toString();
      if (att == 'present') {
        present++;
        if (v['isLate'] == true || v['timing'] == 'late') late++;
      } else if (att == 'leave') {
        leave++;
      } else {
        absent++;
      }
      if (v['parentReplied'] == true) replied++;
    }

    final dateNav = Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(
        tooltip: urdu ? 'پچھلا دن' : 'Previous day',
        visualDensity: VisualDensity.compact,
        onPressed: () => _goToDate(_selectedDate.subtract(const Duration(days: 1))),
        icon: const Icon(GIcons.back, size: 18),
      ),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          minimumSize: const Size(0, 34),
          padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3),
        ),
        onPressed: _pickDate,
        icon: const Icon(GIcons.calendar, size: 16),
        label: Text(DateFormat('EEE d MMM yyyy').format(_selectedDate), style: GText.label(c.textPrimary)),
      ),
      IconButton(
        tooltip: urdu ? 'اگلا دن' : 'Next day',
        visualDensity: VisualDensity.compact,
        onPressed: () => _goToDate(_selectedDate.add(const Duration(days: 1))),
        icon: const Icon(GIcons.forward, size: 18),
      ),
      if (!DateUtils.isSameDay(_selectedDate, DateTime.now()))
        TextButton(
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          onPressed: () => _goToDate(DateTime.now()),
          child: Text(urdu ? 'آج' : 'Today'),
        ),
    ]);

    final bell = Badge(
      isLabelVisible: requests.isNotEmpty,
      backgroundColor: _amber,
      offset: const Offset(-4, 4),
      label: Text('${requests.length}'),
      child: IconButton(
        tooltip: urdu ? 'رخصت کی درخواستیں' : 'Leave requests',
        onPressed: () => _showLeaveInbox(requests),
        icon: Icon(GIcons.notifications, color: c.textSecondary),
      ),
    );

    // The Madrassa hub's top bar already has the logo, the "Daily Log" title,
    // branch, sync, theme and language: this screen adds only its own controls.
    final dayCaption = [
      hijri,
      urdu ? '$workingDays تعلیمی دن' : '$workingDays working days',
      'PTM ${DateFormat('EEE d MMM').format(ptmDate)}',
      if (nazraOnly) urdu ? 'صرف ناظرہ' : 'Nazra only',
    ].join('  ·  ');
    final Widget header;
    if (MadrassaHubSlot.available(context) && !narrow) {
      // Desktop hub: the controls go into the hub's own top bar (no second row).
      final slot = _urduSafe(Row(children: [
        dateNav,
        const SizedBox(width: Gsp.sp3),
        Flexible(child: Text(dayCaption, maxLines: 1, overflow: TextOverflow.ellipsis, style: GText.caption(c.textMuted))),
        const Spacer(),
        bell,
      ]));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _publishedSlot = slot;
          MadrassaHubSlot.toolbar.value = slot;
        }
      });
      header = const SizedBox.shrink();
    } else {
      header = MadrassaErpControlBar(leading: [dateNav], caption: dayCaption, trailing: [bell]);
    }

    Widget body;
    if (holidayName != null || isSunday || isFuture) {
      body = Container(
        decoration: BoxDecoration(color: c.surface, borderRadius: MadrassaErp.radius, border: Border.all(color: c.border)),
        child: Center(
          child: AppEmptyState(
            icon: holidayName != null ? GIcons.event : (isSunday ? GIcons.calendar : GIcons.time),
            title: holidayName ??
                (isSunday
                    ? (urdu ? 'اتوار کی چھٹی' : 'Sunday — weekly holiday')
                    : (isPtmDay ? (urdu ? 'پی ٹی ایم شیڈول ہے' : 'PTM scheduled') : context.l.futureDateTitle)),
            subtitle: holidayName != null || isSunday
                ? (urdu ? 'اس دن مدرسہ بند ہے' : 'Madrassa is closed on this day')
                : context.l.futureDateSubtitle,
            action: requests.isEmpty
                ? null
                : OutlinedButton.icon(
                    onPressed: () => _showLeaveInbox(requests),
                    icon: const Icon(GIcons.notifications, size: 16),
                    label: Text(urdu ? 'رخصت کی درخواستیں (${requests.length})' : 'Leave requests (${requests.length})'),
                  ),
          ),
        ),
      );
    } else if (loading) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      final card = _buildRegisterCard(
        context,
        config: config,
        scoped: scoped,
        shown: shown,
        logData: logData,
        sessions: sessions,
        nazraOnly: nazraOnly,
        isReadOnly: isReadOnly,
        isPtmDay: isPtmDay,
        allowLeave: allowLeave,
        requests: requests,
      );
      final selected = _selectedStudentId == null
          ? null
          : students.firstWhereOrNull((s) => (s['id'] ?? '').toString() == _selectedStudentId);
      if (selected != null && MadrassaErp.roomForPanel(context)) {
        body = Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: card),
          const SizedBox(width: Gsp.sp4),
          SizedBox(
            width: 460,
            child: _studentPanel(selected,
                isPtmDay: isPtmDay, isReadOnly: isReadOnly, allowLeave: allowLeave, onClose: () => setState(() => _selectedStudentId = null)),
          ),
        ]);
      } else {
        body = card;
      }
    }

    final stats = MadrassaErpStatStrip([
      MadrassaErpStat(
        label: context.l.present,
        value: '$present',
        caption: late > 0 ? (urdu ? '$late تاخیر' : '$late late') : (urdu ? 'از ${scoped.length}' : 'of ${scoped.length}'),
        color: c.success,
        icon: GIcons.checkCircle,
        onTap: () => setState(() => _statusFilter = _statusFilter == 'present' ? 'all' : 'present'),
      ),
      MadrassaErpStat(
        label: context.l.late,
        value: '$late',
        color: c.warning,
        icon: GIcons.time,
        onTap: () => setState(() => _statusFilter = _statusFilter == 'late' ? 'all' : 'late'),
      ),
      MadrassaErpStat(
        label: context.l.leave,
        value: '$leave',
        color: c.info,
        icon: GIcons.event,
        onTap: () => setState(() => _statusFilter = _statusFilter == 'leave' ? 'all' : 'leave'),
      ),
      MadrassaErpStat(
        label: context.l.absent,
        value: '$absent',
        color: c.danger,
        icon: GIcons.cancel,
        onTap: () => setState(() => _statusFilter = _statusFilter == 'absent' ? 'all' : 'absent'),
      ),
      MadrassaErpStat(
        label: urdu ? 'جواب دیا' : 'Replied',
        value: '$replied',
        caption: urdu ? 'از ${scoped.length}' : 'of ${scoped.length}',
        color: c.brand,
        icon: GIcons.whatsapp,
      ),
      MadrassaErpStat(
        label: urdu ? 'رخصت کی درخواستیں' : 'Leave requests',
        value: '${requests.length}',
        caption: requests.isEmpty ? null : (urdu ? 'جواب دیں' : 'to answer'),
        color: requests.isEmpty ? c.textMuted : _amber,
        icon: GIcons.notifications,
        onTap: () => _showLeaveInbox(requests),
      ),
    ]);

    final readOnlyBanner = Container(
      padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3, vertical: Gsp.sp2),
      decoration: BoxDecoration(color: c.warningBg, borderRadius: MadrassaErp.radius, border: Border.all(color: c.warning.withValues(alpha: 0.4))),
      child: Row(children: [
        Icon(GIcons.lock, size: 16, color: c.warning),
        const SizedBox(width: Gsp.sp2),
        Expanded(
          child: Text(
            urdu
                ? 'صرف پڑھنے کے لیے: صرف موجودہ یا پچھلے مہینے کا ریکارڈ بدلا جا سکتا ہے۔'
                : 'Read only: only the current or previous month can be changed.',
            style: GText.caption(c.textPrimary),
          ),
        ),
      ]),
    );
    final openDay = holidayName == null && !isSunday && !isFuture;

    if (narrow) {
      // Phone: the header, banner and figures scroll away with the list, so the
      // students get the whole screen.
      return NestedScrollView(
        headerSliverBuilder: (context, _) => [
          SliverToBoxAdapter(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              header,
              Padding(
                padding: EdgeInsets.fromLTRB(pad, Gsp.sp2, pad, 0),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (isReadOnly) ...[readOnlyBanner, const SizedBox(height: Gsp.sp2)],
                  if (openDay) stats,
                ]),
              ),
            ]),
          ),
        ],
        body: Padding(padding: const EdgeInsets.only(top: Gsp.sp2), child: body),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      header,
      Expanded(
        child: Padding(
          padding: EdgeInsets.fromLTRB(pad, Gsp.sp3, pad, Gsp.sp3),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (isReadOnly) ...[readOnlyBanner, const SizedBox(height: Gsp.sp2)],
            if (openDay) ...[stats, const SizedBox(height: Gsp.sp3)],
            Expanded(child: body),
          ]),
        ),
      ),
    ]);
  }

  Widget _buildRegisterCard(
    BuildContext context, {
    required MadrassaConfig config,
    required List<Map<String, dynamic>> scoped,
    required List<Map<String, dynamic>> shown,
    required Map<String, dynamic> logData,
    required List<String> sessions,
    required bool nazraOnly,
    required bool isReadOnly,
    required bool isPtmDay,
    required bool allowLeave,
    required List<_LeaveRequest> requests,
  }) {
    final c = context.comfort;
    final urdu = context.isUrdu;
    final nazraCount = scoped.where((s) => _isNazraStudent(s, nazraOnly)).length;
    final unsaved = _localChanges.length;

    // PTM claims waiting for the teacher
    final ptmClaims = <Map<String, dynamic>>[];
    for (final s in scoped) {
      final sId = (s['id'] ?? '').toString();
      final v = _viewOf(sId, logData);
      if (v['ptmRequestStatus'] == 'claimed') {
        ptmClaims.add({'id': sId, 'name': s['name'] ?? 'Student', 'rollNumber': s['rollNumber'] ?? '?', 'log': v});
      }
    }

    // One list of actions: buttons on a desktop, one menu (plus Save) on a phone.
    final ops = <({String label, IconData icon, bool on, Color? tone, VoidCallback? onTap})>[
      (
        label: context.l.allPresent,
        icon: GIcons.checkCircle,
        on: _allPresentToggled,
        tone: null,
        onTap: isReadOnly
            ? null
            : () {
                _allPresentToggled = !_allPresentToggled;
                for (final s in shown) {
                  final sId = (s['id'] ?? '').toString();
                  final v = _viewOf(sId, logData);
                  final att = v['attendance'];
                  if (att != 'leave' && att != 'leave_requested' && !_isPendingLeave(v)) {
                    _updateAttendanceSilent(sId, _allPresentToggled ? 'present' : 'absent');
                  }
                }
                _changeNotifier.value++;
              },
      ),
      (
        label: context.l.allUniform,
        icon: GIcons.check,
        on: _allUniformToggled,
        tone: null,
        onTap: isReadOnly
            ? null
            : () {
                _allUniformToggled = !_allUniformToggled;
                for (final s in shown) {
                  final sId = (s['id'] ?? '').toString();
                  if (_viewOf(sId, logData)['attendance'] == 'present') {
                    _updateLocalSilent(sId, 'uniform', _allUniformToggled);
                  }
                }
              },
      ),
      (
        label: urdu ? 'سب نے جواب دیا' : 'All replied',
        icon: GIcons.whatsapp,
        on: _allRepliedToggled,
        tone: null,
        onTap: isReadOnly
            ? null
            : () {
                _allRepliedToggled = !_allRepliedToggled;
                for (final s in shown) {
                  _updateLocalSilent((s['id'] ?? '').toString(), 'parentReplied', _allRepliedToggled);
                }
              },
      ),
      (
        label: urdu ? 'گروپ رپورٹ' : 'Group report',
        icon: GIcons.share,
        on: false,
        tone: null,
        onTap: () => _showDailyReportDialog(config, shown, logData),
      ),
      if (requests.isNotEmpty)
        (
          label: urdu ? 'سب رخصتیں منظور (${requests.length})' : 'Approve all leaves (${requests.length})',
          icon: GIcons.checkCircle,
          on: false,
          tone: c.success,
          onTap: () => _approveAllLeaves(requests),
        ),
      if (ptmClaims.isNotEmpty && !isReadOnly)
        (
          label: urdu ? 'پی ٹی ایم دعوے (${ptmClaims.length})' : 'PTM claims (${ptmClaims.length})',
          icon: GIcons.users,
          on: false,
          tone: c.info,
          onTap: () => _showPtmClaimsPopup(context, ptmClaims),
        ),
    ];

    final saveButton = FilledButton.icon(
      onPressed: unsaved == 0 || _isSaving || isReadOnly ? null : _saveChanges,
      icon: _isSaving
          ? SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5, color: c.onBrand))
          : const Icon(GIcons.save, size: 16),
      label: Text(unsaved == 0 ? context.l.saveChanges : '${context.l.saveChanges} ($unsaved)'),
    );

    final actions = <Widget>[
      for (final o in ops)
        o.on
            ? FilledButton.tonalIcon(onPressed: o.onTap, icon: Icon(o.icon, size: 16), label: Text(o.label))
            : OutlinedButton.icon(
                style: o.tone == null
                    ? null
                    : OutlinedButton.styleFrom(foregroundColor: o.tone, side: BorderSide(color: o.tone!.withValues(alpha: 0.5))),
                onPressed: o.onTap,
                icon: Icon(o.icon, size: 16),
                label: Text(o.label),
              ),
      saveButton,
    ];

    final filters = <Widget>[
      SizedBox(
        width: MadrassaErp.narrow(context) ? 200 : 240,
        height: 38,
        child: TextField(
          controller: _searchCtrl,
          onChanged: (v) => setState(() => _searchText = v),
          style: GText.body2(c.textPrimary),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
            prefixIcon: const Icon(GIcons.search, size: 18),
            hintText: urdu ? 'نام یا رول نمبر' : 'Name or roll no.',
            suffixIcon: _searchText.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(GIcons.close, size: 16),
                    onPressed: () {
                      _searchCtrl.clear();
                      setState(() => _searchText = '');
                    },
                  ),
          ),
        ),
      ),
      if (!nazraOnly)
        MadrassaErpFilter<String>(
          label: urdu ? 'پروگرام' : 'Program',
          value: _selectedProgramFilter,
          width: 150,
          options: {
            'all': urdu ? 'سب' : 'All',
            'hifz': '${urdu ? 'حفظ' : 'Hifz'}${_selectedProgramFilter == 'all' ? ' (${scoped.length - nazraCount})' : ''}',
            'nazra': '${urdu ? 'ناظرہ' : 'Nazra'}${_selectedProgramFilter == 'all' ? ' ($nazraCount)' : ''}',
          },
          onChanged: (v) => setState(() => _selectedProgramFilter = v),
        ),
      if (sessions.length > 1)
        MadrassaErpFilter<String>(
          label: urdu ? 'سیشن' : 'Session',
          value: _selectedSessionFilter,
          width: 140,
          options: {'all': urdu ? 'سب' : 'All', for (final s in sessions) s: _sessionLabel(s)},
          onChanged: (v) => setState(() => _selectedSessionFilter = v),
        ),
      MadrassaErpFilter<String>(
        label: urdu ? 'حالت' : 'Status',
        value: _statusFilter,
        width: 150,
        options: {
          'all': urdu ? 'سب' : 'All',
          'present': context.l.present,
          'late': context.l.late,
          'leave': context.l.leave,
          'absent': context.l.absent,
          'requests': urdu ? 'درخواستیں' : 'Leave requests',
          'unsaved': urdu ? 'غیر محفوظ' : 'Unsaved',
        },
        onChanged: (v) => setState(() => _statusFilter = v),
      ),
      if (_isGlobalLevelUser(widget.editorRole))
        Tooltip(
          message: urdu
              ? 'تمام یوزرز کے لیے رخصت (L) کا بٹن دکھائیں یا چھپائیں'
              : 'Show or hide the Leave (L) button for all users',
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Switch(value: allowLeave, onChanged: (v) => _setAllowLeave(v)),
            Text(urdu ? 'رخصت (L) کی اجازت' : 'Leave (L) allowed', style: GText.caption(c.textSecondary)),
          ]),
        ),
    ];

    // Phone: every action except Save goes into one menu; filters scroll in one line.
    final phone = MadrassaErp.narrow(context);
    List<Widget> phoneActions() => [
          PopupMenuButton<int>(
            tooltip: urdu ? 'مزید' : 'More actions',
            icon: Badge(isLabelVisible: requests.isNotEmpty, smallSize: 8, backgroundColor: _amber, child: const Icon(GIcons.more)),
            itemBuilder: (_) => [
              for (final (i, o) in ops.indexed)
                PopupMenuItem<int>(
                  value: i,
                  enabled: o.onTap != null,
                  child: Row(children: [
                    Icon(o.on ? GIcons.checkCircle : o.icon, size: 18, color: o.tone ?? c.textSecondary),
                    const SizedBox(width: Gsp.sp3),
                    Flexible(child: Text(o.label, style: GText.body2(c.textPrimary))),
                  ]),
                ),
            ],
            onSelected: (i) => ops[i].onTap?.call(),
          ),
          saveButton,
        ];

    if (phone) {
      // Phone: one row (search · filter menu · more menu), the list edge to edge,
      // and Save as a bottom bar only while there is something to save.
      final filterActive = _selectedProgramFilter != 'all' || _selectedSessionFilter != 'all' || _statusFilter != 'all';
      PopupMenuItem<String> head(String t) =>
          PopupMenuItem<String>(enabled: false, height: 28, child: Text(t.toUpperCase(), style: GText.overline(c.textMuted)));
      CheckedPopupMenuItem<String> pick(String value, String label, bool on) =>
          CheckedPopupMenuItem<String>(value: value, checked: on, child: Text(label, style: GText.body2(c.textPrimary)));
      final statusLabels = {
        'all': urdu ? 'سب' : 'All',
        'present': context.l.present,
        'late': context.l.late,
        'leave': context.l.leave,
        'absent': context.l.absent,
        'requests': urdu ? 'درخواستیں' : 'Leave requests',
        'unsaved': urdu ? 'غیر محفوظ' : 'Unsaved',
      };
      final filterMenu = PopupMenuButton<String>(
        tooltip: urdu ? 'فلٹر' : 'Filter',
        icon: Badge(isLabelVisible: filterActive, smallSize: 8, backgroundColor: c.brand, child: Icon(GIcons.filter, color: c.textSecondary)),
        itemBuilder: (_) => [
          if (!nazraOnly) ...[
            head(urdu ? 'پروگرام' : 'Program'),
            pick('p:all', urdu ? 'سب' : 'All', _selectedProgramFilter == 'all'),
            pick('p:hifz', '${urdu ? 'حفظ' : 'Hifz'} (${scoped.length - nazraCount})', _selectedProgramFilter == 'hifz'),
            pick('p:nazra', '${urdu ? 'ناظرہ' : 'Nazra'} ($nazraCount)', _selectedProgramFilter == 'nazra'),
            const PopupMenuDivider(),
          ],
          if (sessions.length > 1) ...[
            head(urdu ? 'سیشن' : 'Session'),
            pick('s:all', urdu ? 'سب' : 'All', _selectedSessionFilter == 'all'),
            for (final s in sessions) pick('s:$s', _sessionLabel(s), _selectedSessionFilter == s),
            const PopupMenuDivider(),
          ],
          head(urdu ? 'حالت' : 'Status'),
          for (final e in statusLabels.entries) pick('t:${e.key}', e.value, _statusFilter == e.key),
          if (_isGlobalLevelUser(widget.editorRole)) ...[
            const PopupMenuDivider(),
            pick('leave', urdu ? 'رخصت (L) کی اجازت' : 'Leave (L) allowed', allowLeave),
          ],
        ],
        onSelected: (v) {
          if (v == 'leave') {
            _setAllowLeave(!allowLeave);
            return;
          }
          final val = v.substring(2);
          setState(() {
            if (v.startsWith('p:')) _selectedProgramFilter = val;
            if (v.startsWith('s:')) _selectedSessionFilter = val;
            if (v.startsWith('t:')) _statusFilter = val;
          });
        },
      );
      return Container(
        decoration: BoxDecoration(color: c.surface, border: Border.symmetric(horizontal: BorderSide(color: c.border))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(Gsp.sp2, Gsp.sp2, 0, Gsp.sp2),
            child: Row(children: [
              Expanded(
                child: SizedBox(
                  height: 38,
                  child: TextField(
                    controller: _searchCtrl,
                    onChanged: (v) => setState(() => _searchText = v),
                    style: GText.body2(c.textPrimary),
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                      prefixIcon: const Icon(GIcons.search, size: 18),
                      hintText: urdu
                          ? 'تلاش (${shown.length}/${scoped.length})'
                          : 'Search ${shown.length} of ${scoped.length}',
                    ),
                  ),
                ),
              ),
              filterMenu,
              phoneActions().first,
            ]),
          ),
          Divider(height: 1, color: c.border),
          Expanded(
            child: _registerTable(context,
                rows: shown, logData: logData, nazraOnly: nazraOnly, isReadOnly: isReadOnly, isPtmDay: isPtmDay, allowLeave: allowLeave),
          ),
          if (unsaved > 0 && !isReadOnly)
            Container(
              padding: const EdgeInsets.fromLTRB(Gsp.sp3, Gsp.sp2, Gsp.sp3, Gsp.sp2),
              decoration: BoxDecoration(color: c.surfaceRaised, border: Border(top: BorderSide(color: c.border))),
              child: Row(children: [
                Expanded(
                  child: Text(
                    urdu ? '$unsaved طلباء کی تبدیلیاں باقی' : '$unsaved student(s) not saved',
                    style: GText.caption(c.warning),
                  ),
                ),
                saveButton,
              ]),
            ),
        ]),
      );
    }

    return MadrassaErpCard(
      title: urdu ? 'حاضری رجسٹر' : 'Register',
      subtitle: urdu
          ? '${scoped.length} میں سے ${shown.length} طلباء'
          : '${shown.length} of ${scoped.length} students${unsaved > 0 ? ' · $unsaved unsaved' : ''}',
      actions: actions,
      toolbar: phone
          ? SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (final (i, f) in filters.indexed) ...[if (i > 0) const SizedBox(width: Gsp.sp2), f],
              ]),
            )
          : Wrap(spacing: Gsp.sp2, runSpacing: Gsp.sp2, crossAxisAlignment: WrapCrossAlignment.center, children: filters),
      child: _registerTable(context,
          rows: shown, logData: logData, nazraOnly: nazraOnly, isReadOnly: isReadOnly, isPtmDay: isPtmDay, allowLeave: allowLeave),
    );
  }

  void _setAllowLeave(bool allow) {
    setState(() => _localAllowStudentLeave = allow);
    unawaited(FirebaseFirestore.instance
        .collection('branches')
        .doc(_effectiveBranch)
        .collection('madrassa_config')
        .doc('current')
        .set({'allowStudentLeave': allow}, SetOptions(merge: true))
        .timeout(const Duration(seconds: 4))
        .catchError((err) {
      debugPrint('[DailyLogView] Update allowStudentLeave error: $err');
    }));
    AppToast.showSnackBar(
      context,
      SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(allow
            ? (context.isUrdu ? 'رخصت (L) کا بٹن سب کے لیے آن ہے۔' : 'Leave (L) button is now shown to all users.')
            : (context.isUrdu ? 'رخصت (L) کا بٹن سب کے لیے بند ہے۔' : 'Leave (L) button is now hidden from all users.')),
      ),
    );
  }

  // ── Table ──────────────────────────────────────────────────────────────────

  static const double _wRoll = 40, _wAtt = 118, _wLate = 76, _wTick = 62, _wSabak = 110, _wLesson = 168, _wPtm = 74, _wAct = 64;

  Widget _registerTable(
    BuildContext context, {
    required List<Map<String, dynamic>> rows,
    required Map<String, dynamic> logData,
    required bool nazraOnly,
    required bool isReadOnly,
    required bool isPtmDay,
    required bool allowLeave,
  }) {
    final c = context.comfort;
    final urdu = context.isUrdu;
    if (rows.isEmpty) {
      return Center(
        child: AppEmptyState(
          icon: GIcons.searchOff,
          title: urdu ? 'کوئی طالب علم نہیں ملا' : 'No students match',
          subtitle: urdu ? 'فلٹر بدل کر دیکھیں۔' : 'Try another filter or search.',
          compact: true,
        ),
      );
    }
    if (MadrassaErp.narrow(context)) {
      // Phone: variable-height two-line rows, no sideways scrolling.
      return ListView.builder(
        itemCount: rows.length,
        itemBuilder: (context, i) {
          final s = rows[i];
          return _registerRow(context, s, _viewOf((s['id'] ?? '').toString(), logData), i,
              nazraOnly: nazraOnly, isReadOnly: isReadOnly, isPtmDay: isPtmDay, allowLeave: allowLeave, gap: (w) => w);
        },
      );
    }
    final allNazra = rows.every((s) => _isNazraStudent(s, nazraOnly));
    final minWidth = 220 + _wRoll + _wAtt + _wLate + _wTick * 2 + _wSabak + _wLesson * 2 + _wAct + (isPtmDay ? _wPtm : 0) + 11 * Gsp.sp2 + 2 * Gsp.sp3;

    Widget head(String label, double? w, {bool center = false}) {
      final t = Text(label.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: GText.overline(c.textMuted));
      return w == null
          ? Expanded(child: t)
          : SizedBox(width: w, child: center ? Center(child: t) : t);
    }

    List<Widget> gap(List<Widget> cells) => [
          for (final (i, w) in cells.indexed) ...[if (i > 0) const SizedBox(width: Gsp.sp2), w],
        ];

    final header = Container(
      height: MadrassaErp.headerHeight,
      color: c.surfaceSunken,
      padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3),
      child: Row(
        children: gap([
          head('#', _wRoll),
          head(urdu ? 'طالب علم' : 'Student', null),
          head(urdu ? 'حاضری' : 'P · L · A', _wAtt),
          head(context.l.late, _wLate, center: true),
          head(context.l.uniform, _wTick, center: true),
          head(urdu ? 'جواب' : 'Replied', _wTick, center: true),
          head(urdu ? 'سبق' : 'Sabak', _wSabak, center: true),
          head(allNazra ? (urdu ? 'رکوع' : 'Ruku') : (urdu ? 'سبقی' : 'Sabqi'), _wLesson),
          head(allNazra ? (urdu ? 'قاعدہ' : 'Qaida') : (urdu ? 'منزل' : 'Manzil'), _wLesson),
          if (isPtmDay) head(context.l.ptm, _wPtm, center: true),
          head('', _wAct),
        ]),
      ),
    );

    final list = ListView.builder(
      itemCount: rows.length,
      itemExtent: MadrassaErp.rowHeight,
      itemBuilder: (context, i) {
        final s = rows[i];
        final sId = (s['id'] ?? '').toString();
        return _registerRow(context, s, _viewOf(sId, logData), i,
            nazraOnly: nazraOnly, isReadOnly: isReadOnly, isPtmDay: isPtmDay, allowLeave: allowLeave, gap: gap);
      },
    );

    return LayoutBuilder(builder: (context, box) {
      final width = box.maxWidth < minWidth ? minWidth : box.maxWidth;
      final grid = SizedBox(width: width, child: Column(children: [header, Expanded(child: list)]));
      if (width <= box.maxWidth) return grid;
      return Scrollbar(
        child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: SizedBox(height: box.maxHeight, child: grid)),
      );
    });
  }

  Widget _registerRow(
    BuildContext context,
    Map<String, dynamic> s,
    Map<String, dynamic> v,
    int index, {
    required bool nazraOnly,
    required bool isReadOnly,
    required bool isPtmDay,
    required bool allowLeave,
    required List<Widget> Function(List<Widget>) gap,
  }) {
    final c = context.comfort;
    final urdu = context.isUrdu;
    final sId = (s['id'] ?? '').toString();
    final att = (v['attendance'] ?? 'absent').toString();
    final present = att == 'present';
    final pendingLeave = _isPendingLeave(v);
    final isLate = v['isLate'] == true || v['timing'] == 'late';
    final arrival = v['arrivalTime']?.toString();
    final uniform = att == 'leave' || v['uniform'] == true || v['uniform'] == 'leave';
    final replied = v['parentReplied'] == true;
    final replyText = (v['parentReplyText'] ?? v['parentReplyMessage'])?.toString().trim() ?? '';
    final replyWaiting = !replied && (v['parentRepliedRequested'] == true || replyText.isNotEmpty);
    final nazra = _isNazraStudent(s, nazraOnly);
    final unsaved = _localChanges.containsKey(sId);
    final selected = _selectedStudentId == sId;
    final lines = v['sabakLines'] != null ? _asInt(v['sabakLines']) : 0;
    final totalLines = v['currentLines'] != null
        ? _asInt(v['currentLines'])
        : _asInt(s['currentLines']);
    final canEdit = !isReadOnly;
    final name = (s['name'] ?? '—').toString();
    final session = (s['session'] ?? 'morning').toString().toLowerCase().trim();

    // Attendance cell
    Widget attCell;
    if (pendingLeave) {
      attCell = Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(
          child: InkWell(
            borderRadius: BorderRadius.circular(Gr.r2),
            onTap: canEdit
                ? () => _openLeaveRequest(_LeaveRequest(dateKey: _dateKey, studentId: sId, student: s, log: v))
                : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(color: _amber.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(Gr.r2), border: Border.all(color: _amber.withValues(alpha: 0.55))),
              child: Text(urdu ? 'درخواست' : 'Request', maxLines: 1, overflow: TextOverflow.ellipsis, style: GText.micro(_amberText).copyWith(fontWeight: FontWeight.w700)),
            ),
          ),
        ),
        if (canEdit) ...[
          IconButton(
            tooltip: urdu ? 'منظور' : 'Approve',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            padding: EdgeInsets.zero,
            onPressed: () => _decideLeaveNow(_LeaveRequest(dateKey: _dateKey, studentId: sId, student: s, log: v), approve: true),
            icon: Icon(GIcons.checkCircle, size: 18, color: c.success),
          ),
          IconButton(
            tooltip: urdu ? 'مسترد' : 'Deny',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            padding: EdgeInsets.zero,
            onPressed: () => _decideLeaveNow(_LeaveRequest(dateKey: _dateKey, studentId: sId, student: s, log: v), approve: false),
            icon: Icon(GIcons.cancel, size: 18, color: c.danger),
          ),
        ],
      ]);
    } else {
      Widget seg(String label, String value, Color tone, {bool enabled = true}) {
        final on = att == value;
        return Tooltip(
          message: value == 'present' ? context.l.present : (value == 'leave' ? context.l.leave : context.l.absent),
          child: InkWell(
            borderRadius: BorderRadius.circular(Gr.r2),
            onTap: canEdit && enabled && !on ? () => _updateAttendanceSilent(sId, value) : null,
            child: Container(
              width: 32,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: on ? tone : (enabled ? c.surface : c.surfaceSunken),
                borderRadius: BorderRadius.circular(Gr.r2),
                border: Border.all(color: on ? tone : c.border),
              ),
              child: Text(label, style: GText.label(on ? c.onBrand : (enabled ? c.textSecondary : c.textMuted.withValues(alpha: 0.5)))),
            ),
          ),
        );
      }

      final showLeave = allowLeave || att == 'leave';
      attCell = Row(mainAxisSize: MainAxisSize.min, children: [
        seg('P', 'present', c.success),
        const SizedBox(width: 4),
        if (showLeave) ...[seg('L', 'leave', c.info, enabled: allowLeave), const SizedBox(width: 4)],
        seg('A', 'absent', c.danger),
      ]);
    }

    // Lesson cells
    Widget muted(String t) => Text(t, maxLines: 1, overflow: TextOverflow.ellipsis, style: GText.caption(c.textMuted));

    Widget sabakCell;
    if (!present) {
      sabakCell = Center(child: muted(lines > 0 ? '$lines' : '—'));
    } else {
      sabakCell = Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        _miniIconButton(Icons.remove_rounded, canEdit && lines > 0 ? () => _updateSabakLines(sId, lines - 1) : null,
            tooltip: urdu ? 'ایک لائن کم' : 'One line less'),
        InkWell(
          onTap: canEdit ? () => _showCustomLinesDialog(context, sId, lines) : null,
          borderRadius: BorderRadius.circular(Gr.r2),
          child: Container(
            width: 36,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: c.surfaceSunken, borderRadius: BorderRadius.circular(Gr.r2)),
            child: Text('$lines', style: GText.label(c.textPrimary).copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
          ),
        ),
        _miniIconButton(GIcons.add, canEdit ? () => _updateSabakLines(sId, (lines + 1).clamp(0, 8640)) : null,
            tooltip: urdu ? 'ایک لائن زیادہ' : 'One line more'),
      ]);
    }

    Widget paraRatioCell(String paraKey, String ratioKey) {
      final para = _asInt(v[paraKey]);
      final ratio = v[ratioKey]?.toString();
      if (!present) {
        final txt = ratio == 'nahi_sunaya'
            ? _ratioLabel(ratio)
            : (para > 0 ? '${urdu ? 'پارہ' : 'Para'} $para · ${_ratioLabel(ratio)}' : '—');
        return muted(txt);
      }
      return Row(children: [
        SizedBox(
          width: 62,
          child: _miniDropdown<int>(
            value: para == 0 ? null : para,
            hint: urdu ? 'پارہ' : 'Para',
            items: {for (int p = 1; p <= 30; p++) p: '$p'},
            onChanged: canEdit ? (val) => _updateLocalSilent(sId, paraKey, val ?? 0) : null,
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: _miniDropdown<String>(
            value: (ratio == null || ratio.isEmpty || ratio == '-') ? null : ratio,
            hint: urdu ? 'مقدار' : 'Amount',
            items: {for (final r in const ['1/4', '1/2', '3/4', '1', 'nahi_sunaya']) r: _ratioLabel(r)},
            onChanged: canEdit ? (val) => _updateLocalSilent(sId, ratioKey, val ?? '-') : null,
          ),
        ),
      ]);
    }

    Widget nazraSummary(String text) => InkWell(
          onTap: () => _openStudent(s),
          child: Row(children: [
            Expanded(child: muted(text)),
            if (present && canEdit) Icon(GIcons.edit, size: 14, color: c.textMuted),
          ]),
        );

    Widget lesson1;
    Widget lesson2;
    if (nazra) {
      final rukuPara = _asInt(v['rukuPara']);
      final ruku = v['ruku']?.toString();
      lesson1 = nazraSummary(ruku == 'nahi_sunaya'
          ? _ratioLabel(ruku)
          : (rukuPara > 0 && ruku != null && ruku != '-' ? '${urdu ? 'پارہ' : 'Para'} $rukuPara · ${urdu ? 'رکوع' : 'Ruku'} $ruku' : '—'));
      final qaidaDone = v['qaidaCompleted'] != false &&
          (s['qaidaCompleted'] == true || v['qaidaCompleted'] == true || v['qaidaSabak'] == 'completed');
      final qaida = (v['qaidaSabak'] ?? s['qaidaSabak'])?.toString();
      lesson2 = nazraSummary(qaidaDone
          ? (urdu ? 'قاعدہ مکمل' : 'Qaida complete')
          : (qaida != null && qaida != '-' && qaida != '0' ? '${urdu ? 'تختی' : 'Lesson'} $qaida' : '—'));
    } else {
      lesson1 = paraRatioCell('sabkiPara', 'sabkiRatio');
      lesson2 = paraRatioCell('manzilPara', 'manzilRatio');
    }

    Widget ptmCell() => Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          MadrassaTick(
            on: v['ptm'] == true,
            onIcon: GIcons.users,
            tooltip: urdu ? 'والدین آئے' : 'Parent came',
            onTap: canEdit ? () => _updateLocalSilent(sId, 'ptm', v['ptm'] == true ? null : true) : null,
          ),
          MadrassaTick(
            on: v['ptm'] == false,
            color: c.danger,
            onIcon: GIcons.close,
            tooltip: urdu ? 'والدین نہیں آئے' : 'Parent missed',
            onTap: canEdit ? () => _updateLocalSilent(sId, 'ptm', v['ptm'] == false ? null : false) : null,
          ),
        ]);

    final sub = <String>[
      if (!nazraOnly) nazra ? (urdu ? 'ناظرہ' : 'Nazra') : (urdu ? 'حفظ' : 'Hifz'),
      _sessionLabel(session),
      if (!nazra && totalLines >= 8640) urdu ? 'حفظ مکمل' : 'Hifz complete',
    ].join(' · ');
    final leaveReason = att == 'leave' || pendingLeave ? (v['leaveReason'] ?? '').toString().trim() : '';

    final rowColor = selected
        ? c.brandSoft
        : (pendingLeave
            ? _amber.withValues(alpha: 0.07)
            : (index.isOdd ? c.surfaceSunken.withValues(alpha: 0.35) : c.surface));

    final lateTick = present
        ? MadrassaTick(
            on: isLate,
            color: c.warning,
            onIcon: GIcons.time,
            // Phones have no room for the time beside the mark: it is in the tooltip.
            label: (MadrassaErp.narrow(context) || arrival == null || arrival.isEmpty) ? null : arrival.replaceAll(' ', ''),
            tooltip: isLate
                ? '${arrival == null || arrival.isEmpty ? '' : '$arrival · '}'
                    '${urdu ? 'دیر سے آیا — وقت بدلنے کے لیے کھولیں' : 'Late — open the row to change the time'}'
                : (urdu ? 'وقت پر' : 'On time'),
            onTap: canEdit ? () => _toggleLate(sId, !isLate, v) : null,
          )
        : muted('—');
    final uniformTick = MadrassaTick(
      on: uniform,
      color: att == 'leave' ? c.info : c.success,
      onIcon: GIcons.clothes,
      tooltip: context.l.uniform,
      onTap: canEdit && present ? () => _updateLocalSilent(sId, 'uniform', !(v['uniform'] == true)) : null,
    );
    final repliedTick = Badge(
      isLabelVisible: replyWaiting,
      smallSize: 8,
      backgroundColor: c.info,
      child: MadrassaTick(
        on: replied,
        color: c.brand,
        onIcon: GIcons.whatsapp,
        tooltip: replyWaiting
            ? (replyText.isNotEmpty
                ? '${urdu ? 'والدین کا جواب' : 'Parent reply'}: $replyText'
                : (urdu ? 'والدین نے جواب کی تصدیق مانگی' : 'Parent asked to confirm a reply'))
            : context.l.parentReplied,
        onTap: canEdit
            ? () {
                _updateLocalSilent(sId, 'parentReplied', !replied);
                if (!replied) _updateLocalSilent(sId, 'parentRepliedRequested', false);
              }
            : null,
      ),
    );
    final nameBlock = Row(children: [
      _studentAvatar(s, sId, name),
      const SizedBox(width: Gsp.sp2 + 2),
      Expanded(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
          MadrassaUrduAwareText(name, color: c.textPrimary),
          const SizedBox(height: 2),
          Row(children: [
            Flexible(child: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: GText.micro(c.textMuted))),
            if (leaveReason.isNotEmpty) ...[
              Text('  ·  ${context.l.leave}: ', style: GText.micro(c.textMuted)),
              Flexible(child: MadrassaUrduAwareText(leaveReason, color: c.textMuted, size: 10.5, bold: false)),
            ],
          ]),
        ]),
      ),
    ]);

    // Phone: two short lines per student instead of a wide grid.
    if (MadrassaErp.narrow(context)) {
      // Icon instead of a word label keeps all marks and Sabak on one line.
      Widget labelled(IconData icon, String label, Widget child) => Tooltip(
            message: label,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              child,
            ]),
          );
      return Material(
        color: rowColor,
        child: InkWell(
          onTap: () => _openStudent(s),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: Gsp.sp2, vertical: 6),
            decoration: BoxDecoration(
              border: BorderDirectional(
                bottom: BorderSide(color: c.border),
                start: BorderSide(color: selected ? c.brand : (unsaved ? c.warning : Colors.transparent), width: 3),
              ),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                SizedBox(
                  width: 26,
                  child: Text(s['rollNumber']?.toString() ?? '—', style: GText.label(c.textMuted)),
                ),
                Expanded(child: nameBlock),
                const SizedBox(width: Gsp.sp2),
                attCell,
              ]),
              if (!pendingLeave && att != 'leave')
                Padding(
                  padding: const EdgeInsetsDirectional.only(start: 26 + 34 + Gsp.sp2 + 2),
                  child: Row(children: [
                    if (present) ...[labelled(GIcons.time, context.l.late, lateTick), const SizedBox(width: Gsp.sp2)],
                    labelled(GIcons.clothes, context.l.uniform, uniformTick),
                    const SizedBox(width: Gsp.sp2),
                    labelled(GIcons.whatsapp, context.l.parentReplied, repliedTick),
                    const Spacer(),
                    if (present) SizedBox(width: 100, child: sabakCell),
                  ]),
                ),
            ]),
          ),
        ),
      );
    }

    return RepaintBoundary(
      child: Material(
        color: rowColor,
        child: InkWell(
          hoverColor: c.textPrimary.withValues(alpha: 0.04),
          onTap: () => _openStudent(s),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3),
            decoration: BoxDecoration(
              border: BorderDirectional(
                bottom: BorderSide(color: c.border),
                start: BorderSide(color: selected ? c.brand : (unsaved ? c.warning : Colors.transparent), width: 3),
              ),
            ),
            child: Row(
              children: gap([
                SizedBox(
                  width: _wRoll,
                  child: Text(s['rollNumber']?.toString() ?? '—',
                      style: GText.label(c.textMuted).copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                ),
                Expanded(child: nameBlock),
                SizedBox(width: _wAtt, child: attCell),
                SizedBox(width: _wLate, child: Center(child: lateTick)),
                SizedBox(width: _wTick, child: Center(child: uniformTick)),
                SizedBox(width: _wTick, child: Center(child: repliedTick)),
                SizedBox(width: _wSabak, child: sabakCell),
                SizedBox(width: _wLesson, child: lesson1),
                SizedBox(width: _wLesson, child: lesson2),
                if (isPtmDay) SizedBox(width: _wPtm, child: ptmCell()),
                SizedBox(
                  width: _wAct,
                  child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    _miniIconButton(GIcons.whatsapp, () => _sendDailyWhatsApp(s, v),
                        tooltip: urdu ? 'واٹس ایپ رپورٹ' : 'WhatsApp report', color: c.success),
                    _miniIconButton(GIcons.chevronRight, () => _openStudent(s), tooltip: urdu ? 'تفصیل' : 'Details'),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  /// Student photo (base64 or URL) as a 34 px circle, or the first letter.
  /// Tap: enlarge, with "Change photo"; no photo yet: pick one.
  Widget _studentAvatar(Map<String, dynamic> s, String sId, String name) {
    final c = context.comfort;
    const size = 34.0;
    final raw = (s['photoUrl'] ??
            s['photo_url'] ??
            s['photoBase64'] ??
            s['studentPhotoBase64'] ??
            s['avatarUrl'] ??
            s['imageUrl'] ??
            s['profileImage'])
        ?.toString()
        .trim();
    final bytes = ImageUploadService.decodeBase64ToBytes(raw);
    final letter = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.brandSoft, shape: BoxShape.circle),
      child: (name.isEmpty || MadrassaErp.isUrduText(name))
          ? Icon(Icons.person_rounded, size: size * 0.55, color: c.brand)
          : Text(name.characters.first.toUpperCase(),
          style: GText.label(c.brand).copyWith(fontFamilyFallback: const ['Noori'])),
    );
    Widget img;
    if (_uploadStates[sId] == PhotoUploadStatus.uploading) {
      img = const SizedBox(width: size, height: size, child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator(strokeWidth: 2)));
    } else if (bytes != null) {
      img = ClipOval(
        child: Image.memory(bytes, width: size, height: size, fit: BoxFit.cover, cacheWidth: 96, gaplessPlayback: true, errorBuilder: (_, _, _) => letter),
      );
    } else if (raw != null && raw.startsWith('http')) {
      img = ClipOval(child: Image.network(raw, width: size, height: size, fit: BoxFit.cover, cacheWidth: 96, errorBuilder: (_, _, _) => letter));
    } else {
      img = letter;
    }
    final hasPhoto = bytes != null || (raw != null && raw.startsWith('http'));
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: () {
        if (!hasPhoto) {
          _pickAndUploadPhoto(sId);
          return;
        }
        showDialog<void>(
          context: context,
          builder: (ctx) => Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.all(Gsp.sp4),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(Gr.r4),
                child: InteractiveViewer(
                  maxScale: 4,
                  child: bytes != null
                      ? Image.memory(bytes, width: 320, height: 320, fit: BoxFit.contain)
                      : Image.network(raw!, width: 320, height: 320, fit: BoxFit.contain),
                ),
              ),
              const SizedBox(height: Gsp.sp3),
              Wrap(spacing: Gsp.sp2, children: [
                FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _pickAndUploadPhoto(sId);
                  },
                  icon: const Icon(GIcons.edit, size: 16),
                  label: Text(context.isUrdu ? 'تصویر بدلیں' : 'Change photo'),
                ),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(backgroundColor: c.surface),
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(context.isUrdu ? 'بند کریں' : 'Close'),
                ),
              ]),
            ]),
          ),
        );
      },
      child: Tooltip(message: hasPhoto ? name : (context.isUrdu ? 'تصویر لگائیں' : 'Add photo'), child: img),
    );
  }

  void _toggleLate(String sId, bool late, Map<String, dynamic> v) {
    _updateLocalSilent(sId, 'isLate', late);
    _updateLocalSilent(sId, 'timing', late ? 'late' : 'on_time');
    if (late) {
      final existing = v['arrivalTime']?.toString();
      if (existing == null || existing.isEmpty) {
        _updateLocalSilent(sId, 'arrivalTime', DateFormat('hh:mm a').format(DateTime.now()));
      }
    } else {
      _updateLocalSilent(sId, 'arrivalTime', null);
    }
  }

  Widget _miniIconButton(IconData icon, VoidCallback? onTap, {String? tooltip, Color? color}) {
    final c = context.comfort;
    // Fixed 28 px target: IconButton grows to the theme's minimum size (40+)
    // in some themes and overflowed the Sabak cell.
    final button = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: 28,
        height: 28,
        child: Icon(icon, size: 16, color: onTap == null ? c.textMuted.withValues(alpha: 0.4) : (color ?? c.textSecondary)),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }

  Widget _miniDropdown<T>({
    required T? value,
    required String hint,
    required Map<T, String> items,
    required ValueChanged<T?>? onChanged,
  }) {
    final c = context.comfort;
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: onChanged == null ? c.surfaceSunken : c.surface,
        border: Border.all(color: value == null ? c.border : c.brand.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(Gr.r2),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: items.containsKey(value) ? value : null,
          isDense: true,
          isExpanded: true,
          hint: Text(hint, maxLines: 1, overflow: TextOverflow.ellipsis, style: GText.caption(c.textMuted)),
          icon: Icon(GIcons.chevronDown, size: 14, color: c.textMuted),
          dropdownColor: c.surfaceRaised,
          style: GText.caption(c.textPrimary).copyWith(fontWeight: FontWeight.w600),
          items: [
            for (final e in items.entries)
              DropdownMenuItem<T>(
                value: e.key,
                child: Text(e.value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: MadrassaErp.isUrduText(e.value)
                        ? GText.caption(c.textPrimary).copyWith(fontFamily: 'Noori', fontSize: 13)
                        : null),
              ),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }

  // ── Student editor (panel / dialog / sheet) ───────────────────────────────

  void _openStudent(Map<String, dynamic> s) {
    final sId = (s['id'] ?? '').toString();
    if (MadrassaErp.roomForPanel(context)) {
      setState(() => _selectedStudentId = _selectedStudentId == sId ? null : sId);
      return;
    }
    final config = ref.read(madrassaConfigProvider(_effectiveBranch)).value;
    if (config == null) return;
    final ptmDate = getPtmDateFor(_selectedDate.year, _selectedDate.month, config);
    final isPtmDay = DateUtils.isSameDay(_selectedDate, ptmDate);
    final allowLeave = _localAllowStudentLeave ?? config.allowStudentLeave;
    final isReadOnly = !_canSaveData();
    setState(() => _selectedStudentId = sId);
    final Future<void> done;
    if (MadrassaErp.narrow(context)) {
      done = showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: context.comfort.surface,
        builder: (ctx) => _urduSafe(FractionallySizedBox(
          heightFactor: 0.88,
          child: _studentPanel(s, isPtmDay: isPtmDay, isReadOnly: isReadOnly, allowLeave: allowLeave, onClose: () => Navigator.pop(ctx)),
        )),
      );
    } else {
      done = showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          insetPadding: const EdgeInsets.all(Gsp.sp6),
          child: _urduSafe(SizedBox(
            width: 720,
            height: 640,
            child: _studentPanel(s, isPtmDay: isPtmDay, isReadOnly: isReadOnly, allowLeave: allowLeave, onClose: () => Navigator.pop(ctx)),
          )),
        ),
      );
    }
    done.whenComplete(() {
      if (mounted && _selectedStudentId == sId) setState(() => _selectedStudentId = null);
    });
  }

  Widget _studentPanel(
    Map<String, dynamic> s, {
    required bool isPtmDay,
    required bool isReadOnly,
    required bool allowLeave,
    required VoidCallback onClose,
  }) {
    final c = context.comfort;
    final urdu = context.isUrdu;
    final sId = (s['id'] ?? '').toString();
    final name = (s['name'] ?? '—').toString();
    return Container(
      decoration: BoxDecoration(color: c.surface, borderRadius: MadrassaErp.radius, border: Border.all(color: c.border)),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          color: c.surfaceSunken,
          padding: const EdgeInsetsDirectional.fromSTEB(Gsp.sp4, Gsp.sp3, Gsp.sp2, Gsp.sp3),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                MadrassaUrduAwareText(name, color: c.textPrimary, size: 16),
                Text(
                  '${urdu ? 'رول' : 'Roll'} ${s['rollNumber'] ?? '—'} · ${DateFormat('EEE d MMM yyyy').format(_selectedDate)}',
                  style: GText.caption(c.textMuted),
                ),
              ]),
            ),
            IconButton(tooltip: urdu ? 'بند کریں' : 'Close', onPressed: onClose, icon: const Icon(GIcons.close)),
          ]),
        ),
        Divider(height: 1, color: c.border),
        Expanded(
          child: ValueListenableBuilder<int>(
            valueListenable: _changeNotifier,
            builder: (context, _, _) {
              final view = _viewOf(sId);
              // The editor picks its layout from the screen width; inside a panel
              // it must use its narrow (stacked) layout.
              final mq = MediaQuery.of(context);
              return SingleChildScrollView(
                padding: const EdgeInsets.all(Gsp.sp3),
                child: MediaQuery(
                  data: mq.copyWith(size: Size(420, mq.size.height)),
                  child: _StudentLogCard(
                  key: ValueKey('panel_${sId}_$_dateKey'),
                  student: s,
                  logNotifier: ValueNotifier(view),
                  isPtmDay: isPtmDay,
                  isReadOnly: isReadOnly,
                  branchId: _effectiveBranch,
                  allowStudentLeave: allowLeave,
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
                  ),
                ),
              );
            },
          ),
        ),
        if (!isReadOnly)
          Container(
            decoration: BoxDecoration(border: Border(top: BorderSide(color: c.border))),
            padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3, vertical: Gsp.sp2),
            child: ValueListenableBuilder<int>(
              valueListenable: _changeNotifier,
              builder: (context, _, _) => Row(children: [
                Expanded(
                  child: Text(
                    _localChanges.isEmpty
                        ? (urdu ? 'سب محفوظ ہے' : 'All saved')
                        : (urdu ? '${_localChanges.length} طلباء کی تبدیلیاں باقی' : '${_localChanges.length} student(s) not saved yet'),
                    style: GText.caption(_localChanges.isEmpty ? c.textMuted : c.warning),
                  ),
                ),
                FilledButton.icon(
                  onPressed: _localChanges.isEmpty || _isSaving ? null : _saveChanges,
                  icon: const Icon(GIcons.save, size: 16),
                  label: Text(context.l.saveChanges),
                ),
              ]),
            ),
          ),
      ]),
    );
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

/// A guardian's leave request for one student on one day.
class _LeaveRequest {
  const _LeaveRequest({required this.dateKey, required this.studentId, required this.student, required this.log});
  final String dateKey;
  final String studentId;
  final Map<String, dynamic> student;
  final Map<String, dynamic> log;
  String get id => '$dateKey|$studentId';
}
