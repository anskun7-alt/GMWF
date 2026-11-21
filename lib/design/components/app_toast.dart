// lib/design/components/app_toast.dart
//
// ── AppToast — the app-wide notification / toast system ──────────────────────
// Every transient notification in the app (AppFeedback, Flushbar, SnackBar)
// is rendered here, so they all look and behave the same:
//
//   • Desktop / tablet: bottom-right corner, slides up from the bottom.
//   • Phone (< GBreakpoint.mobile): full width at the top, slides down.
//   • At most [maxVisible] (3) at a time — a 4th removes the oldest.
//   • Auto-closes after its duration (countdown bar; paused while hovered);
//     ✕ closes it immediately.
//   • An identical message already on screen is not shown twice.
//
// Design: one neutral card for every toast; the meaning (success / error /
// warning / info) is carried only by the icon badge and countdown colour.
// Legacy colours (SoftPalette.green500, 0xFFDC2626, ...) and leading emojis
// (✅ ⚠️ ❌) from old SnackBars/Flushbars are mapped onto those four kinds,
// and their text is extracted and re-typeset so everything looks consistent.
//
// Usage:
//   AppToast.show(message: 'Saved', kind: GToastKind.success);
//   AppToast.showSnackBar(context, SnackBar(content: Text('...')));  // drop-in
//
// [AppToastHost] is mounted once, above every route and dialog, in the
// MaterialApp builder (lib/main.dart).
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../tokens/breakpoints.dart';
import '../../services/busy_status.dart';
import '../../widgets/busy_status_host.dart';

enum GToastKind { success, error, warning, info }

/// Accent per kind and theme. Deliberately muted (no neon on dark, no glare on
/// light) for eye comfort; still WCAG-readable against the card surface.
class _Kind {
  final Color accent;
  final IconData icon;
  const _Kind(this.accent, this.icon);

  static IconData iconOf(GToastKind kind) => switch (kind) {
        GToastKind.success => Icons.check_circle_rounded,
        GToastKind.error => Icons.error_rounded,
        GToastKind.warning => Icons.warning_amber_rounded,
        GToastKind.info => Icons.info_rounded,
      };

  static _Kind of(GToastKind kind, {required bool dark}) {
    final accent = switch (kind) {
      GToastKind.success => dark ? SoftPalette.emerald350 : SoftPalette.emerald500,
      GToastKind.error => dark ? SoftPalette.red350 : SoftPalette.red500,
      GToastKind.warning => dark ? SoftPalette.amber300 : SoftPalette.amber400,
      GToastKind.info => dark ? SoftPalette.blue350 : SoftPalette.blue550,
    };
    return _Kind(accent, iconOf(kind));
  }
}

class _ToastEntry {
  final int id;
  final String? title;
  final String? message;
  final Widget? content; // only when the legacy content could not be re-typeset
  final IconData icon;
  final bool loading;
  final GToastKind kind;
  final Color? customAccent; // e.g. role accent; otherwise colour comes from kind + theme
  final Duration duration;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String dedupeKey;
  final Completer<void> closed = Completer<void>();

  _ToastEntry({
    required this.id,
    required this.title,
    required this.message,
    required this.content,
    required this.icon,
    required this.loading,
    required this.kind,
    required this.customAccent,
    required this.duration,
    required this.actionLabel,
    required this.onAction,
    required this.dedupeKey,
  });
}

class AppToast {
  AppToast._();

  static const int maxVisible = 3;
  static const Duration defaultDuration = Duration(seconds: 4);

  static final ValueNotifier<List<_ToastEntry>> _entries = ValueNotifier(const []);
  static int _seq = 0;

