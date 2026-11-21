import 'package:flutter/material.dart';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:gmwf_ui/gmwf_ui.dart' show GEmptyIllustration, GEmptyIllustrationKind;
import 'package:gmwf/design/tokens/comfort_colors.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../../models/donation_models.dart';
import 'donations_shared.dart';

class GlobalAuditTrailScreen extends StatefulWidget {
  final UserRole role;
  const GlobalAuditTrailScreen({super.key, required this.role});

  @override
  State<GlobalAuditTrailScreen> createState() => _GlobalAuditTrailScreenState();
}

class _GlobalAuditTrailScreenState extends State<GlobalAuditTrailScreen> {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  String _filterAction = 'all';
  Future<QuerySnapshot>? _logsFuture;
  List<QueryDocumentSnapshot> _cachedDocs = []; // PERSISTENCE CACHE

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    try {
      Query query = _db.collection('global_audit_logs').orderBy('timestamp', descending: true).limit(100);
      if (_filterAction != 'all') {
        if (_filterAction == 'delete') {
          query = query.where('action', whereIn: ['delete', 'delete_donation']);
        } else if (_filterAction == 'update') {
          query = query.where('action', whereIn: ['update', 'edit']);
        } else {
          query = query.where('action', isEqualTo: _filterAction);
        }
      }
      setState(() {
        _logsFuture = query.get();
      });
    } catch (e) {
      debugPrint('Error loading audit logs: $e');
      setState(() {
        _logsFuture = Future.error(e);
      });
    }
  }

  void _updateFilter(String action) {
    if (_filterAction == action) return;
    setState(() {
      _filterAction = action;
    });
    _loadLogs();
  }

  @override
  Widget build(BuildContext context) {
    final isAuthorized = widget.role.isChairman || widget.role.isHqManager;

    return Scaffold(
      backgroundColor: context.adapt(SoftPalette.slate100),
      body: !isAuthorized 
        ? _buildUnauthorizedView()
        : Container(
            decoration: BoxDecoration(
              color: context.adapt(SoftPalette.gray50),
            ),
            child: Column(
              children: [
                _buildHeader(context),
                _buildFilterBar(),
                Expanded(child: _buildLogsList()),
              ],
            ),
          ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(32, 48, 24, 24),
      decoration: BoxDecoration(
        color: context.adapt(SoftPalette.gray50),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(32)),
        boxShadow: [
          BoxShadow(color: SoftPalette.gray900A4, blurRadius: 20, offset: Offset(0, 10)),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: SoftPalette.orange400.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(Icons.history_toggle_off_rounded, color: SoftPalette.orange400, size: 28),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Global Audit Trail', 
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: context.adapt(SoftPalette.slate900), letterSpacing: -0.5)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(width: 8, height: 8, decoration: const BoxDecoration(color: SoftPalette.emerald350, shape: BoxShape.circle)),
                    const SizedBox(width: 8),
                    Text('AUTHORIZED SYSTEM ACCESS', 
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: context.adapt(SoftPalette.slate550), letterSpacing: 1)),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: Icon(Icons.close_rounded, color: context.adapt(SoftPalette.slate350), size: 28),
          ),
        ],
      ),
    );
  }

  Widget _buildUnauthorizedView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.lock_person_rounded, size: 80, color: SoftPalette.red400.withValues(alpha: 0.1)),
          const SizedBox(height: 24),
          Text('Access Restricted', 
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: context.adapt(SoftPalette.slate900))),
          const SizedBox(height: 8),
          Text('Only Chairman and HQ Manager can view global audit logs.',
            style: TextStyle(color: context.adapt(SoftPalette.slate550)), textAlign: TextAlign.center),
          const SizedBox(height: 32),
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(backgroundColor: context.adapt(SoftPalette.slate900), foregroundColor: context.adapt(SoftPalette.gray50)),
            child: const Text('Go Back'),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 0),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _FilterTab(
              label: 'ALL ACTIVITY',
              isActive: _filterAction == 'all',
              onTap: () => _updateFilter('all'),
            ),
            const SizedBox(width: 12),
            _FilterTab(
              label: 'CREATED',
              isActive: _filterAction == 'create',
              onTap: () => _updateFilter('create'),
            ),
            const SizedBox(width: 12),
            _FilterTab(
              label: 'EDITED',
              isActive: _filterAction == 'update',
              onTap: () => _updateFilter('update'),
            ),
            const SizedBox(width: 12),
            _FilterTab(
              label: 'DELETED',
              isActive: _filterAction == 'delete',
              onTap: () => _updateFilter('delete'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogsList() {
    if (_logsFuture == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return FutureBuilder<QuerySnapshot>(
      future: _logsFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          if (_cachedDocs.isNotEmpty) {
            return Column(
              children: [
                _buildErrorBanner(snapshot.error.toString()),
                Expanded(child: _buildDocsListView(_cachedDocs)),
              ],
            );
          }
          return _buildErrorState(snapshot.error.toString());
        }

        if (snapshot.connectionState == ConnectionState.waiting && _cachedDocs.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }

        final docs = snapshot.data?.docs ?? _cachedDocs;
        if (snapshot.hasData) {
          _cachedDocs = snapshot.data!.docs;
        }

        if (docs.isEmpty) return _buildEmptyState();

        return _buildDocsListView(docs);
      },
    );
  }

  Widget _buildDocsListView(List<QueryDocumentSnapshot> docs) {
    return ListView.builder(
      padding: const EdgeInsets.all(32),
      itemCount: docs.length,
      itemBuilder: (context, index) {
        final entry = AuditLogEntry.fromMap(docs[index].data() as Map<String, dynamic>);
        return _AuditLogCard(entry: entry);
      },
    );
  }

  Widget _buildErrorBanner(String error) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: context.adapt(SoftPalette.amber100m), borderRadius: BorderRadius.circular(12), border: Border.all(color: context.adapt(SoftPalette.amber200))),
      child: Row(children: [
        const Icon(Icons.warning_amber_rounded, size: 16, color: SoftPalette.amber300),
        const SizedBox(width: 12),
        const Expanded(child: Text('Live updates paused. Showing cached data.', style: TextStyle(fontSize: 12, color: SoftPalette.amber300, fontWeight: FontWeight.bold))),
      ]),
    );
  }

  Widget _buildErrorState(String error) {
    final bool isIndexError = error.contains('index') || error.contains('failed-precondition');
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Center(
        child: Container(
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(color: context.adapt(SoftPalette.gray50), borderRadius: BorderRadius.circular(24)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.warning_amber_rounded, size: 48, color: SoftPalette.amber300),
              const SizedBox(height: 20),
              Text('Database Index Required', 
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: context.adapt(SoftPalette.slate900))),
              const SizedBox(height: 12),
              Text(
                isIndexError 
                  ? 'This view requires a simple index for "global_audit_logs".\n\n1. Go to Firebase Console\n2. Firestore -> Indexes\n3. Add Index\n4. Collection: global_audit_logs\n5. Field: timestamp (Descending)'
                  : 'Error: $error',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.adapt(SoftPalette.slate550), height: 1.5),
              ),
              const SizedBox(height: 24),
              Text('Data will appear here automatically once the index is ready.', 
                style: TextStyle(fontSize: 11, color: context.adapt(SoftPalette.gray350), fontStyle: FontStyle.italic), textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const GEmptyIllustration(
            GEmptyIllustrationKind.activity,
            size: 156,
            fallbackIcon: Icons.assignment_turned_in_rounded,
          ),
          const SizedBox(height: 16),
          Text('No activity logs found', style: TextStyle(color: context.adapt(SoftPalette.slate350), fontWeight: FontWeight.w600, fontSize: 15)),
        ],
      ),
    );
  }
}

