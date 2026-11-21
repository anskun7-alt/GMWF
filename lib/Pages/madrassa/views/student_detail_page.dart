import 'package:flutter/material.dart';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:gmwf/design/tokens/comfort_colors.dart';
import 'package:gmwf/design/components/app_toast.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import '../../../theme/role_theme_provider.dart';
import '../../../widgets/read_only_document_tile.dart';
import '../../../services/image_upload_service.dart';
import '../../../services/user_theme_service.dart';
import '../../../services/local_storage_service.dart';
import '../utils/madrassa_local_storage.dart';
import '../student_fee_ledger.dart';
import '../dialogs/enrollment_dialog.dart';
import '../dialogs/change_student_branch_dialog.dart';
import '../widgets/madrassa_status_menu.dart';
import '../widgets/madrassa_erp.dart';
import 'dart:async';
import '../../../services/sync_service.dart';
import '../../../realtime/realtime_manager.dart';
import '../../../realtime/realtime_events.dart';
import '../madrassa_strings.dart';

class StudentDetailPage extends StatefulWidget {
  final Map<String, dynamic> studentData;
  final String branchId;
  final bool isAdmin;
  final String username;
  final String role;

  const StudentDetailPage({
    super.key,
    required this.studentData,
    required this.branchId,
    required this.isAdmin,
    required this.username,
    this.role = 'Madrassa Teacher',
  });

  @override
  State<StudentDetailPage> createState() => _StudentDetailPageState();
}

class _StudentDetailPageState extends State<StudentDetailPage> {
  late Map<String, dynamic> _data;

  bool get _effectiveIsAdmin {
    final r = widget.role.toLowerCase().trim();
    return widget.isAdmin ||
        r.contains('admin') ||
        r.contains('chairman') ||
        r.contains('hq') ||
        r.contains('hq manager') ||
        r.contains('hqmanager') ||
        r.contains('hq_manager') ||
        r.contains('ceo') ||
        r.contains('principal') ||
        r.contains('manager') ||
        r.contains('director') ||
        r.contains('supervisor') ||
        r.contains('global');
  }

  bool get _isHQManager {
    final r = widget.role.toLowerCase().trim();
    return r.contains('hqmanager') ||
        r.contains('hq manager') ||
        r.contains('hq_manager') ||
        r == 'hq' ||
        r.contains('admin') ||
        r.contains('superadmin') ||
        r.contains('director') ||
        r.contains('chairman') ||
        r.contains('ceo');
  }

  String get _effectiveBranch => MadrassaLocalStorage.normalizeBranch(widget.branchId);

  @override
  void initState() {
    super.initState();
    _data = Map<String, dynamic>.from(widget.studentData);
  }