  /// Shows a toast. Returns a future that completes when it is closed.
  ///
  /// [kind] sets the meaning; when omitted it is inferred from a leading emoji
  /// or from [background] / [accent] (legacy colours), defaulting to info.
  static Future<void> show({
    String? message,
    String? title,
    Widget? content,
    GToastKind? kind,
    IconData? icon,
    Color? background,
    Color? accent,
    Duration? duration,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    var t = title?.trim();
    var m = message?.trim();
    IconData? parsedIcon;
    var loading = false;

    // Re-typeset legacy widget content (Text / Row[Icon, Text] ...) when possible.
    Widget? custom = content;
    if (content != null) {
      final parsed = _Parsed();
      _walk(content, parsed);
      if (parsed.clean && parsed.texts.isNotEmpty) {
        custom = null;
        if (parsed.texts.length >= 2 && (t == null || t.isEmpty)) {
          t = parsed.texts.first;
          m = parsed.texts.skip(1).join('\n');
        } else {
          m = [if (m != null && m.isNotEmpty) m, ...parsed.texts].join('\n');
        }
        parsedIcon = parsed.icon;
        loading = parsed.loading;
      }
    }

    // A leading emoji decides the kind (✅ ⚠️ ❌) and is dropped: the badge shows it.
    GToastKind? emojiKind;
    if (t != null && t.isNotEmpty) {
      final r = _stripLeadingSymbols(t);
      emojiKind = r.kind;
      t = r.text;
    } else if (m != null && m.isNotEmpty) {
      final r = _stripLeadingSymbols(m);
      emojiKind = r.kind;
      m = r.text;
    }

    final resolvedKind = kind ?? emojiKind ?? _kindFromColor(background ?? accent) ?? GToastKind.info;
    // A caller-chosen accent (e.g. role accent) is kept only when no kind was implied.
    final customAccent = (kind == null && emojiKind == null && background == null && accent != null)
        ? accent
        : null;

    final key = '${t ?? ''}|${m ?? ''}|${custom == null ? '' : identityHashCode(custom)}';
    final current = _entries.value;
    // Same message already visible (e.g. one event delivered twice): don't stack a copy.
    for (final e in current) {
      if (e.dedupeKey == key && key != '||') return e.closed.future;
    }

    final entry = _ToastEntry(
      id: ++_seq,
      title: (t == null || t.isEmpty) ? null : t,
      message: (m == null || m.isEmpty) ? null : m,
      content: custom,
      icon: icon ?? parsedIcon ?? _Kind.iconOf(resolvedKind),
      loading: loading,
      kind: resolvedKind,
      customAccent: customAccent,
      duration: duration ?? defaultDuration,
      actionLabel: actionLabel,
      onAction: onAction,
      dedupeKey: key,
    );
    final next = [...current, entry];
    // Max 3 on screen: the oldest gives way.
    while (next.length > maxVisible) {
      final oldest = next.removeAt(0);
      if (!oldest.closed.isCompleted) oldest.closed.complete();
    }
    _entries.value = next;
    return entry.closed.future;
  }

  /// Drop-in for `ScaffoldMessenger.of(context).showSnackBar(bar)`.
  static Future<void> showSnackBar(BuildContext context, SnackBar bar) => fromSnackBar(bar);

  /// Same as [showSnackBar] without a BuildContext (safe after an `await`).
  static Future<void> fromSnackBar(SnackBar bar) {
    final action = bar.action;
    return show(
      content: bar.content,
      background: bar.backgroundColor,
      duration: bar.duration,
      actionLabel: action?.label,
      onAction: action?.onPressed,
    );
  }

  /// Closes the most recent toast (replaces `hideCurrentSnackBar`).
  static void hideCurrent() {
    final current = _entries.value;
    if (current.isEmpty) return;
    dismiss(current.last.id);
  }

  /// Closes every toast (replaces `clearSnackBars`).
  static void clear() {
    for (final e in _entries.value) {
      if (!e.closed.isCompleted) e.closed.complete();
    }
    _entries.value = const [];
  }

  static void dismiss(int id) {
    final current = _entries.value;
    final idx = current.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    final e = current[idx];
    if (!e.closed.isCompleted) e.closed.complete();
    _entries.value = [...current]..removeAt(idx);
  }

  /// Shows one toast of each kind, one after another (Ctrl+Shift+T in main.dart).
  /// Five toasts with max 3 visible also demonstrates the oldest giving way.
  static void demo() {
    final samples = <void Function()>[
      () => show(title: 'Token issued', message: '101026-JLJ-002 → 7 (Zakat). Waiting for doctor.',
          kind: GToastKind.success, actionLabel: 'View', onAction: () {}),
      () => show(title: 'Adult patient found', message: 'Registering a CHILD of this guardian.', kind: GToastKind.info),
      () => show(message: '⚠️ Token was already used by another patient (issued on another desk).'),
      () => show(title: 'Upload failed', message: 'Cloud quota reached — will retry automatically.', kind: GToastKind.error),
      () => fromSnackBar(const SnackBar(
            duration: Duration(seconds: 6),
            content: Row(children: [
              SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 12),
              Text('Refreshing inventory from cloud...'),
            ]),
          )),
    ];
    for (var i = 0; i < samples.length; i++) {
      Timer(Duration(milliseconds: 450 * i), samples[i]);
    }
  }

