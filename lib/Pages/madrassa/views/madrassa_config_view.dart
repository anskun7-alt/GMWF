import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'holiday_management_view.dart';
import '../madrassa_strings.dart';
import '../utils/madrassa_csv_service.dart';
import '../utils/madrassa_local_storage.dart';
import '../widgets/madrassa_erp.dart';
import '../../../services/local_storage_service.dart';
import '../../../services/user_theme_service.dart';
import '../../../design/design_system.dart';

// Breakpoints for responsive configuration sizing
const double kConfigMobileBreakpoint = GBreakpoint.compact;

class MadrassaConfigView extends StatefulWidget {
  final String branchId;
  final String username;
  final String role;
  const MadrassaConfigView({
    super.key,
    required this.branchId,
    required this.username,
    this.role = 'Madrassa Admin',
  });

  @override
  State<MadrassaConfigView> createState() => _MadrassaConfigViewState();
}

class _MadrassaConfigViewState extends State<MadrassaConfigView> {
  int _year = DateTime.now().year;
  int _month = DateTime.now().month;
  int _ptmDay = 0;
  
  final _baseFeeController = TextEditingController();
  final _ptmDeductionController = TextEditingController();
  final _msgDeductionController = TextEditingController();
  final _maxAttDeductionController = TextEditingController();
  final _maxUniDeductionController = TextEditingController();
  
  int _initialPtmDay = 0;
  bool _isSaving = false;
  bool _isExporting = false;
  bool _isImporting = false;

  String? _baseFeeError;
  String? _ptmDeductionError;
  String? _msgDeductionError;
  String? _maxAttDeductionError;
  String? _maxUniDeductionError;

  @override
  void initState() {
    super.initState();
    _loadCurrent();
  }

  @override
  void dispose() {
    _baseFeeController.dispose();
    _ptmDeductionController.dispose();
    _msgDeductionController.dispose();
    _maxAttDeductionController.dispose();
    _maxUniDeductionController.dispose();
    super.dispose();
  }

  Future<void> _loadCurrent() async {
    // 1. Try local cache first (instant load, zero Firestore reads)
    try {
      final box = await LocalStorageService.ensureBoxOpen(MadrassaLocalStorage.studentsBox);
      final key = '${widget.branchId.toLowerCase().trim()}__config__current';
      final cached = box.get(key);
      if (cached is Map && mounted) {
        final data = Map<String, dynamic>.from(cached);
        setState(() {
          _year = data['year'] ?? _year;
          _month = data['month'] ?? _month;
          _ptmDay = data['ptmDay'] ?? 0;
          _initialPtmDay = _ptmDay;
          _baseFeeController.text = (data['baseFee'] ?? 3000).toString();
          _ptmDeductionController.text = (data['ptmDeduction'] ?? 700).toString();
          _msgDeductionController.text = (data['messageTotalDeduction'] ?? 1300).toString();
          _maxAttDeductionController.text = (data['attendanceMaxDeduction'] ?? 500).toString();
          _maxUniDeductionController.text = (data['uniformMaxDeduction'] ?? 500).toString();
        });
      }
    } catch (_) {}

    // 2. Refresh from Firestore if network is available
    try {
      final doc = await FirebaseFirestore.instance
          .collection('branches')
          .doc(widget.branchId)
          .collection('madrassa_config')
          .doc('current')
          .get();
      if (doc.exists && mounted && doc.data() != null) {
        final data = doc.data()!;
        final box = await LocalStorageService.ensureBoxOpen(MadrassaLocalStorage.studentsBox);
        final key = '${widget.branchId.toLowerCase().trim()}__config__current';
        await box.put(key, LocalStorageService.sanitize(data));
        setState(() {
          _year = data['year'] ?? _year;
          _month = data['month'] ?? _month;
          _ptmDay = data['ptmDay'] ?? 0;
          _initialPtmDay = _ptmDay;
          _baseFeeController.text = (data['baseFee'] ?? 3000).toString();
          _ptmDeductionController.text = (data['ptmDeduction'] ?? 700).toString();
          _msgDeductionController.text = (data['messageTotalDeduction'] ?? 1300).toString();
          _maxAttDeductionController.text = (data['attendanceMaxDeduction'] ?? 500).toString();
          _maxUniDeductionController.text = (data['uniformMaxDeduction'] ?? 500).toString();
        });
      }
    } catch (_) {}
  }

  DateTime _getFirstFriday(int year, int month) {
    DateTime date = DateTime(year, month, 1);
    while (date.weekday != DateTime.friday) {
      date = date.add(const Duration(days: 1));
    }
    return date;
  }

