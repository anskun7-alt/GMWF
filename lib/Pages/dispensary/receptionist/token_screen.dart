// lib/pages/dispensary/receptionist/token_screen.dart

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:another_flushbar/flushbar.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';

import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/services/network_health_service.dart';
import 'package:gmwf/services/sync_service.dart';
import 'package:gmwf/realtime/realtime_manager.dart';
import 'package:gmwf/realtime/realtime_events.dart';
import 'package:gmwf/widgets/patient_audit_history_dialog.dart';
import 'package:gmwf/utils/formatters.dart';
import 'package:gmwf/services/staff_patient_link_service.dart';
import 'package:gmwf/services/cloud_messaging_service.dart';

class TokenScreen extends StatefulWidget {
  final String branchId;
  final String receptionistId;
  final String receptionistName;
  final String? dispensaryId;
  final Function(String cnic)? onPatientNotFound;
  final String? initialCnic;

  const TokenScreen({
    super.key,
    required this.branchId,
    required this.receptionistId,
    required this.receptionistName,
    this.dispensaryId,
    this.onPatientNotFound,
    this.initialCnic,
  });

  @override
  State<TokenScreen> createState() => TokenScreenState(); // PUBLIC
}

// FIX: PUBLIC (was _TokenScreenState)
class TokenScreenState extends State<TokenScreen> with WidgetsBindingObserver {
  final TextEditingController cnicController = TextEditingController();
  final FocusNode _cnicFocusNode = FocusNode();
  bool _isLoading    = false;
  bool _isRefreshing = false;
  String? _nextSerial;
  Map<String, dynamic>? _patientData;
  List<Map<String, dynamic>> _patientsList = [];
  bool _hasTokenToday    = false;
  // ignore: unused_field
  String? _guardianCnic;
  // ignore: unused_field
  Map<String, dynamic>? _guardianPatient;
  String? _errorMessage;
  Map<String, dynamic>? _medicineRestriction;
  bool _isExceptionPending = false;
  bool _isVitalsDialogOpen = false;

  StreamSubscription<Map<String, dynamic>>? _realtimeSub;
  
  // ─── HANG FIX: Debounce setState ──────────────────────────────────────
  Timer? _debounceListenerTimer;

  bool get _isVitalsTokenAllowed => LocalStorageService.isVitalsTokenAllowed(widget.branchId);

  String? _capturedDispensaryId;

