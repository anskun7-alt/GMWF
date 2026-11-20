// lib/pages/school/daily/views/daily_common.dart
//
// Shared bits for the daily log screens (Phase 3).

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../constants/school_constants.dart';
import '../../models/school_student.dart';
import '../../students/school_student_service.dart';
import '../../students/student_rules.dart';
import '../daily_rules.dart';

/// What every daily tab needs, read once per rebuild.
class DailyContext {
  const DailyContext({
    required this.branchId,
    required this.editorName,
    required this.isPrincipal,
    required this.isTeacher,
    required this.teacherGrades,
    required this.roster,
    required this.calendar,
  });

  final String branchId;
  final String editorName;

  /// Principal / School Admin / executives: may edit any day of an open month
  /// and manage the calendar.
  final bool isPrincipal;
  final bool isTeacher;

  /// Grades a teacher may mark (empty for non-teachers = all).
  final List<String> teacherGrades;
  final StudentRoster roster;
  final SchoolCalendar calendar;

  List<String> get gradeOptions => isTeacher && teacherGrades.isNotEmpty
      ? SchoolConstants.grades.where(teacherGrades.contains).toList()
      : SchoolConstants.grades;

  bool canMarkGrade(String grade) => !isTeacher || teacherGrades.contains(grade);

  /// The first class (in school order) that has students, so screens never
  /// open on an empty class.
  String get firstGradeWithStudents {
    final options = gradeOptions;
    for (final g in options) {
      if (roster.students.any((s) => s.grade == g && !s.isVoid)) return g;
    }
    return options.isEmpty ? SchoolConstants.grades.first : options.first;
  }

  /// Students of a class-section on a day (enrolled that day, sorted by roll).
  List<SchoolStudent> classOn(DateTime day, String grade, String section) {
    final list = roster.students
        .where((s) => s.grade == grade && (section == 'All' || s.section == section))
        .where((s) => !s.isVoid)
        .where((s) => _activeOn(s, day))
        .toList();
    list.sort((a, b) {
      final sec = a.section.compareTo(b.section);
      if (sec != 0) return sec;
      final ra = int.tryParse(a.rollNo) ?? 99999, rb = int.tryParse(b.rollNo) ?? 99999;
      return ra != rb ? ra.compareTo(rb) : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  static bool _activeOn(SchoolStudent s, DateTime d) => StudentRules.isActiveOn(s, d);
}

/// Month / day pickers with previous-next arrows (arrows mirror in Urdu).
class DailyStepper extends StatelessWidget {
  const DailyStepper({super.key, required this.label, required this.onPrev, required this.onNext, this.onTap});
  final String label;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    return Container(
      decoration: BoxDecoration(color: c.surface, borderRadius: Gr.input, border: Border.all(color: c.border)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(tooltip: 'Previous', onPressed: onPrev, icon: const Icon(GIcons.back)),
        InkWell(
          onTap: onTap,
          borderRadius: Gr.input,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gsp.sp2, vertical: Gsp.sp2),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(GIcons.calendar, size: GIconSize.sm, color: c.brand),
              const SizedBox(width: Gsp.sp2),
              Text(label, style: GText.label(c.textPrimary)),
            ]),
          ),
        ),
        IconButton(tooltip: 'Next', onPressed: onNext, icon: const Icon(GIcons.forward)),
      ]),
    );
  }
}

class DailyBanner extends StatelessWidget {
  const DailyBanner({super.key, required this.text, required this.tone, this.icon, this.action});
  final String text;
  final AppChipState tone;
  final IconData? icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final (bg, fg) = switch (tone) {
      AppChipState.danger => (c.dangerBg, c.danger),
      AppChipState.warning => (c.warningBg, c.warning),
      AppChipState.active => (c.successBg, c.success),
      _ => (c.infoBg, c.info),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3, vertical: Gsp.sp2),
      decoration: BoxDecoration(color: bg, borderRadius: Gr.input),
      child: Row(children: [
        Icon(icon ?? GIcons.info, size: GIconSize.sm, color: fg),
        const SizedBox(width: Gsp.sp2),
        Expanded(child: Text(text, style: GText.body2(fg))),
        if (action != null) action!,
      ]),
    );
  }
}

String dailyDayLabel(DateTime d) => DateFormat('EEE d MMM yyyy').format(d);
String dailyMonthLabel(DateTime d) => DateFormat('MMMM yyyy').format(d);
String dailyShortDate(String ymd) {
  final d = DateTime.tryParse(ymd);
  return d == null ? ymd : DateFormat('d MMM').format(d);
}
