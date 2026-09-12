# Distributed LAN-First + Cloud Hybrid Sync Architecture Specification & Master Prompt

> **Context & Purpose**: This document serves as both a **comprehensive architectural blueprint** and an **AI-ready master prompt**. It synthesizes the full operational context, network topology, concurrency safety mechanisms, failure modes, resolved diagnostics, and production-ready code patterns for the multi-device Dispensary Synchronization System (GMWF).

---

## 1. Executive Architecture Summary

The system is a **hybrid dual-layer distributed workflow** designed for high-availability clinics operating under bandwidth, quota, and connectivity constraints:
1. **Edge/LAN Layer (Primary Real-Time Bus)**: Low-latency (5–20ms) WebSocket server running on a local Branch PC with UDP discovery. Facilitates immediate role-to-role broadcasts (Receptionist → Doctor → Dispensar → Supervisor) without cloud hops.
2. **Cloud/Firestore Layer (Durable Asynchronous Ledger)**: Persistent cloud fallback and multi-branch aggregation. Firestore listeners are dynamically **muted** during healthy LAN operation via a **Hysteresis Guard** to preserve daily quota (mitigating Firebase Spark/Blaze read explosions).
3. **Local Queue Layer (`sync_box`)**: Offline-first append-only write queue persisted to local disk (Hive/SQLite) with exponential retry backoff.

```
                  ┌──────────────────────────────────────────────┐
                  │              Firestore Cloud                 │
                  │   (Durable Ledger / Cross-Branch Backup)     │
                  └───────▲──────────────────────────────▲───────┘
                          │ (Async Sync Queue)           │ (Fallback if LAN Down)
                          │                              │
                  ┌───────▼──────────────────────────────▼───────┐
                  │           Hysteresis Guard & Muter           │
                  └───────────────────────▲──────────────────────┘
                                          │
       ┌──────────────────────────────────┴──────────────────────────────────┐
       │                   Local Area Network (LAN WebSocket)                │
       │                   UDP Discovery Port: 45454 | WS: 53281             │
       └───────▲──────────────────▲──────────────────▲──────────────────▲────┘
               │                  │                  │                  │
       ┌───────▼────────┐ ┌───────▼────────┐ ┌───────▼────────┐ ┌───────▼────────┐
       │  Branch Server │ │  Receptionist  │ │   Doctor PC    │ │    Dispensar   │
       │ (State & Sync) │ │ (Entry Creation)│ │ (Prescriptions)│ │  (Fulfillment)  │
       └────────────────┘ └────────────────┘ └────────────────┘ └────────────────┘
```

---

## 2. Role-Scoped Event Protocol & Broadcast Payloads

All LAN frames use a typed envelope structure:
```json
{
  "event": "EVENT_NAME",
  "msg_id": "uuid-v4-or-deterministic-hash",
  "branch_id": "SADDAR_01",
  "timestamp": 1773073510000,
  "payload": {}
}
```

### Core Events:
* `SAVE_ENTRY`: Receptionist generates a token → Server assigns queue number & broadcasts to Doctors.
* `REQUEST_LOCK_TOKEN`: Doctor attempts to open/consult a patient → Server atomically locks token.
* `LOCK_ACQUIRED` / `LOCK_REJECTED`: Server broadcast to confirm owner or reject dual-claim race conditions.
* `SAVE_PRESCRIPTION`: Doctor attaches diagnosis/medicines → Broadcasts to Dispensary queue.
* `DISPENSE_COMPLETED`: Dispensary marks medicines given → Updates status to `completed`.
* `CATCH_UP_REQUEST` & `CATCH_UP_RESPONSE`: Reconnecting client queries Branch Server for snapshot state of today's active tokens.

---

## 3. Critical Architectural Fragilities & Hardening Patterns

### A. Server Crash Resiliency (RAM Volatility vs Local Disk Persistence)
* **Risk**: If the Branch Server process dies or restarts, in-memory deduplication sets and active token state caches vanish. Reconnecting clients receive stale catch-up snapshots.
* **Hardening Pattern**: Write-Ahead Local Cache (WAL) via Hive/SQLite before broadcasting.

```dart
// branch_server_cache_manager.dart
import 'package:hive/hive.dart';

class LocalTokenStorage {
  static const String boxName = 'branch_active_tokens';
  late Box _tokenBox;

  Future<void> init() async {
    _tokenBox = await Hive.openBox(boxName);
  }

  /// Persist token state to disk before sending LAN broadcast
  Future<void> persistTokenState(String tokenId, Map<String, dynamic> tokenData) async {
    tokenData['updated_at'] = DateTime.now().millisecondsSinceEpoch;
    await _tokenBox.put(tokenId, tokenData);
  }

  Map<String, dynamic>? getToken(String tokenId) {
    final raw = _tokenBox.get(tokenId);
    return raw != null ? Map<String, dynamic>.from(raw as Map) : null;
  }

  List<Map<String, dynamic>> getAllActiveTokensToday() {
    return _tokenBox.values
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }
}
```

