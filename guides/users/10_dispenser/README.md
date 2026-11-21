# Role Guide: Pharmacy Dispenser (فارمیسی ڈسپنسر)
# GMWF Standard Operating Procedure (SOP) & Desk Manual

---

## 🎯 Role Identity & Primary Responsibilities
The **Pharmacy Dispenser** is the primary guardian of patient medication distribution at the dispensary. Dispensers ensure medications prescribed by doctors are accurately dispensed according to First-Expiry-First-Out (FEFO) standards, monitor shelf stock levels, and perform daily physical counts.

- **Assigned Desk:** Pharmacy / Dispensary Window
- **Direct Supervisor:** Branch Manager & Medical Officer (Doctor)
- **Primary Modules:**
  - [Dispensary Inventory Module](file:///d:/Dev/Projects/GMWF/gmwf/guides/modules/02_dispensary/inventory/README.md)
  - [Jalalpur Jattan Sample Data](file:///d:/Dev/Projects/GMWF/gmwf/guides/modules/02_dispensary/inventory/JALALPUR_JATTAN_SAMPLE_DATA.md)
  - Patient Dispensing Desk

---

## 📋 Daily Operational Checklist / روزمرہ کام کی فہرست

### 🌅 Morning Routine (صبح کا آغاز - 08:30 AM)
1. **Login & Branch Verification:**
   - Log into the terminal using your designated GMWF dispenser credentials.
   - Confirm the selected branch or active camp is correct (e.g. `Jalalpur Jattan`).
2. **Review Low Stock & Near Expiry Alerts:**
   - Open `[Dispensary Inventory]`.
   - Tap `[Near Expiry]` filter chip. Identify any medicine expiring within 90 days and notify the Doctor.
   - Tap `[Low Stock]` filter chip. Create a restock requisition list for any items below 20 units.
3. **Inspect Barcode Scanner & Label Printer:**
   - Test 1 scan on the USB/Bluetooth barcode reader.

### ☀️ Active Clinical Hours (اوقاتِ کار)
1. **Dispensing Medications to Patients:**
   - Receive the physical Token or digital queue number from the patient.
   - Review prescribed medicines on the screen.
   - System automatically selects the earliest-expiry batch (FEFO). Verify batch number on the physical medicine box.
   - Click `[Confirm Dispense]`. Hand medicines to patient with dosage instructions.
2. **Receiving Incoming Stock Shipments:**
   - Click `[+ Add Medicines]`.
   - **Method A:** For small deliveries, use the 3-Step Guided Wizard.
   - **Method B:** For bulk deliveries, toggle `[Express Scan Mode]` and scan barcodes continuously.
3. **Proposing Corrections (Two-Man Rule):**
   - If you notice a typo in a brand name or dosage form, click `[Edit]`.
   - Fill in the proposed change and explain the reason in `[Submit Medicine Edit Request]`.
   - Inform the Branch Manager or Doctor to approve it from `[Pending Requests]`.

### 🌇 Evening Wrap-Up & Closing (شام کا اختتام - 04:30 PM)
1. **Conduct Routine Stock Check:**
   - Open `[Stock Check]`.
   - Select 5 random medicines and count physical strips on the shelves.
   - Input physical numbers in `[Physical Count]`. Click `[Confirm Match]`.
2. **Review Activity Log:**
   - Open `[Activity Log]` to verify all dispenses and additions were properly recorded.
3. **Log Out Securely.**

---

## 🔒 Security & Authority Boundaries (اختیارات کی حدود)
- ❌ **CANNOT** directly overwrite stock counts without a logged movement.
- ❌ **CANNOT** directly alter master chemical formulas without Doctor/BM approval.
- ❌ **CANNOT** wipe branch stock pools (restricted to `admin123` high authority).
- ❌ **CANNOT** dispense expired or quarantined batches (enforced by system).
- ✅ **CAN** add stock, dispense tokens, request edits, and perform physical audit counts.

---

## 🇵🇰 مکمل اردو خلاصہ (Urdu Summary)
ڈسپنسر کا بنیادی کام ڈاکٹر کے تجویز کردہ نسخے کے مطابق مریض کو درست دوائی فراہم کرنا اور اسٹاک کا خیال رکھنا ہے۔ 
- صبح کے وقت `[Near Expiry]` اور `[Low Stock]` ٹیبز چیک کر کے کم ادویات کی فہرست بنائیں۔
- مریض کو دوائی دیتے وقت ہمیشہ سسٹم میں موجود بیچ نمبر فزیکل ڈبے سے ملائیں۔
- اگر کسی دوائی کے نام یا پیکنگ میں غلطی نظر آئے تو `[Edit]` پر کلک کر کے تصحیح کی درخواست بھیجیں؛ برانچ مینیجر یا ڈاکٹر اسے منظور کریں گے۔
- شام کو روزانہ کم از کم 5 ادویات کی فزیکل گنتی `[Stock Check]` میں لازمی مکمل کریں۔