  /// Plain text of a Text/RichText widget, or null.
  static String? plainText(Widget? w) {
    if (w is Text) return w.data ?? w.textSpan?.toPlainText();
    if (w is RichText) return w.text.toPlainText();
    return null;
  }

  // ── Legacy colour → kind ─────────────────────────────────────────────────
  static GToastKind? _kindFromColor(Color? c) {
    if (c == null || c.a < 0.2) return null;
    final hsv = HSVColor.fromColor(c);
    if (hsv.saturation < 0.25) return GToastKind.info; // greys / slate / navy-ish
    final h = hsv.hue;
    if (h < 15 || h >= 330) return GToastKind.error; // reds, crimson
    if (h < 55) return GToastKind.warning; // orange, amber, brown
    if (h < 190) return GToastKind.success; // greens, emerald, teal
    return GToastKind.info; // blues, indigo, purple
  }

  // ── Leading emoji / symbol handling ──────────────────────────────────────
  static ({String text, GToastKind? kind}) _stripLeadingSymbols(String s) {
    final runes = s.runes.toList();
    var i = 0;
    GToastKind? kind;
    // Symbols, arrows, dingbats, emoji, variation selectors, ZWJ.
    bool isSymbol(int r) =>
        (r >= 0x2190 && r <= 0x2BFF) || r >= 0x1F000 || r == 0xFE0F || r == 0x200D;
    while (i < runes.length && (isSymbol(runes[i]) || runes[i] == 0x20)) {
      final r = runes[i];
      kind ??= switch (r) {
        0x2705 || 0x2714 || 0x1F389 || 0x1F7E2 => GToastKind.success, // ✅ ✔ 🎉 🟢
        0x274C || 0x26D4 || 0x1F6AB || 0x1F6D1 || 0x2716 || 0x1F534 => GToastKind.error, // ❌ ⛔ 🚫 🛑 ✖ 🔴
        0x26A0 || 0x1F7E0 || 0x1F7E1 => GToastKind.warning, // ⚠ 🟠 🟡
        _ => null,
      };
      i++;
    }
    if (i == 0 || i >= runes.length) return (text: s, kind: null);
    return (text: String.fromCharCodes(runes.sublist(i)).trim(), kind: kind);
  }

  static void _walk(Widget w, _Parsed p) {
    if (!p.clean) return;
    if (w is Text) {
      final t = (w.data ?? w.textSpan?.toPlainText() ?? '').trim();
      if (t.isNotEmpty) p.texts.add(t);
    } else if (w is RichText) {
      final t = w.text.toPlainText().trim();
      if (t.isNotEmpty) p.texts.add(t);
    } else if (w is Icon) {
      p.icon ??= w.icon;
    } else if (w is CircularProgressIndicator || w is LinearProgressIndicator) {
      p.loading = true;
    } else if (w is Flex) {
      for (final c in w.children) {
        _walk(c, p);
      }
    } else if (w is Wrap) {
      for (final c in w.children) {
        _walk(c, p);
      }
    } else if (w is Flexible) {
      _walk(w.child, p);
    } else if (w is Padding) {
      if (w.child != null) _walk(w.child!, p);
    } else if (w is Align) {
      if (w.child != null) _walk(w.child!, p);
    } else if (w is SizedBox) {
      if (w.child != null) _walk(w.child!, p);
    } else if (w is Container) {
      if (w.child != null) _walk(w.child!, p);
    } else if (w is DefaultTextStyle) {
      _walk(w.child, p);
    } else if (w is Spacer) {
      // layout only
    } else {
      p.clean = false; // something we can't re-typeset: render it as-is
    }
  }
}

