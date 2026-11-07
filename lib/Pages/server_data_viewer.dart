import 'dart:convert';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import '../services/local_storage_service.dart';

class ServerDataViewer extends StatefulWidget {
  final String branchId;
  final bool isEmbedded;

  const ServerDataViewer({super.key, required this.branchId, this.isEmbedded = false});

  @override
  State<ServerDataViewer> createState() => _ServerDataViewerState();
}

class _ServerDataViewerState extends State<ServerDataViewer> {
  String _selectedDateKey = '';
  String _selectedCategory = 'all';
  String _searchQuery = '';
  bool _sortNewestFirst = true;

  final TextEditingController _searchController = TextEditingController();

  final List<Map<String, String>> _categories = const [
    {'id': 'all', 'label': 'All Categories', 'icon': '📂'},
    {'id': 'dispensary', 'label': 'Dispensary & OPD', 'icon': '🏥'},
    {'id': 'madrassa', 'label': 'Madrassa & Education', 'icon': '🎓'},
    {'id': 'school', 'label': 'School & Library', 'icon': '🏫'},
    {'id': 'finance', 'label': 'Finance & Donations', 'icon': '💰'},
    {'id': 'dasterkhwaan', 'label': 'Dasterkhwaan & Welfare', 'icon': '🍲'},
    {'id': 'system', 'label': 'System & Sync Logs', 'icon': '⚙️'},
    {'id': 'failed_outbox', 'label': 'Failed Outbox (Errors)', 'icon': '🚨'},
  ];

  @override
  void initState() {
    super.initState();
    _selectedDateKey = DateFormat('yyyy-MM-dd').format(DateTime.now());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _detectCategory(Map<String, dynamic> entry) {
    final qt = (entry['queueType'] ?? entry['category'] ?? entry['type'] ?? '').toString().toLowerCase();
    final dataStr = jsonEncode(entry).toLowerCase();

    if (qt.contains('madrassa') || dataStr.contains('madrassa') || dataStr.contains('hafiz') || dataStr.contains('tajweed')) {
      return 'madrassa';
    }
    if (qt.contains('school') || dataStr.contains('school') || qt.contains('library')) {
      return 'school';
    }
    if (qt.contains('donation') || qt.contains('finance') || qt.contains('expense') || qt.contains('loan') || dataStr.contains('amount_paid')) {
      return 'finance';
    }
    if (qt.contains('food') || qt.contains('dasterkhwaan') || qt.contains('ration')) {
      return 'dasterkhwaan';
    }
    if (qt.contains('sync') || qt.contains('heartbeat') || qt.contains('system')) {
      return 'system';
    }
    // Default fallback to dispensary/OPD for patient entries
    return 'dispensary';
  }

  static String _normalizeDateKey(String raw, [String? createdAt]) {
    final s = raw.trim();
    if (s.length == 6 && RegExp(r'^\d{6}$').hasMatch(s)) {
      final d = int.tryParse(s.substring(0, 2)) ?? 1;
      final m = int.tryParse(s.substring(2, 4)) ?? 1;
      final y = 2000 + (int.tryParse(s.substring(4, 6)) ?? 26);
      return '${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}';
    }
    if (s.length >= 10 && RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(s)) {
      return s.substring(0, 10);
    }
    if (createdAt != null && createdAt.isNotEmpty) {
      final dt = DateTime.tryParse(createdAt);
      if (dt != null) {
        return DateFormat('yyyy-MM-dd').format(dt);
      }
    }
    return s.isNotEmpty ? s : 'unknown';
  }

  static String _formatDisplayDate(String normDate) {
    try {
      final dt = DateTime.tryParse(normDate);
      if (dt != null) {
        final now = DateTime.now();
        if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
          return 'Today (${DateFormat('d MMM').format(dt)})';
        }
        final yesterday = now.subtract(const Duration(days: 1));
        if (dt.year == yesterday.year && dt.month == yesterday.month && dt.day == yesterday.day) {
          return 'Yesterday (${DateFormat('d MMM').format(dt)})';
        }
        return DateFormat('d MMM yyyy').format(dt);
      }
    } catch (_) {}
    return normDate;
  }

