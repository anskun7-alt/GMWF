// scripts/generate_pdf_guides.js
// Enterprise PDF Guide Generator for Gulzar Madina Welfare Foundation (GMWF)
// Generates publication-ready PDF manuals in English and Urdu using headless Chrome.

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const CHROME_PATH = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const ROOT_DIR = path.resolve(__dirname, '..');
const GUIDES_DIR = path.join(ROOT_DIR, 'guides');
const PDF_OUT_DIR = path.join(GUIDES_DIR, 'pdf');

if (!fs.existsSync(PDF_OUT_DIR)) {
  fs.mkdirSync(PDF_OUT_DIR, { recursive: true });
}

// Convert image to base64 Data URI
function getBase64Image(relPath) {
  const fullPath = path.isAbsolute(relPath) ? relPath : path.join(ROOT_DIR, relPath);
  if (!fs.existsSync(fullPath)) return '';
  const ext = path.extname(fullPath).toLowerCase().replace('.', '');
  const mime = ext === 'webp' ? 'image/webp' : ext === 'jpg' || ext === 'jpeg' ? 'image/jpeg' : 'image/png';
  const data = fs.readFileSync(fullPath).toString('base64');
  return `data:${mime};base64,${data}`;
}

const logoBase64 = getBase64Image('assets/logo/gmwf-1.webp');

// Screenshots
const ssOverview = getBase64Image('guides/modules/02_dispensary/inventory/screenshots/ref_med_inventory_overview.jpg');
const ssTable = getBase64Image('guides/modules/02_dispensary/inventory/screenshots/ref_medicine_table_rows.png');
const ssDone = getBase64Image('guides/modules/02_dispensary/inventory/screenshots/ref_add_medicine_done_step.jpg');
const ssEdit = getBase64Image('guides/modules/02_dispensary/inventory/screenshots/ref_edit_medicine_request_dialog.png');
const ssLogEmpty = getBase64Image('guides/modules/02_dispensary/inventory/screenshots/ref_inventory_activity_log_empty.png');
const ssReqEmpty = getBase64Image('guides/modules/02_dispensary/inventory/screenshots/ref_pending_requests_empty.png');

// Base CSS Template
function getStyles(isUrdu = false) {
  return `
    @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=Noto+Nastaliq+Urdu:wght@400;600;700&display=swap');

    @page {
      size: A4;
      margin: 14mm 14mm 16mm 14mm;
      @bottom-right {
        content: counter(page);
      }
    }

    * {
      box-sizing: border-box;
      margin: 0;
      padding: 0;
    }

    body {
      font-family: ${isUrdu ? "'Noto Nastaliq Urdu', 'Urdu Typesetting', Tahoma, sans-serif" : "'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif"};
      color: #1e293b;
      background: #ffffff;
      line-height: ${isUrdu ? '2.1' : '1.55'};
      font-size: ${isUrdu ? '13px' : '12px'};
      direction: ${isUrdu ? 'rtl' : 'ltr'};
      text-align: ${isUrdu ? 'right' : 'left'};
      -webkit-print-color-adjust: exact;
      print-color-adjust: exact;
    }

    .header-bar {
      display: flex;
      justify-content: space-between;
      align-items: center;
      border-bottom: 2px solid #0284c7;
      padding-bottom: 12px;
      margin-bottom: 18px;
    }

    .header-logo-group {
      display: flex;
      align-items: center;
      gap: 14px;
    }

    .header-logo {
      width: 50px;
      height: 50px;
      object-fit: contain;
    }

    .org-title {
      font-size: 16px;
      font-weight: 800;
      color: #0f172a;
      letter-spacing: -0.2px;
    }

    .org-subtitle {
      font-size: 11px;
      color: #64748b;
      font-weight: 500;
    }

    .meta-badge {
      text-align: ${isUrdu ? 'left' : 'right'};
      font-size: 10px;
      color: #475569;
    }

    .meta-tag {
      display: inline-block;
      background: #f1f5f9;
      color: #0284c7;
      font-weight: 700;
      padding: 3px 8px;
      border-radius: 6px;
      font-size: 10px;
      margin-top: 3px;
    }

    h1 {
      font-size: 20px;
      font-weight: 800;
      color: #0f172a;
      margin: 14px 0 8px 0;
      border-bottom: 1px solid #e2e8f0;
      padding-bottom: 6px;
    }

    h2 {
      font-size: 15px;
      font-weight: 700;
      color: #0369a1;
      margin: 18px 0 8px 0;
      display: flex;
      align-items: center;
      gap: 6px;
    }

    h3 {
      font-size: 13px;
      font-weight: 700;
      color: #334155;
      margin: 12px 0 6px 0;
    }

    p {
      margin-bottom: 10px;
      color: #334155;
    }

    ul, ol {
      margin: 8px 0 12px 20px;
      padding-right: ${isUrdu ? '20px' : '0'};
      padding-left: ${isUrdu ? '0' : '20px'};
    }

    li {
      margin-bottom: 6px;
    }

    .alert {
      padding: 10px 14px;
      border-radius: 8px;
      margin: 12px 0;
      font-size: 11.5px;
      line-height: ${isUrdu ? '2.0' : '1.5'};
    }

    .alert-info {
      background: #f0f9ff;
      border-left: ${isUrdu ? 'none' : '4px solid #0284c7'};
      border-right: ${isUrdu ? '4px solid #0284c7' : 'none'};
      color: #0369a1;
    }

    .alert-warning {
      background: #fffbeb;
      border-left: ${isUrdu ? 'none' : '4px solid #d97706'};
      border-right: ${isUrdu ? '4px solid #d97706' : 'none'};
      color: #b45309;
    }

    .alert-danger {
      background: #fef2f2;
      border-left: ${isUrdu ? 'none' : '4px solid #dc2626'};
      border-right: ${isUrdu ? '4px solid #dc2626' : 'none'};
      color: #b91c1c;
    }

    .alert-success {
      background: #f0fdf4;
      border-left: ${isUrdu ? 'none' : '4px solid #16a34a'};
      border-right: ${isUrdu ? '4px solid #16a34a' : 'none'};
      color: #15803d;
    }

    table {
      width: 100%;
      border-collapse: collapse;
      margin: 12px 0 16px 0;
      font-size: 11px;
    }

    th {
      background: #f8fafc;
      color: #1e293b;
      font-weight: 700;
      padding: 7px 10px;
      border: 1px solid #cbd5e1;
      text-align: ${isUrdu ? 'right' : 'left'};
    }

    td {
      padding: 6px 10px;
      border: 1px solid #e2e8f0;
      color: #334155;
    }

    tr:nth-child(even) td {
      background: #fdfdfe;
    }

    .badge {
      display: inline-block;
      padding: 2px 7px;
      border-radius: 9999px;
      font-size: 9.5px;
      font-weight: 700;
    }

    .badge-green { background: #dcfce7; color: #15803d; }
    .badge-yellow { background: #fef3c7; color: #b45309; }
    .badge-red { background: #fee2e2; color: #b91c1c; }
    .badge-blue { background: #e0f2fe; color: #0369a1; }
    .badge-gray { background: #f1f5f9; color: #475569; }

    .btn-ref {
      display: inline-block;
      background: #e2e8f0;
      color: #0f172a;
      padding: 1px 6px;
      border-radius: 4px;
      font-family: monospace;
      font-weight: 700;
      font-size: 10px;
      direction: ltr !important;
    }

    .screenshot-card {
      margin: 12px 0 18px 0;
      border: 1px solid #cbd5e1;
      border-radius: 8px;
      overflow: hidden;
      background: #fafafa;
      box-shadow: 0 1px 3px rgba(0,0,0,0.05);
      page-break-inside: avoid;
    }

    .screenshot-img {
      width: 100%;
      display: block;
      max-height: 250px;
      object-fit: contain;
      background: #fff;
    }

    .screenshot-caption {
      padding: 6px 12px;
      background: #f8fafc;
      border-top: 1px solid #e2e8f0;
      font-size: 10px;
      color: #64748b;
      font-weight: 600;
      text-align: center;
    }

    .grid-2 {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 12px;
      margin: 10px 0;
      page-break-inside: avoid;
    }

    .card {
      border: 1px solid #e2e8f0;
      border-radius: 8px;
      padding: 12px;
      background: #ffffff;
      page-break-inside: avoid;
    }

    .card-title {
      font-weight: 700;
      font-size: 12px;
      color: #0369a1;
      margin-bottom: 6px;
    }

    .page-break {
      page-break-after: always;
    }

    .footer {
      position: fixed;
      bottom: 0;
      left: 0;
      right: 0;
      font-size: 9px;
      color: #94a3b8;
      display: flex;
      justify-content: space-between;
      border-top: 1px solid #e2e8f0;
      padding-top: 4px;
    }
  `;
}

