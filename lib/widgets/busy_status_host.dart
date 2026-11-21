// lib/widgets/busy_status_host.dart
//
// Renders BusyStatus app-wide (mounted once in the MaterialApp builder, above every route):
//   • background work  → small quiet pill, bottom-left ("Syncing patient records…")
//   • foreground work  → pill, bottom-centre, with elapsed time after a few seconds
//   • blocking work    → dimmed screen + centred card with step text and reassurance
//   • after a freeze   → short "Sorry for the wait — everything is working again" note
//
// After 4 s the text adds the elapsed time, after 10 s a reassurance line ("This can take a
// minute on large data — please don't close the app"), so long waits never feel like a hang.

import 'dart:async';
import 'package:flutter/material.dart';

import '../design/tokens/soft_palette.dart';
import '../services/busy_status.dart';

class BusyStatusHost extends StatefulWidget {
  const BusyStatusHost({super.key});

  /// Same phone rule as AppToastHost (below 600 px toasts come from the top).
  static bool isPhone(BuildContext context) => MediaQuery.sizeOf(context).width < 600;

  /// How far bottom-right notifications move up while the sync pill shows, so the
  /// pill stays the bottom-most item in that corner. 0 on phones and when idle.
  static double pillLift(BuildContext context) {
    final t = BusyStatus.current;
    if (t == null || t.blocking || isPhone(context)) return 0;
    final tall = !t.background && (t.detail != null || DateTime.now().difference(t.startedAt).inSeconds >= 10);
    return tall ? 62 : 46;
  }

  @override
  State<BusyStatusHost> createState() => _BusyStatusHostState();
}

class _BusyStatusHostState extends State<BusyStatusHost> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    BusyStatus.revision.addListener(_onChange);
    BusyStatus.notice.addListener(_onChange);
    _syncTicker();
  }

  @override
  void dispose() {
    BusyStatus.revision.removeListener(_onChange);
    BusyStatus.notice.removeListener(_onChange);
    _ticker?.cancel();
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    _syncTicker();
    setState(() {});
  }

  // Tick once a second only while something is running (for the elapsed counter).
  void _syncTicker() {
    final active = BusyStatus.current != null;
    if (active && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!active) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = BusyStatus.current;
    final notice = BusyStatus.notice.value;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final phone = BusyStatusHost.isPhone(context);

    return Stack(
      fit: StackFit.expand,
      children: [
        // Blocking scrim + card
        IgnorePointer(
          ignoring: !(task?.blocking ?? false),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: (task != null && task.blocking)
                ? _BlockingCard(key: const ValueKey('busy_blocking'), task: task, isDark: isDark)
                : const SizedBox.shrink(key: ValueKey('busy_none')),
          ),
        ),

        // Phone: no floating pill (it covered the bottom navigation and buttons).
        // Non-blocking work is a thin progress line along the top edge instead.
        if (phone && task != null && !task.blocking)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Semantics(
                label: task.message,
                child: SizedBox(
                  height: 2.5,
                  child: LinearProgressIndicator(
                    minHeight: 2.5,
                    backgroundColor: Colors.transparent,
                    color: task.background ? SoftPalette.vividBlue : SoftPalette.teal500,
                  ),
                ),
              ),
            ),
          ),

        // Non-blocking pill. Desktop: bottom-right, in the notifications corner,
        // always the bottom-most item (AppToastHost lifts its cards above it, see
        // [BusyStatusHost.pillLift]). Phone: bottom centre (toasts come from the top there).
        Positioned(
          left: phone ? 16 : null,
          right: phone ? 16 : 20,
          bottom: phone ? 14 : MediaQuery.paddingOf(context).bottom + 20,
          child: IgnorePointer(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position: Tween(begin: const Offset(0, 0.35), end: Offset.zero).animate(anim),
                  child: child,
                ),
              ),
              child: (task != null && !task.blocking && !phone)
                  ? Align(
                      key: ValueKey('busy_pill_${task.background}'),
                      alignment: phone ? Alignment.bottomCenter : Alignment.bottomRight,
                      widthFactor: phone ? null : 1,
                      heightFactor: phone ? null : 1,
                      child: _StatusPill(task: task, isDark: isDark),
                    )
                  : const SizedBox.shrink(key: ValueKey('busy_pill_none')),
            ),
          ),
        ),

        // Post-freeze notice (above the pill when both show)
        Positioned(
          bottom: (task != null && !task.blocking && !phone) ? 62 : 14,
          left: 16,
          right: 16,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: notice != null
                ? Align(
                    key: ValueKey(notice.at),
                    alignment: Alignment.bottomCenter,
                    child: _RecoveredNotice(notice: notice, isDark: isDark),
                  )
                : const SizedBox.shrink(key: ValueKey('busy_notice_none')),
          ),
        ),
      ],
    );
  }
}