  /// Computes the active dispensary/camp ID from current session state.
  /// Called explicitly at well-defined moments (screen init, patient
  /// selection, in-tab camp switch) and cached into [_capturedDispensaryId]
  /// — NOT called fresh on every rebuild/save, so a camp switch in another
  /// tab of the hybrid screen can't retroactively change the camp an
  /// in-progress token issuance is attributed to.
  String? _computeInitialDispensaryId() {
    if (!CampSessionService.hasCampsForBranch(widget.branchId)) return null;
    final active = CampSessionService.getActiveCamp(widget.branchId);
    if (active != null && active.isNotEmpty) return active;
    if (widget.dispensaryId != null && widget.dispensaryId!.trim().isNotEmpty) {
      return widget.dispensaryId!.trim().toLowerCase();
    }
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final userData = Hive.box('app_settings').get('user_data');
        if (userData is Map && userData['dispensaryId'] != null) {
          final d = userData['dispensaryId'].toString().trim();
          if (d.isNotEmpty && d.toLowerCase() != 'all') return d.toLowerCase();
        }
      }
    } catch (_) {}
    return null;
  }

  static const Color _teal  = Color(0xFF00695C);

  bool get _isKarachi {
    final b = widget.branchId.toLowerCase().trim();
    return b.contains('karachi') || b.contains('haji') || b.contains('saddar') || b.contains('kapaya');
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    LocalStorageService.ensureBoxOpen(LocalStorageService.patientsBox);
    LocalStorageService.ensureBoxOpen(LocalStorageService.entriesBox);
    // FIX 5b: capture the camp once at screen start instead of listening to
    // CampSessionService.activeCampNotifier — that listener was exactly the
    // mechanism that let another tab's camp switch retroactively touch this
    // screen's in-progress token issuance.
    _capturedDispensaryId = _computeInitialDispensaryId();
    _estimateNextSerial();

    if (widget.initialCnic != null && widget.initialCnic!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        focusAndFillCnic(widget.initialCnic!);
      });
    }

    // ── Pure Hive & LAN Realtime Architecture (Zero Firestore Snapshot Listeners) ──
    _realtimeSub = RealtimeManager().messageStream.listen((event) async {
      final type = event['event_type'] as String?;
      final rawData = event['data'];
      final data = (rawData is Map) ? Map<String, dynamic>.from(rawData) : <String, dynamic>{};
      if (!mounted) return;
      final eventBranch = data['branchId']?.toString().toLowerCase().trim();
      final myBranch    = widget.branchId.toLowerCase().trim();
      if (eventBranch != null && eventBranch.isNotEmpty && eventBranch != myBranch) return;
      if (type == RealtimeEvents.saveEntry ||
          type == 'token_created' ||
          type == RealtimeEvents.savePrescription) {
        _instantRefresh();
      } else if (type == 'token_reversal_approved') {
        final tokenSerial = (data['tokenSerial'] ?? data['serial'] ?? data['tokenId'])?.toString();
        if (tokenSerial != null && tokenSerial.isNotEmpty) {
          await LocalStorageService.deleteLocalEntry(widget.branchId, tokenSerial);
        }
        _issuedTokenKeysThisSession.clear();
        if (_patientData != null) {
          final pId = _patientData!['patientId']?.toString();
          if (pId != null && pId.isNotEmpty) {
            _checkIfTokenStillExists(pId);
          }
          setState(() {
            _hasTokenToday = false;
          });
        }
        _instantRefresh();
      } else if (type == RealtimeEvents.tokenExceptionApproved || type == 'restriction_removed') {
        final patientId = (data['patientId'] ?? data['id'])?.toString();
        final reason    = data['reason']?.toString() ?? 'Approved by Doctor';
        final approvedBy = (data['approvedBy'] ?? 'Doctor').toString();
        final requestId = data['requestId']?.toString();

        if (patientId != null && patientId.isNotEmpty) {
          await LocalStorageService.grantTokenException(
            widget.branchId,
            patientId,
            reason: reason,
            approvedBy: approvedBy,
            requestId: requestId,
          );
        }

        // Match against current patient (either patientId or cleaned CNIC)
        final myPId       = _patientData?['patientId']?.toString();
        final myCleanCnic = _getRestrictionId(_patientData ?? {});

        final normPid = patientId?.replaceAll(RegExp(r'[^\w]'), '').toLowerCase() ?? '';
        final normMyPid = myPId?.replaceAll(RegExp(r'[^\w]'), '').toLowerCase() ?? '';
        final normMyClean = myCleanCnic.replaceAll(RegExp(r'[^\w]'), '').toLowerCase();

        if (normPid.isNotEmpty && (normMyPid == normPid || normMyClean == normPid)) {
          _issuedTokenKeysThisSession.clear();
          setState(() {
            _hasTokenToday = false;
            _medicineRestriction = null;
            _isExceptionPending = false;
          });
          _instantRefresh();

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              Flushbar(
                title: '✅ Token Exception Approved',
                message: 'Reason: $reason (Doctor: $approvedBy)',
                backgroundColor: Colors.green.shade700,
                duration: const Duration(seconds: 4),
                flushbarPosition: FlushbarPosition.TOP,
                margin: const EdgeInsets.all(12),
                borderRadius: BorderRadius.circular(12),
                icon: const Icon(Icons.check_circle, color: Colors.white),
              ).show(context);
            }
          });
        }
      }
    });
  }

  DateTime? _lastActiveTime;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _lastActiveTime = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      _instantRefresh();
      final now = DateTime.now();
      if (_lastActiveTime == null || now.difference(_lastActiveTime!).inMinutes >= 10) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _showDispensarySafetyConfirmation();
          }
        });
      }
      _lastActiveTime = now;
    }
  }

  void _showDispensarySafetyConfirmation() {
    if (!CampSessionService.hasCampsForBranch(widget.branchId)) return;
    if (CampSessionService.isSingleContextUser(branchId: widget.branchId)) return;

    final activeCamp = _capturedDispensaryId;
    final label = activeCamp != null && activeCamp.isNotEmpty
        ? CampSessionService.getCampLabel(activeCamp)
        : 'General Branch';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.shield_outlined, color: Colors.teal),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Dispensary Safety Check',
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ],
        ),
        content: Text(
          'You are issuing tokens for $label.\n\nIs this the correct active dispensary desk?',
          style: const TextStyle(fontSize: 15),
        ),
        actions: [
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 6,
            children: [
              OutlinedButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _showCampSelector();
                  });
                },
                child: const Text('Switch Dispensary'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.teal, foregroundColor: Colors.white),
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Confirm'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showCampSelector() {
    final options = CampSessionService.getAvailableCampOptions();
    if (options.length <= 1) return;

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Select Active Dispensary Desk', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              ...options.map((c) => ListTile(
                    title: Text(c['label']!),
                    onTap: () async {
                      Navigator.pop(ctx);
                      await CampSessionService.setActiveCamp(c['id']!);
                      // Deliberate switch from this tab's own selector takes
                      // effect immediately in this tab.
                      _capturedDispensaryId = c['id'];
                      if (mounted) {
                        setState(() {});
                        _estimateNextSerial();
                      }
                    },
                  )),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _debounceListenerTimer?.cancel();  // ← HANG FIX: Clean up debounce timer
    WidgetsBinding.instance.removeObserver(this);
    _realtimeSub?.cancel();
    cnicController.dispose();
    _cnicFocusNode.dispose();
    super.dispose();
  }
  
  // ─── HANG FIX: Debounce listener setState calls ────────────────────────
  void _debounceListenerSetState() {
    _debounceListenerTimer?.cancel();
    _debounceListenerTimer = Timer(const Duration(milliseconds: 50), () {
      if (mounted) {
        setState(() {
          _hasTokenToday = false;
          _medicineRestriction = null;
          _isExceptionPending = false;
        });
      }
    });
  }

  @override
  void didUpdateWidget(TokenScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialCnic != null &&
        widget.initialCnic!.isNotEmpty &&
        widget.initialCnic != oldWidget.initialCnic) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        focusAndFillCnic(widget.initialCnic!);
      });
    }
  }

  // ── Queue-type resolver ────────────────────────────────────────────────────
  /// Canonical resolver — mirrors SyncService.resolveQueueType exactly.
  /// Input can be patient status ('Zakat', 'Non-Zakat', 'GMWF') or any variant.
  /// Strictly enforces Karachi policy: Non-Zakat / PKR 100 tokens are never allowed.
  String _resolveQueueType(String? rawStatus) {
    final s = (rawStatus ?? '').toLowerCase().trim();
    if (s.isEmpty) return 'zakat';
    if (s == 'non-zakat' || s == 'non zakat' || s == 'nonzakat' ||
        s == 'non_zakat' || s.startsWith('non')) {
      if (_isKarachi) {
        debugPrint('[TokenScreen] 🛡️ Blocked Non-Zakat for Karachi branch (${widget.branchId}) — forcing to zakat');
        return 'zakat';
      }
      return 'non-zakat';
    }
    if (s == 'gmwf' || s == 'gm wf' || s == 'gm-wf' || s == 'gm_wf') return 'gmwf';
    if (s == 'zakat') return 'zakat';
    debugPrint('[TokenScreen] ⚠️ Unknown patient status "$rawStatus" — defaulting to zakat');
    return 'zakat';
  }

  // ── Refresh ────────────────────────────────────────────────────────────────
  Future<void> _instantRefresh() async {
    if (_isRefreshing) return;
    if (mounted) setState(() => _isRefreshing = true);
    try {
      await LocalStorageService.downloadTodayTokens(widget.branchId).timeout(
        const Duration(seconds: 3),
        onTimeout: () => {},
      );
      // ── FIRESTORE FIX: always refresh restrictions on every update ────────
      await LocalStorageService.downloadMedicineRestrictions(widget.branchId).timeout(
        const Duration(seconds: 3),
        onTimeout: () => {},
      );
      _estimateNextSerial();
      if (_patientData?['patientId'] != null) {
        final patientId = _patientData!['patientId'] as String;
        final stillHas = await _tokenExistsToday(patientId);
        if (mounted) {
          setState(() => _hasTokenToday = stillHas);
          _checkMedicineRestriction(_patientData!);
        }
      }
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('[TokenScreen] Instant refresh failed: $e');
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  Future<void> _checkIfTokenStillExists(String patientId) async {
    final stillHas = await _tokenExistsToday(patientId);
    if (mounted) setState(() => _hasTokenToday = stillHas);
    if (_patientData != null) _checkMedicineRestriction(_patientData!);
  }

  /// Checks restriction from local Hive (already refreshed from Firestore
  /// by the caller — _selectPatient or _instantRefresh).
  void _checkMedicineRestriction(Map<String, dynamic> patient) {
    if (!mounted) return;
    final rId = _getRestrictionId(patient);
    final pId = patient['patientId']?.toString() ?? patient['id']?.toString() ?? '';

    final shiftInfo = CampSessionService.resolveShiftAndDateKey(null, widget.branchId);
    if (LocalStorageService.hasApprovedTokenException(widget.branchId, rId, dateKey: shiftInfo.dateKey) ||
        LocalStorageService.hasApprovedTokenException(widget.branchId, pId, dateKey: shiftInfo.dateKey)) {
      setState(() {
        _medicineRestriction = null;
      });
      return;
    }

    // Individual-based check: uses patientId (CNIC for adults, CNIC_child_Name for kids)
    final restriction = LocalStorageService.isPatientBlockedByMedicine(widget.branchId, rId);

    setState(() {
      _medicineRestriction = restriction;
    });
  }

  String _getRestrictionId(Map<String, dynamic> p) {
    return LocalStorageService.resolveIndividualPatientId(p);
  }

  bool _isEntryFromToday(Map<dynamic, dynamic> e, {String? targetDateKey}) {
    final now = CampSessionService.getAuthoritativeTime();
    final todayDdMmYy = DateFormat('ddMMyy').format(now);
    final todayYmd = DateFormat('yyyy-MM-dd').format(now);
    final shiftDateKey = targetDateKey ?? CampSessionService.resolveShiftAndDateKey(now, widget.branchId).dateKey;

    final validDates = <String>{
      if (shiftDateKey.isNotEmpty) shiftDateKey.toLowerCase().trim(),
      todayDdMmYy.toLowerCase().trim(),
      todayYmd.toLowerCase().trim(),
    };

    final dk = (e['dateKey'] ?? e['date'] ?? '').toString().toLowerCase().trim();
    if (dk.isNotEmpty && validDates.contains(dk)) return true;

    final serial = (e['serial'] ?? '').toString().toLowerCase().trim();
    if (serial.isNotEmpty) {
      for (final vd in validDates) {
        if (vd.isNotEmpty && serial.startsWith(vd)) return true;
      }
    }

    final createdAt = (e['createdAt'] ?? e['timestamp'] ?? '').toString().trim();
    if (createdAt.isNotEmpty && createdAt.startsWith(todayYmd)) return true;

    return false;
  }

  Map<String, dynamic>? _getPatientTodayToken(Map<String, dynamic> patient, {bool? isVitalsOnly}) {
    String norm(dynamic v) => (v ?? '').toString().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '').trim();

    final pId = (patient['patientId'] ?? patient['id'] ?? '').toString().trim();
    final cleanId = pId.replaceAll(RegExp(r'[^\w]'), '').toLowerCase();
    final resolvedPId = LocalStorageService.resolveIndividualPatientId(patient).trim();
    final cleanResolvedPId = resolvedPId.replaceAll(RegExp(r'[^\w]'), '').toLowerCase();

    final pNameNorm = norm(patient['patientName'] ?? patient['name'] ?? patient['fullName']);
    final pCnicNorm = norm(patient['cnic'] ?? patient['patientCnic']);
    final pGuardNorm = norm(patient['guardianCnic']);
    final pPhoneNorm = norm(patient['phone'] ?? patient['contactPhone']);

    final pAge = (patient['age'] is num) ? (patient['age'] as num).toInt() : (int.tryParse(patient['age']?.toString() ?? '') ?? 0);
    final isChild = patient['isAdult'] == false || pGuardNorm.isNotEmpty || pId.contains('_child_') || resolvedPId.contains('_child_') || (pAge > 0 && pAge < 20);

    final shiftInfo = CampSessionService.resolveShiftAndDateKey(null, widget.branchId);
    final targetDate = shiftInfo.dateKey;

    final rId = _getRestrictionId(patient);
    final cleanRId = rId.replaceAll(RegExp(r'[^\w]'), '').toLowerCase();

    // EXCEPTION PASS: If Doctor approved a token exception today, consider patient available
    if (LocalStorageService.hasApprovedTokenException(widget.branchId, pId, dateKey: targetDate) ||
        (cleanId.isNotEmpty && LocalStorageService.hasApprovedTokenException(widget.branchId, cleanId, dateKey: targetDate)) ||
        (cleanResolvedPId.isNotEmpty && LocalStorageService.hasApprovedTokenException(widget.branchId, cleanResolvedPId, dateKey: targetDate)) ||
        (resolvedPId.isNotEmpty && LocalStorageService.hasApprovedTokenException(widget.branchId, resolvedPId, dateKey: targetDate)) ||
        (cleanRId.isNotEmpty && LocalStorageService.hasApprovedTokenException(widget.branchId, cleanRId, dateKey: targetDate)) ||
        (rId.isNotEmpty && LocalStorageService.hasApprovedTokenException(widget.branchId, rId, dateKey: targetDate))) {
      return null;
    }

    final entries = LocalStorageService.getLocalEntries(widget.branchId);
    for (final e in entries) {
      if (!_isEntryFromToday(e, targetDateKey: targetDate)) continue;

      final status = (e['status'] ?? '').toString().toLowerCase().trim();
      if (status == 'deleted' || status == 'cancelled' || status == 'skipped' || status == 'expired' || status == 'void') {
        continue;
      }

      final eIsVitals = e['isVitalsOnly'] == true ||
          e['vitalsOnly'] == true ||
          (e['visitReason']?.toString().toLowerCase().contains('vitals') == true);
      if (isVitalsOnly != null && eIsVitals != isVitalsOnly) {
        continue;
      }

      final eId = (e['patientId'] ?? e['id'] ?? '').toString().trim();
      final cleanEId = eId.replaceAll(RegExp(r'[^\w]'), '').toLowerCase();
      final resolvedEId = LocalStorageService.resolveIndividualPatientId(e).trim();
      final cleanResolvedEId = resolvedEId.replaceAll(RegExp(r'[^\w]'), '').toLowerCase();

      final eNameNorm = norm(e['patientName'] ?? e['name'] ?? e['fullName']);
      final eCnicNorm = norm(e['patientCnic'] ?? e['cnic']);
      final eGuardNorm = norm(e['guardianCnic']);
      final ePhoneNorm = norm(e['phone'] ?? e['contactPhone']);

      final eAge = (e['age'] is num) ? (e['age'] as num).toInt() : (int.tryParse(e['age']?.toString() ?? '') ?? 0);
      final eIsChild = (e['isAdult'] == false) || eGuardNorm.isNotEmpty || eId.contains('_child_') || resolvedEId.contains('_child_') || (eAge > 0 && eAge < 20);

      // Rule 0: Adult and Child are strictly distinct entities. Never cross-match!
      if (isChild != eIsChild) {
        continue;
      }

      // Rule 1: Canonical resolved individual patientId match (e.g. '0000000000000_child_02' == '0000000000000_child_02')
      if (cleanResolvedPId.isNotEmpty && (cleanResolvedPId == cleanResolvedEId || cleanResolvedPId == cleanEId)) {
        return e;
      }
      if (cleanId.isNotEmpty && cleanId.contains('_child_') && (cleanId == cleanEId || cleanId == cleanResolvedEId)) {
        return e;
      }

      // Rule 2: Adult match by adult CNIC + exact name match
      if (!isChild && !eIsChild) {
        if (pCnicNorm.isNotEmpty && eCnicNorm.isNotEmpty && pCnicNorm == eCnicNorm) {
          if (pNameNorm.isNotEmpty && eNameNorm.isNotEmpty) {
            if (pNameNorm == eNameNorm) return e;
          } else {
            return e;
          }
        }
      }

      // Rule 3: Child match under same guardian CNIC (requires EXACT name match)
      if (isChild && eIsChild) {
        final pGuard = pGuardNorm.isNotEmpty ? pGuardNorm : pCnicNorm;
        final eGuard = eGuardNorm.isNotEmpty ? eGuardNorm : eCnicNorm;
        if (pGuard.isNotEmpty && eGuard.isNotEmpty && pGuard == eGuard) {
          if (pNameNorm.isNotEmpty && eNameNorm.isNotEmpty && pNameNorm == eNameNorm) {
            return e;
          }
        }
      }

      // Rule 4: Phone matching + EXACT name match
      if (pPhoneNorm.length >= 7 && pPhoneNorm == ePhoneNorm) {
        if (pNameNorm.isNotEmpty && eNameNorm.isNotEmpty && pNameNorm == eNameNorm) {
          return e;
        }
      }
    }
    return null;
  }

  bool _hasVitalsTokenToday(Map<String, dynamic>? patient) {
    if (patient == null) return false;
    return _getPatientTodayToken(patient, isVitalsOnly: true) != null;
  }

  bool _hasRegularTokenToday(Map<String, dynamic>? patient) {
    if (patient == null) return false;
    return _getPatientTodayToken(patient, isVitalsOnly: false) != null;
  }

  bool _hasBothTokensToday(Map<String, dynamic>? patient) {
    if (patient == null) return false;
    return _hasVitalsTokenToday(patient) && _hasRegularTokenToday(patient);
  }

  Future<bool> _tokenExistsToday(String patientId, {Map<String, dynamic>? patient, bool? isVitalsOnly}) async {
    final targetPatient = patient ?? _patientData;
    if (targetPatient != null) {
      return _getPatientTodayToken(targetPatient, isVitalsOnly: isVitalsOnly) != null;
    }
    final shiftInfo  = CampSessionService.resolveShiftAndDateKey(null, widget.branchId);
    final targetDate = shiftInfo.dateKey;
    final cleanId    = patientId.replaceAll(RegExp(r'[^\w]'), '').toLowerCase();

    if (LocalStorageService.hasApprovedTokenException(widget.branchId, patientId, dateKey: targetDate) ||
        LocalStorageService.hasApprovedTokenException(widget.branchId, cleanId, dateKey: targetDate)) {
      return false;
    }

    // Check local patient registry first for individual disambiguation
    final pMap = LocalStorageService.getLocalPatient(patientId);
    if (pMap != null) {
      return _getPatientTodayToken(pMap, isVitalsOnly: isVitalsOnly) != null;
    }

    final entries = LocalStorageService.getLocalEntries(widget.branchId);
    return entries.any((e) {
      if (!_isEntryFromToday(e, targetDateKey: targetDate)) return false;

      final status = (e['status'] ?? '').toString().toLowerCase();
      if (status == 'deleted' || status == 'cancelled' || status == 'skipped' || status == 'expired' || status == 'void') {
        return false;
      }

      final eIsVitals = e['isVitalsOnly'] == true ||
          e['vitalsOnly'] == true ||
          (e['visitReason']?.toString().toLowerCase().contains('vitals') == true);
      if (isVitalsOnly != null && eIsVitals != isVitalsOnly) {
        return false;
      }

      final resolvedEPid = LocalStorageService.resolveIndividualPatientId(e).replaceAll(RegExp(r'[^\w]'), '').toLowerCase();
      final ePid   = (e['patientId'] ?? '').toString().replaceAll(RegExp(r'[^\w]'), '').toLowerCase();
      return cleanId.isNotEmpty && (resolvedEPid == cleanId || ePid == cleanId);
    });
  }

  Future<void> _estimateNextSerial() async {
    final now = CampSessionService.getAuthoritativeTime();
    final shiftInfo = CampSessionService.resolveShiftAndDateKey(now, widget.branchId);
    final datePart = shiftInfo.dateKey;
    final activeCamp = _capturedDispensaryId;
    final nextSeq = await LocalStorageService.getNextLocalSerialSequence(
      widget.branchId,
      datePart,
      dispensaryId: activeCamp,
      increment: false,
    );
    final dispTag = CampSessionService.getDispensaryKeyword(activeCamp, branchId: widget.branchId);
    final serialStr = '$datePart-$dispTag-${nextSeq.toString().padLeft(3, '0')}';
    if (mounted) {
      setState(() {
        _nextSerial = serialStr;
      });
    }
  }

  void focusAndFillCnic(String input) {
    final d = input.replaceAll(RegExp(r'[^0-9]'), '');
    String formatted;
    if (d.startsWith('03')) {
      formatted = d.length > 11 ? d.substring(0, 11) : d;
    } else {
      final cnicDigits = d.length > 13 ? d.substring(0, 13) : d;
      formatted = _formatCnic(cnicDigits);
    }
    cnicController.text = formatted;
    cnicController.selection =
        TextSelection.fromPosition(TextPosition(offset: formatted.length));
    _cnicFocusNode.requestFocus();
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) triggerSearch();
    });
  }

  void triggerSearch() => _searchPatient();

  String _formatCnic(String input) {
    final d = input.replaceAll(RegExp(r'[^0-9]'), '');
    final clean = d.length > 13 ? d.substring(0, 13) : d;
    final b = StringBuffer();
    for (int i = 0; i < clean.length; i++) {
      b.write(clean[i]);
      if ((i == 4 || i == 11) && i != clean.length - 1) b.write('-');
    }
    return b.toString();
  }

  // ── Search ─────────────────────────────────────────────────────────────────
  Future<void> _searchPatient() async {
    final input = cnicController.text.trim();
    if (input.isEmpty) return;
    final looksLikeCnic  = RegExp(r'^\d{5}-\d{7}-\d{1}$').hasMatch(input);
    final looksLikePhone = RegExp(r'^03\d{9}$')
        .hasMatch(input.replaceAll(RegExp(r'[^0-9]'), ''));
    if (!looksLikeCnic && !looksLikePhone) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Enter valid CNIC (XXXXX-XXXXXXX-X) or phone (03xxxxxxxxx)'),
        backgroundColor: Colors.orange,
      ));
      return;
    }
    setState(() {
      _isLoading = true; _errorMessage = null; _patientData = null;
      _patientsList.clear(); _hasTokenToday = false;
      _guardianCnic = null; _guardianPatient = null;
    });
    try {
      await LocalStorageService.ensureBoxOpen(LocalStorageService.patientsBox);
      await LocalStorageService.ensureBoxOpen(LocalStorageService.entriesBox);
      var localResults = LocalStorageService.searchPatientsByCnicOrGuardian(
          input, branchId: widget.branchId);
      if (localResults.isEmpty) {
        try {
          await LocalStorageService.downloadAllPatients(widget.branchId).timeout(
            const Duration(seconds: 3),
            onTimeout: () => {},
          );
          localResults = LocalStorageService.searchPatientsByCnicOrGuardian(
              input, branchId: widget.branchId);
        } catch (e) {
          debugPrint('[TokenScreen] Firestore fallback patient fetch failed: $e');
        }

        if (localResults.isEmpty) {
          try {
            final branchRef = FirebaseFirestore.instance
                .collection('branches')
                .doc(widget.branchId)
                .collection('patients');

            final normalized = input.replaceAll(RegExp(r'[^0-9]'), '');
            final cnicQuery = branchRef.where('cnic', isEqualTo: input).limit(10).get().timeout(const Duration(seconds: 3));
            final guardianQuery = branchRef.where('guardianCnic', isEqualTo: input).limit(20).get().timeout(const Duration(seconds: 3));
            final phoneQuery = normalized.length >= 6
                ? branchRef.where('phone', isEqualTo: normalized).limit(1).get().timeout(const Duration(seconds: 3))
                : Future.value(null);

            final results = await Future.wait([cnicQuery, guardianQuery, phoneQuery], eagerError: false);
            final found = <Map<String, dynamic>>[];
            for (final snapshot in results) {
              if (snapshot == null || snapshot is! QuerySnapshot) continue;
              for (final doc in snapshot.docs) {
                final data = Map<String, dynamic>.from(doc.data());
                data['patientId'] = doc.id;
                data['branchId'] = widget.branchId;
                found.add(data);
              }
            }

            if (found.isNotEmpty) {
              await LocalStorageService.saveAllLocalPatients(found);
              localResults = LocalStorageService.searchPatientsByCnicOrGuardian(
                  input, branchId: widget.branchId);
            }
          } catch (e) {
            debugPrint('[TokenScreen] Direct branch patient query failed: $e');
          }
        }
      }
      if (mounted) {
        setState(() => _patientsList = localResults);
      }
      if (localResults.isNotEmpty) {
        if (localResults.length == 1) {
          await _selectPatient(localResults.first);
        } else {
          if (mounted) setState(() => _patientData = null);
        }
      } else {
        if (looksLikeCnic && widget.onPatientNotFound != null) {
          widget.onPatientNotFound!(input);
        } else {
          if (mounted) {
            setState(() =>
                _errorMessage = 'No patient found with this CNIC/phone.');
          }
        }
      }
    } catch (e) {
      if (mounted) setState(() => _errorMessage = 'Search failed: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Selects a patient and checks medicine restriction.
  /// Downloads restrictions from Firestore first so internet-only terminals
  /// always have the latest data before the block check.
  Future<void> _selectPatient(Map<String, dynamic> patient) async {
    // FIX 5b: capture the camp once here, when this patient's workflow
    // starts. A camp switch from another tab in the hybrid screen after
    // this point won't retroactively change which camp this in-progress
    // token gets attributed to. (A switch from THIS tab's own selector
    // still updates it immediately — see _showCampSelector.)
    _capturedDispensaryId = _computeInitialDispensaryId();

    // ── Run restriction refresh in background without blocking UI ────────────
    LocalStorageService.downloadMedicineRestrictions(widget.branchId).catchError((e) {
      debugPrint('[TokenScreen] downloadMedicineRestrictions failed: $e');
    });

    final hasBoth = _hasBothTokensToday(patient);
    final cannotIssueMore = _isVitalsTokenAllowed ? hasBoth : _hasRegularTokenToday(patient);
    if (mounted) {
      setState(() {
        _patientData   = patient;
        _hasTokenToday = cannotIssueMore;
        _errorMessage  = null;
        _isExceptionPending = false;
      });
      _checkMedicineRestriction(patient);
      if (!cannotIssueMore) {
        _showVitalsDialog();
      }
    }
  }

  final Set<String> _issuedTokenKeysThisSession = {};

  // ── Generate token ─────────────────────────────────────────────────────────
  Future<void> _generateToken({
    required String bp,
    required String temp,
    required String sugar,
    required String weight,
    int suggestedDays = 1,
    bool isVitalsOnly = false,
  }) async {
    if (_isLoading) {
      debugPrint('[TokenScreen] Guard triggered: _isLoading is true, returning immediately.');
      return;
    }
    if (_patientData == null || _nextSerial == null) return;

    final patientId = _patientData!['patientId'] as String?;
    if (patientId == null || patientId.isEmpty) {
      throw Exception('Missing patientId');
    }

    final resolvedPid = LocalStorageService.resolveIndividualPatientId(_patientData);
    final effectivePid = resolvedPid.isNotEmpty ? resolvedPid : patientId;
    final cleanPid = effectivePid.replaceAll(RegExp(r'[^\w]'), '').toLowerCase();

    final now = CampSessionService.getAuthoritativeTime();
    final shiftInfo = CampSessionService.resolveShiftAndDateKey(now, widget.branchId);
    final dateKey = shiftInfo.dateKey;
    final tokenTypeTag = isVitalsOnly ? 'vitals' : 'regular';
    final idempotencyKey = '${widget.branchId}_${cleanPid}_${tokenTypeTag}_$dateKey';

    final hasException = LocalStorageService.hasApprovedTokenException(widget.branchId, patientId, dateKey: dateKey) ||
        LocalStorageService.hasApprovedTokenException(widget.branchId, cleanPid, dateKey: dateKey) ||
        LocalStorageService.hasApprovedTokenException(widget.branchId, effectivePid, dateKey: dateKey);

    if (hasException) {
      debugPrint('[TokenScreen] 🟢 Authorized token exception active for $patientId ($dateKey)');
      _issuedTokenKeysThisSession.remove(idempotencyKey);
    } else {
      bool isAlreadyIssued = _issuedTokenKeysThisSession.contains(idempotencyKey);
      if (!isAlreadyIssued) {
        final exists = await _tokenExistsToday(effectivePid, patient: _patientData, isVitalsOnly: isVitalsOnly);
        if (exists) {
          isAlreadyIssued = true;
        }
      }

      if (isAlreadyIssued) {
        debugPrint('[TokenScreen] 🛑 Duplicate token issuance blocked for: $effectivePid');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('⚠️ A ${isVitalsOnly ? "Vitals Inspection" : "Regular"} token has already been issued for this patient today!'),
          backgroundColor: Colors.orange,
          duration: const Duration(seconds: 4),
        ));
        return;
      }
    }

    _issuedTokenKeysThisSession.add(idempotencyKey);

    if (mounted) setState(() => _isLoading = true);
    try {
      final rawName = (_patientData!['patientName'] ?? _patientData!['name'] ?? _patientData!['fullName'])?.toString().trim();
      final patientName = (rawName != null && rawName.isNotEmpty && rawName.toLowerCase() != 'null')
          ? rawName
          : 'Unknown Patient';

      if (!hasException && await _tokenExistsToday(patientId, isVitalsOnly: isVitalsOnly)) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('❌ This patient already has a ${isVitalsOnly ? "Vitals Inspection" : "Regular"} token today!'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 4),
        ));
        setState(() => _isLoading = false);
        return;
      }

      _issuedTokenKeysThisSession.add(idempotencyKey);

      // Background restriction refresh (non-blocking)
      LocalStorageService.downloadMedicineRestrictions(widget.branchId).catchError((e) {
        debugPrint('[TokenScreen] Background restriction refresh failed: $e');
      });

      // Medicine restriction only blocks Regular tokens (prescribing medicines), not vitals-only checkups
      if (!isVitalsOnly && !hasException) {
        _checkMedicineRestriction(_patientData!);
        final restriction = _medicineRestriction;
        if (restriction != null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('❌ Patient blocked. Medicine expires in ${restriction['remainingDays']} days.'),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 4),
            ));
          }
          setState(() => _isLoading = false);
          return;
        }
      }

      final now = CampSessionService.getAuthoritativeTime();
      final shiftInfo = CampSessionService.resolveShiftAndDateKey(now, widget.branchId);
      final dateKey = shiftInfo.dateKey;
      final session = shiftInfo.session;
      final activeCamp = _capturedDispensaryId;
      final dispTag = CampSessionService.getDispensaryKeyword(activeCamp, branchId: widget.branchId);

      final rawStatus = _patientData!['status']?.toString();
      var queueType = _resolveQueueType(rawStatus);
      if (_isKarachi && queueType == 'non-zakat') {
        queueType = 'zakat';
      }

      final hasVitals = bp.isNotEmpty || temp.isNotEmpty || weight.isNotEmpty || sugar.isNotEmpty;
      final Map<String, dynamic>? vitals = hasVitals
          ? <String, dynamic>{
              'bp': bp.isNotEmpty ? bp : 'N/A',
              'temp': temp.isNotEmpty ? temp : 'N/A',
              'tempUnit': 'C',
              'weight': weight.isNotEmpty ? weight : 'N/A',
              'sugar': sugar.isNotEmpty ? sugar : 'N/A',
              'age':        _patientData!['age']        ?? 0,
              'gender':     _patientData!['gender']     ?? 'Unknown',
              'bloodGroup': _patientData!['bloodGroup'] ?? 'N/A',
              'receptionistVitals': {
                'bp': bp.isNotEmpty ? bp : 'N/A',
                'temp': temp.isNotEmpty ? temp : 'N/A',
                'weight': weight.isNotEmpty ? weight : 'N/A',
                'sugar': sugar.isNotEmpty ? sugar : 'N/A',
                'addedBy': widget.receptionistName,
                'addedById': widget.receptionistId,
                'addedAt': now.toIso8601String(),
              },
              'auditTrail': [
                {
                  'role': 'receptionist',
                  'action': 'Added initial vitals',
                  'by': widget.receptionistName,
                  'byId': widget.receptionistId,
                  'at': now.toIso8601String(),
                  'bp': bp.isNotEmpty ? bp : 'N/A',
                  'temp': temp.isNotEmpty ? temp : 'N/A',
                  'weight': weight.isNotEmpty ? weight : 'N/A',
                  if (sugar.isNotEmpty) 'sugar': sugar,
                }
              ],
            }
          : null;

      String? resolvedGuardianName = _patientData!['guardianName']?.toString().trim();
      if ((resolvedGuardianName == null || resolvedGuardianName.isEmpty) &&
          _patientData!['guardianCnic'] != null &&
          _patientData!['guardianCnic'].toString().trim().isNotEmpty) {
        try {
          final gList = LocalStorageService.searchPatientsByCnicOrGuardian(
              _patientData!['guardianCnic'].toString().trim(),
              branchId: widget.branchId);
          for (final gp in gList) {
            final isAdult = gp['isAdult'] == true ||
                (gp['guardianCnic'] == null || (gp['guardianCnic'] as String).trim().isEmpty);
            if (isAdult) {
              final gn = (gp['patientName'] ?? gp['name'] ?? gp['fullName'])?.toString().trim();
              if (gn != null && gn.isNotEmpty) {
                resolvedGuardianName = gn;
                break;
              }
            }
          }
        } catch (_) {}
      }

      final resolvedPidForEntry = LocalStorageService.resolveIndividualPatientId(_patientData);
      final effectivePidForEntry = resolvedPidForEntry.isNotEmpty ? resolvedPidForEntry : patientId;
      final isChildPatient = _patientData!['isAdult'] == false ||
          (_patientData!['guardianCnic']?.toString().trim().isNotEmpty == true) ||
          effectivePidForEntry.contains('_child_');

      final baseData = <String, dynamic>{
        'queueType':     queueType,
        'dateKey':       dateKey,
        'session':       session,
        'patientId':     effectivePidForEntry,
        'patientName':   patientName,
        'name':          patientName,
        'isAdult':       !isChildPatient,
        'age':           _patientData!['age'] ?? 0,
        'gender':        _patientData!['gender'] ?? 'Unknown',
        'isVitalsOnly':  isVitalsOnly,
        'vitalsOnly':    isVitalsOnly,
        'visitReason':   isVitalsOnly ? 'Vitals Inspection Only' : 'Regular Visit',
        'patientCnic': (_patientData!['cnic']?.toString().trim().isNotEmpty == true
            ? _patientData!['cnic'].toString().trim()
            : _patientData!['guardianCnic']?.toString().trim() ?? ''),
        'createdAt':     now.toIso8601String(),
        'status':        'waiting',
        if (vitals != null) 'vitals': vitals,
        'branchId':      widget.branchId,
        'dispensaryTag': dispTag,
        if (_capturedDispensaryId != null && _capturedDispensaryId!.isNotEmpty)
          'dispensaryId': _capturedDispensaryId,
        'createdBy':     widget.receptionistId,
        'createdByName': widget.receptionistName,
        'performedBy':   widget.receptionistName,
        'suggestedDays': suggestedDays,
        if (_patientData!['cnic']?.toString().trim().isNotEmpty == true)
          'cnic': _patientData!['cnic'].toString().trim(),
        if (_patientData!['guardianCnic']?.toString().trim().isNotEmpty == true)
          'guardianCnic': _patientData!['guardianCnic'].toString().trim(),
        if (resolvedGuardianName != null && resolvedGuardianName.isNotEmpty)
          'guardianName': resolvedGuardianName,
      };

      // ── Instant Local Monotonic Serial Generation (0 ms offline latency) ──
      final normDispTag = dispTag.trim().toUpperCase();
      final effectiveCampId = (_capturedDispensaryId != null && _capturedDispensaryId!.isNotEmpty)
          ? _capturedDispensaryId!
          : (activeCamp ?? (normDispTag == 'HAJI' ? 'haji_camp' : 'saddar'));
      final effectiveCampName = CampSessionService.getCampLabel(effectiveCampId);

      final nextSeq = await LocalStorageService.getNextLocalSerialSequence(
        widget.branchId,
        dateKey,
        dispensaryId: effectiveCampId,
        increment: true,
      );
      final seqPadded = nextSeq.toString().padLeft(3, '0');
      final serial = '$dateKey-$normDispTag-$seqPadded';
      final entryData = <String, dynamic>{
        ...baseData,
        'serial': serial,
        'dispensaryTag': normDispTag,
        'dispensaryId': effectiveCampId,
        'campId': effectiveCampId,
        'campName': effectiveCampName,
        'dispensaryName': effectiveCampName,
        'pendingSync': true,
        if (hasException) ...{
          'isExceptionToken': true,
          'exceptionAuthorized': true,
        },
      };

      // STEP 1 — Hive (instant, offline-safe & case-normalized)
      await LocalStorageService.deleteLocalPrescription(serial);
      await LocalStorageService.saveEntryLocal(widget.branchId, serial, entryData);

      if (hasException) {
        await LocalStorageService.consumeTokenException(widget.branchId, patientId, dateKey: dateKey);
        await LocalStorageService.consumeTokenException(widget.branchId, cleanPid, dateKey: dateKey);
      }

      if (weight.isNotEmpty && weight != 'N/A') {
        _patientData!['lastWeight'] = weight;
        _patientData!['weight'] = weight;
        try {
          if (Hive.isBoxOpen(LocalStorageService.patientsBox)) {
            final pBox = Hive.box(LocalStorageService.patientsBox);
            final cachedP = pBox.get(patientId);
            if (cachedP is Map) {
              final updated = Map<String, dynamic>.from(cachedP)
                ..['lastWeight'] = weight
                ..['weight'] = weight;
              await pBox.put(patientId, updated);
            }
          }
        } catch (_) {}
      }

      // STEP 2 — LAN broadcast
      try {
        RealtimeManager().sendMessage({
          ...RealtimeEvents.payload(
            type: RealtimeEvents.saveEntry,
            branchId: widget.branchId,
            data: entryData,
          ),
          'queueType': queueType,
          'dateKey':   dateKey,
          'serial':    serial,
        });
      } catch (e) {
        debugPrint('[TokenScreen] LAN broadcast failed: $e');
      }

      _estimateNextSerial();

      if (mounted) {
        final isSinglePatientSearch = _patientsList.length <= 1;
        if (isSinglePatientSearch) {
          cnicController.clear();
          setState(() {
            _patientData = null;
            _patientsList.clear();
            _hasTokenToday = false;
            _guardianCnic = null;
            _guardianPatient = null;
            _errorMessage = null;
            _isLoading = false;
          });
        } else {
          final currentQuery = cnicController.text.trim();
          final refreshedFamily = currentQuery.isNotEmpty
              ? LocalStorageService.searchPatientsByCnicOrGuardian(currentQuery, branchId: widget.branchId)
              : <Map<String, dynamic>>[];
          setState(() {
            _patientData = null;
            _hasTokenToday = true;
            _guardianCnic = null;
            _guardianPatient = null;
            _errorMessage = null;
            _isLoading = false;
            if (refreshedFamily.isNotEmpty) {
              _patientsList = refreshedFamily;
            }
          });
        }

        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '✅ Token $serial issued to $patientName! [$queueType]'),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 3),
        ));
      }

      // STEP 3 — Firestore in background
      _syncToFirestoreInBackground(dateKey, queueType, serial, entryData);
    } catch (e, stack) {
      debugPrint('[TokenScreen] Token generation failed: $e\n$stack');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failed to issue token: $e'),
          backgroundColor: Colors.red));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ── Firestore sync — only writes directly when LAN server is unavailable ───
  Future<void> _syncToFirestoreInBackground(
    String dateKey,
    String queueType,
    String serial,
    Map<String, dynamic> entryData,
  ) async {
    // [DEDUP] If connected to LAN server, the token already traveled via
    // WebSocket → Server SSM → Firestore.  Skip direct write to avoid
    // double/triple quota consumption.
    final lanConnected = RealtimeManager().isConnected;
    if (lanConnected) {
      debugPrint('[TokenScreen] LAN connected — server will sync $serial to Firestore');
      return;
    }

    bool written = false;
    try {
      final online = NetworkHealthService().isStableOnline;
      if (online) {
        final campDocKey = CampSessionService.getCampDateDocId(
          branchId: widget.branchId,
          dateKey: dateKey,
          campId: entryData['campId']?.toString() ?? entryData['dispensaryId']?.toString(),
          dispensaryTag: entryData['dispensaryTag']?.toString(),
          serial: serial,
        );
        final dayRef = FirebaseFirestore.instance
            .collection('branches')
            .doc(widget.branchId)
            .collection('serials')
            .doc(campDocKey);
        await dayRef
            .collection(queueType)
            .doc(serial)
            .set(entryData, SetOptions(merge: true))
            .timeout(const Duration(seconds: 4));
        await dayRef.set(
          {'lastSerialNumber': int.tryParse(serial.split('-').last) ?? 0},
          SetOptions(merge: true),
        );
        debugPrint(
            '[TokenScreen] ✅ Firestore serials/$campDocKey/$queueType/$serial');
        written = true;
      }
    } catch (e) {
      debugPrint('[TokenScreen] Firestore write failed: $e');
    }

    if (!written) {
      try {
        await LocalStorageService.enqueueSync({
          'type':      'save_entry',
          'branchId':  widget.branchId,
          'dateKey':   dateKey,
          'queueType': queueType,
          'serial':    serial,
          'data':      entryData,
        });
        debugPrint('[TokenScreen] 📥 Queued for sync: $queueType/$serial');
        SyncService().triggerUpload();
      } catch (e) {
        debugPrint('[TokenScreen] Enqueue failed: $e');
      }
    }
  }

  // ── Direct edit patient on token screen ────────────────────────────────────
  Future<void> _requestEditPatient() async {
    if (_patientData == null) return;

    try {
      bool isChild = _patientData!['isAdult'] != true;
      final cnicCtrl = TextEditingController(
          text: isChild
              ? (_patientData!['guardianCnic']?.toString() ?? '')
              : (_patientData!['cnic']?.toString() ?? ''));
      final nameCtrl = TextEditingController(
          text: (_patientData!['patientName'] ?? _patientData!['name'] ?? '').toString());
      final phoneCtrl = TextEditingController(
          text: _patientData!['phone']?.toString() ?? '');
      final dobCtrl = TextEditingController();
      final bloodGroupCtrl = TextEditingController(
          text: _patientData!['bloodGroup']?.toString() ?? 'N/A');
      String selectedStatus = _patientData!['status']?.toString() ?? 'Zakat';
      if (_isKarachi && selectedStatus.toLowerCase().contains('non')) {
        selectedStatus = 'Zakat';
      }
      String selectedGender = _patientData!['gender']?.toString() ?? 'Male';

      final dobValue = _patientData!['dob'];
      if (dobValue != null) {
        DateTime? birthDate;
        if (dobValue is Timestamp) {
          birthDate = dobValue.toDate();
        } else if (dobValue is String) {
          try {
            birthDate = DateFormat('dd-MM-yyyy').parse(dobValue);
          } catch (_) {
            try {
              birthDate = DateTime.parse(dobValue);
            } catch (_) {}
          }
        }
        if (birthDate != null) {
          dobCtrl.text = DateFormat('dd-MM-yyyy').format(birthDate);
        }
      }

      final isDark = _isDark;
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => StatefulBuilder(
          builder: (ctx, setStateDialog) => Dialog(
            backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24)),
            insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: Container(
              width: 520,
              constraints: const BoxConstraints(maxHeight: 700),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E293B) : Colors.white,
                borderRadius: BorderRadius.circular(24),
                border: isDark ? Border.all(color: const Color(0xFF334155)) : null,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Header
                  Container(
                    padding: const EdgeInsets.fromLTRB(20, 18, 16, 18),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: isDark
                            ? [const Color(0xFF0F766E), const Color(0xFF0D9488)]
                            : [Colors.green.shade800, Colors.teal.shade700],
                      ),
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.edit_note_rounded, color: Colors.white, size: 26),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text('Edit Patient Details',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800)),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(ctx),
                          icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 22),
                          padding: EdgeInsets.zero,
                        ),
                      ],
                    ),
                  ),

                  // Form Body
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _editField(nameCtrl, 'Full Name', Icons.person),
                          const SizedBox(height: 14),
                          _editField(
                            cnicCtrl,
                            isChild ? 'Guardian CNIC (XXXXX-XXXXXXX-X)' : 'CNIC (XXXXX-XXXXXXX-X)',
                            Icons.badge,
                            readOnly: false,
                            formatters: [CNICInputFormatter()],
                            maxLen: 15,
                          ),
                          const SizedBox(height: 14),
                          _editField(phoneCtrl, 'Phone Number', Icons.phone),
                          const SizedBox(height: 14),
                          _editField(dobCtrl, 'Date of Birth (dd-MM-yyyy)', Icons.cake),
                          const SizedBox(height: 14),
                          _editField(bloodGroupCtrl, 'Blood Group', Icons.bloodtype),
                          const SizedBox(height: 18),

                          _radioGroup(
                            'Status',
                            _isKarachi
                                ? ['Zakat', 'GMWF']
                                : ['Zakat', 'Non-Zakat', 'GMWF'],
                            selectedStatus,
                            (v) => setStateDialog(() => selectedStatus = v),
                          ),
                          const SizedBox(height: 14),
                          _radioGroup('Gender', ['Male', 'Female', 'Other'],
                              selectedGender,
                              (v) => setStateDialog(() => selectedGender = v)),
                        ],
                      ),
                    ),
                  ),

                  // Actions
                  Divider(height: 1, thickness: 1, color: isDark ? const Color(0xFF334155) : Colors.grey.shade200),
                  Container(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF0F172A) : Colors.grey.shade50,
                      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(24)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: Text('Cancel',
                                style: TextStyle(
                                    color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade700,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () async {
                              final pId = _patientData!['patientId']?.toString() ??
                                  _patientData!['id']?.toString() ?? '';
                              if (pId.isEmpty) return;

                              final updated = Map<String, dynamic>.from(_patientData!);
                              final newCnic = cnicCtrl.text.trim();
                              if (isChild) {
                                updated['guardianCnic'] = newCnic;
                              } else {
                                updated['cnic'] = newCnic;
                                updated['patientCnic'] = newCnic;
                              }
                              updated['name'] = nameCtrl.text.trim();
                              updated['patientName'] = nameCtrl.text.trim();
                              updated['phone'] = phoneCtrl.text.trim().isNotEmpty
                                  ? phoneCtrl.text.trim()
                                  : null;
                              final updatedStatus = (_isKarachi && selectedStatus.toLowerCase().contains('non'))
                                  ? 'Zakat'
                                  : selectedStatus;
                              updated['status'] = updatedStatus;
                              updated['gender'] = selectedGender;
                              updated['bloodGroup'] = bloodGroupCtrl.text.trim().isNotEmpty
                                  ? bloodGroupCtrl.text.trim()
                                  : 'N/A';
                              updated['branchId'] = widget.branchId;

                              if (dobCtrl.text.isNotEmpty &&
                                  RegExp(r'^\d{2}-\d{2}-\d{4}$').hasMatch(dobCtrl.text)) {
                                final parts = dobCtrl.text.split('-');
                                try {
                                  final dt = DateTime(int.parse(parts[2]),
                                      int.parse(parts[1]), int.parse(parts[0]));
                                  updated['dob'] = Timestamp.fromDate(dt);
                                } catch (_) {}
                              }

                              updated['performedBy'] = widget.receptionistName;
                              updated['performedByRole'] = 'receptionist';

                              // 1. Save and atomically migrate CNIC in local storage and active queue entries
                              await LocalStorageService.updatePatientWithCnicMigration(
                                oldPatientId: pId,
                                updatedPatient: updated,
                                oldCnic: _patientData!['cnic']?.toString() ?? _patientData!['guardianCnic']?.toString(),
                              );

                              Navigator.pop(ctx);

                              if (mounted) {
                                setState(() {
                                  _patientData = updated;
                                  if (newCnic.isNotEmpty) {
                                    cnicController.text = newCnic;
                                  }
                                });
                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                                  content: Text('✅ Patient details & CNIC updated instantly!'),
                                  backgroundColor: Colors.green,
                                  duration: Duration(seconds: 3),
                                ));
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green.shade700,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                              elevation: 2,
                            ),
                            child: const Text('Save Changes',
                                style: TextStyle(fontWeight: FontWeight.w700)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    } catch (e, stack) {
      debugPrint('Edit dialog error: $e\n$stack');
    }
  }

  Widget _radioGroup(
    String title,
    List<String> options,
    String current,
    void Function(String) onChanged,
  ) {
    final isDark = _isDark;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 14,
          color: isDark ? const Color(0xFF5EEAD4) : Colors.green.shade800,
        )),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: options
              .map((o) => SizedBox(
                    width: 110,
                    child: RadioListTile<String>(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      title: Text(o, style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: isDark ? const Color(0xFFE2E8F0) : Colors.black87,
                      )),
                      value: o,
                      groupValue: current,
                      activeColor: isDark ? const Color(0xFF2DD4BF) : Colors.green.shade700,
                      onChanged: (v) => onChanged(v!),
                    ),
                  ))
              .toList(),
        ),
      ]),
    );
  }

  // ── Vitals dialog ──────────────────────────────────────────────────────────
  void _showVitalsDialog() async {
    if (_isVitalsDialogOpen || !mounted) return;
    final hasVitalsToday = _hasVitalsTokenToday(_patientData);
    final hasRegularToday = _hasRegularTokenToday(_patientData);

    _isVitalsDialogOpen = true;
    try {
      await showDialog(
        context: context,
        barrierDismissible: true,
        builder: (_) => _VitalsInputDialog(
          patientData: _patientData,
          hasVitalsToday: hasVitalsToday,
          hasRegularToday: hasRegularToday,
          allowVitalsToken: _isVitalsTokenAllowed,
          onSubmitted: ({
            required String bp,
            required String temp,
            required String sugar,
            required String weight,
            required int suggestedDays,
            required bool isVitalsOnly,
          }) {
            _generateToken(
              bp: bp,
              temp: temp,
              sugar: sugar,
              weight: weight,
              suggestedDays: suggestedDays,
              isVitalsOnly: isVitalsOnly,
            );
          },
        ),
      );
    } finally {
      _isVitalsDialogOpen = false;
    }
  }

  Future<void> _requestTokenException() async {
    if (_patientData == null) return;
    setState(() => _isLoading = true);

    try {
      final rId = _getRestrictionId(_patientData!);
      final pId = _patientData!['patientId']?.toString() ?? '';

      final matchedId = (LocalStorageService.isPatientBlockedByMedicine(widget.branchId, rId) != null)
          ? rId : pId;

      final patientName = _patientData!['name']?.toString() ?? 'Unknown';

      final requestData = <String, dynamic>{
        'requestType':     'token_exception',
        'status':          'pending',
        'patientId':       matchedId,
        'patientName':     patientName,
        'cnic':            _patientData!['cnic'],
        'guardianCnic':    _patientData!['guardianCnic'],
        'restriction':     _medicineRestriction ?? {
          'reason': 'Token already issued today for this patient',
          'remainingDays': 0,
        },
        'requestedBy':     widget.receptionistId,
        'requestedByName': widget.receptionistName,
        'requestedAt':     DateTime.now().toIso8601String(),
        'targetRole':      'doctor',
        'branchId':        widget.branchId,
      };

      final docId = 'req_exception_${widget.receptionistId}_${DateTime.now().millisecondsSinceEpoch}';

      try {
        await FirebaseFirestore.instance
            .collection('branches')
            .doc(widget.branchId)
            .collection('edit_requests')
            .doc(docId)
            .set({
          ...requestData,
          'requestedAt': FieldValue.serverTimestamp(),
        });
      } catch (e) {
        debugPrint('[TokenScreen] Firestore offline — using generated ID: $docId');
      }

      await LocalStorageService.saveLocalEditRequest({
        ...requestData,
        'id': docId,
        'requestId': docId,
        'branchId': widget.branchId,
        'status': 'pending',
        'requestedAt': DateTime.now().toIso8601String(),
      });

      await LocalStorageService.enqueueSync({
        'type':      'save_token_exception_request',
        'branchId':  widget.branchId,
        'requestId': docId,
        'data':      requestData,
      });

      RealtimeManager().sendMessage({
        ...RealtimeEvents.payload(
          type:     RealtimeEvents.tokenExceptionRequest,
          branchId: widget.branchId,
          data: {
            'requestId':   docId,
            'patientId':   matchedId,
            'patientName': patientName,
            'restriction': _medicineRestriction ?? {
              'reason': 'Token already issued today for this patient',
              'remainingDays': 0,
            },
            'branchId':    widget.branchId,
          },
        ),
      });

      try {
        CloudMessagingService().notifySupervisorPendingRequests(
          branchId: widget.branchId,
          requestType: 'Token Exception',
          requesterName: widget.receptionistName,
          details: 'Token exception requested for $patientName',
        );
      } catch (e) {
        debugPrint('[TokenScreen] Supervisor notification error: $e');
      }

      setState(() {
        _isExceptionPending = true;
        _isLoading = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('✅ Exception request sent to Doctor!'),
          backgroundColor: Colors.blue,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('❌ Failed to send request: $e'),
          backgroundColor: Colors.redAccent,
        ));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _editField(
    TextEditingController ctrl,
    String label,
    IconData icon, {
    bool readOnly = false,
    List<TextInputFormatter>? formatters,
    int? maxLen,
  }) {
    final isDark = _isDark;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: ctrl,
        readOnly: readOnly,
        inputFormatters: formatters,
        maxLength: maxLen,
        buildCounter: maxLen != null ? (_, {required currentLength, required isFocused, maxLength}) => null : null,
        style: TextStyle(
          fontSize: 14,
          color: isDark ? Colors.white : Colors.black87,
          fontWeight: FontWeight.w500,
        ),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(
            color: isDark ? const Color(0xFF5EEAD4) : Colors.green.shade700,
            fontWeight: FontWeight.w500,
            fontSize: 12,
          ),
          isDense: true,
          prefixIcon: Icon(icon, color: isDark ? const Color(0xFF5EEAD4) : Colors.green, size: 20),
          filled: true,
          fillColor: isDark
              ? (readOnly ? const Color(0xFF0F172A).withValues(alpha: 0.6) : const Color(0xFF0F172A))
              : (readOnly ? Colors.grey.shade100 : Colors.white),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: isDark ? const Color(0xFF334155) : Colors.grey.shade300)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: isDark ? const Color(0xFF334155) : Colors.grey.shade300)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: isDark ? const Color(0xFF2DD4BF) : Colors.green, width: 2)),
          contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        ),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  bool get _isDark {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final dark = Hive.box('app_settings').get('is_dark_mode');
        if (dark != null) return dark == true;
      }
    } catch (_) {}
    return Theme.of(context).brightness == Brightness.dark;
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth    = MediaQuery.of(context).size.width;
    final isMobile       = screenWidth < 600;
    final containerWidth = isMobile ? double.infinity : 480.0;
    final isDark = _isDark;

    return Container(
      color: Colors.transparent,
      child: Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(
              horizontal: isMobile ? 12 : 20,
              vertical:   isMobile ? 16 : 24),
          child: Container(
            width: containerWidth,
            padding: EdgeInsets.all(isMobile ? 18 : 30),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E293B) : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: isDark ? const Color(0xFF334155) : Colors.green.shade200,
                  width: 1.5),
              boxShadow: [
                BoxShadow(
                    color: isDark ? Colors.black26 : Colors.green.withValues(alpha: 0.07),
                    blurRadius: 20,
                    offset: const Offset(0, 6)),
              ],
            ),
            child: Stack(children: [
              Column(mainAxisSize: MainAxisSize.min, children: [
                // Next serial badge
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: isMobile ? 16 : 24,
                      vertical:   isMobile ? 8  : 10),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF0F766E).withValues(alpha: 0.2) : _teal.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(color: isDark ? const Color(0xFF0F766E) : _teal.withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    'Next Token: ${_nextSerial ?? 'Loading...'}',
                    style: TextStyle(
                        color: isDark ? const Color(0xFF38BDF8) : _teal, fontWeight: FontWeight.bold,
                        fontSize: isMobile ? 16 : 20, letterSpacing: 0.4),
                  ),
                ),
                SizedBox(height: isMobile ? 14 : 20),
                Image.asset('assets/logo/gmwf-1.webp',
                    height: isMobile ? 64 : 90),
                SizedBox(height: isMobile ? 10 : 16),
                Text('Issue Token',
                    style: TextStyle(
                        fontSize:   isMobile ? 18 : 22,
                        fontWeight: FontWeight.bold,
                        color:      isDark ? Colors.white : Colors.green[900])),
                SizedBox(height: isMobile ? 18 : 28),

                // CNIC field
                TextField(
                  controller:   cnicController,
                  focusNode:    _cnicFocusNode,
                  maxLength:    15,
                  keyboardType: TextInputType.number,
                  cursorColor:  isDark ? const Color(0xFF38BDF8) : Colors.green[900],
                  onChanged: (v) {
                    final d = v.replaceAll(RegExp(r'[^0-9]'), '');
                    if (d.startsWith('03')) {
                      final phoneDigits = d.length > 11 ? d.substring(0, 11) : d;
                      cnicController.value = TextEditingValue(
                          text: phoneDigits,
                          selection: TextSelection.collapsed(offset: phoneDigits.length));
                    } else {
                      final cnicDigits = d.length > 13 ? d.substring(0, 13) : d;
                      final f = _formatCnic(cnicDigits);
                      cnicController.value = TextEditingValue(
                          text: f,
                          selection: TextSelection.collapsed(offset: f.length));
                    }
                  },
                  onSubmitted: (_) => triggerSearch(),
                  style: TextStyle(color: isDark ? Colors.white : Colors.green[900]),
                  decoration: InputDecoration(
                    labelText:   'Guardian CNIC or Phone',
                    counterText: '',
                    labelStyle:  TextStyle(color: isDark ? const Color(0xFF94A3B8) : Colors.green),
                    prefixIcon:  Icon(Icons.badge, color: isDark ? const Color(0xFF38BDF8) : Colors.green),
                    suffixIcon:  IconButton(
                        icon: Icon(Icons.search, color: isDark ? const Color(0xFF38BDF8) : Colors.green),
                        onPressed: triggerSearch),
                    filled: true, fillColor: isDark ? const Color(0xFF334155) : Colors.green[50],
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: isDark ? const Color(0xFF475569) : Colors.green)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide:
                            BorderSide(color: isDark ? const Color(0xFF38BDF8) : Colors.green, width: 2)),
                  ),
                ),
                const SizedBox(height: 12),

                if (_errorMessage != null)
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                        color: Colors.red[50],
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red.shade200)),
                    child: Row(children: [
                      const Icon(Icons.error_outline,
                          color: Colors.red, size: 18),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_errorMessage!,
                          style: const TextStyle(
                              color: Colors.red, fontSize: 13))),
                    ]),
                  ),

                if (_patientData == null && _patientsList.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ..._patientsList.map((p) {
                    final cnicInfo = _getDisplayCnicInfo(p);
                    final vitalsToken = _getPatientTodayToken(p, isVitalsOnly: true);
                    final regularToken = _getPatientTodayToken(p, isVitalsOnly: false);
                    final rId = _getRestrictionId(p);
                    final restriction = LocalStorageService.isPatientBlockedByMedicine(widget.branchId, rId);

                    final hasBoth = _isVitalsTokenAllowed ? (vitalsToken != null && regularToken != null) : (regularToken != null);
                    final hasAny = _isVitalsTokenAllowed ? (vitalsToken != null || regularToken != null) : (regularToken != null);
                    final isRestricted = restriction != null;

                    Color cardBg;
                    Color cardBorder;
                    if (hasBoth) {
                      cardBg = isDark ? const Color(0xFF3B1E1E) : const Color(0xFFFEF2F2);
                      cardBorder = isDark ? const Color(0xFF7F1D1D) : const Color(0xFFFECACA);
                    } else if (isRestricted && regularToken == null) {
                      cardBg = isDark ? const Color(0xFF3B2A1E) : const Color(0xFFFFFBEB);
                      cardBorder = isDark ? const Color(0xFF78350F) : const Color(0xFFFDE68A);
                    } else {
                      cardBg = isDark ? const Color(0xFF1E293B) : Colors.green[50]!;
                      cardBorder = isDark ? const Color(0xFF334155) : Colors.green.shade200;
                    }

                    return Card(
                      color: cardBg,
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: BorderSide(color: cardBorder, width: hasBoth || isRestricted ? 1.5 : 1)),
                      child: ListTile(
                        dense: isMobile,
                        contentPadding: EdgeInsets.symmetric(
                            horizontal: isMobile ? 10 : 16,
                            vertical:   isMobile ? 4  : 8),
                        title: Row(
                          children: [
                            Expanded(
                              child: Text(
                                p['name'] as String? ?? '',
                                style: TextStyle(
                                    color: isDark ? Colors.white : (hasBoth ? Colors.red.shade900 : Colors.green[900]),
                                    fontWeight: FontWeight.bold,
                                    fontSize: isMobile ? 15 : 16),
                              ),
                            ),
                            if (hasBoth)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: Colors.red.shade600,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  _isVitalsTokenAllowed
                                      ? '🎟️ Dual Tokens Done'
                                      : (regularToken != null && regularToken['serial'] != null
                                          ? '🎟️ #${regularToken['serial']}'
                                          : '🎟️ Token Issued'),
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold),
                                ),
                              )
                            else if (hasAny)
                              Wrap(spacing: 4, runSpacing: 4, children: [
                                if (vitalsToken != null && _isVitalsTokenAllowed)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.purple.shade700,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      '🩺 Vitals: #${vitalsToken['serial'] ?? 'Issued'}',
                                      style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                if (regularToken != null)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.teal.shade700,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      '🎟️ Regular: #${regularToken['serial'] ?? 'Issued'}',
                                      style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                              ])
                            else if (isRestricted)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: Colors.orange.shade700,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  '💊 ${restriction['remainingDays']}d Left',
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold),
                                ),
                              )
                            else
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: Colors.green.shade600,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Text(
                                  '🟢 Available',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold),
                                ),
                              ),
                          ],
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${cnicInfo.label}: ${cnicInfo.cnic}',
                                  style: TextStyle(
                                      color: isDark ? const Color(0xFF94A3B8) : Colors.green[800], fontSize: 12)),
                              Text('Phone: ${p['phone'] ?? '-'}',
                                  style: TextStyle(
                                      color: isDark ? const Color(0xFF94A3B8) : Colors.green[800], fontSize: 12)),
                              if (vitalsToken != null && _isVitalsTokenAllowed)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Row(children: [
                                    Container(
                                      width: 8, height: 8,
                                      decoration: BoxDecoration(color: Colors.purple.shade400, shape: BoxShape.circle),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        'Vitals Inspection: #${vitalsToken['serial'] ?? 'Issued'} (${(vitalsToken['status'] ?? 'waiting').toString().toUpperCase()})',
                                        style: TextStyle(
                                            color: isDark ? const Color(0xFFC084FC) : Colors.purple.shade900,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                  ]),
                                ),
                              if (regularToken != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Row(children: [
                                    Container(
                                      width: 8, height: 8,
                                      decoration: BoxDecoration(color: Colors.teal.shade400, shape: BoxShape.circle),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        'Regular Visit: #${regularToken['serial'] ?? 'Issued'} (${(regularToken['status'] ?? 'waiting').toString().toUpperCase()})',
                                        style: TextStyle(
                                            color: isDark ? const Color(0xFF2DD4BF) : Colors.teal.shade900,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                  ]),
                                ),
                              if (!hasBoth && _isVitalsTokenAllowed) ...[
                                if (vitalsToken == null && regularToken != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(
                                      '🩺 Vitals Inspection: 🟢 Available Today',
                                      style: TextStyle(
                                          color: isDark ? const Color(0xFFA78BFA) : Colors.purple.shade700,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                if (regularToken == null && vitalsToken != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(
                                      '🎟️ Regular Token: 🟢 Available Today',
                                      style: TextStyle(
                                          color: isDark ? const Color(0xFF5EEAD4) : Colors.teal.shade700,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600),
                                    ),
                                  ),
                              ],
                            ],
                          ),
                        ),
                        trailing: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                              backgroundColor: hasBoth
                                  ? Colors.red.shade600
                                  : (isRestricted && regularToken == null ? Colors.orange.shade600 : Colors.green[600]),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 10),
                              minimumSize: const Size(80, 38),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                          onPressed: () async => await _selectPatient(p),
                          child: Text(hasBoth ? 'View' : 'Select',
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                        ),
                      ),
                    );
                  }),
                  const SizedBox(height: 16),
                ] else if (_patientData != null) ...[
                  const SizedBox(height: 8),
                  if (_patientsList.length > 1) ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => setState(() => _patientData = null),
                        icon: Icon(Icons.arrow_back, size: 16, color: _isDark ? const Color(0xFF38BDF8) : Colors.green),
                        label: Text('Back to Family List',
                            style: TextStyle(
                                color: _isDark ? const Color(0xFF38BDF8) : Colors.green,
                                fontWeight: FontWeight.bold,
                                fontSize: 13)),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          backgroundColor: _isDark ? const Color(0xFF1E293B) : Colors.green.shade50,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                              side: BorderSide(color: _isDark ? const Color(0xFF334155) : Colors.green.shade200)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  () {
                    final vitalsTodayToken = _getPatientTodayToken(_patientData!, isVitalsOnly: true);
                    final regularTodayToken = _getPatientTodayToken(_patientData!, isVitalsOnly: false);
                    final hasVitalsToday = _isVitalsTokenAllowed && vitalsTodayToken != null;
                    final hasRegularToday = regularTodayToken != null;
                    final hasBothToday = hasVitalsToday && hasRegularToday;

                    return Container(
                      padding: EdgeInsets.all(isMobile ? 12 : 16),
                      decoration: BoxDecoration(
                        color: _isDark ? const Color(0xFF1E293B) : Colors.green[50],
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: _isDark ? const Color(0xFF334155) : Colors.green.shade200),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: Text(
                                _patientData!['name'] as String? ?? '',
                                style: TextStyle(
                                    fontSize:   isMobile ? 17 : 20,
                                    color:      _isDark ? Colors.white : Colors.green,
                                    fontWeight: FontWeight.bold),
                              )),
                              IconButton(
                                icon: const Icon(Icons.history_rounded,
                                    color: Color(0xFF0D9488), size: 24),
                                tooltip: 'Audit History',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                onPressed: () {
                                  final pId = _patientData!['patientId']?.toString() ?? _patientData!['id']?.toString() ?? '';
                                  PatientAuditHistoryDialog.show(
                                    context,
                                    patientId: pId,
                                    patientName: _patientData!['name']?.toString(),
                                    branchId: widget.branchId,
                                  );
                                },
                              ),
                              const SizedBox(width: 12),
                              IconButton(
                                icon: const Icon(Icons.edit,
                                    color: Colors.orange, size: 24),
                                tooltip: 'Edit Details',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                onPressed: _requestEditPatient,
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Wrap(spacing: 8, runSpacing: 4, children: [
                            Builder(builder: (context) {
                              final staffInfo = StaffPatientLinkService.getStaffInfoForPatient(
                                cnic: _patientData!['cnic']?.toString() ?? _patientData!['guardianCnic']?.toString(),
                                name: _patientData!['name']?.toString() ?? _patientData!['patientName']?.toString(),
                              );
                              if (staffInfo != null) {
                                return StaffPatientLinkService.buildStaffBadge(staffInfo, isDark: _isDark);
                              }
                              return const SizedBox.shrink();
                            }),
                            _infoBadge(Icons.badge, () {
                              final i = _getDisplayCnicInfo(_patientData!);
                              return '${i.label}: ${i.cnic}';
                            }()),
                            _infoBadge(Icons.phone,
                                'Phone: ${_patientData!['phone'] ?? '-'}'),
                            _infoBadge(
                                Icons.category,
                                () {
                                  final q = _resolveQueueType(_patientData!['status'] as String?);
                                  if (_isKarachi) {
                                    if (q.toLowerCase() == 'zakat' || q.toLowerCase() == 'non-zakat') return 'PKR 20';
                                    if (q.toLowerCase() == 'gmwf') return 'GMWF';
                                  }
                                  return q;
                                }()),
                          ]),
                          if ((hasBothToday && _isVitalsTokenAllowed) || ((hasRegularToday || hasVitalsToday) && !_isVitalsTokenAllowed)) ...[
                            const SizedBox(height: 10),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                  color: _isDark ? const Color(0xFF450A0A) : Colors.red[50],
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                      color: _isDark ? const Color(0xFFEF4444) : Colors.red.shade300)),
                              child: Column(
                                children: [
                                  Row(children: [
                                    const Icon(Icons.warning_amber_rounded,
                                        color: Colors.red, size: 22),
                                    const SizedBox(width: 8),
                                    Expanded(child: Text(
                                      _isVitalsTokenAllowed
                                          ? 'Both tokens (Vitals Inspection & Regular Visit) issued today'
                                          : 'Token (#${regularTodayToken?['serial'] ?? vitalsTodayToken?['serial'] ?? 'Issued'}) already issued today',
                                      style: const TextStyle(
                                          color:      Colors.red,
                                          fontWeight: FontWeight.bold,
                                          fontSize:   13),
                                    )),
                                  ]),
                                  const SizedBox(height: 10),
                                  ElevatedButton.icon(
                                    onPressed: (_isLoading || _isExceptionPending) ? null : _requestTokenException,
                                    icon: Icon(
                                      _isExceptionPending ? Icons.hourglass_top : Icons.emergency_share_outlined,
                                      size: 18),
                                    label: Text(_isExceptionPending ? 'Exception Pending...' : 'Request Exception from Doctor'),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: _isExceptionPending ? Colors.orange.shade300 : Colors.orange.shade700,
                                      foregroundColor: Colors.white,
                                      minimumSize: const Size(double.infinity, 40),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ] else if (hasVitalsToday && !hasRegularToday && _isVitalsTokenAllowed) ...[
                            const SizedBox(height: 10),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: _isDark ? const Color(0xFF1E1B4B) : const Color(0xFFF5F3FF),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: _isDark ? const Color(0xFF6366F1) : const Color(0xFFC4B5FD)),
                              ),
                              child: Row(children: [
                                Icon(Icons.info_outline, color: _isDark ? const Color(0xFFA5B4FC) : Colors.purple.shade700, size: 20),
                                const SizedBox(width: 8),
                                Expanded(child: Text(
                                  '🩺 Vitals token (#${vitalsTodayToken['serial'] ?? 'Issued'}) taken. 🟢 Regular visit token still available today.',
                                  style: TextStyle(
                                    color: _isDark ? const Color(0xFFE0E7FF) : Colors.purple.shade900,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                )),
                              ]),
                            ),
                          ] else if (hasRegularToday && !hasVitalsToday && _isVitalsTokenAllowed) ...[
                            const SizedBox(height: 10),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: _isDark ? const Color(0xFF042F2E) : const Color(0xFFF0FDF4),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: _isDark ? const Color(0xFF14B8A6) : const Color(0xFF86EFAC)),
                              ),
                              child: Row(children: [
                                Icon(Icons.info_outline, color: _isDark ? const Color(0xFF5EEAD4) : Colors.teal.shade700, size: 20),
                                const SizedBox(width: 8),
                                Expanded(child: Text(
                                  '🎟️ Regular visit token (#${regularTodayToken['serial'] ?? 'Issued'}) taken. 🩺 Vitals inspection token still available today.',
                                  style: TextStyle(
                                    color: _isDark ? const Color(0xFFCCFBF1) : Colors.teal.shade900,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                )),
                              ]),
                            ),
                          ],
                          if (_medicineRestriction != null && !hasBothToday) ...[
                            const SizedBox(height: 10),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                  color: _isDark ? const Color(0xFF451A03) : Colors.orange[50],
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: _isDark ? const Color(0xFFF97316) : Colors.orange.shade300)),
                              child: Column(
                                children: [
                                  Row(children: [
                                    Icon(Icons.medication_liquid_outlined,
                                        color: Colors.orange.shade800, size: 22),
                                    const SizedBox(width: 8),
                                    Expanded(child: Text(
                                      _medicineRestriction!['isLastDay'] == true
                                        ? 'Restricted: Medicine expires TODAY (Vitals check still allowed)'
                                        : 'Restricted: Medicine expires in ${_medicineRestriction!['remainingDays']} days (Vitals check still allowed)',
                                      style: TextStyle(
                                          color:      _isDark ? const Color(0xFFFDBA74) : Colors.orange.shade900,
                                          fontWeight: FontWeight.bold,
                                          fontSize:   13),
                                    )),
                                  ]),
                                  const SizedBox(height: 10),
                                  ElevatedButton.icon(
                                    onPressed: (_isLoading || _isExceptionPending) ? null : _requestTokenException,
                                    icon: Icon(
                                      _isExceptionPending ? Icons.hourglass_top : Icons.emergency_share_outlined,
                                      size: 18),
                                    label: Text(_isExceptionPending ? 'Exception Pending...' : 'Request Exception from Doctor'),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: _isExceptionPending ? Colors.orange.shade300 : Colors.orange.shade700,
                                      foregroundColor: Colors.white,
                                      minimumSize: const Size(double.infinity, 40),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),
                          () {
                            final cannotIssueToken = _isVitalsTokenAllowed ? hasBothToday : (hasRegularToday || hasVitalsToday);
                            return Container(
                              width: double.infinity,
                              height: isMobile ? 48 : 52,
                              decoration: BoxDecoration(
                                gradient: cannotIssueToken
                                    ? null
                                    : const LinearGradient(
                                        colors: [Color(0xFF00A86B), Color(0xFF00875A)],
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                      ),
                                color: cannotIssueToken
                                    ? (_isDark ? const Color(0xFF334155) : Colors.grey[400])
                                    : null,
                                borderRadius: BorderRadius.circular(14),
                                boxShadow: cannotIssueToken
                                    ? null
                                    : [
                                        BoxShadow(
                                          color: const Color(0xFF00A86B).withValues(alpha: 0.3),
                                          blurRadius: 10,
                                          offset: const Offset(0, 3),
                                        ),
                                      ],
                              ),
                              child: ElevatedButton.icon(
                                onPressed: cannotIssueToken ? null : _showVitalsDialog,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.transparent,
                                  foregroundColor: Colors.white,
                                  shadowColor: Colors.transparent,
                                  padding: EdgeInsets.symmetric(
                                      vertical: isMobile ? 10 : 12),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14)),
                                ),
                                icon: const Icon(Icons.inventory_2_rounded, size: 20),
                                label: Text(
                                  cannotIssueToken
                                      ? (_isVitalsTokenAllowed ? 'Both Tokens Already Issued' : 'Token Already Issued Today')
                                      : (hasVitalsToday
                                          ? 'Issue Regular Token'
                                          : (hasRegularToday
                                              ? (_isVitalsTokenAllowed ? 'Issue Vitals Only Token' : 'Token Already Issued Today')
                                              : 'Enter Vitals & Issue Token')),
                                  style: TextStyle(
                                      fontSize: isMobile ? 14 : 15.5,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 0.3),
                                ),
                              ),
                            );
                          }(),
                        ],
                      ),
                    );
                  }(),
                ],

                SizedBox(height: isMobile ? 16 : 24),
                if (_isLoading)
                  const Center(
                      child: CircularProgressIndicator(
                          color: Colors.green)),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _infoBadge(IconData icon, String text) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: _isDark ? const Color(0xFF38BDF8) : Colors.green[700]),
          const SizedBox(width: 4),
          Text(text,
              style: TextStyle(color: _isDark ? const Color(0xFFCBD5E1) : Colors.green[800], fontSize: 12)),
        ],
      );

  ({String cnic, String label}) _getDisplayCnicInfo(
      Map<String, dynamic> patient) {
    final ownCnic      = patient['cnic']?.toString().trim();
    final guardianCnic = patient['guardianCnic']?.toString().trim();
    if (ownCnic != null && ownCnic.isNotEmpty) {
      return (cnic: ownCnic, label: 'CNIC');
    }
    if (guardianCnic != null && guardianCnic.isNotEmpty) {
      return (cnic: guardianCnic, label: 'Guardian CNIC');
    }
    return (cnic: '-', label: 'CNIC');
  }

  InputDecoration _vitalsDecoration(String label, IconData? icon, bool isDark,
          {String? hint}) =>
      InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: isDark ? const Color(0xFFA7F3D0) : const Color(0xFF064E3B)),
        hintText: hint,
        hintStyle: TextStyle(color: isDark ? const Color(0xFF475569) : const Color(0xFF94A3B8)),
        counterText: '',
        isDense: true,
        prefixIcon: icon != null
            ? Icon(icon, color: isDark ? const Color(0xFF34D399) : Colors.green.shade700, size: 20)
            : null,
        filled: true,
        fillColor: isDark ? const Color(0xFF02140F) : Colors.white,
        border: OutlineInputBorder(
            borderRadius: const BorderRadius.all(Radius.circular(10)),
            borderSide: BorderSide(color: isDark ? const Color(0xFF0D382B) : Colors.grey.shade300)),
        enabledBorder: OutlineInputBorder(
            borderRadius: const BorderRadius.all(Radius.circular(10)),
            borderSide: BorderSide(color: isDark ? const Color(0xFF0D382B) : Colors.grey.shade300)),
        focusedBorder: OutlineInputBorder(
            borderRadius: const BorderRadius.all(Radius.circular(10)),
            borderSide: BorderSide(color: isDark ? const Color(0xFF10B981) : Colors.green.shade700, width: 2)),
      );

  void _formatTemperatureAutoDot(TextEditingController controller) {
    final text    = controller.text;
    if (text.isEmpty || (text.contains('.') && text.endsWith('.'))) return;
    final cleaned = text.replaceAll(RegExp(r'[^0-9]'), '');
    if (cleaned.isEmpty) { controller.clear(); return; }
    String formatted;
    if (cleaned.startsWith('10')) {
      formatted = cleaned.length <= 3
          ? cleaned
          : '${cleaned.substring(0, 3)}.${cleaned.substring(3, cleaned.length.clamp(3, 4))}';
    } else {
      formatted = cleaned.length <= 2
          ? cleaned
          : '${cleaned.substring(0, 2)}.${cleaned.substring(2, cleaned.length.clamp(2, 3))}';
    }
    if (formatted != text) {
      controller.value = TextEditingValue(
          text: formatted,
          selection: TextSelection.collapsed(offset: formatted.length));
    }
  }
}

