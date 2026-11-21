# Gulzar Madina Welfare Foundation (GMWF) — Official System & User Guides
# ادارۂ گلزار مدینہ ویلفیئر فاؤنڈیشن - مرکزی رہنمائی دستی کتب و دستاویزات

Welcome to the central documentation and official guides repository of the **Gulzar Madina Welfare Foundation (GMWF)** Enterprise Management System.

This repository hosts all standardized operational manuals, daily checklists, screen walkthroughs, demonstration datasets, and the official **GMWF PDF Publishing Kit**.

> [!IMPORTANT]
> **Mandatory Bilingual Standard / لازمی دو لسانی معیار:**  
> Every guide follows the official **GMWF PDF Design Standard (`GMWF-GUIDE-DESIGN-01`)**. Every procedure is numbered, screen terms are formatted as clickable chips (`[Stock Check]`, `[Near Expiry]`, `[Express Scan Mode]`), and clear Urdu translations appear directly beneath each English action.

---

## 📥 Official Downloadable PDF Guides / ڈاؤن لوڈ کے لیے پی ڈی ایف دستاویزات

All documents below are built using the official GMWF PDF Kit and adhere strictly to the 10 Golden Rules (A4 format, zero text overflow, embedded vector icons, and native Nastaliq/Naskh typography):

