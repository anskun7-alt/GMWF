import 'package:flutter/material.dart';
import 'package:gmwf/design/tokens/comfort_colors.dart';
import '../utils/madrassa_local_storage.dart';
import '../../../../widgets/app_feedback.dart';
import '../madrassa_strings.dart';
import '../widgets/madrassa_erp.dart';

void showChangeStudentBranchDialog(
  BuildContext context, {
  required Map<String, dynamic> student,
  required String currentBranch,
  required String username,
  required String role,
  VoidCallback? onTransferred,
}) {
  final studentName = (student['name'] ?? 'Student').toString();
  final rollNumber = (student['rollNumber'] ?? '-').toString();
  final studentId = (student['id'] ?? student['studentId'] ?? '').toString();
  final initialBranch = MadrassaLocalStorage.normalizeBranch(
    (student['branchId'] ?? student['branch'] ?? currentBranch).toString(),
  );

  final availableBranches = MadrassaLocalStorage.getAvailableBranchesForSelection();
  String selectedBranch = initialBranch;
  if (!availableBranches.any((b) => b['id'] == selectedBranch) && availableBranches.isNotEmpty) {
    selectedBranch = availableBranches.first['id']!;
  }

  bool isTransferring = false;
  String? errorMessage;

  showDialog(
    context: context,
    barrierDismissible: !isTransferring,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setDs) {
        final c = context.comfort;

        return AlertDialog(
          backgroundColor: c.surface,
          shape: const RoundedRectangleBorder(borderRadius: MadrassaErp.cardRadius),
          titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          actionsPadding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: c.brandSoft,
                  borderRadius: MadrassaErp.radius,
                ),
                child: Icon(
                  Icons.swap_horiz_rounded,
                  color: c.brand,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.isUrdu ? 'طالب علم کی برانچ تبدیل کریں' : 'Change Student Branch',
                      style: context.urduStyle(
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: c.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      context.isUrdu ? 'صرف ہیڈ کوارٹر مینیجر (HQ Manager)' : 'HQ Manager Authorization',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: c.brand,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Student info card
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: c.surfaceSunken,
                    borderRadius: MadrassaErp.radius,
                    border: Border.all(color: c.border),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 20,
                        backgroundColor: c.brandSoft,
                        child: Text(
                          studentName.isNotEmpty ? studentName[0].toUpperCase() : 'S',
                          style: TextStyle(
                            color: c.brand,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              studentName,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                                color: c.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Roll #: $rollNumber • ${student['class'] ?? 'Hifz'}',
                              style: TextStyle(fontSize: 12, color: c.textMuted),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: c.warning.withValues(alpha: 0.12),
                          borderRadius: MadrassaErp.radius,
                          border: Border.all(color: c.warning.withValues(alpha: 0.3)),
                        ),
                        child: Text(
                          initialBranch.toUpperCase(),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: c.warning,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // Destination branch selector
                Text(
                  context.isUrdu ? 'نئی برانچ منتخب کریں:' : 'Select Target Branch:',
                  style: context.urduStyle(
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.bold,
                      color: c.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(height: 8),

                Container(
                  decoration: BoxDecoration(
                    color: c.surfaceSunken,
                    borderRadius: MadrassaErp.radius,
                    border: Border.all(
                      color: c.border,
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: selectedBranch,
                      isExpanded: true,
                      dropdownColor: c.surface,
                      icon: Icon(Icons.arrow_drop_down_rounded, color: c.brand),
                      items: availableBranches.map((b) {
                        final isCurrent = b['id'] == initialBranch;
                        return DropdownMenuItem<String>(
                          value: b['id']!,
                          child: Row(
                            children: [
                              Icon(
                                Icons.apartment_rounded,
                                size: 16,
                                color: isCurrent ? c.textMuted : c.brand,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  b['name']! + (isCurrent ? ' (Current / موجودہ)' : ''),
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: isCurrent ? FontWeight.normal : FontWeight.bold,
                                    color: isCurrent ? c.textMuted : c.textPrimary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                      onChanged: isTransferring
                          ? null
                          : (val) {
                              if (val != null) {
                                setDs(() {
                                  selectedBranch = val;
                                  errorMessage = null;
                                });
                              }
                            },
                    ),
                  ),
                ),

                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: c.brandSoft,
                    borderRadius: MadrassaErp.radius,
                    border: Border.all(color: c.brand.withValues(alpha: 0.2)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline_rounded, size: 16, color: c.brand),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          context.isUrdu
                              ? 'طالب علم صرف اپنی نئی منتخب شدہ برانچ میں نظر آئے گا اور پرانی برانچ کے ریکارڈز صاف کر دیے جائیں گے۔'
                              : 'Student will strictly appear only in the selected branch roster and daily logs. Old branch cache and references will be purged.',
                          style: context.urduStyle(
                            style: TextStyle(
                              fontSize: 11.5,
                              color: c.brand,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                if (errorMessage != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    errorMessage!,
                    style: TextStyle(color: c.danger, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: isTransferring ? null : () => Navigator.pop(ctx),
              child: Text(
                context.l.cancel,
                style: TextStyle(color: c.textMuted),
              ),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: c.brand,
                foregroundColor: c.onBrand,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                shape: const RoundedRectangleBorder(borderRadius: MadrassaErp.radius),
                elevation: 0,
              ),
              onPressed: isTransferring
                  ? null
                  : () async {
                      if (selectedBranch == initialBranch) {
                        setDs(() => errorMessage = context.isUrdu
                            ? 'براہ کرم کوئی مختلف برانچ منتخب کریں'
                            : 'Please select a different branch to transfer');
                        return;
                      }

                      setDs(() {
                        isTransferring = true;
                        errorMessage = null;
                      });

                      try {
                        await MadrassaLocalStorage.transferStudentBranch(
                          oldBranch: initialBranch,
                          newBranch: selectedBranch,
                          studentId: studentId,
                          studentData: student,
                          editorUsername: username,
                          editorRole: role,
                        );

                        if (ctx.mounted) {
                          Navigator.pop(ctx);
                          AppFeedback.showSuccess(
                            context,
                            context.isUrdu
                                ? 'طالب علم کی برانچ کامیابی سے تبدیل ہو گئی'
                                : 'Student transferred to ${selectedBranch.toUpperCase()} successfully!',
                            subtitle: 'Student roster updated and old branch records purged.',
                          );
                          onTransferred?.call();
                        }
                      } catch (e) {
                        if (ctx.mounted) {
                          setDs(() {
                            isTransferring = false;
                            errorMessage = 'Failed to transfer: $e';
                          });
                        }
                      }
                    },
              icon: isTransferring
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: c.onBrand),
                    )
                  : const Icon(Icons.check_circle_outline_rounded, size: 18),
              label: Text(
                context.isUrdu ? 'برانچ تبدیل کریں' : 'Transfer Student',
                style: context.urduStyle(
                  style: TextStyle(fontWeight: FontWeight.bold, color: c.onBrand),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}
