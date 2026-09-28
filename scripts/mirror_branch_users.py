import os
import firebase_admin
from firebase_admin import credentials, firestore

cred_path = os.path.join(os.path.dirname(__file__), 'serviceAccountKey.json')
if not firebase_admin._apps:
    cred = credentials.Certificate(cred_path)
    firebase_admin.initialize_app(cred)

db = firestore.client()

branches = ['karachi', 'gujrat', 'sialkot', 'jalalpurjattan', 'rawalpindi']
count = 0

for b in branches:
    b_users = db.collection('branches').document(b).collection('users').stream()
    for u in b_users:
        d = u.to_dict()
        uid = u.id
        email = d.get('email')
        role = d.get('role')
        if not role or role == 'None':
            continue
        d['uid'] = uid
        d['id'] = uid
        d['branchId'] = b
        d['isCorruptedOrOrphanAuth'] = False
        d['status'] = 'active'
        d['accountStatus'] = 'active'
        d['isActive'] = True
        d['isDeleted'] = False
        db.collection('users').document(uid).set(d, merge=True)
        db.collection('branches').document(b).collection('users').document(uid).set(d, merge=True)
        count += 1
        print(f"Synced [{b}]: {uid} ({email} | {d.get('username')} | {role})")

print(f"\nTotal users synchronized to root /users and branches: {count}")
