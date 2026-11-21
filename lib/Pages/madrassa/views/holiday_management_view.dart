import 'package:flutter/material.dart';
import 'package:gmwf/design/tokens/comfort_colors.dart';
import 'package:gmwf/design/components/app_toast.dart';
import 'package:intl/intl.dart';
import '../madrassa_strings.dart';
import '../utils/madrassa_local_storage.dart';
import '../widgets/madrassa_erp.dart';

class HolidayManagementView extends StatefulWidget {
  final String branchId;
  const HolidayManagementView({super.key, required this.branchId});

  @override
  State<HolidayManagementView> createState() => _HolidayManagementViewState();
}

class _HolidayManagementViewState extends State<HolidayManagementView> {
  Future<void> _showAddHolidayDialog() async {
    final nameController = TextEditingController();
    DateTime? selectedDate;
    String? nameError;
    String? dateError;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setStateDialog) {
          final c = context.comfort;
          return AlertDialog(
            backgroundColor: c.surface,
            shape: const RoundedRectangleBorder(borderRadius: MadrassaErp.cardRadius),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: c.brandSoft,
                    borderRadius: MadrassaErp.radius,
                  ),
                  child: Icon(Icons.celebration_rounded, color: c.brand, size: 20),
                ),
                const SizedBox(width: 10),
                Text(
                  context.t('Add Holiday'),
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17, color: c.textPrimary, fontFamily: context.isUrdu ? 'Noori' : null),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RichText(
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: context.t('Holiday Name'),
                        style: TextStyle(fontWeight: FontWeight.bold, color: c.textPrimary),
                      ),
                      TextSpan(
                        text: ' *',
                        style: TextStyle(color: c.danger, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: nameController,
                  style: TextStyle(color: c.textPrimary),
                  decoration: InputDecoration(
                    hintText: context.t('Enter holiday name (e.g. Eid-ul-Fitr)'),
                    hintStyle: TextStyle(color: c.textMuted),
                    errorText: nameError,
                    filled: true,
                    fillColor: c.surfaceSunken,
                    border: OutlineInputBorder(borderRadius: MadrassaErp.radius, borderSide: BorderSide(color: c.border)),
                    enabledBorder: OutlineInputBorder(borderRadius: MadrassaErp.radius, borderSide: BorderSide(color: c.border)),
                  ),
                  onChanged: (val) {
                    if (nameError != null) setStateDialog(() => nameError = null);
                  },
                ),
                const SizedBox(height: 16),
                RichText(
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: context.t('Holiday Date'),
                        style: TextStyle(fontWeight: FontWeight.bold, color: c.textPrimary),
                      ),
                      TextSpan(
                        text: ' *',
                        style: TextStyle(color: c.danger, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                InkWell(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: selectedDate ?? DateTime.now(),
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2030),
                    );
                    if (picked != null) {
                      setStateDialog(() {
                        selectedDate = picked;
                        dateError = null;
                      });
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: c.surfaceSunken,
                      border: Border.all(color: dateError != null ? c.danger : c.border),
                      borderRadius: MadrassaErp.radius,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          selectedDate == null
                              ? context.t('Select Date')
                              : DateFormat('yyyy-MM-dd').format(selectedDate!),
                          style: TextStyle(
                            color: selectedDate == null ? c.textMuted : c.textPrimary,
                          ),
                        ),
                        Icon(Icons.calendar_today, size: 18, color: c.brand),
                      ],
                    ),
                  ),
                ),
                if (dateError != null) ...[
                  const SizedBox(height: 4),
                  Text(dateError!, style: TextStyle(color: c.danger, fontSize: 12)),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(context.t('Cancel'), style: TextStyle(color: c.textMuted, fontFamily: context.isUrdu ? 'Noori' : null)),
              ),
              ElevatedButton(
                onPressed: () async {
                  bool isValid = true;
                  if (nameController.text.trim().isEmpty) {
                    setStateDialog(() => nameError = context.t('Holiday name is required'));
                    isValid = false;
                  }
                  if (selectedDate == null) {
                    setStateDialog(() => dateError = context.t('Holiday date is required'));
                    isValid = false;
                  }

                  if (!isValid) {
                    AppToast.showSnackBar(context, 
                      SnackBar(
                        content: Text(
                          context.t('Please correct all validation errors to continue'),
                          style: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null),
                        ),
                        backgroundColor: c.danger,
                      ),
                    );
                    return;
                  }

                  final nav = Navigator.of(ctx);
                  await MadrassaLocalStorage.saveHolidayLocalAndSync(
                    branchId: widget.branchId,
                    name: nameController.text.trim(),
                    date: selectedDate!,
                  );
                  nav.pop();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: c.brand,
                  foregroundColor: c.onBrand,
                  elevation: 0,
                  shape: const RoundedRectangleBorder(borderRadius: MadrassaErp.radius),
                ),
                child: Text(context.t('Add'), style: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null)),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _deleteHoliday(String holidayId) async {
    await MadrassaLocalStorage.deleteHolidayLocalAndSync(
      branchId: widget.branchId,
      holidayId: holidayId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    return Scaffold(
      backgroundColor: c.surfaceSunken,
      appBar: AppBar(
        title: Text('Holiday Management', style: TextStyle(color: c.textPrimary, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(icon: const Icon(Icons.add), onPressed: _showAddHolidayDialog),
        ],
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: MadrassaLocalStorage.streamHolidaysCached(widget.branchId),
        builder: (ctx, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final holidays = snapshot.data!;
          if (holidays.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.event_busy_rounded, size: 48, color: c.textMuted.withValues(alpha: 0.5)),
                  const SizedBox(height: 12),
                  Text('No holidays added yet.', style: TextStyle(color: c.textMuted, fontSize: 15)),
                ],
              ),
            );
          }

          final sortedHolidays = List<Map<String, dynamic>>.from(holidays)..sort((a, b) {
            final da = a['date']?.toString() ?? a['id']?.toString() ?? '';
            final db = b['date']?.toString() ?? b['id']?.toString() ?? '';
            return da.compareTo(db);
          });

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: sortedHolidays.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final h = sortedHolidays[i];
              final name = h['name']?.toString() ?? 'Holiday';
              final dateStr = h['date']?.toString() ?? h['id']?.toString() ?? '';
              DateTime? parsedDate;
              if (dateStr.isNotEmpty) {
                parsedDate = DateTime.tryParse(dateStr);
              }
              final displayDate = parsedDate != null ? DateFormat('dd MMM yyyy (EEEE)').format(parsedDate) : dateStr;
              final hId = h['id']?.toString() ?? '';

              return Container(
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: MadrassaErp.cardRadius,
                  border: Border.all(color: c.border),
                ),
                child: ListTile(
                  leading: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: c.brandSoft,
                      borderRadius: MadrassaErp.radius,
                    ),
                    child: Icon(Icons.event_note, color: c.brand, size: 20),
                  ),
                  title: Text(name, style: TextStyle(fontWeight: FontWeight.bold, color: c.textPrimary, fontSize: 14)),
                  subtitle: Text(displayDate, style: TextStyle(color: c.textMuted, fontSize: 12)),
                  trailing: IconButton(
                    icon: Icon(Icons.delete_outline, color: c.danger, size: 20),
                    onPressed: () => _deleteHoliday(hId),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
