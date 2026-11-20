// lib/pages/dispensary/doctor/template_screen.dart
import 'package:flutter/material.dart';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:gmwf/design/tokens/comfort_colors.dart';
import 'package:gmwf/design/components/app_toast.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/master_proforma_service.dart';
import 'package:gmwf/services/stock/stock_pool.dart';
import 'package:gmwf/services/stock/stock_reader.dart';

/// Doctor Prescription Templates & Disease Presets Manager.
class TemplateScreen extends StatefulWidget {
  final String branchId;
  final String doctorName;

  const TemplateScreen({
    super.key,
    this.branchId = 'main_branch',
    this.doctorName = 'Doctor',
  });

  @override
  State<TemplateScreen> createState() => _TemplateScreenState();
}

class _TemplateScreenState extends State<TemplateScreen> {
  Color get _teal => context.comfort.brand;
  Color get _tealLight => context.comfort.brandSoft;

  // Form State
  final TextEditingController _complaintCtrl = TextEditingController();
  final TextEditingController _diagnosisCtrl = TextEditingController();
  int _daysOfMedicine = 1;

  List<Map<String, dynamic>> _prescriptions = [];
  List<Map<String, dynamic>> _labResults = [];

  // Live Inventory
  List<Map<String, dynamic>> _inventory = [];
  bool _isLoadingInventory = true;

  // Active Template Library
  late List<Map<String, dynamic>> _templates;

  @override
  void initState() {
    super.initState();
    _initTemplates();
    _loadDispensaryInventory();
  }

  void _initTemplates() {
    _templates = [
      {
        'id': 'tpl_flu',
        'name': 'Viral Flu / URTI',
        'category': 'General',
        'icon': FontAwesomeIcons.headSideCough,
        'color': SoftPalette.teal500,
        'complaint': 'Fever, sore throat, running nose and body aches for 2 days.',
        'diagnosis': 'Acute Viral Upper Respiratory Tract Infection (URTI)',
        'defaultDays': 1,
        'medicines': [
          {
            'name': 'Paracetamol 500mg',
            'type': 'Tablet',
            'dose': '1+1+1',
            'frequency': 'TDS (8 Hourly)',
            'instructions': 'After meals',
            'quantity': 3,
            'duration': '3 Days',
          },
          {
            'name': 'Chlorpheniramine 4mg (Piriton)',
            'type': 'Tablet',
            'dose': '0+0+1',
            'frequency': 'OD (Bedtime)',
            'instructions': 'At night',
            'quantity': 1,
            'duration': '3 Days',
          },
          {
            'name': 'Syp. Mucaine / Antacid',
            'type': 'Syrup',
            'dose': '2 tsp TDS',
            'frequency': 'TDS (8 Hourly)',
            'instructions': 'Before meals',
            'quantity': 1,
            'duration': '3 Days',
          },
        ],
        'labResults': [
          {'name': 'CBC (Complete Blood Count)'}
        ],
      },
      {
        'id': 'tpl_gastro',
        'name': 'Acute Gastroenteritis',
        'category': 'Gastro',
        'icon': FontAwesomeIcons.bacteria,
        'color': SoftPalette.orange350,
        'complaint': 'Watery diarrhea, vomiting, and abdominal cramps since morning.',
        'diagnosis': 'Acute Gastroenteritis with mild dehydration',
        'defaultDays': 1,
        'medicines': [
          {
            'name': 'Cap. Ciprofloxacin 500mg',
            'type': 'Capsule',
            'dose': '1+0+1',
            'frequency': 'BD (12 Hourly)',
            'instructions': 'After food',
            'quantity': 2,
            'duration': '3 Days',
          },
          {
            'name': 'Tab. Flagyl 400mg',
            'type': 'Tablet',
            'dose': '1+1+1',
            'frequency': 'TDS (8 Hourly)',
            'instructions': 'With food',
            'quantity': 3,
            'duration': '3 Days',
          },
          {
            'name': 'Syp. ORS Powder / Electrolyte',
            'type': 'Syrup',
            'dose': '1 sachet in 1L water SOS',
            'frequency': 'SOS (As needed)',
            'instructions': 'Drink frequently',
            'quantity': 2,
            'duration': '3 Days',
          },
        ],
        'labResults': [
          {'name': 'Urine R/E'},
          {'name': 'Stool Examination'}
        ],
      },
      {
        'id': 'tpl_tonsillitis',
        'name': 'Acute Tonsillitis',
        'category': 'ENT',
        'icon': FontAwesomeIcons.temperatureHigh,
        'color': SoftPalette.purple550,
        'complaint': 'Severe throat pain, difficulty swallowing, high fever.',
        'diagnosis': 'Acute Follicular Tonsillitis',
        'defaultDays': 1,
        'medicines': [
          {
            'name': 'Tab. Augmentin 625mg',
            'type': 'Tablet',
            'dose': '1+0+1',
            'frequency': 'BD (12 Hourly)',
            'instructions': 'Start of meal',
            'quantity': 2,
            'duration': '5 Days',
          },
          {
            'name': 'Tab. Brufen 400mg',
            'type': 'Tablet',
            'dose': '1+0+1',
            'frequency': 'BD (12 Hourly)',
            'instructions': 'After meals',
            'quantity': 2,
            'duration': '3 Days',
          },
        ],
        'labResults': [],
      },
      {
        'id': 'tpl_hypertension',
        'name': 'Hypertension Review',
        'category': 'Cardio',
        'icon': FontAwesomeIcons.heartPulse,
        'color': SoftPalette.slate500,
        'complaint': 'Routine monthly follow-up for high blood pressure. Mild morning headache.',
        'diagnosis': 'Essential Hypertension (Stage 1 / Controlled)',
        'defaultDays': 3,
        'medicines': [
          {
            'name': 'Tab. Amlodipine 5mg',
            'type': 'Tablet',
            'dose': '0+1+0',
            'frequency': 'OD (Morning)',
            'instructions': 'Morning before breakfast',
            'quantity': 1,
            'duration': '30 Days',
          },
          {
            'name': 'Tab. Disprin / Lowplat 75mg',
            'type': 'Tablet',
            'dose': '0+0+1',
            'frequency': 'OD (Night)',
            'instructions': 'After dinner',
            'quantity': 1,
            'duration': '30 Days',
          },
        ],
        'labResults': [
          {'name': 'Lipid Profile'},
          {'name': 'RFT (Renal Function Test)'},
          {'name': 'ECG'}
        ],
      },
    ];
  }

