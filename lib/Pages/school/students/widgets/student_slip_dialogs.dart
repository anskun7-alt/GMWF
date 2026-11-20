// lib/pages/school/students/widgets/student_slip_dialogs.dart
//
// Admission slip preview and student documents viewer (Phase 6: migrated to
// gmwf_ui tokens, GText.urdu, GIcons and dynamic branch name).

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';

import '../../../../services/local_storage_service.dart';
import '../../../../widgets/media_upload_tile.dart';
import '../../models/school_student.dart';
import '../../utils/school_admission_pdf_service.dart';
import '../../widgets/erp/school_erp.dart';

void showStudentDocumentsDialog(BuildContext context, SchoolStudent student) {
  final docCount = (student.photoUrl.isNotEmpty ? 1 : 0) +
      (student.guardianCnicUrl.isNotEmpty ? 1 : 0) +
      (student.bformUrl.isNotEmpty ? 1 : 0) +
      student.additionalDocuments.length;

  showDialog<void>(
    context: context,
    builder: (ctx) {
      final c = ctx.comfort;
      return AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: Gr.modal),
        title: Row(children: [
          Icon(GIcons.layers, color: c.brand),
          const SizedBox(width: Gsp.sp2 + 2),
          Expanded(
            child: Text('Student documents ($docCount) — ${student.name}', style: GText.h3(c.textPrimary)),
          ),
        ]),
        content: SizedBox(
          width: 580,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (student.photoUrl.isNotEmpty) ...[
                  Text('Student profile photo / تصویر طالب علم', style: GText.label(c.textSecondary)),
                  const SizedBox(height: Gsp.sp1 + 2),
                  MediaUploadTile(label: 'Student photo', icon: GIcons.profile, initialValue: student.photoUrl, readOnly: true),
                  const SizedBox(height: Gsp.sp3),
                ],
                if (student.guardianCnicUrl.isNotEmpty) ...[
                  Text("Father's CNIC / شناختی کارڈ والد", style: GText.label(c.textSecondary)),
                  const SizedBox(height: Gsp.sp1 + 2),
                  MediaUploadTile(label: "Father's CNIC", icon: GIcons.employee, isDocument: true, initialValue: student.guardianCnicUrl, readOnly: true),
                  const SizedBox(height: Gsp.sp3),
                ],
                if (student.bformUrl.isNotEmpty) ...[
                  Text('B-Form / birth certificate / ب فارم', style: GText.label(c.textSecondary)),
                  const SizedBox(height: Gsp.sp1 + 2),
                  MediaUploadTile(label: 'B-Form / birth certificate', icon: GIcons.receiptLong, isDocument: true, initialValue: student.bformUrl, readOnly: true),
                  const SizedBox(height: Gsp.sp3),
                ],
                if (student.additionalDocuments.isNotEmpty) ...[
                  Text('Other attached documents / دیگر دستاویزات', style: GText.label(c.textSecondary)),
                  const SizedBox(height: Gsp.sp1 + 2),
                  for (final doc in student.additionalDocuments)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Gsp.sp2),
                      child: MediaUploadTile(
                        label: doc['name'] ?? 'Document',
                        icon: GIcons.layers,
                        isDocument: true,
                        initialValue: doc['url'],
                        readOnly: true,
                      ),
                    ),
                ],
                if (docCount == 0)
                  const AppEmptyState(
                    icon: GIcons.layers,
                    title: 'No documents uploaded yet',
                    subtitle: 'Edit the student record to attach photo, CNIC or B-Form.',
                    compact: true,
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      );
    },
  );
}

