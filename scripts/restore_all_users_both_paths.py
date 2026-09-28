import os
import firebase_admin
from firebase_admin import credentials, firestore

cred_path = os.path.join(os.path.dirname(__file__), 'serviceAccountKey.json')
if not firebase_admin._apps:
    cred = credentials.Certificate(cred_path)
    firebase_admin.initialize_app(cred)

db = firestore.client()

known_branches = ['karachi', 'gujrat', 'sialkot', 'jalalpurjattan', 'rawalpindi']

# Collect all users from all sources
all_users = {}

print("1. Fetching root /users...")
for doc in db.collection('users').stream():
    d = doc.to_dict() or {}
    uid = d.get('uid') or d.get('id') or doc.id
    if uid:
        all_users[uid] = {**d, 'uid': uid, 'id': uid}

print(f"Loaded {len(all_users)} from root.")

print("2. Fetching branch /branches/{b}/users...")
for b in known_branches:
    for doc in db.collection('branches').document(b).collection('users').stream():
        d = doc.to_dict() or {}
        uid = d.get('uid') or d.get('id') or doc.id
        if uid:
            existing = all_users.get(uid, {})
            merged = {**existing, **d, 'uid': uid, 'id': uid}
            if not merged.get('branchId') or merged['branchId'] in ['all', 'global', '']:
                merged['branchId'] = b
            all_users[uid] = merged

print(f"Total unique users after branch scan: {len(all_users)}")

# 3. Process and write back to BOTH paths
synced_count = 0
for uid, u in all_users.items():
    is_deleted = u.get('isDeleted') is True or str(u.get('status', '')).lower() == 'deleted'
    if is_deleted:
        continue

    role = str(u.get('role') or u.get('userRole') or '').strip()
    if not role or role.lower() in ['none', 'null', 'unknown', 'unassigned']:
        email = str(u.get('email') or '').lower()
        un = str(u.get('username') or '').lower()
        if 'teacher' in un or 'teacher' in email or 'teach' in email or 'neelam' in email or 'shazia' in email or 'tooba' in email:
            role = 'Madrassa Teacher'
            u['role'] = role
        elif 'guardian' in un or 'guardian' in email or u.get('studentIds'):
            role = 'Madrassa Guardian'
            u['role'] = role
        elif 'admin' in email or 'admin' in un:
            role = 'admin'
            u['role'] = role
        elif 'doctor' in email or 'doctor' in un or 'dr.' in un:
            role = 'doctor'
            u['role'] = role
        elif 'server' in email or 'server' in un:
            role = 'server'
            u['role'] = role
        else:
            continue

    branch_id = str(u.get('branchId') or '').strip().lower()
    if not branch_id or branch_id in ['all', 'global', 'none']:
        email = str(u.get('email') or '').lower()
        if '@khi.com' in email or '@saddar.com' in email or '@server.com' in email:
            branch_id = 'karachi'
        elif '@grt.com' in email:
            branch_id = 'gujrat'
        elif '@skt.com' in email:
            branch_id = 'sialkot'
        elif '@jlj.com' in email:
            branch_id = 'jalalpurjattan'
        elif '@rwp.com' in email:
            branch_id = 'rawalpindi'
        else:
            branch_id = 'karachi'

    u['branchId'] = branch_id
    u['uid'] = uid
    u['id'] = uid
    u['status'] = 'active'
    u['accountStatus'] = 'active'
    u['isActive'] = True
    u['isDeleted'] = False
    u['isRevoked'] = False
    u['accessRevoked'] = False
    u['isCorruptedOrOrphanAuth'] = False

    # Write to root /users/{uid}
    db.collection('users').document(uid).set(u, merge=True)

    # Write to branch /branches/{branchId}/users/{uid}
    if branch_id and branch_id not in ['all', 'global']:
        db.collection('branches').document(branch_id).collection('users').document(uid).set(u, merge=True)

    synced_count += 1
    print(f"[OK] Restored: {uid} | {u.get('email')} | {u.get('username')} | {role} -> /users/ and /branches/{branch_id}/users/")

print(f"\nTotal active users restored in BOTH paths: {synced_count}")
