// lib/pages/dasterkhwaan/widgets/cook_dialog.dart
//
// Cook / Received-Food / Use-Saved-Food bottom-sheet dialogs.
// Rules enforced:
//  • Stock cannot go negative (qty capped at available stock)
//  • Qty must be > 0
//  • Same ingredient cannot be added twice
//  • "Served" is removed — it comes from token count automatically
//  • Wastage / Saved / Used are logged separately at the bottom
//  • For Saved Food: used + saved + wasted cannot exceed available stock qty
//  • For Cooked Food: saved + wasted cannot exceed used (total output)

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:gmwf/design/tokens/comfort_colors.dart';
import 'package:gmwf/design/components/app_toast.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../models/stock_item.dart';
import '../../../services/cloud/cloud_db.dart';
import '../../../services/stock_floor.dart';

/// Kitchen writes go through [CloudDb]: Firestore answers or the call fails within seconds.
/// An SDK commit on Windows never returns when the daily quota is used up, which left these
/// dialogs spinning forever. Returns false (and tells the user) when the save did not happen.
Future<bool> commitKitchenBatch(BuildContext ctx, CloudBatch batch) async {
  try {
    await batch.commit();
    return true;
  } catch (e) {
    debugPrint('[CookDialog] save failed: $e');
    if (ctx.mounted) {
      AppToast.showSnackBar(ctx, SnackBar(
        content: Text(e is FirebaseException && e.code == 'resource-exhausted'
            ? 'Not saved: today\'s cloud write limit is used up. Try again after the daily reset.'
            : 'Not saved: could not reach the cloud. Check the internet and try again.'),
        backgroundColor: kAccent,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ));
    }
    return false;
  }
}

// ─── Palette (shared across files) ──────────────────────────────────────────
const Color kPrimary   = SoftPalette.slate800;
const Color kAccent    = SoftPalette.red400;
const Color kSuccess   = SoftPalette.green350;
const Color kWarning   = SoftPalette.amber300;
const Color kInfo      = SoftPalette.blue500;
const Color kPurple    = SoftPalette.violet500;
const Color kSurface   = SoftPalette.gray50;
const Color kCardBg    = SoftPalette.gray50;
const Color kTextDark  = SoftPalette.slate900;
const Color kTextMid   = SoftPalette.slate600;
const Color kTextLight = SoftPalette.slate350;
const Color kTeal      = SoftPalette.teal500;

// ─── Shared decoration helpers ───────────────────────────────────────────────
InputDecoration kInputDeco(String label, IconData icon, BuildContext context) => InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, color: context.adapt(kPrimary), size: 20),
      filled: true,
      fillColor: context.adapt(kSurface),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: context.adapt(kPrimary), width: 2)),
      contentPadding:
          const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
    );

Widget kLabel(String text, BuildContext context) => Text(text,
    style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w800,
        color: context.adapt(kTextLight),
        letterSpacing: 1.1));

Widget kSheetHandle(Color accentColor) => Center(
      child: Container(
        width: 60,
        height: 5,
        margin: const EdgeInsets.only(top: 10, bottom: 4),
        decoration: BoxDecoration(
            color: accentColor.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(3)),
      ),
    );

// ════════════════════════════════════════════════════════════════════════════
// FOOD TYPE CHOOSER SHEET
// ════════════════════════════════════════════════════════════════════════════

void showFoodTypeChooser(
  BuildContext context, {
  required List<StockItem> allStockItems,
  required bool stockLoaded,
  required String branchId,
  required String today,
  required Future<void> Function() onDone,
}) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => Container(
      decoration: BoxDecoration(
        color: context.adapt(kCardBg),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 40),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        kSheetHandle(kWarning),
        const SizedBox(height: 12),
        Text('What are you logging?',
            style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.w900, color: context.adapt(kTextDark))),
        const SizedBox(height: 6),
        Text('Choose the type of food entry',
            style: TextStyle(fontSize: 13, color: context.adapt(kTextLight))),
        const SizedBox(height: 24),

        _typeOption(
          context: context,
          color: kWarning,
          icon: Icons.soup_kitchen_rounded,
          title: 'Cooked In-House',
          subtitle: 'Ingredients deducted from inventory',
          onTap: () {
            Navigator.pop(context);
            showCookDialog(
              context,
              isReceivedFood: false,
              allStockItems: allStockItems,
              stockLoaded: stockLoaded,
              branchId: branchId,
              today: today,
              onDone: onDone,
            );
          },
        ),

        const SizedBox(height: 12),

        _typeOption(
          context: context,
          color: kPurple,
          icon: Icons.delivery_dining_rounded,
          title: 'Received Food',
          subtitle: 'Biryani daig, donation etc. — no inventory deduction',
          onTap: () {
            Navigator.pop(context);
            showCookDialog(
              context,
              isReceivedFood: true,
              allStockItems: allStockItems,
              stockLoaded: stockLoaded,
              branchId: branchId,
              today: today,
              onDone: onDone,
            );
          },
        ),

        const SizedBox(height: 12),

        _typeOption(
          context: context,
          color: kTeal,
          icon: Icons.recycling_rounded,
          title: 'Use Saved Food',
          subtitle: 'Serve yesterday\'s carry-over — deducted from saved stock',
          badge: allStockItems.where((i) => i.name.startsWith('Saved:')).length,
          onTap: () {
            Navigator.pop(context);
            showSavedFoodDialog(
              context,
              allStockItems: allStockItems,
              stockLoaded: stockLoaded,
              branchId: branchId,
              today: today,
              onDone: onDone,
            );
          },
        ),

        const SizedBox(height: 8),
      ]),
    ),
  );
}

