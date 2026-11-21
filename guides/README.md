# GMWF Comprehensive System & User Guides Directory
# ادارۂ گلزار مدینہ ویلفیئر فاؤنڈیشن - مرکزی رہنمائی دستی کتب و دستاویزات

Welcome to the central documentation and user guides repository of the **Gulzar Madina Welfare Foundation (GMWF)** Enterprise Management System.

This directory contains complete, production-grade operational manuals, screen guides, and workflow instructions for every module and user desk across all branches, camps, clinics, kitchens, and educational facilities.

> [!IMPORTANT]
> **Mandatory Bilingual Standard / لازمی دو لسانی معیار:**  
> Every guide in this repository is maintained in both **English** and **Urdu (اردو)**. Official system buttons, dialogs, and field labels are referenced in English brackets (e.g. `[Add Medicines]`, `[Stock Check]`, `[Wipe Selected Pool]`) alongside fluent Urdu explanations to ensure complete clarity for all staff members.

---

## 📥 Official Downloadable PDF Guides / ڈاؤن لوڈ کے لیے پی ڈی ایف دستاویزات

All operational guides have been compiled into publication-grade, printable PDFs with high-resolution UI screenshots, workflow diagrams, and bilingual tables:

| Document Title | Language | Category | File Link |
| :--- | :--- | :--- | :--- |
| **Dispensary Medicine Inventory Guide (English)** | English | Clinical Pharmacy | [Download PDF](file:///d:/Dev/Projects/GMWF/gmwf/guides/pdf/GMWF_Dispensary_Inventory_Guide_EN.pdf) |
| **ڈسپنسری میڈیسن انوینٹری رہنما (اردو ایڈیشن)** | اردو (RTL) | شعبہ ادویات و فارمیسی | [ڈاؤن لوڈ پی ڈی ایف](file:///d:/Dev/Projects/GMWF/gmwf/guides/pdf/GMWF_Dispensary_Inventory_Guide_UR.pdf) |
| **Jalalpur Jattan Demonstration Dataset & States** | English & اردو | QA & Testbed | [Download PDF](file:///d:/Dev/Projects/GMWF/gmwf/guides/pdf/GMWF_Jalalpur_Jattan_Demo_State_Guide.pdf) |
| **Dasterkhwaan Food & Kitchen Pantry Inventory Guide** | English & اردو | Community Kitchen | [Download PDF](file:///d:/Dev/Projects/GMWF/gmwf/guides/pdf/GMWF_Dasterkhwaan_Food_Inventory_Guide.pdf) |
| **Pharmacy Dispenser Desk SOP & Daily Checklist** | English & اردو | Role Manual (Desk) | [Download PDF](file:///d:/Dev/Projects/GMWF/gmwf/guides/pdf/GMWF_Dispenser_SOP_Desk_Manual.pdf) |

*All PDFs are stored in [`guides/pdf/`](file:///d:/Dev/Projects/GMWF/gmwf/guides/pdf/) and synchronized into their respective module/role folders.*

---

## 📁 Directory Architecture / فولڈر کا ڈھانچہ

The documentation is organized into two primary pillars:
1. **Modules Guides (`guides/modules/`)**: Deep-dive functional guides organized by subsystem (Dispensary, Office, Dasterkhwaan, Madrassa, School).
2. **User Role Guides (`guides/users/`)**: Role-specific task checklists, desk daily SOPs, and authority boundaries for all 26 system roles.

```
guides/
├── README.md                                    # Central Index & Navigation (This file)
├── pdf/                                         # ★ Central Downloadable PDF Library
│   ├── GMWF_Dispensary_Inventory_Guide_EN.pdf
│   ├── GMWF_Dispensary_Inventory_Guide_UR.pdf
│   ├── GMWF_Jalalpur_Jattan_Demo_State_Guide.pdf
│   ├── GMWF_Dasterkhwaan_Food_Inventory_Guide.pdf
│   └── GMWF_Dispenser_SOP_Desk_Manual.pdf
├── screenshots/                                 # Central Visual Media Repository
│   ├── inventory/                               # Medicine & Stock UI Screenshots
│   ├── dispensary/                              # Doctor, Token, Pharmacy UI
│   ├── office/                                  # Branches, Donations, Treasury
│   ├── dasterkhwaan/                            # Food & Kitchen Pantry UI
│   ├── madrassa/                                # Quranic Education UI
│   └── school/                                  # Academic UI
├── modules/                                     # Module-by-Module Guides
│   ├── 01_office/                               # Executive & Central Office Modules
│   ├── 02_dispensary/                           # Healthcare & Clinical Modules
│   │   ├── inventory/                           # ★ Medicine Inventory Guide & Sample Data
│   │   └── ...
│   ├── 03_dasterkhwaan/                         # Food & Community Kitchen Modules
│   │   ├── dasterkhwaan_inventory/              # ★ Food & Pantry Stock Guide
│   │   └── ...
│   ├── 04_madrassa/                             # Religious Education Modules
│   └── 05_school/                               # Formal Academic Modules
└── users/                                       # 26 User Roles Guides (SOPs & Desk Manuals)
    ├── 06_branch_manager/                       # Branch Manager Manual
    ├── 10_dispenser/                            # Pharmacy Dispenser SOP
    ├── 17_dasterkhwaan_kitchen/                 # Head Chef & Kitchen Keeper Manual
    └── ...
```

---

## 🌟 Available Modules Documentation Index

| Module Path | Core Focus | Languages | Link |
| :--- | :--- | :--- | :--- |
| `guides/modules/02_dispensary/inventory/` | Medicine Stock, FEFO Rules, Guided/Express Addition, Barcodes, Expiries, Discrepancies | English & اردو | [Dispensary Inventory Guide](file:///d:/Dev/Projects/GMWF/gmwf/guides/modules/02_dispensary/inventory/README.md) |
| `guides/modules/02_dispensary/inventory/` | Jalalpur Jattan Demonstration Dataset (Empty, Working, Worked States) | English & اردو | [Jalalpur Jattan Sample Data](file:///d:/Dev/Projects/GMWF/gmwf/guides/modules/02_dispensary/inventory/JALALPUR_JATTAN_SAMPLE_DATA.md) |
| `guides/modules/03_dasterkhwaan/dasterkhwaan_inventory/` | Kitchen Pantry, Bulk Food Grains, Daily Cooking Deductions, Spoilage Logs, Charity Rations | English & اردو | [Dasterkhwaan Stock Guide](file:///d:/Dev/Projects/GMWF/gmwf/guides/modules/03_dasterkhwaan/dasterkhwaan_inventory/README.md) |
| `guides/users/10_dispenser/` | Pharmacy Dispenser Daily SOP, OPD Routine, Two-Man Rule, Barcode Scanning | English & اردو | [Dispenser Desk Manual](file:///d:/Dev/Projects/GMWF/gmwf/guides/users/10_dispenser/README.md) |
| `guides/users/17_dasterkhwaan_kitchen/` | Kitchen Keeper Daily SOP, CookDialog Cauldrons, Spoilage Logging | English & اردو | [Kitchen Keeper Manual](file:///d:/Dev/Projects/GMWF/gmwf/guides/users/17_dasterkhwaan_kitchen/README.md) |
| `guides/users/06_branch_manager/` | Branch Manager Governance, Edit Approvals, Expiry Write-Offs, Weekly Audits | English & اردو | [Branch Manager Manual](file:///d:/Dev/Projects/GMWF/gmwf/guides/users/06_branch_manager/README.md) |
