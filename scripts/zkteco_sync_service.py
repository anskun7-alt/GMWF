#!/usr/bin/env python3
"""
ZKTeco LAN Standalone Service to Cloud Firestore Sync
-----------------------------------------------------
Description:
    Connects to ZKTeco biometric devices over TCP port 4370 (Standalone/Pull Mode),
    fetches attendance logs from internal memory chips, deduplicates records,
    and pushes them directly to Google Cloud Firestore in real time.

Features:
    1. Isolated try/except per device so unplugged/offline scanners won't crash the script.
    2. Document-level deduplication on Firestore (doc_id = "{device_ip}_{user_id}_{timestamp}").
    3. Offline fallback buffer (pending_punches.json) if internet/Firestore drops temporarily.
    4. Optional hardware memory clearing (conn.clear_attendance()) to prevent memory full.
    5. Automatic daemon loop running every 15 seconds (configurable).

Dependencies:
    pip install pyzk firebase-admin

Usage:
    python zkteco_sync_service.py --config config.json
"""

import os
import sys
import json
import time
import argparse
from datetime import datetime

# Configure Windows stdout for UTF-8 encoding
if sys.platform == "win32" and hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

# Automatic Dependency Installer (Self-healing import)
def _ensure_package(module_name, pip_name=None):
    pip_name = pip_name or module_name
    try:
        __import__(module_name)
    except ImportError:
        print(f"[INFO] Package '{pip_name}' is missing. Installing automatically via pip...")
        import subprocess
        try:
            subprocess.check_call([sys.executable, "-m", "pip", "install", pip_name])
            print(f"[INFO] Successfully installed '{pip_name}'.")
        except Exception as e:
            print(f"[ERROR] Failed to auto-install '{pip_name}': {e}")

_ensure_package("zk", "pyzk")
_ensure_package("firebase_admin", "firebase-admin")

# Import ZKTeco library (pyzk)
from zk import ZK

# Import Firebase Admin SDK
import firebase_admin
from firebase_admin import credentials, firestore


# Default Configuration
DEFAULT_CONFIG = {
    "sync_interval_seconds": 15,
    "firebase_credentials_path": "serviceAccountKey.json",
    "clear_memory_after_sync": False,
    "devices": [
        {
            "name": "Office HQ Main Gate Scanner",
            "ip": "192.168.1.150",
            "port": 4370,
            "location": "Office/Dasterkhwaan",
            "branch": "karachi"
        },
        {
            "name": "Dispensary Medical Scanner",
            "ip": "192.168.1.151",
            "port": 4370,
            "location": "Dispensary",
            "branch": "karachi"
        },
        {
            "name": "Madrassa Gate Scanner",
            "ip": "192.168.1.152",
            "port": 4370,
            "location": "Madrassa",
            "branch": "karachi"
        },
        {
            "name": "GMWF Model School Scanner",
            "ip": "192.168.1.153",
            "port": 4370,
            "location": "School",
            "branch": "karachi"
        },
        {
            "name": "Dasterkhwaan Kitchen Scanner",
            "ip": "192.168.1.154",
            "port": 4370,
            "location": "Dasterkhwaan Kitchen",
            "branch": "karachi"
        },
        {
            "name": "Auxiliary Staff Scanner",
            "ip": "192.168.1.155",
            "port": 4370,
            "location": "Office/Dasterkhwaan",
            "branch": "karachi"
        }
    ]
}

OFFLINE_BUFFER_FILE = "pending_punches.json"
STATE_FILE = "synced_keys.json"


def load_config(config_path="config.json"):
    """Loads configuration from JSON file or generates default if missing."""
    if os.path.exists(config_path):
        with open(config_path, "r") as f:
            try:
                return json.load(f)
            except Exception as e:
                print(f"[WARN] Failed to parse {config_path}: {e}. Using default configuration.")
    else:
        with open(config_path, "w") as f:
            json.dump(DEFAULT_CONFIG, f, indent=4)
        print(f"[INFO] Created template configuration file at: {os.path.abspath(config_path)}")
    return DEFAULT_CONFIG


def init_firebase(creds_path):
    """Initializes Firebase Admin SDK smoothly with local buffer fallback."""
    if firebase_admin._apps:
        try:
            return firestore.client()
        except Exception:
            return None

    if os.path.exists(creds_path):
        try:
            cred = credentials.Certificate(creds_path)
            firebase_admin.initialize_app(cred)
            print(f"[FIREBASE] Initialized with credentials file: {creds_path}")
            return firestore.client()
        except Exception as e:
            print(f"[WARN] Error loading {creds_path}: {e}")

    print("[FIREBASE] Running in Local Storage Mode (Buffering scans to 'pending_punches.json').")
    print("[FIREBASE] To sync directly to Cloud Firestore, place 'serviceAccountKey.json' in scripts/ directory.")
    return None


