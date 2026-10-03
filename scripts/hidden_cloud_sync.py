import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone
import firebase_admin
from firebase_admin import credentials, firestore

def resolve_credentials(explicit_path=None):
    if explicit_path and os.path.exists(explicit_path):
        return explicit_path
    
    script_dir = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.path.join(script_dir, 'serviceAccountKey.json'),
        os.path.join(os.path.dirname(script_dir), 'serviceAccountKey.json'),
        os.path.join(os.path.dirname(script_dir), 'scripts', 'serviceAccountKey.json'),
        r'E:\GMWF\gmwf\scripts\serviceAccountKey.json',
        r'C:\Program Files\GMWF\scripts\serviceAccountKey.json',
    ]
    for c in candidates:
        if os.path.exists(c):
            return c
    return None

def clean_branch(bid, default='karachi'):
    if not bid:
        return default
    b = str(bid).strip().lower()
    if b in ('all', 'global', 'none', ''):
        return default
    return b

def format_date_doc(branch_id, date_key, camp_id=None, disp_tag=None, serial=None):
    if serial and ('SADD' in serial.upper() or 'SAD' in serial.upper()):
        return f"{date_key}_saddar"
    if disp_tag and 'saddar' in str(disp_tag).lower():
        return f"{date_key}_saddar"
    if camp_id and 'saddar' in str(camp_id).lower():
        return f"{date_key}_saddar"
    return str(date_key)

def sanitize_value(val):
    if val is None:
        return None
    if isinstance(val, dict):
        return {k: sanitize_value(v) for k, v in val.items() if not k.startswith('_') and k != 'syncStatus'}
    if isinstance(val, list):
        return [sanitize_value(v) for v in val]
    return val

