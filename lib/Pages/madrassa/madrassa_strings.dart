// lib/pages/madrassa/madrassa_strings.dart

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MadrassaLocale {
  final String appName = 'Gulzar Madina';
  final String appSubtitle = 'Madrassa Management';
  final String logout = 'Logout';
  final String save = 'Save';
  final String cancel = 'Cancel';
  final String confirm = 'Confirm';
  final String delete = 'Delete';
  final String edit = 'Edit';
  final String search = 'Search';
  final String loading = 'Loading...';
  final String errorGeneric = 'Error loading data.';
  final String noData = 'No data available.';

  final String navHome = 'Home';
  final String navLog = 'Log';
  final String navMonthly = 'Monthly';
  final String navDaily = 'Daily';
  final String navStudents = 'Students';
  final String navConfig = 'Config';

  final String overviewTitle = 'Madrassa Insights';
  final String classPresence = 'Class Presence';
  final String enrollmentStats = 'Enrollment Stats';
  final String totalStudents = 'Total Students';
  final String todayPresent = 'Today Present';
  final String operationalStatus = 'Operational Status';
  final String academicCycle = 'Academic Cycle';
  final String lastSync = 'Last Sync';
  final String moduleHealth = 'Module Health';
  final String moduleActive = 'Premium • Active';

  final String dailyLogTitle = 'Daily Log';
  final String jumpToToday = 'Jump to Today';
  final String ptmDay = 'PTM DAY';
  final String allPresent = 'All Present';
  final String allUniform = 'All Uniform';
  final String allPtm = 'All PTM';
  final String saveDailyLog = 'Save Daily Log';
  final String savedSuccess = 'Saved Successfully ✓';
  final String unsavedChanges = 'Unsaved Changes';
  final String unsavedChangesBody = 'Discard unsaved changes?';
  final String stay = 'Stay';
  final String discard = 'Discard';
  final String configNotSet = 'Configuration not set!';
  final String viewingOtherMonth = 'Viewing {month}';
  final String skippedLeaveOrSent = '{n} student(s) skipped.';
  final String futureDateTitle = 'Future Date';
  final String futureDateSubtitle = 'Daily Log is not available for future dates.';

  final String present = 'Present';
  final String leave = 'Leave';
  final String sent = 'Sent';
  final String absent = 'Absent';
  final String unknown = 'Unknown';
  final String uniform = 'Uniform';
  final String parentReplied = 'Parent Replied';
  final String ptm = 'PTM';
  final String attendance = 'Attendance';

  final String legendPresent = 'Present';
  final String legendLeave = 'Leave';
  final String legendSent = 'Sent';
  final String legendAbsent = 'Absent';

  final String monthlyReportTitle = 'Monthly Report';
  final String academicDays = 'Academic Days';
  final String baseFeeLabel = 'Base Fee';
  final String exportExcel = 'Export Excel';
  final String printPdf = 'Print PDF';
  final String totalClassDue = 'Total Due';
  final String due = 'DUE';
  final String presentDays = 'Present';
  final String uniformDays = 'Uniform';
  final String messages = 'Messages';
  final String ptmLabel = 'PTM';
  final String yes = 'YES';
  final String no = 'NO';

  final String studentName = 'Student Name';
  final String activeWorkingDays = 'Academic Days';
  final String attendanceSavings = 'Attendance Savings';
  final String uniformSavings = 'Uniform Savings';
  final String message = 'Message';
  final String savings = 'Savings';
  final String amountDue = 'Amount Due';
  final String currentMonth = 'Current Month';
  final String attendanceCredits = 'Attendance Credits';
  final String uniformCredits = 'Uniform Credits';
  final String responseCredits = 'Response Credits';
  final String ptmCredits = 'PTM Credits';
  final String feeInfoNote = 'Discounts applied for discipline.';

  final String memorizationProgress = 'Memorization Progress';
  final String today = 'Today';
  final String weekly = 'Weekly';
  final String monthly = 'Monthly';
  final String lines = 'Lines';
  final String overallProgress = 'Overall Progress';
  final String lineOf = 'Line {n}';
  final String approxPage = 'Approx Pg {n}';

  final String attendanceTracker = 'Attendance Tracker';
  final String todayActions = "Today's Actions";
  final String moreInfo = 'More Info';
  final String sentMyChild = 'Sent My Child';
  final String requestLeave = 'Request Leave';
  final String enterReason = 'Enter Reason';
  final String leaveReasonHint = 'Reason for leave';
  final String parentRequestedLeave = 'Leave Requested by Parent';

  final String studentsRoster = 'Students Roster';
  final String enrollNew = 'Enroll New';
  final String enrollNewStudent = 'Enroll New Student';
  final String studentInformation = 'STUDENT INFORMATION';
  final String guardianInformation = 'GUARDIAN INFORMATION';
  final String studentFullName = 'Student Full Name';
  final String rollNumber = 'Roll Number';
  final String studentCnic = 'Student CNIC';
  final String guardianFullName = 'Guardian Full Name';
  final String guardianCnic = 'Guardian CNIC';
  final String contactPhone = 'Contact Phone';
  final String guardianPhone = 'Guardian Phone';
  final String createLinkAccount = 'Create / Link Account';
  final String createLinkSubtitle = 'Allow guardian portal access';
  final String newGuardian = 'New';
  final String existingGuardian = 'Existing';
  final String loginUsername = 'Login Username';
  final String loginUsernameHint = 'Username';
  final String loginPassword = 'Login Password';
  final String usernameWarning = 'Username cannot be changed.';
  final String searchGuardian = 'Search Guardian';
  final String noGuardiansFound = 'No guardians found.';
  final String enrollAndLink = 'Enroll & Link';
  final String fillRequiredFields = 'Fill required fields.';
  final String usernamePasswordRequired = 'Username/Password required.';
  final String selectExistingGuardian = 'Select guardian.';
  final String enrolledSuccess = 'Student enrolled!';
  final String linked = 'LINKED';
  final String unlinked = 'UNLINKED';
  final String deleteStudentTitle = 'Delete Student?';
  final String deleteStudentBody = 'Remove {name}?';
  final String activateStudent = 'Activate student?';
  final String deactivateStudent = 'Deactivate student?';
  final String confirmAction = 'Are you sure?';
  final String archiveStudent = 'Archive Student';
  final String unarchiveStudent = 'Unarchive Student';
  final String archiveReason = 'Archive Reason';
  final String archiveReasonHint = 'Reason';
  final String unarchiveReasonHint = 'Reason';
  final String statusActive = 'Active';
  final String statusArchived = 'Archived';
  final String statusHifzCompleted = 'Hifz Completed';
  final String statusLeft = 'Left';
  final String joinDate = 'Join Date';
  final String studentProgress = 'Daily Progress';
  final String studentProgressHint = 'Progress details';
  final String performance = 'Performance';
  final String goodJob = 'Good Job';
  final String badJob = 'Needs Improvement';
  final String studentGraduated = 'Graduated';
  final String studentDropped = 'Dropped';
  final String archiveLog = 'Archive Log';
  final String archiveDuration = 'Duration';
  final String auditLog = 'Audit Log';
  final String timeWithOrg = 'Time with Org';
  final String progressMadeHere = 'Progress Made';
  final String previousMadrassa = 'Previous Madrassa';
  final String previousMadrassaName = 'Previous Madrassa Name';
  final String hifzBeforeJoining = 'Prior Hifz Lines';
  final String yearsToComplete = 'Years to Complete';
  final String months = 'Months';
  final String years = 'Years';

  final String guardianPortal = 'Guardian Portal';
  final String guardianPortalSubtitle = 'Account for {name}';
  final String createNew = 'Create New';
  final String linkExisting = 'Link Existing';
  final String portalUsername = 'Portal Username';
  final String securePassword = 'Secure Password';
  final String primaryContact = 'Primary Contact';
  final String searchUsernamePhone = 'Search';
  final String children = 'Children';
  final String linkAccount = 'LINK ACCOUNT';
  final String createPortal = 'CREATE PORTAL';
  final String relationshipEstablished = 'Linked ✓';
  final String accountNotLinked = 'Account Not Linked';
  final String accountNotLinkedBody = 'Contact admin.';
  final String backToLogin = 'Back to Login';
  final String branchMissing = 'Branch missing.';

  final String configTitle = 'Global Settings';
  final String activePeriod = 'Active Period';
  final String year = 'Year';
  final String month = 'Month';
  final String deductionParams = 'Deduction Params';
  final String baseFee = 'Base Fee (Rs.)';
  final String ptmDeduction = 'PTM Deduction';
  final String messageDeduction = 'Message Deduction';
  final String maxAttSavings = 'Max Attendance Savings';
  final String maxUniSavings = 'Max Uniform Savings';
  final String saveConfig = 'SAVE CONFIG';
  final String configSaved = 'Config Saved ✓';
  final String feeModelTitle = 'Fee Model';
  final String feeModelBody = 'Discipline-based savings:';
  final String feeLineAtt = '• Attendance';
  final String feeLineUni = '• Uniform';
  final String feeLineMsg = '• Messages';
  final String feeLinePtm = '• PTM Meeting';
  final String feeFormula = 'Total Due = Base Fee - Savings';
  static const List<String> dayAbbr = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

  final String madrassaManagement = 'Madrassa Management';
  final String dailyLog = 'Daily Log';
  final String students = 'Students';
  final String monthlyReport = 'Monthly Report';
  final String config = 'Config';
  final String saveChanges = 'Save Changes';
  final String madrassaSettings = 'Madrassa Settings';
  final String studentRoster = 'Student Roster';

  final String dataImportExport = 'Data Import / Export';
  final String dataImportExportSubtitle = 'Backup or restore students, daily logs, and audit history';
  final String exportStudents = 'Export Students';
  final String exportDailyLogs = 'Export Daily Logs';
  final String exportAuditLog = 'Export Audit Log';
  final String exportAllCsv = 'Export All (CSV)';
  final String importCsv = 'Import CSV';
  final String importCsvTitle = 'Import Madrassa Data';
  final String importCsvBody = 'Select a CSV file. Type is auto-detected from column headers (Student, DailyLog, or AuditLog format).';
  final String exportSuccess = 'CSV export saved successfully';
  final String exportAllSuccess = 'All CSV files saved';
  final String exportCancelled = 'Export cancelled';
  final String importSuccess = 'Import completed';
  final String importFailed = 'Import failed';

  const MadrassaLocale();
}

