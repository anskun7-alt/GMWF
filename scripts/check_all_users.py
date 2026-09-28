import os
import firebase_admin
from firebase_admin import credentials, firestore, auth

cred_path = os.path.join(os.path.dirname(__file__), 'serviceAccountKey.json')
if not firebase_admin._apps:
    cred = credentials.Certificate(cred_path)
    firebase_admin.initialize_app(cred)

db = firestore.client()

print('=== ALL USERS IN ROOT /users ===')
for u in db.collection('users').stream():
    d = u.to_dict()
    print(f"DocID: {u.id} | Email: {d.get('email')} | Username: {d.get('username')} | Role: {d.get('role')} | Branch: {d.get('branchId')}")

print('\n=== ALL USERS IN /branches/karachi/users ===')
for u in db.collection('branches').document('karachi').collection('users').stream():
    d = u.to_dict()
    print(f"DocID: {u.id} | Email: {d.get('email')} | Username: {d.get('username')} | Role: {d.get('role')} | Branch: {d.get('branchId')}")

print('\n=== ALL FIREBASE AUTH USERS ===')
page = auth.list_users()
for user in page.users:
    print(f"Auth UID: {user.uid} | Email: {user.email} | DisplayName: {user.display_name}")
