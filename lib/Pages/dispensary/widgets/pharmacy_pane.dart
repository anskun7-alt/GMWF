// lib/pages/dispensary/widgets/pharmacy_pane.dart
//
// Building blocks of the Hybrid "Pharmacy" tab, shared by the Receptionist
// screen (which hosts the layout) and the Hybrid desk (dispense pane), so every
// pane has the same radius, header height and type sizes in light and dark.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:gmwf/design/components/app_toast.dart';
import 'package:gmwf/design/tokens/comfort_colors.dart';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:gmwf/utils/branch_labels.dart';
import '../receptionist/token_tally.dart';
import 'desk_theme.dart';

// WhatsApp-style green from the eye-comfort palette (no hard-coded colours):
// a light green on dark surfaces, a deep green on light ones.
const Color kWhatsAppGreenOnDark = SoftPalette.green350;
const Color kWhatsAppGreenOnLight = SoftPalette.green550;

/// Opens WhatsApp (Desktop if installed, else Web) with [text] ready to send; the
/// user picks the contact. No number is stored. Falls back to the clipboard.
Future<void> shareTextToWhatsApp(String text) async {
  final uri = Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}');
  var opened = false;
  try {
    opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint('[Pharmacy] WhatsApp share failed: $e');
  }
  if (!opened) {
    await Clipboard.setData(ClipboardData(text: text));
    AppToast.show(
      message: 'Could not open WhatsApp — summary copied to clipboard.',
      kind: GToastKind.info,
    );
  }
}

/// WhatsApp share button sized for pane headers and the collection strip.
class WhatsAppShareButton extends StatelessWidget {
  final VoidCallback onPressed;

  const WhatsAppShareButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return IconButton(
      visualDensity: VisualDensity.compact,
      tooltip: 'Share to WhatsApp',
      onPressed: onPressed,
      icon: FaIcon(FontAwesomeIcons.whatsapp, size: 18, color: isDark ? kWhatsAppGreenOnDark : kWhatsAppGreenOnLight),
    );
  }
}

/// Corner radius / inner padding shared by every pane on the Pharmacy tab.
const double kPharmacyRadius = 12;
const double kPharmacyPad = 10;

class PharmacyPane extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<Widget> actions;
  final Widget child;

  const PharmacyPane({
    super.key,
    required this.icon,
    required this.title,
    this.actions = const [],
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    return DeskCard(
      radius: kPharmacyRadius,
      accentTop: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 44,
            padding: const EdgeInsets.fromLTRB(14, 0, 8, 0),
            color: c.brandSoft.withValues(alpha: 0.28),
            child: Row(
              children: [
                Icon(icon, size: 18, color: c.brand),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.textPrimary),
                  ),
                ),
                ...actions,
              ],
            ),
          ),
          Divider(height: 1, color: c.border),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// Small toggle chip used in pane headers (e.g. Register / Token & Vitals).
class PaneSegment extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const PaneSegment({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? c.brandSoft : c.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? c.brand : c.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: selected ? c.brand : c.textSecondary),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                color: selected ? c.brand : c.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact pane-header icon button (sort, refresh…).
class PaneAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool busy;

  const PaneAction({super.key, required this.icon, required this.tooltip, this.onPressed, this.busy = false});

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    return IconButton(
      visualDensity: VisualDensity.compact,
      tooltip: tooltip,
      onPressed: busy ? null : onPressed,
      icon: busy
          ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: c.brand))
          : Icon(icon, size: 18, color: c.brand),
    );
  }
}

/// "Today's collection" strip: tokens issued by this user today and the fees
/// collected (Zakat / Non-Zakat / GMWF / Issued by me = total), from [TokenTally].
class TodayCollectionStrip extends StatelessWidget {
  final TokenTally tally;
  final bool isKarachi;

  /// Shows the WhatsApp share button when set.
  final VoidCallback? onShare;

  const TodayCollectionStrip({super.key, required this.tally, required this.isKarachi, this.onShare});

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final money = NumberFormat.decimalPattern();

    Widget metricCell({
      IconData? icon,
      String? imageAsset,
      required Color iconColor,
      required Color iconBg,
      required String label,
      required int count,
      required String amount,
      bool highlight = false,
      bool useExpanded = true,
    }) {
      final inner = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: useExpanded ? MainAxisSize.max : MainAxisSize.min,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: iconBg,
                shape: BoxShape.circle,
              ),
              child: imageAsset != null
                  ? Padding(
                      padding: const EdgeInsets.all(3),
                      child: Image.asset(
                        imageAsset,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => Icon(
                          icon ?? Icons.groups_rounded,
                          size: 16,
                          color: iconColor,
                        ),
                      ),
                    )
                  : Icon(icon, size: 16, color: iconColor),
            ),
            const SizedBox(width: 10),
            Flexible(
              fit: useExpanded ? FlexFit.loose : FlexFit.loose,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: c.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 1),
                  RichText(
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    text: TextSpan(
                      style: TextStyle(
                        fontFamily: 'Roboto',
                        color: c.textPrimary,
                      ),
                      children: [
                        TextSpan(
                          text: '$count',
                          style: const TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        TextSpan(
                          text: ' · $amount',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: highlight ? c.brand : c.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
      return useExpanded ? Expanded(child: inner) : inner;
    }

    Widget vDivider() => Container(width: 1, height: 28, color: c.border);

    List<Widget> buildCells(bool useExpanded) => [
          metricCell(
            icon: Icons.volunteer_activism_rounded,
            iconColor: c.success,
            iconBg: c.successBg,
            label: isKarachi ? BranchLabels.karachiZakatLabel : 'Zakat',
            count: tally.zakat,
            amount: 'PKR ${money.format(tally.zakatAmount)}',
            useExpanded: useExpanded,
          ),
          vDivider(),
          metricCell(
            icon: Icons.group_rounded,
            iconColor: c.info,
            iconBg: c.infoBg,
            label: isKarachi ? BranchLabels.karachiNonZakatLabel : 'Non-Zakat',
            count: tally.nonZakat,
            amount: isKarachi && tally.nonZakat == 0 ? 'Disabled' : 'PKR ${money.format(tally.nonZakatAmount)}',
            useExpanded: useExpanded,
          ),
          vDivider(),
          metricCell(
            icon: Icons.groups_rounded,
            imageAsset: 'assets/logo/gmwf-1.webp',
            iconColor: c.warning,
            iconBg: c.warningBg,
            label: 'GMWF',
            count: tally.gmwf,
            amount: 'PKR 0',
            useExpanded: useExpanded,
          ),
          vDivider(),
          metricCell(
            icon: Icons.check_circle_rounded,
            iconColor: c.brand,
            iconBg: c.brandSoft,
            label: 'Issued by me',
            count: tally.total,
            amount: 'PKR ${money.format(tally.totalAmount)}',
            highlight: true,
            useExpanded: useExpanded,
          ),
        ];

    return DeskCard(
      radius: kPharmacyRadius,
      accentTop: false,
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            Container(
              height: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: c.surfaceSunken.withValues(alpha: 0.65),
                border: Border(right: BorderSide(color: c.border)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: c.brandSoft,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.calendar_today_rounded, size: 16, color: c.brand),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    "Today's collection",
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: c.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth >= 560) {
                    return Row(children: buildCells(true));
                  }
                  return SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: buildCells(false)),
                  );
                },
              ),
            ),
            if (onShare != null)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: WhatsAppShareButton(onPressed: onShare!),
              ),
          ],
        ),
      ),
    );
  }
}
