// lib/pages/dispensary/doctor/template_screen.dart
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/master_proforma_service.dart';

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
  static const Color _teal = Color(0xFF00695C);
  static const Color _tealLight = Color(0xFFE0F2F1);

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
        'color': Colors.teal,
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
        'color': Colors.amber.shade800,
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
        'color': Colors.purple,
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
        'color': Colors.blueGrey,
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

    try {
      final stockBox = await LocalStorageService.ensureBoxOpen(LocalStorageService.stockBox);
      final localStock = stockBox.values.whereType<Map>();
        for (final s in localStock) {
          final item = Map<String, dynamic>.from(s);
          final isCustom = item['isCustomized'] == true || item['userEdited'] == true;
          if (!isCustom) {
            final rawName = (item['name'] ?? '').toString();
            item['name'] = MasterProformaService.cleanBrandToFormula(rawName);
          }
          item['quantity'] = item['quantity'] ?? item['stock'] ?? 0;
          items.add(item);
        }
    } catch (_) {}

    if (items.isEmpty || items.length < 5) {
      items.addAll([
        {'id': 'inv_1', 'name': 'Paracetamol 500mg', 'type': 'Tablet', 'quantity': 140, 'formula': 'Acetaminophen'},
        {'id': 'inv_2', 'name': 'Chlorpheniramine 4mg (Piriton)', 'type': 'Tablet', 'quantity': 85, 'formula': 'Chlorpheniramine Maleate'},
        {'id': 'inv_3', 'name': 'Syp. Mucaine / Antacid', 'type': 'Syrup', 'quantity': 32, 'formula': 'Oxetacaine + Aluminium Hydroxide'},
        {'id': 'inv_4', 'name': 'Cap. Ciprofloxacin 500mg', 'type': 'Capsule', 'quantity': 64, 'formula': 'Ciprofloxacin HCl'},
        {'id': 'inv_5', 'name': 'Tab. Flagyl 400mg', 'type': 'Tablet', 'quantity': 6, 'formula': 'Metronidazole'},
        {'id': 'inv_6', 'name': 'Syp. ORS Powder / Electrolyte', 'type': 'Syrup', 'quantity': 45, 'formula': 'Oral Rehydration Salts'},
        {'id': 'inv_7', 'name': 'Tab. Augmentin 625mg', 'type': 'Tablet', 'quantity': 50, 'formula': 'Co-Amoxiclav'},
        {'id': 'inv_8', 'name': 'Tab. Brufen 400mg', 'type': 'Tablet', 'quantity': 90, 'formula': 'Ibuprofen'},
        {'id': 'inv_9', 'name': 'Tab. Amlodipine 5mg', 'type': 'Tablet', 'quantity': 110, 'formula': 'Amlodipine Besylate'},
        {'id': 'inv_10', 'name': 'Tab. Disprin / Lowplat 75mg', 'type': 'Tablet', 'quantity': 80, 'formula': 'Aspirin 75mg'},
      ]);
    }

    if (mounted) {
      setState(() {
        _inventory = items;
        _isLoadingInventory = false;
      });
    }
  }

  int _getStockForMedicine(String medName) {
    final clean = medName.toLowerCase().trim();
    final item = _inventory.firstWhere(
      (m) {
        final name = (m['name'] ?? '').toString().toLowerCase().trim();
        final form = (m['formula'] ?? '').toString().toLowerCase().trim();
        return name.contains(clean) || clean.contains(name) || (form.isNotEmpty && clean.contains(form));
      },
      orElse: () => {},
    );
    if (item.isEmpty) return 99;
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('⚡ Template "${template['name']}" applied!'),
        backgroundColor: Colors.teal.shade800,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showSaveAsTemplateDialog() {
    if (_complaintCtrl.text.isEmpty && _diagnosisCtrl.text.isEmpty && _prescriptions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill diagnosis or medicines first to save as template!'), backgroundColor: Colors.orange),
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
          title: const Row(
            children: [
              Icon(Icons.bookmark_add_rounded, color: _teal, size: 24),
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
                const Text('Template Name / Title:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey)),
                const SizedBox(height: 6),
                TextField(
                  controller: titleCtrl,
                  decoration: InputDecoration(
                    hintText: 'e.g. Typhoid Fever Protocol',
                    filled: true,
                    fillColor: Colors.grey.shade50,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 14),
                const Text('Category:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey)),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  value: selectedCategory,
                  items: ['General', 'Respiratory', 'Gastro', 'Cardio', 'Pediatric', 'ENT', 'Ortho']
                      .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                      .toList(),
                  onChanged: (v) => setDlgState(() => selectedCategory = v ?? 'General'),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: Colors.grey.shade50,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _tealLight,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Includes: ${_prescriptions.length} Medicine(s) • ${_labResults.length} Lab Test(s) • Day: $_daysOfMedicine',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _teal),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: _teal, foregroundColor: Colors.white),
              onPressed: () {
                final newTpl = {
                  'id': 'tpl_${DateTime.now().millisecondsSinceEpoch}',
                  'name': titleCtrl.text.trim(),
                  'category': selectedCategory,
                  'icon': Icons.medical_services,
                  'color': Colors.teal.shade700,
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
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('⭐ Saved "${newTpl['name']}" template!'), backgroundColor: Colors.teal.shade800),
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
      backgroundColor: const Color(0xFFF1F5F9),
      appBar: AppBar(
        backgroundColor: _teal,
        foregroundColor: Colors.white,
        elevation: 2,
        title: const Row(
          children: [
            Icon(Icons.bookmarks_rounded, color: Colors.white, size: 22),
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
            icon: const Icon(Icons.refresh, color: Colors.white, size: 16),
            label: const Text('Reset Form', style: TextStyle(color: Colors.white, fontSize: 12)),
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
                  colors: [Colors.teal.shade50, Colors.white],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.teal.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.bolt, color: Colors.amber, size: 20),
                      const SizedBox(width: 6),
                      const Text(
                        'Disease Presets & Prescription Templates',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: _teal),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: _showSaveAsTemplateDialog,
                        icon: const Icon(Icons.bookmark_add, size: 15, color: _teal),
                        label: const Text('Save Current as Template', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _teal)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _templates.map((tpl) {
                      return ActionChip(
                        avatar: Icon(tpl['icon'] as IconData? ?? Icons.medical_services, size: 14, color: Colors.white),
                        label: Text(tpl['name'], style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
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
            const Text('Patient Condition / Complaints', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5, color: _teal)),
            const SizedBox(height: 6),
            TextField(
              controller: _complaintCtrl,
              maxLines: 2,
              decoration: InputDecoration(
                hintText: 'e.g. High grade fever, vomiting...',
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 14),

            // Diagnosis
            const Text('Diagnosis', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5, color: _teal)),
            const SizedBox(height: 6),
            TextField(
              controller: _diagnosisCtrl,
              maxLines: 2,
              decoration: InputDecoration(
                hintText: 'e.g. Acute Viral Gastroenteritis',
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 16),

            // Prescribed Medicines
            Row(
              children: [
                const FaIcon(FontAwesomeIcons.pills, color: _teal, size: 16),
                const SizedBox(width: 8),
                Text('Prescribed Medicines (${_prescriptions.length})',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5, color: _teal)),
                const Spacer(),
                if (_prescriptions.isNotEmpty)
                  TextButton(
                    onPressed: () => setState(() => _prescriptions.clear()),
                    child: const Text('Clear All', style: TextStyle(color: Colors.red, fontSize: 11)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (_prescriptions.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: const Center(
                  child: Text(
                    '⚡ Click any Template above to auto-fill prescription medicines and diagnosis',
                    style: TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                ),
              )
            else
              ..._prescriptions.map((m) {
                final stock = _getStockForMedicine(m['name']);
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: _tealLight,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const FaIcon(FontAwesomeIcons.capsules, color: _teal, size: 16),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(m['name'], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
                            const SizedBox(height: 2),
                            Text(
                              'Dose: ${m['dose']} • Freq: ${m['frequency']} • Duration: ${m['duration']} • ${m['instructions']}',
                              style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.red, size: 18),
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