  Future<void> _loadDispensaryInventory() async {
    setState(() => _isLoadingInventory = true);
    final List<Map<String, dynamic>> items = [];

    // This PC's stock pool from the stock book (all batches of a medicine added together,
    // other patients' reservations taken off). No made-up stock: an empty pool stays empty.
    try {
      await LocalStorageService.ensureBoxOpen(LocalStorageService.stockBox);
      await LocalStorageService.ensureBoxOpen(LocalStorageService.prescriptionsBox);
      await LocalStorageService.ensureBoxOpen(LocalStorageService.entriesBox);
      final pool = StockPool.current(widget.branchId);
      if (pool != null) {
        for (final g in StockReader.groups(pool)) {
          if (g.batches.isEmpty) continue;
          final item = Map<String, dynamic>.from(g.primary);
          final isCustom = item['isCustomized'] == true || item['userEdited'] == true;
          if (!isCustom) {
            final rawName = (item['name'] ?? '').toString();
            item['name'] = MasterProformaService.cleanBrandToFormula(rawName);
          }
          item['quantity'] = g.available.floor();
          items.add(item);
        }
      }
    } catch (_) {}

    if (mounted) {
      setState(() {
        _inventory = items;
        _isLoadingInventory = false;
      });
    }
  }

  int _getStockForMedicine(String medName) {
    final clean = medName.toLowerCase().trim();
    if (clean.isEmpty) return 0;
    final item = _inventory.firstWhere(
      (m) {
        final name = (m['name'] ?? '').toString().toLowerCase().trim();
        final form = (m['formula'] ?? '').toString().toLowerCase().trim();
        if (name.isEmpty) return false;
        return name.contains(clean) || clean.contains(name) || (form.isNotEmpty && clean.contains(form));
      },
      orElse: () => {},
    );
    // Not in this pool's stock: none available (never an invented figure).
    if (item.isEmpty) return 0;
    final q = item['quantity'] ?? item['stock'] ?? 0;
    return q is num ? q.toInt() : int.tryParse(q.toString()) ?? 0;
  }

