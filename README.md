<p align="center">
  <img src="assets/logo/gmwf-1.webp" alt="GMWF Logo" width="100" />
</p>

<h1 align="center">Gulzar Madina Welfare Foundation (GMWF)</h1>

<p align="center">
  <strong>All-in-One Operations Platform for Welfare, Healthcare & Education</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Flutter-3.x-02569B.svg?style=flat-square&logo=Flutter&logoColor=white" alt="Flutter" />
  <img src="https://img.shields.io/badge/Firebase-Firestore-FFA611.svg?style=flat-square&logo=Firebase&logoColor=white" alt="Firebase" />
  <img src="https://img.shields.io/badge/Database-Hive%20Local-yellowgreen.svg?style=flat-square" alt="Hive DB" />
  <img src="https://img.shields.io/badge/Platforms-Windows%20%7C%20Android%20%7C%20Web-blue.svg?style=flat-square" alt="Platforms" />
  <img src="https://img.shields.io/badge/Version-v1.5.7-emerald.svg?style=flat-square" alt="Version" />
  <img src="https://img.shields.io/badge/Status-Production-success.svg?style=flat-square" alt="Status" />
</p>

---

## 🌟 What is GMWF?

**GMWF** is an enterprise management system designed specifically for the **Gulzar Madina Welfare Foundation**. It connects healthcare clinics, educational facilities, community welfare services, and financial accounting across multiple branches into one seamless system.

### 💡 The Offline-First Superpower
Internet connections can drop, but community service cannot stop. GMWF is built **offline-first**:
- Every branch workstation continues to work without an internet connection.
- Local computers talk directly to each other over the local office Wi-Fi/LAN (using real-time WebSockets).
- As soon as the internet reconnects, all records automatically sync safely to the cloud.

---

## 🏢 Core Modules

| Module | What It Does | Key Highlights |
|:---|:---|:---|
| 🏥 **Dispensary & Clinic** | Patient care & pharmacy | Fast patient tokens, digital doctor prescriptions (Rx), barcode search, real-time medicine stock deduction. |
| 📖 **Madrassa (Hifz & Nazra)** | Quranic education & tracking | Daily Quran logs (Sabak, Sabki, Manzil), Qaida progress (21 lessons), Ruku tracking with Para, WhatsApp reports, parent report cards. |
| 🏫 **Model School** | Primary & secondary school | Student admissions, automated fee management, exam grading, report cards, and library book loans. |
| 🍲 **Dasterkhwaan** | Community kitchen & meals | Meal token distribution, grocery pantry inventory, and daily cooking consumption logs. |
| 💳 **Donations & Finance** | Transparent financial auditing | Donation receipts (instant WhatsApp share & A5 print), expense logs, multi-tier approvals, and Excel reports. |
| ⏱️ **Biometrics & Attendance** | Staff & student check-ins | ZKTeco biometric machine integration, instant sync across branches, shift hours, and payroll records. |

---

## 👥 Who Can Do What? (User Roles)

- **Executive (Chairman / CEO / HQ Manager)**:
  Full multi-branch visibility, financial approval authority, centralized settings, and student record deletion control.
- **Branch Manager**:
  Day-to-day branch supervision, staff scheduling, local expenses, and inventory requests.
- **Doctor & Dispenser**:
  Patient consultations, clinical notes, medicine distribution, and inventory tracking.
- **Madrassa Teachers & Staff**:
  Attendance, Quran memorization tracking (Hifz), reading progress (Nazra & Qaida), and parent communication.

---

## 🚀 Getting Started

### Prerequisites
- [Flutter SDK](https://flutter.dev/docs/get-started/install) (3.24+ recommended)
- Git

### Quick Setup

```bash
# 1. Clone the repository
git clone https://github.com/YourOrg/gmwf.git
cd gmwf

# 2. Install project packages
flutter pub get

# 3. Run on your desktop
flutter run -d windows
```

### Build Releases

```bash
# Windows Desktop App
flutter build windows --release

# Android App (Split APKs for smaller download)
flutter build apk --release --split-per-abi

# Web Version
flutter build web --release
```

---

## 🔒 Reliability & Security
- **Local Persistence**: Hive NoSQL DB stores critical branch data on disk instantly (<2ms response time).
- **Cloud Backup**: Firebase Firestore securely backs up branch data globally.
- **Biometric Protection**: PINs and attendance credentials operate independently on local hardware to prevent lockout during network blackouts.

---

## 📄 License & Copyright

© 2026 **Gulzar Madina Welfare Foundation (GMWF)**. All rights reserved.  
Developed exclusively for GMWF institutional operations.