---

### B. Doctor Token-Lock Race Condition (Atomic Server Lock)
* **Risk**: Two doctors click token `#005` at the same instant (5–20ms LAN window). Optimistic client locking leads to split-brain consultations.
* **Hardening Pattern**: The Branch Server is the single source of truth; it enforces **First-Write-Wins** with explicit rejection packets.

```dart
// server_lock_handler.dart
class TokenLockManager {
  final Map<String, String> _activeLocks = {}; // tokenId -> doctorDeviceId

  Map<String, dynamic> handleLockRequest({
    required String tokenId,
    required String requestingDoctorId,
    required String requestingDoctorName,
  }) {
    if (_activeLocks.containsKey(tokenId) && _activeLocks[tokenId] != requestingDoctorId) {
      // Already locked by another doctor
      return {
        'status': 'REJECTED',
        'token_id': tokenId,
        'locked_by': _activeLocks[tokenId],
        'reason': 'Token is currently locked by another doctor.',
      };
    }

    // Grant lock atomically
    _activeLocks[tokenId] = requestingDoctorId;
    return {
      'status': 'ACQUIRED',
      'token_id': tokenId,
      'locked_by': requestingDoctorId,
      'doctor_name': requestingDoctorName,
      'locked_at': DateTime.now().millisecondsSinceEpoch,
    };
  }

  void releaseLock(String tokenId, String doctorId) {
    if (_activeLocks[tokenId] == doctorId) {
      _activeLocks.remove(tokenId);
    }
  }
}
```

---

### C. Cloud Write Idempotency & Quota-Safe Sync Worker
* **Risk**: Offline retry queues flushes on reconnect. If network drops mid-ACK, writes retry and cause duplicate Firestore documents or runaway write quota consumption.
* **Hardening Pattern**: Deterministic Firestore Document IDs combined with atomic `set(..., SetOptions(merge: true))`.

```dart
// idempotent_cloud_sync_worker.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive/hive.dart';

class SyncAction {
  final String actionId; // Deterministic: "${branchId}_${date}_${tokenNumber}"
  final String collection;
  final Map<String, dynamic> data;

  SyncAction({required this.actionId, required this.collection, required this.data});
}

class CloudSyncWorker {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final Box _syncQueueBox = Hive.box('sync_queue');

  Future<void> processQueue() async {
    final rawKeys = _syncQueueBox.keys.toList();
    for (final key in rawKeys) {
      final item = Map<String, dynamic>.from(_syncQueueBox.get(key) as Map);
      final String docId = item['action_id'];
      final String collection = item['collection'];
      final Map<String, dynamic> payload = Map<String, dynamic>.from(item['data']);

      try {
        // Deterministic document write (Idempotent: safe against infinite retries)
        await _firestore
            .collection(collection)
            .doc(docId)
            .set(payload, SetOptions(merge: true));

        // Delete from local queue ONLY after confirmed cloud write
        await _syncQueueBox.delete(key);
      } on FirebaseException catch (e) {
        if (e.code == 'resource-exhausted') {
          // Spark/Blaze quota exceeded: halt queue processing until quota window resets
          break;
        }
        // Handle transient errors with exponential backoff
      }
    }
  }
}
```

---

### D. Time-Dampened Hysteresis Guard (Muting Cloud Listeners)
* **Risk**: Flapping WiFi router triggers rapid re-subscription cycles to Firestore collections, consuming thousands of read operations within minutes.
* **Hardening Pattern**: Require consecutive successful pings **plus** a minimum dwell time (e.g., 10 seconds) before disabling Firestore listener fallback.

```dart
// hysteresis_network_guard.dart
import 'dart:async';

enum SyncMode { lanPrimary, cloudFallback }

class HysteresisGuard {
  int _consecutiveSuccess = 0;
  int _consecutiveFailures = 0;
  DateTime _lastModeSwitch = DateTime.now();

  static const int kSuccessThreshold = 3;
  static const int kFailureThreshold = 2;
  static const Duration kMinDwellTime = Duration(seconds: 10);

  SyncMode currentMode = SyncMode.cloudFallback;
  final StreamController<SyncMode> _modeStream = StreamController<SyncMode>.broadcast();
  Stream<SyncMode> get onModeChanged => _modeStream.stream;

  void reportPingResult({required bool isSuccess}) {
    final now = DateTime.now();
    if (isSuccess) {
      _consecutiveSuccess++;
      _consecutiveFailures = 0;

      if (currentMode == SyncMode.cloudFallback &&
          _consecutiveSuccess >= kSuccessThreshold &&
          now.difference(_lastModeSwitch) >= kMinDwellTime) {
        _setMode(SyncMode.lanPrimary, now);
      }
    } else {
      _consecutiveFailures++;
      _consecutiveSuccess = 0;

      if (currentMode == SyncMode.lanPrimary &&
          _consecutiveFailures >= kFailureThreshold &&
          now.difference(_lastModeSwitch) >= kMinDwellTime) {
        _setMode(SyncMode.cloudFallback, now);
      }
    }
  }

  void _setMode(SyncMode newMode, DateTime timestamp) {
    currentMode = newMode;
    _lastModeSwitch = timestamp;
    _modeStream.add(newMode);
  }
}
```

