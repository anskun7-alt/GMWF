# Jalalpur Jattan Dispensary Inventory — Demonstration Dataset & State Walkthrough
# جلال پور جٹاں ڈسپنسری انوینٹری — سیمپل ڈیٹا سیٹ اور کیفیت نامہ

This document provides complete, concrete sample data for the **Jalalpur Jattan Branch** (`jalalpur_jattan`) across all three operational lifecycle states. It can be used by QA testers, software developers, and branch managers during training and audits.

---

## 1. Branch Metadata / برانچ کی بنیادی معلومات
- **Branch ID (`branchId`):** `jalalpur_jattan`
- **Branch Name:** GMWF Medical Center & Maternity Clinic, Jalalpur Jattan
- **Primary Stock Pool:** `jalalpur_jattan`
- **Sub-Camp Stock Pool:** `jalalpur_jattan/flood_relief_camp_2026`
- **Primary Medical Officer:** Dr. Hamza Rafique (UID: `doc_hamza_jj`)
- **Senior Pharmacy Dispenser:** Tariq Mehmood (UID: `disp_tariq_jj`)
- **Branch Manager:** Asif Javed (UID: `bm_asif_jj`)

---

## 2. State 1: Empty State (خالی کیفیت - نئی تنصیب)

### Context:
Newly configured clinic or newly created emergency medical camp before any stock has arrived.

### UI Representation:
- **Banner / Graphic:** `GEmptyIllustration(kind: GEmptyIllustrationKind.box)`
- **Header:** `No Medicines in Stock`
- **Subtext:** `There are currently no pharmaceutical products registered in pool: jalalpur_jattan. Begin by adding stock or importing the regional formulary.`
- **Action Buttons:**
  - `[+ Add First Medicine]`
  - `[Import Regional Catalog]`

### State JSON Representation:
```json
{
  "pool": "jalalpur_jattan",
  "generatedAt": "2026-11-21T08:00:00Z",
  "totalStockUnits": 0,
  "activeCatalogCount": 0,
  "nearExpiryCount": 0,
  "expiredCount": 0,
  "pendingRequests": [],
  "items": []
}
```

---

## 3. State 2: Working / In-Progress State (روزمرہ کام کی حالت)

### Context:
Mid-day clinical session. Outpatient department (OPD) is active, multiple batches are being dispensed, reservations are active, one drug is running low, one is near expiry, and an edit request is in the approval pipeline.

### Active Catalog & Batch Inventory:

```json
[
  {
    "id": "med_panadol_500",
    "name": "Panadol 500mg",
    "formula": "Paracetamol",
    "category": "Tablet",
    "barcode": "8964000100125",
    "minSafetyStock": 100,
    "totalAvailable": 420,
    "reservedUnits": 20,
    "batches": [
      {
        "batchNumber": "BAT-P1-2025",
        "mfgDate": "2025-05-01",
        "expiryDate": "2027-04-01",
        "quantity": 120,
        "isExpired": false,
        "isNearExpiry": false
      },
      {
        "batchNumber": "BAT-P2-2026",
        "mfgDate": "2026-01-01",
        "expiryDate": "2028-01-01",
        "quantity": 300,
        "isExpired": false,
        "isNearExpiry": false
      }
    ]
  },
  {
    "id": "med_amoxil_250",
    "name": "Amoxil 250mg",
    "formula": "Amoxicillin",
    "category": "Capsule",
    "barcode": "8964000200451",
    "minSafetyStock": 50,
    "totalAvailable": 85,
    "reservedUnits": 0,
    "batches": [
      {
        "batchNumber": "AMX-88-K",
        "mfgDate": "2025-08-01",
        "expiryDate": "2027-08-01",
        "quantity": 85,
        "isExpired": false,
        "isNearExpiry": false
      }
    ]
  },
  {
    "id": "med_brufen_400",
    "name": "Brufen 400mg",
    "formula": "Ibuprofen",
    "category": "Tablet",
    "barcode": "8964000300789",
    "minSafetyStock": 60,
    "totalAvailable": 12,
    "reservedUnits": 0,
    "isLowStock": true,
    "batches": [
      {
        "batchNumber": "BRF-04-A",
        "mfgDate": "2024-11-01",
        "expiryDate": "2026-12-01",
        "quantity": 12,
        "isExpired": false,
        "isNearExpiry": false
      }
    ]
  },
  {
    "id": "med_septran_ds",
    "name": "Septran DS",
    "formula": "Co-trimoxazole",
    "category": "Tablet",
    "barcode": "8964000400112",
    "minSafetyStock": 30,
    "totalAvailable": 45,
    "reservedUnits": 0,
    "isNearExpiry": true,
    "daysToExpiry": 40,
    "batches": [
      {
        "batchNumber": "SEP-01-99",
        "mfgDate": "2024-01-01",
        "expiryDate": "2027-01-01",
        "quantity": 45,
        "isExpired": false,
        "isNearExpiry": true
      }
    ]
  },
  {
    "id": "med_calpol_syr",
    "name": "Calpol 120mg/5ml",
    "formula": "Paracetamol",
    "category": "Syrup",
    "barcode": "8964000500223",
    "minSafetyStock": 20,
    "totalAvailable": 0,
    "reservedUnits": 0,
    "isExpired": true,
    "batches": [
      {
        "batchNumber": "CLP-09-OLD",
        "mfgDate": "2023-01-01",
        "expiryDate": "2026-10-01",
        "quantity": 8,
        "isExpired": true,
        "isQuarantined": true
      }
    ]
  }
]
```

