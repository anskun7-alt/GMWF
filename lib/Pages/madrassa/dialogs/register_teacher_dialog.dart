// lib/pages/madrassa/dialogs/register_teacher_dialog.dart
//
// A focused teacher-registration dialog for Madrassa Principals.
// Only collects the essential fields: profile photo, name/username,
// CNIC, phone, address, email, password, and an optional ID-document
// upload. Role is pre-fixed to "Madrassa Teacher".


import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive/hive.dart';

import '../../../services/auth_service.dart';
import '../../../services/image_upload_service.dart';

/// Opens the Register-Teacher dialog and returns `true` if a teacher
/// was successfully registered, `false`/`null` otherwise.
Future<bool?> showRegisterTeacherDialog(
  BuildContext context, {
  required String branchId,
  required String branchName,
  required String principalUsername,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => RegisterTeacherDialog(
      branchId: branchId,
      branchName: branchName,
      principalUsername: principalUsername,
    ),
  );
}

class RegisterTeacherDialog extends StatefulWidget {
  final String branchId;
  final String branchName;
  final String principalUsername;

  const RegisterTeacherDialog({
    super.key,
    required this.branchId,
    required this.branchName,
    required this.principalUsername,
  });

  @override
  State<RegisterTeacherDialog> createState() => _RegisterTeacherDialogState();
}