  Future<void> _showRevertQaidaDialog(BuildContext context, String studentId) async {
    final studentName = _data['name'] ?? 'Student';
    String selectedLesson = '21';

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            final isUrdu = ctx.isUrdu;
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: dialogCtx.adapt(SoftPalette.amber200).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.undo_rounded, color: dialogCtx.adapt(SoftPalette.orange350), size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      isUrdu ? 'قاعدہ تکمیل منسوخ کریں' : 'Revert Qaida Completion',
                      style: ctx.urduStyle(style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isUrdu
                        ? 'کیا آپ $studentName کے لیے قاعدہ کی تکمیل منسوخ کرنا چاہتے ہیں؟ موجودہ تختی / سبق منتخب کریں:'
                        : 'Revert accidental Qaida completion for $studentName. Select current lesson to resume from:',
                    style: ctx.urduStyle(style: TextStyle(fontSize: 13, color: dialogCtx.adapt(SoftPalette.gray900A87))),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    isUrdu ? 'سبق / تختی:' : 'Qaida Lesson (1–21):',
                    style: ctx.urduStyle(style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: dialogCtx.adapt(SoftPalette.gray350))),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      border: Border.all(color: dialogCtx.adapt(SoftPalette.gray150)),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: selectedLesson,
                        isExpanded: true,
                        items: [
                          for (int i = 21; i >= 1; i--)
                            DropdownMenuItem<String>(
                              value: '$i',
                              child: Text(
                                isUrdu ? 'سبق $i (تختی $i)' : 'Lesson $i',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                            ),
                        ],
                        onChanged: (val) {
                          if (val != null) {
                            setDialogState(() {
                              selectedLesson = val;
                            });
                          }
                        },
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(isUrdu ? 'منسوخ' : 'Cancel'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: SoftPalette.orange350,
                    foregroundColor: SoftPalette.gray50,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(isUrdu ? 'منسوخ اور محفوظ کریں' : 'Revert & Save'),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirm == true) {
      final studentCache = MadrassaLocalStorage.getStudentCached(_effectiveBranch, studentId) ?? Map<String, dynamic>.from(_data);
      studentCache['qaidaCompleted'] = false;
      studentCache['qaidaSabak'] = selectedLesson;
      studentCache['lastUpdatedAt'] = DateTime.now().toIso8601String();

      final auditList = List<Map<String, dynamic>>.from(
        (studentCache['auditLog'] as List? ?? []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)),
      );
      auditList.add({
        'status': studentCache['status'] ?? 'active',
        'type': 'qaida_reverted',
        'date': DateTime.now().toIso8601String(),
        'reason': 'Reverted Qaida completion to Lesson $selectedLesson',
      });
      studentCache['auditLog'] = auditList;

      await MadrassaLocalStorage.cacheStudent(_effectiveBranch, studentId, studentCache);

      setState(() {
        _data['qaidaCompleted'] = false;
        _data['qaidaSabak'] = selectedLesson;
      });

      // Broadcast LAN
      try {
        final payload = RealtimeEvents.payload(
          type: RealtimeEvents.saveMadrassaStudent,
          data: {
            ...studentCache,
            'studentId': studentId,
          },
          branchId: _effectiveBranch,
        );
        RealtimeManager().sendMessage(payload);
      } catch (e) {
        debugPrint('[StudentDetailPage] LAN broadcast error: $e');
      }

      // Enqueue sync & upload
      try {
        await LocalStorageService.enqueueSync({
          'type': 'save_madrassa_student',
          'branchId': _effectiveBranch,
          'studentId': studentId,
          'data': studentCache,
        });
        unawaited(SyncService().triggerUpload());
      } catch (e) {
        debugPrint('[StudentDetailPage] enqueueSync error: $e');
      }

      await MadrassaAuditService.logAction(
        branchId: _effectiveBranch,
        editor: widget.username,
        role: widget.role,
        type: 'qaida_reverted',
        message: 'Reverted Qaida completion for $studentName to Lesson $selectedLesson by ${widget.username} (${widget.role}).',
        studentId: studentId,
        studentName: studentName,
      );

      if (context.mounted) {
        AppToast.showSnackBar(context, 
          SnackBar(
            content: Text(
              context.isUrdu
                  ? '$studentName کے لیے قاعدہ تکمیل منسوخ ہو گئی (سبق $selectedLesson)'
                  : 'Qaida completion reverted for $studentName to Lesson $selectedLesson',
            ),
            backgroundColor: SoftPalette.orange350,
          ),
        );
      }
    }
  }

  DateTime _parseDate(dynamic val) {
    if (val is Timestamp) return val.toDate();
    if (val is String) return DateTime.tryParse(val) ?? DateTime.now();
    return DateTime.now();
  }