Widget _typeOption({
  required BuildContext context,
  required Color color,
  required IconData icon,
  required String title,
  required String subtitle,
  required VoidCallback onTap,
  int badge = 0,
}) =>
    GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: color.withValues(alpha: 0.3), width: 1.5),
        ),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(14)),
            child: Icon(icon, color: color, size: 26),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Row(children: [
                Text(title,
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: context.adapt(kTextDark))),
                if (badge > 0) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(20)),
                    child: Text('$badge',
                        style: const TextStyle(
                            color: SoftPalette.gray50,
                            fontSize: 10,
                            fontWeight: FontWeight.w900)),
                  ),
                ],
              ]),
              const SizedBox(height: 3),
              Text(subtitle,
                  style: TextStyle(fontSize: 12, color: context.adapt(kTextMid))),
            ]),
          ),
          Icon(Icons.chevron_right_rounded, color: color, size: 22),
        ]),
      ),
    );

// ════════════════════════════════════════════════════════════════════════════
// USE SAVED FOOD DIALOG
// ════════════════════════════════════════════════════════════════════════════

void showSavedFoodDialog(
  BuildContext context, {
  Map<String, dynamic>? existing,
  String? docId,
  required List<StockItem> allStockItems,
  required bool stockLoaded,
  required String branchId,
  required String today,
  required Future<void> Function() onDone,
}) {
  final isEdit = existing != null && docId != null;

  final savedItems =
      allStockItems.where((i) => i.name.startsWith('Saved:')).toList()
        ..sort((a, b) => a.name.compareTo(b.name));

  StockItem? selectedItem;
  if (isEdit) {
    final dishName = existing['dish'] as String? ?? '';
    try {
      selectedItem = allStockItems.firstWhere((i) => i.name == dishName);
    } catch (_) {}
  }

  final formKey    = GlobalKey<FormState>();
  final notesCtrl  = TextEditingController(text: existing?['notes'] ?? '');
  final usedCtrl   = TextEditingController(
      text: existing != null && (existing['usedKg'] as num? ?? 0) != 0
          ? '${existing['usedKg']}'
          : '');
  final savedCtrl  = TextEditingController(
      text: existing != null && (existing['savedKg'] as num? ?? 0) != 0
          ? '${existing['savedKg']}'
          : '');
  final wastedCtrl = TextEditingController(
      text: existing != null && (existing['wastedKg'] as num? ?? 0) != 0
          ? '${existing['wastedKg']}'
          : '');

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => StatefulBuilder(
      builder: (ctx, setModal) {
        // When editing, add back the previously logged total so the user
        // can redistribute it freely (e.g. fix a wrong value).
        double availableQty = selectedItem?.quantity ?? 0;
        if (isEdit && selectedItem != null) {
          final prevUsed    = (existing['usedKg']   as num? ?? 0).toDouble();
          final prevSaved   = (existing['savedKg']  as num? ?? 0).toDouble();
          final prevWasted  = (existing['wastedKg'] as num? ?? 0).toDouble();
          availableQty += prevUsed + prevSaved + prevWasted;
        }

        return Padding(
          padding:
              EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Container(
            decoration: BoxDecoration(
              color: ctx.adapt(kCardBg),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              kSheetHandle(kTeal),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 36),
                  child: Form(
                    key: formKey,
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [

                      // ── Header ────────────────────────────────────────
                      Row(children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                              color: kTeal.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(12)),
                          child: const Icon(Icons.recycling_rounded,
                              color: kTeal, size: 22),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(
                              isEdit
                                  ? 'Edit Saved Food Entry'
                                  : 'Use Saved Food',
                              style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w900),
                            ),
                            Text(
                              'Serving carry-over from previous day',
                              style: TextStyle(
                                  fontSize: 12, color: ctx.adapt(kTextLight)),
                            ),
                          ]),
                        ),
                      ]),
                      const SizedBox(height: 16),

                      // ── Info banner ───────────────────────────────────
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: kTeal.withValues(alpha: 0.07),
                          borderRadius: BorderRadius.circular(12),
                          border:
                              Border.all(color: kTeal.withValues(alpha: 0.25)),
                        ),
                        child: Row(children: [
                          const Icon(Icons.info_outline_rounded,
                              color: kTeal, size: 16),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'This logs how you used previously saved food. '
                              'Stock will NOT be deducted — it was already '
                              'carried over from yesterday.',
                              style: TextStyle(
                                  fontSize: 12, color: ctx.adapt(kTextMid)),
                            ),
                          ),
                        ]),
                      ),
                      const SizedBox(height: 20),

                      // ── Saved item picker ─────────────────────────────
                      kLabel('SELECT SAVED FOOD', ctx),
                      const SizedBox(height: 8),

                      if (savedItems.isEmpty)
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: kAccent.withValues(alpha: 0.07),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: kAccent.withValues(alpha: 0.3)),
                          ),
                          child: const Row(children: [
                            Icon(Icons.warning_rounded,
                                color: kAccent, size: 18),
                            SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'No saved food carry-overs found in inventory.',
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: kAccent),
                              ),
                            ),
                          ]),
                        )
                      else
                        ...savedItems.map((item) {
                          final isSelected =
                              selectedItem?.id == item.id;
                          return GestureDetector(
                            onTap: () =>
                                setModal(() => selectedItem = item),
                            child: AnimatedContainer(
                              duration:
                                  const Duration(milliseconds: 180),
                              margin:
                                  const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 12),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? kTeal.withValues(alpha: 0.08)
                                    : ctx.adapt(kSurface),
                                borderRadius:
                                    BorderRadius.circular(14),
                                border: Border.all(
                                  color: isSelected
                                      ? kTeal
                                      : Colors.transparent,
                                  width: isSelected ? 2 : 1,
                                ),
                              ),
                              child: Row(children: [
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? kTeal.withValues(alpha: 0.15)
                                        : ctx.adapt(SoftPalette.gray50),
                                    borderRadius:
                                        BorderRadius.circular(10),
                                  ),
                                  child: Icon(
                                    Icons.save_rounded,
                                    color: isSelected
                                        ? kTeal
                                        : ctx.adapt(kTextLight),
                                    size: 18,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                    Text(
                                      item.name
                                          .replaceFirst('Saved: ', ''),
                                      style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w800,
                                          color: isSelected
                                              ? kTeal
                                              : ctx.adapt(kTextDark)),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${item.quantity} ${item.unit} available',
                                      style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: item.quantity <= 0
                                              ? kAccent
                                              : ctx.adapt(kTextLight)),
                                    ),
                                  ]),
                                ),
                                if (isSelected)
                                  Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: const BoxDecoration(
                                        color: kTeal,
                                        shape: BoxShape.circle),
                                    child: const Icon(
                                        Icons.check_rounded,
                                        color: SoftPalette.gray50,
                                        size: 14),
                                  ),
                              ]),
                            ),
                          );
                        }),

                      // ── Quantities ────────────────────────────────────
                      if (selectedItem != null || isEdit) ...[
                        const SizedBox(height: 20),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: kTeal.withValues(alpha: 0.04),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                                color: kTeal.withValues(alpha: 0.2)),
                          ),
                          child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                            Row(children: [
                              const Icon(
                                  Icons.monitor_weight_outlined,
                                  color: kTeal,
                                  size: 18),
                              const SizedBox(width: 8),
                              const Text('QUANTITIES',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w900,
                                      color: kTeal,
                                      letterSpacing: 1.0)),
                            ]),
                            if (selectedItem != null) ...[
                              const SizedBox(height: 8),
                              // ── Available stock banner ────────────────
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 8),
                                decoration: BoxDecoration(
                                  color: kTeal.withValues(alpha: 0.08),
                                  borderRadius:
                                      BorderRadius.circular(10),
                                ),
                                child: Row(children: [
                                  const Icon(Icons.inventory_rounded,
                                      color: kTeal, size: 14),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Available: $availableQty ${selectedItem!.unit}  '
                                    '— Used + Saved + Wasted must not exceed this',
                                    style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: kTeal),
                                  ),
                                ]),
                              ),
                            ],
                            // Info: served from tokens
                            Container(
                              margin:
                                  const EdgeInsets.symmetric(vertical: 8),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: kSuccess.withValues(alpha: 0.08),
                                borderRadius:
                                    BorderRadius.circular(10),
                                border: Border.all(
                                    color:
                                        kSuccess.withValues(alpha: 0.25)),
                              ),
                              child: Row(children: [
                                const Icon(
                                    Icons.confirmation_number_rounded,
                                    color: kSuccess,
                                    size: 15),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '"Served" is tracked automatically from tokens.',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: ctx.adapt(kTextMid),
                                        fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ]),
                            ),
                            Row(children: [
                              Expanded(
                                  child: _numField(
                                      usedCtrl,
                                      'Used (kg)',
                                      Icons.whatshot_rounded,
                                      kTeal)),
                              const SizedBox(width: 10),
                              Expanded(
                                  child: _numField(
                                      savedCtrl,
                                      'Saved (kg)',
                                      Icons.save_rounded,
                                      kInfo)),
                            ]),
                            const SizedBox(height: 10),
                            SizedBox(
                              width: double.infinity,
                              child: _numField(
                                  wastedCtrl,
                                  'Wasted (kg)',
                                  Icons.delete_outline_rounded,
                                  kAccent),
                            ),
                          ]),
                        ),
                      ],

                      const SizedBox(height: 16),

                      // ── Notes ─────────────────────────────────────────
                      kLabel('NOTES (OPTIONAL)', ctx),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: notesCtrl,
                        maxLines: 2,
                        decoration: kInputDeco(
                            'Any observations…', Icons.notes_rounded, ctx),
                      ),
                      const SizedBox(height: 24),

                      // ── Submit ────────────────────────────────────────
                      SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor:
                                (selectedItem == null && !isEdit)
                                    ? kTeal.withValues(alpha: 0.4)
                                    : kTeal,
                            foregroundColor: SoftPalette.gray50,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16)),
                            elevation: 0,
                          ),
                          onPressed:
                              (selectedItem == null && !isEdit)
                                  ? null
                                  : () async {
                                      if (!formKey.currentState!
                                          .validate()) {
                                        return;
                                      }
                                      if (selectedItem == null) return;

                                      final usedKg   = double.tryParse(usedCtrl.text)   ?? 0;
                                      final savedKg  = double.tryParse(savedCtrl.text)  ?? 0;
                                      final wastedKg = double.tryParse(wastedCtrl.text) ?? 0;

                                      // ── VALIDATION: total must not exceed available ──
                                      final totalKg = usedKg + savedKg + wastedKg;
                                      if (totalKg > availableQty) {
                                        AppToast.showSnackBar(ctx, 
                                          SnackBar(
                                            content: Text(
                                              'Total (${totalKg.toStringAsFixed(2)} kg) exceeds '
                                              'available stock (${availableQty.toStringAsFixed(2)} kg). '
                                              'Used + Saved + Wasted cannot exceed what you have.',
                                            ),
                                            backgroundColor: kAccent,
                                            behavior: SnackBarBehavior.floating,
                                            margin: const EdgeInsets.all(16),
                                            shape: RoundedRectangleBorder(
                                                borderRadius: BorderRadius.circular(12)),
                                          ),
                                        );
                                        return;
                                      }

                                      final dishName    = selectedItem!.name;
                                      final displayName =
                                          dishName.replaceFirst('Saved: ', '');

                                      final data = {
                                        'dish':           dishName,
                                        'isReceivedFood': false,
                                        'isSavedFood':    true,
                                        'source':         'Carry-over',
                                        'usedKg':         usedKg,
                                        'savedKg':        savedKg,
                                        'wastedKg':       wastedKg,
                                        'cookedKg':       usedKg,
                                        'distributedKg':  0.0,
                                        'ingredients':    [],
                                        'notes':          notesCtrl.text.trim(),
                                        'createdAt': FieldValue.serverTimestamp(),
                                        'savedCarriedOver': false,
                                      };

                                      final fs     = FirebaseFirestore.instance;
                                      final dayDoc = fs
                                          .collection('branches')
                                          .doc(branchId)
                                          .collection('dasterkhwaan')
                                          .doc(today);
                                      final cookCol =
                                          dayDoc.collection('cooking_sessions');
                                      final batch = CloudDb.instance.batch();

                                      if (isEdit) {
                                        batch.update(cookCol.doc(docId), data);
                                      } else {
                                        batch.set(cookCol.doc(), data);
                                      }

                                      if (!await commitKitchenBatch(ctx, batch)) return;
                                      await onDone();
                                      if (ctx.mounted) Navigator.pop(ctx);

                                      AppToast.showSnackBar(ctx, SnackBar(
                                        content: Text(isEdit
                                            ? '$displayName updated'
                                            : '$displayName (saved food) logged'),
                                        backgroundColor: kTeal,
                                        behavior: SnackBarBehavior.floating,
                                        margin: const EdgeInsets.all(16),
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(12)),
                                      ));
                                    },
                          child: Text(
                            isEdit
                                ? 'Update Entry'
                                : 'Log Saved Food Usage',
                            style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800),
                          ),
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
            ]),
          ),
        );
      },
    ),
  );
}

