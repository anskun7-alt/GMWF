// lib/pages/dispensary/hybrid_all_in_one_screen.dart
//
// The Hybrid desk's "Pharmacy" tab: everything a Receptionist and a Dispenser do,
// on one screen.
//
//   [ Today's collection: Zakat · Non-Zakat · GMWF · Issued by me (PKR)  ⓦ ]
//   [ Today's Tokens        ][ Reception            ][ Dispense             ]
//   [ shift chips, my tokens][ Register | Token &   ][ next waiting patient ]
//   [ + status, reverse ↶   ][ Vitals               ][ (auto, smallest no.) ]
//
// Built from the real screens so behaviour stays identical:
//  • ReceptionistScreen (pharmacy layout) owns Reception, Today's Tokens (reverse
//    token, shift filter, refresh), the collection strip and all receptionist
//    realtime work (reversal approvals, patient edits, catch-up…).
//  • DispensarScreen runs headless for the dispenser's realtime work and the
//    "Prescription ready" popup.
//  • The dispense form (PatientForm) auto-loads the next waiting patient using
//    the dispenser's own queue rules (DispenseQueue), and advances after each
//    dispense. Tapping a "Waiting for Dispense" row loads that patient instead.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/utils/debounced_box_listenable.dart';
import '../../design/design_system.dart';
import 'dispensar/dispensar_screen.dart';
import 'dispensar/dispense_queue.dart';
import 'dispensar/patient_form.dart';
import 'receptionist/receptionist_screen.dart';
import 'widgets/pharmacy_pane.dart';

class HybridAllInOneScreen extends StatefulWidget {
  final String branchId;
  final String userId;
  final String userName;

  const HybridAllInOneScreen({
    super.key,
    required this.branchId,
    required this.userId,
    required this.userName,
  });

  @override
  State<HybridAllInOneScreen> createState() => _HybridAllInOneScreenState();
}

class _HybridAllInOneScreenState extends State<HybridAllInOneScreen> {
  /// Patient open in the dispense form.
  Map<String, dynamic>? _dispensing;

  /// Shift filter of Today's Tokens; the dispense queue follows it.
  String _sessionFilter = 'all';

  /// Just dispensed: skipped until the queue has caught up, so it is not reloaded.
  String? _justDispensed;

  final List<DebouncedBoxListenable> _boxes = [];
  Timer? _advanceDebounce;

  String? get _dispensingSerial => _dispensing?['serial']?.toString();

  @override
  void initState() {
    super.initState();
    CampSessionService.activeCampNotifier.addListener(_scheduleAdvance);
    // Another desk opened a patient (skip them) or won the same token (move on).
    DispenseQueue.listenForClaims();
    DispenseQueue.claimsChanged.addListener(_scheduleAdvance);
    for (final name in [LocalStorageService.entriesBox, LocalStorageService.dispensaryBox]) {
      LocalStorageService.ensureBoxOpen(name).then((box) {
        if (!mounted) return;
        _boxes.add(DebouncedBoxListenable.shared(box)..addListener(_scheduleAdvance));
        _advance();
      }).catchError((e) {
        debugPrint('[Pharmacy] Could not open $name: $e');
      });
    }
  }

  @override
  void dispose() {
    _advanceDebounce?.cancel();
    CampSessionService.activeCampNotifier.removeListener(_scheduleAdvance);
    DispenseQueue.claimsChanged.removeListener(_scheduleAdvance);
    for (final b in _boxes) {
      b.removeListener(_scheduleAdvance);
    }
    super.dispose();
  }

  // ── Auto-load the next patient to dispense ───────────────────────────────
  String get _campFilter {
    if (!CampSessionService.hasCampsForBranch(widget.branchId)) return 'all';
    final active = CampSessionService.getActiveCamp(widget.branchId);
    return (active == null || active.isEmpty) ? 'all' : active;
  }

  List<Map<String, dynamic>> _queue(String sessionFilter) => DispenseQueue.compute(
        branchId: widget.branchId,
        sessionFilter: sessionFilter,
        campFilter: _campFilter,
      );

  void _scheduleAdvance() {
    _advanceDebounce?.cancel();
    _advanceDebounce = Timer(const Duration(milliseconds: 250), _advance);
  }

