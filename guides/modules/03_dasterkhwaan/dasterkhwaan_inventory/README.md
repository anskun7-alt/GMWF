# Dasterkhwaan Food & Kitchen Pantry Inventory — Operational Guide
# دسترخوان فوڈ و کچن پینٹری انوینٹری — آپریشنل و صارف رہنما

---

## 📑 Table of Contents / فہرست مضامین
1. [Overview & Humanitarian Mission / مشن اور نظام کا تعارف](#1-overview--humanitarian-mission)
2. [Core Kitchen Inventory Rules / کچن انوینٹری کے بنیادی قوانین](#2-core-kitchen-inventory-rules)
3. [Dasterkhwaan Stock Screen Anatomy / دسترخوان اسٹاک اسکرین کا جائزہ](#3-dasterkhwaan-stock-screen-anatomy)
4. [Step-by-Step Operational Workflows / روزمرہ آپریشنل طریقہ کار](#4-step-by-step-operational-workflows)
   - 4.1 [Adding New Charity Stock Items / نیا اشیائے خورونوش شامل کرنا](#41-adding-new-charity-stock-items)
   - 4.2 [Receiving Stock & Donations / امدادی راشن و اسٹاک وصولی](#42-receiving-stock--donations)
   - 4.3 [Cooking Meals & Ingredient Deductions / کھانا پکانا اور کچن کا اخراج](#43-cooking-meals--ingredient-deductions)
   - 4.4 [Logging Spoilage, Wastage & Leftovers / ضیاع اور بچے ہوئے کھانے کا اندراج](#44-logging-spoilage-wastage--leftovers)
5. [Role Responsibilities & Access Permissions / کردار اور اختیارات](#5-role-responsibilities--access-permissions)
6. [Jalalpur Jattan Dasterkhwaan Demonstration Scenarios / جلال پور جٹاں دسترخوان کے عملی منظرنامے](#6-jalalpur-jattan-dasterkhwaan-demonstration-scenarios)
7. [مکمل اردو رہنما (Urdu Complete Guide)](#7-مکمل-اردو-رہنما-urdu-complete-guide)

---

## 1. Overview & Humanitarian Mission

The **GMWF Dasterkhwaan Subsystem** manages the food supply chain, kitchen pantries, daily cooking batches, and beneficiary meal distribution across the foundation's charitable dining facilities.

Every grain of wheat, rice, lentil, and litre of oil donated by generous patrons is tracked with financial-grade precision to ensure zero food waste, total transparency, and reliable nutrition for underprivileged community members.

---

## 2. Core Kitchen Inventory Rules

> [!IMPORTANT]
> All kitchen supervisors and storekeepers must enforce these foundational principles:

### Rule 1: Zero-Negative Floor (اسٹاک منفی نہیں ہو سکتا)
- Stock balances cannot drop below zero.
- If the system indicates `40 kg` of Basmati Rice, the kitchen cannot record a cooking batch requiring `50 kg` until a restock receipt is confirmed.

### Rule 2: Automatic Token-Driven Serving Count
- Kitchen staff log the **ingredients consumed** and the **pots (Deghs) prepared**.
- The number of **meals served** is automatically synced from the beneficiary token scanning desk, preventing fabricated headcounts.

### Rule 3: Ingredient Deduplication
- Within a single cooking batch, the same raw ingredient cannot be selected twice.

### Rule 4: Clear Reason Categorization for Deductions
Every deduction from the pantry must be tagged with an audited reason:
- `consumed`: Used in kitchen meal preparation.
- `wasted`: Spoiled, contaminated, or damaged in transit.
- `expired`: Perishable goods that crossed safe consumption dates.
- `audit`: Physical weighing discrepancy corrections.

### Rule 5: Cloud Commit Resiliency (`commitKitchenBatch`)
- Kitchen updates use atomic batching via `CloudDb`.
- If an internet disconnect or Firestore quota constraint occurs, the system informs the user clearly and retains the uncommitted draft locally without freezing the user interface.

---

## 3. Dasterkhwaan Stock Screen Anatomy

The main interface is located at `lib/pages/dasterkhwaan/stock.dart`.

### View Modes:
1. **Stock Items View (Tab 0):**
   - Displays all registered food pantry items.
   - Shows current balance, unit of measurement, and quick increment/decrement action buttons.
   - Search bar for quick filtering of ingredients (e.g. *"Daal"*, *"Chawal"*, *"Ghee"*).
2. **Audit & Deductions Log View (Tab 1):**
   - Chronological ledger of every single receipt, kitchen consumption, and spoilage adjustment.
   - Displays timestamp, operator name, quantity changed, previous balance, and new balance.

---

## 4. Step-by-Step Operational Workflows

### 4.1 Adding New Charity Stock Items
When introducing a new raw food item into the branch pantry:
1. Click `[+ Add Item]` in the header.
2. Enter the **Item Name** (e.g., `Daal Chana Premium`, `Basmati Rice Kainat`, `Cooking Oil Dalda`).
3. Select the standard **Unit of Measure**:
   - `kg` (Kilograms - default for grains, pulses, meat, sugar)
   - `gram` (Grams - for high-value spices, saffron, cardamom)
   - `liter` (Liters - for cooking oil, milk)
   - `piece` (Individual units - eggs, pumpkins)
   - `packet` (Pre-packaged items)
   - `bundle` / `bunch` (Fresh vegetables)
   - `handi` / `plate` (Cooked units)
4. Click `[Add Item]`. The item is initialized with `0.0` balance and an immutable creation audit entry.

### 4.2 Receiving Stock & Donations
When a delivery truck arrives or a donor drops off in-kind food sacks:
1. Locate the item in the pantry list.
2. Tap the green **`[+]`** button.
3. Enter the received quantity (e.g., `250 kg`).
4. Select Reason:
   - `Stock Received / Purchased / Donated`
   - `Audit Adjustment (Count Correction)`
5. Enter vendor/donor notes (e.g., *"Donation by Haji Muhammad Akram - 5 sacks of 50kg"*).
6. Click `[Update Stock]`.

### 4.3 Cooking Meals & Ingredient Deductions (`CookDialog`)
When the kitchen staff begins preparing meals for the day:
1. Tap the `[Cook Meal]` or orange **`[-]`** button.
2. Select or verify the cooking menu:
   - Menu Title (e.g., *Chicken Biryani*, *Daal Chawal*, *Aloo Gosht*).
   - Expected Beneficiary Portions.
3. Add raw ingredients consumed:
   - Select Ingredient $\rightarrow$ Enter Quantity consumed.
4. The system validates that each ingredient does not exceed available stock.
5. Click `[Confirm & Deduct Ingredients]`.
6. Stock balances are deducted atomically, and an audit record tagged `consumed` is posted.

### 4.4 Logging Spoilage, Wastage & Leftovers
If perishable produce rots or cooked food is spoiled:
1. Tap the orange **`[-]`** button on that item.
2. Enter the spoiled quantity.
3. Select Reason: `Spoiled / Wasted / Damaged Food`.
4. In **Audit Notes**, explain the incident (e.g., *"Power outage caused freezer thaw overnight"*).
5. Click `[Confirm Deduction]`. This requires Supervisor co-signature.

---

## 5. Role Responsibilities & Access Permissions

| Role | View Stock | Receive Stock | Deduct Cooking | Log Spoilage | Create Items |
| :--- | :---: | :---: | :---: | :---: | :---: |
| **Kitchen Cook / Chef** | ✅ | ✅ | ✅ | ❌ (Needs BM) | ❌ |
| **Kitchen Storekeeper** | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Branch Manager** | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Dasterkhwaan Supervisor** | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Global Admin / HQ** | ✅ | ✅ | ✅ | ✅ | ✅ |

---

## 6. Jalalpur Jattan Dasterkhwaan Demonstration Scenarios

### Scenario A: Empty Kitchen Pantry
- Newly inaugurated Jalalpur Jattan Community Kitchen before initial food drive.
- Screen displays empty state illustration with message: *"No Charity Stock Items Found"*.
- Action: Storekeeper clicks `[+ Add Item]` to register baseline supplies.

### Scenario B: Active Cooking Session (Jalalpur Jattan Lunch Service)
- **Target Audience:** 650 local beneficiaries.
- **Menu:** Chicken Pulao + Daal Mash.
- **Pantry Level Before Cooking:**
  - `Basmati Rice`: 400 kg
  - `Chicken Broiler`: 120 kg
  - `Cooking Oil`: 85 liters
  - `Daal Mash`: 60 kg
  - `Onions & Tomatoes`: 50 kg
- **Chef Action in `CookDialog`:**
  - Deducts `80 kg` Rice, `45 kg` Chicken, `18 liters` Oil, `12 kg` Onions.
- **Immediate Outcome:**
  - System updates balances instantaneously.
  - Remaining Rice: `320 kg`.
  - Token desk registers 650 served meals without manual double-entry.

### Scenario C: Weekly Reconciled Stock Audit
- Friday evening inspection conducted by Supervisor.
- Physical weighing of rice sacks matches recorded 320 kg within 0.5% margin.
- Audit status badge displays: `Verified & Balanced`.

---

## 7. مکمل اردو رہنما (Urdu Complete Guide)

### 7.1 تعارف اور فلاحی مقصد
گلزار مدینہ ویلفیئر فاؤنڈیشن (GMWF) کے دسترخوان کا نظام مستحق اور غریب افراد کو عزت کے ساتھ معیاری کھانا فراہم کرنے کے لیے بنایا گیا ہے۔ اس انوینٹری سسٹم کا مقصد اشیائے خورونوش (چاول، آٹا، گھی، دالیں، گوشت، مصالحہ جات) کے ایک ایک دانے کا مکمل حساب کتاب رکھنا اور خوراک کے ضیاع کو روکنا ہے۔

### 7.2 دسترخوان انوینٹری کے بنیادی قوانین
1. **اسٹاک کبھی منفی (Negative) نہیں ہو سکتا:** اگر کچن کے اسٹاک میں 30 کلو چاول ہیں تو سسٹم 40 کلو کی کٹوتی ہرگز قبول نہیں کرے گا۔
2. **کھانے والوں کی خودکار گنتی:** کچن کا عملہ صرف استعمال ہونے والے راشن کا اندراج کرتا ہے؛ کھانا کھانے والے افراد کی گنتی ریسیپشن پر اسکین ہونے والے ٹوکنز سے خودکار طور پر مطابقت پذیر ہوتی ہے۔
3. **کٹوتی کی واضح وجوہات:** راشن کے اخراج کے وقت درست وجہ منتخب کرنا لازمی ہے:
   - `consumed`: کچن میں دیگیں پکانے کے لیے استعمال ہوا۔
   - `wasted`: خراب ہو گیا، ضائع ہوا یا گِر گیا۔
   - `expired`: میعاد ختم ہو جانے کے باعث ناقابلِ استعمال۔
   - `audit`: فزیکل وزن کے بعد ہونے والی تصحیح۔

### 7.3 روزمرہ کام کے مراحل

#### نیا سامان شامل کرنا (`[+ Add Item]`):
- اگر گودام میں نئی چیز آئی ہے (مثلاً سرخ لوبیا یا سفید چنے) تو `[+ Add Item]` پر کلک کریں۔
- نام لکھیں اور یونٹ منتخب کریں (`kg`, `liter`, `piece`, `packet` وغیرہ)۔

#### راشن وصول کرنا (سبز `[+]` بٹن):
- جب مخیر حضرات راشن دیں یا فاؤنڈیشن خریداری کرے تو متعلقہ جنس کے سامنے سبز رنگ کا `[+]` بٹن دبائیں۔
- مقدار درج کریں اور نوٹ میں مخیر کا نام یا بل نمبر لکھ کر `[Update Stock]` دبائیں۔

#### کھانا پکانا اور کچن کٹوتی (`CookDialog` / نارنجی `[-]` بٹن):
- روزانہ دیگ پکاتے وقت نارنجی رنگ کا `[-]` بٹن دبائیں۔
- دیگ میں ڈالے گئے اجزاء (چاول، گھی، مصالحہ، چکن) کی مقدار درج کر کے `[Confirm & Deduct]` دبائیں۔
- سسٹم فوری طور پر اسٹاک سے سامان کم کر دے گا اور باقاعدہ لیجر اندراج بن جائے گا۔

#### جلال پور جٹاں دسترخوان کی مثال:
- 600 افراد کے لیے پلاؤ تیار کیا گیا۔
- گودام سے 80 کلو باسمتی چاول، 18 لیٹر کوکنگ آئل اور 45 کلو مرغی کٹوتی کے خانے میں درج کی گئی۔
- اسٹاک فوراً اپڈیٹ ہو گیا اور ریسیپشن پر ٹوکن جاری ہونے کے ساتھ ہی کھانا باحفاظت تقسیم ہو گیا۔