class MadrassaLocaleUr extends MadrassaLocale {
  @override
  final String appName = 'گلزارِ مدینہ';
  @override
  final String appSubtitle = 'مدرسہ مینجمنٹ';
  @override
  final String logout = 'لاگ آؤٹ';
  @override
  final String save = 'محفوظ کریں';
  @override
  final String cancel = 'منسوخ کریں';
  @override
  final String confirm = 'تصدیق کریں';
  @override
  final String delete = 'حذف کریں';
  @override
  final String edit = 'ترمیم کریں';
  @override
  final String search = 'تلاش کریں';
  @override
  final String loading = 'لوڈ ہو رہا ہے...';
  @override
  final String errorGeneric = 'لوڈ کرنے میں خرابی۔';
  @override
  final String noData = 'کوئی ڈیٹا دستیاب نہیں ہے۔';

  @override
  final String navHome = 'ہوم';
  @override
  final String navLog = 'لاگ';
  @override
  final String navMonthly = 'ماہانہ';
  @override
  final String navDaily = 'روزانہ';
  @override
  final String navStudents = 'طلباء';
  @override
  final String navConfig = 'سیٹنگز';

  @override
  final String overviewTitle = 'مدرسہ رپورٹس';
  @override
  final String classPresence = 'کلاس حاضری';
  @override
  final String enrollmentStats = 'داخلہ شماریات';
  @override
  final String totalStudents = 'کل طلباء';
  @override
  final String todayPresent = 'آج حاضر';
  @override
  final String operationalStatus = 'آپریشنل اسٹیٹس';
  @override
  final String academicCycle = 'تعلیمی سال';
  @override
  final String lastSync = 'آخری مطابقت پذیری';
  @override
  final String moduleHealth = 'ماڈیول ہیلتھ';
  @override
  final String moduleActive = 'پریمیئم • فعال';