// ════════════════════════════════════════════════════════════════════════════
// COOK / RECEIVED FOOD DIALOG
// ════════════════════════════════════════════════════════════════════════════

void showCookDialog(
  BuildContext context, {
  Map<String, dynamic>? existing,
  String? docId,
  bool isReceivedFood = false,
  required List<StockItem> allStockItems,
  required bool stockLoaded,
  required String branchId,
  required String today,
  required Future<void> Function() onDone,
}) {
  final isEdit = existing != null && docId != null;
  final bool isReceived =
      isEdit ? (existing['isReceivedFood'] as bool? ?? false) : isReceivedFood;

  final formKey        = GlobalKey<FormState>();
  final dishCtrl       = TextEditingController(text: existing?['dish'] ?? '');
  final sourceCtrl     = TextEditingController(text: existing?['source'] ?? '');
  final notesCtrl      = TextEditingController(text: existing?['notes'] ?? '');
  final usedCtrl       = TextEditingController(
      text: existing != null && (existing['usedKg'] as num? ?? 0) != 0
          ? '${existing['usedKg']}'
          : '');
  final savedCtrl      = TextEditingController(
      text: existing != null && (existing['savedKg'] as num? ?? 0) != 0
          ? '${existing['savedKg']}'
          : '');
  final wastedCtrl     = TextEditingController(
      text: existing != null && (existing['wastedKg'] as num? ?? 0) != 0
          ? '${existing['wastedKg']}'
          : '');

  final List<Map<String, dynamic>> ingredientRows = (!isReceived && isEdit)
      ? List<Map<String, dynamic>>.from(
          (existing['ingredients'] as List<dynamic>? ?? [])
              .map((e) => Map<String, dynamic>.from(e as Map)))
      : (isReceived ? [] : [{'name': '', 'qty': '', 'unit': 'kg'}]);

  final Color typeColor   = isReceived ? kPurple : kWarning;
  final IconData typeIcon =
      isReceived ? Icons.delivery_dining_rounded : Icons.soup_kitchen_rounded;
  final String typeTitle  = isReceived
      ? (isEdit ? 'Edit Received Food' : 'Log Received Food')
      : (isEdit ? 'Edit Cooking Session' : 'Start Cooking');
  final String typeSubtitle = isReceived
      ? (isEdit ? 'Update info' : 'Log externally received food — no stock deduction')
      : (isEdit ? 'Update quantities & ingredients' : 'Ingredients deducted from inventory');

  final savedStockItems =
      allStockItems.where((i) => i.name.startsWith('Saved:')).toList();
  final regularStockItems =
      allStockItems.where((i) => !i.name.startsWith('Saved:')).toList();

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => StatefulBuilder(
      builder: (ctx, setModal) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Container(
          decoration: BoxDecoration(
            color: ctx.adapt(kCardBg),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            kSheetHandle(typeColor),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 36),
                child: Form(
                  key: formKey,
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [

                    // ── Header ──────────────────────────────────────────
                    Row(children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                            color: typeColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(12)),
                        child: Icon(typeIcon, color: typeColor, size: 22),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text(typeTitle,
                              style: const TextStyle(
                                  fontSize: 20, fontWeight: FontWeight.w900)),
                          Text(typeSubtitle,
                              style: TextStyle(
                                  fontSize: 12, color: ctx.adapt(kTextLight))),
                        ]),
                      ),
                    ]),
                    const SizedBox(height: 20),

                    // ── Received food info banner ────────────────────────
                    if (isReceived)
                      Container(
                        margin: const EdgeInsets.only(bottom: 16),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: kPurple.withValues(alpha: 0.07),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: kPurple.withValues(alpha: 0.2)),
                        ),
                        child: Row(children: [
                          const Icon(Icons.info_outline_rounded,
                              color: kPurple, size: 16),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Received externally (daig, donation, etc.). '
                              'Nothing will be deducted from your inventory.',
                              style: TextStyle(fontSize: 12, color: ctx.adapt(kTextMid)),
                            ),
                          ),
                        ]),
                      ),

                    // ── Dish name ────────────────────────────────────────
                    kLabel(isReceived ? 'DISH / FOOD NAME' : 'DISH / MENU NAME', ctx),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: dishCtrl,
                      decoration: kInputDeco(
                        isReceived
                            ? 'e.g. Biryani, Aloo Qeema, Daal'
                            : 'e.g. Daal Chawal, Karahi',
                        Icons.restaurant_menu_rounded,
                        ctx,
                      ),
                      validator: (v) =>
                          v?.trim().isEmpty ?? true ? 'Required' : null,
                    ),

                    // ── Source (received only) ───────────────────────────
                    if (isReceived) ...[
                      const SizedBox(height: 14),
                      kLabel('SOURCE (OPTIONAL)', ctx),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: sourceCtrl,
                        decoration: kInputDeco(
                            'e.g. Donated by XYZ, Catered from ABC',
                            Icons.store_rounded, ctx),
                      ),
                    ],

                    // ── Ingredients (cooked in-house only) ───────────────
                    if (!isReceived) ...[
                      const SizedBox(height: 16),

                      if (savedStockItems.isNotEmpty)
                        Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: kTeal.withValues(alpha: 0.07),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: kTeal.withValues(alpha: 0.25)),
                          ),
                          child: Row(children: [
                            const Icon(Icons.recycling_rounded,
                                color: kTeal, size: 16),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${savedStockItems.length} saved carry-over(s) available — '
                                'search "Saved:" to use them as ingredients.',
                                style: const TextStyle(
                                    fontSize: 11,
                                    color: kTeal,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                          ]),
                        ),

                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            kLabel('INGREDIENTS USED', ctx),
                            const SizedBox(height: 2),
                            Text('Deducted from stock on save',
                                style: TextStyle(
                                    fontSize: 11, color: ctx.adapt(kTextLight))),
                          ]),
                          TextButton.icon(
                            onPressed: () => setModal(() =>
                                ingredientRows
                                    .add({'name': '', 'qty': '', 'unit': 'kg'})),
                            icon: const Icon(Icons.add_rounded, size: 16),
                            label: const Text('Add Row'),
                            style: TextButton.styleFrom(
                                foregroundColor: kWarning),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      ...ingredientRows.asMap().entries.map((entry) {
                        final idx = entry.key;
                        final row = entry.value;
                        final selectedNames = ingredientRows
                            .asMap()
                            .entries
                            .where((e) => e.key != idx)
                            .map((e) => (e.value['name'] as String).toLowerCase())
                            .toSet();

                        return _IngredientRow(
                          key: ValueKey('ing_$idx'),
                          row: row,
                          allStockItems: allStockItems,
                          savedStockItems: savedStockItems,
                          stockLoaded: stockLoaded,
                          selectedNames: selectedNames,
                          showRemove: ingredientRows.length > 1,
                          onChanged: (updated) =>
                              setModal(() => ingredientRows[idx] = updated),
                          onRemove: () =>
                              setModal(() => ingredientRows.removeAt(idx)),
                        );
                      }),
                    ],

                    const SizedBox(height: 20),

                    // ── Quantities ───────────────────────────────────────
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: typeColor.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: typeColor.withValues(alpha: 0.2)),
                      ),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Row(children: [
                          Icon(Icons.monitor_weight_outlined,
                              color: typeColor, size: 18),
                          const SizedBox(width: 8),
                          Text('QUANTITIES',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w900,
                                  color: typeColor,
                                  letterSpacing: 1.0)),
                        ]),
                        const SizedBox(height: 4),

                        // ── Cooked food rule hint ──────────────────────
                        if (!isReceived)
                          Container(
                            margin: const EdgeInsets.symmetric(vertical: 8),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: typeColor.withValues(alpha: 0.07),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                  color: typeColor.withValues(alpha: 0.25)),
                            ),
                            child: Row(children: [
                              Icon(Icons.info_outline_rounded,
                                  color: typeColor, size: 15),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Saved + Wasted cannot exceed Used (total food output).',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: typeColor,
                                      fontWeight: FontWeight.w600),
                                ),
                              ),
                            ]),
                          ),

                        Container(
                          margin: const EdgeInsets.symmetric(vertical: 8),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: kSuccess.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color: kSuccess.withValues(alpha: 0.25)),
                          ),
                          child: Row(children: [
                            const Icon(Icons.confirmation_number_rounded,
                                color: kSuccess, size: 15),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '"Served" is tracked automatically from tokens — no need to enter it here.',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: ctx.adapt(kTextMid),
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                          ]),
                        ),
                        if (!isEdit)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Row(children: [
                              Icon(Icons.info_outline_rounded,
                                  color: typeColor, size: 14),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'You can leave these blank and fill them later via Edit.',
                                  style: TextStyle(
                                      fontSize: 11, color: ctx.adapt(kTextMid)),
                                ),
                              ),
                            ]),
                          ),
                        Row(children: [
                          Expanded(
                              child: _numField(usedCtrl, 'Used (kg)',
                                  Icons.whatshot_rounded, typeColor)),
                          const SizedBox(width: 10),
                          Expanded(
                              child: _numField(savedCtrl, 'Saved (kg)',
                                  Icons.save_rounded, kInfo)),
                        ]),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: MediaQuery.of(ctx).size.width * 0.45,
                          child: _numField(wastedCtrl, 'Wasted (kg)',
                              Icons.delete_outline_rounded, kAccent),
                        ),
                        if (isEdit)
                          Container(
                            margin: const EdgeInsets.only(top: 10),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: kInfo.withValues(alpha: 0.06),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                  color: kInfo.withValues(alpha: 0.2)),
                            ),
                            child: Row(children: [
                              const Icon(Icons.schedule_rounded,
                                  color: kInfo, size: 16),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Saved kg carries over to tomorrow\'s inventory automatically.',
                                  style: TextStyle(
                                      fontSize: 12, color: ctx.adapt(kTextMid)),
                                ),
                              ),
                            ]),
                          ),
                      ]),
                    ),

                    const SizedBox(height: 16),

                    // ── Notes ────────────────────────────────────────────
                    kLabel('NOTES (OPTIONAL)', ctx),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: notesCtrl,
                      maxLines: 2,
                      decoration:
                          kInputDeco('Any observations…', Icons.notes_rounded, ctx),
                    ),
                    const SizedBox(height: 24),

                    // ── Submit ───────────────────────────────────────────
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: typeColor,
                          foregroundColor: SoftPalette.gray50,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
                          elevation: 0,
                        ),
                        onPressed: () async {
                          if (!formKey.currentState!.validate()) return;
                          final dish     = dishCtrl.text.trim();
                          final usedKg   = double.tryParse(usedCtrl.text)   ?? 0;
                          final savedKg  = double.tryParse(savedCtrl.text)  ?? 0;
                          final wastedKg = double.tryParse(wastedCtrl.text) ?? 0;

                          // ── VALIDATION: for cooked food saved+wasted ≤ used ──
                          if (!isReceived && usedKg > 0) {
                            if ((savedKg + wastedKg) > usedKg) {
                              AppToast.showSnackBar(ctx, 
                                SnackBar(
                                  content: Text(
                                    'Saved (${savedKg.toStringAsFixed(2)} kg) + '
                                    'Wasted (${wastedKg.toStringAsFixed(2)} kg) = '
                                    '${(savedKg + wastedKg).toStringAsFixed(2)} kg — '
                                    'cannot exceed Used (${usedKg.toStringAsFixed(2)} kg).',
                                  ),
                                  backgroundColor: kAccent,
                                  behavior: SnackBarBehavior.floating,
                                  margin: const EdgeInsets.all(16),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12)),
                                ),
                              );
                              return;
                            }
                          }

                          final List<Map<String, dynamic>> cleanIngredients =
                              isReceived
                                  ? []
                                  : ingredientRows
                                      .where((r) {
                                        final name =
                                            (r['name'] as String).trim();
                                        final qty = double.tryParse(
                                            r['qty'].toString());
                                        return name.isNotEmpty &&
                                            qty != null &&
                                            qty > 0;
                                      })
                                      .map((r) => {
                                            'name': r['name'],
                                            'qty': double.parse(
                                                r['qty'].toString()),
                                            'unit': r['unit'],
                                          })
                                      .toList();

                          if (!isReceived) {
                            for (final ing in cleanIngredients) {
                              final stockItem = allStockItems.firstWhere(
                                (s) => s.name == ing['name'],
                                orElse: () => StockItem(
                                  id: '',
                                  name: ing['name'] as String,
                                  quantity: double.infinity,
                                  unit: 'kg',
                                  lastUpdated: Timestamp.now(),
                                ),
                              );
                              double availableQty = stockItem.quantity;
                              if (isEdit &&
                                  !(existing['isReceivedFood'] as bool? ?? false)) {
                                final oldIng =
                                    (existing['ingredients'] as List<dynamic>? ?? [])
                                        .map((e) => Map<String, dynamic>.from(e as Map))
                                        .firstWhere(
                                      (e) => e['name'] == ing['name'],
                                      orElse: () => {},
                                    );
                                if (oldIng.isNotEmpty) {
                                  availableQty +=
                                      (oldIng['qty'] as num? ?? 0).toDouble();
                                }
                              }
                              if ((ing['qty'] as double) > availableQty) {
                                AppToast.showSnackBar(ctx, 
                                  SnackBar(
                                    content: Text(
                                        'Not enough ${ing['name']} in stock. Available: $availableQty ${stockItem.unit}'),
                                    backgroundColor: kAccent,
                                    behavior: SnackBarBehavior.floating,
                                    margin: const EdgeInsets.all(16),
                                    shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12)),
                                  ),
                                );
                                return;
                              }
                            }
                          }

                          final data = {
                            'dish':             dish,
                            'isReceivedFood':   isReceived,
                            'isSavedFood':      false,
                            'source':           sourceCtrl.text.trim(),
                            'usedKg':           usedKg,
                            'savedKg':          savedKg,
                            'wastedKg':         wastedKg,
                            'cookedKg':         usedKg,
                            'distributedKg':    0.0,
                            'ingredients':      cleanIngredients,
                            'notes':            notesCtrl.text.trim(),
                            'createdAt':        FieldValue.serverTimestamp(),
                            'savedCarriedOver': false,
                          };

                          final fs       = FirebaseFirestore.instance;
                          final dayDoc   = fs
                              .collection('branches').doc(branchId)
                              .collection('dasterkhwaan').doc(today);
                          final cookCol  = dayDoc.collection('cooking_sessions');
                          final batch    = CloudDb.instance.batch();

                          if (isEdit) {
                            if (!(existing['isReceivedFood'] as bool? ?? false)) {
                              final oldIngredients =
                                  List<Map<String, dynamic>>.from(
                                      (existing['ingredients'] as List<dynamic>? ?? [])
                                          .map((e) => Map<String, dynamic>.from(e as Map)));
                              for (final ing in oldIngredients) {
                                batch.update(
                                  fs
                                      .collection('branches').doc(branchId)
                                      .collection('dasterkhwaan_stock')
                                      .doc(ing['name'] as String),
                                  {
                                    'quantity': FieldValue.increment(
                                        (ing['qty'] as num).toDouble()),
                                    'lastUpdated': FieldValue.serverTimestamp(),
                                  },
                                );
                              }
                            }
                            batch.update(cookCol.doc(docId), data);
                          } else {
                            batch.set(cookCol.doc(), data);
                          }

                          if (!isReceived) {
                            for (final ing in cleanIngredients) {
                              final stockRef = fs
                                  .collection('branches').doc(branchId)
                                  .collection('dasterkhwaan_stock')
                                  .doc(ing['name'] as String);
                              final snap = await stockRef.get().timeout(
                                  const Duration(seconds: 8),
                                  onTimeout: () => stockRef.get(const GetOptions(source: Source.cache)));
                              if (snap.exists) {
                                batch.update(stockRef, {
                                  'quantity': FieldValue.increment(
                                      -(ing['qty'] as num).toDouble()),
                                  'lastUpdated': FieldValue.serverTimestamp(),
                                });
                              } else {
                                // Merge + increment: if the 8 s read missed a document that
                                // does exist, this still deducts instead of overwriting it.
                                // StockFloor below keeps a missing item at 0, not negative.
                                batch.set(stockRef, {
                                  'name':     ing['name'],
                                  'quantity': FieldValue.increment(
                                      -(ing['qty'] as num).toDouble()),
                                  'unit':     ing['unit'],
                                  'lastUpdated': FieldValue.serverTimestamp(),
                                }, SetOptions(merge: true));
                              }
                            }
                          }

                          if (!await commitKitchenBatch(ctx, batch)) return;
                          if (!isReceived) {
                            // Stock cannot go below 0: floor every deducted ingredient.
                            unawaited(StockFloor.repairAll(cleanIngredients.map((ing) => fs
                                .collection('branches').doc(branchId)
                                .collection('dasterkhwaan_stock')
                                .doc(ing['name'] as String)
                                .path)));
                          }
                          await onDone();
                          if (ctx.mounted) Navigator.pop(ctx);

                          AppToast.showSnackBar(ctx, SnackBar(
                            content: Text(isEdit
                                ? '$dish updated'
                                : isReceived
                                    ? '$dish received — logged (no stock deducted)'
                                    : '$dish started — stock deducted'),
                            backgroundColor: kSuccess,
                            behavior: SnackBarBehavior.floating,
                            margin: const EdgeInsets.all(16),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ));
                        },
                        child: Text(
                          isEdit
                              ? 'Update Entry'
                              : isReceived
                                  ? 'Log Received Food'
                                  : 'Start Cooking & Deduct Stock',
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ]),
        ),
      ),
    ),
  );
}

