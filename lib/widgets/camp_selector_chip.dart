// lib/widgets/camp_selector_chip.dart

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:gmwf/services/camp_session_service.dart';

/// Reusable Camp Selector Chip for AppBars & Headers.
/// Enables global/higher-level users and multi-camp staff to switch camps dynamically across the app.
class CampSelectorChip extends StatefulWidget {
  final String? branchId;
  final ValueChanged<String>? onCampChanged;
  final Color? textColor;
  final Color? bgColor;
  final Color? borderColor;

  const CampSelectorChip({
    super.key,
    this.branchId,
    this.onCampChanged,
    this.textColor,
    this.bgColor,
    this.borderColor,
  });

  @override
  State<CampSelectorChip> createState() => _CampSelectorChipState();
}

class _CampSelectorChipState extends State<CampSelectorChip> {
  @override
  void initState() {
    super.initState();
    CampSessionService.activeCampNotifier.addListener(_onActiveCampChanged);
  }

  @override
  void dispose() {
    CampSessionService.activeCampNotifier.removeListener(_onActiveCampChanged);
    super.dispose();
  }

  void _onActiveCampChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final effBranch = widget.branchId ?? (() {
      try {
        if (Hive.isBoxOpen('app_settings')) {
          final box = Hive.box('app_settings');
          final uData = box.get('user_data') ?? box.get('currentUser');
          if (uData is Map) {
            final b = (uData['branchId'] ?? uData['branch'] ?? uData['selectedBranchId'])?.toString();
            if (b != null && b.isNotEmpty) return b;
          }
          final cb = box.get('current_branch_id')?.toString();
          if (cb != null && cb.isNotEmpty) return cb;
        }
      } catch (_) {}
      return null;
    })();

    if (effBranch != null && !CampSessionService.hasCampsForBranch(effBranch)) {
      return const SizedBox.shrink(); // Non-camp branches (Madrassa, School, Office, etc.) do NOT display camp chips!
    }

    final activeCampId = CampSessionService.getActiveCamp(effBranch) ?? 'saddar';
    final activeCampLabel = CampSessionService.getCampLabel(activeCampId);
    final options = CampSessionService.getAvailableCampOptions();

    // Hide only if branch has no camps or options list is empty
    if (options.isEmpty) {
      return const SizedBox.shrink();
    }

    final textColor = widget.textColor ?? Colors.white;
    final bgColor = widget.bgColor ?? Colors.white.withValues(alpha: 0.15);
    final borderColor = widget.borderColor ?? Colors.white.withValues(alpha: 0.30);

    final isBound = CampSessionService.getBoundDispensaryId() != null;
    final shiftName = switch (CampSessionService.getCurrentSession(null, effBranch, activeCampId)) {
      'morning' => 'Morning',
      'evening' => 'Evening',
      'night'   => 'Night',
      _         => '',
    };

    final assignedCamps = (() {
      try {
        if (Hive.isBoxOpen('app_settings')) {
          final uData = Hive.box('app_settings').get('user_data') ?? Hive.box('app_settings').get('currentUser');
          if (uData is Map) {
            return CampSessionService.getAssignedCamps(Map<String, dynamic>.from(uData));
          }
        }
      } catch (_) {}
      return CampSessionService.getAssignedCampsFromHive();
    })();

    final matchingSchedule = (() {
      try {
        if (Hive.isBoxOpen('app_settings')) {
          final uData = Hive.box('app_settings').get('user_data') ?? Hive.box('app_settings').get('currentUser');
          if (uData is Map) {
            return CampSessionService.getMatchingScheduledCamps(Map<String, dynamic>.from(uData));
          }
        }
      } catch (_) {}
      return <String>[];
    })();

    // In unassigned times or for multi-camp staff, doctors can freely switch camps from the AppBar.
    // Lock to a static chip if hardware desk bound, options <= 1, or user has only 1 assigned/scheduled camp.
    final isSingleContext = isBound ||
        options.length <= 1 ||
        assignedCamps.length == 1 ||
        (matchingSchedule.length == 1 && options.length <= 1);

    if (isSingleContext) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: borderColor, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(FontAwesomeIcons.locationDot, color: textColor, size: 11),
            const SizedBox(width: 6),
            Text(
              shiftName.isNotEmpty ? '$activeCampLabel · $shiftName' : activeCampLabel,
              style: TextStyle(
                color: textColor,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 5),
            Icon(Icons.check_circle_rounded, color: Colors.tealAccent.shade400, size: 12),
          ],
        ),
      );
    }

    return PopupMenuButton<String>(
      tooltip: 'Switch Active Camp',
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: Colors.white,
      elevation: 4,
      onSelected: (selectedId) async {
        await CampSessionService.setActiveCamp(selectedId, isManual: true);
        if (mounted) setState(() {});
        if (widget.onCampChanged != null) {
          widget.onCampChanged!(selectedId);
        }
      },
      itemBuilder: (context) => options.map((opt) {
        final id = opt['id']!;
        final label = opt['label']!;
        final isSelected = (id.toLowerCase() == activeCampId.toLowerCase());
        return PopupMenuItem<String>(
          value: id,
          child: Row(
            children: [
              Icon(
                FontAwesomeIcons.tent,
                size: 14,
                color: isSelected ? const Color(0xFF00695C) : Colors.grey.shade600,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    color: isSelected ? const Color(0xFF00695C) : const Color(0xFF1B2631),
                  ),
                ),
              ),
              if (isSelected)
                const Icon(Icons.check_circle_rounded, size: 16, color: Color(0xFF00695C)),
            ],
          ),
        );
      }).toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: borderColor, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(FontAwesomeIcons.tent, color: textColor, size: 11),
            const SizedBox(width: 6),
            Text(
              '$activeCampLabel · $shiftName',
              style: TextStyle(
                color: textColor,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.arrow_drop_down, color: textColor, size: 16),
          ],
        ),
      ),
    );
  }
}