  @override
  final String dailyLogTitle = 'روزانہ لاگ';
  @override
  final String jumpToToday = 'آج پر جائیں';
  @override
  final String ptmDay = 'پی ٹی ایم کا دن';
  @override
  final String allPresent = 'سب حاضر';
  @override
  final String allUniform = 'سب یونیفارم';
  @override
  final String allPtm = 'سب پی ٹی ایم';
  @override
  final String saveDailyLog = 'روزانہ لاگ محفوظ کریں';
  @override
  final String savedSuccess = 'کامیابی سے محفوظ ہو گیا ✓';
  @override
  final String unsavedChanges = 'غیر محفوظ شدہ تبدیلیاں';
  @override
  final String unsavedChangesBody = 'غیر محفوظ شدہ تبدیلیاں خارج کریں؟';
  @override
  final String stay = 'رکیں';
  @override
  final String discard = 'خارج کریں';
  @override
  final String configNotSet = 'کنفیگریشن سیٹ نہیں ہے!';
  @override
  final String viewingOtherMonth = '{month} کا مشاہدہ';
  @override
  final String skippedLeaveOrSent = '{n} طالب علم چھوڑ دیے۔';
  @override
  final String futureDateTitle = 'مستقبل کی تاریخ';
  @override
  final String futureDateSubtitle = 'مستقبل کی تاریخوں کے لیے روزانہ کا لاگ دستیاب نہیں ہے۔';

  @override
  final String present = 'حاضر';
  @override
  final String leave = 'رخصت';
  @override
  final String sent = 'بھیج دیا';
  @override
  final String absent = 'غیر حاضر';
  @override
  final String unknown = 'نامعلوم';
  @override
  final String uniform = 'یونیفارم';
  @override
  final String parentReplied = 'والدین کا جواب';
  @override
  final String ptm = 'پی ٹی ایم';
  @override
  final String attendance = 'حاضری';

  @override
  final String legendPresent = 'حاضر';
  @override
  final String legendLeave = 'رخصت';
  @override
  final String legendSent = 'بھیجا گیا';
  @override
  final String legendAbsent = 'غیر حاضر';

  @override
  final String monthlyReportTitle = 'ماہانہ رپورٹ';
  @override
  final String academicDays = 'تعلیمی دن';
  @override
  final String baseFeeLabel = 'بنیادی فیس';
  @override
  final String exportExcel = 'ایکسل ایکسپورٹ';
  @override
  final String printPdf = 'پی ڈی ایف پرنٹ';
  @override
  final String totalClassDue = 'کل واجب الادا';
  @override
  final String due = 'واجب الادا';
  @override
  final String presentDays = 'حاضر دن';
  @override
  final String uniformDays = 'یونیفارم دن';
  @override
  final String messages = 'پیغامات';
  @override
  final String ptmLabel = 'پی ٹی ایم';
  @override
  final String yes = 'جی ہاں';
  @override
  final String no = 'جی نہیں';