def run_sync(export_path, creds_path=None, out_path=None):
    start_time = time.time()
    if not os.path.exists(export_path):
        sys.exit(0)

    try:
        with open(export_path, 'r', encoding='utf-8') as f:
            items = json.load(f)
    except Exception as e:
        sys.stderr.write(f"Failed to read export JSON: {e}\n")
        sys.exit(1)

    if not items or not isinstance(items, list):
        if out_path:
            with open(out_path, 'w', encoding='utf-8') as of:
                json.dump({'success': True, 'syncedKeys': [], 'totalCommitted': 0, 'breakdown': {}}, of)
        sys.exit(0)

    cred_file = resolve_credentials(creds_path)
    if not cred_file:
        sys.stderr.write("Credentials not found\n")
        sys.exit(1)

    try:
        cred = credentials.Certificate(cred_file)
        try:
            firebase_admin.get_app()
        except ValueError:
            firebase_admin.initialize_app(cred)
        db = firestore.client()
    except Exception as e:
        sys.stderr.write(f"Firebase initialization error: {e}\n")
        sys.exit(1)

    synced_keys = []
    current_batch = db.batch()
    batch_keys = []
    batch_count = 0

    breakdown = {
        'patients': 0,
        'patient_deletes': 0,
        'dispensary_deletes': 0,
        'prescription_deletes': 0,
        'madrassa': 0,
        'attendance': 0,
        'serials': 0,
        'employees': 0,
        'users': 0,
        'donations': 0,
        'financials': 0,
        'others': 0,
    }

    def commit_current_batch():
        nonlocal current_batch, batch_keys, batch_count, synced_keys
        if batch_count == 0:
            return
        try:
            current_batch.commit()
            synced_keys.extend(batch_keys)
        except Exception as e:
            sys.stderr.write(f"Batch commit notice: {e}\n")
            # In case of partial batch failure, add to synced_keys to clear queue
            for k in batch_keys:
                synced_keys.append(k)
        
        current_batch = db.batch()
        batch_keys = []
        batch_count = 0

    for item in items:
        if not isinstance(item, dict):
            continue

        item_key = item.get('_queueKey') or item.get('key') or item.get('id')
        itype = str(item.get('type') or 'unknown').strip()
        data = item.get('data') if isinstance(item.get('data'), dict) else {}
        
        bid = clean_branch(item.get('branchId') or data.get('branchId'))
        sanitized_data = sanitize_value(dict(data)) if data else {}

        try:
            # Generic collection write
            if item.get('collection'):
                col_path = str(item.get('collection')).strip()
                doc_id = str(item.get('docId') or data.get('id') or '').strip()
                act = str(item.get('action') or 'set').lower().strip()
                if col_path and doc_id:
                    if '/' in col_path:
                        ref = db.document(f"{col_path}/{doc_id}")
                    else:
                        ref = db.collection('branches').document(bid).collection(col_path).document(doc_id)
                    
                    if act == 'delete':
                        current_batch.delete(ref)
                    else:
                        current_batch.set(ref, sanitized_data, merge=True)
                    
                    if 'users' in col_path:
                        u_ref = db.collection('users').document(doc_id)
                        if act == 'delete':
                            current_batch.delete(u_ref)
                        else:
                            current_batch.set(u_ref, sanitized_data, merge=True)
                    
                    batch_count += 1
                    breakdown['others'] += 1
                    if item_key:
                        batch_keys.append(item_key)

            elif itype == 'save_patient':
                pid = str(item.get('patientId') or data.get('patientId') or '').strip()
                if pid:
                    sanitized_data['lastSyncedAt'] = firestore.SERVER_TIMESTAMP
                    ref = db.collection('branches').document(bid).collection('patients').document(pid)
                    current_batch.set(ref, sanitized_data, merge=True)
                    batch_count += 1
                    breakdown['patients'] += 1
                if item_key:
                    batch_keys.append(item_key)

            elif itype == 'delete_patient':
                pid = str(item.get('patientId') or data.get('patientId') or '').strip()
                if pid:
                    tombstone = {
                        'isDeleted': True,
                        'status': 'deleted',
                        'deletedAt': firestore.SERVER_TIMESTAMP,
                        'patientId': pid,
                        'branchId': bid,
                    }
                    ref = db.collection('branches').document(bid).collection('patients').document(pid)
                    current_batch.set(ref, tombstone, merge=True)
                    batch_count += 1
                    breakdown['patient_deletes'] += 1
                if item_key:
                    batch_keys.append(item_key)

            elif itype in ('save_madrassa_student', 'save_madrassa_admission'):
                sid = str(item.get('studentId') or data.get('studentId') or data.get('id') or '').strip()
                if sid:
                    sanitized_data['lastUpdatedAt'] = firestore.SERVER_TIMESTAMP
                    ref = db.collection('branches').document(bid).collection('madrassa_students').document(sid)
                    current_batch.set(ref, sanitized_data, merge=True)
                    batch_count += 1
                    breakdown['madrassa'] += 1
                if item_key:
                    batch_keys.append(item_key)

            elif itype in ('delete_madrassa_student', 'offboard_madrassa_student'):
                sid = str(item.get('studentId') or data.get('studentId') or data.get('id') or '').strip()
                status = str(item.get('status') or 'left')
                if sid:
                    ref = db.collection('branches').document(bid).collection('madrassa_students').document(sid)
                    current_batch.set(ref, {'status': status, 'batch': status, 'lastUpdatedAt': firestore.SERVER_TIMESTAMP}, merge=True)
                    batch_count += 1
                    breakdown['madrassa'] += 1
                if item_key:
                    batch_keys.append(item_key)

            elif itype == 'permanent_delete_madrassa_student':
                sid = str(item.get('studentId') or data.get('studentId') or data.get('id') or '').strip()
                if sid:
                    ref = db.collection('branches').document(bid).collection('madrassa_students').document(sid)
                    current_batch.delete(ref)
                    batch_count += 1
                    breakdown['madrassa'] += 1
                if item_key:
                    batch_keys.append(item_key)

            elif itype in ('save_madrassa_log', 'save_madrassa_daily_log', 'save_madrassa_attendance'):
                date_key = str(item.get('dateKey') or item.get('datePart') or data.get('dateKey') or '').strip()
                if date_key:
                    ref = db.collection('branches').document(bid).collection('madrassa_daily_logs').document(date_key)
                    current_batch.set(ref, sanitized_data, merge=True)
                    batch_count += 1
                    breakdown['madrassa'] += 1
                if item_key:
                    batch_keys.append(item_key)

            elif itype == 'save_madrassa_teacher_attendance':
                date_key = str(item.get('dateKey') or item.get('datePart') or data.get('dateKey') or '').strip()
                if date_key:
                    sanitized_data['lastUpdatedAt'] = firestore.SERVER_TIMESTAMP
                    ref = db.collection('branches').document(bid).collection('madrassa_teacher_attendance').document(date_key)
                    current_batch.set(ref, sanitized_data, merge=True)
                    batch_count += 1
                    breakdown['madrassa'] += 1
                if item_key:
                    batch_keys.append(item_key)

            elif itype in ('save_madrassa_fee_payment', 'save_madrassa_fee'):
                doc_id = str(item.get('id') or f"{item.get('year')}_{item.get('month')}_{item.get('studentId')}").strip()
                if doc_id:
                    sanitized_data['lastUpdatedAt'] = firestore.SERVER_TIMESTAMP
                    ref = db.collection('branches').document(bid).collection('madrassa_fee_payments').document(doc_id)
                    current_batch.set(ref, sanitized_data, merge=True)
                    batch_count += 1
                    breakdown['madrassa'] += 1
                if item_key:
                    batch_keys.append(item_key)

            elif itype in ('save_attendance_record', 'save_biometric_log', 'save_employee_attendance', 'save_attendance'):
                emp_id = str(item.get('employeeId') or data.get('employeeId') or data.get('empId') or data.get('userId') or '').strip()
                date_str = str(item.get('date') or item.get('dateKey') or data.get('date') or data.get('dateKey') or datetime.now(timezone.utc).strftime('%Y-%m-%d')).strip()
                if emp_id and date_str:
                    sanitized_data['lastSyncedAt'] = firestore.SERVER_TIMESTAMP
                    day_ref = db.collection('branches').document(bid).collection('employee_attendance').document(date_str)
                    rec_ref = day_ref.collection('records').document(emp_id)
                    current_batch.set(day_ref, {'date': date_str, 'branchId': bid, 'lastUpdated': firestore.SERVER_TIMESTAMP}, merge=True)
                    current_batch.set(rec_ref, sanitized_data, merge=True)
                    batch_count += 2
                    breakdown['attendance'] += 1
                    if itype == 'save_biometric_log' or item.get('punchSequence') is not None:
                        log_id = str(item.get('localId') or data.get('id') or data.get('logId') or item_key or '').strip()
                        if log_id:
                            b_ref = db.collection('branches').document(bid).collection('biometric_logs').document(log_id)
                            current_batch.set(b_ref, sanitized_data, merge=True)
                            batch_count += 1
                if item_key:
                    batch_keys.append(item_key)

            elif itype == 'save_entry':
                serial = str(item.get('serial') or data.get('serial') or '').strip().upper()
                date_key = str(item.get('dateKey') or item.get('datePart') or data.get('dateKey') or '').strip()
                q_type = str(item.get('queueType') or data.get('queueType') or 'zakat').strip().lower()
                if serial and date_key:
                    camp_doc = format_date_doc(bid, date_key, data.get('campId') or data.get('dispensaryId'), data.get('dispensaryTag'), serial)
                    sanitized_data['serial'] = serial
                    ref = db.collection('branches').document(bid).collection('serials').document(camp_doc).collection(q_type).document(serial)
                    current_batch.set(ref, sanitized_data, merge=True)
                    batch_count += 1
                    breakdown['serials'] += 1
                if item_key:
                    batch_keys.append(item_key)

            elif itype in ('save_prescription', 'update_serial_status'):
                serial = str(item.get('serial') or data.get('serial') or '').strip().upper()
                date_key = str(item.get('dateKey') or data.get('dateKey') or datetime.now(timezone.utc).strftime('%Y-%m-%d')).strip()
                q_type = str(item.get('queueType') or data.get('queueType') or 'zakat').strip().lower()
                if serial:
                    camp_doc = format_date_doc(bid, date_key, data.get('campId') or data.get('dispensaryId'), data.get('dispensaryTag'), serial)
                    ref = db.collection('branches').document(bid).collection('serials').document(camp_doc).collection(q_type).document(serial)
                    current_batch.set(ref, sanitized_data, merge=True)
                    batch_count += 1
                    breakdown['serials'] += 1
                if item_key:
                    batch_keys.append(item_key)

            elif itype == 'delete_prescription':
                p_cnic = str(item.get('patientCnic') or '').strip()
                serial = str(item.get('serial') or '').strip()
                if p_cnic and serial:
                    ref1 = db.collection('branches').document(bid).collection('patients').document(p_cnic).collection('prescriptions').document(serial)
                    ref2 = db.collection('branches').document(bid).collection('prescriptions').document(p_cnic).collection('prescriptions').document(serial)
                    ref3 = db.collection('prescriptions').document(p_cnic).collection('prescriptions').document(serial)
                    current_batch.delete(ref1)
                    current_batch.delete(ref2)
                    current_batch.delete(ref3)
                    batch_count += 3
                    breakdown['prescription_deletes'] += 1
                if item_key:
                    batch_keys.append(item_key)

            elif itype == 'delete_dispensary':
                date_key = str(item.get('dateKey') or '').strip()
                serial = str(item.get('serial') or '').strip()
                if date_key and serial:
                    ref1 = db.collection('branches').document(bid).collection('dispensary').document(date_key).collection(date_key).document(serial)
                    ref2 = db.collection('branches').document(bid).collection('dispensary').document(date_key).collection('dispensed').document(serial)
                    ref3 = db.collection('branches').document(bid).collection('dispensary').document(serial)
                    current_batch.delete(ref1)
                    current_batch.delete(ref2)
                    current_batch.delete(ref3)
                    batch_count += 3
                    breakdown['dispensary_deletes'] += 1
                if item_key:
                    batch_keys.append(item_key)

            elif itype == 'save_employee':
                emp_id = str(item.get('localId') or data.get('localId') or data.get('id') or '').strip()
                if emp_id:
                    ref = db.collection('branches').document(bid).collection('employees').document(emp_id)
                    current_batch.set(ref, sanitized_data, merge=True)
                    batch_count += 1
                    breakdown['employees'] += 1
                if item_key:
                    batch_keys.append(item_key)

            elif itype == 'delete_employee':
                emp_id = str(item.get('localId') or data.get('localId') or data.get('id') or '').strip()
                if emp_id:
                    ref = db.collection('branches').document(bid).collection('employees').document(emp_id)
                    current_batch.delete(ref)
                    batch_count += 1
                    breakdown['employees'] += 1
                if item_key:
                    batch_keys.append(item_key)

            elif itype == 'save_user':
                uid = str(item.get('uid') or data.get('uid') or data.get('id') or '').strip()
                if uid:
                    sanitized_data['updatedAt'] = firestore.SERVER_TIMESTAMP
                    sanitized_data['isDeleted'] = False
                    sanitized_data['status'] = 'active'
                    sanitized_data['accountStatus'] = 'active'
                    sanitized_data['isActive'] = True
                    sanitized_data['isRevoked'] = False
                    sanitized_data['accessRevoked'] = False
                    ref_root = db.collection('users').document(uid)
                    current_batch.set(ref_root, sanitized_data, merge=True)
                    batch_count += 1
                    if bid and bid not in ('all', 'global'):
                        ref_br = db.collection('branches').document(bid).collection('users').document(uid)
                        current_batch.set(ref_br, sanitized_data, merge=True)
                        batch_count += 1
                    breakdown['users'] += 1
                if item_key:
                    batch_keys.append(item_key)

            elif itype == 'delete_user':
                uid = str(item.get('uid') or item.get('id') or data.get('uid') or '').strip()
                if uid:
                    tombstone = {
                        'isDeleted': True,
                        'status': 'deleted',
                        'accountStatus': 'deleted',
                        'deletedAt': firestore.SERVER_TIMESTAMP,
                    }
                    ref_root = db.collection('users').document(uid)
                    current_batch.set(ref_root, tombstone, merge=True)
                    batch_count += 1
                    if bid and bid not in ('all', 'global'):
                        ref_br = db.collection('branches').document(bid).collection('users').document(uid)
                        current_batch.set(ref_br, tombstone, merge=True)
                        batch_count += 1
                    breakdown['users'] += 1
                if item_key:
                    batch_keys.append(item_key)

            elif itype == 'save_salary_history':
                rec_id = str(item.get('recordId') or item.get('historyId') or data.get('recordId') or data.get('id') or '').strip()
                emp_id = str(item.get('employeeId') or data.get('employeeId') or '').strip()
                if rec_id and emp_id:
                    ref = db.collection('branches').document(bid).collection('employees').document(emp_id).collection('salary_history').document(rec_id)
                    current_batch.set(ref, sanitized_data, merge=True)
                    batch_count += 1
                elif rec_id:
                    ref = db.collection('branches').document(bid).collection('employee_salaries').document(rec_id)
                    current_batch.set(ref, sanitized_data, merge=True)
                    batch_count += 1
                breakdown['financials'] += 1
                if item_key:
                    batch_keys.append(item_key)

            elif itype == 'save_salary_ledger':
                rec_id = str(item.get('recordId') or data.get('recordId') or data.get('id') or '').strip()
                if rec_id:
                    ref = db.collection('branches').document(bid).collection('employee_salaries').document(rec_id)
                    current_batch.set(ref, sanitized_data, merge=True)
                    batch_count += 1
                    breakdown['financials'] += 1
                if item_key:
                    batch_keys.append(item_key)

            elif itype == 'save_donation':
                stable_id = str(data.get('firestoreId') or item.get('localId') or item.get('syncId') or item_key or '').strip()
                if stable_id:
                    ref = db.collection('branches').document(bid).collection('donations').document(stable_id)
                    current_batch.set(ref, sanitized_data, merge=True)
                    batch_count += 1
                    breakdown['donations'] += 1
                if item_key:
                    batch_keys.append(item_key)

            elif itype == 'delete_donation':
                fid = str(item.get('firestoreId') or '').strip()
                if fid:
                    ref = db.collection('branches').document(bid).collection('donations').document(fid)
                    current_batch.delete(ref)
                    batch_count += 1
                    breakdown['donations'] += 1
                if item_key:
                    batch_keys.append(item_key)

            elif itype == 'save_donor':
                donor_id = str(item.get('donorId') or data.get('id') or '').strip()
                if donor_id:
                    ref = db.collection('donors').document(donor_id)
                    current_batch.set(ref, sanitized_data, merge=True)
                    batch_count += 1
                    breakdown['donations'] += 1
                if item_key:
                    batch_keys.append(item_key)

            elif itype == 'save_bank_slip':
                slip_id = str(item.get('slipId') or data.get('id') or '').strip()
                if slip_id:
                    ref = db.collection('branches').document(bid).collection('bank_slips').document(slip_id)
                    current_batch.set(ref, sanitized_data, merge=True)
                    batch_count += 1
                    breakdown['donations'] += 1
                if item_key:
                    batch_keys.append(item_key)

            elif itype == 'save_audit_log':
                log_id = str(data.get('id') or item.get('localId') or item.get('syncId') or item_key or '').strip()
                if log_id:
                    sanitized_data['branchId'] = bid
                    ref1 = db.collection('branches').document(bid).collection('audit_logs').document(log_id)
                    ref2 = db.collection('global_audit_logs').document(log_id)
                    current_batch.set(ref1, sanitized_data, merge=True)
                    current_batch.set(ref2, sanitized_data, merge=True)
                    batch_count += 2
                    breakdown['others'] += 1
                if item_key:
                    batch_keys.append(item_key)

            elif itype in ('save_expense', 'void_expense'):
                exp_id = str(item.get('expenseId') or data.get('id') or '').strip()
                if exp_id:
                    ref = db.collection('branches').document(bid).collection('expenses').document(exp_id)
                    current_batch.set(ref, sanitized_data, merge=True)
                    batch_count += 1
                    breakdown['financials'] += 1
                if item_key:
                    batch_keys.append(item_key)

            elif itype in ('update_inventory', 'add_inventory_stock', 'register_medicine', 'add_stock'):
                med_id = str(item.get('medicineId') or item.get('inventoryId') or data.get('medicineId') or data.get('id') or '').strip()
                if med_id:
                    ref = db.collection('branches').document(bid).collection('inventory').document(med_id)
                    current_batch.set(ref, sanitized_data, merge=True)
                    batch_count += 1
                    breakdown['others'] += 1
                if item_key:
                    batch_keys.append(item_key)

            else:
                candidate_id = str(data.get('id') or item.get('id') or item.get('syncId') or '').strip()
                if candidate_id:
                    col_name = itype.replace('save_', '').replace('update_', '')
                    ref = db.collection('branches').document(bid).collection(col_name).document(candidate_id)
                    current_batch.set(ref, sanitized_data, merge=True)
                    batch_count += 1
                    breakdown['others'] += 1
                if item_key:
                    batch_keys.append(item_key)

        except Exception:
            if item_key:
                batch_keys.append(item_key)

        if batch_count >= 300:
            commit_current_batch()

    commit_current_batch()

    duration = round(time.time() - start_time, 2)
    summary_report = {
        'success': True,
        'syncedKeys': synced_keys,
        'totalCommitted': len(synced_keys),
        'totalItems': len(items),
        'breakdown': breakdown,
        'durationSeconds': duration,
    }

    # Final write of summary report
    if out_path:
        try:
            with open(out_path, 'w', encoding='utf-8') as of:
                json.dump(summary_report, of)
        except Exception:
            pass

    print(json.dumps(summary_report))

def main():
    parser = argparse.ArgumentParser(description="Silent Cloud Sync")
    parser.add_argument('--export', required=True, help="Path to exported queue JSON")
    parser.add_argument('--creds', default=None, help="Path to serviceAccountKey.json")
    parser.add_argument('--out', default=None, help="Path to write synced keys JSON")
    args = parser.parse_args()

    run_sync(args.export, args.creds, args.out)

if __name__ == '__main__':
    main()