  void _showEntryDetails(BuildContext context, Map<String, dynamic> entry) {
    showModalBottomSheet(
      context: context,
      backgroundColor: SoftPalette.slate800,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        final category = _detectCategory(entry);
        final serial = entry['serial']?.toString() ?? 'N/A';
        final name = entry['patientName'] ?? entry['name'] ?? entry['title'] ?? 'Record Payload';
        final status = (entry['status'] ?? 'waiting').toString();
        final prettyJson = const JsonEncoder.withIndent('  ').convert(entry);

        return Container(
          height: MediaQuery.of(ctx).size.height * 0.75,
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      '#$serial - $name',
                      style: const TextStyle(color: SoftPalette.gray50, fontSize: 18, fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: SoftPalette.gray50A70),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Chip(
                    avatar: Text(_categories.firstWhere((c) => c['id'] == category)['icon'] ?? '📁'),
                    label: Text(category.toUpperCase(), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: SoftPalette.gray50)),
                    backgroundColor: SoftPalette.blue400.withValues(alpha: 0.2),
                    side: BorderSide(color: SoftPalette.blue400.withValues(alpha: 0.4)),
                  ),
                  const SizedBox(width: 8),
                  Chip(
                    label: Text(status.toUpperCase(), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: SoftPalette.gray50)),
                    backgroundColor: status == 'completed' ? SoftPalette.green400.withValues(alpha: 0.2) : SoftPalette.amber300.withValues(alpha: 0.2),
                    side: BorderSide(color: status == 'completed' ? SoftPalette.green400 : SoftPalette.amber300),
                  ),
                ],
              ),
              const Divider(color: SoftPalette.gray50A10, height: 24),
              const Text('RAW RECORD PAYLOAD:', style: TextStyle(color: SoftPalette.gray50A54, fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: SoftPalette.slate900,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: SoftPalette.gray50A10),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      prettyJson,
                      style: const TextStyle(color: SoftPalette.emerald350, fontFamily: 'monospace', fontSize: 13, height: 1.4),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? SoftPalette.slate900 : SoftPalette.slate100,
      appBar: widget.isEmbedded
          ? null
          : AppBar(
              automaticallyImplyLeading: false,
              backgroundColor: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
              elevation: 0,
              scrolledUnderElevation: 0,
              title: Text(
                'Server Data Archive',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                ),
              ),
              iconTheme: IconThemeData(color: isDark ? SoftPalette.gray50 : SoftPalette.slate900),
              actions: [
                IconButton(
                  icon: Icon(
                    _sortNewestFirst ? Icons.sort_rounded : Icons.history_rounded,
                    color: isDark ? SoftPalette.gray50A70 : SoftPalette.slate600,
                  ),
                  tooltip: _sortNewestFirst ? 'Sorting: Newest First' : 'Sorting: Oldest First',
                  onPressed: () {
                    setState(() {
                      _sortNewestFirst = !_sortNewestFirst;
                    });
                  },
                ),
              ],
            ),
      body: ValueListenableBuilder(
        valueListenable: Hive.box(LocalStorageService.entriesBox).listenable(),
        builder: (context, Box box, _) {
          List<Map<String, dynamic>> allEntries = LocalStorageService.getLocalEntries(widget.branchId);
          if (_selectedCategory == 'failed_outbox') {
            try {
              if (Hive.isBoxOpen('realtime_failed_outbox')) {
                final failedBox = Hive.box('realtime_failed_outbox');
                allEntries = failedBox.values
                    .whereType<Map>()
                    .map((m) => Map<String, dynamic>.from(m))
                    .toList();
              }
            } catch (_) {}
          }

          // Group by normalized dateKey
          final Map<String, List<Map<String, dynamic>>> grouped = {};
          for (final entry in allEntries) {
            final rawDk = entry['dateKey']?.toString() ?? '';
            final cAt = entry['createdAt']?.toString() ?? entry['timestamp']?.toString();
            final dk = _normalizeDateKey(rawDk, cAt);
            grouped.putIfAbsent(dk, () => []).add(entry);
          }

          final sortedDates = grouped.keys.toList()..sort((a, b) => _sortNewestFirst ? b.compareTo(a) : a.compareTo(b));

          if (sortedDates.isEmpty) {
            return Center(
              child: Text(
                'No data saved on this server yet.',
                style: TextStyle(color: isDark ? SoftPalette.gray50A54 : SoftPalette.slate350, fontSize: 16),
              ),
            );
          }

          if (!sortedDates.contains(_selectedDateKey) && sortedDates.isNotEmpty) {
            _selectedDateKey = sortedDates.first;
          }

          final rawCurrentList = grouped[_selectedDateKey] ?? [];

          // Filter by category and search query
          final filteredList = rawCurrentList.where((entry) {
            if (_selectedCategory != 'all') {
              final cat = _detectCategory(entry);
              if (cat != _selectedCategory) return false;
            }
            if (_searchQuery.isNotEmpty) {
              final q = _searchQuery.toLowerCase();
              final serial = (entry['serial'] ?? '').toString().toLowerCase();
              final name = (entry['patientName'] ?? entry['name'] ?? '').toString().toLowerCase();
              final by = (entry['performedBy'] ?? '').toString().toLowerCase();
              final qt = (entry['queueType'] ?? '').toString().toLowerCase();

              return serial.contains(q) || name.contains(q) || by.contains(q) || qt.contains(q);
            }
            return true;
          }).toList();

          filteredList.sort((a, b) {
            final tA = (a['createdAt'] ?? '').toString();
            final tB = (b['createdAt'] ?? '').toString();
            return _sortNewestFirst ? tB.compareTo(tA) : tA.compareTo(tB);
          });

          return Column(
            children: [
              // Top Bar Filters: Category Chips + Search Bar
              Container(
                decoration: BoxDecoration(
                  color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                  border: Border(
                    bottom: BorderSide(
                      color: isDark ? SoftPalette.slate800 : SoftPalette.slate150,
                      width: 1,
                    ),
                  ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Column(
                  children: [
                    // Search Bar
                    TextField(
                      controller: _searchController,
                      style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.slate900, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: 'Search by serial #, patient, staff, or category...',
                        hintStyle: TextStyle(color: isDark ? SoftPalette.gray50A38 : SoftPalette.slate350, fontSize: 13),
                        prefixIcon: Icon(Icons.search_rounded, color: isDark ? SoftPalette.gray50A54 : SoftPalette.slate550, size: 20),
                        suffixIcon: _searchQuery.isNotEmpty
                            ? IconButton(
                                icon: Icon(Icons.clear_rounded, color: isDark ? SoftPalette.gray50A54 : SoftPalette.slate550, size: 18),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _searchQuery = '');
                                },
                              )
                            : null,
                        filled: true,
                        fillColor: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: isDark ? SoftPalette.slate800 : SoftPalette.slate150),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: isDark ? SoftPalette.slate800 : SoftPalette.slate150),
                        ),
                      ),
                      onChanged: (val) {
                        setState(() => _searchQuery = val.trim());
                      },
                    ),
                    const SizedBox(height: 10),
                    // Category Chips Scroll
                    SizedBox(
                      height: 38,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _categories.length,
                        separatorBuilder: (context, index) => const SizedBox(width: 8),
                        itemBuilder: (ctx, idx) {
                          final cat = _categories[idx];
                          final isSelected = cat['id'] == _selectedCategory;
                          return ChoiceChip(
                            avatar: Text(cat['icon']!),
                            label: Text(
                              cat['label']!,
                              style: TextStyle(
                                color: isSelected
                                    ? (isDark ? SoftPalette.gray50 : SoftPalette.emerald600)
                                    : (isDark ? SoftPalette.slate350 : SoftPalette.slate600),
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                fontSize: 12,
                              ),
                            ),
                            selected: isSelected,
                            selectedColor: isDark ? SoftPalette.teal550.withOpacity(0.35) : SoftPalette.emerald50,
                            backgroundColor: isDark ? SoftPalette.slate900 : SoftPalette.slate100,
                            side: BorderSide(
                              color: isSelected
                                  ? SoftPalette.emerald350
                                  : (isDark ? SoftPalette.slate700 : SoftPalette.slate200),
                            ),
                            onSelected: (_) {
                              setState(() => _selectedCategory = cat['id']!);
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),

              // Main Layout: Dates Sidebar + Categorized Entries Grid/List
              Expanded(
                child: Row(
                  children: [
                    // Sidebar for Dates
                    Container(
                      width: 230,
                      color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                      child: ListView.builder(
                        itemCount: sortedDates.length,
                        itemBuilder: (context, index) {
                          final date = sortedDates[index];
                          final count = grouped[date]?.length ?? 0;
                          final isSelected = date == _selectedDateKey;

                          return ListTile(
                            dense: true,
                            title: Text(
                              _formatDisplayDate(date),
                              style: TextStyle(
                                color: isSelected
                                    ? (isDark ? SoftPalette.sky350 : SoftPalette.sky500)
                                    : (isDark ? SoftPalette.slate350 : SoftPalette.slate700),
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                            trailing: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? SoftPalette.sky500.withOpacity(0.15)
                                    : (isDark ? SoftPalette.slate800 : SoftPalette.slate100),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isSelected ? SoftPalette.sky500.withOpacity(0.4) : Colors.transparent,
                                ),
                              ),
                              child: Text(
                                '$count',
                                style: TextStyle(
                                  color: isSelected
                                      ? (isDark ? SoftPalette.sky350 : SoftPalette.sky500)
                                      : (isDark ? SoftPalette.slate550 : SoftPalette.slate550),
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            selected: isSelected,
                            selectedTileColor: isDark ? SoftPalette.sky500.withOpacity(0.1) : SoftPalette.slate50,
                            onTap: () {
                              setState(() {
                                _selectedDateKey = date;
                              });
                            },
                          );
                        },
                      ),
                    ),
                    VerticalDivider(width: 1, color: isDark ? SoftPalette.slate800 : SoftPalette.slate150),

                    // Content Area for Selected Date & Filters
                    Expanded(
                      child: filteredList.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.folder_open_rounded, size: 48, color: isDark ? SoftPalette.gray50A24 : SoftPalette.slate200),
                                  const SizedBox(height: 12),
                                  Text(
                                    _searchQuery.isNotEmpty
                                        ? 'No records matching "$_searchQuery"'
                                        : 'No records found for this category/date.',
                                    style: TextStyle(color: isDark ? SoftPalette.gray50A54 : SoftPalette.slate550, fontSize: 14),
                                  ),
                                ],
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.all(20),
                              itemCount: filteredList.length,
                              itemBuilder: (context, index) {
                                final entry = filteredList[index];
                                final category = _detectCategory(entry);
                                final serial = entry['serial']?.toString() ?? 'N/A';
                                final name = (entry['patientName'] ?? entry['name'] ?? entry['title'] ?? 'Record Payload').toString();
                                final byRaw = entry['performedBy'] ??
                                              entry['createdByName'] ??
                                              entry['createdBy'] ??
                                              entry['doctorName'] ??
                                              entry['receptionistName'] ??
                                              entry['_senderUsername'] ??
                                              entry['userId'];
                                final by = (byRaw != null && byRaw.toString().trim().isNotEmpty)
                                    ? byRaw.toString().trim()
                                    : 'Unknown Staff';
                                final status = (entry['status'] ?? 'waiting').toString();
                                final timeStr = entry['createdAt']?.toString() ?? '';

                                String displayTime = '';
                                if (timeStr.isNotEmpty) {
                                  try {
                                    final dt = DateTime.parse(timeStr);
                                    displayTime = DateFormat('hh:mm:ss a').format(dt);
                                  } catch (_) {}
                                }

                                Color statusColor = SoftPalette.amber300;
                                if (status == 'completed' || status == 'dispensed') statusColor = SoftPalette.emerald350;

                                final catIcon = _categories.firstWhere((c) => c['id'] == category, orElse: () => _categories.first)['icon']!;

                                return InkWell(
                                  onTap: () => _showEntryDetails(context, entry),
                                  borderRadius: BorderRadius.circular(14),
                                  child: Card(
                                    color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                                    margin: const EdgeInsets.only(bottom: 10),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                      side: BorderSide(color: isDark ? SoftPalette.slate800 : SoftPalette.slate150),
                                    ),
                                    elevation: isDark ? 0 : 1,
                                    shadowColor: SoftPalette.gray900.withOpacity(0.04),
                                    child: Padding(
                                      padding: const EdgeInsets.all(16),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Text(catIcon, style: const TextStyle(fontSize: 18)),
                                              const SizedBox(width: 8),
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                                decoration: BoxDecoration(
                                                  color: SoftPalette.sky500.withOpacity(0.12),
                                                  borderRadius: BorderRadius.circular(6),
                                                  border: Border.all(color: SoftPalette.sky500.withOpacity(0.35)),
                                                ),
                                                child: Text(
                                                  '#$serial',
                                                  style: const TextStyle(color: SoftPalette.sky500, fontWeight: FontWeight.bold, fontSize: 12),
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Text(
                                                  name,
                                                  style: TextStyle(
                                                    color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                                                    fontSize: 15,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ),
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                                decoration: BoxDecoration(
                                                  color: statusColor.withOpacity(0.12),
                                                  borderRadius: BorderRadius.circular(6),
                                                  border: Border.all(color: statusColor.withOpacity(0.35)),
                                                ),
                                                child: Text(
                                                  status.toUpperCase(),
                                                  style: TextStyle(color: statusColor, fontSize: 11, fontWeight: FontWeight.bold),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 12),
                                          const Divider(color: SoftPalette.gray50A10, height: 1),
                                          const SizedBox(height: 10),
                                          Row(
                                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                            children: [
                                              Row(
                                                children: [
                                                  const Icon(Icons.person_outline_rounded, size: 14, color: SoftPalette.gray50A54),
                                                  const SizedBox(width: 4),
                                                  Text('By: $by', style: const TextStyle(color: SoftPalette.gray50A54, fontSize: 12)),
                                                ],
                                              ),
                                              Row(
                                                children: [
                                                  const Icon(Icons.access_time_rounded, size: 14, color: SoftPalette.gray50A54),
                                                  const SizedBox(width: 4),
                                                  Text(displayTime, style: const TextStyle(color: SoftPalette.gray50A54, fontSize: 12)),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