  @override
  final String studentName = 'طالب علم کا نام';
  @override
  final String activeWorkingDays = 'تعلیمی دن';
  @override
  final String attendanceSavings = 'حاضری بچت';
  @override
  final String uniformSavings = 'یونیفارم بچت';
  @override
  final String message = 'پیغامات';
  @override
  final String savings = 'بچت';
  @override
  final String amountDue = 'واجب الادا رقم';
  @override
  final String currentMonth = 'موجودہ مہینہ';
  @override
  final String attendanceCredits = 'حاضری رعایت';
  @override
  final String uniformCredits = 'یونیفارم رعایت';
  @override
  final String responseCredits = 'جوابی رعایت';
  @override
  final String ptmCredits = 'پی ٹی ایم رعایت';
  @override
  final String feeInfoNote = 'نظم و ضبط کی بنیاد پر رعایت لاگو کی گئی ہے۔';

  @override
  final String memorizationProgress = 'حفظ کی کارکردگی';
  @override
  final String today = 'آج';
  @override
  final String weekly = 'ہفتہ وار';
  @override
  final String monthly = 'ماہانہ';
  @override
  final String lines = 'لائنیں';
  @override
  final String overallProgress = 'مجموعی ترقی';
  @override
  final String lineOf = 'لائن {n}';
  @override
  final String approxPage = 'اندازاً صفحہ {n}';

  @override
  final String attendanceTracker = 'حاضری ٹریکر';
  @override
  final String todayActions = 'آج کے اقدامات';
  @override
  final String sentMyChild = 'بچے کو بھیج دیا';
  @override
  final String requestLeave = 'رخصت کی درخواست';
  @override
  final String enterReason = 'وجہ درج کریں';
  @override
  final String leaveReasonHint = 'رخصت کی وجہ';
  @override
  final String parentRequestedLeave = 'والدین کی طرف سے رخصت کی درخواست';

  @override
  final String studentsRoster = 'طلباء کا روسٹر';
  @override
  final String enrollNew = 'نیا داخلہ';
  @override
  final String enrollNewStudent = 'نیا طالب علم داخل کریں';
  @override
  final String studentInformation = 'طالب علم کی معلومات';
  @override
  final String guardianInformation = 'سرپرست کی معلومات';
  @override
  final String studentFullName = 'طالب علم کا پورا نام';
  @override
  final String rollNumber = 'رول نمبر';
  @override
  final String studentCnic = 'طالب علم کا شناختی کارڈ / فارم بی';
  @override
  final String guardianFullName = 'سرپرست کا پورا نام';
  @override
  final String guardianCnic = 'سرپرست کا شناختی کارڈ';
  @override
  final String contactPhone = 'رابطہ نمبر';
  @override
  final String guardianPhone = 'سرپرست کا فون';
  @override
  final String createLinkAccount = 'اکاؤنٹ بنائیں / لنک کریں';
  @override
  final String createLinkSubtitle = 'سرپرست پورٹل تک رسائی کی اجازت دیں';
  @override
  final String newGuardian = 'نیا';
  @override
  final String existingGuardian = 'موجودہ';
  @override
  final String loginUsername = 'لاگ ان صارف نام';
  @override
  final String loginUsernameHint = 'صارف نام';
  @override
  final String loginPassword = 'لاگ ان پاس ورڈ';
  @override
  final String usernameWarning = 'صارف نام تبدیل نہیں کیا جا سکتا۔';
  @override
  final String searchGuardian = 'سرپرست تلاش کریں';
  @override
  final String noGuardiansFound = 'کوئی سرپرست نہیں ملا۔';
  @override
  final String enrollAndLink = 'داخلہ اور لنک کریں';
  @override
  final String fillRequiredFields = 'ضروری خانے پُر کریں۔';
  @override
  final String usernamePasswordRequired = 'صارف نام اور پاس ورڈ ضروری ہے۔';
  @override
  final String selectExistingGuardian = 'سرپرست منتخب کریں۔';
  @override
  final String enrolledSuccess = 'طالب علم کا داخلہ ہو گیا!';
  @override
  final String linked = 'منسلک';
  @override
  final String unlinked = 'غیر منسلک';
  @override
  final String deleteStudentTitle = 'طالب علم خارج کریں؟';
  @override
  final String deleteStudentBody = 'کیا آپ {name} کو خارج کرنا چاہتے ہیں؟';
  @override
  final String activateStudent = 'طالب علم کو بحال کریں؟';
  @override
  final String deactivateStudent = 'طالب علم کو غیر فعال کریں؟';
  @override
  final String confirmAction = 'کیا آپ کو یقین ہے؟';
  @override
  final String archiveStudent = 'طالب علم آرکائیو کریں';
  @override
  final String unarchiveStudent = 'طالب علم ان آرکائیو کریں';
  @override
  final String archiveReason = 'آرکائیو کرنے کی وجہ';
  @override
  final String archiveReasonHint = 'وجہ';
  @override
  final String unarchiveReasonHint = 'وجہ';
  @override
  final String statusActive = 'فعال';
  @override
  final String statusArchived = 'آرکائیو شدہ';
  @override
  final String statusHifzCompleted = 'حفظ مکمل';
  @override
  final String statusLeft = 'چھوڑ دیا';
  @override
  final String joinDate = 'شمولیت کی تاریخ';
  @override
  final String studentProgress = 'روزانہ کی ترقی';
  @override
  final String studentProgressHint = 'ترقی کی تفصیلات';
  @override
  final String performance = 'کارکردگی';
  @override
  final String goodJob = 'بہترین کام';
  @override
  final String badJob = 'بہتری کی ضرورت ہے';
  @override
  final String studentGraduated = 'فارغ التحصیل';
  @override
  final String studentDropped = 'خارج شدہ';
  @override
  final String archiveLog = 'آرکائیو لاگ';
  @override
  final String archiveDuration = 'دورانیہ';
  @override
  final String auditLog = 'آڈٹ لاگ';
  @override
  final String timeWithOrg = 'ادارے کے ساتھ وقت';
  @override
  final String progressMadeHere = 'یہاں کی جانے والی پیش رفت';
  @override
  final String previousMadrassa = 'سابقہ مدرسہ';
  @override
  final String previousMadrassaName = 'سابقہ مدرسہ کا نام';
  @override
  final String hifzBeforeJoining = 'شمولیت سے پہلے حفظ کردہ لائنیں';
  @override
  final String yearsToComplete = 'تکمیل کے لیے سال';
  @override
  final String months = 'مہینے';
  @override
  final String years = 'سال';