def load_synced_keys():
    """Loads already processed punch keys to prevent re-processing."""
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, "r") as f:
                return set(json.load(f))
        except Exception:
            return set()
    return set()


def save_synced_keys(keys_set):
    """
    Saves synced keys set to state file (capped at 20,000 entries).
    
    NOTE (Future Maintenance Item):
    synced_keys.json accumulates processed punch document keys across long uptime runs.
    While capped at 20,000 entries here, a formal pruning mechanism (e.g., archiving entries
    older than N days / 90 days based on ISO timestamp parsing) should be scheduled for future maintenance.
    """
    keys_list = list(keys_set)
    if len(keys_list) > 20000:
        keys_list = keys_list[-10000:]  # Keep latest 10k entries
    with open(STATE_FILE, "w") as f:
        json.dump(keys_list, f)


def save_offline_punch(punch):
    """Saves punch to offline buffer file if Firestore is unreachable."""
    pending = []
    if os.path.exists(OFFLINE_BUFFER_FILE):
        try:
            with open(OFFLINE_BUFFER_FILE, "r") as f:
                pending = json.load(f)
        except Exception:
            pending = []

    pending.append(punch)
    with open(OFFLINE_BUFFER_FILE, "w") as f:
        json.dump(pending, f, indent=2)


# Global quota cooldown tracking (epoch seconds). Prevents 60-second retry timeout loops when Firestore daily limit is reached.
_quota_cooldown_until = 0


