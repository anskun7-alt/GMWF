// lib/pages/donations/donor_portal.dart

import 'package:flutter/material.dart';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:gmwf_ui/gmwf_ui.dart' show GEmptyIllustration, GEmptyIllustrationKind;
import 'package:gmwf/design/components/app_toast.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:gmwf/pages/donations/donations_shared.dart';
import 'package:gmwf/models/donation_models.dart';
import 'package:gmwf/services/donations_local_storage.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/theme/role_theme_provider.dart';
import 'package:gmwf/pages/donations/donations_screen.dart' show DonDS;

class DonorPortal extends StatefulWidget {
  const DonorPortal({super.key});

  @override
  State<DonorPortal> createState() => _DonorPortalState();
}

class _DonorPortalState extends State<DonorPortal> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  bool _isLoading = false;
  DonorRecord? _loggedDonor;
  List<DonationRecord> _donations = [];
  List<DonorRecord> _householdMembers = [];

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final name = _nameController.text.trim();
    final phone = _phoneController.text.trim();

    if (name.isEmpty || phone.isEmpty) {
      _showSnack('Please enter both name and phone number');
      return;
    }

    setState(() => _isLoading = true);

    try {
      // 1. Search for donor in Firestore /donors collection
      final query = await FirebaseFirestore.instance
          .collection('donors')
          .where('phones', arrayContains: phone)
          .get();

      DonorRecord? match;
      for (var doc in query.docs) {
        final d = DonorRecord.fromMap(doc.data());
        if (d.name.toLowerCase() == name.toLowerCase()) {
          match = d;
          break;
        }
      }

      if (match == null) {
        // Try exact phone match if arrayContains failed for some reason (legacy storage)
        final query2 = await FirebaseFirestore.instance
            .collection('donors')
            .where('phone', isEqualTo: phone)
            .get();
        
        for (var doc in query2.docs) {
          final d = DonorRecord.fromMap(doc.data());
          if (d.name.toLowerCase() == name.toLowerCase()) {
            match = d;
            break;
          }
        }
      }

      if (match != null) {
        setState(() => _loggedDonor = match);
        await _loadDonorData(match!);
      } else {
        _showSnack('No matching donor record found. Please check your details.');
      }
    } catch (e) {
      _showSnack('Connection error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _loadDonorData(DonorRecord donor) async {
    setState(() => _isLoading = true);
    try {
      // 1. Load donations across all branches (Collection Group Query)
      final donationsQuery = await FirebaseFirestore.instance
          .collectionGroup('donations')
          .where('donorId', isEqualTo: donor.id)
          .get();

      // collectionGroup returns both the branches/{b}/donations copy and the
      // top-level donations/ copy of each receipt; keep one per donation.
      final seen = <String>{};
      final List<DonationRecord> loadedDonations = [];
      for (final doc in donationsQuery.docs) {
        final data = doc.data();
        final key = (data['localId'] ?? doc.id).toString();
        if (!seen.add(key)) continue;
        loadedDonations.add(DonationRecord.fromMap(data, doc.id));
      }

      loadedDonations.sort((a, b) => b.date.compareTo(a.date));

      // 2. Load household members if applicable
      List<DonorRecord> members = [donor];
      if (donor.householdId != null && donor.householdId!.isNotEmpty) {
        final householdQuery = await FirebaseFirestore.instance
            .collection('donors')
            .where('householdId', isEqualTo: donor.householdId)
            .get();
        
        members = householdQuery.docs.map((doc) => DonorRecord.fromMap(doc.data())).toList();
      } else {
        // Search by phone for others sharing the same number
        final phoneQuery = await FirebaseFirestore.instance
            .collection('donors')
            .where('phones', arrayContains: donor.phone)
            .get();
        
        members = phoneQuery.docs.map((doc) => DonorRecord.fromMap(doc.data())).toList();
      }

      // If household members found, also load their donations?
      // For now, let's just focus on the primary donor but show others.

      setState(() {
        _donations = loadedDonations;
        _householdMembers = members;
      });
    } catch (e) {
      _showSnack('Error loading donation history: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _updateProfile() async {
    if (_loggedDonor == null) return;

    final name = _nameController.text.trim();
    final phone = _phoneController.text.trim();

    if (name.isEmpty || phone.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      final oldData = _loggedDonor!.toMap();
      final updatedDonor = _loggedDonor!.copyWith(
        name: name,
        phones: [phone], // For simplicity, setting primary phone
        lastUpdatedAt: DateTime.now().toIso8601String(),
      );

      // 1. Update Firestore root /donors
      await FirebaseFirestore.instance
          .collection('donors')
          .doc(updatedDonor.id)
          .set(updatedDonor.toMap(), SetOptions(merge: true));

      // 2. Update Firestore branch specific donor record
      if (updatedDonor.branchId.isNotEmpty) {
        await FirebaseFirestore.instance
            .collection('branches')
            .doc(updatedDonor.branchId)
            .collection('donors')
            .doc(updatedDonor.id)
            .set(updatedDonor.toMap(), SetOptions(merge: true));
      }

      // 3. Log Audit Trail
      await _logAuditTrail(updatedDonor, oldData, updatedDonor.toMap());

      // 4. Update local state
      setState(() => _loggedDonor = updatedDonor);
      _showSnack('Profile updated successfully');
    } catch (e) {
      _showSnack('Update failed: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _logAuditTrail(DonorRecord donor, Map<String, dynamic> oldData, Map<String, dynamic> newData) async {
    final logId = DateTime.now().millisecondsSinceEpoch.toString();
    final log = AuditLogEntry(
      id: logId,
      collection: 'donors',
      documentId: donor.id,
      action: 'update',
      userId: 'donor_portal_${donor.id}',
      username: '${donor.name} (Donor)',
      timestamp: DateTime.now().toIso8601String(),
      branchId: donor.branchId,
      oldData: oldData,
      newData: newData,
      reason: 'Self-update via Donor Portal',
    );

    await FirebaseFirestore.instance
        .collection('global_audit_logs')
        .doc(logId)
        .set(log.toMap());
  }

  void _showSnack(String msg) {
    AppToast.showSnackBar(context, SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [DS.navy900, DS.navy800],
          ),
        ),
        child: SafeArea(
          child: _loggedDonor == null ? _buildLogin() : _buildDashboard(),
        ),
      ),
    );
  }

  Widget _buildLogin() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 450),
          padding: const EdgeInsets.all(40),
          decoration: BoxDecoration(
            color: SoftPalette.gray50.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(DS.r2xl),
            border: Border.all(color: SoftPalette.gray50.withValues(alpha: 0.1)),
            boxShadow: [
              BoxShadow(
                color: SoftPalette.gray900.withValues(alpha: 0.3),
                blurRadius: 30,
                offset: const Offset(0, 15),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: DonDS.teal.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.volunteer_activism_rounded, color: DonDS.teal, size: 48),
              ),
              const SizedBox(height: 24),
              Text('GMWF Donor Portal', style: DS.display(color: SoftPalette.gray50)),
              const SizedBox(height: 8),
              Text('Access your donation history and profile', 
                  textAlign: TextAlign.center,
                  style: DS.body(color: SoftPalette.gray50.withValues(alpha: 0.6))),
              const SizedBox(height: 40),
              _buildTextField(
                controller: _nameController,
                label: 'Full Name',
                icon: Icons.person_rounded,
                hint: 'As on your receipt',
              ),
              const SizedBox(height: 20),
              _buildTextField(
                controller: _phoneController,
                label: 'Phone Number',
                icon: Icons.phone_android_rounded,
                hint: 'e.g. 03001234567',
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 40),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _login,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: DonDS.teal,
                    foregroundColor: SoftPalette.gray50,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.rLg)),
                    elevation: 0,
                  ),
                  child: _isLoading 
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: SoftPalette.gray50, strokeWidth: 2))
                    : const Text('Sign In', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 24),
              Text('Secured by GMWF System', style: DS.caption(color: SoftPalette.gray50.withValues(alpha: 0.4))),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDashboard() {
    return Column(
      children: [
        _buildHeader(),
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildStatsSection(),
                const SizedBox(height: 32),
                _buildActionCards(),
                const SizedBox(height: 32),
                _buildDonationsList(),
                const SizedBox(height: 32),
                _buildHouseholdSection(),
                const SizedBox(height: 40),
                Center(
                  child: Text('Official GMWF Donor Records', 
                    style: DS.caption(color: SoftPalette.gray50.withValues(alpha: 0.2))),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatsSection() {
    final totalAmount = _donations.fold<double>(0, (sum, d) => sum + d.amount);
    final count = _donations.length;
    final avg = count == 0 ? 0.0 : totalAmount / count;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('SUMMARY', style: DS.label(color: SoftPalette.gray50.withValues(alpha: 0.6)).copyWith(letterSpacing: 1.5)),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth > 600;
            return isWide 
              ? Row(
                  children: [
                    Expanded(child: _buildStatCard('Total Contributed', 'PKR ${NumberFormat('#,###').format(totalAmount)}', Icons.volunteer_activism_rounded, DonDS.teal)),
                    const SizedBox(width: 16),
                    Expanded(child: _buildStatCard('Donations Count', count.toString(), Icons.history_toggle_off_rounded, SoftPalette.yellow200)),
                    const SizedBox(width: 16),
                    Expanded(child: _buildStatCard('Average Donation', 'PKR ${NumberFormat('#,###').format(avg)}', Icons.analytics_rounded, SoftPalette.indigo500)),
                  ],
                )
              : Column(
                  children: [
                    _buildStatCard('Total Contributed', 'PKR ${NumberFormat('#,###').format(totalAmount)}', Icons.volunteer_activism_rounded, DonDS.teal),
                    const SizedBox(height: 12),
                    _buildStatCard('Donations Count', count.toString(), Icons.history_toggle_off_rounded, SoftPalette.yellow200),
                    const SizedBox(height: 12),
                    _buildStatCard('Average Donation', 'PKR ${NumberFormat('#,###').format(avg)}', Icons.analytics_rounded, SoftPalette.indigo500),
                  ],
                );
          },
        ),
      ],
    );
  }

  Widget _buildStatCard(String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: SoftPalette.gray50.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(DS.r2xl),
        border: Border.all(color: SoftPalette.gray50.withValues(alpha: 0.08)),
        boxShadow: [
          BoxShadow(
            color: SoftPalette.gray900.withValues(alpha: 0.1),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(DS.rLg),
              border: Border.all(color: color.withValues(alpha: 0.2)),
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: DS.caption(color: SoftPalette.gray50.withValues(alpha: 0.4))),
                const SizedBox(height: 4),
                Text(value, style: DS.heading(color: SoftPalette.gray50).copyWith(fontSize: 18, fontFamily: 'DMMono')),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      decoration: BoxDecoration(
        color: SoftPalette.gray50.withValues(alpha: 0.05),
        border: Border(bottom: BorderSide(color: SoftPalette.gray50.withValues(alpha: 0.1))),
      ),
      child: Row(
        children: [
          Container(
            width: 56, height: 56,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [DonDS.teal, DonDS.teal.withValues(alpha: 0.7)]),
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: DonDS.teal.withValues(alpha: 0.3), blurRadius: 15, spreadRadius: 2)],
            ),
            child: Center(
              child: Text(_loggedDonor!.name[0].toUpperCase(), 
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: SoftPalette.gray50)),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Donor Portal', style: DS.label(color: DonDS.teal).copyWith(fontSize: 10, letterSpacing: 2)),
                Text(_loggedDonor!.name, style: DS.heading(color: SoftPalette.gray50).copyWith(fontSize: 22)),
                Text(_loggedDonor!.phone, style: DS.caption(color: SoftPalette.gray50.withValues(alpha: 0.4))),
              ],
            ),
          ),
          _buildGlassButton(
            icon: Icons.logout_rounded,
            onTap: () => setState(() => _loggedDonor = null),
            color: SoftPalette.red400,
          ),
        ],
      ),
    );
  }

  Widget _buildActionCards() {
    return Row(
      children: [
        Expanded(
          child: _buildActionCard(
            'Edit Profile',
            'Update your name and contact',
            Icons.edit_note_rounded,
            DonDS.teal,
            _showEditProfileDialog,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _buildActionCard(
            'Support',
            'Contact our foundation',
            Icons.help_outline_rounded,
            SoftPalette.indigo500,
            () => _showSnack('Support contact: 0331-8525333'),
          ),
        ),
      ],
    );
  }

  Widget _buildActionCard(String title, String sub, IconData icon, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(DS.rLg),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(DS.rLg),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 16),
            Text(title, style: DS.heading(color: SoftPalette.gray50).copyWith(fontSize: 16)),
            const SizedBox(height: 4),
            Text(sub, style: DS.caption(color: SoftPalette.gray50.withValues(alpha: 0.5))),
          ],
        ),
      ),
    );
  }

  void _showEditProfileDialog() {
    final nameEdit = TextEditingController(text: _loggedDonor!.name);
    final phoneEdit = TextEditingController(text: _loggedDonor!.phone);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: DS.navy800,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.rXl)),
        title: Text('Edit Profile', style: DS.heading(color: SoftPalette.gray50)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildTextField(
              controller: nameEdit,
              label: 'Full Name',
              icon: Icons.person_rounded,
            ),
            const SizedBox(height: 16),
            _buildTextField(
              controller: phoneEdit,
              label: 'Phone Number',
              icon: Icons.phone_android_rounded,
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 12),
            Text('Updates will be recorded in the audit trail.', 
                style: DS.caption(color: SoftPalette.gray50.withValues(alpha: 0.3)).copyWith(fontSize: 10)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _nameController.text = nameEdit.text;
              _phoneController.text = phoneEdit.text;
              _updateProfile();
            },
            style: ElevatedButton.styleFrom(backgroundColor: DonDS.teal),
            child: const Text('Save Changes'),
          ),
        ],
      ),
    );
  }

  Widget _buildGlassButton({required IconData icon, required VoidCallback onTap, Color color = SoftPalette.gray50}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.1)),
        ),
        child: Icon(icon, color: color, size: 20),
      ),
    );
  }

  Widget _buildDonationsList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('MY DONATIONS', style: DS.label(color: SoftPalette.gray50.withValues(alpha: 0.6)).copyWith(letterSpacing: 1.5)),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: DonDS.teal.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: DonDS.teal.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.cloud_done_rounded, color: DonDS.teal, size: 12),
                  const SizedBox(width: 4),
                  Text('VERIFIED', style: DS.caption(color: DonDS.teal).copyWith(fontSize: 9, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_donations.isEmpty)
          _buildEmptyHistory()
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _donations.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, i) => _buildDonationCard(_donations[i]),
          ),
      ],
    );
  }

  Widget _buildEmptyHistory() {
    return Container(
      padding: const EdgeInsets.all(60),
      width: double.infinity,
      decoration: BoxDecoration(
        color: SoftPalette.gray50.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(DS.rLg),
        border: Border.all(color: SoftPalette.gray50.withValues(alpha: 0.05), style: BorderStyle.none),
      ),
      child: Column(
        children: [
          const GEmptyIllustration(
            GEmptyIllustrationKind.finance,
            size: 144,
            fallbackIcon: Icons.history_rounded,
          ),
          const SizedBox(height: 16),
          Text('No donation history found yet', style: DS.body(color: SoftPalette.gray50.withValues(alpha: 0.3))),
          const SizedBox(height: 8),
          Text('If you recently donated, please wait for sync.', 
              style: DS.caption(color: SoftPalette.gray50.withValues(alpha: 0.15))),
        ],
      ),
    );
  }

  Widget _buildDonationCard(DonationRecord d) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: SoftPalette.gray50.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(DS.rLg),
        border: Border.all(color: SoftPalette.gray50.withValues(alpha: 0.08)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: d.category.lightColor.withValues(alpha: 0.05),
                  shape: BoxShape.circle,
                ),
                child: Icon(d.category.icon, color: d.category.color, size: 24),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(d.category.label, style: DS.heading(color: SoftPalette.gray50).copyWith(fontSize: 16)),
                    const SizedBox(height: 2),
                    Text(DateFormat('EEEE, MMM dd, yyyy').format(DateTime.parse(d.date)), 
                        style: DS.caption(color: SoftPalette.gray50.withValues(alpha: 0.4))),
                  ],
                ),
              ),
              Text('PKR ${NumberFormat('#,###').format(d.amount)}', 
                  style: DS.heading(color: DonDS.teal).copyWith(fontSize: 18, fontFamily: 'DMMono')),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Divider(color: SoftPalette.gray50A10, height: 1),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildDetailItem('RECEIPT', d.receiptNo, Icons.confirmation_number_outlined),
              _buildDetailItem('METHOD', d.paymentMethod, Icons.payment_rounded),
              _buildDetailItem('BRANCH', d.branchName, Icons.location_on_outlined),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDetailItem(String label, String value, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 12, color: SoftPalette.gray50.withValues(alpha: 0.3)),
        const SizedBox(width: 6),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: DS.caption(color: SoftPalette.gray50.withValues(alpha: 0.3)).copyWith(fontSize: 8, letterSpacing: 0.5)),
            Text(value.toUpperCase(), style: DS.label(color: SoftPalette.gray50.withValues(alpha: 0.7)).copyWith(fontSize: 10)),
          ],
        ),
      ],
    );
  }

  Widget _buildHouseholdSection() {
    if (_householdMembers.length <= 1) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('HOUSEHOLD DATA', style: DS.label(color: SoftPalette.gray50.withValues(alpha: 0.6)).copyWith(letterSpacing: 1.5)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: SoftPalette.indigo600.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(4)),
              child: Text('LINKED ACCOUNTS', style: TextStyle(fontSize: 8, color: SoftPalette.indigo350, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: SoftPalette.indigo600.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(DS.rLg),
            border: Border.all(color: SoftPalette.indigo600.withValues(alpha: 0.1)),
          ),
          child: Column(
            children: _householdMembers.map((m) {
              final isMe = m.id == _loggedDonor!.id;
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(
                  children: [
                    Container(
                      width: 32, height: 32,
                      decoration: BoxDecoration(
                        color: isMe ? DonDS.teal.withValues(alpha: 0.1) : SoftPalette.gray50.withValues(alpha: 0.05),
                        shape: BoxShape.circle,
                      ),
                      child: Center(child: Text(m.name[0], style: TextStyle(fontSize: 12, color: isMe ? DonDS.teal : SoftPalette.gray50A38, fontWeight: FontWeight.bold))),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(m.name, style: DS.body(color: isMe ? SoftPalette.gray50 : SoftPalette.gray50A70)),
                              if (isMe) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                  decoration: BoxDecoration(color: DonDS.teal, borderRadius: BorderRadius.circular(4)),
                                  child: const Text('YOU', style: TextStyle(fontSize: 7, color: SoftPalette.gray50, fontWeight: FontWeight.bold)),
                                ),
                              ],
                            ],
                          ),
                          Text(m.phone, style: DS.caption(color: SoftPalette.gray50.withValues(alpha: 0.2))),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded, size: 16, color: SoftPalette.gray50.withValues(alpha: 0.1)),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    String? hint,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: DS.label(color: SoftPalette.gray50.withValues(alpha: 0.6))),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          inputFormatters: keyboardType == TextInputType.phone
              ? [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(11)]
              : null,
          style: const TextStyle(color: SoftPalette.gray50),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: SoftPalette.gray50.withValues(alpha: 0.2)),
            prefixIcon: Icon(icon, color: SoftPalette.gray50.withValues(alpha: 0.4), size: 20),
            filled: true,
            fillColor: SoftPalette.gray50.withValues(alpha: 0.05),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(DS.rMd),
              borderSide: BorderSide(color: SoftPalette.gray50.withValues(alpha: 0.1)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(DS.rMd),
              borderSide: BorderSide(color: SoftPalette.gray50.withValues(alpha: 0.1)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(DS.rMd),
              borderSide: const BorderSide(color: DonDS.teal),
            ),
          ),
        ),
      ],
    );
  }
}
