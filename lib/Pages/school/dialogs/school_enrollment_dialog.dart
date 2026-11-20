// lib/pages/school/dialogs/school_enrollment_dialog.dart
//
// Student admission & edit form (School ERP Phase 2 + Phase 6 gmwf_ui migration).
// Built cleanly on gmwf_ui tokens (context.comfort, GText, GText.urdu, Gsp, Gr, GIcons).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gmwf_ui/gmwf_ui.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../../services/image_upload_service.dart';
import '../../../services/local_storage_service.dart';
import '../../../services/zkteco_network_service.dart';
import '../../../utils/formatters.dart';
import '../../../widgets/media_upload_tile.dart';
import '../constants/school_constants.dart';
import '../core/school_madrassa_transfer_reader.dart';
import '../models/school_student.dart';
import '../students/school_student_service.dart';
import '../students/student_rules.dart';
import '../students/widgets/student_dialogs.dart' show showStudentDuplicateDialog;
import '../utils/school_admission_pdf_service.dart';
import '../widgets/erp/school_erp.dart';

class SchoolEnrollmentDialog extends StatefulWidget {
  final String branchId;
  final SchoolStudent? studentToEdit;

  /// Saved on the record and in the audit log.
  final String editorName;

  /// Principal / School Admin may correct an admission number.
  final bool canEditAdmissionNo;

  const SchoolEnrollmentDialog({
    super.key,
    required this.branchId,
    this.studentToEdit,
    this.editorName = 'User',
    this.canEditAdmissionNo = false,
  });

  @override
  State<SchoolEnrollmentDialog> createState() => _SchoolEnrollmentDialogState();
}

