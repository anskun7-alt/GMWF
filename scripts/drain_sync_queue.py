import json
import os
import sys
from datetime import datetime, timezone
import firebase_admin
from firebase_admin import credentials, firestore

def main():
    cred_path = os.path.join(os.path.dirname(__file__), 'serviceAccountKey.json')
    if not os.path.exists(cred_path):
        print(f"Error: Credentials not found at {cred_path}")
        sys.exit(1)

    cred = credentials.Certificate(cred_path)
    try:
        firebase_admin.get_app()
    except ValueError:
        firebase_admin.initialize_app(cred)

    db = firestore.client()

    export_path = r'C:\Users\win\.gemini\antigravity-ide\brain\8f93c25e-8604-4f85-8534-a74eedde6c37\scratch\sync_queue_export.json'
    with open(export_path, 'r', encoding='utf-8') as f:
        items = json.load(f)

    print(f"Loaded {len(items)} items from sync_queue_export.json")

    # 1. First, save target teachers (Neelam, Shazia, Tooba) & other active users
    active_users = [
        {
            'uid': 'X1HExgGevzbpAFA6SsLBUVuS1za2',
            'username': 'Neelam',
            'usernameLower': 'neelam',
            'email': 'neelam@khi.com',
            'role': 'Madrassa Teacher',
            'branchId': 'karachi',
            'status': 'active',
            'accountStatus': 'active',
            'isActive': True,
            'isDeleted': False,
            'accessRevoked': False,
            'isRevoked': False,
        },
        {
            'uid': 'daO5FtlLThWfhfbic89p94tCFnC2',
            'username': 'Shazia',
            'usernameLower': 'shazia',
            'email': 'shazia@khi.com',
            'role': 'Madrassa Teacher',
            'branchId': 'karachi',
            'status': 'active',
            'accountStatus': 'active',
            'isActive': True,
            'isDeleted': False,
            'accessRevoked': False,
            'isRevoked': False,
        },
        {
            'uid': 'Q4Sw1jzvgdWi4M95AfF0YOmQi1E2',
            'username': 'Tooba',
            'usernameLower': 'tooba',
            'email': 'tooba@khi.com',
            'role': 'Madrassa Teacher',
            'branchId': 'karachi',
            'status': 'active',
            'accountStatus': 'active',
            'isActive': True,
            'isDeleted': False,
            'accessRevoked': False,
            'isRevoked': False,
        },
        {
            'uid': 'Qfp71qt5mGcFsMLvquWEoGhZrfk2',
            'username': 'haroon',
            'usernameLower': 'haroon',
            'email': 'haroon@gujrat.com',
            'role': 'Madrassa Guardian',
            'branchId': 'gujrat',
            'status': 'active',
            'accountStatus': 'active',
            'isActive': True,
            'isDeleted': False,
            'accessRevoked': False,
            'isRevoked': False,
        }
    ]

    print("\n--- Updating Active Users in Firestore ---")
    for u in active_users:
        uid = u['uid']
        bid = u['branchId']
        u['updatedAt'] = firestore.SERVER_TIMESTAMP
        db.collection('users').document(uid).set(u, merge=True)
        if bid and bid not in ('all', 'global'):
            db.collection('branches').document(bid).collection('users').document(uid).set(u, merge=True)
        print(f"  [OK] User {u['username']} ({uid}) saved to /users and /branches/{bid}/users")

    # 2. Process other items in batches
    batch = db.batch()
    batch_count = 0
    total_committed = 0

    patients_written = 0
    students_written = 0
    attendance_written = 0
    entries_written = 0
    others_written = 0
    skipped_count = 0

    def commit_batch():
        nonlocal batch, batch_count, total_committed
        if batch_count > 0:
            batch.commit()
            total_committed += batch_count
            print(f"  Committed batch of {batch_count} writes (Total committed: {total_committed})")
            batch = db.batch()
            batch_count = 0

    for item in items:
        itype = item.get('type')
        data = item.get('data') or {}
        bid = item.get('branchId') or data.get('branchId') or 'karachi'
        if isinstance(bid, str):
            bid = bid.lower().strip()
        if not bid or bid in ('all', 'global'):
            bid = 'karachi'

        if itype == 'save_patient':
            pid = str(item.get('patientId') or data.get('patientId') or '').strip()
            if not pid:
                skipped_count += 1
                continue
            fs_data = dict(data)
            fs_data['lastSyncedAt'] = firestore.SERVER_TIMESTAMP
            ref = db.collection('branches').document(bid).collection('patients').document(pid)
            batch.set(ref, fs_data, merge=True)
            batch_count += 1
            patients_written += 1

        elif itype in ('save_madrassa_student', 'save_madrassa_admission'):
            sid = str(item.get('studentId') or data.get('studentId') or data.get('id') or '').strip()
            if not sid:
                skipped_count += 1
                continue
            fs_data = dict(data)
            fs_data['lastUpdatedAt'] = firestore.SERVER_TIMESTAMP
            ref = db.collection('branches').document(bid).collection('madrassa_students').document(sid)
            batch.set(ref, fs_data, merge=True)
            batch_count += 1
            students_written += 1

        elif itype in ('save_attendance_record', 'save_attendance', 'save_biometric_log', 'save_employee_attendance'):
            emp_id = str(item.get('employeeId') or data.get('employeeId') or data.get('empId') or '').strip()
            date_str = str(item.get('date') or item.get('dateKey') or data.get('date') or data.get('dateKey') or '').strip()
            if not emp_id or not date_str:
                skipped_count += 1
                continue
            fs_data = dict(data)
            fs_data['lastSyncedAt'] = firestore.SERVER_TIMESTAMP
            day_ref = db.collection('branches').document(bid).collection('employee_attendance').document(date_str)
            rec_ref = day_ref.collection('records').document(emp_id)
            batch.set(day_ref, {'date': date_str, 'branchId': bid, 'lastUpdated': firestore.SERVER_TIMESTAMP}, merge=True)
            batch.set(rec_ref, fs_data, merge=True)
            batch_count += 2
            attendance_written += 1

        elif itype == 'save_entry':
            serial = str(item.get('serial') or data.get('serial') or '').strip().upper()
            date_key = str(item.get('dateKey') or data.get('dateKey') or '').strip()
            q_type = str(item.get('queueType') or data.get('queueType') or 'zakat').strip().lower()
            if not serial or not date_key:
                skipped_count += 1
                continue
            camp_doc = f"{date_key}_saddar" if 'SADD' in serial else date_key
            fs_data = dict(data)
            fs_data['serial'] = serial
            ref = db.collection('branches').document(bid).collection('serials').document(camp_doc).collection(q_type).document(serial)
            batch.set(ref, fs_data, merge=True)
            batch_count += 1
            entries_written += 1

        elif itype == 'save_employee':
            emp_id = str(item.get('localId') or data.get('localId') or data.get('id') or '').strip()
            if not emp_id:
                skipped_count += 1
                continue
            fs_data = dict(data)
            ref = db.collection('branches').document(bid).collection('employees').document(emp_id)
            batch.set(ref, fs_data, merge=True)
            batch_count += 1
            others_written += 1

        elif itype == 'save_audit_log':
            log_id = str(data.get('id') or item.get('syncId') or item.get('_queueKey') or '').strip()
            if not log_id:
                skipped_count += 1
                continue
            ref1 = db.collection('branches').document(bid).collection('audit_logs').document(log_id)
            ref2 = db.collection('global_audit_logs').document(log_id)
            batch.set(ref1, data, merge=True)
            batch.set(ref2, data, merge=True)
            batch_count += 2
            others_written += 1

        elif itype == 'save_salary_history':
            rec_id = str(item.get('recordId') or data.get('recordId') or '').strip()
            if not rec_id:
                skipped_count += 1
                continue
            ref = db.collection('branches').document(bid).collection('employee_salaries').document(rec_id)
            batch.set(ref, data, merge=True)
            batch_count += 1
            others_written += 1

        else:
            skipped_count += 1

        if batch_count >= 300:
            commit_batch()

    commit_batch()

    print("\n=== Sync Drain Summary ===")
    print(f"Patients written: {patients_written}")
    print(f"Madrassa students written: {students_written}")
    print(f"Attendance records written: {attendance_written}")
    print(f"Serial entries written: {entries_written}")
    print(f"Other records written: {others_written}")
    print(f"Skipped (stale delete / no id): {skipped_count}")
    print(f"Total Firestore writes committed: {total_committed}")

if __name__ == '__main__':
    main()