### In-Flight Pending Request (Two-Man Approval):
```json
{
  "requestId": "req_jj_20261121_001",
  "branchId": "jalalpur_jattan",
  "medicineId": "med_amoxil_250",
  "requestedBy": {
    "uid": "disp_tariq_jj",
    "name": "Tariq Mehmood",
    "role": "dispenser"
  },
  "requestedAt": "2026-11-21T10:15:30Z",
  "changes": {
    "category": {
      "old": "Tablet",
      "proposed": "Capsule"
    }
  },
  "reason": "Manufacturer carton indicates blister capsules, not compressed tablets.",
  "status": "PENDING"
}
```

---

## 4. State 3: Worked / Completed State (مکمل تصدیق شدہ کیفیت)

### Context:
End of audit cycle. The Branch Manager approved Tariq's edit request, the expired Calpol syrup was formally written off and neutralized, Brufen was restocked from the central warehouse, and a full physical shelf count was audited.

### Final Reconciliation Report:
```json
{
  "auditId": "audit_jj_20261121_reconciled",
  "branchId": "jalalpur_jattan",
  "timestamp": "2026-11-21T16:30:00Z",
  "auditors": [
    {"name": "Dr. Hamza Rafique", "role": "Medical Officer"},
    {"name": "Asif Javed", "role": "Branch Manager"}
  ],
  "summary": {
    "itemsAudited": 5,
    "perfectMatches": 5,
    "discrepancies": 0,
    "expiredDisposedUnits": 8,
    "restockedUnits": 200,
    "totalShelfUnits": 762,
    "status": "AUDITED_AND_CERTIFIED"
  },
  "movementsLogged": [
    {
      "opId": "op_jj_disp_0991",
      "type": "dispense",
      "medicine": "Panadol 500mg",
      "qty": 20,
      "token": "TK-14",
      "patient": "Rashid Minhas"
    },
    {
      "opId": "op_jj_restock_0412",
      "type": "restock",
      "medicine": "Brufen 400mg",
      "qty": 200,
      "batch": "BRF-05-B",
      "supplier": "GMWF Central Warehouse Lahore"
    },
    {
      "opId": "op_jj_writeoff_0019",
      "type": "adjust",
      "medicine": "Calpol 120mg/5ml",
      "qty": -8,
      "reason": "Expired stock disposed via pharmaceutical incineration",
      "approvedBy": "Dr. Hamza Rafique"
    }
  ]
}
```

---

## 5. Automated Seeding Snippet (Dart / Hive Mock)

This Dart code snippet can be placed in development scratch scripts or automated integration tests to instantly populate the Jalalpur Jattan state in local storage:

```dart
import 'package:hive/hive.dart';

Future<void> seedJalalpurJattanDemoState() async {
  final box = await Hive.openBox('stock_pool_jalalpur_jattan');
  await box.clear();

  final demoData = {
    'med_panadol_500': {
      'name': 'Panadol 500mg',
      'formula': 'Paracetamol',
      'category': 'Tablet',
      'barcode': '8964000100125',
      'minSafetyStock': 100,
      'batches': [
        {'batchNumber': 'BAT-P1-2025', 'qty': 120, 'expiry': '2027-04-01'},
        {'batchNumber': 'BAT-P2-2026', 'qty': 300, 'expiry': '2028-01-01'},
      ],
    },
    'med_amoxil_250': {
      'name': 'Amoxil 250mg',
      'formula': 'Amoxicillin',
      'category': 'Capsule',
      'barcode': '8964000200451',
      'minSafetyStock': 50,
      'batches': [
        {'batchNumber': 'AMX-88-K', 'qty': 85, 'expiry': '2027-08-01'},
      ],
    },
    'med_brufen_400': {
      'name': 'Brufen 400mg',
      'formula': 'Ibuprofen',
      'category': 'Tablet',
      'barcode': '8964000300789',
      'minSafetyStock': 60,
      'batches': [
        {'batchNumber': 'BRF-04-A', 'qty': 12, 'expiry': '2026-12-01'},
      ],
    },
  };

  for (final entry in demoData.entries) {
    await box.put(entry.key, entry.value);
  }
}
```