  void _applyTemplate(Map<String, dynamic> template) {
    final medsToApply = (template['medicines'] as List<dynamic>?)?.map((e) => Map<String, dynamic>.from(e as Map)).toList() ?? [];
    setState(() {
      _complaintCtrl.text = template['complaint'] ?? '';
      _diagnosisCtrl.text = template['diagnosis'] ?? '';
      _daysOfMedicine = template['defaultDays'] ?? 1;
      _prescriptions = medsToApply;
      _labResults = (template['labResults'] as List<dynamic>?)?.map((e) => Map<String, dynamic>.from(e as Map)).toList() ?? [];
    });
    AppToast.showSnackBar(context, 
      SnackBar(
        content: Text('⚡ Template "${template['name']}" applied!'),
        backgroundColor: SoftPalette.teal600,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showSaveAsTemplateDialog() {
    if (_complaintCtrl.text.isEmpty && _diagnosisCtrl.text.isEmpty && _prescriptions.isEmpty) {
      AppToast.showSnackBar(context, 
        const SnackBar(content: Text('Please fill diagnosis or medicines first to save as template!'), backgroundColor: SoftPalette.amber300),
      );
      return;
    }

    final titleCtrl = TextEditingController(text: _diagnosisCtrl.text.isNotEmpty ? _diagnosisCtrl.text : 'Custom Preset');
    String selectedCategory = 'General';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Icon(Icons.bookmark_add_rounded, color: context.adapt(_teal), size: 24),
              SizedBox(width: 8),
              Text('Save As Reusable Template', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ],
          ),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Template Name / Title:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.adapt(SoftPalette.gray350))),
                const SizedBox(height: 6),
                TextField(
                  controller: titleCtrl,
                  decoration: InputDecoration(
                    hintText: 'e.g. Typhoid Fever Protocol',
                    filled: true,
                    fillColor: context.adapt(SoftPalette.gray50),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 14),
                Text('Category:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.adapt(SoftPalette.gray350))),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  value: selectedCategory,
                  items: ['General', 'Respiratory', 'Gastro', 'Cardio', 'Pediatric', 'ENT', 'Ortho']
                      .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                      .toList(),
                  onChanged: (v) => setDlgState(() => selectedCategory = v ?? 'General'),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: context.adapt(SoftPalette.gray50),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: context.adapt(_tealLight),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Includes: ${_prescriptions.length} Medicine(s) • ${_labResults.length} Lab Test(s) • Day: $_daysOfMedicine',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: context.adapt(_teal)),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: _teal, foregroundColor: SoftPalette.gray50),
              onPressed: () {
                final newTpl = {
                  'id': 'tpl_${DateTime.now().millisecondsSinceEpoch}',
                  'name': titleCtrl.text.trim(),
                  'category': selectedCategory,
                  'icon': Icons.medical_services,
                  'color': SoftPalette.teal550,
                  'complaint': _complaintCtrl.text.trim(),
                  'diagnosis': _diagnosisCtrl.text.trim(),
                  'defaultDays': _daysOfMedicine,
                  'medicines': List<Map<String, dynamic>>.from(_prescriptions),
                  'labResults': List<Map<String, dynamic>>.from(_labResults),
                };

                setState(() {
                  _templates.insert(0, newTpl);
                });
                Navigator.pop(ctx);
                AppToast.showSnackBar(context, 
                  SnackBar(content: Text('⭐ Saved "${newTpl['name']}" template!'), backgroundColor: SoftPalette.teal600),
                );
              },
              child: const Text('Save Template'),
            ),
          ],
        ),
      ),
    );
  }

  void _clearForm() {
    setState(() {
      _complaintCtrl.clear();
      _diagnosisCtrl.clear();
      _prescriptions.clear();
      _labResults.clear();
      _daysOfMedicine = 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.adapt(SoftPalette.slate100),
      appBar: AppBar(
        backgroundColor: _teal,
        foregroundColor: SoftPalette.gray50,
        elevation: 2,
        title: const Row(
          children: [
            Icon(Icons.bookmarks_rounded, color: SoftPalette.gray50, size: 22),
            SizedBox(width: 8),
            Text(
              'Doctor Prescription Templates',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: _clearForm,
            icon: const Icon(Icons.refresh, color: SoftPalette.gray50, size: 16),
            label: const Text('Reset Form', style: TextStyle(color: SoftPalette.gray50, fontSize: 12)),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Templates Quick Bar ──
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [context.adapt(SoftPalette.teal100m), context.adapt(SoftPalette.gray50)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: context.adapt(SoftPalette.teal300)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.bolt, color: SoftPalette.amber200, size: 20),
                      const SizedBox(width: 6),
                      Text(
                        'Disease Presets & Prescription Templates',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: context.adapt(_teal)),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: _showSaveAsTemplateDialog,
                        icon: Icon(Icons.bookmark_add, size: 15, color: context.adapt(_teal)),
                        label: Text('Save Current as Template', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: context.adapt(_teal))),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _templates.map((tpl) {
                      return ActionChip(
                        avatar: Icon(tpl['icon'] as IconData? ?? Icons.medical_services, size: 14, color: SoftPalette.gray50),
                        label: Text(tpl['name'], style: const TextStyle(color: SoftPalette.gray50, fontSize: 12, fontWeight: FontWeight.w600)),
                        backgroundColor: tpl['color'] as Color? ?? _teal,
                        elevation: 2,
                        pressElevation: 4,
                        onPressed: () => _applyTemplate(tpl),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),

            // Complaint
            Text('Patient Condition / Complaints', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5, color: context.adapt(_teal))),
            const SizedBox(height: 6),
            TextField(
              controller: _complaintCtrl,
              maxLines: 2,
              decoration: InputDecoration(
                hintText: 'e.g. High grade fever, vomiting...',
                filled: true,
                fillColor: context.adapt(SoftPalette.gray50),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 14),

            // Diagnosis
            Text('Diagnosis', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5, color: context.adapt(_teal))),
            const SizedBox(height: 6),
            TextField(
              controller: _diagnosisCtrl,
              maxLines: 2,
              decoration: InputDecoration(
                hintText: 'e.g. Acute Viral Gastroenteritis',
                filled: true,
                fillColor: context.adapt(SoftPalette.gray50),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 16),

            // Prescribed Medicines
            Row(
              children: [
                FaIcon(FontAwesomeIcons.pills, color: context.adapt(_teal), size: 16),
                const SizedBox(width: 8),
                Text('Prescribed Medicines (${_prescriptions.length})',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5, color: context.adapt(_teal))),
                const Spacer(),
                if (_prescriptions.isNotEmpty)
                  TextButton(
                    onPressed: () => setState(() => _prescriptions.clear()),
                    child: Text('Clear All', style: TextStyle(color: context.adapt(SoftPalette.red400), fontSize: 11)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (_prescriptions.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: context.adapt(SoftPalette.gray50),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: context.adapt(SoftPalette.gray100)),
                ),
                child: Center(
                  child: Text(
                    '⚡ Click any Template above to auto-fill prescription medicines and diagnosis',
                    style: TextStyle(color: context.adapt(SoftPalette.gray350), fontSize: 13),
                  ),
                ),
              )
            else
              ..._prescriptions.map((m) {
                final stock = _getStockForMedicine((m['name'] ?? '').toString());
                final isOutOfStock = stock <= 0;
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: context.adapt(isOutOfStock ? SoftPalette.gray100 : SoftPalette.gray50),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: context.adapt(isOutOfStock ? SoftPalette.red300 : SoftPalette.gray150)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: context.adapt(_tealLight),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: FaIcon(FontAwesomeIcons.capsules, color: context.adapt(_teal), size: 16),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    (m['name'] ?? '').toString(),
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13.5,
                                      color: isOutOfStock ? context.adapt(SoftPalette.gray550) : null,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                // Stock of this dispensary: out-of-stock lines are flagged,
                                // they are never given an invented quantity.
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                  decoration: BoxDecoration(
                                    color: context.adapt(isOutOfStock ? SoftPalette.pink100m : SoftPalette.green100m),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    isOutOfStock ? 'Out of stock' : 'Stock: $stock',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.bold,
                                      color: context.adapt(isOutOfStock ? SoftPalette.red550 : SoftPalette.green550),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Dose: ${m['dose']} • Freq: ${m['frequency']} • Duration: ${m['duration']} • ${m['instructions']}',
                              style: TextStyle(fontSize: 11.5, color: context.adapt(SoftPalette.gray550)),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.delete_outline, color: context.adapt(SoftPalette.red400), size: 18),
                        onPressed: () => setState(() => _prescriptions.remove(m)),
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}
