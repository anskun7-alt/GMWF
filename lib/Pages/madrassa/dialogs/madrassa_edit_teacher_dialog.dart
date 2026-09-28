// lib/pages/madrassa/dialogs/madrassa_edit_teacher_dialog.dart
//
// Allows Madrassa Principals to edit any teacher's details:
// full name, email, phone, CNIC, address, teaching specialization,
// shift/sessions, active status, profile picture, ID doc, and optional password reset.

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../services/image_upload_service.dart';
import '../../../services/offline_auth_service.dart';
import '../../../services/local_storage_service.dart';
import '../utils/madrassa_local_storage.dart';

/// Shows the Edit Teacher dialog. Returns `true` if changes were saved.
Future<bool?> showMadrassaEditTeacherDialog(
  BuildContext context, {
  required String branchId,
  required Map<String, dynamic> teacher,
  required String principalUsername,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => MadrassaEditTeacherDialog(
      branchId: branchId,
      teacher: teacher,
      principalUsername: principalUsername,
    ),
  );
}

class MadrassaEditTeacherDialog extends StatefulWidget {
  final String branchId;
  final Map<String, dynamic> teacher;
  final String principalUsername;

  const MadrassaEditTeacherDialog({
    super.key,
    required this.branchId,
    required this.teacher,
    required this.principalUsername,
  });

  @override
  State<MadrassaEditTeacherDialog> createState() => _MadrassaEditTeacherDialogState();
}