class _VitalsInputDialog extends StatefulWidget {
  final Map<String, dynamic>? patientData;
  final bool hasVitalsToday;
  final bool hasRegularToday;
  final bool allowVitalsToken;
  final void Function({
    required String bp,
    required String temp,
    required String sugar,
    required String weight,
    required int suggestedDays,
    required bool isVitalsOnly,
  }) onSubmitted;

  const _VitalsInputDialog({
    required this.patientData,
    required this.hasVitalsToday,
    required this.hasRegularToday,
    this.allowVitalsToken = true,
    required this.onSubmitted,
  });

  @override
  State<_VitalsInputDialog> createState() => _VitalsInputDialogState();
}

class _VitalsInputDialogState extends State<_VitalsInputDialog> {
  final systolicCtrl = TextEditingController();
  final diastolicCtrl = TextEditingController();
  final tempCtrl = TextEditingController();
  final sugarCtrl = TextEditingController();
  final weightCtrl = TextEditingController();

  final systolicFocus = FocusNode();
  final diastolicFocus = FocusNode();
  final tempFocus = FocusNode();
  final sugarFocus = FocusNode();
  final weightFocus = FocusNode();

  int suggestedDays = 1;
  bool isIssuingInDialog = false;

  static const Color _teal = Color(0xFF00695C);