  DateTime getPtmDate() {
    if (_ptmDay > 0) return DateTime(_year, _month, _ptmDay);
    return _getFirstFriday(_year, _month);
  }

  Future<void> _migratePtmAttendance(int oldDay, int newDay, int year, int month) async {
    final oldDate = oldDay == 0 ? _getFirstFriday(year, month) : DateTime(year, month, oldDay);
    final newDate = newDay == 0 ? _getFirstFriday(year, month) : DateTime(year, month, newDay);
    
    final oldDateStr = DateFormat('yyyy-MM-dd').format(oldDate);
    final newDateStr = DateFormat('yyyy-MM-dd').format(newDate);

    if (oldDateStr == newDateStr) return;

    final oldDocRef = FirebaseFirestore.instance
        .collection('branches')
        .doc(widget.branchId)
        .collection('madrassa_daily_logs')
        .doc(oldDateStr);

    final newDocRef = FirebaseFirestore.instance
        .collection('branches')
        .doc(widget.branchId)
        .collection('madrassa_daily_logs')
        .doc(newDateStr);

    try {
      final oldSnap = await oldDocRef.get();
      if (!oldSnap.exists) return;

      final oldData = oldSnap.data() ?? {};
      final Map<String, dynamic> oldUpdates = {};
      final Map<String, dynamic> newUpdates = {};

      bool hasChanges = false;
      oldData.forEach((studentId, studentLog) {
        if (studentLog is Map<String, dynamic> && studentLog.containsKey('ptm')) {
          final ptmVal = studentLog['ptm'];
          newUpdates[studentId] = {
            ...studentLog,
            'ptm': ptmVal,
          };
          final updatedStudentLog = Map<String, dynamic>.from(studentLog);
          updatedStudentLog.remove('ptm');
          oldUpdates[studentId] = updatedStudentLog;
          hasChanges = true;
        }
      });

      if (hasChanges) {
        final batch = FirebaseFirestore.instance.batch();
        batch.set(oldDocRef, oldUpdates, SetOptions(merge: true));
        batch.set(newDocRef, newUpdates, SetOptions(merge: true));
        await batch.commit();
      }
    } catch (e) {
      debugPrint('Error migrating PTM attendance: $e');
    }
  }