  @override
  final String guardianPortal = 'سرپرست پورٹل';
  @override
  final String guardianPortalSubtitle = 'اکاؤنٹ برائے {name}';
  @override
  final String createNew = 'نیا بنائیں';
  @override
  final String linkExisting = 'موجودہ لنک کریں';
  @override
  final String portalUsername = 'پورٹل صارف نام';
  @override
  final String securePassword = 'محفوظ پاس ورڈ';
  @override
  final String primaryContact = 'بنیادی رابطہ';
  @override
  final String searchUsernamePhone = 'تلاش کریں';
  @override
  final String children = 'بچے';
  @override
  final String linkAccount = 'اکاؤنٹ لنک کریں';
  @override
  final String createPortal = 'پورٹل بنائیں';
  @override
  final String relationshipEstablished = 'لنک ہو گیا ✓';
  @override
  final String accountNotLinked = 'اکاؤنٹ لنک نہیں ہے';
  @override
  final String accountNotLinkedBody = 'انتظامیہ سے رابطہ کریں۔';
  @override
  final String backToLogin = 'لاگ ان پر واپس جائیں';
  @override
  final String branchMissing = 'برانچ موجود نہیں ہے۔';

  @override
  final String configTitle = 'عمومی سیٹنگز';
  @override
  final String activePeriod = 'فعال مدت';
  @override
  final String year = 'سال';
  @override
  final String month = 'مہینہ';
  @override
  final String deductionParams = 'رعایت کے پیرامیٹرز';
  @override
  final String baseFee = 'بنیادی پوائنٹس';
  @override
  final String ptmDeduction = 'پی ٹی ایم رعایت';
  @override
  final String messageDeduction = 'پیغام رعایت';
  @override
  final String maxAttSavings = 'زیادہ سے زیادہ حاضری رعایت';
  @override
  final String maxUniSavings = 'زیادہ سے زیادہ یونیفارم رعایت';
  @override
  final String saveConfig = 'سیٹنگز محفوظ کریں';
  @override
  final String configSaved = 'سیٹنگز محفوظ ہو گئیں ✓';
  @override
  final String feeModelTitle = 'رعایتی ماڈل';
  @override
  final String feeModelBody = 'نظم و ضبط کی بنیاد پر رعایت:';
  @override
  final String feeLineAtt = '• حاضری';
  @override
  final String feeLineUni = '• یونیفارم';
  @override
  final String feeLineMsg = '• پیغامات';
  @override
  final String feeLinePtm = '• پی ٹی ایم میٹنگ';
  @override
  final String feeFormula = 'کل فیس = بنیادی فیس - رعایت';

  @override
  final String madrassaManagement = 'مدرسہ انتظامیہ';
  @override
  final String dailyLog = 'روزانہ لاگ';
  @override
  final String students = 'طلباء';
  @override
  final String monthlyReport = 'ماہانہ رپورٹ';
  @override
  final String config = 'سیٹنگز';
  @override
  final String saveChanges = 'تبدیلیاں محفوظ کریں';
  @override
  final String madrassaSettings = 'مدرسہ سیٹنگز';
  @override
  final String studentRoster = 'طلباء کی فہرست';