  @override
  void initState() {
    super.initState();
    final lastWeight = LocalStorageService.getLastRecordedWeight(widget.patientData);
    if (lastWeight != null && lastWeight.isNotEmpty && lastWeight != 'N/A') {
      weightCtrl.text = lastWeight;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) systolicFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    systolicCtrl.dispose();
    diastolicCtrl.dispose();
    tempCtrl.dispose();
    sugarCtrl.dispose();
    weightCtrl.dispose();

    systolicFocus.dispose();
    diastolicFocus.dispose();
    tempFocus.dispose();
    sugarFocus.dispose();
    weightFocus.dispose();
    super.dispose();
  }

  void _formatTemperatureAutoDot(TextEditingController ctrl) {
    final text = ctrl.text;
    if (text.isEmpty || (text.contains('.') && text.endsWith('.'))) return;
    final cleaned = text.replaceAll(RegExp(r'[^0-9]'), '');
    if (cleaned.isEmpty) { ctrl.clear(); return; }
    String formatted;
    if (cleaned.startsWith('10')) {
      formatted = cleaned.length <= 3
          ? cleaned
          : '${cleaned.substring(0, 3)}.${cleaned.substring(3, cleaned.length.clamp(3, 4))}';
    } else {
      formatted = cleaned.length <= 2
          ? cleaned
          : '${cleaned.substring(0, 2)}.${cleaned.substring(2, cleaned.length.clamp(2, 3))}';
    }
    if (formatted != text) {
      ctrl.value = TextEditingValue(
          text: formatted,
          selection: TextSelection.collapsed(offset: formatted.length));
    }
  }