  Future<void> _save() async {
    bool hasError = false;
    
    setState(() {
      _baseFeeError = null;
      _ptmDeductionError = null;
      _msgDeductionError = null;
      _maxAttDeductionError = null;
      _maxUniDeductionError = null;
    });

    final bool isFeeEnabled = LocalStorageService.isMadrassaFeeEnabled(widget.branchId);

    double? base, ptm, msg, att, uni;

    if (isFeeEnabled) {
      final baseVal = _baseFeeController.text.trim();
      final ptmVal = _ptmDeductionController.text.trim();
      final msgVal = _msgDeductionController.text.trim();
      final attVal = _maxAttDeductionController.text.trim();
      final uniVal = _maxUniDeductionController.text.trim();

      if (baseVal.isEmpty) {
        setState(() => _baseFeeError = 'Base points are required');
        hasError = true;
      }
      if (ptmVal.isEmpty) {
        setState(() => _ptmDeductionError = 'PTM deduction is required');
        hasError = true;
      }
      if (msgVal.isEmpty) {
        setState(() => _msgDeductionError = 'Message deduction is required');
        hasError = true;
      }
      if (attVal.isEmpty) {
        setState(() => _maxAttDeductionError = 'Max attendance deduction is required');
        hasError = true;
      }
      if (uniVal.isEmpty) {
        setState(() => _maxUniDeductionError = 'Max uniform deduction is required');
        hasError = true;
      }

      base = double.tryParse(baseVal);
      ptm = double.tryParse(ptmVal);
      msg = double.tryParse(msgVal);
      att = double.tryParse(attVal);
      uni = double.tryParse(uniVal);

      if (baseVal.isNotEmpty && base == null) {
        setState(() => _baseFeeError = 'Enter a valid number');
        hasError = true;
      }
      if (ptmVal.isNotEmpty && ptm == null) {
        setState(() => _ptmDeductionError = 'Enter a valid number');
        hasError = true;
      }
      if (msgVal.isNotEmpty && msg == null) {
        setState(() => _msgDeductionError = 'Enter a valid number');
        hasError = true;
      }
      if (attVal.isNotEmpty && att == null) {
        setState(() => _maxAttDeductionError = 'Enter a valid number');
        hasError = true;
      }
      if (uniVal.isNotEmpty && uni == null) {
        setState(() => _maxUniDeductionError = 'Enter a valid number');
        hasError = true;
      }

      if (hasError) {
        if (mounted) {
          AppToast.showSnackBar(context, 
            const SnackBar(
              backgroundColor: SoftPalette.red400,
              content: Text('Please correct all validation errors to continue'),
            ),
          );
        }
        return;
      }

      if ((ptm! + msg! + att! + uni!) != base!) {
        if (mounted) {
          AppToast.showSnackBar(context, 
            SnackBar(
              backgroundColor: SoftPalette.red400,
              content: Text('Sum of deductions ($ptm + $msg + $att + $uni = ${ptm + msg + att + uni}) must equal Base Points ($base)'),
            ),
          );
        }
        return;
      }
    }

    setState(() => _isSaving = true);

    try {
      final Map<String, dynamic> updateData = {
        'year': _year,
        'month': _month,
        'ptmDay': _ptmDay,
      };

      if (isFeeEnabled && base != null) {
        updateData.addAll({
          'baseFee': base,
          'ptmDeduction': ptm,
          'messageTotalDeduction': msg,
          'attendanceMaxDeduction': att,
          'uniformMaxDeduction': uni,
        });
      }

      bool isRescheduled = _ptmDay != _initialPtmDay;
      int oldPtmDay = _initialPtmDay;

      if (isRescheduled) {
        final oldDate = oldPtmDay == 0 ? 'Auto (1st Fri)' : 'Day $oldPtmDay';
        final newDate = _ptmDay == 0 ? 'Auto (1st Fri)' : 'Day $_ptmDay';
        
        updateData['auditLog'] = FieldValue.arrayUnion([
          {
            'type': 'ptm_reschedule',
            'oldValue': oldDate,
            'newValue': newDate,
            'timestamp': Timestamp.now(),
            'month': _month,
            'year': _year,
          }
        ]);
      }

      await FirebaseFirestore.instance
          .collection('branches')
          .doc(widget.branchId)
          .collection('madrassa_config')
          .doc('current')
          .set(updateData, SetOptions(merge: true))
          .timeout(const Duration(seconds: 5));

      // Cache locally in Hive for instant future offline/local-first loading
      try {
        final box = await LocalStorageService.ensureBoxOpen(MadrassaLocalStorage.studentsBox);
        final key = '${widget.branchId.toLowerCase().trim()}__config__current';
        final cached = box.get(key);
        final merged = cached is Map ? Map<String, dynamic>.from(cached) : <String, dynamic>{};
        updateData.forEach((k, v) {
          if (k != 'auditLog') merged[k] = v;
        });
        await box.put(key, LocalStorageService.sanitize(merged));
      } catch (_) {}

      if (isRescheduled) {
        await _migratePtmAttendance(oldPtmDay, _ptmDay, _year, _month);
        _initialPtmDay = _ptmDay;
      }

      final oldDate = oldPtmDay == 0 ? 'Auto' : 'Day $oldPtmDay';
      final newDate = _ptmDay == 0 ? 'Auto' : 'Day $_ptmDay';
      String auditMessage = (isFeeEnabled && base != null)
          ? 'Madrassa configuration updated. Base: Rs. ${base.toInt()}, PTM: $newDate'
          : 'Madrassa configuration updated. PTM: $newDate';
      if (isRescheduled) {
        auditMessage += ' (PTM Rescheduled from $oldDate to $newDate)';
      }

      await MadrassaAuditService.logAction(
        branchId: widget.branchId,
        editor: widget.username,
        role: widget.role,
        type: isRescheduled ? 'ptm_reschedule' : 'config_change',
        message: auditMessage,
      );

      if (mounted) {
        AppToast.showSnackBar(context, 
          SnackBar(content: Text(context.l.configSaved)),
        );
      }
    } catch (e) {
      if (mounted) {
        AppToast.showSnackBar(context, 
          SnackBar(content: Text('Error saving: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _exportCsv(MadrassaCsvType type) async {
    setState(() => _isExporting = true);
    try {
      final saved = type == MadrassaCsvType.unknown
          ? await MadrassaCsvService.exportAll(widget.branchId)
          : await MadrassaCsvService.exportSingle(widget.branchId, type);

      if (!mounted) return;
      if (saved == 0) {
        AppToast.showSnackBar(context, 
          SnackBar(content: Text(context.l.exportCancelled)),
        );
      } else {
        AppToast.showSnackBar(context, 
          SnackBar(
            content: Text(
              type == MadrassaCsvType.unknown
                  ? context.l.exportAllSuccess
                  : context.l.exportSuccess,
            ),
            backgroundColor: SoftPalette.green400,
          ),
        );

        await MadrassaAuditService.logAction(
          branchId: widget.branchId,
          editor: widget.username,
          role: widget.role,
          type: 'csv_export',
          message: 'Madrassa CSV export (${type.name}) completed.',
        );
      }
    } catch (e) {
      if (mounted) {
        AppToast.showSnackBar(context, 
          SnackBar(content: Text('Export failed: $e'), backgroundColor: SoftPalette.red400),
        );
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _importCsv() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final bytes = result.files.first.bytes;
      if (bytes == null) return;
      final csvText = utf8.decode(bytes);
      final detectedType = MadrassaCsvService.detectCsvType(csvText);

      if (!mounted) return;
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(
            context.l.importCsvTitle,
            style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          content: Text(
            '${context.l.importCsvBody}\n\nDetected: ${detectedType.name}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(context.l.cancel, style: context.urduStyle()),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: SoftPalette.teal550),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                context.l.importCsv,
                style: context.urduStyle(style: const TextStyle(color: SoftPalette.gray50)),
              ),
            ),
          ],
        ),
      );
      if (confirm != true) return;

      setState(() => _isImporting = true);
      final importResult = await MadrassaCsvService.importCsv(
  branchId: widget.branchId,
  csvText: csvText,
  editor: widget.username,
);

      await MadrassaAuditService.logAction(
        branchId: widget.branchId,
        editor: widget.username,
        role: widget.role,
        type: 'csv_import',
        message: importResult.message,
      );
// Re-download/sync the local cache for any successfully parsed DailyLogs or Students CSV import,
// even if Firestore skipped writing identical rows (so that local Hive matches Firestore).
if (importResult.type == MadrassaCsvType.dailyLogs) {
  final monthsToSync = <String>{};
  final allRows = MadrassaCsvService.parseCsvRows(csvText);
  for (final row in allRows) {
    final d = row['date']?.trim();
    if (d != null && d.length >= 7) {
      monthsToSync.add(d.substring(0, 7));
    }
  }
  for (final ym in monthsToSync) {
    final parts = ym.split('-');
    if (parts.length == 2) {
      final y = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      if (y != null && m != null) {
        await MadrassaLocalStorage.downloadLogsForMonth(widget.branchId, y, m);
      }
    }
  }
} else if (importResult.type == MadrassaCsvType.students) {
  await MadrassaLocalStorage.downloadStudents(widget.branchId);
}
      if (mounted) {
        AppToast.showSnackBar(context, 
          SnackBar(
            content: Text('${context.l.importSuccess}: ${importResult.message}'),
            backgroundColor: (importResult.imported > 0 || importResult.skipped > 0) ? SoftPalette.green400 : SoftPalette.amber300,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        AppToast.showSnackBar(context, 
          SnackBar(
            content: Text('${context.l.importFailed}: $e'),
            backgroundColor: SoftPalette.red400,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: UserThemeService.listenable(widget.username),
      builder: (context, _, child) {
        final c = context.comfort;
        final scaffoldBg = c.surfaceSunken;

        return Scaffold(
          backgroundColor: scaffoldBg,
          body: LayoutBuilder(
            builder: (context, constraints) {
              final isMobile = constraints.maxWidth < kConfigMobileBreakpoint;
              final bool isFeeEnabled = LocalStorageService.isMadrassaFeeEnabled(widget.branchId);

              return SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: isMobile ? 16 : 24,
                  vertical: isMobile ? 18 : 24,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildWelcomeHeader(context),
                    const SizedBox(height: 24),
                    if (!isFeeEnabled)
                      _buildActivePeriodCard(context)
                    else if (isMobile) ...[
                      _buildActivePeriodCard(context),
                      const SizedBox(height: 20),
                      _buildDeductionsCard(context),
                    ] else ...[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: _buildActivePeriodCard(context)),
                          const SizedBox(width: 24),
                          Expanded(child: _buildDeductionsCard(context)),
                        ],
                      ),
                    ],
                    const SizedBox(height: 20),
                    _buildSaveConfigBar(context, isMobile: isMobile),
                    const SizedBox(height: 28),
                    _buildDataImportExportCard(context),
                    if (isMobile) ...[
                      const SizedBox(height: 24),
                      _buildAccountCard(context),
                    ],
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildSaveConfigBar(BuildContext context, {required bool isMobile}) {
    final c = context.comfort;
    final saveButton = FilledButton.icon(
      onPressed: _isSaving ? null : _save,
      icon: _isSaving
          ? SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: c.onBrand,
              ),
            )
          : const Icon(Icons.save_rounded, size: 18),
      label: Text(
        context.l.save,
        style: GText.label(c.onBrand).copyWith(fontFamilyFallback: const ['Noori']),
      ),
      style: FilledButton.styleFrom(
        backgroundColor: c.brand,
        foregroundColor: c.onBrand,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );

    if (isMobile) {
      return SizedBox(
        width: double.infinity,
        height: 46,
        child: saveButton,
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: MadrassaErp.cardRadius,
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 18,
            color: c.brand,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              context.isUrdu
                  ? 'تعلیمی سیشن اور کٹوتی کے قواعد محفوظ کرنے کے لیے کلک کریں۔'
                  : 'Changes to academic period and deduction rules will apply immediately upon saving.',
              style: GText.body2(c.textSecondary).copyWith(fontSize: 12.5, fontFamilyFallback: const ['Noori']),
            ),
          ),
          const SizedBox(width: 16),
          saveButton,
        ],
      ),
    );
  }

  Widget _buildAccountCard(BuildContext context) {
    final c = context.comfort;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: MadrassaErp.cardRadius,
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: c.brand.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(
              child: Text(
                widget.username.isNotEmpty ? widget.username[0].toUpperCase() : 'U',
                style: GText.body1Bold(c.brand),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MadrassaUrduAwareText(
                  widget.username,
                  color: c.textPrimary,
                  size: 14,
                  bold: true,
                ),
                const SizedBox(height: 2),
                Text(
                  '${widget.branchId.toUpperCase()} • ${widget.role.toUpperCase()}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GText.caption(c.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(
                    context.isUrdu ? 'لاگ آؤٹ' : 'Sign Out',
                    style: GText.h3(c.textPrimary).copyWith(fontFamilyFallback: const ['Noori']),
                  ),
                  content: Text(
                    context.isUrdu ? 'کیا آپ واقعی لاگ آؤٹ کرنا چاہتے ہیں؟' : 'Are you sure you want to sign out?',
                    style: GText.body2(c.textSecondary).copyWith(fontFamilyFallback: const ['Noori']),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(context.l.cancel, style: TextStyle(color: c.textMuted)),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: c.danger, foregroundColor: Colors.white),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(context.isUrdu ? 'لاگ آؤٹ' : 'Sign Out'),
                    ),
                  ],
                ),
              );

              if (confirm == true) {
                if (!context.mounted) return;
                final navigator = Navigator.of(context);
                await FirebaseAuth.instance.signOut();
                navigator.pushNamedAndRemoveUntil('/login', (_) => false);
              }
            },
            icon: Icon(Icons.logout_rounded, size: 16, color: c.danger),
            label: Text(
              context.isUrdu ? 'لاگ آؤٹ' : 'Sign Out',
              style: GText.caption(c.danger).copyWith(fontWeight: FontWeight.bold),
            ),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: c.danger.withValues(alpha: 0.3)),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWelcomeHeader(BuildContext context) {
    final c = context.comfort;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: MadrassaErp.cardRadius,
        border: Border.all(color: c.border),
      ),
      padding: const EdgeInsets.all(20),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isMobile = constraints.maxWidth < 600;

          final settingsIconBadge = Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: c.brandSoft,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.settings_suggest_rounded,
              color: c.brand,
              size: 24,
            ),
          );

          final titleText = MadrassaUrduAwareText(
            context.l.configTitle,
            color: c.textPrimary,
            size: 18,
            bold: true,
          );

          final subtitleText = MadrassaUrduAwareText(
            'Set active month and rules',
            color: c.textMuted,
            size: 13,
            bold: false,
          );

          final manageHolidaysBtn = OutlinedButton.icon(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => HolidayManagementView(branchId: widget.branchId),
                ),
              );
            },
            icon: Icon(Icons.calendar_today_rounded, size: 15, color: c.brand),
            label: Text(
              'Manage Holidays',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: c.brand),
            ),
            style: OutlinedButton.styleFrom(
              backgroundColor: c.brandSoft,
              side: BorderSide(color: c.brand.withValues(alpha: 0.25)),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: const RoundedRectangleBorder(
                borderRadius: MadrassaErp.radius,
              ),
            ),
          );

          if (isMobile) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    settingsIconBadge,
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          titleText,
                          const SizedBox(height: 2),
                          subtitleText,
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: manageHolidaysBtn,
                ),
              ],
            );
          } else {
            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      settingsIconBadge,
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            titleText,
                            const SizedBox(height: 2),
                            subtitleText,
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                manageHolidaysBtn,
              ],
            );
          }
        },
      ),
    );
  }

  Widget _buildActivePeriodCard(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark || UserThemeService.isDarkMode(widget.username);
    final periodColor = isDark ? SoftPalette.blue350 : HSLColor.fromAHSL(1.0, 210, 0.65, 0.45).toColor();

    return _configCard(
      context: context,
      title: context.l.activePeriod,
      subtitle: 'Select active year, month, and PTM day',
      icon: Icons.calendar_month_rounded,
      hue: 210,
      trailing: TextButton.icon(
        onPressed: () {
          setState(() {
            _year = DateTime.now().year;
            _month = DateTime.now().month;
          });
          AppToast.showSnackBar(context, 
            SnackBar(
              content: Text(
                'Detected current period: ${DateFormat('MMMM yyyy').format(DateTime.now())}',
              ),
              duration: const Duration(seconds: 2),
            ),
          );
        },
        icon: Icon(Icons.autorenew_rounded, color: periodColor, size: 18),
        label: Text(
          'Auto Detect',
          style: TextStyle(color: periodColor, fontWeight: FontWeight.bold),
        ),
      ),
      child: Column(
        children: [
          _dropdownField(
            context,
            context.l.year,
            _year,
            List.generate(5, (i) => 2024 + i),
            (v) => setState(() => _year = v!),
            prefixIcon: Icons.calendar_today_rounded,
          ),
          const SizedBox(height: 16),
          _dropdownField(
            context,
            context.l.month,
            _month,
            List.generate(12, (i) => i + 1),
            (v) => setState(() => _month = v!),
            isMonth: true,
            prefixIcon: Icons.date_range_rounded,
          ),
          const SizedBox(height: 16),
          _dropdownField(
            context,
            context.l.ptmDay,
            _ptmDay,
            List.generate(32, (i) => i),
            (v) => setState(() => _ptmDay = v!),
            isPtmDay: true,
            prefixIcon: Icons.event_rounded,
          ),
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: MadrassaLocalStorage.streamHolidaysCached(widget.branchId),
            builder: (context, snapshot) {
              if (!snapshot.hasData) return const SizedBox.shrink();
              final ptmDate = getPtmDate();
              final hasHoliday = snapshot.data!.any((doc) {
                final dateObj = doc['date'];
                DateTime? d;
                if (dateObj is Timestamp) {
                  d = dateObj.toDate();
                } else if (dateObj is String) {
                  d = DateTime.tryParse(dateObj);
                } else if (dateObj is DateTime) {
                  d = dateObj;
                }
                if (d != null) {
                  return d.year == ptmDate.year &&
                      d.month == ptmDate.month &&
                      d.day == ptmDate.day;
                }
                return false;
              });

              if (hasHoliday) {
                return Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isDark ? SoftPalette.orange800.withValues(alpha: 0.5) : SoftPalette.pink100m,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: isDark ? SoftPalette.orange700 : SoftPalette.red200),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, color: isDark ? SoftPalette.red350 : SoftPalette.red500),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Warning: Selected PTM date falls on a holiday.',
                            style: TextStyle(
                              color: isDark ? SoftPalette.red300 : SoftPalette.red550,
                              fontWeight: FontWeight.w500,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }
              return const SizedBox.shrink();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildDataImportExportCard(BuildContext context) {
    final c = context.comfort;
    final busy = _isExporting || _isImporting;

    return _configCard(
      context: context,
      title: context.l.dataImportExport,
      subtitle: context.l.dataImportExportSubtitle,
      icon: Icons.swap_vert_rounded,
      hue: 280,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isMobile = constraints.maxWidth < 600;

          final studentsTile = _exportTile(
            context,
            label: context.l.exportStudents,
            subtitle: context.isUrdu ? 'طلباء کی فہرست' : 'Students Roster',
            icon: Icons.groups_outlined,
            iconColor: context.adapt(SoftPalette.teal550),
            onPressed: busy ? null : () => _exportCsv(MadrassaCsvType.students),
          );

          final dailyLogsTile = _exportTile(
            context,
            label: context.l.exportDailyLogs,
            subtitle: context.isUrdu ? 'حاضری اور اسباق' : 'Attendance & Logs',
            icon: Icons.event_note_outlined,
            iconColor: context.adapt(SoftPalette.blue350),
            onPressed: busy ? null : () => _exportCsv(MadrassaCsvType.dailyLogs),
          );

          final auditLogTile = _exportTile(
            context,
            label: context.l.exportAuditLog,
            subtitle: context.isUrdu ? 'سرگرمی لاگ' : 'Audit Trail',
            icon: Icons.history_edu_outlined,
            iconColor: context.adapt(SoftPalette.violet550),
            onPressed: busy ? null : () => _exportCsv(MadrassaCsvType.auditLog),
          );

          final exportAllTile = _exportTile(
            context,
            label: context.l.exportAllCsv,
            subtitle: context.isUrdu ? 'مکمل بیک اپ' : 'Complete Backup',
            icon: Icons.folder_zip_outlined,
            iconColor: context.adapt(SoftPalette.emerald350),
            isPrimary: true,
            onPressed: busy ? null : () => _exportCsv(MadrassaCsvType.unknown),
          );

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isMobile) ...[
                Row(
                  children: [
                    Expanded(child: studentsTile),
                    const SizedBox(width: 10),
                    Expanded(child: dailyLogsTile),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(child: auditLogTile),
                    const SizedBox(width: 10),
                    Expanded(child: exportAllTile),
                  ],
                ),
              ] else ...[
                Row(
                  children: [
                    Expanded(child: studentsTile),
                    const SizedBox(width: 12),
                    Expanded(child: dailyLogsTile),
                    const SizedBox(width: 12),
                    Expanded(child: auditLogTile),
                    const SizedBox(width: 12),
                    Expanded(child: exportAllTile),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              // Import / Restore Box
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: busy ? null : _importCsv,
                  borderRadius: MadrassaErp.radius,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: c.surfaceSunken,
                      borderRadius: MadrassaErp.radius,
                      border: Border.all(
                        color: c.border,
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: c.brandSoft,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: _isImporting
                              ? Center(
                                  child: SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: c.brand),
                                  ),
                                )
                              : Icon(
                                  Icons.upload_file_rounded,
                                  color: c.brand,
                                  size: 22,
                                ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                context.l.importCsv,
                                style: context.urduStyle(
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13.5,
                                    color: c.textPrimary,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                context.isUrdu
                                    ? 'CSV فائل سے طلباء یا لاگز بحال کریں'
                                    : 'Restore students, daily logs, or audit records from CSV',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: c.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.arrow_forward_ios_rounded,
                          size: 13,
                          color: c.brand,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_isExporting) ...[
                const SizedBox(height: 12),
                LinearProgressIndicator(color: c.brand),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _exportTile(
    BuildContext context, {
    required String label,
    required String subtitle,
    required IconData icon,
    required Color iconColor,
    required VoidCallback? onPressed,
    bool isPrimary = false,
  }) {
    final c = context.comfort;
    final cardBg = isPrimary ? c.brandSoft : c.surface;
    final borderColor = isPrimary ? c.brand.withValues(alpha: 0.35) : c.border;
    final textColor = c.textPrimary;
    final subColor = c.textMuted;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: MadrassaErp.radius,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: MadrassaErp.radius,
            border: Border.all(color: borderColor, width: 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: iconColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(icon, size: 17, color: iconColor),
                  ),
                  Icon(
                    Icons.arrow_downward_rounded,
                    size: 15,
                    color: isPrimary ? c.brand : subColor,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.urduStyle(
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    color: textColor,
                  ),
                ),
              ),
              const SizedBox(height: 1),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.urduStyle(
                  style: TextStyle(
                    fontSize: 10,
                    color: subColor,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDeductionsCard(BuildContext context) {
    final c = context.comfort;
    final bool isFeeEnabled = LocalStorageService.isMadrassaFeeEnabled(widget.branchId);

    return _configCard(
      context: context,
      title: context.l.deductionParams,
      subtitle: isFeeEnabled ? 'Rules for calculating pro-rated dues' : 'Financial System & Fees are disabled in Branch Facilities',
      icon: Icons.account_balance_wallet_rounded,
      hue: isFeeEnabled ? 35 : 200,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isFeeEnabled) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: c.warning.withValues(alpha: 0.12),
                borderRadius: MadrassaErp.radius,
                border: Border.all(color: c.warning.withValues(alpha: 0.35)),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded, color: c.warning, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Money Factor is disabled for this branch in Branch Facilities. Fee dues and deduction savings are turned off and hidden across all Parent, Teacher, and Principal screens.',
                      style: TextStyle(fontSize: 12, color: c.warning, fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
          ],
          Row(
            children: [
              Expanded(
                child: _textField(
                  context,
                  context.l.baseFee,
                  _baseFeeController,
                  isRequired: true,
                  errorText: _baseFeeError,
                  prefixIcon: Icons.money_rounded,
                  onChanged: (v) {
                    if (_baseFeeError != null) setState(() => _baseFeeError = null);
                  },
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _textField(
                  context,
                  context.l.ptmDeduction,
                  _ptmDeductionController,
                  isRequired: true,
                  errorText: _ptmDeductionError,
                  prefixIcon: Icons.discount_rounded,
                  onChanged: (v) {
                    if (_ptmDeductionError != null) setState(() => _ptmDeductionError = null);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _textField(
            context,
            context.l.messageDeduction,
            _msgDeductionController,
            isRequired: true,
            errorText: _msgDeductionError,
            prefixIcon: Icons.sms_rounded,
            onChanged: (v) {
              if (_msgDeductionError != null) setState(() => _msgDeductionError = null);
            },
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _textField(
                  context,
                  context.l.maxAttSavings,
                  _maxAttDeductionController,
                  isRequired: true,
                  errorText: _maxAttDeductionError,
                  prefixIcon: Icons.check_circle_outline_rounded,
                  onChanged: (v) {
                    if (_maxAttDeductionError != null) setState(() => _maxAttDeductionError = null);
                  },
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _textField(
                  context,
                  context.l.maxUniSavings,
                  _maxUniDeductionController,
                  isRequired: true,
                  errorText: _maxUniDeductionError,
                  prefixIcon: Icons.checkroom_rounded,
                  onChanged: (v) {
                    if (_maxUniDeductionError != null) setState(() => _maxUniDeductionError = null);
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _configCard({
    required BuildContext context,
    required String title,
    required String subtitle,
    required Widget child,
    required IconData icon,
    required double hue,
    Widget? trailing,
  }) {
    final c = context.comfort;
    final accentColor = c.brand;
    final bgTint = c.brandSoft;

    return MadrassaCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: bgTint,
                  borderRadius: MadrassaErp.radius,
                ),
                child: Icon(icon, color: accentColor, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MadrassaUrduAwareText(
                      title,
                      color: c.textPrimary,
                      size: 16,
                      bold: true,
                    ),
                    const SizedBox(height: 2),
                    MadrassaUrduAwareText(
                      subtitle,
                      color: c.textMuted,
                      size: 12,
                      bold: false,
                    ),
                  ],
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
          const SizedBox(height: 20),
          child,
        ],
      ),
    );
  }

  Widget _textField(
    BuildContext context,
    String label,
    TextEditingController controller, {
    String? errorText,
    bool isRequired = false,
    ValueChanged<String>? onChanged,
    IconData? prefixIcon,
  }) {
    final c = context.comfort;
    final inputBg = c.surfaceSunken;
    final borderColor = c.border;
    final textPrimary = c.textPrimary;
    final labelColor = c.textPrimary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        isRequired
            ? RichText(
                text: TextSpan(
                  children: [
                    TextSpan(
                      text: label,
                      style: context.urduStyle(
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: labelColor,
                        ),
                      ),
                    ),
                    TextSpan(
                      text: ' *',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: c.danger),
                    ),
                  ],
                ),
              )
            : MadrassaUrduAwareText(
                label,
                color: labelColor,
                size: 13,
                bold: true,
              ),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          keyboardType: TextInputType.number,
          onChanged: onChanged,
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: textPrimary),
          decoration: InputDecoration(
            errorText: errorText,
            prefixIcon: prefixIcon != null ? Icon(prefixIcon, size: 20, color: c.textMuted) : null,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: MadrassaErp.radius,
              borderSide: BorderSide(color: borderColor),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: MadrassaErp.radius,
              borderSide: BorderSide(
                color: errorText != null ? c.danger : borderColor,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: MadrassaErp.radius,
              borderSide: BorderSide(color: c.brand, width: 2),
            ),
            filled: true,
            fillColor: inputBg,
          ),
        ),
      ],
    );
  }

  Widget _dropdownField(
    BuildContext context,
    String label,
    int value,
    List<int> items,
    ValueChanged<int?> onChanged, {
    bool isMonth = false,
    bool isPtmDay = false,
    IconData? prefixIcon,
  }) {
    final c = context.comfort;
    final cardBg = c.surface;
    final inputBg = c.surfaceSunken;
    final borderColor = c.border;
    final textPrimary = c.textPrimary;
    final labelColor = c.textPrimary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MadrassaUrduAwareText(
          label,
          color: labelColor,
          size: 13,
          bold: true,
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<int>(
          initialValue: value,
          dropdownColor: cardBg,
          items: items.map((i) {
            String text = '$i';
            if (isMonth) text = DateFormat('MMMM').format(DateTime(2024, i));
            if (isPtmDay) text = i == 0 ? 'Auto (1st Friday)' : 'Day $i';
            return DropdownMenuItem(value: i, child: Text(text, style: TextStyle(color: textPrimary)));
          }).toList(),
          onChanged: onChanged,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: textPrimary,
          ),
          decoration: InputDecoration(
            prefixIcon: prefixIcon != null ? Icon(prefixIcon, size: 20, color: c.textMuted) : null,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: MadrassaErp.radius,
              borderSide: BorderSide(color: borderColor),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: MadrassaErp.radius,
              borderSide: BorderSide(color: borderColor),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: MadrassaErp.radius,
              borderSide: BorderSide(color: c.brand, width: 2),
            ),
            filled: true,
            fillColor: inputBg,
          ),
        ),
      ],
    );
  }
}
