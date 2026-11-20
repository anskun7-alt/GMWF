// lib/pages/school/library/widgets/library_widgets.dart
//
// Small building blocks for the library screens, built only from gmwf_ui
// tokens (context.comfort, GText, Gsp, Gr, GIcons).

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../../../services/image_upload_service.dart';
import '../library_models.dart';
import '../library_rules.dart';

String libraryDate(DateTime? d) => d == null ? '—' : DateFormat('d MMM yyyy').format(d);

/// A title that renders Urdu/Arabic in Nastaliq, right-to-left, and Latin in Inter.
class LibraryTitle extends StatelessWidget {
  const LibraryTitle(this.text, {super.key, this.size = 15, this.color, this.maxLines = 1, this.weight = FontWeight.w600, this.dense = false});

  final String text;
  final double size;
  final Color? color;
  final int maxLines;
  final FontWeight weight;

  /// Tight line height for one-line table cells (Nastaliq is very tall).
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final col = color ?? c.textPrimary;
    final urdu = hasArabicScript(text);
    return Text(
      text,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      textDirection: urdu ? TextDirection.rtl : null,
      style: urdu
          ? GText.urdu(col, size: size + 1, weight: weight).copyWith(height: dense ? 1.3 : 1.6)
          : GText.body1(col).copyWith(fontSize: size, fontWeight: weight, height: dense ? 1.3 : null),
    );
  }
}

/// Book cover: the uploaded image, or a generated cover (title initials on the brand tint).
class LibraryCover extends StatelessWidget {
  const LibraryCover({super.key, required this.title, this.coverUrl = '', this.width = 44, this.dimmed = false});

  final String title;
  final String coverUrl;
  final double width;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final height = width * 1.45;
    final bytes = coverUrl.isEmpty ? null : ImageUploadService.decodeBase64ToBytes(coverUrl);
    final radius = BorderRadius.circular(width < 60 ? Gr.r1 + 2 : Gr.r3);

    Widget child;
    if (bytes != null) {
      child = Image.memory(bytes, fit: BoxFit.cover, width: width, height: height, gaplessPlayback: true);
    } else {
      final words = title.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
      final initials = words.take(2).map((w) => String.fromCharCode(w.runes.first)).join();
      child = Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [c.brand, c.brandStrong],
          ),
        ),
        child: Stack(children: [
          // Spine line
          PositionedDirectional(start: width * 0.09, top: 0, bottom: 0, child: Container(width: 1.5, color: c.onBrand.withValues(alpha: 0.25))),
          Center(
            child: Padding(
              padding: EdgeInsets.all(width * 0.1),
              child: Text(
                initials.isEmpty ? '?' : initials,
                textAlign: TextAlign.center,
                maxLines: 1,
                style: (hasArabicScript(initials) ? GText.urdu(c.onBrand, size: width * 0.34) : GText.h2(c.onBrand))
                    .copyWith(fontSize: width * 0.34, height: 1.2),
              ),
            ),
          ),
          if (width >= 80)
            PositionedDirectional(
              start: width * 0.16,
              end: width * 0.08,
              bottom: width * 0.1,
              child: Text(
                title,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                textDirection: hasArabicScript(title) ? TextDirection.rtl : null,
                style: hasArabicScript(title)
                    ? GText.urdu(c.onBrand.withValues(alpha: 0.9), size: 12).copyWith(height: 1.5)
                    : GText.caption(c.onBrand.withValues(alpha: 0.9)),
              ),
            ),
        ]),
      );
    }

    return Opacity(
      opacity: dimmed ? 0.45 : 1,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: GShadow.s1(Theme.of(context).brightness == Brightness.dark),
        ),
        child: ClipRRect(borderRadius: radius, child: child),
      ),
    );
  }
}

Color libraryStockColor(BuildContext context, LibraryStockLevel level) {
  final c = context.comfort;
  return switch (level) {
    LibraryStockLevel.inStock => c.success,
    LibraryStockLevel.low => c.warning,
    LibraryStockLevel.out => c.danger,
    LibraryStockLevel.unlisted => c.textMuted,
  };
}

String libraryStockLabel(LibraryStockLevel level) => switch (level) {
      LibraryStockLevel.inStock => 'In stock',
      LibraryStockLevel.low => 'Low',
      LibraryStockLevel.out => 'All out',
      LibraryStockLevel.unlisted => 'Unlisted',
    };

/// "2 / 3" with a coloured bar.
class LibraryStockBar extends StatelessWidget {
  const LibraryStockBar({super.key, required this.available, required this.total, required this.level, this.wide = false});

  final int available;
  final int total;
  final LibraryStockLevel level;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final col = libraryStockColor(context, level);
    final value = total <= 0 ? 0.0 : available / total;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Text('$available', style: GText.body1Bold(c.textPrimary)),
          Text(' / $total ${wide ? (total == 1 ? 'copy available' : 'copies available') : ''}', style: GText.caption(c.textMuted)),
        ]),
        const SizedBox(height: Gsp.sp1),
        SizedBox(width: wide ? double.infinity : 96, child: GProgressBar(value: value, color: col, height: wide ? 8 : 5)),
      ],
    );
  }
}

