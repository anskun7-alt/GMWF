import os
import sys
import firebase_admin
from firebase_admin import credentials, firestore

# Force UTF-8 output
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

cred_path = os.path.join(os.path.dirname(__file__), 'serviceAccountKey.json')
if not firebase_admin._apps:
    firebase_admin.initialize_app(credentials.Certificate(cred_path))

db = firestore.client()

print('=== 1. ROOT COLLECTIONS IN FIRESTORE ===')
collections = [c.id for c in db.collections()]
print('Collections:', collections)

print('\n=== 2. APP CONTROL & LOGS ===')
if 'app_control' in collections:
    docs = list(db.collection('app_control').stream())
    for d in docs:
        print(f"app_control doc: {d.id} => {d.to_dict()}")

if 'audit_logs' in collections:
    docs = list(db.collection('audit_logs').limit(10).stream())
    print(f"audit_logs docs: {len(docs)}")
    for d in docs:
        print(f"audit_log {d.id} => {d.to_dict()}")

print('\n=== 3. RECENT ACTIVITY IN USERS COLLECTION (Filtered for Recent Versions) ===')
for u in db.collection('users').stream():
    d = u.to_dict()
    ver = d.get('appVersion') or d.get('lastDeviceInfo', {}).get('appVersion')
    last_device = d.get('lastDeviceInfo', {})
    last_seen = d.get('lastSeen')
    name = d.get('name') or d.get('username') or d.get('displayName')
    role = d.get('role')
    branch = d.get('branchId')
    email = d.get('email')
    
    # Show active users in September/October
    if last_seen and ('2026-09' in str(last_seen) or '2026-10' in str(last_seen)):
        dev_name = last_device.get('deviceName', 'N/A') if isinstance(last_device, dict) else 'N/A'
        os_info = last_device.get('os', 'N/A') if isinstance(last_device, dict) else 'N/A'
        print(f"User: {email} | Name: {name} | Role: {role} | Branch: {branch} | Ver: {ver} | Device: {dev_name} ({os_info}) | LastSeen: {last_seen}")

print('\n=== 4. CHECKING BRANCH LEVEL LOGS / DIAGNOSTICS ===')
for b in ['karachi', 'gujrat', 'talwandi', 'sialkot', 'rawalpindi']:
    subcols = [c.id for c in db.collection('branches').document(b).collections()]
    log_subcols = [c for c in subcols if any(k in c.lower() for k in ['log', 'error', 'session', 'device', 'audit', 'status', 'request'])]
    if log_subcols:
        print(f"Branch '{b}' log/request subcollections: {log_subcols}")
        for lsc in log_subcols:
            sample_docs = list(db.collection('branches').document(b).collection(lsc).limit(5).stream())
            print(f"  Branch '{b}' -> '{lsc}' has {len(sample_docs)} sample docs")
            for sd in sample_docs:
                print(f"    [{lsc}] {sd.id}: {sd.to_dict()}")