class _SchoolEnrollmentDialogState extends State<SchoolEnrollmentDialog> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _admissionNoCtrl;
  late final TextEditingController _rollNoCtrl;
  late final TextEditingController _emergencyCtrl;
  late final TextEditingController _nameCtrl;
  late final TextEditingController _guardianNameCtrl;
  late final TextEditingController _bformNoCtrl;
  late final TextEditingController _guardianCnicCtrl;
  late final TextEditingController _fatherProfessionCtrl;
  late final TextEditingController _guardianPhoneCtrl;
  late final TextEditingController _addressCtrl;
  late final TextEditingController _previousSchoolCtrl;
  late final TextEditingController _biometricPinCtrl;

  String _bloodGroup = '';
  bool _rollAuto = true;
  Map<String, String> _fieldErrors = const {};

  String _selectedGrade = '1';
  String _selectedSection = 'A';
  String _selectedAcademicGroup = 'General';
  String _selectedGender = 'Male';
  DateTime _admissionDate = DateTime.now();
  DateTime? _dob;
  bool _parentSignatureConfirmed = false;

  String? _photoUrl;
  String? _guardianCnicUrl;
  String? _bformUrl;
  List<Map<String, String>> _additionalDocuments = [];

  String? _transferredMadrassaStudentId;
  String? _transferredMadrassaInfo;

  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final st = widget.studentToEdit;

    _admissionNoCtrl = TextEditingController(
      text: st?.admissionNo ?? SchoolStudentService.nextAdmissionNo(widget.branchId),
    );
    _rollNoCtrl = TextEditingController(text: st?.rollNo ?? '');
    _rollAuto = st == null;
    _emergencyCtrl = TextEditingController(text: st?.emergencyContact ?? '');
    _bloodGroup = st?.bloodGroup ?? '';
    _nameCtrl = TextEditingController(text: st?.name ?? '');
    _guardianNameCtrl = TextEditingController(text: st?.guardianName ?? '');
    _bformNoCtrl = TextEditingController(text: st?.bformNo ?? '');
    _guardianCnicCtrl = TextEditingController(text: st?.guardianCnic ?? '');
    _fatherProfessionCtrl = TextEditingController(text: st?.fatherProfession ?? '');
    _guardianPhoneCtrl = TextEditingController(text: _formatPhoneDigits(st?.guardianPhone ?? ''));
    _addressCtrl = TextEditingController(text: st?.address ?? '');
    _previousSchoolCtrl = TextEditingController(text: st?.previousSchool ?? '');

    final initialPin = st != null
        ? (ZkTecoNetworkService.getCredentialByEntityId(st.id)?.biometricPin ?? st.biometricPin)
        : '';
    _biometricPinCtrl = TextEditingController(text: initialPin);

    if (st != null) {
      _selectedGrade = SchoolConstants.grades.contains(st.grade) ? st.grade : SchoolConstants.grades.first;
      _selectedSection = SchoolConstants.sections.contains(st.section) ? st.section : SchoolConstants.sections.first;
      final availGroups = SchoolConstants.getAcademicGroupsForGrade(_selectedGrade);
      _selectedAcademicGroup = availGroups.contains(st.academicGroup) ? st.academicGroup : availGroups.first;
      _selectedGender = st.gender == 'Female' ? 'Female' : 'Male';
      _parentSignatureConfirmed = st.parentSignatureConfirmed;
      if (st.transferredFromMadrassaId.isNotEmpty) {
        _transferredMadrassaStudentId = st.transferredFromMadrassaId;
        _transferredMadrassaInfo = 'Madrassa record ${st.transferredFromMadrassaId}';
      }
      _photoUrl = st.photoUrl;
      _guardianCnicUrl = st.guardianCnicUrl;
      _bformUrl = st.bformUrl;
      _additionalDocuments = st.additionalDocuments.map((d) => Map<String, String>.from(d)).toList();

      if (st.admissionDate.isNotEmpty) {
        _admissionDate = DateTime.tryParse(st.admissionDate) ?? DateTime.now();
      }
      if (st.dob.isNotEmpty) {
        _dob = DateTime.tryParse(st.dob);
      }
    } else {
      _selectedGrade = '1';
      _selectedAcademicGroup = 'General';
      _suggestRoll();
    }
  }

  String get _academicYear => (widget.studentToEdit?.academicYear.isNotEmpty ?? false)
      ? widget.studentToEdit!.academicYear
      : StudentRules.academicYearOf(_admissionDate);

  void _suggestRoll() {
    if (!_rollAuto) return;
    _rollNoCtrl.text = StudentRules.suggestRollNo(
      SchoolStudentService.roster(widget.branchId).students,
      grade: _selectedGrade,
      section: _selectedSection,
      academicYear: _academicYear,
      exceptId: widget.studentToEdit?.id,
    );
  }

  String _formatPhoneDigits(String raw) {
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    return digits.length > 11 ? digits.substring(0, 11) : digits;
  }

  @override
  void dispose() {
    _admissionNoCtrl.dispose();
    _emergencyCtrl.dispose();
    _rollNoCtrl.dispose();
    _nameCtrl.dispose();
    _guardianNameCtrl.dispose();
    _bformNoCtrl.dispose();
    _guardianCnicCtrl.dispose();
    _fatherProfessionCtrl.dispose();
    _guardianPhoneCtrl.dispose();
    _addressCtrl.dispose();
    _previousSchoolCtrl.dispose();
    _biometricPinCtrl.dispose();
    super.dispose();
  }

  Future<void> _openMadrassaTransferPicker() async {
    var madrassaStudents = <Map<String, dynamic>>[];
    try {
      madrassaStudents = SchoolMadrassaTransferReader.students(widget.branchId);
      if (madrassaStudents.isEmpty) {
        madrassaStudents = SchoolMadrassaTransferReader.students('all');
      }
    } catch (e) {
      debugPrint('[SchoolEnrollmentDialog] Fetch madrassa students error: $e');
    }

    if (madrassaStudents.isEmpty) {
      if (mounted) AppFeedback.info(context, 'No Madrassa students found in local storage to transfer.');
      return;
    }

    final selected = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) {
        var filter = '';
        return StatefulBuilder(builder: (dctx, setPickerState) {
          final c = dctx.comfort;
          final filtered = madrassaStudents.where((s) {
            final q = filter.trim().toLowerCase();
            if (q.isEmpty) return true;
            final name = (s['name'] ?? '').toString().toLowerCase();
            final guardian = (s['guardianName'] ?? s['fatherName'] ?? '').toString().toLowerCase();
            final cnic = (s['studentCnic'] ?? s['bFormNo'] ?? s['bformNo'] ?? '').toString().toLowerCase();
            final roll = (s['rollNo'] ?? '').toString().toLowerCase();
            final pin = (s['biometricPin'] ?? '').toString();
            return name.contains(q) || guardian.contains(q) || cnic.contains(q) || roll.contains(q) || pin.contains(q);
          }).toList();

          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: Gr.modal),
            title: Row(children: [
              Icon(GIcons.swapDesk, color: c.brand),
              const SizedBox(width: Gsp.sp2 + 2),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Transfer from Madrassa (read-only)', style: GText.h3(c.textPrimary)),
                  Text('مدرسہ کے طالب علم کی تفصیلات درآمد کریں', style: GText.urdu(c.textMuted, size: 13)),
                ]),
              ),
            ]),
            content: SizedBox(
              width: 580,
              height: 440,
              child: Column(children: [
                TextField(
                  decoration: const InputDecoration(
                    hintText: 'Search by student name, father, CNIC or PIN…',
                    prefixIcon: Icon(GIcons.search, size: 18),
                    isDense: true,
                  ),
                  onChanged: (v) => setPickerState(() => filter = v),
                ),
                const SizedBox(height: Gsp.sp3),
                Expanded(
                  child: filtered.isEmpty
                      ? const AppEmptyState(icon: GIcons.searchOff, title: 'No matching Madrassa students', compact: true)
                      : ListView.separated(
                          itemCount: filtered.length,
                          separatorBuilder: (_, _) => Divider(height: 1, color: c.border),
                          itemBuilder: (_, idx) {
                            final std = filtered[idx];
                            final stdId = std['id']?.toString() ?? '';
                            final cred = ZkTecoNetworkService.getCredentialByEntityId(stdId);
                            final pin = cred?.biometricPin ?? std['biometricPin']?.toString() ?? '';
                            final photoBytes = ImageUploadService.decodeBase64ToBytes(std['photoUrl']?.toString() ?? '');

                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(vertical: Gsp.sp1),
                              leading: CircleAvatar(
                                backgroundColor: c.brandSoft,
                                backgroundImage: photoBytes != null && photoBytes.isNotEmpty ? MemoryImage(photoBytes) : null,
                                child: photoBytes == null || photoBytes.isEmpty ? Icon(GIcons.profile, color: c.brand) : null,
                              ),
                              title: Row(children: [
                                Flexible(child: Text(std['name']?.toString() ?? 'Unknown', style: GText.body2Bold(c.textPrimary))),
                                if (pin.isNotEmpty) ...[
                                  const SizedBox(width: Gsp.sp2),
                                  AppChip(label: 'PIN $pin', state: AppChipState.info),
                                ],
                              ]),
                              subtitle: Text(
                                'Father: ${std['guardianName'] ?? std['fatherName'] ?? '—'} · CNIC: ${std['studentCnic'] ?? std['bFormNo'] ?? '—'}',
                                style: GText.caption(c.textMuted),
                              ),
                              trailing: FilledButton(
                                onPressed: () => Navigator.pop(ctx, std),
                                child: const Text('Import'),
                              ),
                            );
                          },
                        ),
                ),
              ]),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
          );
        });
      },
    );

    if (selected != null && mounted) {
      final stdId = selected['id']?.toString() ?? '';
      final cred = ZkTecoNetworkService.getCredentialByEntityId(stdId);
      final pin = cred?.biometricPin ?? selected['biometricPin']?.toString() ?? '';

      setState(() {
        _transferredMadrassaStudentId = stdId;
        _transferredMadrassaInfo = '${selected['name']} (Madrassa student)';
        _nameCtrl.text = selected['name']?.toString() ?? '';
        _guardianNameCtrl.text = (selected['guardianName'] ?? selected['fatherName'] ?? '').toString();
        _bformNoCtrl.text = (selected['studentCnic'] ?? selected['bFormNo'] ?? selected['bformNo'] ?? '').toString();
        _guardianCnicCtrl.text = (selected['guardianCnic'] ?? selected['fatherCnic'] ?? '').toString();
        _guardianPhoneCtrl.text = _formatPhoneDigits((selected['contactPhone'] ?? selected['guardianPhone'] ?? selected['phone'] ?? '').toString());
        _addressCtrl.text = (selected['address'] ?? '').toString();
        _fatherProfessionCtrl.text = (selected['fatherProfession'] ?? '').toString();
        _previousSchoolCtrl.text = 'مدرسہ گلزار مدینہ (Madrassa Gulzar Madina Hifz)';
        _photoUrl = selected['photoUrl']?.toString() ?? _photoUrl;
        _guardianCnicUrl = selected['guardianCnicUrl']?.toString() ?? _guardianCnicUrl;
        _bformUrl = (selected['bFormUrl'] ?? selected['bformUrl'])?.toString() ?? _bformUrl;
        if (pin.isNotEmpty) _biometricPinCtrl.text = pin;
        final dobRaw = selected['dob']?.toString() ?? '';
        if (dobRaw.isNotEmpty) _dob = DateTime.tryParse(dobRaw);
      });

      AppFeedback.success(context, 'Imported details for "${selected['name']}" (read-only copy).');
    }
  }

  Future<void> _save({bool print = false, bool allowDuplicates = false}) async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isSaving = true;
      _fieldErrors = const {};
    });

    final isEdit = widget.studentToEdit != null;
    final enteredPin = _biometricPinCtrl.text.trim();
    final pinOwnerId = widget.studentToEdit?.id ?? '';

    try {
      if (enteredPin.isNotEmpty) {
        final conflict = ZkTecoNetworkService.findPinConflict(enteredPin, excludeEntityId: pinOwnerId);
        final isTransferredStudent = conflict != null &&
            _transferredMadrassaStudentId != null &&
            conflict.entityId == _transferredMadrassaStudentId;
        if (conflict != null && !isTransferredStudent) {
          throw StudentException(
            'PIN $enteredPin is already assigned to "${conflict.entityName}" (${conflict.branchId.toUpperCase()}). Choose a unique PIN.',
            fields: const {'biometricPin': 'PIN already in use'},
          );
        }
      }

      final form = <String, dynamic>{
        'admissionNo': _admissionNoCtrl.text.trim(),
        'rollNo': _rollNoCtrl.text.trim(),
        'name': _nameCtrl.text.trim(),
        'guardianName': _guardianNameCtrl.text.trim(),
        'fatherName': _guardianNameCtrl.text.trim(),
        'bformNo': _bformNoCtrl.text.trim(),
        'bForm': _bformNoCtrl.text.trim(),
        'guardianCnic': _guardianCnicCtrl.text.trim(),
        'fatherCnic': _guardianCnicCtrl.text.trim(),
        'dob': _dob != null ? DateFormat('yyyy-MM-dd').format(_dob!) : '',
        'grade': _selectedGrade,
        'section': _selectedSection,
        'academicGroup': _selectedAcademicGroup,
        'fatherProfession': _fatherProfessionCtrl.text.trim(),
        'profession': _fatherProfessionCtrl.text.trim(),
        'guardianPhone': _guardianPhoneCtrl.text.trim(),
        'phone': _guardianPhoneCtrl.text.trim(),
        'emergencyContact': _emergencyCtrl.text.trim(),
        'bloodGroup': _bloodGroup,
        'address': _addressCtrl.text.trim(),
        'previousSchool': _previousSchoolCtrl.text.trim(),
        'prevSchool': _previousSchoolCtrl.text.trim(),
        'biometricPin': enteredPin,
        'gender': _selectedGender,
        'photoUrl': _photoUrl ?? '',
        'guardianCnicUrl': _guardianCnicUrl ?? '',
        'bformUrl': _bformUrl ?? '',
        'additionalDocuments': _additionalDocuments,
        'admissionDate': DateFormat('yyyy-MM-dd').format(_admissionDate),
        'parentSignatureConfirmed': _parentSignatureConfirmed,
        if (!isEdit && _transferredMadrassaStudentId != null) 'transferredFromMadrassaId': _transferredMadrassaStudentId,
      };

      final studentId = await SchoolStudentService.save(
        branchId: widget.branchId,
        existingId: widget.studentToEdit?.id,
        form: form,
        editorName: widget.editorName,
        allowDuplicates: allowDuplicates,
        canEditAdmissionNo: widget.canEditAdmissionNo,
      );

      if (enteredPin.isNotEmpty) {
        try {
          await ZkTecoNetworkService.assignPinToEntity(
            entityId: studentId,
            entityName: _nameCtrl.text.trim(),
            entityType: 'school_student',
            branchId: widget.branchId,
            customPin: enteredPin,
          );
        } catch (e) {
          debugPrint('[SchoolEnrollmentDialog] PIN assignment failed: $e');
        }
      }

      final saved = SchoolStudentService.roster(widget.branchId).byId(studentId);
      if (!mounted) return;
      final parent = Navigator.of(context);
      final messengerContext = parent.context;
      parent.pop(true);
      if (messengerContext.mounted) {
        AppFeedback.success(
          messengerContext,
          isEdit ? 'Student profile updated' : 'Student enrolled — admission no. ${saved?.admissionNo ?? ''}',
        );
      }
      if (print && saved != null) {
        await SchoolAdmissionPdfService.printAdmissionSlip(saved);
      }
    } on StudentException catch (e) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _fieldErrors = e.fields;
      });
      if (e.duplicates.isNotEmpty) {
        final again = await showStudentDuplicateDialog(context, e.duplicates);
        if (again == true && mounted) await _save(print: print, allowDuplicates: true);
        return;
      }
      AppFeedback.error(context, e.message);
    } catch (e) {
      debugPrint('[SchoolEnrollmentDialog] save failed: $e');
      if (!mounted) return;
      setState(() => _isSaving = false);
      AppFeedback.error(context, 'Could not save the student: $e');
    }
  }

  Future<void> _addCustomDocumentDialog() async {
    final titleCtrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final c = ctx.comfort;
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: Gr.modal),
          title: Row(children: [
            Icon(GIcons.layers, color: c.brand),
            const SizedBox(width: Gsp.sp2 + 2),
            Expanded(child: Text('Add custom document / دیگر دستاویز', style: GText.h3(c.textPrimary))),
          ]),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Enter document title (e.g. School Leaving Certificate, Medical Certificate):', style: GText.body2(c.textSecondary)),
              const SizedBox(height: Gsp.sp3),
              TextField(
                controller: titleCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Document name / نام دستاویز *',
                  hintText: 'e.g. Previous School Leaving Certificate',
                  isDense: true,
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final text = titleCtrl.text.trim();
                if (text.isNotEmpty) Navigator.pop(ctx, text);
              },
              child: const Text('Add document'),
            ),
          ],
        );
      },
    );
    titleCtrl.dispose();

    if (result != null && result.isNotEmpty) {
      setState(() => _additionalDocuments.add({'name': result, 'url': ''}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final isEditing = widget.studentToEdit != null;
    final branchName = LocalStorageService.getBranchName(widget.branchId);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: Gr.modal),
      backgroundColor: c.surface,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 780,
          maxHeight: MediaQuery.sizeOf(context).height * 0.94,
        ),
        child: Padding(
          padding: const EdgeInsets.all(Gsp.sp5),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Dialog top bar
                Row(children: [
                  const GModuleTile(icon: GIcons.student, size: 36),
                  const SizedBox(width: Gsp.sp3),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(isEditing ? 'Edit student admission' : 'New student admission', style: GText.h3(c.textPrimary)),
                      Text('Taleem o Tarbiyat School System · $branchName · $_academicYear', style: GText.caption(c.textMuted)),
                    ]),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: _isSaving ? null : () => Navigator.of(context).pop(false),
                    icon: const Icon(GIcons.close),
                  ),
                ]),
                const SizedBox(height: Gsp.sp3),
                Divider(height: 1, color: c.border),

                // Scrollable body
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(vertical: Gsp.sp4),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      if (!isEditing) _buildMadrassaTransferBar(c),
                      _buildFormHeader(c, branchName),
                      const SizedBox(height: Gsp.sp4),
                      Divider(height: 1, color: c.border),
                      const SizedBox(height: Gsp.sp4),

                      _buildAdmissionNoAndDateRow(c),
                      const SizedBox(height: Gsp.sp4),
                      _buildFormFieldsSection(c),

                      const SizedBox(height: Gsp.sp5),
                      Divider(height: 1, color: c.border),
                      const SizedBox(height: Gsp.sp4),

                      _buildDocumentsSection(c),

                      const SizedBox(height: Gsp.sp5),
                      Divider(height: 1, color: c.border),
                      const SizedBox(height: Gsp.sp3),

                      _buildParentSignatureRow(c),
                    ]),
                  ),
                ),

                Divider(height: 1, color: c.border),
                const SizedBox(height: Gsp.sp3),

                // Footer action buttons
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: Gsp.sp2,
                  runSpacing: Gsp.sp2,
                  children: [
                    TextButton(
                      onPressed: _isSaving ? null : () => Navigator.of(context).pop(false),
                      child: const Text('Cancel / منسوخ'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _isSaving ? null : () => _save(print: true),
                      icon: const Icon(GIcons.print, size: 16),
                      label: const Text('Save & Print PDF'),
                    ),
                    FilledButton.icon(
                      onPressed: _isSaving ? null : () => _save(),
                      icon: _isSaving
                          ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: c.onBrand, strokeWidth: 2))
                          : const Icon(GIcons.checkCircle, size: 16),
                      label: Text(_isSaving ? 'Saving…' : (isEditing ? 'Save changes' : 'Enroll student')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMadrassaTransferBar(GComfortColors c) => Container(
        margin: const EdgeInsets.only(bottom: Gsp.sp3),
        padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3, vertical: Gsp.sp2),
        decoration: BoxDecoration(
          color: c.brandSoft,
          borderRadius: SchoolErp.radius,
          border: Border.all(color: c.brand.withValues(alpha: 0.3)),
        ),
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: Gsp.sp2,
          runSpacing: Gsp.sp2,
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(GIcons.madrassa, size: GIconSize.sm, color: c.brand),
              const SizedBox(width: Gsp.sp2),
              Text(
                _transferredMadrassaInfo != null
                    ? 'Imported from: $_transferredMadrassaInfo'
                    : 'Transfer student from Madrassa (Hifz / Nazra)?',
                style: GText.body2Bold(c.brand),
              ),
            ]),
            OutlinedButton.icon(
              icon: const Icon(GIcons.swapDesk, size: 16),
              label: Text(_transferredMadrassaInfo != null ? 'Change selection' : 'Import from Madrassa'),
              onPressed: _openMadrassaTransferPicker,
            ),
          ],
        ),
      );

  Widget _buildFormHeader(GComfortColors c, String branchName) => Container(
        padding: const EdgeInsets.all(Gsp.sp3),
        decoration: BoxDecoration(
          color: c.surfaceSunken,
          borderRadius: SchoolErp.radius,
          border: Border.all(color: c.border),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          ClipRRect(
            borderRadius: Gr.button,
            child: Image.asset(
              'assets/logo/twt.webp',
              height: 44,
              width: 44,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => Icon(GIcons.student, size: 36, color: c.brand),
            ),
          ),
          const SizedBox(width: Gsp.sp3),
          Flexible(
            child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Text(
                'تعلیم و تربیت سکول سسٹم · داخلہ فارم',
                textAlign: TextAlign.center,
                textDirection: TextDirection.rtl,
                style: GText.urdu(c.textPrimary, size: 20, weight: FontWeight.w700),
              ),
              Text(
                'Gulzar Madina Welfare Foundation · $branchName',
                textAlign: TextAlign.center,
                style: GText.caption(c.textMuted),
              ),
            ]),
          ),
        ]),
      );

  Widget _numberField({
    required GComfortColors c,
    required String label,
    required TextEditingController controller,
    required String errorKey,
    bool readOnly = false,
    String? helper,
    ValueChanged<String>? onChanged,
  }) =>
      TextFormField(
        controller: controller,
        readOnly: readOnly,
        onChanged: onChanged,
        style: GText.body2Bold(c.textPrimary),
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          helperMaxLines: 2,
          errorText: _fieldErrors[errorKey],
          isDense: true,
          filled: readOnly,
          fillColor: readOnly ? c.surfaceSunken : null,
          suffixIcon: readOnly ? Icon(GIcons.lock, size: 16, color: c.textMuted) : null,
        ),
        validator: (v) => v == null || v.trim().isEmpty ? 'Required / ضروری ہے' : null,
      );

  Widget _buildAdmissionNoAndDateRow(GComfortColors c) {
    final isEditing = widget.studentToEdit != null;
    final admission = _numberField(
      c: c,
      label: 'Admission No / داخلہ نمبر',
      controller: _admissionNoCtrl,
      errorKey: 'admissionNo',
      readOnly: !widget.canEditAdmissionNo,
      helper: isEditing ? null : 'Issued automatically for this branch',
    );
    final roll = _numberField(
      c: c,
      label: 'Roll No / رول نمبر',
      controller: _rollNoCtrl,
      errorKey: 'rollNo',
      helper: 'Class $_selectedGrade-$_selectedSection · $_academicYear',
      onChanged: (_) => _rollAuto = false,
    );
    final date = InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: _admissionDate,
          firstDate: DateTime(2015),
          lastDate: DateTime.now().add(const Duration(days: 60)),
        );
        if (picked != null) {
          setState(() => _admissionDate = picked);
          _suggestRoll();
        }
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: 'Admission Date / تاریخ داخلہ',
          errorText: _fieldErrors['admissionDate'],
          isDense: true,
          suffixIcon: Icon(GIcons.calendar, size: 16, color: c.brand),
        ),
        child: Text(DateFormat('dd-MM-yyyy').format(_admissionDate), style: GText.body2Bold(c.textPrimary)),
      ),
    );

    return LayoutBuilder(builder: (context, box) {
      if (box.maxWidth < 560) {
        return Column(children: [admission, const SizedBox(height: Gsp.sp3), roll, const SizedBox(height: Gsp.sp3), date]);
      }
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: admission),
        const SizedBox(width: Gsp.sp3),
        Expanded(child: roll),
        const SizedBox(width: Gsp.sp3),
        Expanded(child: date),
      ]);
    });
  }

  Widget _buildGenderAndHealthRow(GComfortColors c) {
    final gender = DropdownButtonFormField<String>(
      isExpanded: true,
      initialValue: _selectedGender,
      decoration: const InputDecoration(labelText: 'Gender / جنس *', isDense: true),
      items: const [
        DropdownMenuItem(value: 'Male', child: Text('Male / لڑکا')),
        DropdownMenuItem(value: 'Female', child: Text('Female / لڑکی')),
      ],
      onChanged: (v) => setState(() => _selectedGender = v ?? 'Male'),
    );
    final blood = DropdownButtonFormField<String>(
      isExpanded: true,
      initialValue: _bloodGroup,
      decoration: const InputDecoration(labelText: 'Blood group (optional)', isDense: true),
      items: [
        const DropdownMenuItem(value: '', child: Text('Not known')),
        for (final g in const ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-']) DropdownMenuItem(value: g, child: Text(g)),
      ],
      onChanged: (v) => setState(() => _bloodGroup = v ?? ''),
    );
    final emergency = TextFormField(
      controller: _emergencyCtrl,
      keyboardType: TextInputType.phone,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(11)],
      decoration: InputDecoration(
        labelText: 'Emergency contact (optional)',
        hintText: '03XXXXXXXXX',
        errorText: _fieldErrors['emergencyContact'],
        isDense: true,
      ),
      validator: (v) {
        final d = (v ?? '').trim();
        return d.isNotEmpty && d.length != 11 ? 'Must be 11 digits' : null;
      },
    );
    return LayoutBuilder(builder: (context, box) {
      if (box.maxWidth < 560) {
        return Column(children: [gender, const SizedBox(height: Gsp.sp3), blood, const SizedBox(height: Gsp.sp3), emergency]);
      }
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: gender),
        const SizedBox(width: Gsp.sp2),
        Expanded(child: blood),
        const SizedBox(width: Gsp.sp2),
        Expanded(flex: 2, child: emergency),
      ]);
    });
  }

  Widget _buildFormFieldsSection(GComfortColors c) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _bilingualField(c: c, urduLabel: 'نام طالب علم', englishLabel: 'Student full name', controller: _nameCtrl, errorKey: 'name', isRequired: true, hint: 'Enter student full name'),
          const SizedBox(height: Gsp.sp3),
          _bilingualField(c: c, urduLabel: 'والد کا نام', englishLabel: "Father's / guardian name", controller: _guardianNameCtrl, errorKey: 'guardianName', isRequired: true, hint: "Enter father's full name"),
          const SizedBox(height: Gsp.sp3),
          _bilingualField(
            c: c,
            urduLabel: 'بچے کا ب فارم نمبر',
            englishLabel: "Child's B-Form number",
            controller: _bformNoCtrl,
            errorKey: 'bformNo',
            hint: 'XXXXX-XXXXXXX-X',
            keyboardType: TextInputType.number,
            inputFormatters: [CNICInputFormatter(), LengthLimitingTextInputFormatter(15)],
          ),
          const SizedBox(height: Gsp.sp3),
          _bilingualField(
            c: c,
            urduLabel: 'والد کا شناختی کارڈ نمبر',
            englishLabel: "Father's CNIC number",
            controller: _guardianCnicCtrl,
            errorKey: 'guardianCnic',
            hint: 'XXXXX-XXXXXXX-X',
            keyboardType: TextInputType.number,
            inputFormatters: [CNICInputFormatter(), LengthLimitingTextInputFormatter(15)],
          ),
          const SizedBox(height: Gsp.sp3),
          _buildDobRow(c),
          const SizedBox(height: Gsp.sp3),
          _buildGenderAndHealthRow(c),
          const SizedBox(height: Gsp.sp3),
          _buildClassSectionAndStreamRow(c),
          const SizedBox(height: Gsp.sp3),
          _bilingualField(c: c, urduLabel: 'پیشہ', englishLabel: "Father's profession", controller: _fatherProfessionCtrl, hint: 'e.g. Business / Private job'),
          const SizedBox(height: Gsp.sp3),
          _bilingualField(
            c: c,
            urduLabel: 'فون نمبر',
            englishLabel: 'Contact phone (11 digits)',
            controller: _guardianPhoneCtrl,
            errorKey: 'guardianPhone',
            isRequired: true,
            hint: '03001234567',
            keyboardType: TextInputType.phone,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(11)],
            customValidator: (v) {
              if (v == null || v.trim().isEmpty) return 'Contact phone is required';
              if (v.trim().length != 11) return 'Phone number must be exactly 11 digits';
              return null;
            },
          ),
          const SizedBox(height: Gsp.sp3),
          _bilingualField(c: c, urduLabel: 'گھر کا پتہ', englishLabel: 'Home address', controller: _addressCtrl, hint: 'Street / Mohallah'),
          const SizedBox(height: Gsp.sp3),
          _bilingualField(c: c, urduLabel: 'سابقہ مدرسہ / سکول کا نام', englishLabel: 'Previous school / madrassa', controller: _previousSchoolCtrl, hint: 'Optional'),
          const SizedBox(height: Gsp.sp3),
          _bilingualField(
            c: c,
            urduLabel: 'بائیو میٹرک اسکینر پن',
            englishLabel: 'Biometric scanner PIN',
            controller: _biometricPinCtrl,
            errorKey: 'biometricPin',
            hint: 'Unique numeric PIN for attendance scanner',
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            prefixIcon: GIcons.fingerprint,
          ),
        ],
      );

  Widget _bilingualField({
    required GComfortColors c,
    required String urduLabel,
    required String englishLabel,
    required TextEditingController controller,
    bool isRequired = false,
    String? hint,
    TextInputType keyboardType = TextInputType.text,
    List<TextInputFormatter>? inputFormatters,
    IconData? prefixIcon,
    String? Function(String?)? customValidator,
    String? errorKey,
  }) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Flexible(
            child: Row(children: [
              if (prefixIcon != null) ...[Icon(prefixIcon, size: 15, color: c.brand), const SizedBox(width: Gsp.sp1 + 2)],
              Flexible(
                child: Text(
                  '$englishLabel${isRequired ? ' *' : ''}',
                  overflow: TextOverflow.ellipsis,
                  style: GText.label(c.textSecondary),
                ),
              ),
            ]),
          ),
          const SizedBox(width: Gsp.sp2),
          Text(urduLabel, textDirection: TextDirection.rtl, style: GText.urdu(c.textPrimary, size: 14)),
        ]),
        const SizedBox(height: Gsp.sp1),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          inputFormatters: inputFormatters,
          style: GText.body2(c.textPrimary),
          decoration: InputDecoration(
            hintText: hint,
            errorText: errorKey == null ? null : _fieldErrors[errorKey],
            isDense: true,
          ),
          validator: customValidator ?? (isRequired ? (v) => v == null || v.trim().isEmpty ? '$englishLabel is required' : null : null),
        ),
      ]);

  Widget _buildDobRow(GComfortColors c) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('Date of birth', style: GText.label(c.textSecondary)),
          Text('تاریخ پیدائش', textDirection: TextDirection.rtl, style: GText.urdu(c.textPrimary, size: 14)),
        ]),
        const SizedBox(height: Gsp.sp1),
        InkWell(
          onTap: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: _dob ?? DateTime(2015, 1, 1),
              firstDate: DateTime(2000),
              lastDate: DateTime.now(),
            );
            if (picked != null) setState(() => _dob = picked);
          },
          child: InputDecorator(
            decoration: InputDecoration(
              isDense: true,
              errorText: _fieldErrors['dob'],
              suffixIcon: Icon(GIcons.calendar, size: 16, color: c.brand),
            ),
            child: Text(
              _dob != null ? DateFormat('dd-MM-yyyy').format(_dob!) : 'Select date of birth',
              style: _dob != null ? GText.body2Bold(c.textPrimary) : GText.body2(c.textMuted),
            ),
          ),
        ),
      ]);

  Widget _buildClassSectionAndStreamRow(GComfortColors c) {
    final groupOptions = SchoolConstants.getAcademicGroupsForGrade(_selectedGrade);
    final isHigh = SchoolConstants.isHighSchool(_selectedGrade);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text('Class, section & academic stream', style: GText.label(c.textSecondary)),
        Text('کلاس اور تعلیمی گروپ', textDirection: TextDirection.rtl, style: GText.urdu(c.textPrimary, size: 14)),
      ]),
      const SizedBox(height: Gsp.sp1),
      Row(children: [
        Expanded(
          flex: 2,
          child: DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: _selectedGrade,
            decoration: const InputDecoration(labelText: 'Class / کلاس', isDense: true),
            items: [for (final g in SchoolConstants.grades) DropdownMenuItem(value: g, child: Text(g))],
            onChanged: (v) {
              if (v != null) {
                setState(() {
                  _selectedGrade = v;
                  final avail = SchoolConstants.getAcademicGroupsForGrade(v);
                  if (!avail.contains(_selectedAcademicGroup)) _selectedAcademicGroup = avail.first;
                  _suggestRoll();
                });
              }
            },
          ),
        ),
        const SizedBox(width: Gsp.sp2),
        Expanded(
          flex: 1,
          child: DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: _selectedSection,
            decoration: const InputDecoration(labelText: 'Section', isDense: true),
            items: [for (final s in SchoolConstants.sections) DropdownMenuItem(value: s, child: Text('Sec $s'))],
            onChanged: (v) {
              if (v != null) {
                setState(() {
                  _selectedSection = v;
                  _suggestRoll();
                });
              }
            },
          ),
        ),
        const SizedBox(width: Gsp.sp2),
        Expanded(
          flex: 2,
          child: DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: groupOptions.contains(_selectedAcademicGroup) ? _selectedAcademicGroup : groupOptions.first,
            decoration: InputDecoration(labelText: isHigh ? 'Stream / گروپ' : 'General', isDense: true),
            items: [for (final g in groupOptions) DropdownMenuItem(value: g, child: Text(g, overflow: TextOverflow.ellipsis))],
            onChanged: isHigh
                ? (v) {
                    if (v != null) setState(() => _selectedAcademicGroup = v);
                  }
                : null,
          ),
        ),
      ]),
    ]);
  }

  Widget _buildDocumentsSection(GComfortColors c) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Row(children: [
              Icon(GIcons.layers, size: GIconSize.sm, color: c.brand),
              const SizedBox(width: Gsp.sp2),
              Text('DOCUMENTS & PHOTO', style: GText.overline(c.textMuted)),
            ]),
            Text('دستاویزات اور تصویر', textDirection: TextDirection.rtl, style: GText.urdu(c.brand, size: 14)),
          ]),
          const SizedBox(height: Gsp.sp3),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: MediaUploadTile(
                label: 'طالب علم کی تصویر\nStudent photo',
                icon: GIcons.image,
                initialValue: _photoUrl,
                onChanged: (val) => setState(() => _photoUrl = val),
              ),
            ),
            const SizedBox(width: Gsp.sp2 + 2),
            Expanded(
              child: MediaUploadTile(
                label: 'والد کا شناختی کارڈ\nFather CNIC',
                icon: GIcons.employee,
                isDocument: true,
                initialValue: _guardianCnicUrl,
                onChanged: (val) => setState(() => _guardianCnicUrl = val),
              ),
            ),
            const SizedBox(width: Gsp.sp2 + 2),
            Expanded(
              child: MediaUploadTile(
                label: 'ب فارم / برتھ سرٹیفکیٹ\nB-Form / birth cert',
                icon: GIcons.receiptLong,
                isDocument: true,
                initialValue: _bformUrl,
                onChanged: (val) => setState(() => _bformUrl = val),
              ),
            ),
          ]),
          if (_additionalDocuments.isNotEmpty) ...[
            const SizedBox(height: Gsp.sp3),
            Text('Additional documents / دیگر دستاویزات', style: GText.caption(c.textMuted)),
            const SizedBox(height: Gsp.sp2),
            for (final (index, doc) in _additionalDocuments.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: Gsp.sp2),
                child: Row(children: [
                  Expanded(
                    child: MediaUploadTile(
                      label: doc['name'] ?? 'Custom document',
                      icon: GIcons.layers,
                      isDocument: true,
                      initialValue: doc['url'],
                      onChanged: (val) => setState(() => _additionalDocuments[index]['url'] = val ?? ''),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Remove document',
                    icon: Icon(GIcons.delete, color: c.danger, size: GIconSize.sm),
                    onPressed: () => setState(() => _additionalDocuments.removeAt(index)),
                  ),
                ]),
              ),
          ],
          const SizedBox(height: Gsp.sp2),
          OutlinedButton.icon(
            icon: const Icon(GIcons.add, size: 16),
            label: const Text('Add custom document / دیگر دستاویز منسلک کریں'),
            onPressed: _addCustomDocumentDialog,
          ),
        ],
      );

  Widget _buildParentSignatureRow(GComfortColors c) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Row(children: [
              Checkbox(
                value: _parentSignatureConfirmed,
                onChanged: (v) => setState(() => _parentSignatureConfirmed = v ?? false),
              ),
              Flexible(
                child: Text(
                  'Parent / guardian verified & declared (تصدیق شدہ)',
                  style: GText.body2Bold(c.textPrimary),
                ),
              ),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('دستخط والدین', textDirection: TextDirection.rtl, style: GText.urdu(c.textPrimary, size: 15)),
            SizedBox(width: 130, child: Divider(color: c.textPrimary, thickness: 1)),
          ]),
        ],
      );
}