void showStudentAdmissionSlip(BuildContext context, SchoolStudent student, {VoidCallback? onEdit}) {
  final branchName = LocalStorageService.getBranchName(student.branchId);
  showDialog<void>(
    context: context,
    builder: (ctx) {
      final c = ctx.comfort;
      return Dialog(
        shape: RoundedRectangleBorder(borderRadius: Gr.modal),
        backgroundColor: c.surface,
        child: Container(
          width: 640,
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.9),
          padding: const EdgeInsets.all(Gsp.sp5),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Official admission form preview
                Container(
                  padding: const EdgeInsets.all(Gsp.sp4),
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: SchoolErp.radius,
                    border: Border.all(color: c.textPrimary, width: 1.5),
                  ),
                  child: Column(children: [
                    Text(
                      'تعلیم و تربیت سکول سسٹم',
                      textAlign: TextAlign.center,
                      textDirection: TextDirection.rtl,
                      style: GText.urdu(c.textPrimary, size: 22, weight: FontWeight.w700),
                    ),
                    Text(
                      'گلزار مدینہ ویلفیئر فاؤنڈیشن · $branchName',
                      textAlign: TextAlign.center,
                      textDirection: TextDirection.rtl,
                      style: GText.urdu(c.textSecondary, size: 13),
                    ),
                    const SizedBox(height: Gsp.sp2),
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Image.asset(
                        'assets/logo/twt.webp',
                        height: 36,
                        errorBuilder: (_, _, _) => Icon(GIcons.student, color: c.brand, size: GIconSize.lg),
                      ),
                      const SizedBox(width: Gsp.sp2 + 2),
                      Text(
                        'داخلہ فارم',
                        textDirection: TextDirection.rtl,
                        style: GText.urdu(c.textPrimary, size: 18, weight: FontWeight.w700),
                      ),
                    ]),
                    Divider(color: c.textPrimary, thickness: 1),
                    const SizedBox(height: Gsp.sp2),

                    // Meta row
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      Text('Date / تاریخ: ${student.admissionDate}', style: GText.label(c.textPrimary)),
                      Text('Adm no: ${student.admissionNo} · Roll: ${student.rollNo}', style: GText.label(c.brand)),
                    ]),
                    const SizedBox(height: Gsp.sp3),

                    _SlipRow(label: 'Student name / نام طالب علم', value: student.name),
                    _SlipRow(label: 'Father name / والد کا نام', value: student.guardianName),
                    _SlipRow(label: 'B-Form no / ب فارم نمبر', value: student.bformNo.isNotEmpty ? student.bformNo : '—'),
                    _SlipRow(label: 'Father CNIC / شناختی کارڈ والد', value: student.guardianCnic.isNotEmpty ? student.guardianCnic : '—'),
                    _SlipRow(label: 'Date of birth / تاریخ پیدائش', value: student.dob.isNotEmpty ? student.dob : '—'),
                    _SlipRow(label: 'Class & section / کلاس', value: '${student.grade}-${student.section} (${student.academicGroup})'),
                    _SlipRow(label: 'Profession / پیشہ', value: student.fatherProfession.isNotEmpty ? student.fatherProfession : '—'),
                    _SlipRow(label: 'Phone / فون نمبر', value: student.guardianPhone),
                    _SlipRow(label: 'Address / گھر کا پتہ', value: student.address.isNotEmpty ? student.address : '—'),
                    _SlipRow(label: 'Previous school / سابقہ ادارہ', value: student.previousSchool.isNotEmpty ? student.previousSchool : '—'),
                    if (student.biometricPin.isNotEmpty)
                      _SlipRow(label: 'Biometric PIN / بائیو میٹرک پن', value: student.biometricPin),
                    const SizedBox(height: Gsp.sp4),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Text('دستخط والدین', textDirection: TextDirection.rtl, style: GText.urdu(c.textPrimary, size: 14)),
                        SizedBox(width: 120, child: Divider(color: c.textPrimary, thickness: 1)),
                      ]),
                    ),
                  ]),
                ),
                const SizedBox(height: Gsp.sp4),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: Gsp.sp2,
                  runSpacing: Gsp.sp2,
                  children: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
                    OutlinedButton.icon(
                      onPressed: () => SchoolAdmissionPdfService.printAdmissionSlip(student),
                      icon: const Icon(GIcons.print, size: 16),
                      label: const Text('Print / PDF'),
                    ),
                    if (onEdit != null)
                      FilledButton.icon(
                        onPressed: () {
                          Navigator.pop(ctx);
                          onEdit();
                        },
                        icon: const Icon(GIcons.edit, size: 16),
                        label: const Text('Edit admission'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _SlipRow extends StatelessWidget {
  const _SlipRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gsp.sp1),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 220, child: Text(label, style: GText.caption(c.textMuted))),
        Expanded(child: Text(value, style: GText.body2Bold(c.textPrimary))),
      ]),
    );
  }
}