// Chrome headless execution
function renderPdf(htmlContent, outputPath) {
  const tempHtml = path.join(PDF_OUT_DIR, `temp_${Date.now()}_${Math.random().toString(36).substring(7)}.html`);
  fs.writeFileSync(tempHtml, htmlContent, 'utf8');

  try {
    execFileSync(CHROME_PATH, [
      '--headless=new',
      '--disable-gpu',
      '--no-pdf-header-footer',
      `--print-to-pdf=${outputPath}`,
      tempHtml
    ], { stdio: 'ignore' });
    console.log(`[OK] Generated: ${path.basename(outputPath)} (${(fs.statSync(outputPath).size / 1024).toFixed(1)} KB)`);
  } catch (err) {
    console.error(`[ERR] Failed generating ${outputPath}:`, err.message);
  } finally {
    if (fs.existsSync(tempHtml)) fs.unlinkSync(tempHtml);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. ENGLISH DISPENSARY INVENTORY PDF
// ─────────────────────────────────────────────────────────────────────────────
function generateDispensaryInventoryPdfEN() {
  const html = `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>GMWF Dispensary Inventory System Guide</title>
  <style>${getStyles(false)}</style>
</head>
<body>
  <div class="header-bar">
    <div class="header-logo-group">
      <img src="${logoBase64}" class="header-logo" alt="GMWF Logo">
      <div>
        <div class="org-title">Gulzar Madina Welfare Foundation</div>
        <div class="org-subtitle">Healthcare & Medical Operations Management</div>
      </div>
    </div>
    <div class="meta-badge">
      <div>Document Ref: <strong>GMWF-SOP-MED-01</strong></div>
      <div>Effective: November 2026 | Version 2.4</div>
      <div class="meta-tag">OFFICIAL OPERATIONAL GUIDE</div>
    </div>
  </div>

  <h1>Dispensary Medicine Inventory System — Operational Guide</h1>
  <p>The GMWF Dispensary Inventory Subsystem is a pharmaceutical management engine designed for foundation clinics, medical camps, and regional distribution centers. It enforces offline-first synchronization, First-Expiry-First-Out (FEFO) dispensing, and audited stock transactions.</p>

  <div class="alert alert-info">
    <strong>Core Architectural Principle:</strong> Standalone clinics utilize a single branch stock pool (<span class="btn-ref">jalalpur_jattan</span>). When establishing field camps, each camp maintains an isolated stock pool (<span class="btn-ref">jalalpur_jattan/flood_relief</span>). Cross-pool dispensing is prohibited without an explicit logged transfer.
  </div>

  <h2>1. Non-Negotiable Core Inventory Rules</h2>
  <ul>
    <li><strong>Rule 1: Immutable Movement Logging (OpId):</strong> Absolute database overwrites of quantities are strictly prohibited. Every stock change must be recorded via a <span class="btn-ref">StockMovement</span> (<span class="btn-ref">restock</span>, <span class="btn-ref">dispense</span>, <span class="btn-ref">count</span>, or <span class="btn-ref">adjust</span>) with a unique cryptographic OpId.</li>
    <li><strong>Rule 2: First-Expiry-First-Out (FEFO):</strong> The oldest non-expired batch is served automatically. Subsequent batches are locked from dispensing until the earliest batch is depleted.</li>
    <li><strong>Rule 3: Expiry Date Standards:</strong> All expiry dates normalize to the first of the month (<span class="btn-ref">YYYY-MM-01</span>) and must be strictly in a future month. Present or past month registrations are rejected.</li>
    <li><strong>Rule 4: Zero-Floor & Consultation Reservation:</strong> Stock cannot drop below zero. When a doctor prescribes medication, the quantity is placed in <span class="btn-ref">Reserved</span> status to prevent double-dispensing.</li>
    <li><strong>Rule 5: Two-Man Rule for Dispensers:</strong> Dispensers cannot modify medicine formulas or brand names directly. Clicking <span class="btn-ref">[Edit]</span> creates a proposal in <span class="btn-ref">[Pending Requests]</span> requiring Doctor, Branch Manager, or Supervisor approval.</li>
    <li><strong>Rule 6: Higher Authority Password Gating:</strong> Master pool wipe operations require administrative privileges and the security override password: <span class="btn-ref">admin123</span>.</li>
  </ul>

  <div class="screenshot-card">
    <img src="${ssOverview}" class="screenshot-img" alt="Inventory Overview">
    <div class="screenshot-caption">Figure 1.1: Dispensary Inventory Dashboard with Search Bar, Filter Chips, and Pool Selector</div>
  </div>

  <h2>2. Multiple Ways to Do Things (Operational Workflows)</h2>

  <div class="grid-2">
    <div class="card">
      <div class="card-title">Adding Stock: 3 Methods</div>
      <p><strong>Method A (Guided Wizard):</strong> Recommended for daily shipments. 3-step wizard with selection, batch verification, and receipt card.</p>
      <p><strong>Method B (Express Barcode):</strong> Continuous scanner mode. Scan carton barcode, type received count, and press Enter without mouse clicks.</p>
      <p><strong>Method C (Direct Catalog):</strong> For doctors/incharges registering brand new chemical formulas.</p>
    </div>
    <div class="card">
      <div class="card-title">Modifying Details: 2 Methods</div>
      <p><strong>Method A (Direct Edit):</strong> Available to Branch Managers and Doctors for instant typo corrections.</p>
      <p><strong>Method B (Proposed Request):</strong> Dispensers submit proposals with explanation. Moves to <span class="btn-ref">[Pending Requests]</span> for sign-off.</p>
    </div>
  </div>

  <div class="grid-2">
    <div class="card">
      <div class="card-title">Stock Audits: 2 Methods</div>
      <p><strong>Method A (Stock Check):</strong> Fast shelf count verification. Identifies items needing verification (<span class="btn-ref">Needs a count</span>).</p>
      <p><strong>Method B (Medicine Ledger):</strong> Full financial-grade transaction history showing closing balances per patient token.</p>
    </div>
    <div class="card">
      <div class="card-title">Handling Expiries: 2 Methods</div>
      <p><strong>Method A (Official Quarantine):</strong> Write off expired stock with disposal audit trail (Incineration / Return).</p>
      <p><strong>Method B (Batch Correction):</strong> Correct data-entry typos in batch expiry with supervisor approval.</p>
    </div>
  </div>

  <div class="screenshot-card">
    <img src="${ssTable}" class="screenshot-img" alt="Medicine Table">
    <div class="screenshot-caption">Figure 1.2: Medicine Inventory Table with Real-Time Stock, Batch Counts, and Status Badges</div>
  </div>

  <div class="page-break"></div>

  <h2>3. Role Authority Matrix</h2>
  <table>
    <thead>
      <tr>
        <th>Action / Capability</th>
        <th>Dispenser</th>
        <th>Receptionist</th>
        <th>Doctor</th>
        <th>Branch Manager</th>
        <th>Supervisor</th>
        <th>Admin / HQ</th>
      </tr>
    </thead>
    <tbody>
      <tr>
        <td>View Catalog & Search</td>
        <td><span class="badge badge-green">YES</span></td>
        <td><span class="badge badge-green">YES</span></td>
        <td><span class="badge badge-green">YES</span></td>
        <td><span class="badge badge-green">YES</span></td>
        <td><span class="badge badge-green">YES</span></td>
        <td><span class="badge badge-green">YES</span></td>
      </tr>
      <tr>
        <td>Add Stock (Wizard / Express)</td>
        <td><span class="badge badge-green">YES</span></td>
        <td><span class="badge badge-red">NO</span></td>
        <td><span class="badge badge-green">YES</span></td>
        <td><span class="badge badge-green">YES</span></td>
        <td><span class="badge badge-green">YES</span></td>
        <td><span class="badge badge-green">YES</span></td>
      </tr>
      <tr>
        <td>Dispense to Patient against Token</td>
        <td><span class="badge badge-green">YES</span></td>
        <td><span class="badge badge-red">NO</span></td>
        <td><span class="badge badge-red">NO</span></td>
        <td><span class="badge badge-green">YES</span></td>
        <td><span class="badge badge-green">YES</span></td>
        <td><span class="badge badge-green">YES</span></td>
      </tr>
      <tr>
        <td>Submit Medicine Edit Request</td>
        <td><span class="badge badge-green">YES</span></td>
        <td><span class="badge badge-red">NO</span></td>
        <td><span class="badge badge-green">YES</span></td>
        <td><span class="badge badge-green">YES</span></td>
        <td><span class="badge badge-green">YES</span></td>
        <td><span class="badge badge-green">YES</span></td>
      </tr>
      <tr>
        <td>Approve / Reject Edit Requests</td>
        <td><span class="badge badge-red">NO</span></td>
        <td><span class="badge badge-red">NO</span></td>
        <td><span class="badge badge-green">YES</span></td>
        <td><span class="badge badge-green">YES</span></td>
        <td><span class="badge badge-green">YES</span></td>
        <td><span class="badge badge-green">YES</span></td>
      </tr>
      <tr>
        <td>Perform Physical Stock Count</td>
        <td><span class="badge badge-green">YES</span></td>
        <td><span class="badge badge-red">NO</span></td>
        <td><span class="badge badge-green">YES</span></td>
        <td><span class="badge badge-green">YES</span></td>
        <td><span class="badge badge-green">YES</span></td>
        <td><span class="badge badge-green">YES</span></td>
      </tr>
      <tr>
        <td>Wipe Selected Pool (Password: admin123)</td>
        <td><span class="badge badge-red">NO</span></td>
        <td><span class="badge badge-red">NO</span></td>
        <td><span class="badge badge-red">NO</span></td>
        <td><span class="badge badge-red">NO</span></td>
        <td><span class="badge badge-red">NO</span></td>
        <td><span class="badge badge-green">YES</span></td>
      </tr>
    </tbody>
  </table>

  <h2>4. Jalalpur Jattan Operational Scenarios</h2>

  <div class="card" style="margin-bottom: 12px;">
    <div class="card-title">Scenario A: Empty State (New Setup / Zero Stock)</div>
    <p>Displays <span class="btn-ref">GEmptyIllustration</span> with header <em>"No Medicines in Stock"</em>. Staff are provided two immediate action buttons: <span class="btn-ref">[+ Add First Medicine]</span> and <span class="btn-ref">[Import Regional Catalog]</span>. Useful for newly deployed camp databases.</p>
  </div>

  <div class="card" style="margin-bottom: 12px;">
    <div class="card-title">Scenario B: Working / In-Progress State (Active Clinic Session)</div>
    <p>Typical mid-day clinic operation at Jalalpur Jattan:</p>
    <ul>
      <li><strong>Panadol 500mg:</strong> 420 units in stock. 20 units highlighted in light blue as <span class="badge badge-blue">Reserved</span> for Patient Token #14.</li>
      <li><strong>Brufen 400mg:</strong> 12 units remaining. Shows amber warning <span class="badge badge-yellow">Low Stock</span>.</li>
      <li><strong>Septran DS:</strong> 45 units remaining. Shows warning <span class="badge badge-yellow">Near Expiry (40 Days)</span>.</li>
      <li><strong>Calpol 120mg/5ml Syrup:</strong> 0 shelf stock. Flagged <span class="badge badge-red">Expired</span> and excluded from prescriptions.</li>
      <li><strong>Pending Request:</strong> Dispenser Tariq submitted a request to correct Amoxil dosage from Tablet to Capsule. Awaiting BM approval.</li>
    </ul>
  </div>

  <div class="card">
    <div class="card-title">Scenario C: Worked / Completed State (Reconciled Audit)</div>
    <p>Friday evening closing: Physical counts verified by Dr. Hamza and BM Asif. Discrepancy counter reads <span class="badge badge-green">0 Discrepancies</span>. All audited medicines show green checkmarks <span class="btn-ref">[Confirmed Stock - Audited Today]</span>. Database cache synchronized with Nexus Server.</p>
  </div>

  <div class="screenshot-card" style="margin-top: 14px;">
    <img src="${ssDone}" class="screenshot-img" alt="Add Medicine Completion">
    <div class="screenshot-caption">Figure 1.3: Guided Add Medicine Step 3 Summary Receipt with Projected Stock and Expiry Countdown</div>
  </div>
</body>
</html>`;

  const outPath = path.join(PDF_OUT_DIR, 'GMWF_Dispensary_Inventory_Guide_EN.pdf');
  renderPdf(html, outPath);
  fs.copyFileSync(outPath, path.join(ROOT_DIR, 'guides/modules/02_dispensary/inventory/GMWF_Dispensary_Inventory_Guide_EN.pdf'));
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. URDU DISPENSARY INVENTORY PDF (مکمل اردو رہنما)
// ─────────────────────────────────────────────────────────────────────────────
function generateDispensaryInventoryPdfUR() {
  const html = `<!DOCTYPE html>
<html dir="rtl" lang="ur">
<head>
  <meta charset="utf-8">
  <title>گلزار مدینہ ویلفیئر فاؤنڈیشن — ڈسپنسری انوینٹری رہنما</title>
  <style>${getStyles(true)}</style>
</head>
<body>
  <div class="header-bar">
    <div class="header-logo-group">
      <img src="${logoBase64}" class="header-logo" alt="GMWF Logo">
      <div>
        <div class="org-title">ادارہ گلزار مدینہ ویلفیئر فاؤنڈیشن (رجسٹرڈ)</div>
        <div class="org-subtitle">ڈسپنسری و شعبہ ادویات — مرکزی آپریشنل و تدریسی مینوئل</div>
      </div>
    </div>
    <div class="meta-badge">
      <div>دستاویز نمبر: <strong>GMWF-SOP-MED-01-UR</strong></div>
      <div>تاریخِ نفاذ: نومبر 2026ء | ورژن 2.4</div>
      <div class="meta-tag">سرکاری آپریشنل دستاویز</div>
    </div>
  </div>

  <h1>ڈسپنسری میڈیسن انوینٹری سسٹم — جامع صارف و آپریشنل رہنما</h1>
  <p>یہ دستاویز گلزار مدینہ ویلفیئر فاؤنڈیشن (GMWF) کے کلینکس، ڈسپنسریوں اور فری میڈیکل کیمپس کے عملے کے لیے تیار کی گئی ہے۔ اس کا مقصد ادویات کے اندراج، ترسیل، ایکسپائری اور فزیکل اسٹاک کی درست جانچ پڑتال کے اصولوں کو آسان اردو میں سمجھانا ہے۔</p>

  <div class="alert alert-info">
    <strong>اسٹاک پول کا بنیادی اصول:</strong> ہر عام برانچ کا ایک مرکزی اسٹاک پول ہوتا ہے جیسے (<span class="btn-ref">jalalpur_jattan</span>)۔ اگر برانچ کے تحت کوئی عارضی کیمپ لگایا جائے تو اس کا الگ پول بنتا ہے جیسے (<span class="btn-ref">jalalpur_jattan/free_camp</span>)۔ ایک پول کی دوائی دوسرے پول میں باقاعدہ ٹرانسفر کے بغیر استعمال نہیں کی جا سکتی۔
  </div>

  <h2>1. انوینٹری کے بنیادی اور سخت ترین قوانین</h2>
  <ul>
    <li><strong>قانون 1: اسٹاک میں براہ راست تبدیلی پر مکمل پابندی:</strong> کوئی بھی ڈسپنسر یا صارف ڈیٹا بیس میں موجود تعداد کو زبردستی (مثلاً 50 کی جگہ 120) نہیں بدل سکتا۔ اسٹاک کی ہر تبدیلی ایک باقاعدہ <span class="btn-ref">StockMovement</span> (<span class="btn-ref">restock</span>، <span class="btn-ref">dispense</span>، <span class="btn-ref">count</span> یا <span class="btn-ref">adjust</span>) کے ذریعے ایک مخصوص آپریشن آئی ڈی (OpId) کے ساتھ محفوظ ہوتی ہے۔</li>
    <li><strong>قانون 2: پہلے ایکسپائر، پہلے اخراج (FEFO اصول):</strong> جس بیچ کی میعاد پہلے ختم ہو رہی ہوگی، مریض کو دوائی دیتے وقت سسٹم خود بخود وہی بیچ منتخب کرے گا۔ نئے بیچ پرانے بیچ ختم ہونے تک محفوظ رہیں گے۔</li>
    <li><strong>قانون 3: ایکسپائری تاریخ کا معیار:</strong> ایکسپائری تاریخ کا اندراج ہمیشہ مہینے کی پہلی تاریخ (<span class="btn-ref">YYYY-MM-01</span>) پر ہوتا ہے اور یہ تاریخ لازمی طور پر آئندہ کے کسی مہینے کی ہونی چاہیے۔ موجودہ یا گزرے ہوئے مہینے کی دوائی کا اندراج سسٹم قبول نہیں کرے گا۔</li>
    <li><strong>قانون 4: زیرو فلور اور ٹوکن ریزرویشن:</strong> دوائی کا اسٹاک منفی میں نہیں جا سکتا۔ جب ڈاکٹر کسی مریض کے ٹوکن پر نسخہ لکھتا ہے تو دوائی کے دانے فوری طور پر <span class="btn-ref">Reserved</span> ہو جاتے ہیں تاکہ کوئی دوسرا ڈسپنسر غلطی سے وہی دانے کسی اور مریض کو نہ دے سکے۔</li>
    <li><strong>قانون 5: ڈسپنسرز کے لیے ٹو مین رول (Two-Man Rule):</strong> ڈسپنسر کسی دوائی کا نام، فارمولا یا پیکنگ براہ راست تبدیل نہیں کر سکتا۔ ڈسپنسر کا ترمیم کرنا <span class="btn-ref">[Pending Requests]</span> میں منظوری کے لیے چلا جاتا ہے جسے ڈاکٹر، برانچ مینیجر یا سپروائزر منظور کرتے ہیں۔</li>
    <li><strong>قانون 6: اعلیٰ اختیارات اور پاس ورڈ لاک:</strong> پورے پول کا اسٹاک وائپ کرنے کے لیے ایڈمن پاس ورڈ لازمی ہے: <span class="btn-ref">admin123</span>۔</li>
  </ul>

  <div class="screenshot-card">
    <img src="${ssOverview}" class="screenshot-img" alt="Inventory Overview">
    <div class="screenshot-caption">تصویر 1.1: ڈسپنسری انوینٹری کی مرکزی اسکرین — سرچ بار، فلٹر ٹیبز اور برانچ سلیکٹر</div>
  </div>

  <h2>2. کام کرنے کے مختلف طریقے (Workflows)</h2>

  <div class="grid-2">
    <div class="card">
      <div class="card-title">نیا اسٹاک شامل کرنے کے 3 طریقے</div>
      <p><strong>طریقہ الف (3 مرحلہ وزرڈ):</strong> روزانہ کی ادویات وصولی کے لیے بہترین۔ دوائی تلاش کریں، بیچ و ایکسپائری درج کریں اور رسید کارڈ دیکھ کر کنفرم کریں۔</p>
      <p><strong>طریقہ ب (ایکسپریس بارکوڈ اسکینر):</strong> اسکرین پر <span class="btn-ref">[Express Scan Mode]</span> آن کریں۔ ڈبے کا بارکوڈ اسکین کریں، تعداد لکھ کر انٹر دبائیں۔ ماؤس چھوئے بغیر فوری اندراج۔</p>
      <p><strong>طریقہ ج (ڈائریکٹ کیٹلاگ):</strong> انچارج حضرات نئی دوائی کا فارمولا اور محفوظ اسٹاک پہلے سے رجسٹر کر سکتے ہیں۔</p>
    </div>
    <div class="card">
      <div class="card-title">تفصیلات درست کرنے کے 2 طریقے</div>
      <p><strong>طریقہ الف (براہ راست ترمیم):</strong> برانچ مینیجرز اور ڈاکٹرز فوری طور پر املا یا کیٹیگری درست کر سکتے ہیں۔</p>
      <p><strong>طریقہ ب (ڈسپنسر کی درخواست):</strong> ڈسپنسر ترمیم کی وجہ لکھ کر درخواست جمع کروائے گا جو <span class="btn-ref">[Pending Requests]</span> میں چلی جائے گی۔</p>
    </div>
  </div>

  <div class="grid-2">
    <div class="card">
      <div class="card-title">اسٹاک پڑتال (آڈٹ) کے 2 طریقے</div>
      <p><strong>طریقہ الف (اسٹاک چیک رپورٹ):</strong> شیلف پر موجود گولیاں گن کر <span class="btn-ref">[Physical Count]</span> درج کریں۔ برابر ہونے پر سبز بیج لگ جاتا ہے۔</p>
      <p><strong>طریقہ ب (میڈیسن لیجر):</strong> اکاؤنٹنگ کی طرح ہر ٹوکن، مریض اور تاریخ وار ترسیل کا مکمل آڈٹ لیجر دیکھیں۔</p>
    </div>
    <div class="card">
      <div class="card-title">ایکسپائری ادویات کا تصرف</div>
      <p><strong>طریقہ الف (باقاعدہ تلفی):</strong> ایکسپائر شدہ بیچ کو الگ کر کے تصدیق شدہ طریقہ (جلانا یا سپلائر کو واپسی) کے تحت سسٹم سے خارج کریں۔</p>
      <p><strong>طریقہ ب (بیچ تصحیح):</strong> اگر اندراج کے وقت تاریخ غلط لکھی گئی ہو تو سپروائزر کی منظوری سے تصحیح کریں۔</p>
    </div>
  </div>

  <div class="page-break"></div>

  <h2>3. جلال پور جٹاں برانچ کے 3 عملی منظرنامے (Sample Scenarios)</h2>

  <div class="card" style="margin-bottom: 12px;">
    <div class="card-title">منظرنامہ 1: بالکل خالی اسٹاک (Empty State)</div>
    <p>جب نئی برانچ یا عارضی میڈیکل کیمپ کا افتتاح ہو اور ابھی دوائی درج نہ ہوئی ہو۔ اسکرین پر خوبصورت تصویر اور پیغام آتا ہے: <em>"No Medicines in Stock"</em>۔ سامنے دو بٹن ظاہر ہوتے ہیں: <span class="btn-ref">[+ Add First Medicine]</span> (پہلی دوائی درج کریں) اور <span class="btn-ref">[Import Regional Catalog]</span> (فاؤنڈیشن کی معیاری لسٹ امپورٹ کریں)۔</p>
  </div>

  <div class="card" style="margin-bottom: 12px;">
    <div class="card-title">منظرنامہ 2: عام او پی ڈی کے دوران کام کی کیفیت (Working State)</div>
    <p>جلال پور جٹاں کلینک میں صبح 11 بجے مریضوں کا رش ہے اور مختلف ادویات مختلف کیفیتوں میں ہیں:</p>
    <ul>
      <li><strong>پیناڈول (Panadol 500mg):</strong> 420 گولیاں اسٹاک میں ہیں۔ 20 گولیاں نیلے رنگ میں <span class="badge badge-blue">Reserved</span> ہیں کیونکہ وہ ڈاکٹر روم میں موجود ٹوکن نمبر 14 کے مریض کو لکھی گئی ہیں۔</li>
      <li><strong>بروفین (Brufen 400mg):</strong> صرف 12 گولیاں باقی ہیں جس پر پیلے رنگ میں <span class="badge badge-yellow">Low Stock</span> کا الرٹ آ رہا ہے۔</li>
      <li><strong>سیپٹران (Septran DS):</strong> 45 گولیاں ہیں جن کی میعاد میں 40 دن باقی ہیں۔ سسٹم نے پیلے رنگ میں <span class="badge badge-yellow">Near Expiry</span> کا بیج لگا دیا ہے۔</li>
      <li><strong>کیلیپول شربت (Calpol Syrup):</strong> اس کی ایکسپائری گزر چکی ہے، سسٹم نے اسے خودکار طریقے سے الگ (<span class="badge badge-red">Expired</span>) کر دیا ہے اور ڈاکٹر اسے نسخے میں منتخب نہیں کر سکتا۔</li>
      <li><strong>زیرِ التواء درخواست:</strong> ڈسپنسر طارق نے ایموکسل کی پیکنگ گولی سے کیپسول کرنے کی درخواست دی ہے جو مینیجر کی منظوری کی منتظر ہے۔</li>
    </ul>
  </div>

  <div class="card">
    <div class="card-title">منظرنامہ 3: مکمل تصدیق شدہ آڈٹ (Worked / Completed State)</div>
    <p>جمعہ کی شام 4 بجے ہفتہ وار آڈٹ مکمل ہو چکا ہے۔ ڈاکٹر حمزہ اور برانچ مینیجر آصف نے الماریوں کی گنتی سسٹم سے ملا لی ہے۔ کسی دوائی میں کوئی فرق نہیں ہے (<span class="badge badge-green">0 Discrepancies</span>)۔ تمام ادویات کے آگے سبز رنگ میں <span class="btn-ref">[Confirmed Stock - Audited Today]</span> لکھا آ رہا ہے۔ تمام ڈیٹا لوکل سرور اور کلاؤڈ پر محفوظ ہو چکا ہے۔</p>
  </div>

  <div class="screenshot-card" style="margin-top: 14px;">
    <img src="${ssEdit}" class="screenshot-img" alt="Dispenser Edit Request">
    <div class="screenshot-caption">تصویر 1.4: ڈسپنسر ترمیم کی درخواست کا ڈائیلاگ — تبدیلی کی وجہ لکھ کر جمع کروانے کا عمل</div>
  </div>
</body>
</html>`;

  const outPath = path.join(PDF_OUT_DIR, 'GMWF_Dispensary_Inventory_Guide_UR.pdf');
  renderPdf(html, outPath);
  fs.copyFileSync(outPath, path.join(ROOT_DIR, 'guides/modules/02_dispensary/inventory/GMWF_Dispensary_Inventory_Guide_UR.pdf'));
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. JALALPUR JATTAN DEMO & SAMPLE DATA PDF
// ─────────────────────────────────────────────────────────────────────────────
function generateJalalpurJattanDataPdf() {
  const html = `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Jalalpur Jattan Demonstration Dataset & States</title>
  <style>${getStyles(false)}</style>
</head>
<body>
  <div class="header-bar">
    <div class="header-logo-group">
      <img src="${logoBase64}" class="header-logo" alt="GMWF Logo">
      <div>
        <div class="org-title">Gulzar Madina Welfare Foundation</div>
        <div class="org-subtitle">Branch Operations & Quality Assurance Testbeds</div>
      </div>
    </div>
    <div class="meta-badge">
      <div>Document Ref: <strong>GMWF-DATA-JJ-01</strong></div>
      <div>Branch: <strong>Jalalpur Jattan (jalalpur_jattan)</strong></div>
      <div class="meta-tag">SAMPLE DATASET & STATE WALKTHROUGH</div>
    </div>
  </div>

  <h1>Jalalpur Jattan Dispensary Inventory — Demonstration Dataset</h1>
  <p>This document details the exact JSON fixtures, state machine transitions, and UI appearances across the 3 lifecycle states for <strong>Jalalpur Jattan Branch</strong> (Pool: <span class="btn-ref">jalalpur_jattan</span>).</p>

  <h2>1. State Comparison Matrix</h2>
  <table>
    <thead>
      <tr>
        <th>Indicator / Field</th>
        <th>State 1: Empty State</th>
        <th>State 2: Working / In-Progress</th>
        <th>State 3: Worked / Completed</th>
      </tr>
    </thead>
    <tbody>
      <tr>
        <td>Total Stock Units</td>
        <td><span class="badge badge-gray">0 Units</span></td>
        <td><span class="badge badge-blue">562 Units</span></td>
        <td><span class="badge badge-green">762 Units</span></td>
      </tr>
      <tr>
        <td>Active Items in Catalog</td>
        <td>0 Medicines</td>
        <td>5 Medicines</td>
        <td>5 Medicines</td>
      </tr>
      <tr>
        <td>Reserved Units</td>
        <td>0</td>
        <td><span class="badge badge-yellow">20 Units (Token #14)</span></td>
        <td>0 (Dispensed)</td>
      </tr>
      <tr>
        <td>Low Stock Warnings</td>
        <td>0</td>
        <td><span class="badge badge-yellow">1 (Brufen 400mg: 12 left)</span></td>
        <td>0 (Restocked 200 units)</td>
      </tr>
      <tr>
        <td>Near Expiry Warnings</td>
        <td>0</td>
        <td><span class="badge badge-yellow">1 (Septran DS: 40 days)</span></td>
        <td>1 (Prioritized for OPD)</td>
      </tr>
      <tr>
        <td>Expired & Quarantined</td>
        <td>0</td>
        <td><span class="badge badge-red">1 (Calpol Syrup: 8 bottles)</span></td>
        <td>0 (Incinerated & Written Off)</td>
      </tr>
      <tr>
        <td>Pending Dispenser Requests</td>
        <td>0</td>
        <td><span class="badge badge-yellow">1 (Amoxil Capsule edit)</span></td>
        <td>0 (Approved & Applied)</td>
      </tr>
      <tr>
        <td>Physical Audit Status</td>
        <td>N/A</td>
        <td>In Progress / Due</td>
        <td><span class="badge badge-green">Confirmed Match (0 Discrepancy)</span></td>
      </tr>
    </tbody>
  </table>

  <h2>2. Concrete Medicine Batch Records (Working State)</h2>
  <table>
    <thead>
      <tr>
        <th>Medicine Name</th>
        <th>Generic Formula</th>
        <th>Batch Number</th>
        <th>Expiry Date</th>
        <th>Stock Qty</th>
        <th>Status Badge</th>
      </tr>
    </thead>
    <tbody>
      <tr>
        <td><strong>Panadol 500mg</strong></td>
        <td>Paracetamol</td>
        <td>BAT-P1-2025</td>
        <td>2027-04-01</td>
        <td>120 Tabs</td>
        <td><span class="badge badge-green">Active (FEFO #1)</span></td>
      </tr>
      <tr>
        <td><strong>Panadol 500mg</strong></td>
        <td>Paracetamol</td>
        <td>BAT-P2-2026</td>
        <td>2028-01-01</td>
        <td>300 Tabs</td>
        <td><span class="badge badge-blue">Protected (FEFO #2)</span></td>
      </tr>
      <tr>
        <td><strong>Amoxil 250mg</strong></td>
        <td>Amoxicillin</td>
        <td>AMX-88-K</td>
        <td>2027-08-01</td>
        <td>85 Caps</td>
        <td><span class="badge badge-green">Active (Edit Pending)</span></td>
      </tr>
      <tr>
        <td><strong>Brufen 400mg</strong></td>
        <td>Ibuprofen</td>
        <td>BRF-04-A</td>
        <td>2026-12-01</td>
        <td>12 Tabs</td>
        <td><span class="badge badge-yellow">Low Stock Alert</span></td>
      </tr>
      <tr>
        <td><strong>Septran DS</strong></td>
        <td>Co-trimoxazole</td>
        <td>SEP-01-99</td>
        <td>2027-01-01</td>
        <td>45 Tabs</td>
        <td><span class="badge badge-yellow">Near Expiry (40 Days)</span></td>
      </tr>
      <tr>
        <td><strong>Calpol Syrup</strong></td>
        <td>Paracetamol</td>
        <td>CLP-09-OLD</td>
        <td>2026-10-01</td>
        <td>8 Bottles</td>
        <td><span class="badge badge-red">Expired (Quarantined)</span></td>
      </tr>
    </tbody>
  </table>

  <div class="screenshot-card">
    <img src="${ssReqEmpty}" class="screenshot-img" alt="Pending Requests Empty">
    <div class="screenshot-caption">Figure 2.1: Reconciled State with 0 Pending Requests and Full Synchronization</div>
  </div>

  <h2>3. اردو خلاصہ برائے جلال پور جٹاں ڈیٹا سیٹ</h2>
  <p dir="rtl" style="line-height: 2.1; font-size: 13px;">
    جلال پور جٹاں برانچ کے اس ڈیٹا سیٹ میں تینوں کیفیات کو واضح کیا گیا ہے۔ پہلی کیفیت میں جب اسٹاک خالی ہوتا ہے تو اسکرین پر <span class="btn-ref">[+ Add First Medicine]</span> ظاہر ہوتا ہے۔ دوسری کیفیت میں عام او پی ڈی کے دوران پیناڈول کی 20 گولیاں ٹوکن نمبر 14 کے لیے ریزرو ہیں، بروفین کی 12 گولیاں رہ جانے پر وارننگ ہے اور کیلیپول شربت ایکسپائر ہو کر الگ ہو چکا ہے۔ تیسری کیفیت میں جمعہ کے روز ڈاکٹر حمزہ اور برانچ مینیجر آصف نے فزیکل آڈٹ مکمل کر کے زیرو فرق (<span class="badge badge-green">0 Discrepancy</span>) کی تصدیق کر دی ہے۔
  </p>
</body>
</html>`;

  const outPath = path.join(PDF_OUT_DIR, 'GMWF_Jalalpur_Jattan_Demo_State_Guide.pdf');
  renderPdf(html, outPath);
  fs.copyFileSync(outPath, path.join(ROOT_DIR, 'guides/modules/02_dispensary/inventory/GMWF_Jalalpur_Jattan_Demo_State_Guide.pdf'));
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. DASTERKHWAAN FOOD INVENTORY PDF
// ─────────────────────────────────────────────────────────────────────────────
function generateDasterkhwaanPdf() {
  const html = `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>GMWF Dasterkhwaan Food Inventory Guide</title>
  <style>${getStyles(false)}</style>
</head>
<body>
  <div class="header-bar">
    <div class="header-logo-group">
      <img src="${logoBase64}" class="header-logo" alt="GMWF Logo">
      <div>
        <div class="org-title">Gulzar Madina Welfare Foundation</div>
        <div class="org-subtitle">Dasterkhwaan & Community Kitchen Logistics</div>
      </div>
    </div>
    <div class="meta-badge">
      <div>Document Ref: <strong>GMWF-SOP-FOOD-01</strong></div>
      <div>Effective: November 2026 | Version 2.0</div>
      <div class="meta-tag">COMMUNITY KITCHEN MANUAL</div>
    </div>
  </div>

  <h1>Dasterkhwaan Food & Kitchen Pantry Inventory Guide</h1>
  <p>The GMWF Dasterkhwaan Subsystem tracks the bulk food supply chain, kitchen pantries, daily cooking cauldrons (Deghs), and beneficiary meal distribution across the foundation's charitable dining centers.</p>

  <div class="alert alert-info">
    <strong>Key Principle:</strong> Beneficiary headcounts are verified through the reception token scanner. Kitchen staff focus strictly on recording raw ingredients placed into cauldrons. The system links consumed food against issued tokens automatically.
  </div>

  <h2>1. Essential Kitchen Pantry Rules</h2>
  <ul>
    <li><strong>Non-Negative Inventory:</strong> Pantry quantities cannot drop below zero. Attempting to deduct 50 kg of rice when only 35 kg exist in storage is blocked.</li>
    <li><strong>Audited Reason Tags:</strong> Every deduction must be assigned a validated reason: <span class="btn-ref">consumed</span> (cooking meals), <span class="btn-ref">wasted</span> (spoiled/burnt food), <span class="btn-ref">expired</span> (passed safe consumption date), or <span class="btn-ref">audit</span> (count adjustment).</li>
    <li><strong>Ingredient Deduplication:</strong> In any single cooking batch, the same raw ingredient cannot be selected twice.</li>
    <li><strong>Multi-Unit Standards:</strong> Standard units include <span class="btn-ref">kg</span>, <span class="btn-ref">gram</span>, <span class="btn-ref">liter</span>, <span class="btn-ref">piece</span>, <span class="btn-ref">packet</span>, and <span class="btn-ref">handi</span>.</li>
  </ul>

  <h2>2. Jalalpur Jattan Dasterkhwaan Lunch Service (Demonstration)</h2>
  <div class="card" style="margin-bottom: 12px;">
    <div class="card-title">Event Target: 650 Beneficiaries | Menu: Chicken Pulao & Daal Mash</div>
    <table>
      <thead>
        <tr>
          <th>Ingredient</th>
          <th>Opening Balance</th>
          <th>Cook Deduction (Cauldrons)</th>
          <th>Closing Balance</th>
          <th>Status</th>
        </tr>
      </thead>
      <tbody>
        <tr>
          <td>Basmati Rice Kainat</td>
          <td>400 kg</td>
          <td>-80 kg</td>
          <td>320 kg</td>
          <td><span class="badge badge-green">Adequate</span></td>
        </tr>
        <tr>
          <td>Chicken Broiler</td>
          <td>120 kg</td>
          <td>-45 kg</td>
          <td>75 kg</td>
          <td><span class="badge badge-green">Adequate</span></td>
        </tr>
        <tr>
          <td>Cooking Oil Dalda</td>
          <td>85 Liters</td>
          <td>-18 Liters</td>
          <td>67 Liters</td>
          <td><span class="badge badge-green">Adequate</span></td>
        </tr>
        <tr>
          <td>Daal Mash Premium</td>
          <td>60 kg</td>
          <td>-15 kg</td>
          <td>45 kg</td>
          <td><span class="badge badge-green">Adequate</span></td>
        </tr>
        <tr>
          <td>Spices & Salt Mix</td>
          <td>25 kg</td>
          <td>-4 kg</td>
          <td>21 kg</td>
          <td><span class="badge badge-green">Adequate</span></td>
        </tr>
      </tbody>
    </table>
  </div>

  <h2>3. اردو رہنمائی برائے کچن انوینٹری (Urdu Section)</h2>
  <div class="card" dir="rtl" style="line-height: 2.1; font-size: 13px;">
    <p><strong>دسترخوان کے کچن کیپر کے لیے ہدایات:</strong></p>
    <ul>
      <li>دیگ پکانے سے قبل نارنجی رنگ کا <span class="btn-ref">[-]</span> بٹن یا <span class="btn-ref">[Cook Meal]</span> ڈائیلاگ کھول کر دیگوں میں ڈالے گئے چاول، گھی اور گوشت کا وزن درج کریں۔</li>
      <li>نیا راشن یا مخیر حضرات کی طرف سے امداد آنے پر سبز رنگ کا <span class="btn-ref">[+]</span> بٹن دبا کر فوری تعداد درج کریں۔</li>
      <li>کھانا کھانے والے افراد کی تعداد ریسیپشن پر اسکین ہونے والے ٹوکنز سے خودکار طور پر ملائی جاتی ہے اس لیے کچن عملے کو اضافی اندراج کی ضرورت نہیں۔</li>
      <li>اگر کھانا جل جائے یا خراب ہو جائے تو <span class="btn-ref">Spoiled / Wasted</span> منتخب کر کے برانچ مینیجر کی منظوری سے اندراج کریں۔</li>
    </ul>
  </div>
</body>
</html>`;

  const outPath = path.join(PDF_OUT_DIR, 'GMWF_Dasterkhwaan_Food_Inventory_Guide.pdf');
  renderPdf(html, outPath);
  fs.copyFileSync(outPath, path.join(ROOT_DIR, 'guides/modules/03_dasterkhwaan/dasterkhwaan_inventory/GMWF_Dasterkhwaan_Food_Inventory_Guide.pdf'));
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. DISPENSER SOP DESK MANUAL PDF
// ─────────────────────────────────────────────────────────────────────────────
function generateDispenserSopPdf() {
  const html = `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>GMWF Dispenser SOP & Desk Manual</title>
  <style>${getStyles(false)}</style>
</head>
<body>
  <div class="header-bar">
    <div class="header-logo-group">
      <img src="${logoBase64}" class="header-logo" alt="GMWF Logo">
      <div>
        <div class="org-title">Gulzar Madina Welfare Foundation</div>
        <div class="org-subtitle">Pharmacy Operations & Clinical Support Services</div>
      </div>
    </div>
    <div class="meta-badge">
      <div>Document Ref: <strong>GMWF-SOP-ROLE-10</strong></div>
      <div>Role: <strong>Pharmacy Dispenser (10_dispenser)</strong></div>
      <div class="meta-tag">DESK SOP & DAILY CHECKLIST</div>
    </div>
  </div>

  <h1>Pharmacy Dispenser — Standard Operating Procedure & Checklist</h1>
  <p>The Pharmacy Dispenser is responsible for dispensing doctor-prescribed medications accurately, adhering to FEFO standards, receiving incoming deliveries, and maintaining physical shelf reconciliation.</p>

  <h2>Daily Operational Checklist</h2>
  <div class="grid-2">
    <div class="card">
      <div class="card-title">Morning Routine (08:30 AM)</div>
      <ul>
        <li>Login and verify active branch pool (<span class="btn-ref">jalalpur_jattan</span>).</li>
        <li>Check <span class="btn-ref">[Near Expiry]</span> tab. Inform Doctor of batches expiring within 90 days.</li>
        <li>Check <span class="btn-ref">[Low Stock]</span> tab. Requisition supplies for items below 20 units.</li>
        <li>Test 1 barcode scan on the physical reader.</li>
      </ul>
    </div>
    <div class="card">
      <div class="card-title">Clinical OPD Hours</div>
      <ul>
        <li>Receive patient token and review prescription on screen.</li>
        <li>Verify physical box batch against the system-selected FEFO batch.</li>
        <li>Dispense medication and explain dosage instructions.</li>
        <li>For incoming shipments, use <span class="btn-ref">[Express Scan Mode]</span>.</li>
      </ul>
    </div>
  </div>

  <div class="card" style="margin-top: 10px;">
    <div class="card-title">Evening Closing Routine (04:30 PM)</div>
    <ul>
      <li>Open <span class="btn-ref">[Stock Check]</span> and physically verify at least 5 random medicine shelves.</li>
      <li>Review <span class="btn-ref">[Activity Log]</span> to confirm all movements are accounted for.</li>
      <li>Ensure all proposal edit requests have been reviewed by the Doctor or Branch Manager.</li>
    </ul>
  </div>

  <h2 style="margin-top: 16px;">فارمیسی ڈسپنسر کا یومیہ چیک لسٹ (Urdu Summary)</h2>
  <div class="card" dir="rtl" style="line-height: 2.1; font-size: 13px;">
    <ul>
      <li>صبح 8:30 پر لاگ ان کریں اور <span class="btn-ref">[Near Expiry]</span> ٹیب میں 90 دنوں کے اندر ایکسپائر ہونے والی ادویات چیک کر کے ڈاکٹر کو مطلع کریں۔</li>
      <li>مریض کو دوائی دیتے وقت اسکرین پر آنے والا بیچ نمبر فزیکل ڈبے سے ضرور ملائیں۔</li>
      <li>نئی دوائی وصول کرتے وقت <span class="btn-ref">[Express Scan Mode]</span> آن کر کے بارکوڈ اسکینر سے تیز ترین اندراج کریں۔</li>
      <li>شام کو کم از کم 5 ادویات کی فزیکل گنتی الماری سے کر کے <span class="btn-ref">[Stock Check]</span> میں اندراج کریں۔</li>
    </ul>
  </div>
</body>
</html>`;

  const outPath = path.join(PDF_OUT_DIR, 'GMWF_Dispenser_SOP_Desk_Manual.pdf');
  renderPdf(html, outPath);
  fs.copyFileSync(outPath, path.join(ROOT_DIR, 'guides/users/10_dispenser/GMWF_Dispenser_SOP_Desk_Manual.pdf'));
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN EXECUTION
// ─────────────────────────────────────────────────────────────────────────────
console.log('Generating Enterprise GMWF PDF Guides...');
generateDispensaryInventoryPdfEN();
generateDispensaryInventoryPdfUR();
generateJalalpurJattanDataPdf();
generateDasterkhwaanPdf();
generateDispenserSopPdf();
console.log('All PDF Guides generated successfully.');
