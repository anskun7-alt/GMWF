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
import '../../../services/local_storage_service.dart';
import '../../../services/user_theme_service.dart';

// Breakpoints for responsive configuration sizing
const double kConfigMobileBreakpoint = 800.0;

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
    final doc = await FirebaseFirestore.instance
        .collection('branches')
        .doc(widget.branchId)
        .collection('madrassa_config')
        .doc('current')
        .get();
    if (doc.exists && mounted) {
      final data = doc.data()!;
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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              backgroundColor: Colors.red,
              content: Text('Please correct all validation errors to continue'),
            ),
          );
        }
        return;
      }

      if ((ptm! + msg! + att! + uni!) != base!) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: Colors.red,
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l.configSaved)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l.exportCancelled)),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              type == MadrassaCsvType.unknown
                  ? context.l.exportAllSuccess
                  : context.l.exportSuccess,
            ),
            backgroundColor: Colors.green,
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e'), backgroundColor: Colors.red),
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
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0F766E)),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                context.l.importCsv,
                style: context.urduStyle(style: const TextStyle(color: Colors.white)),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${context.l.importSuccess}: ${importResult.message}'),
            backgroundColor: (importResult.imported > 0 || importResult.skipped > 0) ? Colors.green : Colors.orange,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${context.l.importFailed}: $e'),
            backgroundColor: Colors.red,
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
      builder: (context, _, __) {
        final isDark = Theme.of(context).brightness == Brightness.dark || UserThemeService.isDarkMode(widget.username);
        final scaffoldBg = isDark ? const Color(0xFF0F172A) : const Color(0xFFF8F9FD);

        return Scaffold(
          backgroundColor: scaffoldBg,
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildWelcomeHeader(context),
                const SizedBox(height: 32),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final bool isFeeEnabled = LocalStorageService.isMadrassaFeeEnabled(widget.branchId);
                    final isMobile = constraints.maxWidth < kConfigMobileBreakpoint;
                    if (!isFeeEnabled) {
                      return _buildActivePeriodCard(context);
                    }
                    if (isMobile) {
                      return Column(
                        children: [
                          _buildActivePeriodCard(context),
                          const SizedBox(height: 24),
                          _buildDeductionsCard(context),
                        ],
                      );
                    } else {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: _buildActivePeriodCard(context)),
                          const SizedBox(width: 24),
                          Expanded(child: _buildDeductionsCard(context)),
                        ],
                      );
                    }
                  },
                ),
                const SizedBox(height: 32),
                _buildDataImportExportCard(context),
                const SizedBox(height: 32),
                Align(
                  alignment: Alignment.centerRight,
                  child: ElevatedButton.icon(
                    onPressed: _isSaving ? null : _save,
                    icon: _isSaving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.save_outlined),
                    label: Text(
                      context.l.save,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0F766E),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      elevation: 2,
                    ),
                  ),
                ),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isMobile = MediaQuery.of(context).size.width < kConfigMobileBreakpoint;
                    if (isMobile) {
                      return Column(
                        children: [
                          const SizedBox(height: 24),
                          SizedBox(
                            width: double.infinity,
                            height: 52,
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                final navigator = Navigator.of(context);
                                await FirebaseAuth.instance.signOut();
                                navigator.pushNamedAndRemoveUntil('/login', (_) => false);
                              },
                              icon: const Icon(Icons.logout_rounded, color: Colors.redAccent),
                              label: const Text(
                                'Sign Out',
                                style: TextStyle(
                                  color: Colors.redAccent,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(color: Colors.redAccent, width: 1.5),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildWelcomeHeader(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF0F766E), Color(0xFF10B981)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F766E).withValues(alpha: 0.3),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.all(24),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isMobile = constraints.maxWidth < 600;

          final settingsIconBadge = Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.settings_suggest_rounded,
              color: Colors.white,
              size: 28,
            ),
          );

          final titleText = Text(
            context.l.configTitle,
            style: context.urduStyle(
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          );

          final subtitleText = Text(
            'Set active month and rules',
            style: context.urduStyle(
              style: TextStyle(
                fontSize: 14,
                color: Colors.white.withValues(alpha: 0.85),
              ),
            ),
          );

          final manageHolidaysBtn = ElevatedButton.icon(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => HolidayManagementView(branchId: widget.branchId),
                ),
              );
            },
            icon: const Icon(Icons.calendar_today_rounded, size: 16),
            label: const Text(
              'Manage Holidays',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.15),
              foregroundColor: Colors.white,
              shadowColor: Colors.transparent,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(30),
                side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
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
                    const SizedBox(width: 16),
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
                const SizedBox(height: 20),
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
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            titleText,
                            const SizedBox(height: 4),
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
    final periodColor = isDark ? const Color(0xFF60A5FA) : HSLColor.fromAHSL(1.0, 210, 0.65, 0.45).toColor();

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
          ScaffoldMessenger.of(context).showSnackBar(
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
                      color: isDark ? const Color(0xFF451A03).withValues(alpha: 0.5) : Colors.red.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: isDark ? const Color(0xFF78350F) : Colors.red.shade100),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, color: isDark ? const Color(0xFFF87171) : Colors.red.shade700),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Warning: Selected PTM date falls on a holiday.',
                            style: TextStyle(
                              color: isDark ? const Color(0xFFFCA5A5) : Colors.red.shade800,
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
          final exportButtons = [
            _csvActionButton(
              context,
              label: context.l.exportStudents,
              icon: Icons.groups_outlined,
              onPressed: busy ? null : () => _exportCsv(MadrassaCsvType.students),
            ),
            _csvActionButton(
              context,
              label: context.l.exportDailyLogs,
              icon: Icons.event_note_outlined,
              onPressed: busy ? null : () => _exportCsv(MadrassaCsvType.dailyLogs),
            ),
            _csvActionButton(
              context,
              label: context.l.exportAuditLog,
              icon: Icons.history_edu_outlined,
              onPressed: busy ? null : () => _exportCsv(MadrassaCsvType.auditLog),
            ),
            _csvActionButton(
              context,
              label: context.l.exportAllCsv,
              icon: Icons.folder_zip_outlined,
              onPressed: busy ? null : () => _exportCsv(MadrassaCsvType.unknown),
              filled: true,
            ),
          ];

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isMobile)
                ...exportButtons.map((b) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: SizedBox(width: double.infinity, child: b),
                    ))
              else
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: exportButtons,
                ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: busy ? null : _importCsv,
                  icon: _isImporting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.upload_file_outlined),
                  label: Text(
                    context.l.importCsv,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF0F766E),
                    side: const BorderSide(color: Color(0xFF0F766E)),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
              if (_isExporting)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: LinearProgressIndicator(color: Color(0xFF0F766E)),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _csvActionButton(
    BuildContext context, {
    required String label,
    required IconData icon,
    required VoidCallback? onPressed,
    bool filled = false,
  }) {
    if (filled) {
      return ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF0F766E),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      );
    }

    final isDark = Theme.of(context).brightness == Brightness.dark || UserThemeService.isDarkMode(widget.username);

    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF44474E),
        side: BorderSide(color: isDark ? const Color(0xFF334155) : const Color(0xFFD0D3D9)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }

  Widget _buildDeductionsCard(BuildContext context) {
    final bool isFeeEnabled = LocalStorageService.isMadrassaFeeEnabled(widget.branchId);
    final isDark = Theme.of(context).brightness == Brightness.dark || UserThemeService.isDarkMode(widget.username);

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
                color: isDark ? const Color(0xFF451A03).withValues(alpha: 0.5) : const Color(0xFFFFFBEB),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: isDark ? const Color(0xFF78350F) : const Color(0xFFF59E0B)),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded, color: isDark ? const Color(0xFFFBBF24) : const Color(0xFFD97706), size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Money Factor is disabled for this branch in Branch Facilities. Fee dues and deduction savings are turned off and hidden across all Parent, Teacher, and Principal screens.',
                      style: TextStyle(fontSize: 12, color: isDark ? const Color(0xFFFDE68A) : const Color(0xFF92400E), fontWeight: FontWeight.w500),
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
    final isDark = Theme.of(context).brightness == Brightness.dark || UserThemeService.isDarkMode(widget.username);
    final cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;
    final borderColor = isDark ? const Color(0xFF334155) : Colors.grey.withValues(alpha: 0.12);
    final textPrimary = isDark ? Colors.white : const Color(0xFF1A1C1E);
    final textMuted = isDark ? const Color(0xFF94A3B8) : Colors.grey;

    final accentColor = HSLColor.fromAHSL(1.0, hue, 0.65, isDark ? 0.60 : 0.45).toColor();
    final bgTint = HSLColor.fromAHSL(1.0, hue, 0.65, isDark ? 0.20 : 0.94).toColor();

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: borderColor),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1A1C1E).withValues(alpha: isDark ? 0.2 : 0.04),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: bgTint,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: accentColor, size: 22),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: context.urduStyle(
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                          color: textPrimary,
                        ),
                      ),
                    ),
                    Text(
                      subtitle,
                      style: context.urduStyle(
                        style: TextStyle(fontSize: 12, color: textMuted),
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
          const SizedBox(height: 24),
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
    final isDark = Theme.of(context).brightness == Brightness.dark || UserThemeService.isDarkMode(widget.username);
    final inputBg = isDark ? const Color(0xFF0F172A) : Colors.white;
    final borderColor = isDark ? const Color(0xFF334155) : const Color(0xFFE0E2E7);
    final textPrimary = isDark ? Colors.white : const Color(0xFF1A1C1E);
    final labelColor = isDark ? Colors.white70 : const Color(0xFF44474E);

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
                    const TextSpan(
                      text: ' *',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFFD32F2F)),
                    ),
                  ],
                ),
              )
            : Text(
                label,
                style: context.urduStyle(
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: labelColor,
                  ),
                ),
              ),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          keyboardType: TextInputType.number,
          onChanged: onChanged,
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: textPrimary),
          decoration: InputDecoration(
            errorText: errorText,
            prefixIcon: prefixIcon != null ? Icon(prefixIcon, size: 20, color: isDark ? const Color(0xFF94A3B8) : null) : null,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: borderColor),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: errorText != null ? const Color(0xFFD32F2F) : borderColor,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFF0F766E), width: 2),
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
    final isDark = Theme.of(context).brightness == Brightness.dark || UserThemeService.isDarkMode(widget.username);
    final cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;
    final inputBg = isDark ? const Color(0xFF0F172A) : Colors.white;
    final borderColor = isDark ? const Color(0xFF334155) : const Color(0xFFE0E2E7);
    final textPrimary = isDark ? Colors.white : Colors.black87;
    final labelColor = isDark ? Colors.white70 : const Color(0xFF44474E);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: context.urduStyle(
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: labelColor,
            ),
          ),
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
            prefixIcon: prefixIcon != null ? Icon(prefixIcon, size: 20, color: isDark ? const Color(0xFF94A3B8) : null) : null,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: borderColor),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: borderColor),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFF0F766E), width: 2),
            ),
            filled: true,
            fillColor: inputBg,
          ),
        ),
      ],
    );
  }
}