class _Parsed {
  final List<String> texts = [];
  IconData? icon;
  bool loading = false;
  bool clean = true;
}

/// Mount once above the app's Navigator (MaterialApp.builder).
class AppToastHost extends StatelessWidget {
  const AppToastHost({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<_ToastEntry>>(
      valueListenable: AppToast._entries,
      builder: (context, entries, _) {
        if (entries.isEmpty) return const SizedBox.shrink();
        final size = MediaQuery.sizeOf(context);
        final isPhone = size.width < GBreakpoint.mobile;
        final padding = MediaQuery.paddingOf(context);
        final dark = Theme.of(context).brightness == Brightness.dark;

        final cards = [
          for (final e in entries)
            Padding(
              key: ValueKey(e.id),
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: _ToastCard(entry: e, fromTop: isPhone, darkTheme: dark),
            ),
        ];

        final column = AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: isPhone ? Alignment.topCenter : Alignment.bottomCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            // Newest nearest the screen edge it comes from.
            children: isPhone ? cards.reversed.toList() : cards,
          ),
        );

        if (isPhone) {
          return Positioned(top: padding.top + 8, left: 12, right: 12, child: column);
        }
        // The sync pill ("Syncing offline data…") shares this corner and always
        // stays at the very bottom: while it shows, the cards sit above it.
        return ValueListenableBuilder<int>(
          valueListenable: BusyStatus.revision,
          builder: (context, _, _) => AnimatedPositioned(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            right: 20,
            bottom: padding.bottom + 20 + BusyStatusHost.pillLift(context),
            width: math.min(372.0, size.width - 40),
            child: column,
          ),
        );
      },
    );
  }
}

class _ToastCard extends StatefulWidget {
  final _ToastEntry entry;
  final bool fromTop;
  final bool darkTheme;
  const _ToastCard({required this.entry, required this.fromTop, required this.darkTheme});

  @override
  State<_ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<_ToastCard> with TickerProviderStateMixin {
  late final AnimationController _show = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
    reverseDuration: const Duration(milliseconds: 180),
  );
  // Countdown to auto-close; drives the progress bar and pauses on hover.
  late final AnimationController _life = AnimationController(vsync: this, duration: widget.entry.duration);
  bool _closing = false;
  bool _hovered = false;

  // Very long durations are "until done" toasts (e.g. a loading message): no bar.
  bool get _showCountdown => widget.entry.duration <= const Duration(minutes: 1);

  @override
  void initState() {
    super.initState();
    _show.forward();
    _life.addStatusListener((s) {
      if (s == AnimationStatus.completed) _close();
    });
    _life.forward();
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    _life.stop();
    if (mounted) await _show.reverse();
    AppToast.dismiss(widget.entry.id);
  }