  @override
  final String dataImportExport = 'ڈیٹا درآمد / برآمد';
  @override
  final String dataImportExportSubtitle = 'طلباء، روزانہ لاگ اور آڈٹ ہسٹری بیک اپ یا بحالی';
  @override
  final String exportStudents = 'طلباء برآمد';
  @override
  final String exportDailyLogs = 'روزانہ لاگ برآمد';
  @override
  final String exportAuditLog = 'آڈٹ لاگ برآمد';
  @override
  final String exportAllCsv = 'سب برآمد (CSV)';
  @override
  final String importCsv = 'CSV درآمد';
  @override
  final String importCsvTitle = 'مدرسہ ڈیٹا درآمد';
  @override
  final String importCsvBody = 'CSV فائل منتخب کریں۔ کالم ہیڈرز سے قسم خود پہچانی جائے گی۔';
  @override
  final String exportSuccess = 'CSV برآمد محفوظ ہو گئی';
  @override
  final String exportAllSuccess = 'تمام CSV فائلیں محفوظ ہو گئیں';
  @override
  final String exportCancelled = 'برآمد منسوخ';
  @override
  final String importSuccess = 'درآمد مکمل';
  @override
  final String importFailed = 'درآمد ناکام';

  const MadrassaLocaleUr();
}

class MStr {
  static const MadrassaLocale en = MadrassaLocale();
  static const MadrassaLocale ur = MadrassaLocaleUr();
}

class MadrassaLanguageProvider extends ChangeNotifier {
  String _localeCode = 'en';

  MadrassaLanguageProvider() {
    _loadLocale();
  }

  Future<void> _loadLocale() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedCode = prefs.getString('madrassa_locale');
      if (savedCode != null && savedCode != _localeCode) {
        _localeCode = savedCode;
        notifyListeners();
      }
    } catch (_) {}
  }

  String get localeCode => _localeCode;
  String get languageCode => _localeCode;
  MadrassaLocale get locale => _localeCode == 'ur' ? MStr.ur : MStr.en;

  Future<void> toggleLanguage() async {
    _localeCode = _localeCode == 'en' ? 'ur' : 'en';
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('madrassa_locale', _localeCode);
    } catch (_) {}
  }

  Future<void> setLanguage(String code) async {
    _localeCode = code;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('madrassa_locale', _localeCode);
    } catch (_) {}
  }
}

extension MadrassaLocaleExtension on BuildContext {
  MadrassaLocale get l {
    try {
      return Provider.of<MadrassaLanguageProvider>(this).locale;
    } catch (_) {
      return MStr.en;
    }
  }

  String get languageCode {
    try {
      return Provider.of<MadrassaLanguageProvider>(this).localeCode;
    } catch (_) {
      return 'en';
    }
  }

  bool get isUrdu => languageCode == 'ur';

  TextStyle urduStyle({TextStyle? style}) {
    final base = style ?? const TextStyle();
    if (isUrdu) {
      return base.copyWith(
        fontFamily: 'Noori',
      );
    }
    return base;
  }
}