// ════════════════════════════════════════════════════════════════════════════
// INGREDIENT ROW WIDGET
// ════════════════════════════════════════════════════════════════════════════

class _IngredientRow extends StatefulWidget {
  final Map<String, dynamic> row;
  final List<StockItem> allStockItems;
  final List<StockItem> savedStockItems;
  final bool stockLoaded;
  final Set<String> selectedNames;
  final bool showRemove;
  final ValueChanged<Map<String, dynamic>> onChanged;
  final VoidCallback onRemove;

  const _IngredientRow({
    super.key,
    required this.row,
    required this.allStockItems,
    required this.savedStockItems,
    required this.stockLoaded,
    required this.selectedNames,
    required this.showRemove,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  State<_IngredientRow> createState() => _IngredientRowState();
}

class _IngredientRowState extends State<_IngredientRow> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _qtyCtrl;
  String _unit          = 'kg';
  String _selectedName  = '';
  double _maxQty        = double.infinity;

  @override
  void initState() {
    super.initState();
    _selectedName = widget.row['name'] as String? ?? '';
    _nameCtrl     = TextEditingController(text: _selectedName);
    _qtyCtrl      = TextEditingController(
        text: widget.row['qty']?.toString() ?? '');
    _unit         = widget.row['unit'] as String? ?? 'kg';
    _updateMaxQty(_selectedName);
  }

  void _updateMaxQty(String name) {
    _stockUnit = null;
    if (name.isEmpty) { _maxQty = double.infinity; return; }
    try {
      final item = widget.allStockItems.firstWhere(
          (s) => s.name.toLowerCase() == name.toLowerCase());
      _maxQty = item.quantity;
      // The amount is deducted from this stock item as typed, so it must be in the item's
      // own unit ("500 gram" against rice kept in kg used to deduct 500 kg).
      _stockUnit = item.unit;
      _unit = item.unit;
    } catch (_) {
      _maxQty = double.infinity;
    }
  }

  /// Unit of the selected stock item; while set, the unit dropdown is locked to it.
  String? _stockUnit;

  void _notify() {
    widget.onChanged({'name': _selectedName, 'qty': _qtyCtrl.text, 'unit': _unit});
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _qtyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stockItem = widget.allStockItems.where(
        (s) => s.name.toLowerCase() == _selectedName.toLowerCase()).firstOrNull;
    final hasItem    = stockItem != null;
    final stockQty   = hasItem ? stockItem.quantity : 0.0;
    final stockUnit  = hasItem ? stockItem.unit : '';
    final outOfStock = hasItem && stockQty <= 0;
    final lowStock   = hasItem && stockQty > 0 && stockQty <= 2;
    final isSavedIng = _selectedName.startsWith('Saved:');
    final Color stockColor = outOfStock
        ? kAccent
        : isSavedIng
            ? kTeal
            : lowStock
                ? kWarning
                : kSuccess;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            flex: 3,
            child: widget.stockLoaded
                ? Autocomplete<String>(
                    initialValue: TextEditingValue(text: _selectedName),
                    optionsBuilder: (v) {
                      final q = v.text.toLowerCase();
                      Iterable<StockItem> pool;
                      if (q.isEmpty) {
                        pool = [
                          ...widget.savedStockItems,
                          ...widget.allStockItems
                              .where((i) => !i.name.startsWith('Saved:')),
                        ];
                      } else {
                        pool = [
                          ...widget.savedStockItems
                              .where((i) => i.name.toLowerCase().contains(q)),
                          ...widget.allStockItems
                              .where((i) =>
                                  !i.name.startsWith('Saved:') &&
                                  i.name.toLowerCase().contains(q)),
                        ];
                      }
                      return pool
                          .where((i) => !widget.selectedNames
                              .contains(i.name.toLowerCase()))
                          .map((i) => i.name)
                          .take(10);
                    },
                    optionsViewBuilder: (ctx2, onSel, opts) => Align(
                      alignment: Alignment.topLeft,
                      child: Material(
                        elevation: 8,
                        borderRadius: BorderRadius.circular(12),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                              maxHeight: 260, maxWidth: 260),
                          child: ListView.builder(
                            padding: EdgeInsets.zero,
                            shrinkWrap: true,
                            itemCount: opts.length,
                            itemBuilder: (_, i) {
                              final opt     = opts.elementAt(i);
                              final isSaved = opt.startsWith('Saved:');
                              final item    = widget.allStockItems.firstWhere(
                                (s) => s.name == opt,
                                orElse: () => StockItem(
                                    id: '', name: opt, quantity: 0,
                                    unit: 'kg', lastUpdated: Timestamp.now()),
                              );
                              final sColor = item.quantity <= 0
                                  ? kAccent
                                  : isSaved
                                      ? kTeal
                                      : item.quantity <= 2
                                          ? kWarning
                                          : kSuccess;
                              return ListTile(
                                dense: true,
                                enabled: item.quantity > 0,
                                tileColor: isSaved
                                    ? kTeal.withValues(alpha: 0.05)
                                    : null,
                                leading: isSaved
                                    ? const Icon(Icons.recycling_rounded,
                                        size: 16, color: kTeal)
                                    : null,
                                title: Text(
                                  isSaved
                                      ? opt.replaceFirst('Saved: ', '')
                                      : opt,
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: isSaved ? kTeal : ctx2.adapt(kTextDark)),
                                ),
                                subtitle: Text(
                                  item.quantity <= 0
                                      ? 'Out of stock'
                                      : isSaved
                                          ? '${item.quantity} ${item.unit} carry-over'
                                          : '${item.quantity} ${item.unit} available',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: sColor,
                                      fontWeight: FontWeight.w600),
                                ),
                                trailing: Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                      color: sColor, shape: BoxShape.circle),
                                ),
                                onTap: item.quantity <= 0 ? null : () => onSel(opt),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                    fieldViewBuilder: (ctx2, ctrl, focus, _) => TextFormField(
                      controller: ctrl,
                      focusNode: focus,
                      decoration:
                          kInputDeco('Search stock…', Icons.search_rounded, ctx2),
                      onChanged: (v) {
                        setState(() {
                          _selectedName = v;
                          _updateMaxQty(v);
                        });
                        _notify();
                      },
                    ),
                    onSelected: (s) {
                      setState(() {
                        _selectedName = s;
                        _updateMaxQty(s);
                        final si = widget.allStockItems.firstWhere(
                          (i) => i.name == s,
                          orElse: () => StockItem(
                              id: '', name: s, quantity: 0,
                              unit: 'kg', lastUpdated: Timestamp.now()),
                        );
                        _unit = si.unit;
                      });
                      _notify();
                    },
                  )
                : TextFormField(
                    controller: _nameCtrl,
                    decoration:
                        kInputDeco('Item', Icons.inventory_2_outlined, context),
                    onChanged: (v) {
                      _selectedName = v;
                      _notify();
                    },
                  ),
          ),
          const SizedBox(width: 8),

          Expanded(
            flex: 2,
            child: TextFormField(
              controller: _qtyCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: kInputDeco('Qty', Icons.scale_rounded, context).copyWith(
                errorStyle: const TextStyle(fontSize: 9, height: 0.8),
              ),
              validator: (v) {
                final qty = double.tryParse(v ?? '');
                if (qty == null || qty <= 0) return 'Must be > 0';
                if (_maxQty != double.infinity && qty > _maxQty) {
                  return 'Max: $_maxQty';
                }
                return null;
              },
              onChanged: (v) {
                _notify();
                final qty = double.tryParse(v);
                if (qty != null && _maxQty != double.infinity && qty > _maxQty) {
                  _qtyCtrl.text = _maxQty.toString();
                  _qtyCtrl.selection = TextSelection.fromPosition(
                      TextPosition(offset: _qtyCtrl.text.length));
                  _notify();
                }
              },
            ),
          ),
          const SizedBox(width: 6),

          SizedBox(
            width: 68,
            child: DropdownButtonFormField<String>(
              // Rebuilt when the unit changes (initialValue is only read once).
              key: ValueKey('unit_${_stockUnit ?? ''}_$_unit'),
              initialValue: _unit,
              isDense: true,
              decoration: kInputDeco('', Icons.straighten, context).copyWith(
                prefixIcon: null,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              ),
              items: <String>{'kg', 'gram', 'liter', 'piece', 'packet', _unit}
                  .map((u) => DropdownMenuItem(
                      value: u,
                      child: Text(u, style: const TextStyle(fontSize: 12))))
                  .toList(),
              // Locked to the stock item's unit once an item from stock is chosen.
              onChanged: _stockUnit != null
                  ? null
                  : (v) {
                      setState(() => _unit = v!);
                      _notify();
                    },
            ),
          ),
          const SizedBox(width: 4),

          if (widget.showRemove)
            IconButton(
              icon: const Icon(Icons.remove_circle_outline_rounded,
                  color: kAccent, size: 20),
              onPressed: widget.onRemove,
            ),
        ]),

        if (hasItem)
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 4),
            child: Row(children: [
              Container(
                width: 7, height: 7,
                decoration: BoxDecoration(color: stockColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 5),
              Text(
                outOfStock
                    ? 'Out of stock — cannot use'
                    : isSavedIng
                        ? 'Carry-over: $stockQty $stockUnit available'
                        : 'Available: $stockQty $stockUnit',
                style: TextStyle(
                    fontSize: 10,
                    color: stockColor,
                    fontWeight: FontWeight.w700),
              ),
            ]),
          ),
      ]),
    );
  }
}

// ── Number field helper ───────────────────────────────────────────────────────

Widget _numField(
        TextEditingController ctrl, String label, IconData icon, Color color) =>
    TextFormField(
      controller: ctrl,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: color, size: 18),
        filled: true,
        fillColor: color.withValues(alpha: 0.06),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: color, width: 1.5)),
        contentPadding:
            const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        labelStyle: TextStyle(color: color, fontSize: 12),
      ),
      validator: (v) {
        if (v == null || v.isEmpty) return null;
        final d = double.tryParse(v);
        if (d == null || d < 0) return 'Must be ≥ 0';
        return null;
      },
    );