def flush_offline_buffer(db):
    """Attempts to push unsent offline buffered punches to Firestore using batched writes."""
    global _quota_cooldown_until
    if not db or not os.path.exists(OFFLINE_BUFFER_FILE):
        return

    now = time.time()
    if now < _quota_cooldown_until:
        remaining_mins = int((_quota_cooldown_until - now) // 60) + 1
        return

    try:
        with open(OFFLINE_BUFFER_FILE, "r") as f:
            pending = json.load(f)

        if not pending:
            return

        print(f"[SYNC] Found {len(pending)} offline buffered punches. Uploading to Firestore...")
        remaining = list(pending)
        flushed_count = 0
        batch_size = 200

        while remaining:
            chunk = remaining[:batch_size]
            batch = db.batch()
            for punch in chunk:
                doc_id = punch.get("doc_id") or punch.get("id") or f"{punch.get('branchId', '')}_{punch.get('deviceIp', '')}_{punch.get('pin', '')}_{punch.get('timestamp_epoch', '')}"
                ref = db.collection("biometric_punches").document(doc_id)
                batch.set(ref, punch, merge=True)

            try:
                batch.commit()
                flushed_count += len(chunk)
                remaining = remaining[batch_size:]
                # Update file progressively after each successful batch
                with open(OFFLINE_BUFFER_FILE, "w") as f:
                    json.dump(remaining, f, indent=2)
            except Exception as be:
                err_str = str(be)
                if "429" in err_str or "Quota" in err_str or "ResourceExhausted" in err_str:
                    _quota_cooldown_until = time.time() + 900  # 15 min cooldown
                    print(f"[SYNC] ⚠️ Firestore daily write quota reached (HTTP 429).")
                    print(f"[SYNC] 🔒 {len(remaining)} punches safely preserved in '{OFFLINE_BUFFER_FILE}'. Cloud flush paused for 15 minutes.")
                    break
                else:
                    print(f"[WARN] Batch commit encountered error: {be}. Retaining {len(remaining)} punches for next cycle.")
                    break

        if not remaining:
            print(f"[SYNC] ✅ All {flushed_count} offline buffered punches flushed successfully!")
        elif flushed_count > 0:
            print(f"[SYNC] ℹ️ Flushed {flushed_count} punches; {len(remaining)} remain safely buffered.")

    except Exception as e:
        print(f"[WARN] Error reading offline buffer file: {e}")


# In-memory dictionary tracking pending hardware memory clears across sync cycles.
# This flag is intentionally in-memory only. On restart, it resets to unset,
# meaning any device memory clear that hadn't yet executed will simply be
# re-evaluated on the next cycle. This is a deliberate fail-safe, not an oversight.
_pending_clears_by_ip = {}

# In-memory employee directory cache (PIN -> Employee info)
_employee_cache = {}
_employee_cache_timestamp = 0


def get_employee_directory(db):
    """
    Loads employee profiles from Firestore and indexes them by PIN and ID.
    Cached in memory for 10 minutes to minimize Firestore read quota.
    """
    global _employee_cache, _employee_cache_timestamp
    now = time.time()
    if _employee_cache and (now - _employee_cache_timestamp < 600):
        return _employee_cache

    if not db:
        return _employee_cache

    try:
        directory = {}
        # 1. Fetch root employees collection
        for doc in db.collection("employees").stream():
            data = doc.to_dict()
            emp_id = doc.id
            name = data.get("name") or data.get("employeeName") or "Employee"
            pin = str(data.get("biometricPin") or data.get("pin") or data.get("localId") or "").strip()
            dept = data.get("department") or data.get("dept") or ""
            branch = data.get("branchId") or data.get("branch") or ""
            role = data.get("role") or data.get("designation") or ""

            info = {
                "name": name,
                "employeeId": emp_id,
                "department": dept,
                "branchId": branch,
                "role": role,
            }
            if pin:
                directory[pin] = info
            directory[emp_id] = info

        # 2. Fetch branch subcollections
        for branch_doc in db.collection("branches").stream():
            b_id = branch_doc.id
            for doc in db.collection("branches").document(b_id).collection("employees").stream():
                data = doc.to_dict()
                emp_id = doc.id
                name = data.get("name") or data.get("employeeName") or "Employee"
                pin = str(data.get("biometricPin") or data.get("pin") or data.get("localId") or "").strip()
                dept = data.get("department") or data.get("dept") or ""
                branch = data.get("branchId") or b_id
                role = data.get("role") or data.get("designation") or ""

                info = {
                    "name": name,
                    "employeeId": emp_id,
                    "department": dept,
                    "branchId": branch,
                    "role": role,
                }
                if pin:
                    directory[pin] = info
                directory[emp_id] = info

        _employee_cache = directory
        _employee_cache_timestamp = now
        print(f"[DIRECTORY] Loaded {len(directory)} employee mappings from Firestore.")
    except Exception as e:
        print(f"[WARN] Error refreshing employee directory: {e}")

    return _employee_cache


def has_pending_buffer_for_ip(ip):
    """Checks if pending_punches.json contains unsent punches for the specified IP."""
    if not os.path.exists(OFFLINE_BUFFER_FILE):
        return False
    try:
        with open(OFFLINE_BUFFER_FILE, "r") as f:
            pending = json.load(f)
            return any(p.get("deviceIp") == ip for p in pending)
    except Exception:
        return False


def fetch_and_sync_device(device_cfg, db, synced_keys, clear_memory=False):
    """
    Connects to a single ZKTeco device via pyzk on port 4370.
    Wrapped in isolated try/except so one offline device won't break others.
    """
    ip = device_cfg.get("ip")
    port = device_cfg.get("port", 4370)
    name = device_cfg.get("name", f"ZKTeco ({ip})")
    location = device_cfg.get("location", "Office")

    print(f"\n[DEVICE] Connecting to {name} at {ip}:{port}...")

    zk = ZK(ip, port=port, timeout=5, password=0, force_udp=False, ommit_ping=False)
    conn = None

    try:
        conn = zk.connect()
        print(f"[DEVICE] ✅ Connected to {name} ({ip})")

        # Step 0: Cycle N+1 Check — If previous cycle was 100% verified synced, clear device memory now
        if clear_memory and _pending_clears_by_ip.get(ip) is True:
            if db and not has_pending_buffer_for_ip(ip):
                print(f"[DEVICE] ⚠️ Executing verified 2-cycle memory clear for {name} ({ip})...")
                try:
                    conn.clear_attendance()
                    _pending_clears_by_ip[ip] = False
                    print(f"[DEVICE] ✅ Memory cleared successfully for {name} ({ip}).")
                except Exception as ce:
                    print(f"[DEVICE] ❌ Failed to clear memory for {name}: {ce}")
            else:
                print(f"[DEVICE] ℹ️ Skipping memory clear for {name}: pending offline buffer or Firestore unavailable.")

        # Disable device during read operation to prevent concurrent writes
        conn.disable_device()

        # Fetch attendance logs from internal memory
        attendances = conn.get_attendance()
        print(f"[DEVICE] Read {len(attendances)} total raw log records from {name}")

        new_punches_count = 0
        all_writes_succeeded = True

        directory = get_employee_directory(db) if db else {}

        for atten in attendances:
            pin = str(atten.user_id).strip()
            timestamp_dt = atten.timestamp
            timestamp_str = timestamp_dt.isoformat()
            timestamp_epoch = int(timestamp_dt.timestamp())

            # [FIX-3.3] Standardized branch-namespaced epoch document ID & deduplication key
            branch = str(device_cfg.get("branch") or "").strip().lower()
            if not branch:
                if not hasattr(fetch_and_sync_device, "_warned_devices"):
                    fetch_and_sync_device._warned_devices = set()
                if ip not in fetch_and_sync_device._warned_devices:
                    fetch_and_sync_device._warned_devices.add(ip)
                    print(f"[CONFIG] Device '{name}' has no 'branch' set — doc IDs are not branch-namespaced and may collide across branches sharing the same private IP range. Add 'branch' to config.json.")
                doc_id = f"{ip}_{pin}_{timestamp_epoch}"
            else:
                doc_id = f"{branch}_{ip}_{pin}_{timestamp_epoch}"
            dedup_key = doc_id

            if dedup_key in synced_keys:
                continue

            synced_keys.add(dedup_key)
            new_punches_count += 1

            # Auto-enrich with employee details if mapped
            emp_info = directory.get(pin) if directory else None
            if emp_info:
                emp_name = emp_info.get("name", f"User {pin}")
                emp_id = emp_info.get("employeeId", "")
                emp_dept = emp_info.get("department", "")
                emp_branch = emp_info.get("branchId", "")
                emp_role = emp_info.get("role", "")
                is_mapped = True
            else:
                emp_name = f"Unmapped User (PIN {pin})"
                emp_id = ""
                emp_dept = ""
                emp_branch = ""
                emp_role = ""
                is_mapped = False

            punch_record = {
                "id": doc_id,
                "doc_id": doc_id,
                "pin": pin,
                "timestamp": timestamp_str,
                "timestamp_epoch": timestamp_epoch,
                "deviceIp": ip,
                "deviceName": name,
                "buildingLocation": location,
                "source": "python_zk_service",
                "syncedAt": datetime.now().isoformat(),
                "employeeName": emp_name,
                "employeeId": emp_id,
                "department": emp_dept,
                "branchId": emp_branch,
                "role": emp_role,
                "isMapped": is_mapped,
            }

            if db and time.time() >= _quota_cooldown_until:
                try:
                    db.collection("biometric_punches").document(doc_id).set(punch_record, merge=True)
                    print(f"  └─ [SYNCED] {emp_name} (PIN: {pin}) | Time: {timestamp_str} | Loc: {location}")
                except Exception as e:
                    err_str = str(e)
                    if "429" in err_str or "Quota" in err_str or "ResourceExhausted" in err_str:
                        _quota_cooldown_until = time.time() + 900
                        print(f"  └─ [OFFLINE BUFFERED] Quota reached (HTTP 429) -> safely buffered locally. Pausing Firestore writes for 15 min.")
                    else:
                        print(f"  └─ [OFFLINE BUFFERED] Firestore error: {e}")
                    all_writes_succeeded = False
                    save_offline_punch(punch_record)
            else:
                all_writes_succeeded = False
                save_offline_punch(punch_record)

        # Re-enable device
        conn.enable_device()

        # Cycle N Check: If all writes succeeded and clear_memory is enabled, set pending flag for Cycle N+1
        if clear_memory and new_punches_count > 0:
            if all_writes_succeeded:
                _pending_clears_by_ip[ip] = True
                print(f"[DEVICE] ℹ️ Flagged {name} ({ip}) for memory clear on NEXT sync cycle.")
            else:
                _pending_clears_by_ip[ip] = False
                print(f"[DEVICE] ⚠️ Not clear-flagged: Some punches were offline-buffered for {name}.")

        print(f"[DEVICE] Finished {name}: {new_punches_count} new punches synced.")

    except Exception as e:
        print(f"[DEVICE] ❌ Could not connect or sync {name} ({ip}): {e}")
        print("  └─ Isolated error: Other devices will continue syncing.")
    finally:
        if conn:
            try:
                conn.disconnect()
            except Exception:
                pass


def main():
    parser = argparse.ArgumentParser(description="ZKTeco LAN Service to Cloud Firestore Sync")
    parser.add_argument("--config", default="config.json", help="Path to config.json file")
    parser.add_argument("--once", action="store_true", help="Run sync once and exit (no continuous loop)")
    args = parser.parse_args()

    print("==========================================================")
    print("      ZKTeco LAN Standalone Service to Firestore Sync     ")
    print("==========================================================")

    config = load_config(args.config)
    creds_path = config.get("firebase_credentials_path", "serviceAccountKey.json")
    interval = config.get("sync_interval_seconds", 15)
    clear_memory = config.get("clear_memory_after_sync", False)

    db = init_firebase(creds_path)
    synced_keys = load_synced_keys()

    try:
        while True:
            # 1. Flush offline buffer if Firestore is available
            flush_offline_buffer(db)

            # 2. Iterate through all registered ZKTeco scanners
            devices = config.get("devices", [])
            for dev in devices:
                fetch_and_sync_device(dev, db, synced_keys, clear_memory=clear_memory)

            # Save state
            save_synced_keys(synced_keys)

            if args.once:
                print("\n[INFO] Single run completed. Exiting.")
                break

            print(f"\n[SLEEP] Waiting {interval} seconds until next sync cycle...")
            time.sleep(interval)

    except KeyboardInterrupt:
        print("\n[INFO] Service stopped by user.")
        save_synced_keys(synced_keys)
        sys.exit(0)


if __name__ == "__main__":
    main()