extension MadrassaTranslationExtension on BuildContext {
  String t(String text) {
    if (!isUrdu) return text;
    final map = {
      'Today': 'آج',
      'Progress': 'کارکردگی',
      'Fees': 'فیس',
      'Account': 'اکاؤنٹ',
      'Request Leave': 'رخصت کی درخواست',
      'Leave Reason': 'رخصت کی وجہ',
      'Cancel': 'منسوخ کریں',
      'Submit': 'جمع کریں',
      'Submit Request': 'درخواست جمع کریں',
      'Request Rejoining': 'دوبارہ شمولیت کی درخواست',
      'Rejoining Reason': 'دوبارہ شمولیت کی وجہ',
      'Please specify the reason/notes for requesting to rejoin the Madrassa.': 'براہ کرم مدرسہ میں دوبارہ شمولیت کی درخواست کی وجہ/نوٹس لکھیں۔',
      'No date chosen': 'کوئی تاریخ منتخب نہیں کی گئی',
      'Rejoin Request': 'دوبارہ شمولیت کی درخواست',
      'rejoin': 'دوبارہ شمولیت',
      'Select Date': 'تاریخ منتخب کریں',
      'Enter reason here...': 'وجہ یہاں درج کریں...',
      'e.g. Relocating back, student wants to resume.': 'مثال کے طور پر: واپس منتقلی، طالب علم دوبارہ پڑھنا چاہتا ہے۔',
      'Rejoining reason is required': 'دوبارہ شمولیت کی وجہ ضروری ہے',
      'Leave reason is required': 'رخصت کی وجہ ضروری ہے',
      'Student Full Name': 'طالب علم کا پورا نام',
      'Student Information': 'طالب علم کی معلومات',
      'Guardian Information': 'سرپرست کی معلومات',
      'Roll Number': 'رول نمبر',
      'Student CNIC': 'طالب علم کا شناختی کارڈ / فارم بی',
      'Guardian CNIC': 'سرپرست کا شناختی کارڈ',
      'Guardian Full Name': 'سرپرست کا پورا نام',
      'Contact Phone': 'رابطہ نمبر',
      'Join Date': 'شمولیت کی تاریخ',
      'Previous Madrassa': 'سابقہ مدرسہ',
      'Hifz Before Joining': 'شمولیت سے پہلے حفظ کردہ لائنیں',
      'Login Username': 'صارف نام',
      'Login Password': 'پاس ورڈ',
      'Create / Link Account': 'اکاؤنٹ بنائیں / لنک کریں',
      'Allow guardian portal access': 'سرپرست پورٹل تک رسائی دیں',
      'Save': 'محفوظ کریں',
      'Close': 'بند کریں',
      'Change Language': 'زبان تبدیل کریں',
      'English': 'انگریزی',
      'Urdu': 'اردو',
      'Select Language': 'زبان منتخب کریں',
      'Please select your preferred language': 'براہ کرم اپنی پسندیدہ زبان منتخب کریں',
      'Select student to preview': 'طالب علم منتخب کریں',
      'Guardian Portal': 'سرپرست پورٹل',
      'Search by name or roll number...': 'نام یا رول نمبر سے تلاش کریں...',
      'No matching students found.': 'کوئی مماثل طالب علم نہیں ملا۔',
      'Logout': 'لاگ آؤٹ',
      'Academic Summary': 'تعلیمی خلاصہ',
      'Attendance': 'حاضری',
      'Clean': 'صاف',
      'Unclean': 'غیر صاف',
      'Memorization': 'حفظ',
      'Discipline Dues': 'ڈسپلن فیس',
      'Active Period': 'فعال مدت',
      'Year': 'سال',
      'Month': 'مہینہ',
      'Deduction Params': 'رعایت کے پیرامیٹرز',
      'Base Fee (Rs.)': 'بنیادی فیس (روپے)',
      'PTM Deduction': 'پی ٹی ایم رعایت',
      'Message Deduction': 'پیغام رعایت',
      'Max Attendance Savings': 'زیادہ سے زیادہ حاضری رعایت',
      'Max Uniform Savings': 'زیادہ سے زیادہ یونیفارم رعایت',
      'Global Settings': 'عمومی سیٹنگز',
      'Save Config': 'سیٹنگز محفوظ کریں',
      'Config Saved ✓': 'سیٹنگز محفوظ ہو گئیں ✓',
      'Fee Model': 'رعایتی ماڈل',
      'Discipline-based savings:': 'نظم و ضبط کی بنیاد پر رعایت:',
      'Total Due = Base Fee - Savings': 'کل فیس = بنیادی فیس - رعایت',
      'Madrassa Management': 'مدرسہ انتظامیہ',
      'Daily Log': 'روزانہ لاگ',
      'Students': 'طلباء',
      'Monthly Report': 'ماہانہ رپورٹ',
      'Config': 'سیٹنگز',
      'Save Changes': 'تبدیلیاں محفوظ کریں',
      'Madrassa Settings': 'مدرسہ سیٹنگز',
      'Student Roster': 'طلباء کی فہرست',
      'Log Out Account': 'اکاؤنٹ لاگ آؤٹ کریں',
      'Guardian Details': 'سرپرست کی تفصیلات',
      "Today's Attendance": 'آج حاضری',
      "Today's Lesson Progress": 'آج حفظ کی ترقی',
      "Today's Actions": 'آج کے اقدامات',
      'Sent My Child': 'بچے کو بھیج دیا',
      'Student Details': 'طالب علم کی تفصیلات',
      'No announcements today.': 'آج کوئی اعلانات نہیں ہیں۔',
      'Rejoining status is pending approval.': 'دوبارہ شمولیت کا اسٹیٹس منظوری کا منتظر ہے۔',
      'Account Details': 'اکاؤنٹ کی تفصیلات',
      'Contact Admin': 'انتظامیہ سے رابطہ کریں',
      'Account Not Linked': 'اکاؤنٹ لنک نہیں ہے',
      'Your account is not linked to any student.': 'آپ کا اکاؤنٹ کسی طالب علم سے منسلک نہیں ہے۔',
      'Back to Login': 'لاگ ان پر واپس جائیں',
      'No active students found.': 'کوئی فعال طلباء نہیں ملے۔',
      'Unsaved Changes': 'غیر محفوظ شدہ تبدیلیاں',
      'Discard unsaved changes?': 'کیا غیر محفوظ شدہ تبدیلیاں خارج کر دی جائیں؟',
      'Discard': 'خارج کریں',
      'Stay': 'رکیں',
      'Saved Successfully ✓': 'کامیابی سے محفوظ ہو گیا ✓',
      'Saved Successfully': 'کامیابی سے محفوظ ہو گیا',
      'Status History': 'اسٹیٹس کی ہسٹری',
      'View Status History': 'اسٹیٹس کی ہسٹری دیکھیں',
      'Status of student {name} changed from {from} to {to}.': 'طالب علم {name} کا اسٹیٹس تبدیل ہو گیا۔',
      'Audit Log': 'آڈٹ لاگ',
      'Total Duration': 'کل دورانیہ',
      'Student': 'طالب علم',
      'Existing Guardian Found: ': 'موجودہ سرپرست مل گیا: ',
      'Both fields are required. Sundays are automatically skipped.': 'دونوں خانے پُر کرنا ضروری ہیں۔ اتوار خود بخود چھوڑ دیا جائے گا۔',
      'Holiday Name': 'تعطیل کا نام',
      'Number of Days': 'دنوں کی تعداد',
      'Holiday Date': 'تعطیل کی تاریخ',
      'Add Holiday': 'تعطیل شامل کریں',
      'Holiday Management': 'تعطیلات کا انتظام',
      'No holidays added yet.': 'ابھی تک کوئی تعطیل شامل نہیں کی گئی ہے۔',
      'Add': 'شامل کریں',
      'Reject Rejoin Request': 'دوبارہ شمولیت کی درخواست مسترد کریں',
      'Rejection Reason': 'مسترد کرنے کی وجہ',
      'Are you sure you want to reject the rejoin request for ': 'کیا آپ دوبارہ شمولیت کی درخواست کو مسترد کرنا چاہتے ہیں برائے ',
      'Reject': 'مسترد کریں',
      'Please correct all validation errors to continue': 'براہ کرم جاری رکھنے کے لیے تمام غلطیاں درست کریں۔',
      'Rejection reason is required': 'مسترد کرنے کی وجہ ضروری ہے',
      'Holiday name is required': 'تعطیل کا نام ضروری ہے',
      'Holiday date is required': 'تعطیل کی تاریخ ضروری ہے',
      'Hifz Completed Successfully': 'حفظ کامیابی کے ساتھ مکمل ہوا',
      'Time Taken:': 'لگنے والا وقت:',
      'Started Hifz:': 'حفظ کا آغاز:',
      'Completed Hifz:': 'حفظ کی تکمیل:',
      'Teacher Response': 'اساتذہ کا جواب',
      'PTM Meeting': 'پی ٹی ایم میٹنگ',
      'Uniform': 'یونیفارم',
      'Fee Calculation Flow': 'فیس کے حساب کتاب کا طریقہ',
      'Pro-rated Base Fee': 'بنیادی فیس (روزانہ کی بنیاد پر)',
      'Total Savings / Deductions': 'کل رعایت / منہائی',
      'Combined rewards for attendance, behavior & PTM': 'حاضری، برتاؤ اور پی ٹی ایم کے لیے مشترکہ رعایت',
      'Final Net Amount Due': 'کل واجب الادا رقم',
      'Monthly Statement': 'ماہانہ گوشوارہ',
      'Preparing your Excel report...': 'ایکسل رپورٹ تیار کی جا رہی ہے...',
      'Preparing your PDF report...': 'پی ڈی ایف رپورٹ تیار کی جا رہی ہے...',
      'Rejoin Request Pending': 'دوبارہ شمولیت کی درخواست زیر التوا ہے',
      'No history records found.': 'کوئی تاریخچہ ریکارڈ نہیں ملا۔',
      'Status History Timeline': 'اسٹیٹس کی تاریخ کا ٹائم لائن',
      'Student name is required': 'طالب علم کا نام ضروری ہے',
      'Roll number is required': 'رول نمبر ضروری ہے',
      'Guardian CNIC is required': 'سرپرست کا شناختی کارڈ ضروری ہے',
      'Guardian name is required': 'سرپرست کا نام ضروری ہے',
      'Contact phone is required': 'رابطہ نمبر ضروری ہے',
      'Username is required': 'صارف نام ضروری ہے',
      'Password is required': 'پاس ورڈ ضروری ہے',
      'Enter a valid 15-character CNIC (e.g. 12345-1234567-1)': 'براہ کرم شناختی کارڈ نمبر (12345-1234567-1) درج کریں',
      'Enter a valid 11-digit phone number': 'براہ کرم 11 ہندسوں کا فون نمبر درج کریں',
      'Sabak': 'سبق',
      'Sabki': 'سبکی',
      'Manzil': 'منزل',
      'Para': 'پارہ',
      'Ratio': 'حصہ',
      'Pao (1/4)': 'پاؤ (1/4)',
      'Nisf (1/2)': 'نصف (1/2)',
      'Salasa (3/4)': 'ثلاثہ (3/4)',
      'Para (1)': 'پارہ (1)',
      'Overall Quran Majeed Memorization Progress': 'مجموعی قرآن مجید حفظ کی پیشرفت',
      'Quran Majeed & Attendance Progress': 'قرآن مجید اور حاضری کی پیشرفت',
      'Quran Majeed & Attendance': 'قرآن مجید اور حاضری',
      'Cleanliness': 'صفائی',
      'Absent': 'غائب',
    };
    return map[text] ?? text;
  }
}

class MadrassaAuditService {
  static Future<void> logAction({
    required String branchId,
    required String editor,
    required String role,
    required String type,
    required String message,
    String? studentId,
    String? studentName,
  }) async {
    try {
      await FirebaseFirestore.instance
          .collection('branches')
          .doc(branchId)
          .collection('madrassa_audit_logs')
          .add({
        'timestamp': FieldValue.serverTimestamp(),
        'editor': editor,
        'role': role,
        'type': type,
        'message': message,
        if (studentId != null) 'studentId': studentId,
        if (studentName != null) 'studentName': studentName,
      });
    } catch (e) {
      debugPrint('Error writing audit log: $e');
    }
  }
}