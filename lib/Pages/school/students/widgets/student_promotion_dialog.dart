// lib/pages/school/students/widgets/student_promotion_dialog.dart
//
// End-of-year bulk promotion dialog (School ERP plan §3.3, Phase 5).
// Principal / School Admin picks a source class, target academic year and
// effective date, reviews each active student (Promote / Hold back / Graduate /
// Skip), adjusts target section/stream if needed, and applies in one batch.

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../constants/school_constants.dart';
import '../../models/school_student.dart';
import '../../widgets/erp/school_erp.dart';
import '../promotion_rules.dart';
import '../school_student_service.dart';
import '../student_rules.dart';

Future<PromotionBatchResult?> showStudentPromotionDialog(
  BuildContext context, {
  required String branchId,
  required String editorName,
  required bool isPrincipal,
  String? initialGrade,
}) =>
    showDialog<PromotionBatchResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _StudentPromotionDialog(
        branchId: branchId,
        editorName: editorName,
        isPrincipal: isPrincipal,
        initialGrade: initialGrade,
      ),
    );

class _StudentPromotionDialog extends StatefulWidget {
  const _StudentPromotionDialog({
    required this.branchId,
    required this.editorName,
    required this.isPrincipal,
    this.initialGrade,
  });

  final String branchId;
  final String editorName;
  final bool isPrincipal;
  final String? initialGrade;

  @override
  State<_StudentPromotionDialog> createState() => _StudentPromotionDialogState();
}

