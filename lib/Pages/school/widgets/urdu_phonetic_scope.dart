// lib/pages/school/widgets/urdu_phonetic_scope.dart
//
// Turns on the Urdu phonetic keyboard (core/urdu_phonetic.dart) for every text
// field while the School module is open, including fields inside dialogs.
//
//   • Ctrl + Shift + K switches English ⇄ Urdu.
//   • A floating "اردو / EN" button (bottom corner, above dialogs) does the same;
//     long-press it to see the key map.
//   • The choice is remembered per device (app_settings: school_urdu_phonetic).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gmwf_ui/gmwf_ui.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../core/urdu_phonetic.dart';

class UrduPhoneticScope extends StatefulWidget {
  const UrduPhoneticScope({super.key, required this.child, this.showButton = true});

  final Widget child;
  final bool showButton;

  /// True while Urdu mode is on.
  static final ValueNotifier<bool> enabled = ValueNotifier<bool>(_load());

  static const String _prefKey = 'school_urdu_phonetic';

  static bool _load() {
    try {
      return Hive.isBoxOpen('app_settings') && Hive.box('app_settings').get(_prefKey) == true;
    } catch (_) {
      return false;
    }
  }

  static void toggle() => setEnabled(!enabled.value);

  static void setEnabled(bool on) {
    enabled.value = on;
    try {
      if (Hive.isBoxOpen('app_settings')) Hive.box('app_settings').put(_prefKey, on);
    } catch (_) {}
  }

  @override
  State<UrduPhoneticScope> createState() => _UrduPhoneticScopeState();
}

class _UrduPhoneticScopeState extends State<UrduPhoneticScope> {
  TextEditingController? _controller;
  TextEditingValue _last = TextEditingValue.empty;
  bool _applying = false;
  OverlayEntry? _button;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocusChange);
    HardwareKeyboard.instance.addHandler(_onKey);
    if (widget.showButton) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _insertButton());
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocusChange);
    HardwareKeyboard.instance.removeHandler(_onKey);
    _detach();
    _button?.remove();
    _button = null;
    super.dispose();
  }

  // ── Shortcut ─────────────────────────────────────────────────────────────
  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.keyK) return false;
    final k = HardwareKeyboard.instance;
    if (!(k.isControlPressed && k.isShiftPressed)) return false;
    UrduPhoneticScope.toggle();
    return true;
  }

  // ── Following the focused field ──────────────────────────────────────────
  void _onFocusChange() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    final state = ctx?.findAncestorStateOfType<EditableTextState>();
    final controller = (state == null || UrduPhonetic.skipField(state.widget)) ? null : state.widget.controller;
    if (identical(controller, _controller)) return;
    _detach();
    if (controller != null) {
      _controller = controller;
      _last = controller.value;
      controller.addListener(_onEdit);
    }
  }

  void _detach() {
    _controller?.removeListener(_onEdit);
    _controller = null;
  }

  void _onEdit() {
    final c = _controller;
    if (c == null || _applying) return;
    final current = c.value;
    if (UrduPhoneticScope.enabled.value) {
      final converted = UrduPhonetic.convertEdit(_last, current);
      if (converted != null) {
        _applying = true;
        c.value = converted;
        _applying = false;
      }
    }
    _last = c.value;
  }

  // ── Floating switch ──────────────────────────────────────────────────────
  void _insertButton() {
    if (!mounted || _button != null) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final theme = Theme.of(context);
    _button = OverlayEntry(
      builder: (_) => PositionedDirectional(
        end: Gsp.sp4,
        bottom: Gsp.sp4,
        child: SafeArea(child: Theme(data: theme, child: const _PhoneticButton())),
      ),
    );
    overlay.insert(_button!);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _PhoneticButton extends StatelessWidget {
  const _PhoneticButton();

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    return ValueListenableBuilder<bool>(
      valueListenable: UrduPhoneticScope.enabled,
      builder: (context, on, _) => Tooltip(
        message: on
            ? 'Urdu phonetic keyboard ON — Ctrl+Shift+K to switch. Long-press for the key map.'
            : 'Type in Urdu (phonetic) — Ctrl+Shift+K. Long-press for the key map.',
        child: Material(
          color: on ? c.brand : c.surfaceRaised,
          elevation: 4,
          shape: StadiumBorder(side: BorderSide(color: on ? c.brand : c.borderStrong)),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: UrduPhoneticScope.toggle,
            onLongPress: () => showUrduPhoneticHelp(context),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3, vertical: Gsp.sp2),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(GIcons.keyboard, size: GIconSize.sm, color: on ? c.onBrand : c.textSecondary),
                const SizedBox(width: Gsp.sp2),
                Text(
                  on ? 'اردو' : 'EN',
                  style: on ? GText.urdu(c.onBrand, size: 15).copyWith(height: 1.2) : GText.label(c.textPrimary),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet with the full key map.
Future<void> showUrduPhoneticHelp(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) {
        final c = ctx.comfort;
        Widget key(String k, String u) => Container(
              width: 64,
              padding: const EdgeInsets.symmetric(vertical: Gsp.sp1),
              decoration: BoxDecoration(color: c.surfaceSunken, borderRadius: Gr.input, border: Border.all(color: c.border)),
              child: Column(children: [
                Text(u, style: GText.urdu(c.textPrimary, size: 20).copyWith(height: 1.5)),
                Text(k, style: GText.caption(c.textMuted)),
              ]),
            );
        Widget section(String title, Map<String, String> m) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: Gsp.sp4, bottom: Gsp.sp2),
                child: Text(title.toUpperCase(), style: GText.overline(c.textMuted)),
              ),
              Wrap(spacing: Gsp.sp2, runSpacing: Gsp.sp2, children: [for (final e in m.entries) key(e.key, e.value)]),
            ]);
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.75,
          builder: (ctx, scroll) => ListView(
            controller: scroll,
            padding: const EdgeInsets.all(Gsp.sp5),
            children: [
              Text('Urdu phonetic keyboard', style: GText.h3(c.textPrimary)),
              const SizedBox(height: Gsp.sp1),
              Text(
                'Press Ctrl + Shift + K (or tap the اردو / EN button) to switch. Keys sound like the letter, as in InPage: '
                'a → ا, b → ب, s → س. Hold Shift for the second letter (Shift+s → ص). Numbers, phone and CNIC fields stay in English.',
                style: GText.body2(c.textSecondary),
              ),
              section('Letters', UrduPhonetic.lower),
              section('With Shift', UrduPhonetic.upper),
              section('Punctuation', UrduPhonetic.punctuation),
            ],
          ),
        );
      },
    );