class _RegisterTeacherDialogState extends State<RegisterTeacherDialog>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _authService = AuthService();

  // Controllers
  final _fullNameCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _emailCtrl    = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _phoneCtrl    = TextEditingController();
  final _cnicCtrl     = TextEditingController();
  final _addressCtrl  = TextEditingController();

  // Profile photo
  Uint8List? _profileBytes;
  String?    _profileBase64;

  // Optional CNIC / ID doc (base64)
  String? _idDocBase64;

  // Teaching shift
  String _session = 'morning';

  // Teaching specialization
  String _teachingType = 'hifz';

  bool _obscurePass  = true;
  bool _loading      = false;
  String? _usernameError;

  late final AnimationController _anim;
  late final Animation<double>   _fade;

  static const _emerald   = Color(0xFF0F766E);
  static const _emeraldLt = Color(0xFF14B8A6);
  static const _danger    = Color(0xFFEF4444);

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 350));
    _fade = CurvedAnimation(parent: _anim, curve: Curves.easeOut);
    _anim.forward();
  }

  @override
  void dispose() {
    _anim.dispose();
    _fullNameCtrl.dispose();
    _usernameCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _phoneCtrl.dispose();
    _cnicCtrl.dispose();
    _addressCtrl.dispose();
    super.dispose();
  }

  // ── Theme helpers ─────────────────────────────────────────────────────────
  bool   _isDark(BuildContext ctx) => Theme.of(ctx).brightness == Brightness.dark;
  Color  _bg(BuildContext ctx)     => _isDark(ctx) ? const Color(0xFF0F172A) : Colors.white;
  Color  _card(BuildContext ctx)   => _isDark(ctx) ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC);
  Color  _bord(BuildContext ctx)   => _isDark(ctx) ? const Color(0xFF334155) : const Color(0xFFE2E8F0);
  Color  _text(BuildContext ctx)   => _isDark(ctx) ? const Color(0xFFF1F5F9) : const Color(0xFF0F172A);
  Color  _muted(BuildContext ctx)  => _isDark(ctx) ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

  // ── Pickers ───────────────────────────────────────────────────────────────
  Future<void> _pickPhoto() async {
    try {
      final source = await ImageUploadService.showSourceDialog(context, title: 'Profile Photo');
      if (source == null) return;
      final b64 = await ImageUploadService.pickAndProcessImage(source: source, quality: 85);
      if (b64 == null || b64.isEmpty || !mounted) return;
      final bytes = ImageUploadService.decodeBase64ToBytes(b64);
      if (bytes == null) return;
      setState(() { _profileBytes = bytes; _profileBase64 = b64; });
    } catch (e) { _snack('Could not pick photo: $e', error: true); }
  }

  Future<void> _pickIdDoc() async {
    try {
      final source = await ImageUploadService.showSourceDialog(context, title: 'Upload CNIC / ID Document');
      if (source == null) return;
      final b64 = await ImageUploadService.pickAndProcessImage(source: source, quality: 90);
      if (b64 == null || b64.isEmpty || !mounted) return;
      setState(() => _idDocBase64 = b64);
      _snack('ID document attached ✓', success: true);
    } catch (e) { _snack('Could not pick document: $e', error: true); }
  }

  // ── Username check ────────────────────────────────────────────────────────
  Future<bool> _usernameExists(String username) async {
    final lower = username.trim().toLowerCase();
    try {
      if (Hive.isBoxOpen('local_users')) {
        for (final val in Hive.box('local_users').values) {
          if (val is Map) {
            final u  = (val['username']?.toString() ?? '').toLowerCase().trim();
            final ul = (val['usernameLower']?.toString() ?? '').toLowerCase().trim();
            final isDeleted = val['isDeleted'] == true || val['status'] == 'deleted' || val['accountStatus'] == 'deleted';
            if (!isDeleted && (u == lower || ul == lower)) return true;
          }
        }
      }
    } catch (_) {}
    try {
      final res = await FirebaseFirestore.instance
          .collection('users')
          .where('usernameLower', isEqualTo: lower)
          .limit(1)
          .get()
          .timeout(const Duration(seconds: 5));
      if (res.docs.isNotEmpty) {
        final docData = res.docs.first.data();
        final status = (docData['status'] ?? docData['accountStatus'] ?? '').toString().toLowerCase();
        if (docData['isDeleted'] != true && status != 'deleted') {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  // ── Submit ────────────────────────────────────────────────────────────────
  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _usernameError = null; _loading = true; });

    final username = _usernameCtrl.text.trim();
    final email    = _emailCtrl.text.trim().toLowerCase();

    try {
      if (await _usernameExists(username)) {
        setState(() => _usernameError = 'Username already taken');
        _snack('Username already exists', error: true);
        return;
      }

      final fullName = _fullNameCtrl.text.trim();
      final effectiveName = fullName.isNotEmpty ? fullName : username;

      await _authService.signUp(
        email:                email,
        password:             _passwordCtrl.text.trim(),
        username:             username,
        role:                 'Madrassa Teacher',
        branchId:             widget.branchId,
        branchName:           widget.branchName,
        phone:                _phoneCtrl.text.trim().isNotEmpty  ? _phoneCtrl.text.trim() : null,
        identification:       _cnicCtrl.text.trim().isNotEmpty   ? _cnicCtrl.text.trim()  : null,
        address:              _addressCtrl.text.trim().isNotEmpty ? _addressCtrl.text.trim() : null,
        profileImageBytes:    _profileBytes,
        profilePictureBase64: _profileBase64,
        identificationBase64: _idDocBase64,
        name:                 effectiveName,
        specialization:       _teachingType,
        teachingType:         _teachingType,
        session:              _session,
        sessions:             _session == 'all'
                                  ? ['morning', 'evening', 'night']
                                  : [_session],
      );

      // Cache specialization and name in local_users
      try {
        if (Hive.isBoxOpen('local_users')) {
          final box = Hive.box('local_users');
          final raw = box.get(username) ?? box.get(username.toLowerCase());
          if (raw is Map) {
            final updated = Map<String, dynamic>.from(raw);
            updated['name'] = effectiveName;
            updated['displayName'] = effectiveName;
            updated['specialization'] = _teachingType;
            updated['teachingType'] = _teachingType;
            await box.put(username, updated);
            await box.put(username.toLowerCase(), updated);
          }
        }
      } catch (_) {}

      if (!mounted) return;
      final typeLabel = _teachingType == 'hifz' ? 'Hifz' : _teachingType == 'nazra' ? 'Nazra' : 'Hifz & Nazra';
      _snack('$username registered as $typeLabel Teacher ✓', success: true);
      Navigator.of(context).pop(true);
    } on Exception catch (e) {
      _snack(e.toString().replaceAll('Exception: ', ''), error: true);
    } catch (e) {
      _snack('Unexpected error: $e', error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _snack(String msg, {bool error = false, bool success = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        Icon(
          error ? Icons.error_outline : success ? Icons.check_circle_outline : Icons.info_outline,
          color: Colors.white, size: 17,
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

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context);
    final bg   = _bg(context);
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
          constraints: const BoxConstraints(maxWidth: 540, maxHeight: 790),
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
                              dark: dark, card: card, bord: bord, text: text, muted: muted,
                              icon: Icons.badge_outlined, accent: _emerald,
                              title: 'Account Credentials',
                              child: Column(children: [
                                _field(dark: dark, bord: bord, text: text, muted: muted,
                                  ctrl: _fullNameCtrl, label: 'Full Name *', icon: Icons.badge_rounded,
                                  validator: (v) => (v?.trim().isEmpty ?? true) ? 'Required' : null,
                                ),
                                const SizedBox(height: 12),
                                _field(dark: dark, bord: bord, text: text, muted: muted,
                                  ctrl: _usernameCtrl, label: 'Username *', icon: Icons.alternate_email_rounded,
                                  errorText: _usernameError,
                                  validator: (v) => (v?.trim().isEmpty ?? true) ? 'Required' : null,
                                  onChanged: (_) { if (_usernameError != null) setState(() => _usernameError = null); },
                                ),
                                const SizedBox(height: 12),
                                _field(dark: dark, bord: bord, text: text, muted: muted,
                                  ctrl: _emailCtrl, label: 'Email *', icon: Icons.mail_outline_rounded,
                                  keyboardType: TextInputType.emailAddress,
                                  validator: (v) {
                                    if (v == null || v.trim().isEmpty) return 'Required';
                                    if (!v.contains('@')) return 'Invalid email';
                                    return null;
                                  },
                                ),
                                const SizedBox(height: 12),
                                _passwordField(dark: dark, bord: bord, text: text, muted: muted),
                              ]),
                            ),
                            const SizedBox(height: 14),
                            _buildSection(
                              dark: dark, card: card, bord: bord, text: text, muted: muted,
                              icon: Icons.person_outline_rounded, accent: const Color(0xFF7C3AED),
                              title: 'Personal Details',
                              child: Column(children: [
                                _field(dark: dark, bord: bord, text: text, muted: muted,
                                  ctrl: _cnicCtrl, label: 'CNIC / National ID',
                                  icon: Icons.credit_card_outlined, hint: '42101-1234567-8',
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d-]'))],
                                ),
                                const SizedBox(height: 12),
                                _field(dark: dark, bord: bord, text: text, muted: muted,
                                  ctrl: _phoneCtrl, label: 'Phone Number',
                                  icon: Icons.phone_outlined, hint: '03001234567',
                                  keyboardType: TextInputType.phone,
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly,
                                    LengthLimitingTextInputFormatter(11),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                _field(dark: dark, bord: bord, text: text, muted: muted,
                                  ctrl: _addressCtrl, label: 'Address',
                                  icon: Icons.home_outlined, maxLines: 2,
                                ),
                              ]),
                            ),
                            const SizedBox(height: 14),
                            _buildSection(
                              dark: dark, card: card, bord: bord, text: text, muted: muted,
                              icon: Icons.menu_book_rounded, accent: const Color(0xFF7E22CE),
                              title: 'Teaching Specialization',
                              child: _teachingTypeSelector(dark, bord, text, muted),
                            ),
                            const SizedBox(height: 14),
                            _buildSection(
                              dark: dark, card: card, bord: bord, text: text, muted: muted,
                              icon: Icons.access_time_rounded, accent: const Color(0xFF0369A1),
                              title: 'Teaching Shift',
                              child: _sessionSelector(dark, bord, text, muted),
                            ),
                            const SizedBox(height: 14),
                            _buildSection(
                              dark: dark, card: card, bord: bord, text: text, muted: muted,
                              icon: Icons.folder_outlined, accent: const Color(0xFFD97706),
                              title: 'Documents (Optional)',
                              child: _docTile(dark, bord, text, muted),
                            ),
                            const SizedBox(height: 24),
                            SizedBox(
                              height: 50,
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _emerald,
                                  foregroundColor: Colors.white,
                                  elevation: 3,
                                  shadowColor: _emerald.withValues(alpha: 0.4),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                ),
                                icon: const Icon(Icons.how_to_reg_rounded, size: 20),
                                label: const Text(
                                  'Register Teacher',
                                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, letterSpacing: 0.2),
                                ),
                                onPressed: _loading ? null : _submit,
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              // Loading overlay
              if (_loading)
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
                        decoration: BoxDecoration(
                          color: bg,
                          borderRadius: BorderRadius.circular(18),
                          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 24)],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 48, height: 48,
                              child: CircularProgressIndicator(color: _emerald, strokeWidth: 3.5),
                            ),
                            const SizedBox(height: 16),
                            Text('Creating Account…',
                                style: TextStyle(color: text, fontWeight: FontWeight.w700, fontSize: 15)),
                            const SizedBox(height: 4),
                            Text('Please wait', style: TextStyle(color: muted, fontSize: 12)),
                          ],
                        ),
                      ),
                    ),
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
      padding: const EdgeInsets.fromLTRB(20, 20, 12, 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: dark
              ? [_emerald.withValues(alpha: 0.3), _emeraldLt.withValues(alpha: 0.1)]
              : [_emerald.withValues(alpha: 0.08), _emeraldLt.withValues(alpha: 0.04)],
          begin: Alignment.topLeft, end: Alignment.bottomRight,
        ),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(bottom: BorderSide(color: bord, width: 1)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [_emerald, _emeraldLt],
                begin: Alignment.topLeft, end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [BoxShadow(color: _emerald.withValues(alpha: 0.35), blurRadius: 10, offset: const Offset(0, 3))],
            ),
            child: const Icon(Icons.school_rounded, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Register Teacher',
                    style: TextStyle(color: _emerald, fontWeight: FontWeight.w800, fontSize: 17, letterSpacing: -0.3)),
                const SizedBox(height: 2),
                Text('Madrassa Teacher • ${widget.branchName}',
                    style: const TextStyle(color: _emeraldLt, fontSize: 12, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 20),
            onPressed: _loading ? null : () => Navigator.of(context).pop(false),
            splashRadius: 18,
          ),
        ],
      ),
    );
  }

  Widget _buildPhotoSection(bool dark, Color bord) {
    return Center(
      child: GestureDetector(
        onTap: _pickPhoto,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 86, height: 86,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: _profileBytes != null ? _emerald : bord,
                  width: 2.5,
                ),
                boxShadow: [BoxShadow(
                  color: _emerald.withValues(alpha: _profileBytes != null ? 0.25 : 0.06),
                  blurRadius: 12,
                )],
              ),
              child: ClipOval(
                child: _profileBytes != null
                    ? Image.memory(_profileBytes!, fit: BoxFit.cover)
                    : Container(
                        color: _emerald.withValues(alpha: 0.07),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.person_outline_rounded, size: 30, color: _emerald.withValues(alpha: 0.5)),
                            const SizedBox(height: 2),
                            const Text('Photo', style: TextStyle(fontSize: 10, color: _emerald, fontWeight: FontWeight.w500)),
                          ],
                        ),
                      ),
              ),
            ),
            Positioned(
              right: -2, bottom: -2,
              child: GestureDetector(
                onTap: _profileBytes != null
                    ? () => setState(() { _profileBytes = null; _profileBase64 = null; })
                    : _pickPhoto,
                child: Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: _profileBytes != null ? _danger : _emerald,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 4)],
                  ),
                  child: Icon(
                    _profileBytes != null ? Icons.close_rounded : Icons.camera_alt_rounded,
                    color: Colors.white, size: 12,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSection({
    required bool dark, required Color card, required Color bord,
    required Color text, required Color muted,
    required IconData icon, required Color accent,
    required String title, required Widget child,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: bord),
        boxShadow: [BoxShadow(
          color: Colors.black.withValues(alpha: dark ? 0.12 : 0.04),
          blurRadius: 10, offset: const Offset(0, 3),
        )],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, color: accent, size: 16),
                ),
                const SizedBox(width: 9),
                Text(title, style: TextStyle(color: text, fontWeight: FontWeight.w700, fontSize: 13)),
              ],
            ),
          ),
          Divider(height: 1, color: bord),
          Padding(padding: const EdgeInsets.all(14), child: child),
        ],
      ),
    );
  }

  // Shared text field builder
  Widget _field({
    required bool dark, required Color bord, required Color text, required Color muted,
    required TextEditingController ctrl, required String label, required IconData icon,
    String? hint, TextInputType keyboardType = TextInputType.text,
    List<TextInputFormatter>? inputFormatters,
    String? Function(String?)? validator, String? errorText,
    ValueChanged<String>? onChanged, int maxLines = 1,
  }) {
    return TextFormField(
      controller: ctrl,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      maxLines: maxLines,
      onChanged: onChanged,
      validator: validator,
      style: TextStyle(color: text, fontSize: 13.5),
      decoration: InputDecoration(
        labelText: label, hintText: hint, errorText: errorText,
        prefixIcon: Icon(icon, size: 18, color: muted),
        labelStyle: TextStyle(color: muted, fontSize: 13),
        hintStyle: TextStyle(color: muted.withValues(alpha: 0.6), fontSize: 12.5),
        filled: true,
        fillColor: dark ? const Color(0xFF0F172A) : Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: bord)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: bord)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _emerald, width: 1.8)),
        errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _danger)),
        focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _danger, width: 1.8)),
        errorStyle: const TextStyle(fontSize: 11),
      ),
    );
  }

  Widget _passwordField({
    required bool dark, required Color bord, required Color text, required Color muted,
  }) {
    return TextFormField(
      controller: _passwordCtrl,
      obscureText: _obscurePass,
      style: TextStyle(color: text, fontSize: 13.5),
      validator: (v) => (v?.length ?? 0) < 6 ? 'Minimum 6 characters' : null,
      decoration: InputDecoration(
        labelText: 'Password *',
        prefixIcon: Icon(Icons.lock_outline_rounded, size: 18, color: muted),
        suffixIcon: IconButton(
          icon: Icon(_obscurePass ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 18, color: muted),
          onPressed: () => setState(() => _obscurePass = !_obscurePass),
          splashRadius: 18,
        ),
        labelStyle: TextStyle(color: muted, fontSize: 13),
        filled: true,
        fillColor: dark ? const Color(0xFF0F172A) : Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: bord)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: bord)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _emerald, width: 1.8)),
        errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _danger)),
        focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _danger, width: 1.8)),
        errorStyle: const TextStyle(fontSize: 11),
      ),
    );
  }

  Widget _teachingTypeSelector(bool dark, Color bord, Color text, Color muted) {
    const purple = Color(0xFF7E22CE);
    const purpleLt = Color(0xFFA855F7);

    const types = [
      {
        'value': 'hifz',
        'label': 'Hifz',
        'arabic': 'حِفْظ',
        'sub': 'Quran Memorization',
        'icon': Icons.auto_stories_rounded,
      },
      {
        'value': 'nazra',
        'label': 'Nazra',
        'arabic': 'نَظْرَة',
        'sub': 'Quran Reading / Recitation',
        'icon': Icons.menu_book_rounded,
      },
      {
        'value': 'both',
        'label': 'Both',
        'arabic': 'حِفْظ + نَظْرَة',
        'sub': 'Hifz & Nazra',
        'icon': Icons.import_contacts_rounded,
      },
    ];

    return Column(
      children: types.map((t) {
        final isSelected = _teachingType == t['value'];
        return GestureDetector(
          onTap: () => setState(() => _teachingType = t['value'] as String),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: isSelected
                  ? purple.withValues(alpha: dark ? 0.22 : 0.08)
                  : (dark ? const Color(0xFF0F172A) : Colors.white),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSelected ? purple : bord,
                width: isSelected ? 1.8 : 1,
              ),
              boxShadow: isSelected
                  ? [BoxShadow(color: purple.withValues(alpha: 0.18), blurRadius: 6)]
                  : null,
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: (isSelected ? purple : muted).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(
                    t['icon'] as IconData,
                    size: 18,
                    color: isSelected ? purple : muted,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            t['label'] as String,
                            style: TextStyle(
                              color: isSelected ? purple : text,
                              fontWeight: FontWeight.w700,
                              fontSize: 13.5,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            t['arabic'] as String,
                            style: TextStyle(
                              color: isSelected ? purpleLt : muted,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                              fontFamily: 'Jameel Noori Nastaleeq',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        t['sub'] as String,
                        style: TextStyle(
                          color: isSelected ? purpleLt : muted,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: 18, height: 18,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isSelected ? purple : Colors.transparent,
                    border: Border.all(
                      color: isSelected ? purple : bord,
                      width: 2,
                    ),
                  ),
                  child: isSelected
                      ? const Icon(Icons.check_rounded, size: 11, color: Colors.white)
                      : null,
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _sessionSelector(bool dark, Color bord, Color text, Color muted) {

    const sessions = [
      {'value': 'morning', 'label': 'Morning',    'icon': Icons.wb_sunny_outlined,    'sub': '8:00 AM – 2:00 PM'},
      {'value': 'evening', 'label': 'Evening',    'icon': Icons.wb_twilight_outlined,  'sub': '2:00 PM – 8:00 PM'},
      {'value': 'night',   'label': 'Night',      'icon': Icons.nights_stay_outlined,  'sub': '8:00 PM – 8:00 AM'},
      {'value': 'all',     'label': 'All Shifts', 'icon': Icons.all_inclusive_rounded, 'sub': 'Full-day coverage'},
    ];
    return Wrap(
      spacing: 8, runSpacing: 8,
      children: sessions.map((s) {
        final isSelected = _session == s['value'];
        return GestureDetector(
          onTap: () => setState(() => _session = s['value'] as String),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: isSelected
                  ? _emerald.withValues(alpha: dark ? 0.22 : 0.09)
                  : (dark ? const Color(0xFF0F172A) : Colors.white),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSelected ? _emerald : bord,
                width: isSelected ? 1.8 : 1,
              ),
              boxShadow: isSelected
                  ? [BoxShadow(color: _emerald.withValues(alpha: 0.18), blurRadius: 6)]
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(s['icon'] as IconData, size: 15, color: isSelected ? _emerald : muted),
                const SizedBox(width: 7),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s['label'] as String,
                        style: TextStyle(
                          color: isSelected ? _emerald : text,
                          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                          fontSize: 12,
                        )),
                    Text(s['sub'] as String,
                        style: TextStyle(color: isSelected ? _emeraldLt : muted, fontSize: 10.5)),
                  ],
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _docTile(bool dark, Color bord, Color text, Color muted) {
    final attached = _idDocBase64 != null && _idDocBase64!.isNotEmpty;
    return GestureDetector(
      onTap: attached ? () => setState(() => _idDocBase64 = null) : _pickIdDoc,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: attached
              ? _emerald.withValues(alpha: dark ? 0.15 : 0.07)
              : (dark ? const Color(0xFF0F172A) : Colors.white),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: attached ? _emerald : bord, width: attached ? 1.5 : 1),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: (attached ? _emerald : const Color(0xFFD97706)).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                attached ? Icons.check_circle_rounded : Icons.upload_file_rounded,
                size: 18,
                color: attached ? _emerald : const Color(0xFFD97706),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    attached ? 'ID Document Attached' : 'Upload CNIC / ID Document',
                    style: TextStyle(
                      color: attached ? _emerald : text,
                      fontWeight: FontWeight.w600, fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    attached ? 'Tap to remove' : 'Photo of CNIC or other ID (optional)',
                    style: TextStyle(color: muted, fontSize: 11.5),
                  ),
                ],
              ),
            ),
            attached
                ? const Icon(Icons.close_rounded, color: _danger, size: 18)
                : Icon(Icons.chevron_right_rounded, color: muted, size: 20),
          ],
        ),
      ),
    );
  }
}
