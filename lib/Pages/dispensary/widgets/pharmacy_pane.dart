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
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(kPharmacyRadius),
        border: Border.all(color: c.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 44,
            padding: const EdgeInsets.fromLTRB(14, 0, 8, 0),
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
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? c.brandSoft : null,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? c.brand : c.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: selected ? c.brand : c.textSecondary),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                color: selected ? c.brand : c.textSecondary,
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

    // Each chip uses a designed foreground/background pair, readable in both themes.
    Widget chip(String label, int count, String amount, Color fg, Color bg, {bool strong = false}) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: strong ? fg : bg),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: fg)),
            const SizedBox(width: 6),
            Text('$count', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: fg)),
            const SizedBox(width: 6),
            Text(
              amount,
              style: TextStyle(fontSize: 11.5, fontWeight: strong ? FontWeight.w800 : FontWeight.w600, color: fg),
            ),
          ],
        ),
      );
    }

    return Container(
      height: 40,
      padding: EdgeInsets.only(left: 12, right: onShare == null ? 12 : 4),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(kPharmacyRadius),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Icon(Icons.payments_outlined, size: 18, color: c.brand),
          const SizedBox(width: 8),
          Text(
            "Today's collection",
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.textPrimary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(
                children: [
                  chip(isKarachi ? BranchLabels.karachiZakatLabel : 'Zakat', tally.zakat, 'PKR ${money.format(tally.zakatAmount)}',
                      c.success, c.successBg),
                  const SizedBox(width: 6),
                  chip(
                    isKarachi ? BranchLabels.karachiNonZakatLabel : 'Non-Zakat',
                    tally.nonZakat,
                    isKarachi && tally.nonZakat == 0 ? 'Disabled' : 'PKR ${money.format(tally.nonZakatAmount)}',
                    c.info,
                    c.infoBg,
                  ),
                  const SizedBox(width: 6),
                  chip('GMWF', tally.gmwf, 'PKR 0', c.warning, c.warningBg),
                  const SizedBox(width: 6),
                  // Count = tokens issued by me today (same list as "Today's Tokens").
                  chip('Issued by me', tally.total, 'PKR ${money.format(tally.totalAmount)}', c.brand, c.brandSoft,
                      strong: true),
                ],
              ),
            ),
          ),
          if (onShare != null) ...[
            const SizedBox(width: 4),
            WhatsAppShareButton(onPressed: onShare!),
          ],
        ],
      ),
    );
  }
}
