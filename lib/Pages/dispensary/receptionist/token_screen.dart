// lib/pages/dispensary/receptionist/token_screen.dart

import 'package:gmwf/services/cloud/cloud_db.dart';
import 'package:gmwf/services/cloud/lan_firestore_gate.dart';
import 'package:gmwf/services/quota_service.dart';
import 'package:gmwf/utils/perf_trace.dart';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:gmwf/design/components/flushbar_compat.dart';
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
import 'package:gmwf/design/design_system.dart';
import 'package:gmwf/utils/branch_labels.dart';

class TokenScreen extends StatefulWidget {
  final String branchId;
  final String receptionistId;
  final String receptionistName;
  final String? dispensaryId;
  final Function(String cnic)? onPatientNotFound;
  final String? initialCnic;
  final String? targetPatientId;
  final bool isCompactHybrid;

  const TokenScreen({
    super.key,
    required this.branchId,
    required this.receptionistId,
    required this.receptionistName,
    this.dispensaryId,
    this.onPatientNotFound,
    this.initialCnic,
    this.targetPatientId,
    this.isCompactHybrid = false,
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
  Timer? _searchDebounceTimer;

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
    return null;
  }

  void _onActiveCampChanged() {
    if (!mounted) return;
    final active = CampSessionService.getActiveCamp(widget.branchId);
    if (active != null && active.isNotEmpty && active != _capturedDispensaryId) {
      setState(() {
        _capturedDispensaryId = active;
      });
      _estimateNextSerial();
    }
  }

  void updateDispensaryId(String campId) {
    if (_capturedDispensaryId != campId) {
      if (mounted) {
        setState(() {
          _capturedDispensaryId = campId;
        });
        _estimateNextSerial();
      }
    }
  }

  bool get _isKarachi => BranchLabels.isKarachiBranch(widget.branchId);

  @override
  void initState() {
    super.initState();
    debugPrint("[Lifecycle] TokenScreen initState");
    WidgetsBinding.instance.addObserver(this);
    LocalStorageService.ensureBoxOpen(LocalStorageService.patientsBox);
    LocalStorageService.ensureBoxOpen(LocalStorageService.entriesBox);
    _capturedDispensaryId = PerfTrace.measure('TokenScreen.initState: _computeInitialDispensaryId', _computeInitialDispensaryId);
    CampSessionService.activeCampNotifier.addListener(_onActiveCampChanged);
    PerfTrace.measureAsync('TokenScreen.initState: _estimateNextSerial', _estimateNextSerial);

    // Background CNIC standardization & deduplication check for active branch
    Future.microtask(() {
      LocalStorageService.standardizeAndDeduplicateAllPatients(
        branchId: widget.branchId,
        processRemote: false,
      );
    });

    if (widget.targetPatientId != null && widget.targetPatientId!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        selectPatientDirectly(widget.targetPatientId!, cnicFallback: widget.initialCnic);
      });
    } else if (widget.initialCnic != null && widget.initialCnic!.isNotEmpty) {
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
      } else if (type == 'patient_edit_approved' ||
          type == RealtimeEvents.savePatient ||
          type == 'save_patient' ||
          type == 'migrate_patient_key') {
        final eventPid = (data['patientId'] ?? data['oldPatientId'] ?? '').toString().trim();
        final newPid = (data['newPatientId'] ?? data['changes']?['patientId'] ?? eventPid).toString().trim();
        final rawChanges = data['changes'] ?? data['patient'] ?? data;
        if (type == 'patient_edit_approved' && eventPid.isNotEmpty && rawChanges is Map) {
          await LocalStorageService.updatePatientWithCnicMigration(
            oldPatientId: eventPid,
            updatedPatient: {
              ...Map<String, dynamic>.from(rawChanges),
              'branchId': widget.branchId,
            },
            isFromSync: true,
          );
        }
        if (mounted) {
          setState(() {
            if (_patientData != null) {
              final curPid = (_patientData!['patientId'] ?? _patientData!['id'] ?? '').toString().trim();
              if (curPid.isNotEmpty && (curPid == eventPid || curPid == newPid || eventPid.isEmpty)) {
                final fresh = (newPid.isNotEmpty ? LocalStorageService.getLocalPatient(newPid) : null) ??
                    LocalStorageService.getLocalPatient(curPid);
                if (fresh != null) {
                  _patientData = fresh;
                }
              }
            }
            for (int i = 0; i < _patientsList.length; i++) {
              final itemPid = (_patientsList[i]['patientId'] ?? _patientsList[i]['id'] ?? '').toString().trim();
              if (itemPid.isNotEmpty && (itemPid == eventPid || itemPid == newPid)) {
                final fresh = (newPid.isNotEmpty ? LocalStorageService.getLocalPatient(newPid) : null) ??
                    LocalStorageService.getLocalPatient(itemPid);
                if (fresh != null) {
                  _patientsList[i] = fresh;
                }
              }
            }
          });
          if (type == 'patient_edit_approved') {
            AppToast.showSnackBar(
              context,
              const SnackBar(
                content: Text('✅ Patient edit request approved & applied!'),
                backgroundColor: SoftPalette.green500,
                duration: Duration(seconds: 3),
              ),
            );
          }
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
                backgroundColor: SoftPalette.green500,
                duration: const Duration(seconds: 4),
                flushbarPosition: FlushbarPosition.TOP,
                margin: const EdgeInsets.all(12),
                borderRadius: BorderRadius.circular(12),
                icon: const Icon(Icons.check_circle, color: SoftPalette.gray50),
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
            Icon(Icons.shield_outlined, color: SoftPalette.teal500),
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
                style: ElevatedButton.styleFrom(backgroundColor: SoftPalette.teal500, foregroundColor: SoftPalette.gray50),
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
    CampSessionService.activeCampNotifier.removeListener(_onActiveCampChanged);
    _debounceListenerTimer?.cancel();  // ← HANG FIX: Clean up debounce timer
    _searchDebounceTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _realtimeSub?.cancel();
    cnicController.dispose();
    _cnicFocusNode.dispose();
    debugPrint("[Lifecycle] TokenScreen dispose");
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
    // Only react to a NEW target. Re-selecting whenever _patientData is null re-opened the
    // last registered patient on every parent rebuild (connection/sync status changes).
    if (widget.targetPatientId != null &&
        widget.targetPatientId!.isNotEmpty &&
        (widget.targetPatientId != oldWidget.targetPatientId ||
         widget.initialCnic != oldWidget.initialCnic)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        selectPatientDirectly(widget.targetPatientId!, cnicFallback: widget.initialCnic);
      });
    } else if (widget.initialCnic != null &&
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

    // Individual-based check: uses patientId (CNIC for adults, CNIC_child_Name for kids, cross-linked with guardian/phone)
    final restriction = LocalStorageService.isPatientBlockedByMedicine(widget.branchId, rId, patient);

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

    final pNameNorm = norm(LocalStorageService.resolveCanonicalPatientName(patient));
    final pCnicNorm = norm(patient['cnic'] ?? patient['patientCnic']);
    final pGuardNorm = norm(patient['guardianCnic']);
    final pPhoneNorm = norm(patient['phone'] ?? patient['contactPhone']);

    final isChild = LocalStorageService.isChildPatientRecord(patient);

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
    final matchingActive = <Map<String, dynamic>>[];
    final matchingSkipped = <Map<String, dynamic>>[];

    for (final e in entries) {
      if (!_isEntryFromToday(e, targetDateKey: targetDate)) continue;

      final status = (e['status'] ?? '').toString().toLowerCase().trim();
      if (status == 'deleted' || status == 'cancelled' || status == 'expired' || status == 'void') {
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
      final eExplicitAdult = e['isAdult'] is bool ? e['isAdult'] as bool : null;
      final eIsChild = eId.contains('_child_') ||
          resolvedEId.contains('_child_') ||
          (eExplicitAdult != null
              ? !eExplicitAdult
              : (eGuardNorm.isNotEmpty || (eAge > 0 && eAge < 18)));

      // Rule 0: Adult and Child are strictly distinct entities. Never cross-match!
      if (isChild != eIsChild) {
        continue;
      }

      bool isDummy(String c) =>
          c.isEmpty ||
          c == '0000000000000' ||
          c == '1234567890123' ||
          RegExp(r'^0+$').hasMatch(c) ||
          RegExp(r'^1+$').hasMatch(c) ||
          c == 'na' ||
          c == 'none';

      bool isMatch = false;

      // Rule 1: Canonical resolved individual patientId match (non-dummy)
      if (cleanResolvedPId.isNotEmpty && !isDummy(cleanResolvedPId) && (cleanResolvedPId == cleanResolvedEId || cleanResolvedPId == cleanEId)) {
        isMatch = true;
      } else if (cleanId.isNotEmpty && !isDummy(cleanId) && cleanId.contains('_child_') && (cleanId == cleanEId || cleanId == cleanResolvedEId)) {
        isMatch = true;
      } else if (!isChild && !eIsChild) {
        // Rule 2: Adult match by adult CNIC (non-dummy) + exact name match
        if (pCnicNorm.isNotEmpty && !isDummy(pCnicNorm) && eCnicNorm.isNotEmpty && pCnicNorm == eCnicNorm) {
          if (pNameNorm.isNotEmpty && eNameNorm.isNotEmpty) {
            if (pNameNorm == eNameNorm) isMatch = true;
          } else {
            isMatch = true;
          }
        }
      } else if (isChild && eIsChild) {
        // Rule 3: Child match under same guardian CNIC (requires non-dummy CNIC AND EXACT name match)
        final pGuard = pGuardNorm.isNotEmpty ? pGuardNorm : pCnicNorm;
        final eGuard = eGuardNorm.isNotEmpty ? eGuardNorm : eCnicNorm;
        if (pGuard.isNotEmpty && !isDummy(pGuard) && eGuard.isNotEmpty && pGuard == eGuard) {
          if (pNameNorm.isNotEmpty && eNameNorm.isNotEmpty && pNameNorm == eNameNorm) {
            isMatch = true;
          }
        }
      }

      // Rule 4: Phone matching (non-dummy) + EXACT name match
      if (!isMatch && pPhoneNorm.length >= 7 && !isDummy(pPhoneNorm) && pPhoneNorm == ePhoneNorm) {
        if (pNameNorm.isNotEmpty && eNameNorm.isNotEmpty && pNameNorm == eNameNorm) {
          isMatch = true;
        }
      }

      if (isMatch) {
        if (status == 'skipped') {
          matchingSkipped.add(e);
        } else {
          matchingActive.add(e);
        }
      }
    }

    // Rule: 1 token per day.
    // If patient already has an active/completed token -> blocked
    if (matchingActive.isNotEmpty) {
      return matchingActive.first;
    }
    // If patient was skipped 2 or more times -> blocked (doctor exception required to issue another)
    if (matchingSkipped.length >= 2) {
      return matchingSkipped.first;
    }
    // If patient was skipped 1 time (and no active token) -> allow 1 retry token!
    // If patient was never issued (0 active, 0 skipped) -> allowed!
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
    int activeCount = 0;
    int skippedCount = 0;
    for (final e in entries) {
      // The list holds the whole token history in key order; an older token is skipped. (It
      // used to end the check, so the first old token made every patient look token-free.)
      if (!_isEntryFromToday(e, targetDateKey: targetDate)) continue;

      final status = (e['status'] ?? '').toString().toLowerCase();
      if (status == 'deleted' || status == 'cancelled' || status == 'expired' || status == 'void') {
        continue;
      }

      final eIsVitals = e['isVitalsOnly'] == true ||
          e['vitalsOnly'] == true ||
          (e['visitReason']?.toString().toLowerCase().contains('vitals') == true);
      if (isVitalsOnly != null && eIsVitals != isVitalsOnly) {
        continue;
      }

      final resolvedEPid = LocalStorageService.resolveIndividualPatientId(e).replaceAll(RegExp(r'[^\w]'), '').toLowerCase();
      final ePid   = (e['patientId'] ?? '').toString().replaceAll(RegExp(r'[^\w]'), '').toLowerCase();
      if (cleanId.isNotEmpty && (resolvedEPid == cleanId || ePid == cleanId)) {
        if (status == 'skipped') {
          skippedCount++;
        } else {
          activeCount++;
        }
      }
    }
    if (activeCount > 0) return true;
    if (skippedCount >= 2) return true;
    return false;
  }

  Future<void> _estimateNextSerial() async {
    final now = CampSessionService.getAuthoritativeTime();
    final shiftInfo = CampSessionService.resolveShiftAndDateKey(now, widget.branchId);
    final datePart = shiftInfo.dateKey;
    final session = shiftInfo.session;
    final activeCamp = _capturedDispensaryId ?? CampSessionService.getActiveCamp(widget.branchId);
    final nextSeq = await LocalStorageService.getNextLocalSerialSequence(
      widget.branchId,
      datePart,
      dispensaryId: activeCamp,
      session: session,
      increment: false,
    );
    final sessionLetter = CampSessionService.getSessionLetter(session);
    final dispTag = CampSessionService.getDispensaryKeyword(activeCamp, branchId: widget.branchId);
    final serialStr = '$datePart$sessionLetter-$dispTag-${nextSeq.toString().padLeft(3, '0')}';
    if (mounted) {
      setState(() {
        _nextSerial = serialStr;
      });
    }
  }

  Future<void> focusAndSelectPatient(String patientId, {String? cnicToFill}) async {
    _searchDebounceTimer?.cancel();
    final cnic = (cnicToFill != null && cnicToFill.isNotEmpty)
        ? cnicToFill
        : (patientId.contains('_child_') ? patientId.split('_child_').first : patientId);
    final d = cnic.replaceAll(RegExp(r'[^0-9]'), '');
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

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await LocalStorageService.ensureBoxOpen(LocalStorageService.patientsBox);
      await LocalStorageService.ensureBoxOpen(LocalStorageService.entriesBox);

      var localResults = LocalStorageService.searchPatientsByCnicOrGuardian(
          formatted, branchId: widget.branchId);
      if (localResults.isEmpty && d.isNotEmpty && d != formatted) {
        localResults = LocalStorageService.searchPatientsByCnicOrGuardian(
            d, branchId: widget.branchId);
      }
      if (localResults.isEmpty) {
        localResults = LocalStorageService.searchPatientsByCnicOrGuardian(
            patientId, branchId: widget.branchId);
      }

      final normPid = patientId.replaceAll('-', '').trim().toLowerCase();
      final hasTarget = localResults.any((p) {
        final pid = (p['patientId'] ?? p['id'] ?? '').toString().replaceAll('-', '').trim().toLowerCase();
        return pid == normPid || pid == patientId.toLowerCase();
      });

      if (!hasTarget) {
        final direct = LocalStorageService.getLocalPatient(patientId) ??
            LocalStorageService.getLocalPatient(normPid) ??
            LocalStorageService.getLocalPatientByCnic(formatted) ??
            LocalStorageService.getLocalPatientByCnic(d);
        if (direct != null) {
          localResults.insert(0, direct);
        }
      }

      localResults = _deduplicateAndHealPatientList(localResults);
      if (mounted) {
        setState(() => _patientsList = localResults);
      }

      // Auto-open only when the CNIC has a single account; for a family the list is shown
      // and the receptionist selects the patient.
      if (localResults.length == 1) {
        await _selectPatient(localResults.first);
      }
    } catch (e) {
      debugPrint('[TokenScreen] focusAndSelectPatient error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Directly selects a newly registered patient (child or adult),
  /// populates the UI, and automatically opens the vitals/token dialog.
  Future<void> selectPatientDirectly(String patientIdOrCnic, {String? cnicFallback}) async {
    _searchDebounceTimer?.cancel();
    final searchInput = (cnicFallback != null && cnicFallback.isNotEmpty)
        ? cnicFallback
        : (patientIdOrCnic.contains('_child_') ? patientIdOrCnic.split('_child_').first : patientIdOrCnic);
    focusAndFillCnic(searchInput, autoSearch: false);
    _searchDebounceTimer?.cancel();

    await LocalStorageService.ensureBoxOpen(LocalStorageService.patientsBox);
    final box = Hive.box(LocalStorageService.patientsBox);
    dynamic match = box.get(patientIdOrCnic);
    if (match == null && patientIdOrCnic.contains('-')) {
      match = box.get(patientIdOrCnic.replaceAll('-', ''));
    }
    if (match == null && !patientIdOrCnic.contains('-') && patientIdOrCnic.length == 13) {
      final formatted = '${patientIdOrCnic.substring(0, 5)}-${patientIdOrCnic.substring(5, 12)}-${patientIdOrCnic.substring(12)}';
      match = box.get(formatted);
    }
    if (match == null) {
      for (final v in box.values) {
        if (v is Map) {
          final pid = (v['patientId'] ?? v['id'])?.toString();
          final pCnic = (v['cnic'] ?? v['patientCnic'])?.toString();
          if (pid == patientIdOrCnic || pCnic == patientIdOrCnic ||
              (pid != null && pid.replaceAll('-', '') == patientIdOrCnic.replaceAll('-', '')) ||
              (pCnic != null && pCnic.replaceAll('-', '') == patientIdOrCnic.replaceAll('-', ''))) {
            match = v;
            break;
          }
        }
      }
    }
    // A family (shared CNIC) with more than one account: list them and let the receptionist
    // pick — never auto-select one of them.
    final familyResults = LocalStorageService.searchPatientsByCnicOrGuardian(
        searchInput, branchId: widget.branchId);
    if (familyResults.length > 1) {
      if (mounted) {
        setState(() {
          _patientsList = familyResults.map(_healPatient).toList();
          _patientData = null;
          _errorMessage = null;
        });
      }
      _searchDebounceTimer?.cancel();
      return;
    }
    if (match == null && familyResults.length == 1) {
      match = familyResults.first;
    }

    if (match is Map && mounted) {
      final pMap = Map<String, dynamic>.from(match);
      setState(() {
        _patientsList = [pMap];
      });
      await _selectPatient(pMap);
    } else if (mounted) {
      _searchPatient();
    }
    _searchDebounceTimer?.cancel();
  }

  void focusAndFillCnic(String input, {bool autoSearch = true}) {
    _searchDebounceTimer?.cancel();
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
    if (autoSearch) {
      _searchDebounceTimer = Timer(const Duration(milliseconds: 300), () {
        if (mounted) triggerSearch();
      });
    }
  }

  void triggerSearch() {
    _searchDebounceTimer?.cancel();
    _searchPatient();
  }

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
  String _getPatientDisplayName(Map<String, dynamic> p) {
    final canonical = LocalStorageService.resolveCanonicalPatientName(p);
    if (canonical.isNotEmpty) {
      return canonical;
    }
    final cnicInfo = _getDisplayCnicInfo(p);
    if (cnicInfo.cnic.isNotEmpty && cnicInfo.cnic != '-') {
      return 'Patient (${cnicInfo.cnic})';
    }
    return 'Patient';
  }

  /// Resolves the guardian's display name for a child patient (used ONLY for a
  /// secondary "Guardian: …" subtitle/label — never as the child's own name).
  String? _resolveChildGuardianName(Map<String, dynamic> child) {
    if (!LocalStorageService.isChildPatientRecord(child)) return null;
    final raw = child['guardianName']?.toString().trim() ?? '';
    if (raw.isNotEmpty && raw != '0' && raw.toLowerCase() != 'null' && raw != '-') {
      return raw;
    }
    final gDigits = (child['guardianCnic'] ?? child['guardian_cnic'] ?? '')
        .toString()
        .replaceAll(RegExp(r'\D'), '');
    if (gDigits.isEmpty) return null;
    for (final other in _patientsList) {
      if (LocalStorageService.isChildPatientRecord(other)) continue;
      final oDigits = (other['cnic'] ?? other['patientCnic'] ?? '')
          .toString()
          .replaceAll(RegExp(r'\D'), '');
      if (oDigits == gDigits) {
        final adultName = LocalStorageService.resolveCanonicalPatientName(other);
        if (adultName.isNotEmpty) return adultName;
      }
    }
    return null;
  }

  String _getPatientDisplayPhone(Map<String, dynamic> p) {
    final ph = (p['phone'] ?? p['contactPhone'] ?? p['patientPhone'] ?? p['phoneNumber'] ?? p['mobile'] ?? p['guardianPhone'] ?? '')
        .toString().trim();
    return (ph.isNotEmpty && ph != '0' && ph.toLowerCase() != 'null') ? ph : '-';
  }

  /// Merges duplicate patient records (e.g. dashed and un-dashed stubs for same CNIC)
  /// and applies field healing across all records in the list while strictly isolating
  /// adults from children sharing the same guardian CNIC.
  List<Map<String, dynamic>> _deduplicateAndHealPatientList(List<Map<String, dynamic>> list) {
    if (list.isEmpty) return [];
    final grouped = <String, Map<String, dynamic>>{};
    for (final raw in list) {
      final healed = _healPatient(raw);
      final isChild = LocalStorageService.isChildPatientRecord(healed);
      final cleanCnic = (healed['cnic'] ?? healed['patientCnic'])?.toString().replaceAll(RegExp(r'\D'), '').trim() ?? '';
      final cleanGuard = (healed['guardianCnic'] ?? healed['guardian_cnic'])?.toString().replaceAll(RegExp(r'\D'), '').trim() ?? '';
      final pid = (healed['patientId'] ?? healed['id'] ?? '').toString().trim();

      String effectiveKey;
      if (pid.contains('_child_')) {
        final parts = pid.split('_child_');
        final g = parts[0].replaceAll(RegExp(r'\D'), '');
        final child = parts.sublist(1).join('_child_').replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase().trim();
        final gDash = g.length == 13 ? '${g.substring(0, 5)}-${g.substring(5, 12)}-${g.substring(12, 13)}' : g;
        effectiveKey = '${gDash}_child_$child';
      } else if (isChild) {
        final g = cleanGuard.isNotEmpty ? cleanGuard : cleanCnic;
        final gDash = g.length == 13 ? '${g.substring(0, 5)}-${g.substring(5, 12)}-${g.substring(12, 13)}' : g;
        final childName = LocalStorageService.resolveCanonicalPatientName(healed)
            .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')
            .toLowerCase();
        effectiveKey = '${gDash}_child_${childName.isNotEmpty ? childName : 'child'}';
      } else if (cleanCnic.length == 13) {
        effectiveKey = '${cleanCnic.substring(0, 5)}-${cleanCnic.substring(5, 12)}-${cleanCnic.substring(12, 13)}';
      } else {
        effectiveKey = pid;
      }

      if (!grouped.containsKey(effectiveKey)) {
        grouped[effectiveKey] = healed;
      } else {
        final merged = LocalStorageService.mergePatientMaps(grouped[effectiveKey]!, healed);
        grouped[effectiveKey] = merged;
        // Actively clean up duplicate keys from patientsBox so they don't linger
        if (Hive.isBoxOpen(LocalStorageService.patientsBox)) {
          final box = Hive.box(LocalStorageService.patientsBox);
          final rawId = (raw['patientId'] ?? raw['id'])?.toString();
          if (rawId != null && rawId.isNotEmpty && rawId != effectiveKey) {
            unawaited(box.delete(rawId));
          }
        }
      }
    }
    final result = grouped.values.toList();
    // Deterministic ordering: adult guardian first, then children alphabetically.
    result.sort((a, b) {
      final aChild = LocalStorageService.isChildPatientRecord(a);
      final bChild = LocalStorageService.isChildPatientRecord(b);
      if (aChild != bChild) return aChild ? 1 : -1;
      return _getPatientDisplayName(a).toLowerCase().compareTo(_getPatientDisplayName(b).toLowerCase());
    });
    return result;
  }

  /// Rebuilds a wiped patient record (blank name/CNIC/phone) from tokens and prescriptions,
  /// strictly isolating adults from children so family members sharing a CNIC never
  /// cross-contaminate each other's name, guardianCnic, or demographics.
  Map<String, dynamic> _healPatient(Map<String, dynamic> p) {
    bool blank(dynamic v) {
      final s = (v ?? '').toString().trim();
      final lower = s.toLowerCase();
      return s.isEmpty || s == '0' || lower == 'null' || s == '-' || lower == 'unknown' || lower == 'unknown patient';
    }
    String normAlnum(dynamic v) => (v ?? '').toString().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

    final healed = Map<String, dynamic>.from(p);
    bool changed = LocalStorageService.normalizePatientRecordIdentity(healed);

    final pid = (healed['patientId'] ?? healed['id'] ?? '').toString().trim();
    final isChild = LocalStorageService.isChildPatientRecord(healed);

    String normPidForMatch(String raw) {
      final s = raw.trim().toLowerCase();
      if (s.contains('_child_')) {
        final parts = s.split('_child_');
        final g = parts[0].replaceAll(RegExp(r'\D'), '');
        final c = parts.sublist(1).join('_child_').replaceAll(RegExp(r'[^a-z0-9]'), '');
        return '${g}_child_$c';
      }
      return s.replaceAll(RegExp(r'[-\s]'), '');
    }
    final normPid = normPidForMatch(pid);

    // 1. Resolve CNIC from own fields or patientId (strictly respecting adult vs child)
    String pCnic = isChild ? '' : (healed['cnic'] ?? healed['patientCnic'] ?? '').toString().trim();
    String pGuard = isChild ? (healed['guardianCnic'] ?? healed['guardian_cnic'] ?? '').toString().trim() : '';
    if (isChild && blank(pGuard) && pid.contains('_child_')) {
      final gDigits = pid.split('_child_').first.replaceAll(RegExp(r'\D'), '');
      if (gDigits.length == 13) {
        pGuard = _formatCnic(gDigits);
        healed['guardianCnic'] = pGuard;
        changed = true;
      }
    } else if (!isChild && blank(pCnic) && pid.isNotEmpty && !pid.contains('_child_') && RegExp(r'^[\d\-\s]+$').hasMatch(pid)) {
      final clean = pid.replaceAll(RegExp(r'\D'), '');
      if (clean.length == 13) {
        pCnic = _formatCnic(clean);
        healed['cnic'] = pCnic;
        changed = true;
      }
    }
    final normCnic = pCnic.replaceAll(RegExp(r'\D'), '');
    final normGuard = pGuard.replaceAll(RegExp(r'\D'), '');

    // 2. Resolve canonical name from patientId if child record has no valid name
    final existingCanonicalName = LocalStorageService.resolveCanonicalPatientName(healed);
    if (existingCanonicalName.isEmpty && pid.contains('_child_')) {
      final childPart = pid.split('_child_').sublist(1).join('_child_').replaceAll('_', ' ').trim();
      if (childPart.isNotEmpty) {
        healed['name'] = childPart;
        healed['patientName'] = childPart;
        changed = true;
      }
    }
    final currentNameNorm = normAlnum(LocalStorageService.resolveCanonicalPatientName(healed));

    // 3. Heal missing fields from entriesBox ONLY from entries belonging to THIS exact individual
    final needsName = blank(healed['name']) || blank(healed['patientName']);
    final needsPhone = blank(healed['phone']);
    final needsCnic = isChild ? blank(healed['guardianCnic']) : blank(healed['cnic']);
    if ((needsName || needsPhone || needsCnic) && Hive.isBoxOpen(LocalStorageService.entriesBox)) {
      try {
        final eBox = Hive.box(LocalStorageService.entriesBox);
        for (final raw in eBox.values) {
          if (raw is! Map) continue;
          final entryPid = (raw['patientId'] ?? raw['id'] ?? '').toString().trim();
          final entryNormPid = normPidForMatch(entryPid);
          final entryCnic = (raw['patientCnic'] ?? raw['cnic'] ?? '').toString().replaceAll(RegExp(r'\D'), '');
          final entryGuard = (raw['guardianCnic'] ?? '').toString().replaceAll(RegExp(r'\D'), '');
          final entryNameRaw = (raw['patientName'] ?? raw['name'] ?? raw['fullName'])?.toString().trim() ?? '';
          final entryNameNorm = normAlnum(entryNameRaw);

          // Strict adult/child isolation: NEVER heal an adult from a child's token or vice versa!
          final entryIsChild = raw['isAdult'] == false ||
              entryPid.contains('_child_') ||
              (raw['isAdult'] != true && entryGuard.isNotEmpty);
          if (isChild != entryIsChild) continue;

          final idMatches = normPid.isNotEmpty &&
              !normPid.startsWith('unknown') &&
              entryNormPid.isNotEmpty &&
              normPid == entryNormPid;

          bool individualCnicMatch = false;
          if (!idMatches) {
            if (isChild) {
              // Child match requires guardian CNIC match AND exact child name match
              final effEntryGuard = entryGuard.isNotEmpty ? entryGuard : entryCnic;
              if (normGuard.length == 13 &&
                  effEntryGuard == normGuard &&
                  currentNameNorm.isNotEmpty &&
                  entryNameNorm.isNotEmpty &&
                  currentNameNorm == entryNameNorm) {
                individualCnicMatch = true;
              }
            } else {
              // Adult match requires adult CNIC match AND (missing name OR same adult name)
              if (normCnic.length == 13 && entryCnic == normCnic) {
                if (currentNameNorm.isEmpty || entryNameNorm.isEmpty || currentNameNorm == entryNameNorm) {
                  individualCnicMatch = true;
                }
              }
            }
          }

          if (!idMatches && !individualCnicMatch) continue;

          // Only fill name if BOTH name and patientName are blank (never stamp another person's name)
          if (blank(healed['name']) && blank(healed['patientName']) && !blank(entryNameRaw)) {
            healed['name'] = entryNameRaw;
            healed['patientName'] = entryNameRaw;
            changed = true;
          }
          final ph = raw['phone'] ?? raw['contactPhone'] ?? raw['patientPhone'] ?? raw['phoneNumber'];
          if (blank(healed['phone']) && !blank(ph)) {
            healed['phone'] = ph.toString().trim();
            changed = true;
          }
          if (!isChild && blank(healed['cnic']) && entryCnic.length == 13) {
            healed['cnic'] = _formatCnic(entryCnic);
            changed = true;
          }
          if (isChild && blank(healed['guardianCnic'])) {
            final g = entryGuard.length == 13 ? entryGuard : (entryCnic.length == 13 ? entryCnic : '');
            if (g.length == 13) {
              healed['guardianCnic'] = _formatCnic(g);
              changed = true;
            }
          }
          for (final k in ['gender', 'age', 'dob', 'address', 'bloodGroup', 'status']) {
            if (blank(healed[k]) && !blank(raw[k])) {
              healed[k] = raw[k];
              changed = true;
            }
          }

          if (!blank(healed['name']) && !blank(healed['phone'])) break;
        }
      } catch (e) {
        debugPrint('[TokenScreen] heal from entriesBox failed: $e');
      }
    }

    // 4. Also check prescriptionsBox if still missing name (strictly matching patientId or adult CNIC)
    if (blank(healed['name']) && blank(healed['patientName']) && Hive.isBoxOpen(LocalStorageService.prescriptionsBox)) {
      try {
        final rxBox = Hive.box(LocalStorageService.prescriptionsBox);
        for (final raw in rxBox.values) {
          if (raw is! Map) continue;
          final rxPid = (raw['patientId'] ?? '').toString().trim();
          final rxNormPid = normPidForMatch(rxPid);
          final rxCnic = (raw['patientCnic'] ?? raw['cnic'] ?? '').toString().replaceAll(RegExp(r'\D'), '');
          final rxGuard = (raw['guardianCnic'] ?? '').toString().replaceAll(RegExp(r'\D'), '');
          final rxIsChild = raw['isAdult'] == false ||
              rxPid.contains('_child_') ||
              (raw['isAdult'] != true && rxGuard.isNotEmpty);
          if (isChild != rxIsChild) continue;

          final idMatches = normPid.isNotEmpty &&
              !normPid.startsWith('unknown') &&
              rxNormPid.isNotEmpty &&
              rxNormPid == normPid;
          final adultCnicMatches = !isChild && normCnic.length == 13 && rxCnic == normCnic;
          if (idMatches || adultCnicMatches) {
            final n = raw['patientName'] ?? raw['name'];
            if (!blank(n)) {
              healed['name'] = n.toString().trim();
              healed['patientName'] = n.toString().trim();
              changed = true;
              break;
            }
          }
        }
      } catch (_) {}
    }

    // 5. Persist healed patient ONLY when a field was actually repaired
    if (changed && !blank(healed['name'])) {
      unawaited(LocalStorageService.saveLocalPatient(healed, isFromSync: true));
    }
    return healed;
  }

  Future<void> _searchPatient() async {
    final input = cnicController.text.trim();
    if (input.isEmpty) return;
    final digitsOnly = input.replaceAll(RegExp(r'[^0-9]'), '');
    final hasLetters = RegExp(r'[a-zA-Z]').hasMatch(input);
    final isPhonePrefix = digitsOnly.startsWith('03') || digitsOnly.startsWith('923');
    final looksLikeCnic  = !hasLetters && !isPhonePrefix &&
        (RegExp(r'^\d{5}-\d{7}-\d{1}$').hasMatch(input) || digitsOnly.length == 13);
    final looksLikePhone = !hasLetters &&
        ((digitsOnly.startsWith('03') && digitsOnly.length == 11) ||
         (digitsOnly.startsWith('92') && digitsOnly.length == 12));
    final looksLikeName  = hasLetters && !input.contains('_child_') && input.length >= 3;
    final looksLikeId    = input.contains('_child_');

    if (!looksLikeCnic && !looksLikePhone && !looksLikeName && !looksLikeId) {
      AppToast.showSnackBar(context, const SnackBar(
        content: Text('Please enter complete 13-digit CNIC or 11-digit Phone (03XXXXXXXXX)'),
        backgroundColor: SoftPalette.amber300,
      ));
      return;
    }

    final formattedCnic = digitsOnly.length == 13
        ? '${digitsOnly.substring(0, 5)}-${digitsOnly.substring(5, 12)}-${digitsOnly.substring(12)}'
        : input;
    final unformattedCnic = digitsOnly.length == 13 ? digitsOnly : input;

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
      if (localResults.isEmpty && formattedCnic != input) {
        localResults = LocalStorageService.searchPatientsByCnicOrGuardian(
            formattedCnic, branchId: widget.branchId);
      }
      if (localResults.isEmpty && unformattedCnic != input) {
        localResults = LocalStorageService.searchPatientsByCnicOrGuardian(
            unformattedCnic, branchId: widget.branchId);
      }
      if (localResults.isEmpty && digitsOnly.isNotEmpty) {
        localResults = LocalStorageService.searchPatientsByCnicOrGuardian(
            digitsOnly, branchId: widget.branchId);
      }

      final bool hasValidLocalMatch = localResults.any((p) {
        final n = (p['name'] ?? p['patientName'] ?? p['fullName'] ?? '').toString().trim();
        return n.isNotEmpty && n != '0' && n.toLowerCase() != 'null';
      });

      if (localResults.isEmpty || !hasValidLocalMatch) {
        // Fast targeted lookup with Karachi family / sub-branch cross-search
        try {
          final branchCandidates = <String>{
            widget.branchId,
            if (CampSessionService.isKarachiFamily(widget.branchId))
              ...const ['karachi', 'karachi_saddar', 'saddar', 'karachi_haji']
          };

          final found = <Map<String, dynamic>>[];
          final seenIds = <String>{};

          for (final bId in branchCandidates) {
            final branchRef = FirebaseFirestore.instance
                .collection('branches')
                .doc(bId)
                .collection('patients');

            final queries = <Future<QuerySnapshot?>>[];
            if (looksLikeCnic) {
              queries.add(branchRef.where('cnic', isEqualTo: formattedCnic).limit(10).get().timeout(const Duration(seconds: 3)));
              if (formattedCnic != unformattedCnic) {
                queries.add(branchRef.where('cnic', isEqualTo: unformattedCnic).limit(10).get().timeout(const Duration(seconds: 3)));
              }
              queries.add(branchRef.where('guardianCnic', isEqualTo: formattedCnic).limit(20).get().timeout(const Duration(seconds: 3)));
              if (formattedCnic != unformattedCnic) {
                queries.add(branchRef.where('guardianCnic', isEqualTo: unformattedCnic).limit(20).get().timeout(const Duration(seconds: 3)));
              }
            }
            if (looksLikePhone) {
              queries.add(branchRef.where('phone', isEqualTo: digitsOnly).limit(5).get().timeout(const Duration(seconds: 3)));
              if (digitsOnly.startsWith('92') && digitsOnly.length == 12) {
                queries.add(branchRef.where('phone', isEqualTo: '0${digitsOnly.substring(2)}').limit(5).get().timeout(const Duration(seconds: 3)));
              } else if (digitsOnly.startsWith('03') && digitsOnly.length == 11) {
                queries.add(branchRef.where('phone', isEqualTo: digitsOnly.substring(1)).limit(5).get().timeout(const Duration(seconds: 3)));
              }
            }
            if (looksLikeName) {
              queries.add(branchRef.where('name', isGreaterThanOrEqualTo: input).where('name', isLessThanOrEqualTo: '$input\uf8ff').limit(10).get().timeout(const Duration(seconds: 3)));
            }

            final results = await Future.wait(queries, eagerError: false);
            for (final snapshot in results) {
              if (snapshot == null) continue;
              for (final doc in snapshot.docs) {
                if (!seenIds.add(doc.id)) continue;
                final data = Map<String, dynamic>.from(doc.data() as Map);
                data['patientId'] = doc.id;
                data['branchId'] = bId;
                found.add(data);
              }
            }
            if (found.isNotEmpty) break;
          }

          if (found.isNotEmpty) {
            await LocalStorageService.saveAllLocalPatients(found);
            localResults = LocalStorageService.searchPatientsByCnicOrGuardian(
                formattedCnic, branchId: widget.branchId);
            if (localResults.isEmpty) {
              localResults = LocalStorageService.searchPatientsByCnicOrGuardian(
                  input, branchId: widget.branchId);
            }
            if (localResults.isEmpty) {
              localResults = found;
            }
          }
        } catch (e) {
          debugPrint('[TokenScreen] Direct branch patient query failed: $e');
        }
      }
        localResults = _deduplicateAndHealPatientList(localResults);
      if (mounted) {
        setState(() => _patientsList = localResults);
      }
      if (localResults.isNotEmpty) {
        // Auto-open only a single match. With several family accounts the receptionist
        // selects the patient manually (no auto-pick of the last registered patient).
        if (localResults.length == 1) {
          await _selectPatient(localResults.first);
        } else {
          if (mounted) {
            setState(() {
              _patientData = null;
              _errorMessage = null;
            });
          }
        }
      } else {
        Map<String, dynamic>? directHiveMatch;
        final targetId = widget.targetPatientId?.trim();
        if (targetId != null && targetId.isNotEmpty && Hive.isBoxOpen(LocalStorageService.patientsBox)) {
          final box = Hive.box(LocalStorageService.patientsBox);
          dynamic raw = box.get(targetId);
          if (raw == null && targetId.contains('-')) {
            raw = box.get(targetId.replaceAll('-', ''));
          }
          if (raw is Map) {
            // Only fall back to the last registered patient if it IS what was searched.
            // Otherwise a search for an unknown CNIC opened that unrelated patient.
            final searched = digitsOnly;
            String digits(dynamic v) => (v ?? '').toString().replaceAll(RegExp(r'[^0-9]'), '');
            final pid = digits(raw['patientId'] ?? raw['id']);
            final matchesSearch = searched.isNotEmpty &&
                (digits(raw['cnic']) == searched ||
                    digits(raw['guardianCnic']) == searched ||
                    digits(raw['phone']) == searched ||
                    pid == searched ||
                    pid.startsWith(searched));
            if (matchesSearch) directHiveMatch = Map<String, dynamic>.from(raw);
          }
        }

        if (directHiveMatch != null) {
          if (mounted) {
            setState(() => _patientsList = [directHiveMatch!]);
          }
          await _selectPatient(directHiveMatch);
        } else if (looksLikeCnic && widget.onPatientNotFound != null && _patientData == null) {
          widget.onPatientNotFound!(formattedCnic);
        } else {
          if (mounted) {
            setState(() {
              _patientData = null;
              _errorMessage = 'No patient found with CNIC/phone: $formattedCnic';
            });
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
    final effectivePatient = _healPatient(patient);
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

    final hasBoth = _hasBothTokensToday(effectivePatient);
    final cannotIssueMore = _isVitalsTokenAllowed ? hasBoth : _hasRegularTokenToday(effectivePatient);
    if (mounted) {
      setState(() {
        _patientData   = effectivePatient;
        _hasTokenToday = cannotIssueMore;
        _errorMessage  = null;
        _isExceptionPending = false;
      });
      _checkMedicineRestriction(effectivePatient);
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
        AppToast.showSnackBar(context, SnackBar(
          content: Text('⚠️ A ${isVitalsOnly ? "Vitals Inspection" : "Regular"} token has already been issued for this patient today!'),
          backgroundColor: SoftPalette.amber300,
          duration: const Duration(seconds: 4),
        ));
        return;
      }
    }

    _issuedTokenKeysThisSession.add(idempotencyKey);

    if (mounted) setState(() => _isLoading = true);
    try {
      final rawName = LocalStorageService.resolveCanonicalPatientName(_patientData);
      final patientName = rawName.isNotEmpty ? rawName : 'Unknown Patient';

      if (!hasException && await _tokenExistsToday(patientId, isVitalsOnly: isVitalsOnly)) {
        AppToast.showSnackBar(context, SnackBar(
          content: Text('❌ This patient already has a ${isVitalsOnly ? "Vitals Inspection" : "Regular"} token today!'),
          backgroundColor: SoftPalette.red400,
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
            AppToast.showSnackBar(context, SnackBar(
              content: Text('❌ Patient blocked. Medicine expires in ${restriction['remainingDays']} days.'),
              backgroundColor: SoftPalette.red400,
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
      final activeCamp = _capturedDispensaryId ?? CampSessionService.getActiveCamp(widget.branchId);
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
        'fullName':      patientName,
        'isAdult':       !isChildPatient,
        'age':           _patientData!['age'] ?? 0,
        'patientAge':    _patientData!['age'] ?? 0,
        'gender':        _patientData!['gender'] ?? 'Unknown',
        'patientGender': _patientData!['gender'] ?? 'Unknown',
        'bloodGroup':    _patientData!['bloodGroup'] ?? 'N/A',
        if (_patientData!['dob'] != null) 'dob': _patientData!['dob'],
        if (_patientData!['dob'] != null || _patientData!['dateOfBirth'] != null)
          'dateOfBirth': _patientData!['dob'] ?? _patientData!['dateOfBirth'],
        if (_patientData!['phone']?.toString().trim().isNotEmpty == true)
          'phone': _patientData!['phone'].toString().trim(),
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
      final hasCamps = CampSessionService.hasCampsForBranch(widget.branchId);
      final effectiveCampId = (_capturedDispensaryId != null && _capturedDispensaryId!.isNotEmpty)
          ? _capturedDispensaryId!
          : (activeCamp ?? (hasCamps ? (normDispTag == 'HAJI' ? 'haji_camp' : 'saddar') : widget.branchId));
      final effectiveCampName = hasCamps
          ? CampSessionService.getCampLabel(effectiveCampId)
          : LocalStorageService.getBranchName(widget.branchId);

      final localSeq = await LocalStorageService.getNextLocalSerialSequence(
        widget.branchId,
        dateKey,
        dispensaryId: effectiveCampId,
        session: session,
      );
      final sessionLetter = CampSessionService.getSessionLetter(session);
      // Strictly single canonical numbering sequence (001 to 999) for both online and offline.
      final serverSeq = await RealtimeManager().reserveSerial('$dateKey$sessionLetter-$normDispTag', localSeq);
      final int nextSeq;
      if (serverSeq != null) {
        nextSeq = serverSeq;
        await LocalStorageService.getNextLocalSerialSequence(
          widget.branchId,
          dateKey,
          dispensaryId: effectiveCampId,
          session: session,
          increment: true,
          atLeast: nextSeq,
        );
      } else {
        // Offline: continue directly in the single shared 001..999 sequence
        nextSeq = await LocalStorageService.getNextLocalSerialSequence(
          widget.branchId,
          dateKey,
          dispensaryId: effectiveCampId,
          session: session,
          increment: true,
          atLeast: localSeq,
        );
      }
      final seqPadded = nextSeq.toString().padLeft(3, '0');
      final serial = '$dateKey$sessionLetter-$normDispTag-$seqPadded';
      final entryData = <String, dynamic>{
        ...baseData,
        'serial': serial,
        'dateKey': dateKey,
        'session': session,
        'sessionLetter': sessionLetter,
        'dispensaryTag': normDispTag,
        'dispensaryId': effectiveCampId,
        'campId': effectiveCampId,
        'campName': effectiveCampName,
        'dispensaryName': effectiveCampName,
        'pendingSync': true,
        // Fair queue order: online tokens are in server order by number; a token numbered
        // offline is placed among them by this (server-corrected) issue time.
        'issuedAtMs': CampSessionService.getAuthoritativeTime().millisecondsSinceEpoch,
        if (serverSeq == null) 'issuedOffline': true,
        if (hasException) ...{
          'isExceptionToken': true,
          'exceptionAuthorized': true,
        },
      };

      // STEP 1 — Hive (instant, offline-safe & case-normalized)
      // Only clear an orphaned prescription when this serial is free. If another token
      // already holds it (serial issued on another desk), that prescription is theirs;
      // saveEntryLocal's collision guard keeps both records.
      if (LocalStorageService.getLocalEntry(widget.branchId, serial) == null) {
        await LocalStorageService.deleteLocalPrescription(serial);
      }
      final storedAsSerial = await LocalStorageService.saveEntryLocal(widget.branchId, serial, entryData);

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

      // STEP 2 — LAN broadcast (unbreakable sequence order)
      String? tokenMessageId;
      try {
        if (nextSeq > 1) {
          final prefix = '$dateKey$sessionLetter-$normDispTag';
          final from = (nextSeq - 20) > 1 ? nextSeq - 20 : 1;
          for (int i = from; i < nextSeq; i++) {
            final priorSer = '$prefix-${i.toString().padLeft(3, '0')}';
            final priorLogical = 'save_entry|$priorSer';
            if (RealtimeManager().isRecordPendingOrUnacked(priorLogical)) {
              unawaited(RealtimeManager().flushOutboxNow());
              break;
            }
          }
        }

        tokenMessageId = RealtimeManager().sendMessageTracked({
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

      // The patient is told their number only once the server has saved the token and sent
      // it to the doctor/dispenser desks (normally a few ms on a wired LAN). Before, the number
      // was shown first and delivered afterwards, so a patient could sit down while the
      // doctor's screen did not have them yet. The token stays in the outbox and is re-sent
      // until the server confirms, so a timeout here never loses it.
      bool serverConfirmed = false;
      if (serverSeq != null) {
        serverConfirmed = await RealtimeManager()
            .waitForServerAck(tokenMessageId, timeout: const Duration(seconds: 5));
      }

      _estimateNextSerial();

      if (mounted) {
        final currentQuery = cnicController.text.trim();
        final refreshedPatients = currentQuery.isNotEmpty
            ? _deduplicateAndHealPatientList(
                LocalStorageService.searchPatientsByCnicOrGuardian(currentQuery, branchId: widget.branchId),
              )
            : <Map<String, dynamic>>[];
        setState(() {
          _hasTokenToday = true;
          _guardianCnic = null;
          _guardianPatient = null;
          _errorMessage = null;
          _isLoading = false;
          if (refreshedPatients.isNotEmpty) {
            _patientsList = refreshedPatients;
          }
          if (_patientData != null) {
            final selPid = LocalStorageService.resolveIndividualPatientId(_patientData);
            _patientData = _patientsList.firstWhere(
              (p) => LocalStorageService.resolveIndividualPatientId(p) == selPid ||
                     p['patientId'] == _patientData!['patientId'] ||
                     (p['id'] != null && p['id'] == _patientData!['id']),
              orElse: () => _patientData!,
            );
          }
        });

        if (serverSeq == null) {
          AppToast.showSnackBar(context, SnackBar(
            content: Text('📴 OFFLINE: Token $serial issued to $patientName on this desk only. '
                'It will be sent to the doctor/dispenser screens as soon as the server is reachable.'),
            backgroundColor: SoftPalette.orange400,
            duration: const Duration(seconds: 6),
          ));
        } else if (!serverConfirmed) {
          AppToast.showSnackBar(context, SnackBar(
            content: Text('⚠️ Token $serial issued to $patientName, but the server has not confirmed it yet. '
                'It is being re-sent automatically — check the doctor screen shows it.'),
            backgroundColor: SoftPalette.orange400,
            duration: const Duration(seconds: 6),
          ));
        } else {
          AppToast.showSnackBar(context, SnackBar(
            content: Text(
                '✅ Token $serial issued to $patientName! [${BranchLabels.text(queueType, widget.branchId)}]'),
            backgroundColor: SoftPalette.green400,
            duration: const Duration(seconds: 3),
          ));
        }
      }

      // STEP 3 — Firestore in background (never for a collided serial: it would merge
      // this patient into the other patient's cloud record)
      if (storedAsSerial) {
        _syncToFirestoreInBackground(dateKey, queueType, serial, entryData);
      } else if (mounted) {
        AppToast.hideCurrent();
        AppToast.showSnackBar(context, SnackBar(
          content: Text('⚠️ Token $serial was already used by another patient (issued on another desk). '
              'Both records were kept and flagged for supervisor review.'),
          backgroundColor: SoftPalette.orange400,
          duration: const Duration(seconds: 6),
        ));
      }
    } catch (e, stack) {
      debugPrint('[TokenScreen] Token generation failed: $e\n$stack');
      AppToast.showSnackBar(context, SnackBar(
          content: Text('Failed to issue token: $e'),
          backgroundColor: SoftPalette.red400));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ── Firestore sync — writes via CloudDb REST or enqueues for SyncService ───
  Future<void> _syncToFirestoreInBackground(
    String dateKey,
    String queueType,
    String serial,
    Map<String, dynamic> entryData,
  ) async {
    // [DEDUP] If connected to LAN server, the token already traveled via
    // WebSocket → Server SSM → Firestore. Skip direct write to avoid
    // double/triple quota consumption.
    final lanConnected = RealtimeManager().isConnected;
    if (lanConnected) {
      debugPrint('[TokenScreen] LAN connected — server will sync $serial to Firestore');
      return;
    }

    bool written = false;
    try {
      final online = NetworkHealthService().isStableOnline;
      if (online && !QuotaService.isPausedForDailyReset) {
        final campDocKey = CampSessionService.getCampDateDocId(
          branchId: widget.branchId,
          dateKey: dateKey,
          campId: entryData['campId']?.toString() ?? entryData['dispensaryId']?.toString(),
          dispensaryTag: entryData['dispensaryTag']?.toString(),
          serial: serial,
        );
        final dayRef = CloudDb.instance
            .collection('branches')
            .doc(widget.branchId.toLowerCase().trim())
            .collection('serials')
            .doc(campDocKey);
        await dayRef
            .collection(queueType)
            .doc(serial)
            .set(LocalStorageService.sanitizeForCloudUpload(entryData), SetOptions(merge: true))
            .timeout(const Duration(seconds: 8));
        await dayRef.set(
          {'lastSerialNumber': int.tryParse(serial.split('-').last) ?? 0},
          SetOptions(merge: true),
        );
        debugPrint(
            '[TokenScreen] ✅ Firestore confirmed: serials/$campDocKey/$queueType/$serial');
        written = true;

        // Update local entry ONLY after confirmed CloudDb write
        try {
          if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
            final eBox = Hive.box(LocalStorageService.entriesBox);
            final normBranch = widget.branchId.toLowerCase().trim();
            final canonicalKey = '$normBranch-${serial.toUpperCase()}';
            final existing = eBox.get(canonicalKey) ?? eBox.get(serial);
            if (existing is Map) {
              final upd = Map<String, dynamic>.from(existing);
              upd['pendingSync'] = false;
              upd['synced'] = true;
              upd['syncStatus'] = 'synced';
              await eBox.put(canonicalKey, upd);
            }
          }
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[TokenScreen] CloudDb direct write refused/failed: $e');
    }

    if (!written) {
      if (RealtimeManager().isConnected) {
        debugPrint('[TokenScreen] LAN connected — skipping cloud enqueue for $serial');
        return;
      }
      try {
        await LocalStorageService.enqueueSync({
          'type':      'save_entry',
          'branchId':  widget.branchId.toLowerCase().trim(),
          'dateKey':   dateKey,
          'queueType': queueType,
          'serial':    serial,
          'data':      entryData,
        });
        debugPrint('[TokenScreen] 📥 Queued for sync: $queueType/$serial');
        SyncService().triggerUpload(urgent: true);
      } catch (e) {
        debugPrint('[TokenScreen] Enqueue failed: $e');
      }
    }
  }

  // ── Request patient details edit on token screen (requires approval) ───────
  Future<void> _requestEditPatient() async {
    if (_patientData == null) return;

    try {
      bool isChild = LocalStorageService.isChildPatientRecord(_patientData!);
      final cnicCtrl = TextEditingController(
          text: isChild
              ? (_patientData!['guardianCnic']?.toString() ?? '')
              : (_patientData!['cnic']?.toString() ?? ''));
      final nameCtrl = TextEditingController(
          text: LocalStorageService.resolveCanonicalPatientName(_patientData));
      final phoneCtrl = TextEditingController(
          text: _patientData!['phone']?.toString() ?? '');
      final dobCtrl = TextEditingController();
      final reasonCtrl = TextEditingController();
      const validBloodGroups = ['N/A', 'A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'];
      final rawBgInit = (_patientData!['bloodGroup']?.toString() ?? 'N/A').trim().toUpperCase();
      String selectedBloodGroup = validBloodGroups.contains(rawBgInit) ? rawBgInit : 'N/A';
      String selectedStatus = _patientData!['status']?.toString() ?? 'Zakat';
      if (_isKarachi && selectedStatus.toLowerCase().contains('non')) {
        selectedStatus = 'Zakat';
      }
      String selectedGender = _patientData!['gender']?.toString() ?? 'Male';

      final dobValue = _patientData!['dob'] ?? _patientData!['dateOfBirth'];
      if (dobValue != null) {
        final birthDate = LocalStorageService.tryParseDob(dobValue);
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
            backgroundColor: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24)),
            insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: Container(
              width: 520,
              constraints: const BoxConstraints(maxHeight: 740),
              decoration: BoxDecoration(
                color: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
                borderRadius: BorderRadius.circular(24),
                border: isDark ? Border.all(color: SoftPalette.slate700) : null,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Header
                  Container(
                    padding: const EdgeInsets.fromLTRB(20, 18, 16, 18),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          context.comfort.brand,
                          context.comfort.brandStrong,
                        ],
                      ),
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.edit_note_rounded, color: SoftPalette.gray50, size: 26),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text('Request Patient Details Edit',
                              style: TextStyle(
                                  color: SoftPalette.gray50,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800)),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(ctx),
                          icon: const Icon(Icons.close_rounded, color: SoftPalette.gray50A70, size: 22),
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
                          _editField(
                            phoneCtrl,
                            'Phone Number (optional)',
                            Icons.phone,
                            keyboardType: TextInputType.phone,
                            formatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(11),
                            ],
                            maxLen: 11,
                          ),
                          const SizedBox(height: 14),
                          _editField(
                            dobCtrl,
                            'Date of Birth (dd-MM-yyyy)',
                            Icons.cake,
                            keyboardType: TextInputType.datetime,
                            formatters: [
                              FilteringTextInputFormatter.allow(RegExp(r'[0-9-]')),
                              LengthLimitingTextInputFormatter(10),
                              DobInputFormatter(),
                            ],
                            maxLen: 10,
                            suffixIcon: IconButton(
                              tooltip: 'Pick Date of Birth from Calendar',
                              icon: Icon(
                                Icons.calendar_month_rounded,
                                color: context.comfort.brand,
                                size: 20,
                              ),
                              onPressed: () async {
                                final now = DateTime.now();
                                final currentDob = LocalStorageService.tryParseDob(dobCtrl.text.trim()) ??
                                    (isChild
                                        ? now.subtract(const Duration(days: 365 * 5))
                                        : now.subtract(const Duration(days: 365 * 25)));
                                final picked = await showDatePicker(
                                  context: ctx,
                                  initialDate: currentDob.isAfter(now)
                                      ? now
                                      : (currentDob.year < 1900 ? DateTime(1900) : currentDob),
                                  firstDate: DateTime(1900),
                                  lastDate: now,
                                );
                                if (picked != null) {
                                  setStateDialog(() {
                                    dobCtrl.text =
                                        '${picked.day.toString().padLeft(2, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.year}';
                                  });
                                }
                              },
                            ),
                          ),
                          const SizedBox(height: 14),
                          _editDropdown(
                            label: 'Blood Group',
                            icon: Icons.bloodtype_outlined,
                            value: selectedBloodGroup,
                            items: validBloodGroups,
                            onChanged: (v) {
                              if (v != null) setStateDialog(() => selectedBloodGroup = v);
                            },
                          ),
                          const SizedBox(height: 14),
                          _editField(
                            reasonCtrl,
                            'Reason for Edit Request (Required)',
                            Icons.notes_rounded,
                          ),
                          const SizedBox(height: 18),

                          _radioGroup(
                            'Status',
                            _isKarachi
                                ? [BranchLabels.karachiZakatLabel, 'GMWF']
                                : ['Zakat', 'Non-Zakat', 'GMWF'],
                            (_isKarachi && (selectedStatus == 'Zakat' || selectedStatus == '20')) ? BranchLabels.karachiZakatLabel : selectedStatus,
                            (v) => setStateDialog(() => selectedStatus = (v == BranchLabels.karachiZakatLabel) ? 'Zakat' : v),
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
                  Divider(height: 1, thickness: 1, color: isDark ? SoftPalette.slate700 : SoftPalette.gray100),
                  Container(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                    decoration: BoxDecoration(
                      color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(24)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: Text('Cancel',
                                style: TextStyle(
                                    color: isDark ? SoftPalette.slate350 : SoftPalette.gray550,
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

                              final trimmedName = nameCtrl.text.trim();
                              if (trimmedName.isEmpty) {
                                AppToast.showSnackBar(
                                  context,
                                  const SnackBar(
                                    content: Text('Please enter the patient name.'),
                                    backgroundColor: SoftPalette.orange400,
                                  ),
                                );
                                return;
                              }

                              final reasonText = reasonCtrl.text.trim();
                              if (reasonText.isEmpty) {
                                AppToast.showSnackBar(
                                  context,
                                  const SnackBar(
                                    content: Text('Please enter a reason for the edit request.'),
                                    backgroundColor: SoftPalette.orange400,
                                  ),
                                );
                                return;
                              }

                              final newCnic = cnicCtrl.text.trim();
                              // Rule: 1 adult per CNIC — prevent changing an adult's CNIC onto
                              // a CNIC that already belongs to another registered adult.
                              if (!isChild) {
                                final newDigits = newCnic.replaceAll(RegExp(r'\D'), '');
                                final oldDigits = (_patientData!['cnic'] ?? _patientData!['patientCnic'] ?? pId)
                                    .toString()
                                    .replaceAll(RegExp(r'\D'), '');
                                if (newDigits.length == 13 && newDigits != oldDigits) {
                                  final conflictingAdult = LocalStorageService.getLocalAdultByCnic(newCnic);
                                  if (conflictingAdult != null) {
                                    final conflictPid = (conflictingAdult['patientId'] ?? conflictingAdult['id'] ?? '')
                                        .toString()
                                        .replaceAll('-', '')
                                        .toLowerCase();
                                    if (conflictPid != pId.replaceAll('-', '').toLowerCase()) {
                                      final conflictName = LocalStorageService.resolveCanonicalPatientName(conflictingAdult);
                                      AppToast.showSnackBar(
                                        context,
                                        SnackBar(
                                          content: Text(
                                            'Only 1 adult is allowed per CNIC. This CNIC already belongs to '
                                            '${conflictName.isNotEmpty ? conflictName : 'another adult'}.',
                                          ),
                                          backgroundColor: SoftPalette.orange400,
                                          duration: const Duration(seconds: 4),
                                        ),
                                      );
                                      return;
                                    }
                                  }
                                }
                              }

                              final rawDobInput = dobCtrl.text.trim();
                              DateTime? parsedDob;
                              if (rawDobInput.isNotEmpty) {
                                parsedDob = LocalStorageService.tryParseDob(rawDobInput) ??
                                    parseDobDateTime(rawDobInput);
                                if (parsedDob == null) {
                                  AppToast.showSnackBar(
                                    context,
                                    const SnackBar(
                                      content: Text('Invalid Date of Birth. Please use dd-MM-yyyy (e.g. 15-08-1990).'),
                                      backgroundColor: SoftPalette.orange400,
                                    ),
                                  );
                                  return;
                                }
                              }

                              final updatedStatus = (_isKarachi && selectedStatus.toLowerCase().contains('non'))
                                  ? 'Zakat'
                                  : selectedStatus;
                              final isoDob = parsedDob?.toIso8601String();
                              final calcAge = isoDob != null
                                  ? LocalStorageService.calculateAgeFromDob(isoDob)
                                  : (_patientData!['age'] is num
                                      ? (_patientData!['age'] as num).toInt()
                                      : int.tryParse(_patientData!['age']?.toString() ?? ''));

                              final proposedData = <String, dynamic>{
                                'name': trimmedName,
                                'patientName': trimmedName,
                                'fullName': trimmedName,
                                'isAdult': !isChild,
                                if (isChild) 'guardianCnic': newCnic,
                                if (!isChild) 'cnic': newCnic,
                                if (!isChild) 'patientCnic': newCnic,
                                'phone': phoneCtrl.text.trim().isNotEmpty
                                    ? phoneCtrl.text.trim()
                                    : null,
                                'status': updatedStatus,
                                'gender': selectedGender,
                                'patientGender': selectedGender,
                                'bloodGroup': selectedBloodGroup.isNotEmpty
                                    ? selectedBloodGroup
                                    : 'N/A',
                                if (isoDob != null) 'dob': isoDob,
                                if (isoDob != null) 'dateOfBirth': isoDob,
                                if (calcAge != null && calcAge >= 0) 'age': calcAge,
                                if (calcAge != null && calcAge >= 0) 'patientAge': calcAge,
                                'branchId': widget.branchId,
                                'reason': reasonText,
                              };

                              final reqId = 'req_patient_edit_${widget.receptionistId}_${DateTime.now().millisecondsSinceEpoch}';
                              final currentDisplayName = LocalStorageService.resolveCanonicalPatientName(_patientData);
                              final reqPayload = <String, dynamic>{
                                'id': reqId,
                                'requestId': reqId,
                                'type': 'patient_edit',
                                'requestType': 'patient_edit',
                                'collection': 'edit_requests',
                                'status': 'pending',
                                'branchId': widget.branchId,
                                if (_capturedDispensaryId != null && _capturedDispensaryId!.isNotEmpty)
                                  'dispensaryId': _capturedDispensaryId,
                                if (_capturedDispensaryId != null && _capturedDispensaryId!.isNotEmpty)
                                  'campId': _capturedDispensaryId,
                                'patientId': pId,
                                'patientName': currentDisplayName.isNotEmpty ? currentDisplayName : trimmedName,
                                'cnic': _patientData!['cnic'],
                                'guardianCnic': _patientData!['guardianCnic'],
                                'originalData': LocalStorageService.sanitize(Map<String, dynamic>.from(_patientData!)),
                                'proposedData': LocalStorageService.sanitize(proposedData),
                                'reason': reasonText,
                                'requestedBy': widget.receptionistId,
                                'requestedByName': widget.receptionistName,
                                'requesterName': widget.receptionistName,
                                'requestedAt': DateTime.now().toIso8601String(),
                                'targetRole': 'supervisor',
                              };

                              // 1. Save locally to local_edit_requests so it shows up immediately in Requests
                              await LocalStorageService.saveLocalEditRequest(reqPayload);

                              // 2. Cloud upload & durable sync queue (when not on a LAN client desk)
                              final uploadsHere = !LanFirestoreGate.isLanDesk;
                              if (uploadsHere) {
                                unawaited(CloudDb.instance
                                    .collection('branches')
                                    .doc(widget.branchId)
                                    .collection('edit_requests')
                                    .doc(reqId)
                                    .set({
                                  ...reqPayload,
                                  'requestedAt': FieldValue.serverTimestamp(),
                                }, SetOptions(merge: true)).then<void>((_) {}, onError: (Object e) {
                                  debugPrint('[TokenScreen] Firestore offline — queued patient_edit: $reqId ($e)');
                                }));

                                await LocalStorageService.enqueueSync({
                                  'type': 'save_edit_request',
                                  'branchId': widget.branchId,
                                  'requestId': reqId,
                                  'collection': 'edit_requests',
                                  'data': reqPayload,
                                });
                                unawaited(SyncService().triggerUpload(urgent: true).catchError((_) {}));
                              }

                              // 3. Broadcast over LAN to Server, Supervisor, and Doctor screens
                              try {
                                RealtimeManager().sendMessage({
                                  ...RealtimeEvents.payload(
                                    type: RealtimeEvents.requestCreated,
                                    branchId: widget.branchId,
                                    data: reqPayload,
                                  ),
                                });
                              } catch (_) {}

                              // 4. Push notification to Supervisor
                              try {
                                CloudMessagingService().notifySupervisorPendingRequests(
                                  branchId: widget.branchId,
                                  requestType: 'Patient Edit',
                                  requesterName: widget.receptionistName,
                                  details: 'Patient edit requested for ${reqPayload['patientName']} ($reasonText)',
                                );
                              } catch (_) {}

                              if (ctx.mounted) Navigator.pop(ctx);

                              if (mounted) {
                                AppToast.showSnackBar(
                                  context,
                                  const SnackBar(
                                    content: Text('✅ Patient edit request sent for approval!'),
                                    backgroundColor: SoftPalette.blue400,
                                    duration: Duration(seconds: 3),
                                  ),
                                );
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: SoftPalette.green500,
                              foregroundColor: SoftPalette.gray50,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                              elevation: 2,
                            ),
                            child: const Text('Send Edit Request',
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
          color: isDark ? SoftPalette.teal200 : SoftPalette.green550,
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
                        color: isDark ? SoftPalette.slate150 : SoftPalette.gray900A87,
                      )),
                      value: o,
                      groupValue: current,
                      activeColor: isDark ? SoftPalette.teal300 : SoftPalette.green500,
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

      // Pass the patient so the same lookup as the block itself runs, and use the id of the
      // record that actually blocks: approving the exception clears that record.
      final blocking = LocalStorageService.isPatientBlockedByMedicine(widget.branchId, rId, _patientData);
      final blockingId = blocking?['patientId']?.toString() ?? '';
      final matchedId = blocking == null ? pId : (blockingId.isNotEmpty ? blockingId : rId);

      final patientName = LocalStorageService.resolveCanonicalPatientName(_patientData).isNotEmpty
          ? LocalStorageService.resolveCanonicalPatientName(_patientData)
          : 'Unknown';

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

      // Local copy and the LAN message come first: the cloud write used to be awaited before
      // them (up to 15–30 s without internet), so the doctor got the request late. A desk
      // linked to the LAN does not upload at all — the server uploads it once.
      final uploadsHere = !LanFirestoreGate.isLanDesk;
      if (uploadsHere) {
        unawaited(CloudDb.instance
            .collection('branches')
            .doc(widget.branchId)
            .collection('edit_requests')
            .doc(docId)
            .set({
          ...requestData,
          'requestedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true)).then<void>((_) {}, onError: (Object e) {
          debugPrint('[TokenScreen] Firestore offline — queued: $docId ($e)');
        }));
      }

      await LocalStorageService.saveLocalEditRequest({
        ...requestData,
        'id': docId,
        'requestId': docId,
        'branchId': widget.branchId,
        'status': 'pending',
        'requestedAt': DateTime.now().toIso8601String(),
      });

      if (uploadsHere) await LocalStorageService.enqueueSync({
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
        AppToast.showSnackBar(context, const SnackBar(
          content: Text('✅ Exception request sent to Doctor!'),
          backgroundColor: SoftPalette.blue400,
        ));
      }
    } catch (e) {
      if (mounted) {
        AppToast.showSnackBar(context, SnackBar(
          content: Text('❌ Failed to send request: $e'),
          backgroundColor: SoftPalette.red400,
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
    TextInputType? keyboardType,
    Widget? suffixIcon,
  }) {
    final isDark = _isDark;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: ctrl,
        readOnly: readOnly,
        keyboardType: keyboardType,
        inputFormatters: formatters,
        maxLength: maxLen,
        buildCounter: maxLen != null ? (_, {required currentLength, required isFocused, maxLength}) => null : null,
        style: TextStyle(
          fontSize: 14,
          color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87,
          fontWeight: FontWeight.w500,
        ),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(
            color: context.comfort.brand,
            fontWeight: FontWeight.w500,
            fontSize: 12,
          ),
          isDense: true,
          prefixIcon: Icon(icon, color: context.comfort.brand, size: 20),
          suffixIcon: suffixIcon,
          filled: true,
          fillColor: isDark
              ? (readOnly ? SoftPalette.slate900.withValues(alpha: 0.6) : SoftPalette.slate900)
              : (readOnly ? SoftPalette.gray100 : SoftPalette.gray50),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: isDark ? SoftPalette.slate700 : SoftPalette.gray150)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: isDark ? SoftPalette.slate700 : SoftPalette.gray150)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: context.comfort.brand, width: 2)),
          contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        ),
      ),
    );
  }

  Widget _editDropdown({
    required String label,
    required IconData icon,
    required String value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
  }) {
    final isDark = _isDark;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: DropdownButtonFormField<String>(
        initialValue: items.contains(value) ? value : items.first,
        isExpanded: true,
        dropdownColor: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
        icon: Icon(Icons.keyboard_arrow_down_rounded, color: context.comfort.brand),
        style: TextStyle(
          fontSize: 14,
          color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87,
          fontWeight: FontWeight.w500,
        ),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(
            color: context.comfort.brand,
            fontWeight: FontWeight.w500,
            fontSize: 12,
          ),
          isDense: true,
          prefixIcon: Icon(icon, color: context.comfort.brand, size: 20),
          filled: true,
          fillColor: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: isDark ? SoftPalette.slate700 : SoftPalette.gray150)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: isDark ? SoftPalette.slate700 : SoftPalette.gray150)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: context.comfort.brand, width: 2)),
          contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        ),
        items: items
            .map((e) => DropdownMenuItem<String>(
                  value: e,
                  child: Text(
                    e,
                    style: TextStyle(
                      fontSize: 14,
                      color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87,
                    ),
                  ),
                ))
            .toList(),
        onChanged: onChanged,
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
    final isMobile       = GBreakpoint.isMobile(context);
    final containerWidth = isMobile ? double.infinity : 560.0;
    final isDark = _isDark;
    final c = context.comfort;

    return Container(
      color: Colors.transparent,
      child: Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(
              horizontal: isMobile ? 8 : 12,
              vertical:   8),
          child: Container(
            width: containerWidth,
            padding: EdgeInsets.symmetric(horizontal: isMobile ? 4 : 8, vertical: 8),
            child: Stack(children: [
              Column(mainAxisSize: MainAxisSize.min, children: [
                // Status Pill + Hero Serial + Flanking-Line Logo Header
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                  decoration: BoxDecoration(
                    color: c.brandSoft,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    'Next Token • Ready',
                    style: TextStyle(
                      color: c.brand,
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _nextSerial ?? 'Loading...',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: isMobile ? 22 : 26,
                    fontWeight: FontWeight.w900,
                    color: c.textPrimary,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        height: 1.5,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              c.brand.withValues(alpha: 0.04),
                              c.brand.withValues(alpha: isDark ? 0.65 : 0.45),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Transform.rotate(
                      angle: 0.785398,
                      child: Container(
                        width: 5.5,
                        height: 5.5,
                        color: c.brand.withValues(alpha: isDark ? 0.75 : 0.55),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Image.asset(
                        'assets/logo/gmwf-1.webp',
                        height: isMobile ? 76 : (widget.isCompactHybrid ? 108 : 140),
                      ),
                    ),
                    Transform.rotate(
                      angle: 0.785398,
                      child: Container(
                        width: 5.5,
                        height: 5.5,
                        color: c.brand.withValues(alpha: isDark ? 0.75 : 0.55),
                      ),
                    ),
                    Expanded(
                      child: Container(
                        height: 1.5,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              c.brand.withValues(alpha: isDark ? 0.65 : 0.45),
                              c.brand.withValues(alpha: 0.04),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Issue Token',
                  style: TextStyle(
                    fontSize: isMobile ? 16 : 18,
                    fontWeight: FontWeight.w800,
                    color: c.textPrimary,
                  ),
                ),
                SizedBox(height: isMobile ? 12 : 16),

                // CNIC field
                TextField(
                  controller:   cnicController,
                  focusNode:    _cnicFocusNode,
                  maxLength:    15,
                  keyboardType: TextInputType.number,
                  cursorColor:  c.brand,
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

                    _searchDebounceTimer?.cancel();
                    if (d.isEmpty) {
                      if (_patientData != null || _patientsList.isNotEmpty || _errorMessage != null) {
                        setState(() {
                          _patientData = null;
                          _patientsList.clear();
                          _errorMessage = null;
                          _hasTokenToday = false;
                        });
                      }
                      return;
                    }

                    final hasLetters = RegExp(r'[a-zA-Z]').hasMatch(v);
                    final isPhonePrefix = d.startsWith('03') || d.startsWith('923');
                    final isFullCnic = !hasLetters && !isPhonePrefix && d.length == 13;
                    final isFullPhone = !hasLetters &&
                        ((d.startsWith('03') && d.length == 11) ||
                         (d.startsWith('92') && d.length == 12));
                    final isNameSearch = hasLetters && !v.contains('_child_') && v.trim().length >= 3;
                    final isIdSearch = v.contains('_child_');

                    if (isFullCnic || isFullPhone || isNameSearch || isIdSearch) {
                      _searchDebounceTimer = Timer(const Duration(milliseconds: 300), () {
                        if (mounted) _searchPatient();
                      });
                    } else {
                      if (_patientData != null || _patientsList.isNotEmpty || _errorMessage != null) {
                        setState(() {
                          _patientData = null;
                          _patientsList.clear();
                          _errorMessage = null;
                          _hasTokenToday = false;
                        });
                      }
                    }
                  },
                  onSubmitted: (_) => triggerSearch(),
                  style: TextStyle(color: c.textPrimary),
                  decoration: InputDecoration(
                    hintText:    'Guardian CNIC or Phone',
                    hintStyle:   TextStyle(color: c.textMuted, fontSize: 13.5),
                    counterText: '',
                    prefixIcon:  Icon(Icons.search_rounded, color: c.textSecondary, size: 20),
                    suffixIcon:  cnicController.text.isNotEmpty
                        ? IconButton(
                            icon: Icon(Icons.arrow_forward_rounded, color: c.brand, size: 20),
                            tooltip: 'Search',
                            onPressed: triggerSearch,
                          )
                        : null,
                    filled: true,
                    fillColor: c.surface,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide(color: c.borderStrong)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide(color: c.brand, width: 1.8)),
                  ),
                ),
                const SizedBox(height: 12),

                if (_patientData == null && _patientsList.isEmpty)
                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: ElevatedButton(
                      onPressed: () {
                        if (cnicController.text.trim().isNotEmpty) {
                          triggerSearch();
                        } else if (widget.onPatientNotFound != null) {
                          widget.onPatientNotFound!('');
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: c.brand,
                        foregroundColor: c.onBrand,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.medical_services_outlined, size: 18),
                          SizedBox(width: 8),
                          Text(
                            'Register Patient / Issue Token',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                          ),
                          SizedBox(width: 8),
                          Icon(Icons.arrow_forward_rounded, size: 17),
                        ],
                      ),
                    ),
                  ),

                if (_errorMessage != null)
                  Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                        color: isDark ? SoftPalette.red800 : SoftPalette.pink100m,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: isDark ? SoftPalette.red550 : SoftPalette.red300)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          const Icon(Icons.error_outline,
                              color: SoftPalette.red400, size: 18),
                          const SizedBox(width: 8),
                          Expanded(child: Text(_errorMessage!,
                              style: TextStyle(
                                  color: isDark ? SoftPalette.red300 : SoftPalette.red550,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600))),
                        ]),
                        if (widget.onPatientNotFound != null && cnicController.text.trim().isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Align(
                            alignment: Alignment.centerRight,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: c.brand,
                                foregroundColor: c.onBrand,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                              icon: const Icon(Icons.person_add, size: 16),
                              label: const Text('Register Patient Now', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                              onPressed: () {
                                final d = cnicController.text.replaceAll(RegExp(r'[^0-9]'), '');
                                final formatted = d.length == 13 ? _formatCnic(d) : cnicController.text.trim();
                                widget.onPatientNotFound!(formatted);
                              },
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                if (_patientData == null && _patientsList.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ..._patientsList.map((p) {
                    final cnicInfo = _getDisplayCnicInfo(p);
                    final isChildRec = LocalStorageService.isChildPatientRecord(p);
                    final guardianName = isChildRec ? _resolveChildGuardianName(p) : null;
                    final rawAge = p['age'];
                    final ageVal = rawAge is num ? rawAge.toInt() : int.tryParse(rawAge?.toString() ?? '');
                    final genderVal = p['gender']?.toString().trim() ?? '';
                    final hasDemo = (ageVal != null && ageVal > 0) ||
                        (genderVal.isNotEmpty && genderVal.toLowerCase() != 'unknown' && genderVal.toLowerCase() != 'null');
                    final vitalsToken = _getPatientTodayToken(p, isVitalsOnly: true);
                    final regularToken = _getPatientTodayToken(p, isVitalsOnly: false);
                    final rId = _getRestrictionId(p);
                    final restriction = LocalStorageService.isPatientBlockedByMedicine(widget.branchId, rId, p);

                    final hasBoth = _isVitalsTokenAllowed ? (vitalsToken != null && regularToken != null) : (regularToken != null);
                    final hasAny = _isVitalsTokenAllowed ? (vitalsToken != null || regularToken != null) : (regularToken != null);
                    final isRestricted = restriction != null;

                    Color cardBg;
                    Color cardBorder;
                    if (hasBoth) {
                      cardBg = c.dangerBg;
                      cardBorder = c.danger.withValues(alpha: 0.35);
                    } else if (isRestricted && regularToken == null) {
                      cardBg = c.warningBg;
                      cardBorder = c.warning.withValues(alpha: 0.35);
                    } else {
                      cardBg = c.surfaceSunken;
                      cardBorder = c.border;
                    }

                    return Card(
                      elevation: 0,
                      color: cardBg,
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: BorderSide(color: cardBorder, width: hasBoth || isRestricted ? 1.4 : 1)),
                      child: ListTile(
                        dense: isMobile,
                        contentPadding: EdgeInsets.symmetric(
                            horizontal: isMobile ? 10 : 14,
                            vertical:   isMobile ? 4  : 6),
                        title: Row(
                          children: [
                            Expanded(
                              child: Wrap(
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 6,
                                runSpacing: 4,
                                children: [
                                  Text(
                                    _getPatientDisplayName(p),
                                    style: TextStyle(
                                        color: hasBoth ? c.danger : c.textPrimary,
                                        fontWeight: FontWeight.w700,
                                        fontSize: isMobile ? 15 : 15.5),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                    decoration: BoxDecoration(
                                      color: isChildRec ? c.infoBg : c.brandSoft,
                                      borderRadius: BorderRadius.circular(5),
                                      border: Border.all(
                                        color: (isChildRec ? c.info : c.brand).withValues(alpha: 0.35),
                                      ),
                                    ),
                                    child: Text(
                                      isChildRec ? 'Child' : 'Adult',
                                      style: TextStyle(
                                        color: isChildRec ? c.info : c.brand,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (hasBoth)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: SoftPalette.red500,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  _isVitalsTokenAllowed
                                      ? '🎟️ Dual Tokens Done'
                                      : (regularToken != null && regularToken['serial'] != null
                                          ? '🎟️ #${LocalStorageService.formatCanonicalSerialForDisplay(regularToken['serial']?.toString())}'
                                          : '🎟️ Token Issued'),
                                  style: const TextStyle(
                                      color: SoftPalette.gray50,
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
                                      color: SoftPalette.purple600,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      '🩺 Vitals: #${LocalStorageService.formatCanonicalSerialForDisplay(vitalsToken['serial']?.toString())}',
                                      style: const TextStyle(color: SoftPalette.gray50, fontSize: 10.5, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                if (regularToken != null)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: SoftPalette.teal550,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      '🎟️ Regular: #${LocalStorageService.formatCanonicalSerialForDisplay(regularToken['serial']?.toString())}',
                                      style: const TextStyle(color: SoftPalette.gray50, fontSize: 10.5, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                              ])
                            else if (isRestricted)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: SoftPalette.orange350,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  '💊 ${restriction['remainingDays']}d Left',
                                  style: const TextStyle(
                                      color: SoftPalette.gray50,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold),
                                ),
                              )
                            else
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: c.successBg,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: c.success.withValues(alpha: 0.3)),
                                ),
                                child: Text(
                                  'Available',
                                  style: TextStyle(
                                      color: c.success,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700),
                                ),
                              ),
                          ],
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (isChildRec && guardianName != null && guardianName.isNotEmpty)
                                Text('Guardian: $guardianName',
                                    style: TextStyle(color: c.textSecondary, fontSize: 12, fontWeight: FontWeight.w600)),
                              if (hasDemo || (p['bloodGroup'] != null && p['bloodGroup'].toString().trim().isNotEmpty && p['bloodGroup'].toString().trim().toUpperCase() != 'N/A'))
                                Text(
                                  [
                                    if (genderVal.isNotEmpty && genderVal.toLowerCase() != 'unknown' && genderVal.toLowerCase() != 'null')
                                      genderVal,
                                    if (ageVal != null && ageVal > 0) '$ageVal yrs',
                                    if (p['bloodGroup'] != null && p['bloodGroup'].toString().trim().isNotEmpty && p['bloodGroup'].toString().trim().toUpperCase() != 'N/A')
                                      'Blood: ${p['bloodGroup'].toString().trim().toUpperCase()}',
                                  ].join(' · '),
                                  style: TextStyle(color: c.textMuted, fontSize: 11.5),
                                ),
                              Text('${cnicInfo.label}: ${cnicInfo.cnic}',
                                  style: TextStyle(color: c.textSecondary, fontSize: 12)),
                              Text('Phone: ${_getPatientDisplayPhone(p)}',
                                  style: TextStyle(color: c.textSecondary, fontSize: 12)),
                              if (vitalsToken != null && _isVitalsTokenAllowed)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Row(children: [
                                    Container(
                                      width: 8, height: 8,
                                      decoration: BoxDecoration(color: SoftPalette.purple500, shape: BoxShape.circle),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        'Vitals Inspection: #${LocalStorageService.formatCanonicalSerialForDisplay(vitalsToken['serial']?.toString())} (${(vitalsToken['status'] ?? 'waiting').toString().toUpperCase()})',
                                        style: TextStyle(
                                            color: isDark ? SoftPalette.purple350 : SoftPalette.violet700,
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
                                      decoration: BoxDecoration(color: SoftPalette.teal400, shape: BoxShape.circle),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        'Regular Visit: #${LocalStorageService.formatCanonicalSerialForDisplay(regularToken['serial']?.toString())} (${(regularToken['status'] ?? 'waiting').toString().toUpperCase()})',
                                        style: TextStyle(
                                            color: isDark ? SoftPalette.teal300 : SoftPalette.teal700,
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
                                          color: isDark ? SoftPalette.violet350 : SoftPalette.purple600,
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
                                          color: isDark ? SoftPalette.teal200 : SoftPalette.teal550,
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
                                  ? c.danger
                                  : (isRestricted && regularToken == null ? c.warning : c.brand),
                              foregroundColor: c.onBrand,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 10),
                              minimumSize: const Size(80, 36),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                          onPressed: () async => await _selectPatient(p),
                          child: Text(hasBoth ? 'View' : 'Select',
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
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
                        icon: Icon(Icons.close_rounded, size: 16, color: c.textSecondary),
                        label: Text('Deselect Patient',
                            style: TextStyle(
                                color: c.textSecondary,
                                fontWeight: FontWeight.w700,
                                fontSize: 12.5)),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          backgroundColor: c.surfaceSunken,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                              side: BorderSide(color: c.border)),
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
                    final selectedIsChild = LocalStorageService.isChildPatientRecord(_patientData!);
                    final selectedGuardianName = selectedIsChild ? _resolveChildGuardianName(_patientData!) : null;

                    return Container(
                      padding: EdgeInsets.all(isMobile ? 12 : 16),
                      decoration: BoxDecoration(
                        color: c.surfaceSunken,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: c.borderStrong),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: Wrap(
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  spacing: 8,
                                  runSpacing: 6,
                                  children: [
                                    Text(
                                      _getPatientDisplayName(_patientData!),
                                      style: TextStyle(
                                          fontSize:   isMobile ? 16.5 : 18,
                                          color:      c.textPrimary,
                                          fontWeight: FontWeight.w800),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: selectedIsChild ? c.infoBg : c.brandSoft,
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(
                                          color: (selectedIsChild ? c.info : c.brand).withValues(alpha: 0.35),
                                        ),
                                      ),
                                      child: Text(
                                        selectedIsChild ? 'Child' : 'Adult',
                                        style: TextStyle(
                                          color: selectedIsChild ? c.info : c.brand,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    _buildCategoryBadge(),
                                    Builder(builder: (context) {
                                      final staffInfo = StaffPatientLinkService.getStaffInfoFromPatientMap(_patientData);
                                      if (staffInfo != null) {
                                        return StaffPatientLinkService.buildStaffBadge(staffInfo, isDark: _isDark);
                                      }
                                      return const SizedBox.shrink();
                                    }),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: Icon(Icons.history_rounded,
                                    color: c.brand, size: 22),
                                tooltip: 'Audit History',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                onPressed: () {
                                  final pId = _patientData!['patientId']?.toString() ?? _patientData!['id']?.toString() ?? '';
                                  PatientAuditHistoryDialog.show(
                                    context,
                                    patientId: pId,
                                    patientName: _getPatientDisplayName(_patientData!),
                                    branchId: widget.branchId,
                                  );
                                },
                              ),
                              const SizedBox(width: 12),
                              IconButton(
                                icon: Icon(Icons.edit_rounded,
                                    color: c.warning, size: 22),
                                tooltip: 'Edit Details',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                onPressed: _requestEditPatient,
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              if (selectedIsChild && selectedGuardianName != null && selectedGuardianName.isNotEmpty)
                                _infoBadge(Icons.family_restroom_rounded, 'Guardian: $selectedGuardianName'),
                              _infoBadge(Icons.badge_outlined, () {
                                final i = _getDisplayCnicInfo(_patientData!);
                                return '${i.label}: ${i.cnic}';
                              }()),
                              _infoBadge(Icons.phone_outlined,
                                  'Phone: ${_getPatientDisplayPhone(_patientData!)}'),
                              if ((_patientData!['age'] ?? _patientData!['patientAge']) != null &&
                                  ((_patientData!['age'] ?? _patientData!['patientAge']).toString().trim() != '0'))
                                _infoBadge(Icons.calendar_today_outlined,
                                    'Age: ${_patientData!['age'] ?? _patientData!['patientAge']} yrs'),
                              if ((_patientData!['gender'] ?? _patientData!['patientGender']) != null &&
                                  (_patientData!['gender'] ?? _patientData!['patientGender']).toString().trim().isNotEmpty &&
                                  (_patientData!['gender'] ?? _patientData!['patientGender']).toString().trim().toLowerCase() != 'unknown')
                                _infoBadge(Icons.wc_rounded,
                                    'Gender: ${_patientData!['gender'] ?? _patientData!['patientGender']}'),
                              if (LocalStorageService.tryParseDob(_patientData!['dob'] ?? _patientData!['dateOfBirth']) != null)
                                _infoBadge(
                                  Icons.cake_outlined,
                                  'DOB: ${DateFormat('dd-MM-yyyy').format(LocalStorageService.tryParseDob(_patientData!['dob'] ?? _patientData!['dateOfBirth'])!)}',
                                ),
                              if (_patientData!['bloodGroup'] != null &&
                                  _patientData!['bloodGroup'].toString().trim().isNotEmpty &&
                                  _patientData!['bloodGroup'].toString().trim().toUpperCase() != 'N/A')
                                _infoBadge(Icons.bloodtype_outlined,
                                    'Blood: ${_patientData!['bloodGroup'].toString().trim().toUpperCase()}'),
                            ],
                          ),
                          if ((hasBothToday && _isVitalsTokenAllowed) || ((hasRegularToday || hasVitalsToday) && !_isVitalsTokenAllowed)) ...[
                            const SizedBox(height: 10),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                  color: _isDark ? SoftPalette.red800 : SoftPalette.pink100m,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                      color: _isDark ? SoftPalette.red400 : SoftPalette.red400)),
                              child: Column(
                                children: [
                                  Row(children: [
                                    const Icon(Icons.warning_amber_rounded,
                                        color: SoftPalette.red400, size: 22),
                                    const SizedBox(width: 8),
                                    Expanded(child: Text(
                                      (regularTodayToken?['status'] == 'skipped' || vitalsTodayToken?['status'] == 'skipped')
                                          ? 'Patient skipped twice today. Doctor exception required'
                                          : (_isVitalsTokenAllowed
                                              ? 'Both tokens (Vitals Inspection & Regular Visit) issued today'
                                              : 'Token (#${LocalStorageService.formatCanonicalSerialForDisplay(regularTodayToken?['serial']?.toString() ?? vitalsTodayToken?['serial']?.toString())}) already issued today'),
                                      style: const TextStyle(
                                          color:      SoftPalette.red400,
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
                                      backgroundColor: _isExceptionPending ? SoftPalette.amber300 : SoftPalette.orange350,
                                      foregroundColor: SoftPalette.gray50,
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
                                color: _isDark ? SoftPalette.indigo800 : SoftPalette.violet100m,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: _isDark ? SoftPalette.indigo500 : SoftPalette.violet300),
                              ),
                              child: Row(children: [
                                Icon(Icons.info_outline, color: _isDark ? SoftPalette.indigo300 : SoftPalette.purple600, size: 20),
                                const SizedBox(width: 8),
                                Expanded(child: Text(
                                  '🩺 Vitals token (#${LocalStorageService.formatCanonicalSerialForDisplay(vitalsTodayToken['serial']?.toString())}) taken. 🟢 Regular visit token still available today.',
                                  style: TextStyle(
                                    color: _isDark ? SoftPalette.slate150 : SoftPalette.violet700,
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
                                color: _isDark ? SoftPalette.teal800 : SoftPalette.emerald50m,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: _isDark ? SoftPalette.teal350 : SoftPalette.emerald200),
                              ),
                              child: Row(children: [
                                Icon(Icons.info_outline, color: _isDark ? SoftPalette.teal200 : SoftPalette.teal550, size: 20),
                                const SizedBox(width: 8),
                                Expanded(child: Text(
                                  '🎟️ Regular visit token (#${LocalStorageService.formatCanonicalSerialForDisplay(regularTodayToken['serial']?.toString())}) taken. 🩺 Vitals inspection token still available today.',
                                  style: TextStyle(
                                    color: _isDark ? SoftPalette.teal100 : SoftPalette.teal700,
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
                                  color: _isDark ? SoftPalette.orange800 : SoftPalette.amber100m,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: _isDark ? SoftPalette.orange350 : SoftPalette.amber300)),
                              child: Column(
                                children: [
                                  Row(children: [
                                    Icon(Icons.medication_liquid_outlined,
                                        color: SoftPalette.orange400, size: 22),
                                    const SizedBox(width: 8),
                                    Expanded(child: Text(
                                      _medicineRestriction!['isLastDay'] == true
                                        ? 'Restricted: Medicine expires TODAY (Vitals check still allowed)'
                                        : 'Restricted: Medicine expires in ${_medicineRestriction!['remainingDays']} days (Vitals check still allowed)',
                                      style: TextStyle(
                                          color:      _isDark ? SoftPalette.amber200 : SoftPalette.orange400,
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
                                      backgroundColor: _isExceptionPending ? SoftPalette.amber300 : SoftPalette.orange350,
                                      foregroundColor: SoftPalette.gray50,
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
                            return SizedBox(
                              width: double.infinity,
                              height: 46,
                              child: ElevatedButton.icon(
                                onPressed: cannotIssueToken ? null : _showVitalsDialog,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: c.brand,
                                  disabledBackgroundColor: c.surface,
                                  foregroundColor: c.onBrand,
                                  disabledForegroundColor: c.textMuted,
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10)),
                                ),
                                icon: const Icon(Icons.inventory_2_rounded, size: 19),
                                label: Text(
                                  cannotIssueToken
                                      ? ((regularTodayToken?['status'] == 'skipped' || vitalsTodayToken?['status'] == 'skipped')
                                          ? 'Skipped Twice - Exception Required'
                                          : (_isVitalsTokenAllowed ? 'Both Tokens Already Issued' : 'Token Already Issued Today'))
                                      : (hasVitalsToday
                                          ? 'Issue Regular Token'
                                          : (hasRegularToday
                                              ? (_isVitalsTokenAllowed ? 'Issue Vitals Only Token' : 'Token Already Issued Today')
                                              : 'Enter Vitals & Issue Token')),
                                  style: TextStyle(
                                      fontSize: isMobile ? 13.5 : 14.5,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.2),
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
                  Center(
                      child: CircularProgressIndicator(
                          color: c.brand)),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _infoBadge(
    IconData icon,
    String text, {
    String? imageAsset,
    Color? backgroundColor,
    Color? borderColor,
    Color? textColor,
    Color? iconColor,
  }) {
    final c = context.comfort;
    final bg = backgroundColor ?? c.surface;
    final bd = borderColor ?? c.borderStrong;
    final tc = textColor ?? c.textPrimary;
    final ic = iconColor ?? c.brand;

    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: bd, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (imageAsset != null)
            Image.asset(
              imageAsset,
              width: 14,
              height: 14,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => Icon(icon, size: 14, color: ic),
            )
          else
            Icon(icon, size: 14, color: ic),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: tc,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryBadge() {
    final q = _resolveQueueType(_patientData!['status'] as String?);
    final isGmwf = q.toLowerCase() == 'gmwf';
    final rawLabel = _isKarachi
        ? (isGmwf ? 'GMWF' : BranchLabels.karachiZakatLabel)
        : (isGmwf ? 'GMWF' : q);

    String displayLabel;
    final lLower = rawLabel.trim().toLowerCase();
    if (lLower == 'non-zakat' || lLower == 'non_zakat') {
      displayLabel = 'Non-Zakat';
    } else if (lLower == 'zakat') {
      displayLabel = 'Zakat';
    } else if (lLower == 'gmwf') {
      displayLabel = 'GMWF';
    } else if (rawLabel.trim().isEmpty) {
      displayLabel = 'General';
    } else {
      displayLabel = rawLabel.trim().split(RegExp(r'[\s_-]+')).map((w) {
        if (w.isEmpty) return '';
        return '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}';
      }).join(' ');
    }

    Color bg;
    Color border;
    Color textCol;
    IconData iconData;

    if (isGmwf) {
      bg = _isDark ? SoftPalette.yellow800.withValues(alpha: 0.25) : SoftPalette.yellow50;
      border = _isDark ? SoftPalette.yellow500.withValues(alpha: 0.5) : SoftPalette.yellow600.withValues(alpha: 0.6);
      textCol = _isDark ? SoftPalette.yellow300 : SoftPalette.yellow900;
      iconData = Icons.stars_rounded;
    } else if (lLower == 'zakat') {
      bg = _isDark ? SoftPalette.emerald900.withValues(alpha: 0.25) : SoftPalette.emerald50;
      border = _isDark ? SoftPalette.emerald600.withValues(alpha: 0.5) : SoftPalette.emerald400.withValues(alpha: 0.7);
      textCol = _isDark ? SoftPalette.emerald300 : SoftPalette.emerald700;
      iconData = Icons.volunteer_activism_rounded;
    } else {
      bg = _isDark ? SoftPalette.blue900.withValues(alpha: 0.2) : SoftPalette.blue50;
      border = _isDark ? SoftPalette.blue400.withValues(alpha: 0.4) : SoftPalette.blue300.withValues(alpha: 0.6);
      textCol = _isDark ? SoftPalette.blue200 : SoftPalette.blue700;
      iconData = Icons.shield_outlined;
    }

    return _infoBadge(
      iconData,
      displayLabel,
      imageAsset: isGmwf ? 'assets/logo/gmwf-1.webp' : null,
      backgroundColor: bg,
      borderColor: border,
      textColor: textCol,
      iconColor: textCol,
    );
  }

  ({String cnic, String label}) _getDisplayCnicInfo(
      Map<String, dynamic> patient) {
    final isChild = LocalStorageService.isChildPatientRecord(patient);
    final ownCnic = (patient['cnic'] ?? patient['patientCnic'] ?? patient['cNic'])?.toString().trim();
    final guardianCnic = (patient['guardianCnic'] ?? patient['guardian_cnic'])?.toString().trim();
    final pid = (patient['patientId'] ?? patient['id'] ?? '').toString().trim();

    String? formatValid(String? raw) {
      if (raw == null || raw.isEmpty || raw == '-' || raw.startsWith('unknown_')) return null;
      final clean = raw.replaceAll(RegExp(r'\D'), '');
      return clean.length == 13 ? _formatCnic(clean) : raw;
    }

    if (isChild) {
      final fromGuard = formatValid(guardianCnic);
      if (fromGuard != null) return (cnic: fromGuard, label: 'Guardian CNIC');
      if (pid.contains('_child_')) {
        final fromPid = formatValid(pid.split('_child_').first);
        if (fromPid != null) return (cnic: fromPid, label: 'Guardian CNIC');
      }
      final fromOwn = formatValid(ownCnic);
      if (fromOwn != null) return (cnic: fromOwn, label: 'Guardian CNIC');
      final searchDigits = cnicController.text.replaceAll(RegExp(r'\D'), '');
      if (searchDigits.length == 13) {
        return (cnic: _formatCnic(searchDigits), label: 'Guardian CNIC');
      }
      return (cnic: '-', label: 'Guardian CNIC');
    }

    final fromOwn = formatValid(ownCnic);
    if (fromOwn != null) return (cnic: fromOwn, label: 'CNIC');
    if (pid.isNotEmpty && !pid.contains('_child_') && RegExp(r'^[\d\-\s]+$').hasMatch(pid)) {
      final clean = pid.replaceAll(RegExp(r'\D'), '');
      if (clean.length == 13) return (cnic: _formatCnic(clean), label: 'CNIC');
    }
    final fromGuard = formatValid(guardianCnic);
    if (fromGuard != null) return (cnic: fromGuard, label: 'Guardian CNIC');
    final searchDigits = cnicController.text.replaceAll(RegExp(r'\D'), '');
    if (searchDigits.length == 13) {
      return (cnic: _formatCnic(searchDigits), label: 'CNIC');
    }
    return (cnic: '-', label: 'CNIC');
  }

  InputDecoration _vitalsDecoration(String label, IconData? icon, bool isDark,
          {String? hint}) =>
      InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: isDark ? SoftPalette.emerald150 : SoftPalette.emerald700),
        hintText: hint,
        hintStyle: TextStyle(color: isDark ? SoftPalette.slate600 : SoftPalette.slate350),
        counterText: '',
        isDense: true,
        prefixIcon: icon != null
            ? Icon(icon, color: isDark ? SoftPalette.emerald300 : SoftPalette.green500, size: 20)
            : null,
        filled: true,
        fillColor: isDark ? SoftPalette.teal900 : SoftPalette.gray50,
        border: OutlineInputBorder(
            borderRadius: const BorderRadius.all(Radius.circular(10)),
            borderSide: BorderSide(color: isDark ? SoftPalette.emerald750 : SoftPalette.gray150)),
        enabledBorder: OutlineInputBorder(
            borderRadius: const BorderRadius.all(Radius.circular(10)),
            borderSide: BorderSide(color: isDark ? SoftPalette.emerald750 : SoftPalette.gray150)),
        focusedBorder: OutlineInputBorder(
            borderRadius: const BorderRadius.all(Radius.circular(10)),
            borderSide: BorderSide(color: isDark ? SoftPalette.emerald350 : SoftPalette.green500, width: 2)),
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
  String? _vitalsError; // shown inside the dialog (a SnackBar would appear behind it)

  Color get _teal => context.comfort.brand;

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
    final c = context.comfort;
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: icon != null
          ? Icon(icon, color: _teal, size: 20)
          : null,
      labelStyle: TextStyle(color: c.textSecondary, fontSize: 13),
      hintStyle: TextStyle(color: c.textMuted, fontSize: 12),
      filled: true,
      fillColor: c.surfaceSunken,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: c.border)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: c.border)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: _teal, width: 1.8)),
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
      setState(() => _vitalsError = 'Please enter BP and Temperature.');
      return;
    }

    if (temp.isNotEmpty) {
      final tempVal = double.tryParse(temp);
      if (tempVal == null || tempVal < 30.0 || tempVal > 110.0) {
        setState(() => _vitalsError = 'Please enter a valid Temperature (°C).');
        return;
      }
    }

    final bpString = (systolic.isNotEmpty && diastolic.isNotEmpty)
        ? '$systolic/$diastolic'
        : (systolic.isNotEmpty ? systolic : '');

    setState(() {
      _vitalsError = null;
      isIssuingInDialog = true;
    });
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
    final c = context.comfort;
    final dialogBg = c.surface;
    final titleBg = c.brandSoft;
    final titleTextColor = c.brand;
    final sectionBg = c.surfaceSunken;
    final sectionBorder = c.border;
    final textColor = c.textPrimary;
    final labelColor = c.textSecondary;
    final dialogBorder = c.border;

    final canonicalName = LocalStorageService.resolveCanonicalPatientName(widget.patientData);
    final patientName = canonicalName.isNotEmpty ? canonicalName : 'Name not recorded';
    final isChildPatient = widget.patientData != null && LocalStorageService.isChildPatientRecord(widget.patientData!);
    final rawGuardianName = widget.patientData?['guardianName']?.toString().trim() ?? '';
    final guardianLabel = (isChildPatient &&
            rawGuardianName.isNotEmpty &&
            rawGuardianName != '0' &&
            rawGuardianName.toLowerCase() != 'null' &&
            rawGuardianName != '-')
        ? rawGuardianName
        : null;

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
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Flexible(
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
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                decoration: BoxDecoration(
                                  color: isChildPatient ? c.infoBg : c.brandSoft,
                                  borderRadius: BorderRadius.circular(5),
                                  border: Border.all(
                                    color: (isChildPatient ? c.info : c.brand).withValues(alpha: 0.35),
                                  ),
                                ),
                                child: Text(
                                  isChildPatient ? 'Child' : 'Adult',
                                  style: TextStyle(
                                    color: isChildPatient ? c.info : c.brand,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (guardianLabel != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              'Guardian: $guardianLabel',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: labelColor,
                                fontWeight: FontWeight.w500,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
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
                        color: isDark ? SoftPalette.slate550 : SoftPalette.gray350,
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
                    'Temperature (°C)',
                    Icons.thermostat,
                    isDark,
                    hint: 'e.g. 37.0'),
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
                  final itemBg = isSelected ? _teal : sectionBg;
                  final itemBorder = isSelected ? _teal : sectionBorder;

                  return Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(right: d < 3 ? 8 : 0),
                      child: InkWell(
                        onTap: () => setState(() => suggestedDays = d),
                        borderRadius: BorderRadius.circular(10),
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
                                color: isSelected ? c.onBrand : textColor,
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
          child: Column(
           mainAxisSize: MainAxisSize.min,
           crossAxisAlignment: CrossAxisAlignment.stretch,
           children: [
            if (_vitalsError != null)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: isDark ? SoftPalette.red800 : SoftPalette.red100t,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: isDark ? SoftPalette.red600 : SoftPalette.red200),
                ),
                child: Row(children: [
                  Icon(Icons.error_outline_rounded, size: 18, color: isDark ? SoftPalette.red300 : SoftPalette.red550),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_vitalsError!,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: isDark ? SoftPalette.red300 : SoftPalette.red550)),
                  ),
                ]),
              ),
            Row(
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
                        color: isDark ? SoftPalette.slate350 : SoftPalette.gray500,
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
                    backgroundColor: widget.hasVitalsToday ? SoftPalette.gray350 : SoftPalette.purple600,
                    foregroundColor: SoftPalette.gray50,
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
                  backgroundColor: widget.hasRegularToday ? c.surfaceSunken : _teal,
                  foregroundColor: widget.hasRegularToday ? c.textMuted : c.onBrand,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                  elevation: 0,
                ),
              ),
            ],
          ),
          ],
          ),
        ),
      ],
    );
  }
}