  Widget _buildAvatarFallback(String? name, {double fontSize = 28}) {
    final initial = name != null && name.isNotEmpty ? name[0].toUpperCase() : '?';
    return Container(
      color: context.adapt(SoftPalette.teal550).withValues(alpha: 0.15),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: context.adapt(SoftPalette.teal550),
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildDetailRow(IconData icon, String label, String value) {
    final c = context.comfort;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: c.brand),
          const SizedBox(width: 12),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: c.textMuted,
              fontWeight: FontWeight.w500,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: c.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final studentId = _data['id']?.toString() ?? '';
    if (!Hive.isBoxOpen(LocalStorageService.madrassaStudentsBox)) {
      return FutureBuilder<Box>(
        future: LocalStorageService.ensureBoxOpen(LocalStorageService.madrassaStudentsBox),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Scaffold(
              body: Center(child: CircularProgressIndicator(color: context.adapt(SoftPalette.teal550))),
            );
          }
          return _buildDetailPageWithBox(context, snapshot.data!, studentId);
        },
      );
    }
    return _buildDetailPageWithBox(context, Hive.box(LocalStorageService.madrassaStudentsBox), studentId);
  }

  Widget _buildDetailPageWithBox(BuildContext context, Box studentsBox, String studentId) {
    return ValueListenableBuilder(
      valueListenable: studentsBox.listenable(),
      builder: (context, Box box, _) {
        final cached = MadrassaLocalStorage.getStudentCached(_effectiveBranch, studentId);
        if (cached != null) {
          _data = {'id': studentId, ...cached};
        }

        final name = _data['name'] ?? 'Student';
        final rollNumber = _data['rollNumber'] ?? '?';
        final className = _data['class'] ?? 'Hifz';
        final photoUrl = (_data['photoUrl'] ??
            _data['photo_url'] ??
            _data['photoBase64'] ??
            _data['studentPhotoBase64'] ??
            _data['avatarUrl'] ??
            _data['imageUrl'] ??
            _data['profileImage'])?.toString();
        final status = _data['status'] ?? 'active';

        final currentLines = int.tryParse(_data['currentLines']?.toString() ?? '0') ?? 0;
        final isNazra = (_data['isNazra'] == true) ||
            (_data['program']?.toString().toLowerCase() == 'nazra') ||
            (_data['class']?.toString().toLowerCase() == 'nazra') ||
            LocalStorageService.isMadrassaNazraOnly(_effectiveBranch);
        final prevLines = isNazra ? 0 : (int.tryParse(_data['prevHifzLines']?.toString() ?? '0') ?? 0);
        final totalLines = currentLines + prevLines;
        const maxLines = 8640;
        final pct = ((totalLines / maxLines) * 100).clamp(0.0, 100.0).toStringAsFixed(1);
        final isQaidaComp = _data['qaidaCompleted'] == true || _data['qaidaSabak'] == 'completed';
        final qaidaLesson = int.tryParse(_data['qaidaSabak']?.toString() ?? '1') ?? 1;

        final String? bFormUrl = _data['bFormUrl'] ?? _data['bFormBase64'];
        final String? guardianCnicUrl = _data['guardianCnicUrl'] ?? _data['guardianCnicBase64'];
        final String? hifzCertificateUrl = _data['hifzCertificateUrl'] ?? _data['hifzCertificateBase64'];

        final c = context.comfort;
        final isDark = UserThemeService.isDarkMode(widget.username);
        final scaffoldBg = c.surfaceSunken;
        final cardBg = c.surface;
        final textPrimary = c.textPrimary;
        final borderColor = c.border;

        return Scaffold(
          backgroundColor: scaffoldBg,
          appBar: AppBar(
            backgroundColor: cardBg,
            elevation: 0,
            scrolledUnderElevation: 0,
            shape: Border(bottom: BorderSide(color: borderColor, width: 1)),
            leading: IconButton(
              icon: Icon(Icons.arrow_back_rounded, color: textPrimary),
              onPressed: () => Navigator.pop(context),
            ),
            title: Text(
              name,
              style: TextStyle(
                color: textPrimary,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
            actions: [
              StatusActionMenu(
                student: _data,
                branchId: _effectiveBranch,
                isAdmin: _effectiveIsAdmin,
                t: RoleThemeScope.dataOf(context),
                username: widget.username,
                role: widget.role,
              ),
              IconButton(
                icon: Icon(Icons.receipt_long_rounded, color: context.adapt(SoftPalette.blue500)),
                tooltip: 'Student Fee Ledger & Receipts',
                onPressed: () {
                  final feeVal = double.tryParse(_data['monthlyFee']?.toString() ?? '0') ?? 0.0;
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => StudentFeeLedgerScreen(
                        branchId: _effectiveBranch,
                        studentId: studentId,
                        studentName: name,
                        fatherName: _data['fatherName']?.toString(),
                        rollNumber: rollNumber,
                        monthlyFee: feeVal,
                      ),
                    ),
                  );
                },
              ),
              IconButton(
                icon: Icon(Icons.edit_note_rounded, color: context.adapt(SoftPalette.teal550)),
                tooltip: 'Edit Student Details',
                onPressed: () => showAddStudentDialog(
                  context,
                  _effectiveBranch,
                  student: _data,
                  username: widget.username,
                  role: widget.role,
                ),
              ),
              if (_isHQManager)
                IconButton(
                  icon: Icon(Icons.swap_horiz_rounded, color: context.adapt(SoftPalette.indigo500)),
                  tooltip: context.isUrdu ? 'طالب علم کی برانچ تبدیل کریں' : 'Change Student Branch',
                  onPressed: () => showChangeStudentBranchDialog(
                    context,
                    student: _data,
                    currentBranch: _effectiveBranch,
                    username: widget.username,
                    role: widget.role,
                    onTransferred: () {
                      Navigator.pop(context);
                    },
                  ),
                ),
              const SizedBox(width: 8),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Center(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 800),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header card
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: cardBg,
                        borderRadius: MadrassaErp.cardRadius,
                        border: Border.all(color: borderColor),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: borderColor, width: 2),
                            ),
                            child: ClipOval(
                              child: () {
                                final str = photoUrl?.toString().trim();
                                final bytes = ImageUploadService.decodeBase64ToBytes(str);
                                if (bytes != null) {
                                  return Image.memory(
                                    bytes,
                                    fit: BoxFit.cover,
                                    width: 64,
                                    height: 64,
                                    errorBuilder: (_, __, ___) => _buildAvatarFallback(name),
                                  );
                                } else if (str != null && str.startsWith('http')) {
                                  return Image.network(
                                    str,
                                    fit: BoxFit.cover,
                                    width: 64,
                                    height: 64,
                                    errorBuilder: (_, __, ___) => _buildAvatarFallback(name),
                                  );
                                }
                                return _buildAvatarFallback(name);
                              }(),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                MadrassaUrduAwareText(
                                  name,
                                  color: textPrimary,
                                  size: 20,
                                  bold: true,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Roll #: $rollNumber • Class: $className',
                                  style: TextStyle(
                                    color: c.textMuted,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: c.brandSoft,
                                    borderRadius: MadrassaErp.radius,
                                  ),
                                  child: Text(
                                    'Status: ${status.toUpperCase()}',
                                    style: TextStyle(
                                      color: c.brand,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Progress card
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: cardBg,
                        borderRadius: MadrassaErp.cardRadius,
                        border: Border.all(color: borderColor),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (isNazra) ...[
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      'Qaida & Nazra Progress',
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.bold,
                                        color: textPrimary,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: isQaidaComp
                                            ? context.adapt(SoftPalette.green400).withValues(alpha: 0.15)
                                            : context.adapt(SoftPalette.teal500).withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(
                                          color: isQaidaComp
                                              ? context.adapt(SoftPalette.green400).withValues(alpha: 0.4)
                                              : context.adapt(SoftPalette.teal500).withValues(alpha: 0.4),
                                        ),
                                      ),
                                      child: Text(
                                        isQaidaComp ? 'قاعدہ مکمل ✅' : 'سبق نمبر $qaidaLesson / ۲۱',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: isQaidaComp ? context.adapt(SoftPalette.green400) : (isDark ? SoftPalette.teal300 : SoftPalette.teal550),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                Text(
                                  isQaidaComp ? '100%' : '${((qaidaLesson / 21) * 100).clamp(0, 100).toStringAsFixed(0)}%',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: isQaidaComp ? context.adapt(SoftPalette.green400) : (isDark ? SoftPalette.teal300 : SoftPalette.teal550),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: LinearProgressIndicator(
                                value: isQaidaComp ? 1.0 : (qaidaLesson / 21).clamp(0.0, 1.0),
                                backgroundColor: isDark ? SoftPalette.slate700 : SoftPalette.slate100,
                                valueColor: AlwaysStoppedAnimation<Color>(isQaidaComp ? context.adapt(SoftPalette.green400) : context.adapt(SoftPalette.teal550)),
                                minHeight: 10,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      'Qaida Status: ${isQaidaComp ? "Completed / مکمل ✅" : "Lesson $qaidaLesson of 21"}',
                                      style: TextStyle(fontSize: 12, color: context.adapt(SoftPalette.gray500)),
                                    ),
                                    if (isQaidaComp) ...[
                                      const SizedBox(width: 8),
                                      InkWell(
                                        onTap: () => _showRevertQaidaDialog(context, studentId),
                                        borderRadius: BorderRadius.circular(4),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: context.adapt(SoftPalette.amber200).withValues(alpha: 0.15),
                                            borderRadius: BorderRadius.circular(4),
                                            border: Border.all(color: context.adapt(SoftPalette.amber300).withValues(alpha: 0.5)),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons.undo_rounded, size: 11, color: context.adapt(SoftPalette.orange350)),
                                              const SizedBox(width: 3),
                                              Text(
                                                'Revert',
                                                style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: context.adapt(SoftPalette.orange350)),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                Text(
                                  'Nazra Sabak: $currentLines lines',
                                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: textPrimary),
                                ),
                              ],
                            ),
                          ] else ...[
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Memorization Progress',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                    color: textPrimary,
                                  ),
                                ),
                                Text(
                                  '$pct%',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: isDark ? SoftPalette.teal300 : SoftPalette.teal550,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: LinearProgressIndicator(
                                value: (totalLines / maxLines).clamp(0.0, 1.0),
                                backgroundColor: isDark ? SoftPalette.slate700 : SoftPalette.slate100,
                                valueColor: AlwaysStoppedAnimation<Color>(context.adapt(SoftPalette.teal550)),
                                minHeight: 10,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Current: $currentLines lines',
                                  style: TextStyle(fontSize: 12, color: context.adapt(SoftPalette.gray500)),
                                ),
                                Text(
                                  'Prior Hifz: $prevLines lines',
                                  style: TextStyle(fontSize: 12, color: context.adapt(SoftPalette.gray500)),
                                ),
                                Text(
                                  'Total: $totalLines / $maxLines',
                                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: textPrimary),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Personal info card
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: cardBg,
                        borderRadius: MadrassaErp.cardRadius,
                        border: Border.all(color: borderColor),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.person_outline_rounded, color: c.brand),
                              const SizedBox(width: 10),
                              Text(
                                'Student Personal Details',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  color: textPrimary,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Divider(color: borderColor),
                          _buildDetailRow(
                            Icons.credit_card_rounded,
                            'Student CNIC / B-Form #',
                            _data['studentCnic']?.toString().isNotEmpty == true ? _data['studentCnic'] : 'Not Provided',
                          ),
                          _buildDetailRow(
                            Icons.category_rounded,
                            'Program / Class',
                            isNazra ? 'Nazra (ناظرہ قرآن)' : 'Hifz (حفظ قرآن)',
                          ),
                          _buildDetailRow(
                            Icons.schedule_rounded,
                            'Shift / Session',
                            (_data['session']?.toString().toLowerCase() == 'evening')
                                ? '🌅 Evening Shift'
                                : (_data['session']?.toString().toLowerCase() == 'night')
                                    ? '🌙 Night Shift'
                                    : '☀️ Morning Shift',
                          ),
                          _buildDetailRow(
                            Icons.person_rounded,
                            'Gender',
                            (_data['gender']?.toString().toLowerCase() == 'female' || _data['gender']?.toString().toLowerCase() == 'girl')
                                ? '👧 Girl (Female)'
                                : '👦 Boy (Male)',
                          ),
                          _buildDetailRow(
                            Icons.calendar_today_rounded,
                            'Join Date',
                            _data['joinDate'] != null ? DateFormat('dd MMMM yyyy').format(_parseDate(_data['joinDate'])) : 'Not Provided',
                          ),
                          if (_data['hasPrevMadrassa'] == true && !isNazra) ...[
                            _buildDetailRow(
                              Icons.school_outlined,
                              'Previous Madrassa',
                              _data['prevMadrassaName'] ?? 'Not Provided',
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Guardian info card
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: cardBg,
                        borderRadius: MadrassaErp.cardRadius,
                        border: Border.all(color: borderColor),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.family_restroom_rounded, color: c.brand),
                              const SizedBox(width: 10),
                              Text(
                                'Guardian / Parent Details',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  color: textPrimary,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Divider(color: borderColor),
                          _buildDetailRow(
                            Icons.badge_outlined,
                            'Guardian Name',
                            _data['guardianName'] ?? 'Not Provided',
                          ),
                          _buildDetailRow(
                            Icons.credit_card_outlined,
                            'Guardian CNIC',
                            _data['guardianCnic'] ?? 'Not Provided',
                          ),
                          _buildDetailRow(
                            Icons.phone_outlined,
                            'Contact Phone',
                            _data['contactPhone'] ?? _data['phone'] ?? 'Not Provided',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Documents Card
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: cardBg,
                        borderRadius: MadrassaErp.cardRadius,
                        border: Border.all(color: borderColor),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.folder_shared_outlined, color: c.brand),
                              const SizedBox(width: 10),
                              Text(
                                'Student & Guardian Documents',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  color: textPrimary,
                                ),
                              ),
                              const Spacer(),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: c.surfaceSunken,
                                  borderRadius: MadrassaErp.radius,
                                ),
                                child: Text(
                                  'Read Only',
                                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: c.textMuted),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Divider(color: borderColor),
                          const SizedBox(height: 8),
                          ReadOnlyDocumentTile(
                            label: 'Guardian CNIC Document',
                            icon: Icons.badge_outlined,
                            documentUri: guardianCnicUrl,
                          ),
                          const SizedBox(height: 12),
                          ReadOnlyDocumentTile(
                            label: 'B-Form / Birth Certificate',
                            icon: Icons.assignment_ind_outlined,
                            documentUri: bFormUrl,
                          ),
                          if (hifzCertificateUrl != null && hifzCertificateUrl.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            ReadOnlyDocumentTile(
                              label: 'Certificate of Hifz Completion',
                              icon: Icons.workspace_premium_outlined,
                              documentUri: hifzCertificateUrl,
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