| Ref Code | Document Title | Language | Pages | Direct PDF Download |
| :--- | :--- | :--- | :---: | :--- |
| **GMWF-SOP-MED-01** | **Dispensary Inventory System — How To Use It** | English | 7 | [Download PDF](file:///d:/Dev/Projects/GMWF/gmwf/guides/pdf/GMWF_Dispensary_Inventory_Guide_EN.pdf) |
| **GMWF-SOP-MED-01-UR** | **ڈسپنسری انوینٹری سسٹم — استعمال کا طریقہ (جامع اردو ایڈیشن)** | اردو (RTL) | 7 | [ڈاؤن لوڈ پی ڈی ایف](file:///d:/Dev/Projects/GMWF/gmwf/guides/pdf/GMWF_Dispensary_Inventory_Guide_UR.pdf) |
| **GMWF-DATA-JJ-01** | **Jalalpur Jattan Dispensary — What Each Screen Looks Like** | Bilingual | 3 | [Download PDF](file:///d:/Dev/Projects/GMWF/gmwf/guides/pdf/GMWF_Jalalpur_Jattan_Demo_Data.pdf) |
| **GMWF-SOP-FOOD-01** | **Dasterkhwaan Kitchen Pantry Guide** | Bilingual | 3 | [Download PDF](file:///d:/Dev/Projects/GMWF/gmwf/guides/pdf/GMWF_Dasterkhwaan_Kitchen_Guide.pdf) |
| **GMWF-SOP-ROLE-10** | **Pharmacy Dispenser — Your Daily Checklist & Desk SOP** | Bilingual | 4 | [Download PDF](file:///d:/Dev/Projects/GMWF/gmwf/guides/pdf/GMWF_Dispenser_Daily_Checklist.pdf) |
| **GMWF-GUIDE-DESIGN-01** | **GMWF PDF Design Guide & Publishing Standard** | English | 6 | [Download PDF](file:///d:/Dev/Projects/GMWF/gmwf/guides/pdf/GMWF_PDF_Design_Guide.pdf) |
| **GMWF-KIT-01** | **GMWF Official PDF Authoring Kit (ZIP)** | Python & CSS | — | [Download Kit ZIP](file:///d:/Dev/Projects/GMWF/gmwf/guides/pdf/GMWF_PDF_Kit.zip) |

*All PDFs are located in [`guides/pdf/`](file:///d:/Dev/Projects/GMWF/gmwf/guides/pdf/) and synced to their corresponding module folders.*

---

## 🎨 GMWF PDF Kit & Documentation Standard

The official design system and publishing toolkit is permanently preserved in the repository at [`guides/pdf_kit/`](file:///d:/Dev/Projects/GMWF/gmwf/guides/pdf_kit/).

### The 10 Golden Rules (خلاصہ دس سنہرے اصول)
1. **One page, one job:** One task or idea per page. Never cram multiple distinct jobs onto one sheet.
2. **One step, one action:** Start every step with an imperative verb (Open, Scan, Type, Press). Maximum 15 words.
3. **Procedures are numbered:** Always use numbered badges `(1)`, `(2)`, `(3)` or tick-boxes `[ ]`. Never explain workflows in paragraphs.
4. **Show the real screen:** Every how-to has real cropped screenshots with red numbered pins and a legend.
5. **Screen words go in chips:** Any text seen on screen is formatted as a dashed chip or button shape (e.g. `[Near Expiry]`, `[+ Add Item]`).
6. **Urdu goes directly under English:** Field documents feature English followed immediately by Urdu under each step.
7. **Colour only carries meaning:**
   - **Deep Green (`#0B3D2E`):** Headers, titles, table headings.
   - **Brand Green (`#146C43`) / OK (`#1E8E4E`):** Allowed, success, done.
   - **Amber (`#A85F00`):** Caution, low stock, near expiry.
   - **Red (`#C0272D`):** Stop, expired, blocked, danger.
   - **Blue (`#1565C0`):** Tip, reserved units.
8. **Say what to do when it goes wrong:** Every procedure with failure risks includes a red `STOP` box directing the user to the supervisor.
9. **Never print secrets:** No passwords, phone numbers, or real patient names appear in documentation (use demo names only).
10. **Nothing overflows, nothing is tiny:** Body text is at least 11 pt. Python build checks verify `overflow: []`.

### PDF Kit Architecture
```
guides/pdf_kit/
├── GMWF_PDF_Design_Guide.pdf        # Visual standard and specifications
├── GMWF_PDF_Kit.zip                 # Standalone portable distribution package
└── kit/                             # Active Python publishing framework
    ├── kit.py                       # Reusable blocks (hero, h2, steps, callout, table, quick, pflow)
    ├── style.css                    # Unified colors, measurements, and A4 print layout
    ├── new_doc_template.py          # Starter template for authoring new manuals
    ├── fonts/                       # Embedded Inter (400-800) and Noto Nastaliq Urdu (400-700)
    └── img/                         # High-res logos and annotated UI screenshots
```

---

## 📁 Directory Architecture / فولڈر کا ڈھانچہ

```
guides/
├── README.md                                    # Central Index & Overview (This file)
├── pdf/                                         # Official Published PDF Manuals & Kit Archive
│   ├── GMWF_Dispensary_Inventory_Guide_EN.pdf
│   ├── GMWF_Dispensary_Inventory_Guide_UR.pdf
│   ├── GMWF_Jalalpur_Jattan_Demo_Data.pdf
│   ├── GMWF_Dasterkhwaan_Kitchen_Guide.pdf
│   ├── GMWF_Dispenser_Daily_Checklist.pdf
│   ├── GMWF_PDF_Design_Guide.pdf
│   └── GMWF_PDF_Kit.zip
├── pdf_kit/                                     # Permanent GMWF PDF Publishing Framework
│   ├── GMWF_PDF_Design_Guide.pdf
│   ├── GMWF_PDF_Kit.zip
│   └── kit/ (kit.py, style.css, fonts, img)
├── screenshots/                                 # Central Visual Media Repository
│   ├── inventory/
│   ├── dispensary/
│   ├── office/
│   ├── dasterkhwaan/
│   ├── madrassa/
│   └── school/
├── modules/                                     # Module-by-Module Operational Guides
│   ├── 01_office/                               # Executive & Central Office Modules
│   ├── 02_dispensary/                           # Healthcare & Clinical Modules
│   │   ├── inventory/                           # ★ Medicine Inventory Guide & Sample Data
│   │   └── ...
│   ├── 03_dasterkhwaan/                         # Food & Community Kitchen Modules
│   │   ├── dasterkhwaan_inventory/              # ★ Kitchen Pantry Guide
│   │   └── ...
│   ├── 04_madrassa/                             # Religious Education Modules
│   └── 05_school/                               # Formal Academic Modules
└── users/                                       # 26 Role-Specific SOPs & Desk Manuals
    ├── 06_branch_manager/                       # Branch Manager Manual
    ├── 10_dispenser/                            # ★ Pharmacy Dispenser Daily Checklist
    ├── 17_dasterkhwaan_kitchen/                 # Head Chef & Kitchen Keeper Manual
    └── ...
```

---

## 🌟 Available Guides Index

| Module / Role Path | Focus | Link |
| :--- | :--- | :--- |
| `guides/modules/02_dispensary/inventory/` | Medicine Stock, FEFO Rules, Guided/Express Addition, Barcodes, Expiries | [Dispensary Inventory Guide](file:///d:/Dev/Projects/GMWF/gmwf/guides/modules/02_dispensary/inventory/README.md) |
| `guides/modules/02_dispensary/inventory/` | Jalalpur Jattan Demonstration Dataset (Empty, Working, Completed States) | [Jalalpur Jattan Sample Data](file:///d:/Dev/Projects/GMWF/gmwf/guides/modules/02_dispensary/inventory/JALALPUR_JATTAN_SAMPLE_DATA.md) |
| `guides/modules/03_dasterkhwaan/dasterkhwaan_inventory/` | Kitchen Pantry, 4 Rules, Cauldrons (Deghs), Reason Codes, Lunch Demo | [Dasterkhwaan Kitchen Guide](file:///d:/Dev/Projects/GMWF/gmwf/guides/modules/03_dasterkhwaan/dasterkhwaan_inventory/README.md) |
| `guides/users/10_dispenser/` | Pharmacy Dispenser Daily Checklist, 08:30 AM / OPD / 04:30 PM, DOs & DONTs | [Dispenser Daily Checklist](file:///d:/Dev/Projects/GMWF/gmwf/guides/users/10_dispenser/README.md) |
| `guides/pdf_kit/` | PDF Authoring Kit, Design Specifications, Python & CSS Source | [PDF Design Kit](file:///d:/Dev/Projects/GMWF/gmwf/guides/pdf_kit/) |