  /// Keeps the open patient while they are still waiting (never switches away
  /// mid-dispense); otherwise loads the waiting patient with the smallest token.
  void _advance() {
    if (!mounted) return;
    try {
      final queue = _queue(_sessionFilter);
      final skip = _justDispensed;
      if (skip != null &&
          !DispenseQueue.activePending(queue).any((p) => DispenseQueue.sameSerial(p['serial'], skip))) {
        _justDispensed = null; // the queue has caught up
      }

      final current = _dispensingSerial;
      if (current != null && current.isNotEmpty) {
        // Still waiting (in any shift)? Keep it — e.g. the user changed the shift filter.
        final stillWaiting = DispenseQueue.pickNext(queue, currentSerial: current, skipSerial: _justDispensed);
        if (DispenseQueue.sameSerial(stillWaiting?['serial'], current)) return;
        final anyShift = DispenseQueue.pickNext(_queue('all'), currentSerial: current, skipSerial: _justDispensed);
        if (DispenseQueue.sameSerial(anyShift?['serial'], current)) return;
      }

      final next = DispenseQueue.pickNext(queue, skipSerial: _justDispensed);
      if (!DispenseQueue.sameSerial(next?['serial'], current) || (next == null) != (_dispensing == null)) {
        setState(() => _dispensing = next);
      }
    } catch (e) {
      debugPrint('[Pharmacy] Could not pick the next patient: $e');
    }
  }

  void _onDispensed() {
    if (!mounted) return;
    setState(() {
      _justDispensed = _dispensingSerial;
      _dispensing = null;
    });
    _advance();
  }

  /// Allows selecting a waiting patient directly, with auto-selection defaulting to FIFO smallest token.
  void _onDispenseRequested(Map<String, dynamic> entry) {
    if (!mounted || entry.isEmpty) return;
    final serial = (entry['serial'] ?? entry['id'])?.toString();
    if (serial != null && serial.isNotEmpty) {
      setState(() {
        _dispensing = entry;
      });
    }
  }

  void _onSessionFilterChanged(String filter) {
    if (filter == _sessionFilter) return;
    _sessionFilter = filter;
    _advance();
  }

  /// From the headless dispenser engine: the open patient got a new prescription
  /// (refresh it) or was cleared/dispensed elsewhere (null -> load the next one).
  void _onEngineSelectedChanged(Map<String, dynamic>? updated) {
    if (!mounted) return;
    if (updated == null) {
      setState(() => _dispensing = null);
      _advance();
    } else {
      setState(() => _dispensing = updated);
    }
  }

  // ── Dispense pane ─────────────────────────────────────────────────────────
  Widget _dispensePane() {
    final c = context.comfort;
    final entry = _dispensing;
    final serial = _dispensingSerial;
    return PharmacyPane(
      icon: Icons.medication_outlined,
      title: serial == null ? 'Dispense' : 'Dispense  ·  #$serial',
      child: entry == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.medication_liquid_rounded, size: 52, color: c.textMuted),
                    const SizedBox(height: 12),
                    Text(
                      'No patients waiting to dispense',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.textSecondary),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'The next prescription opens here automatically.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: c.textMuted),
                    ),
                  ],
                ),
              ),
            )
          : PatientForm(
              key: ValueKey(serial),
              branchId: widget.branchId,
              queueEntry: entry,
              dispenserName: widget.userName,
              onDispensed: _onDispensed,
              isCompactPreview: true,
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final receptionist = ReceptionistScreen(
      branchId: widget.branchId,
      receptionistId: widget.userId,
      receptionistName: widget.userName,
      isEmbedded: true,
      // The dispenser engine below shows the "Prescription ready" popup once.
      suppressPrescriptionNotifications: true,
      pharmacy: ReceptionistPharmacySlots(
        dispensePane: _dispensePane(),
        dispensingSerial: _dispensingSerial,
        onDispenseRequested: _onDispenseRequested,
        onSessionFilterChanged: _onSessionFilterChanged,
      ),
    );

    return Column(
      children: [
        // No UI: dispenser realtime work for this tab.
        DispensarScreen(
          branchId: widget.branchId,
          dispenserId: widget.userId,
          dispenserName: widget.userName,
          isEmbedded: true,
          headless: true,
          selectedEntry: _dispensing,
          onSelectedEntryChanged: _onEngineSelectedChanged,
        ),
        Expanded(
          child: MediaQuery.sizeOf(context).width >= 900 ? _compactText(context, receptionist) : receptionist,
        ),
      ],
    );
  }

  /// Slightly smaller, uniform text so the three panes fit a 1366x768 desk
  /// (on top of the user's own text scale).
  static Widget _compactText(BuildContext context, Widget child) {
    final mq = MediaQuery.of(context);
    return MediaQuery(
      data: mq.copyWith(textScaler: TextScaler.linear(mq.textScaler.scale(1.0) * 0.92)),
      child: child,
    );
  }
}