class LibraryStockChip extends StatelessWidget {
  const LibraryStockChip(this.level, {super.key});
  final LibraryStockLevel level;

  @override
  Widget build(BuildContext context) =>
      AppChip.dot(label: libraryStockLabel(level), state: AppChipState.custom, color: libraryStockColor(context, level));
}

class LibraryLoanStatusChip extends StatelessWidget {
  const LibraryLoanStatusChip(this.loan, {super.key, required this.now});
  final LibraryLoan loan;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    if (loan.status == LibraryLoanStatus.lost) return const AppChip(label: 'Lost', state: AppChipState.danger, icon: GIcons.cancel);
    if (loan.status == LibraryLoanStatus.returned) {
      final late = loan.daysOverdue(now);
      return AppChip(
        label: late > 0 ? 'Returned · $late d late' : 'Returned',
        state: late > 0 ? AppChipState.warning : AppChipState.active,
        icon: GIcons.checkCircle,
      );
    }
    if (loan.isOverdue(now)) {
      final d = loan.daysOverdue(now);
      return AppChip(label: 'Overdue · $d ${d == 1 ? 'day' : 'days'}', state: AppChipState.danger, icon: GIcons.overdue);
    }
    final left = loan.dueDate == null ? null : DateTime(loan.dueDate!.year, loan.dueDate!.month, loan.dueDate!.day)
        .difference(DateTime(now.year, now.month, now.day))
        .inDays;
    return AppChip(
      label: left == null ? 'Out' : left == 0 ? 'Due today' : 'Due in $left ${left == 1 ? 'day' : 'days'}',
      state: left != null && left <= 1 ? AppChipState.warning : AppChipState.info,
      icon: GIcons.time,
    );
  }
}

class LibraryMemberAvatar extends StatelessWidget {
  const LibraryMemberAvatar({super.key, required this.member, this.size = 36});
  final LibraryMember member;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final bytes = member.photoUrl.isEmpty ? null : ImageUploadService.decodeBase64ToBytes(member.photoUrl);
    final initials = member.name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).take(2).map((w) => String.fromCharCode(w.runes.first)).join();
    final tint = switch (member.type) {
      LibraryMemberType.student => c.brand,
      LibraryMemberType.teacher => c.accentStrong,
      LibraryMemberType.outsider => c.textSecondary,
    };
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: tint.withValues(alpha: 0.14)),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: bytes != null
          ? Image.memory(bytes, fit: BoxFit.cover, width: size, height: size, gaplessPlayback: true)
          : Text(initials.isEmpty ? '?' : initials.toUpperCase(), style: GText.label(tint).copyWith(fontSize: size * 0.36)),
    );
  }
}

class LibraryMemberTypeChip extends StatelessWidget {
  const LibraryMemberTypeChip(this.member, {super.key});
  final LibraryMember member;

  @override
  Widget build(BuildContext context) {
    if (member.blocked) return const AppChip(label: 'Blocked', state: AppChipState.danger, icon: GIcons.block);
    if (member.isLegacy) return const AppChip(label: 'Unlinked', state: AppChipState.warning, icon: GIcons.warning);
    return AppChip(
      label: member.inactive ? '${member.type.label} · inactive' : member.type.label,
      state: switch (member.type) {
        LibraryMemberType.student => AppChipState.info,
        LibraryMemberType.teacher => AppChipState.active,
        LibraryMemberType.outsider => AppChipState.neutral,
      },
      icon: switch (member.type) {
        LibraryMemberType.student => GIcons.student,
        LibraryMemberType.teacher => GIcons.teacher,
        LibraryMemberType.outsider => GIcons.profile,
      },
    );
  }
}

/// A labelled value used in detail panels.
class LibraryFact extends StatelessWidget {
  const LibraryFact({super.key, required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gsp.sp1),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: GIconSize.sm, color: c.textMuted),
        const SizedBox(width: Gsp.sp2),
        SizedBox(width: 92, child: Text(label, style: GText.caption(c.textMuted))),
        Expanded(child: Text(value.isEmpty ? '—' : value, style: GText.body2(c.textPrimary))),
      ]),
    );
  }
}

/// Bordered panel surface used for the side panels and list containers.
class LibraryPanel extends StatelessWidget {
  const LibraryPanel({super.key, required this.child, this.padding = const EdgeInsets.all(Gsp.sp4)});
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    return Container(
      decoration: BoxDecoration(color: c.surface, borderRadius: Gr.card, border: Border.all(color: c.border)),
      padding: padding,
      child: child,
    );
  }
}

/// Section title inside a panel.
class LibrarySubhead extends StatelessWidget {
  const LibrarySubhead(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    return Padding(
      padding: const EdgeInsets.only(top: Gsp.sp4, bottom: Gsp.sp2),
      child: Row(children: [
        Expanded(child: Text(text.toUpperCase(), style: GText.overline(c.textMuted))),
        if (trailing != null) trailing!,
      ]),
    );
  }
}