  InputDecoration _vitalsDecoration(String label, IconData? icon, bool isDark, {String? hint}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: icon != null
          ? Icon(icon, color: isDark ? const Color(0xFF34D399) : _teal, size: 20)
          : null,
      labelStyle: TextStyle(color: isDark ? const Color(0xFFA7F3D0) : Colors.grey.shade700, fontSize: 13),
      hintStyle: TextStyle(color: isDark ? const Color(0xFF64748B) : Colors.grey.shade400, fontSize: 12),
      filled: true,
      fillColor: isDark ? const Color(0xFF02140F) : Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: isDark ? const Color(0xFF0D382B) : Colors.grey.shade300)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: isDark ? const Color(0xFF0D382B) : Colors.grey.shade300)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: _teal, width: 2)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      isDense: true,
    );
  }

  void submitToken({required bool isVitalsOnly}) {
    if (isIssuingInDialog) return;
    if (isVitalsOnly && !widget.allowVitalsToken) return;
    if (isVitalsOnly && widget.hasVitalsToday) return;
    if (!isVitalsOnly && widget.hasRegularToday) return;

    final systolic  = systolicCtrl.text.trim();
    final diastolic = diastolicCtrl.text.trim();
    final temp      = tempCtrl.text.trim();
    final sugar     = sugarCtrl.text.trim();
    final weight    = weightCtrl.text.trim();

    if (systolic.isEmpty || diastolic.isEmpty || temp.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Please enter BP and Temperature!'),
          backgroundColor: Colors.red));
      return;
    }

    if (temp.isNotEmpty) {
      final tempVal = double.tryParse(temp);
      if (tempVal == null || tempVal < 80.0 || tempVal > 110.0) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Temperature must be between 80.0 and 110.0'),
            backgroundColor: Colors.red));
        return;
      }
    }

    final bpString = (systolic.isNotEmpty && diastolic.isNotEmpty)
        ? '$systolic/$diastolic'
        : (systolic.isNotEmpty ? systolic : '');

    setState(() => isIssuingInDialog = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });

    widget.onSubmitted(
      bp: bpString,
      temp: temp,
      sugar: sugar,
      weight: weight,
      suggestedDays: suggestedDays,
      isVitalsOnly: isVitalsOnly,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dialogBg = isDark ? const Color(0xFF041C16) : Colors.white;
    final titleBg = isDark ? const Color(0xFF072B21) : Colors.green.shade50;
    final titleTextColor = isDark ? const Color(0xFF34D399) : Colors.green.shade700;
    final sectionBg = isDark ? const Color(0xFF02140F) : Colors.grey.shade50;
    final sectionBorder = isDark ? const Color(0xFF0D382B) : Colors.grey.shade300;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final labelColor = isDark ? const Color(0xFFA7F3D0) : Colors.grey.shade700;
    final dialogBorder = isDark ? const Color(0xFF10B981) : Colors.green.shade200;

    final patientName = (widget.patientData?['patientName'] ?? widget.patientData?['name'] ?? widget.patientData?['fullName'] ?? 'Unknown').toString().trim();

    return AlertDialog(
      backgroundColor: dialogBg,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: dialogBorder, width: 1.5)),
      contentPadding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
      title: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: titleBg,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(children: [
          Icon(Icons.monitor_heart, color: titleTextColor, size: 24),
          const SizedBox(width: 12),
          Text(
            'Enter Vitals',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: titleTextColor,
              fontSize: 18,
            ),
          ),
        ]),
      ),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: sectionBg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: sectionBorder),
                ),
                child: Row(
                  children: [
                    Icon(Icons.person_outline, size: 20, color: _teal),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        patientName,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          color: textColor,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Blood Pressure (mmHg) *',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: labelColor,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: systolicCtrl,
                      focusNode: systolicFocus,
                      maxLength: 3,
                      textInputAction: TextInputAction.next,
                      onSubmitted: (_) => diastolicFocus.requestFocus(),
                      onChanged: (val) {
                        if (val.length == 3) diastolicFocus.requestFocus();
                      },
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      style: TextStyle(color: textColor, fontSize: 14, fontWeight: FontWeight.w600),
                      decoration: _vitalsDecoration('Systolic', Icons.favorite, isDark, hint: '120'),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      '/',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: isDark ? const Color(0xFF64748B) : Colors.grey,
                      ),
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: diastolicCtrl,
                      focusNode: diastolicFocus,
                      maxLength: 3,
                      textInputAction: TextInputAction.next,
                      onSubmitted: (_) => tempFocus.requestFocus(),
                      onChanged: (val) {
                        if (val.length == 3) tempFocus.requestFocus();
                      },
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      style: TextStyle(color: textColor, fontSize: 14, fontWeight: FontWeight.w600),
                      decoration: _vitalsDecoration('Diastolic', Icons.favorite_border, isDark, hint: '80'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: tempCtrl,
                focusNode: tempFocus,
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => sugarFocus.requestFocus(),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  LengthLimitingTextInputFormatter(5),
                ],
                onChanged: (_) => _formatTemperatureAutoDot(tempCtrl),
                style: TextStyle(color: textColor, fontSize: 14, fontWeight: FontWeight.w600),
                decoration: _vitalsDecoration(
                    'Temperature (°F)',
                    Icons.thermostat,
                    isDark,
                    hint: 'e.g. 98.6'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: sugarCtrl,
                focusNode: sugarFocus,
                maxLength: 3,
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => weightFocus.requestFocus(),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: TextStyle(color: textColor, fontSize: 14, fontWeight: FontWeight.w600),
                decoration: _vitalsDecoration('Blood Sugar (mg/dL)', Icons.bloodtype, isDark),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: weightCtrl,
                focusNode: weightFocus,
                maxLength: 3,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) {
                  if (!widget.hasRegularToday) {
                    submitToken(isVitalsOnly: false);
                  } else if (!widget.hasVitalsToday && widget.allowVitalsToken) {
                    submitToken(isVitalsOnly: true);
                  }
                },
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: TextStyle(color: textColor, fontSize: 14, fontWeight: FontWeight.w600),
                decoration: _vitalsDecoration('Weight (kg) (Optional)', Icons.monitor_weight, isDark),
              ),
              const SizedBox(height: 16),
              Text(
                'Days Suggestion (asked by patient):',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: titleTextColor),
              ),
              const SizedBox(height: 8),
              Row(
                children: [1, 2, 3].map((d) {
                  final isSelected = suggestedDays == d;
                  final itemBg = isSelected
                      ? _teal
                      : (isDark ? const Color(0xFF02140F) : Colors.green.shade50);
                  final itemBorder = isSelected
                      ? _teal
                      : (isDark ? const Color(0xFF0D382B) : Colors.green.shade200);

                  return Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(right: d < 3 ? 8 : 0),
                      child: InkWell(
                        onTap: () => setState(() => suggestedDays = d),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: itemBg,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: itemBorder,
                              width: 1.5,
                            ),
                          ),
                          child: Center(
                            child: Text(
                              '$d Day${d > 1 ? 's' : ''}',
                              style: TextStyle(
                                color: isSelected
                                    ? Colors.white
                                    : (isDark ? const Color(0xFF34D399) : _teal),
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: sectionBg,
            borderRadius: const BorderRadius.only(
              bottomLeft: Radius.circular(20),
              bottomRight: Radius.circular(20),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () {
                  if (Navigator.of(context).canPop()) Navigator.of(context).pop();
                },
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: Text('Cancel',
                    style: TextStyle(
                        color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600,
                        fontWeight: FontWeight.w500)),
              ),
              if (widget.allowVitalsToken) ...[
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: (isIssuingInDialog || widget.hasVitalsToday) ? null : () => submitToken(isVitalsOnly: true),
                  icon: Icon(widget.hasVitalsToday ? Icons.check_circle_outline : Icons.monitor_heart, size: 18),
                  label: Text(
                    widget.hasVitalsToday ? 'Vitals Token Issued Today' : 'Issue Vitals Only Token',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: widget.hasVitalsToday ? Colors.grey : Colors.purple.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                    elevation: widget.hasVitalsToday ? 0 : 2,
                  ),
                ),
              ],
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: (isIssuingInDialog || widget.hasRegularToday) ? null : () => submitToken(isVitalsOnly: false),
                icon: Icon(widget.hasRegularToday ? Icons.check_circle_outline : Icons.local_hospital, size: 18),
                label: Text(
                  widget.hasRegularToday
                      ? (widget.allowVitalsToken ? 'Regular Token Issued Today' : 'Token Issued Today')
                      : (widget.allowVitalsToken ? 'Issue Regular Token' : 'Issue Token'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: widget.hasRegularToday ? Colors.grey : Colors.green.shade600,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                  elevation: widget.hasRegularToday ? 0 : 2,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}