String _elapsedText(BusyTask t) {
  final s = DateTime.now().difference(t.startedAt).inSeconds;
  if (s < 4) return '';
  if (s < 60) return '${s}s';
  return '${s ~/ 60}m ${(s % 60).toString().padLeft(2, '0')}s';
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.task, required this.isDark});
  final BusyTask task;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final quiet = task.background;
    final accent = quiet ? SoftPalette.vividBlue : SoftPalette.teal500;
    final bg = isDark ? SoftPalette.slate800.withValues(alpha: 0.94) : Colors.white.withValues(alpha: 0.96);
    final fg = isDark ? SoftPalette.slate100 : SoftPalette.slate800;
    final elapsed = _elapsedText(task);
    final seconds = DateTime.now().difference(task.startedAt).inSeconds;

    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 440),
        padding: EdgeInsets.symmetric(horizontal: quiet ? 12 : 16, vertical: quiet ? 8 : 11),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: accent.withValues(alpha: 0.35)),
          boxShadow: [
            BoxShadow(color: accent.withValues(alpha: 0.18), blurRadius: 18, offset: const Offset(0, 6)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: quiet ? 13 : 16,
              height: quiet ? 13 : 16,
              child: CircularProgressIndicator(strokeWidth: 2.2, color: accent),
            ),
            SizedBox(width: quiet ? 9 : 11),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${task.message}…',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: quiet ? 12 : 13.5,
                      fontWeight: quiet ? FontWeight.w500 : FontWeight.w600,
                      color: fg,
                    ),
                  ),
                  if (!quiet && (task.detail != null || seconds >= 10))
                    Text(
                      task.detail ?? 'Still working — please wait',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: fg.withValues(alpha: 0.65)),
                    ),
                ],
              ),
            ),
            if (elapsed.isNotEmpty) ...[
              const SizedBox(width: 10),
              Text(
                elapsed,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: accent,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _BlockingCard extends StatelessWidget {
  const _BlockingCard({super.key, required this.task, required this.isDark});
  final BusyTask task;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final seconds = DateTime.now().difference(task.startedAt).inSeconds;
    final fg = isDark ? SoftPalette.slate100 : SoftPalette.slate800;
    final sub = fg.withValues(alpha: 0.65);
    final reassurance = seconds >= 20
        ? 'This is taking longer than usual, but the app is still working. Please don\'t close it.'
        : seconds >= 8
            ? 'This can take a little while with a lot of data. Please don\'t close the app.'
            : (task.detail ?? 'This will only take a moment.');

    return Material(
      color: Colors.transparent,
      child: Container(
        color: (isDark ? Colors.black : SoftPalette.slate900).withValues(alpha: 0.45),
        alignment: Alignment.center,
        child: Container(
            width: 360,
            padding: const EdgeInsets.fromLTRB(26, 26, 26, 22),
            decoration: BoxDecoration(
              color: isDark ? SoftPalette.slate800 : Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: SoftPalette.teal500.withValues(alpha: 0.22),
                  blurRadius: 40,
                  offset: const Offset(0, 14),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(strokeWidth: 3.2, color: SoftPalette.teal500),
                ),
                const SizedBox(height: 18),
                Text(
                  '${task.message}…',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: fg),
                ),
                const SizedBox(height: 8),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: Text(
                    reassurance,
                    key: ValueKey(reassurance),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, height: 1.4, color: sub),
                  ),
                ),
                if (seconds >= 4) ...[
                  const SizedBox(height: 12),
                  Text(
                    _elapsedText(task),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: SoftPalette.teal500,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
                if (seconds >= 10) ...[
                  const SizedBox(height: 14),
                  TextButton(
                    onPressed: () {
                      task.end();
                      BusyStatus.dismissAll();
                    },
                    style: TextButton.styleFrom(
                      foregroundColor: SoftPalette.teal500,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('Dismiss Overlay', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
  }
}

class _RecoveredNotice extends StatelessWidget {
  const _RecoveredNotice({required this.notice, required this.isDark});
  final BusyNotice notice;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final fg = isDark ? SoftPalette.slate100 : SoftPalette.slate800;
    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onTap: BusyStatus.dismissNotice,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 520),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: isDark ? SoftPalette.slate800 : Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: SoftPalette.vividGreen.withValues(alpha: 0.45)),
            boxShadow: [
              BoxShadow(color: SoftPalette.vividGreen.withValues(alpha: 0.18), blurRadius: 18, offset: const Offset(0, 6)),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle_rounded, color: SoftPalette.vividGreen, size: 18),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  notice.message,
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: fg),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