  @override
  void dispose() {
    _show.dispose();
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    // Legacy widget content was built white-on-dark, so it keeps the dark card.
    final dark = widget.darkTheme || e.content != null;
    final accent = e.customAccent ?? _Kind.of(e.kind, dark: dark).accent;
    // Eye comfort: no pure white / pure black surfaces or text in either theme.
    final surface = dark ? SoftPalette.slate800 : SoftPalette.gray50;
    final border = dark ? SoftPalette.gray50.withValues(alpha: 0.08) : SoftPalette.slate150;
    final titleColor = dark ? SoftPalette.slate150 : SoftPalette.slate800;
    final detailColor = dark ? SoftPalette.slate350 : SoftPalette.slate550;
    final soloColor = dark ? SoftPalette.slate200 : SoftPalette.slate750;

    final enter = CurvedAnimation(parent: _show, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
    final slide = Tween<Offset>(begin: Offset(0, widget.fromTop ? -0.35 : 0.35), end: Offset.zero).animate(enter);
    final scale = Tween<double>(begin: 0.94, end: 1).animate(enter);

    final Widget body = e.content != null
        ? DefaultTextStyle.merge(
            style: TextStyle(color: soloColor, fontSize: 13.5, height: 1.3),
            child: IconTheme.merge(data: IconThemeData(color: soloColor), child: e.content!),
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (e.title != null)
                Text(
                  e.title!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: titleColor,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                    letterSpacing: -0.1,
                  ),
                ),
              if (e.message != null)
                Padding(
                  padding: EdgeInsets.only(top: e.title != null ? 3 : 0),
                  child: Text(
                    e.message!,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: e.title != null ? detailColor : soloColor,
                      fontSize: e.title != null ? 12.5 : 13,
                      fontWeight: e.title != null ? FontWeight.w400 : FontWeight.w500,
                      height: 1.35,
                    ),
                  ),
                ),
            ],
          );

    final badge = Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: dark ? 0.16 : 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: e.loading
          ? SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: accent),
            )
          : Icon(e.icon, color: accent, size: 19),
    );

    final card = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(color: SoftPalette.gray900.withValues(alpha: dark ? 0.22 : 0.08), blurRadius: 24, offset: const Offset(0, 8)),
          BoxShadow(color: SoftPalette.gray900.withValues(alpha: dark ? 0.12 : 0.05), blurRadius: 4, offset: const Offset(0, 1)),
        ],
      ),
      child: Material(
        color: surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 6, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (e.content == null) ...[badge, const SizedBox(width: 12)],
                  Expanded(
                    child: Padding(
                      // Centre a one-line message against the 34px badge.
                      padding: EdgeInsets.only(top: e.content == null && e.title == null ? 7 : 1),
                      child: body,
                    ),
                  ),
                  if (e.actionLabel != null && e.onAction != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: TextButton(
                        onPressed: () {
                          e.onAction!();
                          _close();
                        },
                        style: TextButton.styleFrom(
                          foregroundColor: accent,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          minimumSize: const Size(0, 32),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        child: Text(e.actionLabel!, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
                      ),
                    ),
                  _CloseButton(onTap: _close, dark: dark),
                ],
              ),
            ),
            if (_showCountdown)
              AnimatedBuilder(
                animation: _life,
                builder: (context, _) => Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FractionallySizedBox(
                    widthFactor: 1 - _life.value,
                    child: Container(height: 2.5, color: accent.withValues(alpha: _hovered ? 0.45 : 0.85)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    return FadeTransition(
      opacity: enter,
      child: SlideTransition(
        position: slide,
        child: ScaleTransition(
          scale: scale,
          alignment: widget.fromTop ? Alignment.topCenter : Alignment.bottomRight,
          child: MouseRegion(
            // Reading it: hold the countdown while the pointer is on the toast.
            onEnter: (_) {
              _life.stop();
              setState(() => _hovered = true);
            },
            onExit: (_) {
              setState(() => _hovered = false);
              if (!_closing) _life.forward();
            },
            child: card,
          ),
        ),
      ),
    );
  }
}

class _CloseButton extends StatefulWidget {
  final VoidCallback onTap;
  final bool dark;
  const _CloseButton({required this.onTap, required this.dark});

  @override
  State<_CloseButton> createState() => _CloseButtonState();
}

class _CloseButtonState extends State<_CloseButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: (widget.dark ? SoftPalette.gray50 : SoftPalette.gray900).withValues(alpha: _hover ? (widget.dark ? 0.10 : 0.06) : 0.0),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(
            Icons.close_rounded,
            size: 16,
            color: widget.dark
                ? SoftPalette.gray50.withValues(alpha: _hover ? 0.9 : 0.5)
                : SoftPalette.slate800.withValues(alpha: _hover ? 0.85 : 0.45),
          ),
        ),
      ),
    );
  }
}
