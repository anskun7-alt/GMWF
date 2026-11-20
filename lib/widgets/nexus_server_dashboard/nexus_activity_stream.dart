import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'nexus_colors.dart';

enum NexusLogSeverity { info, system, warn, error }

class NexusParsedLog {
  final NexusLogSeverity severity;
  final String title;
  final String detail;
  final String timestamp;
  final String raw;

  const NexusParsedLog({
    required this.severity,
    required this.title,
    required this.detail,
    required this.timestamp,
    required this.raw,
  });

  static NexusParsedLog fromRawString(String raw, int index) {
    var clean = raw.trim();
    NexusLogSeverity severity = NexusLogSeverity.info;
    String title = 'Activity';
    String detail = clean;
    String timestamp = 'Just now';

    // Parse leading timestamp if present e.g. [16:20:15]
    final timeMatch = RegExp(r'^\[(\d{1,2}:\d{2}(?::\d{2})?)\]').firstMatch(clean);
    if (timeMatch != null) {
      timestamp = timeMatch.group(1)!;
      clean = clean.substring(timeMatch.end).trim();
      detail = clean;
    }

    if (clean.contains('✅') || clean.toLowerCase().contains('synced') || clean.toLowerCase().contains('started')) {
      severity = NexusLogSeverity.system;
      title = 'System Operation';
    } else if (clean.contains('⚠️') || clean.toLowerCase().contains('warning') || clean.toLowerCase().contains('duplicate')) {
      severity = NexusLogSeverity.warn;
      title = 'Warning Event';
    } else if (clean.contains('❌') || clean.toLowerCase().contains('error') || clean.toLowerCase().contains('failed')) {
      severity = NexusLogSeverity.error;
      title = 'Error Alert';
    } else if (clean.contains('📨') || clean.contains('IDENTIFIED')) {
      severity = NexusLogSeverity.info;
      title = 'Network Packet';
    }

    // Clean leading emoji symbols safely
    const leadingPrefixes = ['✅', '⚠️', '❌', '📨', 'ℹ️', '⏱️', '🚀', '🔄', '🟢'];
    for (final p in leadingPrefixes) {
      if (detail.startsWith(p)) {
        detail = detail.substring(p.length).trim();
        break;
      }
    }

    return NexusParsedLog(
      severity: severity,
      title: title,
      detail: detail,
      timestamp: timestamp,
      raw: raw,
    );
  }
}

class NexusActivityStream extends StatelessWidget {
  final List<String> rawLogs;
  final VoidCallback? onViewAllLogs;
  final int maxItems;

  const NexusActivityStream({
    super.key,
    required this.rawLogs,
    this.onViewAllLogs,
    this.maxItems = 8,
  });

  @override
  Widget build(BuildContext context) {
    final parsed = rawLogs.reversed.take(maxItems).toList().asMap().entries.map((entry) {
      return NexusParsedLog.fromRawString(entry.value, entry.key);
    }).toList();

    return Container(
      decoration: BoxDecoration(
        color: NexusColors.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NexusColors.cardBorder, width: 1.0),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 15, 18, 13),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Text(
                      'Live System Activity',
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: NexusColors.textMain,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: NexusColors.successMuted,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 5.5,
                            height: 5.5,
                            decoration: BoxDecoration(
                              color: NexusColors.success,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Live',
                            style: GoogleFonts.inter(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: NexusColors.success,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (onViewAllLogs != null)
                  InkWell(
                    onTap: onViewAllLogs,
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: Row(
                        children: [
                          Text(
                            'Full Event Logs',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: NexusColors.primary,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(Icons.arrow_forward_rounded, size: 13, color: NexusColors.primary),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Divider(color: NexusColors.cardBorder, height: 1),

          if (parsed.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 34),
              child: Center(
                child: Text(
                  'No recent activity recorded yet',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: NexusColors.textSecondary,
                  ),
                ),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(vertical: 6),
              itemCount: parsed.length,
              separatorBuilder: (context, i) => Divider(
                color: NexusColors.cardBorder.withValues(alpha: 0.7),
                height: 1,
                indent: 18,
                endIndent: 18,
              ),
              itemBuilder: (context, i) {
                final log = parsed[i];
                final (badgeBg, badgeColor, badgeLabel) = switch (log.severity) {
                  NexusLogSeverity.system => (NexusColors.successMuted, NexusColors.success, 'SYSTEM'),
                  NexusLogSeverity.warn => (NexusColors.warningMuted, NexusColors.warning, 'WARN'),
                  NexusLogSeverity.error => (NexusColors.errorMuted, NexusColors.error, 'ERROR'),
                  NexusLogSeverity.info => (NexusColors.primaryMuted, NexusColors.primary, 'INFO'),
                };

                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 58,
                        child: Container(
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                          decoration: BoxDecoration(
                            color: badgeBg,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            badgeLabel,
                            style: GoogleFonts.inter(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.4,
                              color: badgeColor,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          log.detail,
                          style: GoogleFonts.inter(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                            color: NexusColors.textMain,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        log.timestamp,
                        style: GoogleFonts.firaCode(
                          fontSize: 11,
                          fontWeight: FontWeight.w400,
                          color: NexusColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
