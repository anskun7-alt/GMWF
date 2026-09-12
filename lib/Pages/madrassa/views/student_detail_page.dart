import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import '../../../theme/role_theme_provider.dart';
import '../../../widgets/read_only_document_tile.dart';
import '../../../services/image_upload_service.dart';
import '../../../services/user_theme_service.dart';
import '../../../services/local_storage_service.dart';
import '../utils/madrassa_local_storage.dart';
import '../dialogs/enrollment_dialog.dart';
import '../madrassa_strings.dart';
import '../widgets/madrassa_status_menu.dart';

class StudentDetailPage extends StatefulWidget {
  final Map<String, dynamic> studentData;
  final String branchId;
  final bool isAdmin;
  final String username;
  final String role;

  const StudentDetailPage({
    super.key,
    required this.studentData,
    required this.branchId,
    required this.isAdmin,
    required this.username,
    this.role = 'Madrassa Teacher',
  });

  @override
  State<StudentDetailPage> createState() => _StudentDetailPageState();
}

class _StudentDetailPageState extends State<StudentDetailPage> {
  late Map<String, dynamic> _data;

  @override
  void initState() {
    super.initState();
    _data = Map<String, dynamic>.from(widget.studentData);
  }

  DateTime _parseDate(dynamic val) {
    if (val is Timestamp) return val.toDate();
    if (val is String) return DateTime.tryParse(val) ?? DateTime.now();
    return DateTime.now();
  }