class _MadrassaEditTeacherDialogState extends State<MadrassaEditTeacherDialog>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _nameCtrl;
  late final TextEditingController _usernameCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _cnicCtrl;
  late final TextEditingController _addressCtrl;
  late final TextEditingController _passwordCtrl;

  late String _session;
  late String _teachingType;
  late bool _isActive;

  Uint8List? _profileBytes;
  String? _profileBase64;
  String? _idDocBase64;

  bool _obscurePass = true;
  bool _saving = false;

  late final AnimationController _anim;
  late final Animation<double> _fade;

  static const _emerald = Color(0xFF0F766E);
  static const _danger = Color(0xFFEF4444);

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 300));
    _fade = CurvedAnimation(parent: _anim, curve: Curves.easeOut);
    _anim.forward();

    final t = widget.teacher;
    var initialName = (t['displayName'] ?? t['name'] ?? t['username'] ?? '').toString();
    final lowerInitial = initialName.toLowerCase().trim();
    if (lowerInitial == 'hifz' || lowerInitial == 'nazra' || lowerInitial == 'both' || lowerInitial == 'hifz & nazra') {
      final fallback = (t['displayName'] ?? t['username'] ?? '').toString();
      initialName = (fallback.toLowerCase().trim() == lowerInitial) ? '' : fallback;
    }
    _nameCtrl = TextEditingController(text: initialName);
    _usernameCtrl = TextEditingController(text: (t['username'] ?? '').toString());
    _emailCtrl = TextEditingController(text: (t['email'] ?? '').toString());
    _phoneCtrl = TextEditingController(text: (t['phone'] ?? '').toString());
    _cnicCtrl = TextEditingController(text: (t['identification'] ?? t['cnic'] ?? '').toString());
    _addressCtrl = TextEditingController(text: (t['address'] ?? '').toString());
    _passwordCtrl = TextEditingController();

    // Session shift
    final s = (t['session'] ?? 'morning').toString().toLowerCase();
    _session = ['morning', 'evening', 'night', 'all'].contains(s) ? s : 'morning';

    // Teaching specialization
    final rawSpec = (t['specialization'] ?? t['teachingType'] ?? t['name'] ?? 'hifz').toString().toLowerCase();
    if (rawSpec.contains('both') || rawSpec.contains('all')) {
      _teachingType = 'both';
    } else if (rawSpec.contains('nazra')) {
      _teachingType = 'nazra';
    } else {
      _teachingType = 'hifz';
    }

    _isActive = t['status']?.toString().toLowerCase() != 'inactive' &&
        t['isActive'] != false &&
        t['status']?.toString().toLowerCase() != 'offboarded';

    _profileBase64 = (t['profilePictureBase64'] ?? t['profilePictureUrl'] ?? t['avatarUrl'])?.toString();
    _idDocBase64 = (t['identificationBase64'] ?? t['idDocBase64'])?.toString();
  }

  @override
  void dispose() {
    _anim.dispose();
    _nameCtrl.dispose();
    _usernameCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _cnicCtrl.dispose();
    _addressCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  bool _isDark(BuildContext ctx) => Theme.of(ctx).brightness == Brightness.dark;
  Color _bg(BuildContext ctx) => _isDark(ctx) ? const Color(0xFF0F172A) : Colors.white;
  Color _card(BuildContext ctx) => _isDark(ctx) ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC);
  Color _bord(BuildContext ctx) => _isDark(ctx) ? const Color(0xFF334155) : const Color(0xFFE2E8F0);
  Color _text(BuildContext ctx) => _isDark(ctx) ? const Color(0xFFF1F5F9) : const Color(0xFF0F172A);
  Color _muted(BuildContext ctx) => _isDark(ctx) ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

  Future<void> _pickPhoto() async {
    try {
      final source = await ImageUploadService.showSourceDialog(context, title: 'Profile Photo');
      if (source == null) return;
      final b64 = await ImageUploadService.pickAndProcessImage(source: source, quality: 85);
      if (b64 == null || b64.isEmpty || !mounted) return;
      final bytes = ImageUploadService.decodeBase64ToBytes(b64);
      if (bytes == null) return;
      setState(() {
        _profileBytes = bytes;
        _profileBase64 = b64;
      });
      _snack('Profile photo updated ✓', success: true);
    } catch (e) {
      _snack('Could not load image: $e', error: true);
    }
  }

  Future<void> _pickIdDoc() async {
    try {
      final source = await ImageUploadService.showSourceDialog(context, title: 'Upload CNIC / ID Document');
      if (source == null) return;
      final b64 = await ImageUploadService.pickAndProcessImage(source: source, quality: 90);
      if (b64 == null || b64.isEmpty || !mounted) return;
      setState(() => _idDocBase64 = b64);
      _snack('ID document updated ✓', success: true);
    } catch (e) {
      _snack('Could not pick document: $e', error: true);
    }
  }

  void _snack(String msg, {bool error = false, bool success = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        Icon(
          error ? Icons.error_outline : success ? Icons.check_circle_outline : Icons.info_outline,
          color: Colors.white,
          size: 17,
        ),
        const SizedBox(width: 9),
        Expanded(child: Text(msg, style: const TextStyle(fontSize: 13))),
      ]),
      backgroundColor: error ? _danger : success ? _emerald : const Color(0xFF37474F),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(16),
      duration: const Duration(seconds: 3),
    ));
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final teacherId = widget.teacher['id'] ?? widget.teacher['uid'] ?? _usernameCtrl.text.trim();
    final updatedData = Map<String, dynamic>.from(widget.teacher);

    final newPass = _passwordCtrl.text.trim();

    final cleanUsername = _usernameCtrl.text.trim();
    final cleanUsernameLower = cleanUsername.toLowerCase();
    final cleanEmail = _emailCtrl.text.trim().toLowerCase();

    updatedData['displayName'] = _nameCtrl.text.trim();
    updatedData['name'] = _nameCtrl.text.trim();
    updatedData['username'] = cleanUsername;
    updatedData['usernameLower'] = cleanUsernameLower;
    updatedData['email'] = cleanEmail;
    updatedData['phone'] = _phoneCtrl.text.trim();
    updatedData['identification'] = _cnicCtrl.text.trim();
    updatedData['cnic'] = _cnicCtrl.text.trim();
    updatedData['address'] = _addressCtrl.text.trim();
    updatedData['specialization'] = _teachingType;
    updatedData['teachingType'] = _teachingType;
    updatedData['session'] = _session;
    updatedData['sessions'] = _session == 'all' ? ['morning', 'evening', 'night'] : [_session];
    updatedData['isActive'] = _isActive;
    updatedData['status'] = _isActive ? 'active' : 'inactive';
    updatedData['accountStatus'] = _isActive ? 'active' : 'inactive';
    updatedData['lastUpdatedBy'] = widget.principalUsername;
    updatedData['lastUpdatedAt'] = DateTime.now().toIso8601String();

    if (_profileBase64 != null) {
      updatedData['profilePictureBase64'] = _profileBase64;
      updatedData['profilePictureUrl'] = _profileBase64;
      updatedData['avatarUrl'] = _profileBase64;
    }
    if (_idDocBase64 != null) {
      updatedData['identificationBase64'] = _idDocBase64;
      updatedData['idDocBase64'] = _idDocBase64;
    }

    try {
      // 1. Password change if requested
      if (newPass.isNotEmpty) {
        updatedData['password'] = newPass;
        updatedData['passwordHash'] = LocalStorageService.hashPassword(newPass);
        if (cleanEmail.isNotEmpty) {
          await OfflineAuthService.saveCredentials(
            usernameOrEmail: cleanEmail,
            password: newPass,
            userData: updatedData,
            setAsLastLoggedIn: false,
          );
        }
        if (cleanUsernameLower.isNotEmpty && cleanUsernameLower != cleanEmail) {
          await OfflineAuthService.saveCredentials(
            usernameOrEmail: cleanUsernameLower,
            password: newPass,
            userData: updatedData,
            setAsLastLoggedIn: false,
          );
        }
        try {
          await FirebaseFirestore.instance.collection('users').doc(teacherId.toString()).set({
            'password': newPass,
            'passwordHash': LocalStorageService.hashPassword(newPass),
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        } catch (_) {}
      }

      // Also ensure LocalStorageService indexes the updated user offline across all key variants
      await LocalStorageService.saveLocalUser(updatedData);

      // 2. Save profile in Madrassa Local Storage and enqueue sync
      await MadrassaLocalStorage.saveTeacherProfileLocalAndSync(
        branchId: widget.branchId,
        teacherId: teacherId.toString(),
        teacherData: updatedData,
      );

      if (!mounted) return;
      _snack('Teacher details updated successfully ✓', success: true);
      Navigator.of(context).pop(true);
    } catch (e) {
      _snack('Failed to update teacher: $e', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context);
    final bg = _bg(context);
    final card = _card(context);
    final bord = _bord(context);
    final text = _text(context);
    final muted = _muted(context);

    return FadeTransition(
      opacity: _fade,
      child: Dialog(
        backgroundColor: bg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 820),
          child: Stack(
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildHeader(dark, bord),
                  Flexible(
                    child: SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const SizedBox(height: 16),
                            _buildPhotoSection(dark, bord),
                            const SizedBox(height: 16),
                            _buildSection(
                              dark: dark,
                              card: card,
                              bord: bord,
                              text: text,
                              muted: muted,
                              icon: Icons.person_outline_rounded,
                              accent: _emerald,
                              title: 'Basic Info & Credentials',
                              child: Column(
                                children: [
                                  _field(
                                    dark: dark,
                                    bord: bord,
                                    text: text,
                                    muted: muted,
                                    ctrl: _nameCtrl,
                                    label: 'Full Name *',
                                    icon: Icons.badge_outlined,
                                    validator: (v) => (v?.trim().isEmpty ?? true) ? 'Required' : null,
                                  ),
                                  const SizedBox(height: 12),
                                  _field(
                                    dark: dark,
                                    bord: bord,
                                    text: text,
                                    muted: muted,
                                    ctrl: _usernameCtrl,
                                    label: 'Username *',
                                    icon: Icons.alternate_email_rounded,
                                    validator: (v) => (v?.trim().isEmpty ?? true) ? 'Required' : null,
                                  ),
                                  const SizedBox(height: 12),
                                  _field(
                                    dark: dark,
                                    bord: bord,
                                    text: text,
                                    muted: muted,
                                    ctrl: _emailCtrl,
                                    label: 'Email *',
                                    icon: Icons.mail_outline_rounded,
                                    keyboardType: TextInputType.emailAddress,
                                    validator: (v) {
                                      if (v == null || v.trim().isEmpty) return 'Required';
                                      if (!v.contains('@')) return 'Invalid email';
                                      return null;
                                    },
                                  ),
                                  const SizedBox(height: 12),
                                  _passwordField(dark: dark, bord: bord, text: text, muted: muted),
                                ],
                              ),
                            ),
                            const SizedBox(height: 14),
                            _buildSection(
                              dark: dark,
                              card: card,
                              bord: bord,
                              text: text,
                              muted: muted,
                              icon: Icons.contact_phone_outlined,
                              accent: const Color(0xFF7C3AED),
                              title: 'Personal Details & Contact',
                              child: Column(
                                children: [
                                  _field(
                                    dark: dark,
                                    bord: bord,
                                    text: text,
                                    muted: muted,
                                    ctrl: _cnicCtrl,
                                    label: 'CNIC / National ID',
                                    icon: Icons.credit_card_outlined,
                                    hint: '42101-1234567-8',
                                    keyboardType: TextInputType.number,
                                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d-]'))],
                                  ),
                                  const SizedBox(height: 12),
                                  _field(
                                    dark: dark,
                                    bord: bord,
                                    text: text,
                                    muted: muted,
                                    ctrl: _phoneCtrl,
                                    label: 'Phone Number',
                                    icon: Icons.phone_outlined,
                                    hint: '03001234567',
                                    keyboardType: TextInputType.phone,
                                  ),
                                  const SizedBox(height: 12),
                                  _field(
                                    dark: dark,
                                    bord: bord,
                                    text: text,
                                    muted: muted,
                                    ctrl: _addressCtrl,
                                    label: 'Residential Address',
                                    icon: Icons.home_outlined,
                                    maxLines: 2,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 14),
                            _buildSection(
                              dark: dark,
                              card: card,
                              bord: bord,
                              text: text,
                              muted: muted,
                              icon: Icons.menu_book_rounded,
                              accent: const Color(0xFF0D9488),
                              title: 'Teaching Specialization',
                              child: _teachingTypeSelector(dark, bord, text, muted),
                            ),
                            const SizedBox(height: 14),
                            _buildSection(
                              dark: dark,
                              card: card,
                              bord: bord,
                              text: text,
                              muted: muted,
                              icon: Icons.access_time_rounded,
                              accent: const Color(0xFF0284C7),
                              title: 'Teaching Shift',
                              child: _sessionSelector(dark, bord, text, muted),
                            ),
                            const SizedBox(height: 14),
                            _buildSection(
                              dark: dark,
                              card: card,
                              bord: bord,
                              text: text,
                              muted: muted,
                              icon: Icons.toggle_on_outlined,
                              accent: _isActive ? Colors.green : Colors.grey,
                              title: 'Account Status',
                              child: SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(
                                  _isActive ? 'Teacher Active & Teaching' : 'Teacher Inactive (Suspended)',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: _isActive ? Colors.green : Colors.red,
                                  ),
                                ),
                                subtitle: Text(
                                  _isActive
                                      ? 'Teacher can login, take attendance, and manage student logs.'
                                      : 'Teacher account is paused and cannot submit daily entries.',
                                  style: TextStyle(fontSize: 11.5, color: muted),
                                ),
                                value: _isActive,
                                activeThumbColor: _emerald,
                                onChanged: (val) => setState(() => _isActive = val),
                              ),
                            ),
                            const SizedBox(height: 14),
                            _buildSection(
                              dark: dark,
                              card: card,
                              bord: bord,
                              text: text,
                              muted: muted,
                              icon: Icons.folder_outlined,
                              accent: const Color(0xFFD97706),
                              title: 'Documents & CNIC Attachment',
                              child: _docTile(dark, bord, text, muted),
                            ),
                            const SizedBox(height: 24),
                            SizedBox(
                              height: 50,
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _emerald,
                                  foregroundColor: Colors.white,
                                  elevation: 2,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                ),
                                onPressed: _saving ? null : _save,
                                icon: _saving
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                                      )
                                    : const Icon(Icons.check_circle_rounded, size: 20),
                                label: Text(
                                  _saving ? 'Saving Changes...' : 'Save Teacher Changes',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              Positioned(
                top: 14,
                right: 14,
                child: IconButton(
                  icon: Icon(Icons.close_rounded, color: muted),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(bool dark, Color bord) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 48, 16),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: bord)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _emerald.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.edit_note_rounded, color: _emerald, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Edit Teacher Details',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 2),
                Text(
                  'Branch: ${widget.branchId.toUpperCase()} • Edit profile & settings',
                  style: TextStyle(fontSize: 12, color: _muted(context)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhotoSection(bool dark, Color bord) {
    return Center(
      child: Stack(
        children: [
          CircleAvatar(
            radius: 46,
            backgroundColor: _card(context),
            backgroundImage: _profileBytes != null
                ? MemoryImage(_profileBytes!)
                : (_profileBase64 != null && _profileBase64!.isNotEmpty)
                    ? MemoryImage(base64Decode(_profileBase64!)) as ImageProvider
                    : null,
            child: (_profileBytes == null && (_profileBase64 == null || _profileBase64!.isEmpty))
                ? const Icon(Icons.person_rounded, size: 48, color: _emerald)
                : null,
          ),
          Positioned(
            bottom: 0,
            right: 0,
            child: InkWell(
              onTap: _pickPhoto,
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: _emerald,
                  shape: BoxShape.circle,
                  border: Border.all(color: _bg(context), width: 2),
                ),
                child: const Icon(Icons.camera_alt_rounded, size: 16, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection({
    required bool dark,
    required Color card,
    required Color bord,
    required Color text,
    required Color muted,
    required IconData icon,
    required Color accent,
    required String title,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: bord),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 17, color: accent),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: text),
              ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _field({
    required bool dark,
    required Color bord,
    required Color text,
    required Color muted,
    required TextEditingController ctrl,
    required String label,
    required IconData icon,
    String? hint,
    int maxLines = 1,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: ctrl,
      maxLines: maxLines,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      validator: validator,
      style: TextStyle(color: text, fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon, size: 18, color: muted),
        filled: true,
        fillColor: dark ? const Color(0xFF0F172A) : Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: bord),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: bord),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _emerald, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }

  Widget _passwordField({
    required bool dark,
    required Color bord,
    required Color text,
    required Color muted,
  }) {
    return TextFormField(
      controller: _passwordCtrl,
      obscureText: _obscurePass,
      style: TextStyle(color: text, fontSize: 13),
      decoration: InputDecoration(
        labelText: 'Change Password (leave empty to keep unchanged)',
        hintText: 'Min 6 characters',
        prefixIcon: Icon(Icons.lock_outline_rounded, size: 18, color: muted),
        suffixIcon: IconButton(
          icon: Icon(_obscurePass ? Icons.visibility_off : Icons.visibility, size: 18, color: muted),
          onPressed: () => setState(() => _obscurePass = !_obscurePass),
        ),
        filled: true,
        fillColor: dark ? const Color(0xFF0F172A) : Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: bord),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: bord),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _emerald, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }

  Widget _teachingTypeSelector(bool dark, Color bord, Color text, Color muted) {
    return Row(
      children: [
        _chip('hifz', '🕋 Hifz', _teachingType == 'hifz', (v) => setState(() => _teachingType = 'hifz')),
        const SizedBox(width: 8),
        _chip('nazra', '📖 Nazra', _teachingType == 'nazra', (v) => setState(() => _teachingType = 'nazra')),
        const SizedBox(width: 8),
        _chip('both', '✨ Both', _teachingType == 'both', (v) => setState(() => _teachingType = 'both')),
      ],
    );
  }

  Widget _sessionSelector(bool dark, Color bord, Color text, Color muted) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _chip('morning', '☀️ Morning', _session == 'morning', (v) => setState(() => _session = 'morning')),
        _chip('evening', '🌅 Evening', _session == 'evening', (v) => setState(() => _session = 'evening')),
        _chip('night', '🌙 Night', _session == 'night', (v) => setState(() => _session = 'night')),
        _chip('all', '🕒 Full Day', _session == 'all', (v) => setState(() => _session = 'all')),
      ],
    );
  }

  Widget _chip(String key, String label, bool selected, ValueChanged<bool> onSelected) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      selectedColor: _emerald,
      backgroundColor: _isDark(context) ? const Color(0xFF0F172A) : Colors.white,
      labelStyle: TextStyle(
        color: selected ? Colors.white : _text(context),
        fontWeight: selected ? FontWeight.bold : FontWeight.normal,
        fontSize: 12,
      ),
      onSelected: onSelected,
    );
  }

  Widget _docTile(bool dark, Color bord, Color text, Color muted) {
    final hasDoc = _idDocBase64 != null && _idDocBase64!.isNotEmpty;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: _pickIdDoc,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: dark ? const Color(0xFF0F172A) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: bord),
        ),
        child: Row(
          children: [
            Icon(
              hasDoc ? Icons.check_circle_rounded : Icons.file_upload_outlined,
              color: hasDoc ? _emerald : muted,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                hasDoc ? 'ID Document Attached (Tap to replace)' : 'Attach CNIC / ID Document',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: hasDoc ? FontWeight.bold : FontWeight.normal,
                  color: hasDoc ? _emerald : muted,
                ),
              ),
            ),
            if (hasDoc)
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 16, color: Colors.grey),
                onPressed: () => setState(() => _idDocBase64 = null),
              ),
          ],
        ),
      ),
    );
  }
}