class _FilterTab extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _FilterTab({required this.label, required this.isActive, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? SoftPalette.indigo500 : context.adapt(SoftPalette.gray50),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: isActive ? SoftPalette.indigo500 : context.adapt(SoftPalette.slate150)),
          boxShadow: isActive ? [BoxShadow(color: SoftPalette.indigo500.withValues(alpha: 0.3), blurRadius: 8, offset: const Offset(0, 4))] : [],
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            color: isActive ? SoftPalette.gray50 : context.adapt(SoftPalette.slate550),
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}

class _AuditLogCard extends StatelessWidget {
  final AuditLogEntry entry;
  const _AuditLogCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    final dt = DateTime.tryParse(entry.timestamp) ?? DateTime.now();
    final timeStr = DateFormat('hh:mm a').format(dt);
    final dateStr = DateFormat('MMM dd, yyyy').format(dt);

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        color: context.adapt(SoftPalette.gray50),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: context.adapt(SoftPalette.slate150).withValues(alpha: 0.6)),
        boxShadow: [
          BoxShadow(color: SoftPalette.gray900.withValues(alpha: 0.02), blurRadius: 15, offset: const Offset(0, 8)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            decoration: BoxDecoration(
              color: context.adapt(SoftPalette.gray50),
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _buildActionBadge(),
                Text('$dateStr • $timeStr', 
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: context.adapt(SoftPalette.slate350))),
              ],
            ),
          ),
          // Body
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(color: context.adapt(SoftPalette.slate900), shape: BoxShape.circle),
                      child: Center(
                        child: Text(
                          entry.username.trim().isNotEmpty ? entry.username.trim()[0].toUpperCase() : 'U',
                          style: TextStyle(color: context.adapt(SoftPalette.gray50), fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.username.trim().isNotEmpty ? entry.username : 'System User',
                            style: TextStyle(fontWeight: FontWeight.w900, color: context.adapt(SoftPalette.slate900), fontSize: 15),
                          ),
                          Row(
                            children: [
                              Text('User ID: ${entry.userId.trim().isNotEmpty ? entry.userId : 'system'}', style: TextStyle(fontSize: 11, color: context.adapt(SoftPalette.slate550))),
                              if (entry.branchName.isNotEmpty) ...[
                                Text(' • ', style: TextStyle(fontSize: 11, color: context.adapt(SoftPalette.slate200))),
                                Text(entry.branchName.toUpperCase(), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: SoftPalette.indigo500, letterSpacing: 0.5)),
                              ]
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                _buildDescription(context),
                if (entry.reason != null && entry.reason!.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _buildReasonPanel(),
                ],
                if (entry.action == 'update' && entry.oldData != null && entry.newData != null) ...[
                  const SizedBox(height: 20),
                  _buildDiffView(context),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionBadge() {
    Color color;
    String label;
    IconData icon;

    switch (entry.action) {
      case 'create':
        color = SoftPalette.emerald350;
        label = 'CREATED';
        icon = Icons.add_circle_outline_rounded;
        break;
      case 'update':
        color = SoftPalette.indigo500;
        label = 'EDITED';
        icon = Icons.edit_note_rounded;
        break;
      case 'delete':
      case 'delete_donation':
        color = SoftPalette.red400;
        label = 'DELETED';
        icon = Icons.delete_outline_rounded;
        break;
      default:
        color = SoftPalette.slate550;
        label = 'ACTIVITY';
        icon = Icons.info_outline_rounded;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: color, letterSpacing: 1)),
      ],
    );
  }

  Widget _buildDescription(BuildContext context) {
    final oldD = entry.oldData ?? {};
    final newD = entry.newData ?? {};
    final combined = {...oldD, ...newD};

    final collection = entry.collection.toLowerCase();
    final actionText = entry.action == 'create'
        ? 'created'
        : entry.action == 'update'
            ? 'modified'
            : 'permanently deleted';

    // 1. Donation Box
    if (collection.contains('box') || combined.containsKey('boxNumber')) {
      final boxNo = combined['boxNumber'] ?? entry.documentId;
      final holder = combined['holderName'] ?? '';
      final area = combined['area'] ?? '';
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: context.adapt(SoftPalette.slate100).withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(16),
        ),
        child: RichText(
          text: TextSpan(
            style: TextStyle(fontSize: 14, color: context.adapt(SoftPalette.slate700), height: 1.5),
            children: [
              const TextSpan(text: 'Donation Box '),
              TextSpan(text: '#$boxNo', style: TextStyle(fontWeight: FontWeight.w900, color: context.adapt(SoftPalette.slate900), fontFamily: 'monospace')),
              if (holder.toString().isNotEmpty) ...[
                const TextSpan(text: ' for '),
                TextSpan(text: holder.toString(), style: TextStyle(fontWeight: FontWeight.w800, color: context.adapt(SoftPalette.slate900))),
              ],
              if (area.toString().isNotEmpty) ...[
                TextSpan(text: ' (${area.toString()})'),
              ],
              TextSpan(text: ' was $actionText.'),
            ],
          ),
        ),
      );
    }

    // 2. Donation Record
    if (collection.contains('donation') || combined.containsKey('receiptNo') || combined.containsKey('donorName') || combined.containsKey('amount')) {
      final donor = combined['donorName'] ?? 'Walk-in / Anonymous Donor';
      final receipt = cleanReceiptNumber(combined['receiptNo']?.toString() ?? '');
      final amount = (combined['amount'] as num?)?.toDouble() ?? 0.0;
      final category = combined['categoryId']?.toString().toUpperCase() ?? '';

      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: context.adapt(SoftPalette.slate100).withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(16),
        ),
        child: RichText(
          text: TextSpan(
            style: TextStyle(fontSize: 14, color: context.adapt(SoftPalette.slate700), height: 1.5),
            children: [
              const TextSpan(text: 'Donation record '),
              if (receipt.isNotEmpty) ...[
                TextSpan(text: '($receipt) ', style: const TextStyle(fontWeight: FontWeight.w900, color: SoftPalette.indigo500, fontFamily: 'monospace')),
              ],
              const TextSpan(text: 'for '),
              TextSpan(text: donor.toString(), style: TextStyle(fontWeight: FontWeight.w900, color: context.adapt(SoftPalette.slate900))),
              if (amount > 0) ...[
                const TextSpan(text: ' with value of '),
                TextSpan(
                  text: 'PKR ${NumberFormat('#,###').format(amount)}',
                  style: const TextStyle(fontWeight: FontWeight.w900, color: SoftPalette.emerald550, fontFamily: 'monospace'),
                ),
              ],
              if (category.isNotEmpty) ...[
                TextSpan(text: ' [$category]'),
              ],
              TextSpan(text: ' was $actionText.'),
            ],
          ),
        ),
      );
    }

    // 3. Daily Log / Module Log (e.g. Madrassa / School / Dispensary daily log)
    if (collection.contains('daily_log') || entry.reason?.toLowerCase().contains('daily log') == true || combined.containsKey('dateKey') || combined.containsKey('totalPresent')) {
      final date = combined['date'] ?? combined['dateKey'] ?? entry.documentId;
      final branch = entry.branchName.isNotEmpty ? entry.branchName : (combined['branchName'] ?? combined['branchId'] ?? 'Branch');
      final logType = collection.contains('madrassa')
          ? 'Madrassa'
          : (collection.contains('school') ? 'School' : (collection.contains('dispensary') ? 'Dispensary' : 'Daily'));

      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: context.adapt(SoftPalette.slate100).withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(16),
        ),
        child: RichText(
          text: TextSpan(
            style: TextStyle(fontSize: 14, color: context.adapt(SoftPalette.slate700), height: 1.5),
            children: [
              TextSpan(text: '$logType Daily Log ', style: const TextStyle(fontWeight: FontWeight.bold)),
              const TextSpan(text: 'for '),
              TextSpan(text: branch.toString(), style: TextStyle(fontWeight: FontWeight.w900, color: context.adapt(SoftPalette.slate900))),
              const TextSpan(text: ' on '),
              TextSpan(text: date.toString(), style: const TextStyle(fontWeight: FontWeight.w800, color: SoftPalette.indigo500)),
              TextSpan(text: ' was $actionText.'),
            ],
          ),
        ),
      );
    }

    // 4. Donor Profile
    if (collection.contains('donor') || combined.containsKey('phones') || combined.containsKey('cnic')) {
      final name = combined['name'] ?? combined['donorName'] ?? entry.documentId;
      final phone = (combined['phones'] is List && (combined['phones'] as List).isNotEmpty)
          ? (combined['phones'] as List).first
          : (combined['phone'] ?? '');

      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: context.adapt(SoftPalette.slate100).withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(16),
        ),
        child: RichText(
          text: TextSpan(
            style: TextStyle(fontSize: 14, color: context.adapt(SoftPalette.slate700), height: 1.5),
            children: [
              const TextSpan(text: 'Donor Profile for '),
              TextSpan(text: name.toString(), style: TextStyle(fontWeight: FontWeight.w900, color: context.adapt(SoftPalette.slate900))),
              if (phone.toString().isNotEmpty) TextSpan(text: ' (${phone.toString()})'),
              TextSpan(text: ' was $actionText.'),
            ],
          ),
        ),
      );
    }

    // 5. Generic fallback with clean entity identification
    final identifier = combined['name'] ?? combined['title'] ?? combined['patientName'] ?? combined['serial'] ?? combined['id'] ?? entry.documentId;
    final collName = collection.isNotEmpty ? collection.replaceAll('_', ' ').toUpperCase() : 'RECORD';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.adapt(SoftPalette.slate100).withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: RichText(
        text: TextSpan(
          style: TextStyle(fontSize: 14, color: context.adapt(SoftPalette.slate700), height: 1.5),
          children: [
            TextSpan(text: '$collName record '),
            TextSpan(text: '#$identifier ', style: TextStyle(fontWeight: FontWeight.w900, color: context.adapt(SoftPalette.slate900))),
            TextSpan(text: 'was $actionText.'),
          ],
        ),
      ),
    );
  }

  Widget _buildReasonPanel() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [SoftPalette.amber300.withValues(alpha: 0.15), SoftPalette.amber300.withValues(alpha: 0.05)],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SoftPalette.amber300.withValues(alpha: 0.2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline_rounded, size: 16, color: SoftPalette.orange500),
          const SizedBox(width: 12),
          Expanded(
            child: Text(entry.reason!, 
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: SoftPalette.orange500, fontStyle: FontStyle.italic)),
          ),
        ],
      ),
    );
  }

  Widget _buildDiffView(BuildContext context) {
    final oldData = entry.oldData ?? {};
    final newData = entry.newData ?? {};
    
    // Ignore internal keys
    const ignoredKeys = {
      'timestamp', 'lastUpdatedAt', 'hiveKey', 'localId', 'id', 'firestoreId',
      'submissionId', 'syncStatus', 'editHistory', 'searchTokens', 'searchKeywords'
    };

    final allKeys = {...oldData.keys, ...newData.keys}
        .where((k) => !ignoredKeys.contains(k))
        .toList();

    final List<Widget> changes = [];
    for (var k in allKeys) {
      final oldVal = oldData[k]?.toString() ?? 'None';
      final newVal = newData[k]?.toString() ?? 'None';
      if (oldVal != newVal) {
        changes.add(_buildDiffRow(context, _formatFieldLabel(k), oldVal, newVal));
      }
    }

    if (changes.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('MODIFICATIONS', 
          style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: context.adapt(SoftPalette.slate350), letterSpacing: 1.2)),
        const SizedBox(height: 12),
        ...changes,
      ],
    );
  }

  String _formatFieldLabel(String key) {
    return key
        .replaceAll('_', ' ')
        .replaceAllMapped(RegExp(r'([A-Z])'), (m) => ' ${m.group(0)}')
        .trim()
        .toUpperCase();
  }

  Widget _buildDiffRow(BuildContext context, String field, String oldVal, String newVal) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(width: 110, 
            child: Text(field, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: context.adapt(SoftPalette.slate550)), overflow: TextOverflow.ellipsis)),
          Expanded(
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(oldVal, style: const TextStyle(fontSize: 11, color: SoftPalette.red400, decoration: TextDecoration.lineThrough)),
                const SizedBox(width: 8),
                Icon(Icons.east_rounded, size: 12, color: context.adapt(SoftPalette.slate200)),
                const SizedBox(width: 8),
                Text(newVal, style: const TextStyle(fontSize: 11, color: SoftPalette.emerald350, fontWeight: FontWeight.w900)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