  Widget _buildAvatarFallback(String? name, {double fontSize = 28}) {
    final initial = name != null && name.isNotEmpty ? name[0].toUpperCase() : '?';
    return Container(
      color: const Color(0xFF008080).withValues(alpha: 0.15),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: const Color(0xFF008080),
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildDetailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: const Color(0xFF008080)),
          const SizedBox(width: 12),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey.shade600,
              fontWeight: FontWeight.w500,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1E293B),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final studentId = _data['id']?.toString() ?? '';
    if (!Hive.isBoxOpen(LocalStorageService.madrassaStudentsBox)) {
      return FutureBuilder<Box>(
        future: LocalStorageService.ensureBoxOpen(LocalStorageService.madrassaStudentsBox),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator(color: Color(0xFF00796B))),
            );
          }
          return _buildDetailPageWithBox(context, snapshot.data!, studentId);
        },
      );
    }
    return _buildDetailPageWithBox(context, Hive.box(LocalStorageService.madrassaStudentsBox), studentId);
  }

  Widget _buildDetailPageWithBox(BuildContext context, Box studentsBox, String studentId) {
    return ValueListenableBuilder(
      valueListenable: studentsBox.listenable(),
      builder: (context, Box box, _) {
        final cached = MadrassaLocalStorage.getStudentCached(widget.branchId, studentId);
        if (cached != null) {
          _data = {'id': studentId, ...cached};
        }

        final name = _data['name'] ?? 'Student';
        final rollNumber = _data['rollNumber'] ?? '?';
        final className = _data['class'] ?? 'Hifz';
        final photoUrl = _data['photoUrl']?.toString();
        final status = _data['status'] ?? 'active';

        final currentLines = int.tryParse(_data['currentLines']?.toString() ?? '0') ?? 0;
        final prevLines = int.tryParse(_data['prevHifzLines']?.toString() ?? '0') ?? 0;
        final totalLines = currentLines + prevLines;
        const maxLines = 8640;
        final pct = ((totalLines / maxLines) * 100).clamp(0.0, 100.0).toStringAsFixed(1);

        final String? bFormUrl = _data['bFormUrl'] ?? _data['bFormBase64'];
        final String? guardianCnicUrl = _data['guardianCnicUrl'] ?? _data['guardianCnicBase64'];
        final String? hifzCertificateUrl = _data['hifzCertificateUrl'] ?? _data['hifzCertificateBase64'];

        final isDark = UserThemeService.isDarkMode(widget.username);
        final scaffoldBg = isDark ? const Color(0xFF0F172A) : const Color(0xFFF8F9FD);
        final cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;
        final textPrimary = isDark ? Colors.white : const Color(0xFF1E293B);
        final borderColor = isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);

        return Scaffold(
          backgroundColor: scaffoldBg,
          appBar: AppBar(
            backgroundColor: cardBg,
            elevation: 0,
            scrolledUnderElevation: 0,
            leading: IconButton(
              icon: Icon(Icons.arrow_back_rounded, color: textPrimary),
              onPressed: () => Navigator.pop(context),
            ),
            title: Text(
              name,
              style: TextStyle(
                color: textPrimary,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
            actions: [
              StatusActionMenu(
                student: _data,
                branchId: widget.branchId,
                isAdmin: widget.isAdmin,
                t: RoleThemeScope.dataOf(context),
                username: widget.username,
                role: widget.role,
              ),
              IconButton(
                icon: const Icon(Icons.edit_note_rounded, color: Color(0xFF008080)),
                tooltip: 'Edit Student Details',
                onPressed: () => showAddStudentDialog(
                  context,
                  widget.branchId,
                  student: _data,
                  username: widget.username,
                  role: widget.role,
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Center(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 800),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header card
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF006666), Color(0xFF008080)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF008080).withValues(alpha: 0.25),
                            blurRadius: 16,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 72,
                            height: 72,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white.withValues(alpha: 0.4), width: 2.5),
                            ),
                            child: ClipOval(
                              child: () {
                                final str = photoUrl?.toString().trim();
                                final bytes = ImageUploadService.decodeBase64ToBytes(str);
                                if (bytes != null) {
                                  return Image.memory(
                                    bytes,
                                    fit: BoxFit.cover,
                                    width: 72,
                                    height: 72,
                                    errorBuilder: (_, __, ___) => _buildAvatarFallback(name),
                                  );
                                } else if (str != null && str.startsWith('http')) {
                                  return Image.network(
                                    str,
                                    fit: BoxFit.cover,
                                    width: 72,
                                    height: 72,
                                    errorBuilder: (_, __, ___) => _buildAvatarFallback(name),
                                  );
                                }
                                return _buildAvatarFallback(name);
                              }(),
                            ),
                          ),
                          const SizedBox(width: 18),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  name,
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Roll #: $rollNumber • Class: $className',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.9),
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    'Status: ${status.toUpperCase()}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Progress card
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Memorization Progress',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF1E293B),
                                ),
                              ),
                              Text(
                                '$pct%',
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF008080),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: LinearProgressIndicator(
                              value: (totalLines / maxLines).clamp(0.0, 1.0),
                              backgroundColor: const Color(0xFFF1F5F9),
                              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF008080)),
                              minHeight: 10,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Current: $currentLines lines',
                                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                              ),
                              Text(
                                'Prior Hifz: $prevLines lines',
                                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                              ),
                              Text(
                                'Total: $totalLines / $maxLines',
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Personal info card
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.person_outline_rounded, color: Color(0xFF008080)),
                              SizedBox(width: 10),
                              Text(
                                'Student Personal Details',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF1E293B),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          const Divider(),
                          _buildDetailRow(
                            Icons.credit_card_rounded,
                            'Student CNIC / B-Form #',
                            _data['studentCnic']?.toString().isNotEmpty == true ? _data['studentCnic'] : 'Not Provided',
                          ),
                          _buildDetailRow(
                            Icons.calendar_today_rounded,
                            'Join Date',
                            _data['joinDate'] != null ? DateFormat('dd MMMM yyyy').format(_parseDate(_data['joinDate'])) : 'Not Provided',
                          ),
                          if (_data['hasPrevMadrassa'] == true) ...[
                            _buildDetailRow(
                              Icons.school_outlined,
                              'Previous Madrassa',
                              _data['prevMadrassaName'] ?? 'Not Provided',
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Guardian info card
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.family_restroom_rounded, color: Color(0xFF008080)),
                              SizedBox(width: 10),
                              Text(
                                'Guardian / Parent Details',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF1E293B),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          const Divider(),
                          _buildDetailRow(
                            Icons.badge_outlined,
                            'Guardian Name',
                            _data['guardianName'] ?? 'Not Provided',
                          ),
                          _buildDetailRow(
                            Icons.credit_card_outlined,
                            'Guardian CNIC',
                            _data['guardianCnic'] ?? 'Not Provided',
                          ),
                          _buildDetailRow(
                            Icons.phone_outlined,
                            'Contact Phone',
                            _data['contactPhone'] ?? _data['phone'] ?? 'Not Provided',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Documents Card
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.folder_shared_outlined, color: Color(0xFF008080)),
                              const SizedBox(width: 10),
                              const Text(
                                'Student & Guardian Documents',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF1E293B),
                                ),
                              ),
                              const Spacer(),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade100,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Text(
                                  'Read Only',
                                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          const Divider(),
                          const SizedBox(height: 8),
                          ReadOnlyDocumentTile(
                            label: 'Guardian CNIC Document',
                            icon: Icons.badge_outlined,
                            documentUri: guardianCnicUrl,
                          ),
                          const SizedBox(height: 12),
                          ReadOnlyDocumentTile(
                            label: 'B-Form / Birth Certificate',
                            icon: Icons.assignment_ind_outlined,
                            documentUri: bFormUrl,
                          ),
                          if (hifzCertificateUrl != null && hifzCertificateUrl.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            ReadOnlyDocumentTile(
                              label: 'Certificate of Hifz Completion',
                              icon: Icons.workspace_premium_outlined,
                              documentUri: hifzCertificateUrl,
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
