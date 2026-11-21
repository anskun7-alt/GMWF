# Jalalpur Jattan Dispensary — What Each Screen Looks Like
# جلال پور جٹاں ڈسپنسری — مختلف حالتوں میں اسکرین پر کیسا نظر آتا ہے

| Document Ref | Branch & Pool | Version | Category |
| :--- | :--- | :--- | :--- |
| **GMWF-DATA-JJ-01** | `jalalpur_jattan` | Version 2.0 (1.6.6) | **SAMPLE DATA & STATE GUIDE** |

> **Official PDF Edition:** [GMWF_Jalalpur_Jattan_Demo_Data.pdf](file:///d:/Dev/Projects/GMWF/gmwf/guides/pdf/GMWF_Jalalpur_Jattan_Demo_Data.pdf)

Pool: `jalalpur_jattan` — Use this sample to **learn the app** and to **test it**. It shows the same clinic in **3 situations**:

> یہ نمونہ بتاتا ہے کہ ایک ہی کلینک تین مختلف حالتوں میں اسکرین پر کیسا نظر آتا ہے۔

---

## 📊 The 3 Situations / تین بنیادی حالتیں

```
┌───────────────────────────┐      ┌───────────────────────────┐      ┌───────────────────────────┐
│     1 · EMPTY (خالی)      │  ──> │    2 · WORKING (جاری)     │  ──> │   3 · COMPLETED (مکمل)    │
│          0 UNITS          │      │         562 UNITS         │      │         762 UNITS         │
│  New setup, no stock yet  │      │ Patients being served     │      │ Friday audit, 0 diffs     │
└───────────────────────────┘      └───────────────────────────┘      └───────────────────────────┘
```

| Metric | 1 · EMPTY (خالی) | 2 · WORKING (جاری) | 3 · COMPLETED (مکمل) |
| :--- | :---: | :---: | :---: |
| **Units in Stock** | **0** | **562** | **762** |
| **Medicines in Catalog** | 0 | 5 | 5 |
| **Reserved Units** | 0 | **20 (Token #14)** | 0 (dispensed) |
| **Low Stock Warnings** | 0 | **1 (Brufen 400mg: 12 left)** | 0 (restocked 200 units) |
| **Near Expiry Warnings** | 0 | **1 (Septran DS: 40 days)** | 1 (prioritized in OPD) |
| **Expired & Quarantined** | 0 | **1 (Calpol Syrup: 8 bottles)** | 0 (incinerated & written off) |
| **Pending Dispenser Requests** | 0 | **1 (Amoxil Capsule edit)** | 0 (approved & applied) |
| **Physical Audit Status** | N/A | In progress / Due | **Confirmed · 0 discrepancy** |
| **Action / Screen Shows** | `+ Add First Medicine`<br>`Import Regional Catalog` | Active OPD session with warnings & reservations | Green badge:<br>`Confirmed Stock - Audited Today` |

---

## 🎨 Colour Meaning — Same on Every Screen / رنگوں کا مطلب

| Colour Badge | System Meaning | Urdu Translation |
| :--- | :--- | :--- |
| 🟢 **Green** | All good. Safe to use. | *سبز: ٹھیک ہے۔* |
| 🟡 **Amber / Yellow** | Be careful. Low stock, or running out of date soon. | *پیلا: احتیاط کریں۔ کم ہے یا جلد ختم ہونے والی ہے۔* |
| 🔴 **Red** | Stop. Expired, blocked, or zero stock. | *سرخ: رک جائیں۔ ایکسپائر یا بند ہے۔* |

---

## 💊 Real Medicine Batches (Working State) / جاری حالت: اصل بیچ ریکارڈ

This table represents the live inventory database at Jalalpur Jattan during active clinic hours:

| Medicine Name | Generic Compound | Batch No. | Expiry Date | Stock | What The Screen Shows |
| :--- | :--- | :--- | :---: | :---: | :--- |
| **Panadol 500mg** | Paracetamol | `BAT-P1-2025` | 2027-04-01 | 120 tabs | <span style="color:#1E8E4E;font-weight:bold">Active · FEFO #1</span> *(پہلے دیا جائے گا)* |
| **Panadol 500mg** | Paracetamol | `BAT-P2-2026` | 2028-01-01 | 300 tabs | <span style="color:#1565C0;font-weight:bold">Locked · FEFO #2</span> *(بیچ 1 ختم ہونے تک بند)* |
| **Amoxil 250mg** | Amoxicillin | `AMX-88-K` | 2027-08-01 | 85 caps | <span style="color:#1E8E4E;font-weight:bold">Active · Edit Pending</span> *(تبدیلی زیرِ التواء)* |
| **Brufen 400mg** | Ibuprofen | `BRF-04-A` | 2026-12-01 | 12 tabs | <span style="color:#A85F00;font-weight:bold">Low Stock Alert</span> *(کم اسٹاک وارننگ)* |
| **Septran DS** | Co-trimoxazole | `SEP-01-99` | 2027-01-01 | 45 tabs | <span style="color:#A85F00;font-weight:bold">Near Expiry · 40 days</span> *(جلد ایکسپائر)* |
| **Calpol Syrup** | Paracetamol | `CLP-09-OLD` | 2026-10-01 | 8 bottles | <span style="color:#C0272D;font-weight:bold">Expired · Quarantined</span> *(الگ شدہ — بند)* |

---

## 👥 Who Did What In This Demo / اس مثال میں کس نے کیا کیا

1. **Doctor reserves 20 Panadol for Token #14:**  
   Nobody else can dispense those 20 physical tablets while the consultation is open.  
   *(ڈاکٹر نے ٹوکن 14 کے لیے پیناڈول کی 20 گولیاں ریزرو کر دیں۔ کوئی اور نہیں دے سکتا)*
2. **Dispenser Tariq asks to correct Amoxil from Tablet to Capsule:**  
   The change sits safely in `[Pending Requests]` awaiting Branch Manager review.  
   *(ڈسپنسر طارق نے ایموکسل کو ٹیبلٹ سے کیپسول کرنے کی درخواست دی — مینیجر کی منظوری کا انتظار)*
3. **Friday evening: Dr. Hamza and Branch Manager Asif count shelves:**  
   Every physical pill matches the software count. **Result: 0 differences**.  
   *(جمعہ کی شام ڈاکٹر حمزہ اور برانچ مینیجر آصف نے شیلف گنے — نتیجہ: کوئی فرق نہیں)*

```
┌────────────────────────────────────────────────────────────────────────┐
│ ✔️ COMPLETED = EVERYTHING MATCHES                                       │
│ All audited medicines display a green tick:                            │
│ [Confirmed Stock - Audited Today]                                      │
│ The tablet, phone, and Nexus Server have the exact same numbers.       │
│                                                                        │
│ مکمل حالت میں سب ادویات پر سبز نشان ہوتا ہے اور لوکل سرور کے ساتھ ہم آہنگی ہو چکی ہوتی ہے۔ │
└────────────────────────────────────────────────────────────────────────┘
```