class _StudentPromotionDialogState extends State<_StudentPromotionDialog> {
  late String _sourceGrade;
  String _sourceSection = 'All';
  late final TextEditingController _targetYearCtrl;
  DateTime _effectiveDate = DateTime.now();
  Map<String, PromotionDecision> _decisions = {};
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _sourceGrade = (widget.initialGrade != null && SchoolConstants.grades.contains(widget.initialGrade))
        ? widget.initialGrade!
        : SchoolConstants.grades.first;
    final curYear = StudentRules.academicYearOf(DateTime.now());
    _targetYearCtrl = TextEditingController(text: PromotionRules.nextAcademicYear(curYear));
    _resetDecisions();
  }

  @override
  void dispose() {
    _targetYearCtrl.dispose();
    super.dispose();
  }

  List<SchoolStudent> _candidates(StudentRoster roster) => roster.students
      .where((s) => s.isActive && s.grade == _sourceGrade && (_sourceSection == 'All' || s.section == _sourceSection))
      .toList();

  void _resetDecisions() {
    final roster = SchoolStudentService.roster(widget.branchId);
    final targetYear = _targetYearCtrl.text.trim();
    _decisions = {
      for (final s in _candidates(roster)) s.id: PromotionRules.defaultDecision(s, targetYear: targetYear),
    };
  }

  void _setAll(PromotionAction action, List<SchoolStudent> candidates) {
    setState(() {
      for (final s in candidates) {
        final cur = _decisions[s.id] ?? PromotionRules.defaultDecision(s, targetYear: _targetYearCtrl.text.trim());
        _decisions[s.id] = cur.copyWith(action: action);
      }
    });
  }

  Future<void> _apply(List<PromotionPlanRow> plan) async {
    final yearErr = PromotionRules.validateTargetYear(_targetYearCtrl.text);
    if (yearErr != null) {
      setState(() => _error = yearErr);
      return;
    }
    final activeChanges = plan.where((r) => r.action != PromotionAction.skip).length;
    if (activeChanges == 0) {
      setState(() => _error = 'Select at least one student to promote, hold back, or graduate.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await SchoolStudentService.promoteBatch(
        branchId: widget.branchId,
        sourceGrade: _sourceGrade,
        targetYear: _targetYearCtrl.text.trim(),
        effectiveDate: _effectiveDate,
        plan: plan,
        editorName: widget.editorName,
        isPrincipal: widget.isPrincipal,
      );
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e is StudentException ? e.message : '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final roster = SchoolStudentService.roster(widget.branchId);
    final candidates = _candidates(roster);
    final targetYear = _targetYearCtrl.text.trim();
    final nextGrade = PromotionRules.nextGradeOf(_sourceGrade);
    final isFinal = PromotionRules.isFinalGrade(_sourceGrade);
    final plan = PromotionRules.buildPlan(
      candidates: candidates,
      allStudents: roster.students,
      decisions: _decisions,
      targetYear: targetYear,
    );

    final toPromote = plan.where((r) => r.action == PromotionAction.promote).length;
    final toHold = plan.where((r) => r.action == PromotionAction.holdBack).length;
    final toGraduate = plan.where((r) => r.action == PromotionAction.graduate).length;
    final toSkip = plan.where((r) => r.action == PromotionAction.skip).length;
    final targetIsHighSchool = nextGrade != null && SchoolConstants.isHighSchool(nextGrade);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: Gr.modal),
      backgroundColor: c.surface,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 880,
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: Padding(
          padding: const EdgeInsets.all(Gsp.sp5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(children: [
                const GModuleTile(icon: GIcons.student, size: 36),
                const SizedBox(width: Gsp.sp3),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('End-of-year class promotion', style: GText.h3(c.textPrimary)),
                    Text(
                      isFinal
                          ? 'Final class ($_sourceGrade): active students graduate unless held back or skipped.'
                          : 'Move Class $_sourceGrade students to Class $nextGrade for the new session, with per-student hold-back.',
                      style: GText.caption(c.textMuted),
                    ),
                  ]),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  icon: const Icon(GIcons.close),
                ),
              ]),
              const SizedBox(height: Gsp.sp3),
              Divider(height: 1, color: c.border),
              const SizedBox(height: Gsp.sp3),

              // Controls row
              Wrap(
                spacing: Gsp.sp3,
                runSpacing: Gsp.sp2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SchoolErpFilter<String>(
                    label: 'Source class',
                    value: _sourceGrade,
                    width: 140,
                    options: {for (final g in SchoolConstants.grades) g: 'Class $g'},
                    onChanged: (v) => setState(() {
                      _sourceGrade = v;
                      _error = null;
                      _resetDecisions();
                    }),
                  ),
                  SchoolErpFilter<String>(
                    label: 'Section',
                    value: _sourceSection,
                    width: 120,
                    options: {'All': 'All', for (final s in SchoolConstants.sections) s: 'Section $s'},
                    onChanged: (v) => setState(() {
                      _sourceSection = v;
                      _resetDecisions();
                    }),
                  ),
                  SizedBox(
                    width: 150,
                    height: 38,
                    child: TextField(
                      controller: _targetYearCtrl,
                      style: GText.body2(c.textPrimary),
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: 'Target session',
                        hintText: '2027-28',
                        contentPadding: EdgeInsets.symmetric(horizontal: Gsp.sp3, vertical: 8),
                      ),
                      onChanged: (_) => setState(() => _error = null),
                    ),
                  ),
                  InkWell(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _effectiveDate,
                        firstDate: DateTime(2020),
                        lastDate: DateTime.now().add(const Duration(days: 31)),
                      );
                      if (picked != null) setState(() => _effectiveDate = picked);
                    },
                    child: SizedBox(
                      width: 165,
                      height: 38,
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          isDense: true,
                          labelText: 'Effective date',
                          suffixIcon: Icon(GIcons.calendar, size: 16),
                          contentPadding: EdgeInsets.symmetric(horizontal: Gsp.sp3, vertical: 6),
                        ),
                        child: Text(DateFormat('d MMM yyyy').format(_effectiveDate), style: GText.body2(c.textPrimary)),
                      ),
                    ),
                  ),
                  if (candidates.isNotEmpty) ...[
                    TextButton(
                      onPressed: () => _setAll(isFinal ? PromotionAction.graduate : PromotionAction.promote, candidates),
                      child: Text(isFinal ? 'Graduate all' : 'Promote all'),
                    ),
                    TextButton(
                      onPressed: () => _setAll(PromotionAction.skip, candidates),
                      child: const Text('Skip all'),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: Gsp.sp3),

              // Summary strip
              SchoolErpStatStrip([
                SchoolErpStat(label: 'In class', value: '${plan.length}', icon: GIcons.student),
                if (!isFinal)
                  SchoolErpStat(label: 'Promote → $nextGrade', value: '$toPromote', color: c.success, icon: GIcons.trendUp),
                if (isFinal)
                  SchoolErpStat(label: 'Graduate', value: '$toGraduate', color: c.info, icon: GIcons.checkCircle),
                SchoolErpStat(label: 'Hold back', value: '$toHold', color: c.warning, icon: GIcons.history),
                SchoolErpStat(label: 'Skipped', value: '$toSkip', color: c.textMuted, icon: GIcons.cancel),
              ]),
              if (_error != null) ...[
                const SizedBox(height: Gsp.sp2),
                Container(
                  padding: const EdgeInsets.all(Gsp.sp3),
                  decoration: BoxDecoration(color: c.dangerBg, borderRadius: SchoolErp.radius),
                  child: Text(_error!, style: GText.body2(c.danger)),
                ),
              ],
              const SizedBox(height: Gsp.sp3),

              // Student list
              Expanded(
                child: plan.isEmpty
                    ? AppEmptyState(
                        icon: GIcons.student,
                        title: 'No active students in Class $_sourceGrade${_sourceSection == 'All' ? '' : '-$_sourceSection'}',
                        subtitle: 'Choose another class or section to promote.',
                        compact: true,
                      )
                    : Container(
                        decoration: BoxDecoration(
                          borderRadius: SchoolErp.radius,
                          border: Border.all(color: c.border),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Column(children: [
                          Container(
                            height: SchoolErp.headerHeight,
                            color: c.surfaceSunken,
                            padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3),
                            child: Row(children: [
                              Expanded(flex: 4, child: Text('STUDENT', style: GText.overline(c.textMuted))),
                              SizedBox(width: 90, child: Text('CURRENT', style: GText.overline(c.textMuted))),
                              SizedBox(width: 155, child: Text('ACTION', style: GText.overline(c.textMuted))),
                              SizedBox(width: 96, child: Text('SECTION', style: GText.overline(c.textMuted))),
                              if (targetIsHighSchool) Expanded(flex: 3, child: Text('STREAM', style: GText.overline(c.textMuted))),
                              SizedBox(width: 84, child: Text('NEW ROLL', textAlign: TextAlign.end, style: GText.overline(c.textMuted))),
                            ]),
                          ),
                          Expanded(
                            child: ListView.separated(
                              itemCount: plan.length,
                              separatorBuilder: (_, _) => Divider(height: 1, color: c.border),
                              itemBuilder: (context, i) {
                                final row = plan[i];
                                final s = row.student;
                                final dec = _decisions[s.id] ?? PromotionRules.defaultDecision(s, targetYear: targetYear);
                                final actions = [
                                  if (!isFinal) PromotionAction.promote,
                                  if (isFinal) PromotionAction.graduate,
                                  PromotionAction.holdBack,
                                  PromotionAction.skip,
                                ];
                                final canChangeSection =
                                    row.action == PromotionAction.promote || row.action == PromotionAction.holdBack;
                                final groups = SchoolConstants.getAcademicGroupsForGrade(row.targetGrade);

                                return Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3, vertical: Gsp.sp2),
                                  child: Row(children: [
                                    Expanded(
                                      flex: 4,
                                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                        Row(children: [
                                          Flexible(
                                            child: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: GText.body2Bold(c.textPrimary)),
                                          ),
                                          if (row.alreadyInTargetYear) ...[
                                            const SizedBox(width: Gsp.sp2),
                                            const AppChip(label: 'Already in session', state: AppChipState.warning),
                                          ],
                                        ]),
                                        Text('${s.admissionNo} · Father: ${s.guardianName}',
                                            maxLines: 1, overflow: TextOverflow.ellipsis, style: GText.caption(c.textMuted)),
                                      ]),
                                    ),
                                    SizedBox(
                                      width: 90,
                                      child: Text('${s.grade}-${s.section} (#${s.rollNo})', style: GText.caption(c.textSecondary)),
                                    ),
                                    SizedBox(
                                      width: 155,
                                      child: DropdownButtonHideUnderline(
                                        child: DropdownButton<PromotionAction>(
                                          value: actions.contains(row.action) ? row.action : actions.first,
                                          isDense: true,
                                          isExpanded: true,
                                          style: GText.body2(c.textPrimary),
                                          items: [
                                            for (final a in actions)
                                              DropdownMenuItem(
                                                value: a,
                                                child: Text(a == PromotionAction.promote ? 'Promote → $nextGrade' : a.label),
                                              ),
                                          ],
                                          onChanged: (v) {
                                            if (v != null) setState(() => _decisions[s.id] = dec.copyWith(action: v));
                                          },
                                        ),
                                      ),
                                    ),
                                    SizedBox(
                                      width: 96,
                                      child: canChangeSection
                                          ? DropdownButtonHideUnderline(
                                              child: DropdownButton<String>(
                                                value: row.targetSection,
                                                isDense: true,
                                                style: GText.body2(c.textPrimary),
                                                items: [
                                                  for (final sec in SchoolConstants.sections) DropdownMenuItem(value: sec, child: Text('Sec $sec')),
                                                ],
                                                onChanged: (v) {
                                                  if (v != null) setState(() => _decisions[s.id] = dec.copyWith(targetSection: v));
                                                },
                                              ),
                                            )
                                          : Text('—', style: GText.caption(c.textMuted)),
                                    ),
                                    if (targetIsHighSchool)
                                      Expanded(
                                        flex: 3,
                                        child: canChangeSection && SchoolConstants.isHighSchool(row.targetGrade)
                                            ? DropdownButtonHideUnderline(
                                                child: DropdownButton<String>(
                                                  value: groups.contains(row.targetGroup) ? row.targetGroup : groups.first,
                                                  isDense: true,
                                                  isExpanded: true,
                                                  style: GText.caption(c.textPrimary),
                                                  items: [
                                                    for (final g in groups)
                                                      DropdownMenuItem(value: g, child: Text(g, overflow: TextOverflow.ellipsis)),
                                                  ],
                                                  onChanged: (v) {
                                                    if (v != null) setState(() => _decisions[s.id] = dec.copyWith(targetGroup: v));
                                                  },
                                                ),
                                              )
                                            : Text('—', style: GText.caption(c.textMuted)),
                                      ),
                                    SizedBox(
                                      width: 84,
                                      child: Align(
                                        alignment: AlignmentDirectional.centerEnd,
                                        child: SchoolErpCell.mono(
                                          context,
                                          canChangeSection ? '#${row.targetRollNo}' : (row.action == PromotionAction.graduate ? 'Grad' : '—'),
                                          color: row.action == PromotionAction.promote
                                              ? c.success
                                              : row.action == PromotionAction.graduate
                                                  ? c.info
                                                  : row.action == PromotionAction.holdBack
                                                      ? c.warning
                                                      : c.textMuted,
                                        ),
                                      ),
                                    ),
                                  ]),
                                );
                              },
                            ),
                          ),
                        ]),
                      ),
              ),
              const SizedBox(height: Gsp.sp4),

              // Footer actions
              Row(children: [
                Text(
                  'Promotion records class history & issues new roll numbers. Nothing is deleted.',
                  style: GText.caption(c.textMuted),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: Gsp.sp2),
                FilledButton.icon(
                  onPressed: _saving || plan.isEmpty ? null : () => _apply(plan),
                  icon: _saving
                      ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: c.onBrand))
                      : const Icon(GIcons.check),
                  label: Text(_saving
                      ? 'Applying…'
                      : 'Apply (${toPromote + toHold + toGraduate} ${toPromote + toHold + toGraduate == 1 ? 'student' : 'students'})'),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