---

## 4. Production Issues & Field Troubleshooting Playbook

### Issue 1: Queue Stuck at Count (e.g. 130) / Quota Exhaustion
* **Symptom**: Local actions queue up in `sync_box`; Firestore stops receiving updates.
* **Root Cause**: Firebase **Spark (Free) Plan** daily limits exceeded (50K reads/day, 20K writes/day). At 180K reads / 35K writes, Firestore returns `RESOURCE_EXHAUSTED` and rejects all writes/reads until 00:00 PST.
* **Action Plan**:
  1. Upgrade project to **Blaze Plan** (Pay-as-you-go). Estimated cost for this traffic profile is nominal (~$2–$5/month).
  2. Audit Firestore listeners across non-dispensary screens (Finance/Office/Inventory) to ensure unneeded collections are not streaming continuously.

---

### Issue 2: 2.4GHz LAN Discovery Failure (Server + Doctor Disconnected)
* **Symptom**: Server and Doctor PC are both on 2.4GHz WiFi band and cannot discover each other via UDP broadcast, but a 5GHz device connects seamlessly.
* **Diagnostic Checklist**:
  1. **Windows WiFi Adapter Power Saving**: Windows frequently cuts power to 2.4GHz WiFi multicast/broadcast receiver rings.
     * *Fix*: `Device Manager` → `Network Adapters` → `Properties` → `Power Management` → Uncheck *“Allow the computer to turn off this device to save power”*.
  2. **Windows Firewall Profile Mismatch**: Network recognized as *Public* instead of *Private*, silently blocking incoming UDP 45454 / WS 53281.
  3. **Packet Loss / RF Shadowing**: 2.4GHz congestion causing UDP broadcast packet drop.

#### PowerShell Diagnostic Script (Run on Doctor & Server PCs):
```powershell
# Diagnostic Script: Test LAN Connectivity & Firewall Profile
Write-Host "=== 1. NETWORK PROFILE ===" -ForegroundColor Cyan
Get-NetConnectionProfile | Select-Object Name, NetworkCategory, InterfaceAlias

Write-Host "`n=== 2. IP & GATEWAY CONFIG ===" -ForegroundColor Cyan
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127*" } | Select-Object IPAddress, InterfaceAlias

Write-Host "`n=== 3. CHECK LISTENING PORTS ===" -ForegroundColor Cyan
Get-NetTCPConnection -LocalPort 53281 -ErrorAction SilentlyContinue | Select-Object LocalAddress, LocalPort, State

Write-Host "`n=== 4. FIREWALL STATUS (UDP 45454 / TCP 53281) ===" -ForegroundColor Cyan
Get-NetFirewallRule -DisplayName "*GMWF*" -ErrorAction SilentlyContinue | Select-Object DisplayName, Enabled, Direction, Action
```

---

## 5. Master Prompt for AI & Engineering Handoff

When instructing an LLM or developer to build, debug, or extend this system (e.g., replicating for Dastarkhawaan / Kitchen module), provide the prompt below:

```markdown
You are an expert distributed systems and Flutter engineer specializing in edge-first, offline-durable sync architectures with LAN-first routing and cloud fallback.

### System Architecture Guidelines:
1. Primary Transport: LAN WebSocket with UDP Discovery (multicast/broadcast fallback) for all real-time clinic operations (Receptionist -> Doctor -> Dispensary -> Supervisor).
2. Cloud Layer: Firestore used as an asynchronous durable ledger. When LAN is healthy, Firestore listeners MUST be muted via a Hysteresis Guard to avoid quota consumption.
3. Resilience & Idempotency:
   - Branch Server MUST persist state to local disk (Hive/SQLite) prior to broadcast to survive sudden reboots/power outages.
   - Doctor token locks MUST be validated atomically on the server with explicit rejection envelopes.
   - Cloud sync queues (`sync_box`) MUST use deterministic document IDs and set(merge: true) to prevent double writes upon network retries.
   - Hysteresis guards MUST enforce a minimum dwell time (10s+) to eliminate connection flapping.

When reviewing code, diagnosing sync issues, or generating new modules, strictly adhere to these distributed invariants and check for race conditions, quota leaks, and unhandled offline states.
```
