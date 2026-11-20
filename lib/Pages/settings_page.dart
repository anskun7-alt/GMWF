import 'package:gmwf/utils/debounced_box_listenable.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../theme/app_theme.dart';
import '../theme/role_theme_provider.dart';
import '../design/tokens/soft_palette.dart';
import '../utils/localization_helper.dart';
import '../services/local_storage_service.dart';
import '../utils/formatters.dart';
import '../services/offline_auth_service.dart' as offline_auth;
import '../services/auth_service.dart';
import '../services/auto_update_service.dart';
import '../services/image_upload_service.dart';
import '../services/user_theme_service.dart';
import '../services/user_language_service.dart';
import '../widgets/update_dialog_widget.dart';
import '../realtime/realtime_events.dart';
import '../realtime/realtime_manager.dart';
import 'school/views/school_about_view.dart';
import 'support_page.dart';
import '../services/quota_service.dart';
import '../services/hidden_force_uploader.dart';
import '../widgets/queue_doctor_dialog.dart';
import 'settings/biometric_device_manager_page.dart';
import 'settings/python_terminal_screen.dart';


class SettingsPage extends StatefulWidget {
  final Map<String, dynamic> userData;
  final bool embedded;

  const SettingsPage({
    super.key,
    required this.userData,
    this.embedded = false,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late Box _settingsBox;
  late TextEditingController _terminalIdController;
  int _mobileTab = 0; // 0: All, 1: Appearance, 2: Account, 3: Sync & Tools

  @override
  void initState() {
    super.initState();
    _settingsBox = Hive.box('app_settings');
    
    final currentTid = _settingsBox.get('terminal_id', defaultValue: '') as String;
    _terminalIdController = TextEditingController(text: currentTid);
    
    _terminalIdController.addListener(_onTerminalIdChanged);
  }

  @override
  void dispose() {
    _terminalIdController.removeListener(_onTerminalIdChanged);
    _terminalIdController.dispose();
    super.dispose();
  }

  void _onTerminalIdChanged() {
    final text = _terminalIdController.text.trim().toUpperCase();
    _settingsBox.put('terminal_id', text);
  }

  ImageProvider? _getProfileImageProvider(String? photoStr) {
    if (photoStr == null || photoStr.trim().isEmpty) return null;
    final s = photoStr.trim();
    if (s.startsWith('data:image') || s.length > 200) {
      try {
        final base64Str = s.contains(',') ? s.split(',').last : s;
        final bytes = base64Decode(base64Str.replaceAll(RegExp(r'\s+'), ''));
        return MemoryImage(bytes);
      } catch (_) {}
    }
    if (s.startsWith('http://') || s.startsWith('https://')) {
      return NetworkImage(s);
    }
    try {
      if (File(s).existsSync()) {
        return FileImage(File(s));
      }
    } catch (_) {}
    return null;
  }

  Future<void> _pickProfilePicture(BuildContext context) async {
    final source = await ImageUploadService.showSourceDialog(context, title: 'Choose Profile Photo');
    if (source == null) return;

    final base64Img = await ImageUploadService.pickAndProcessImage(source: source, maxWidth: 512, maxHeight: 512);
    if (base64Img == null || base64Img.isEmpty) return;

    setState(() {
      widget.userData['profileImage'] = base64Img;
      widget.userData['photoUrl'] = base64Img;
      widget.userData['profilePictureUrl'] = base64Img;
    });

    await LocalStorageService.saveLocalUser(widget.userData);
    await offline_auth.OfflineAuthService.updateCachedUserData(widget.userData);

    // Sync over LAN Server if connected
    try {
      final bId = widget.userData['branchId']?.toString() ?? 'all';
      RealtimeManager().sendMessage(
        RealtimeEvents.payload(
          type: RealtimeEvents.saveUser,
          branchId: bId,
          data: Map<String, dynamic>.from(widget.userData),
        ),
      );
    } catch (e) {
      debugPrint('[SettingsPage] Realtime sync error: $e');
    }

    try {
      final uid = (FirebaseAuth.instance.currentUser?.uid ?? widget.userData['uid'] ?? widget.userData['id'])?.toString();
      if (uid != null && uid.isNotEmpty) {
        final updateData = {
          'profileImage': base64Img,
          'photoUrl': base64Img,
          'profilePictureUrl': base64Img,
          'updatedAt': FieldValue.serverTimestamp(),
        };

        await FirebaseFirestore.instance.collection('users').doc(uid).set(updateData, SetOptions(merge: true));

        final branchId = widget.userData['branchId']?.toString();
        if (branchId != null && branchId.isNotEmpty && branchId != 'all' && branchId != 'unknown') {
          await FirebaseFirestore.instance
              .collection('branches')
              .doc(branchId)
              .collection('users')
              .doc(uid)
              .set(updateData, SetOptions(merge: true));
        }

        try {
          final cgSnap = await FirebaseFirestore.instance
              .collectionGroup('users')
              .where('uid', isEqualTo: uid)
              .get()
              .timeout(const Duration(seconds: 4));
          for (final doc in cgSnap.docs) {
            await doc.reference.set(updateData, SetOptions(merge: true));
          }
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[SettingsPage] Error uploading profile photo to cloud: $e');
    }

    if (context.mounted) {
      AppToast.showSnackBar(context, 
        const SnackBar(
          content: Text('✅ Profile picture updated successfully!'),
          backgroundColor: SoftPalette.green400,
        ),
      );
    }
  }

  TextStyle _getStyle(RoleThemeData t, {double size = 14, FontWeight weight = FontWeight.normal, double height = 1.2}) {
    return TextStyle(
      color: t.textPrimary,
      fontSize: size,
      fontWeight: weight,
      height: height,
    );
  }

  Widget _sectionLabel(RoleThemeData t, String labelKey) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 4, bottom: 12, top: 16),
      child: Text(
        context.tr(labelKey).toUpperCase(),
        style: TextStyle(
          color: t.textTertiary,
          fontSize: 10,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  Widget _profileItem(RoleThemeData t, IconData icon, String labelKey, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: t.bg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: t.bgRule),
            ),
            child: Icon(icon, color: t.textSecondary, size: 20),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.tr(labelKey),
                  style: TextStyle(color: t.textTertiary, fontSize: 11, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: TextStyle(color: t.textPrimary, fontSize: 14, fontWeight: FontWeight.w700),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider(RoleThemeData t) {
    return Divider(color: t.bgRule, height: 24);
  }

  Widget _buildColorPill(RoleThemeData t, String label, String? hexColor, Color previewColor) {
    final activeHex = _settingsBox.get('custom_accent_color') as String?;
    final isSelected = hexColor == null ? (activeHex == null || activeHex.isEmpty) : (activeHex?.toUpperCase() == hexColor.toUpperCase());
    final isLightColor = previewColor.computeLuminance() > 0.45;
    
    return Tooltip(
      message: label,
      child: GestureDetector(
        onTap: () async {
          if (hexColor == null) {
            await _settingsBox.delete('custom_accent_color');
          } else {
            await _settingsBox.put('custom_accent_color', hexColor);
          }
          UserThemeService.notifyThemeChanged();
          setState(() {});
        },
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: previewColor,
            shape: BoxShape.circle,
            border: Border.all(
              color: isSelected ? t.textPrimary : t.bgRule,
              width: isSelected ? 3.0 : 1.0,
            ),
            boxShadow: isSelected
                ? [BoxShadow(color: previewColor.withValues(alpha: 0.5), blurRadius: 10, spreadRadius: 2)]
                : [],
          ),
          child: isSelected
              ? Icon(
                  Icons.check,
                  color: isLightColor ? SoftPalette.gray900 : SoftPalette.gray50,
                  size: 20,
                )
              : null,
        ),
      ),
    );
  }

  Widget _buildCustomHexColorPill(RoleThemeData t) {
    final activeHex = _settingsBox.get('custom_accent_color') as String?;
    const presetHexes = {
      '#4A7FB5', '#B8860B', '#0047AB', '#2C4A8F', '#3A5178',
      '#00A86B', '#2E7D5B', '#0E6E63', '#0E7C90', '#4B0082',
      '#008080', '#5E5490', '#C2185B', '#D97706', '#DC2626',
      '#7650CC', '#3D60DD', '#0F8A6B',
    };
    final isCustomSelected = activeHex != null && activeHex.isNotEmpty && !presetHexes.contains(activeHex);

    Color customPreview = t.accent;
    if (isCustomSelected) {
      try {
        final hex = activeHex.replaceAll('#', '');
        customPreview = Color(int.parse('FF$hex', radix: 16));
      } catch (_) {}
    }

    final isLightColor = customPreview.computeLuminance() > 0.45;

    return Tooltip(
      message: isCustomSelected ? 'Custom ($activeHex)' : 'Custom Hex Color',
      child: GestureDetector(
        onTap: () => _showCustomColorDialog(t),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: isCustomSelected ? customPreview : t.bgCardAlt,
            shape: BoxShape.circle,
            border: Border.all(
              color: isCustomSelected ? t.textPrimary : t.bgRule,
              width: isCustomSelected ? 3.0 : 1.0,
            ),
            boxShadow: isCustomSelected
                ? [BoxShadow(color: customPreview.withValues(alpha: 0.5), blurRadius: 10, spreadRadius: 2)]
                : [],
          ),
          child: isCustomSelected
              ? Icon(
                  Icons.check,
                  color: isLightColor ? SoftPalette.gray900 : SoftPalette.gray50,
                  size: 20,
                )
              : Icon(
                  Icons.colorize_rounded,
                  color: t.textSecondary,
                  size: 20,
                ),
        ),
      ),
    );
  }

  Future<void> _showCustomColorDialog(RoleThemeData t) async {
    final activeHex = _settingsBox.get('custom_accent_color') as String? ?? '#4A7FB5';
    final ctrl = TextEditingController(text: activeHex);
    String tempHex = activeHex;

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Color? preview;
            try {
              final hex = tempHex.replaceAll('#', '').trim();
              if (hex.length == 6) {
                preview = Color(int.parse('FF$hex', radix: 16));
              }
            } catch (_) {}

            return AlertDialog(
              backgroundColor: t.bgCard,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Text('Custom Accent Color', style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: preview ?? t.accent,
                          shape: BoxShape.circle,
                          border: Border.all(color: t.bgRule, width: 2),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: TextField(
                          controller: ctrl,
                          style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold),
                          decoration: roleInputDecoration(context, label: 'HEX Code (e.g. #4A7FB5)', icon: Icons.palette_outlined),
                          onChanged: (val) {
                            tempHex = val;
                            setDialogState(() {});
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text('Cancel', style: TextStyle(color: t.textTertiary)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: preview ?? t.accent,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: preview != null ? () => Navigator.pop(ctx, tempHex.toUpperCase().trim()) : null,
                  child: const Text('Apply', style: TextStyle(color: SoftPalette.gray50, fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
    );

    if (result != null && result.isNotEmpty) {
      String cleanHex = result.startsWith('#') ? result : '#$result';
      await _settingsBox.put('custom_accent_color', cleanHex);
      UserThemeService.notifyThemeChanged();
      setState(() {});
    }
  }

  Widget _buildToggleButton(RoleThemeData t, String text, bool isSelected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 8),
        decoration: BoxDecoration(
          color: isSelected ? t.accent : t.bgCardAlt,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? t.accent : t.bgRule,
            width: isSelected ? 1.5 : 1.0,
          ),
          boxShadow: isSelected
              ? [BoxShadow(color: t.accent.withValues(alpha: 0.25), blurRadius: 10, offset: const Offset(0, 3))]
              : [],
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: isSelected ? SoftPalette.gray50 : t.textPrimary,
            fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
            fontSize: 13,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  Widget _buildSegmentedSelector<T>(
    RoleThemeData t, 
    String labelKey, 
    T activeValue, 
    Map<T, String> options, 
    Function(T) onSelected
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.tr(labelKey),
          style: _getStyle(t, size: 13, weight: FontWeight.bold),
        ),
        const SizedBox(height: 10),
        Row(
          children: options.entries.map((entry) {
            final isSelected = activeValue == entry.key;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: _buildToggleButton(
                  t, 
                  context.tr(entry.value), 
                  isSelected, 
                  () => onSelected(entry.key)
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  static const Map<GThemeChoice, String> _themeBlurbs = {
    GThemeChoice.gmwf: 'Emerald and gold on warm ivory. The default.',
    GThemeChoice.nexus: 'Graphite and cobalt blue, from the Server Control Center.',
    GThemeChoice.twilight: 'Plum and violet on soft lilac.',
  };

  /// The three themes (GMWF / Nexus / Twilight) and the dark-mode switch. One
  /// saved setting decides colours on every screen, School and the title bar.
  Widget _buildThemeChoiceSelector(RoleThemeData t, String? userPrefKey) {
    final active = UserThemeService.getThemeChoice(userPrefKey);
    final dark = UserThemeService.isDarkMode(userPrefKey);
    final brightness = dark ? Brightness.dark : Brightness.light;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'One theme for every screen. Dark mode is a separate switch below.',
          style: TextStyle(color: t.textSecondary, fontSize: 12),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(builder: (context, constraints) {
          final cols = constraints.maxWidth >= 640 ? 3 : 1;
          const spacing = 10.0;
          final cardWidth = (constraints.maxWidth - (cols - 1) * spacing) / cols;
          return Wrap(
            spacing: spacing,
            runSpacing: spacing,
            children: [
              for (final choice in GThemeChoice.values)
                SizedBox(
                  width: cardWidth,
                  child: _themeChoiceCard(t, choice, GTheme.colors(brightness, family: choice.family), choice == active, () async {
                    await UserThemeService.setThemeChoice(choice, explicitUserKey: userPrefKey);
                    if (mounted) setState(() {});
                  }),
                ),
            ],
          );
        }),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: t.bgCardAlt,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: t.bgRule),
          ),
          child: Row(children: [
            Icon(dark ? Icons.dark_mode_rounded : Icons.light_mode_rounded, size: 18, color: t.textSecondary),
            const SizedBox(width: 10),
            Expanded(child: Text('Dark mode', style: _getStyle(t, size: 13, weight: FontWeight.w600))),
            Switch(
              value: dark,
              onChanged: (v) async {
                await UserThemeService.setDarkMode(v, explicitUserKey: userPrefKey);
                if (mounted) setState(() {});
              },
            ),
          ]),
        ),
      ],
    );
  }

  Widget _themeChoiceCard(RoleThemeData t, GThemeChoice choice, GComfortColors c, bool selected, VoidCallback onTap) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: selected ? Color.alphaBlend(c.brand.withValues(alpha: t.isDarkCanvas ? 0.16 : 0.08), t.bgCard) : t.bgCardAlt,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: selected ? c.brand : t.bgRule, width: selected ? 1.8 : 1),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            // Mini preview: sidebar, canvas, a card and a brand button.
            Container(
              height: 58,
              decoration: BoxDecoration(
                color: c.background,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: c.border),
              ),
              clipBehavior: Clip.antiAlias,
              child: Row(children: [
                Container(width: 28, color: c.sidebarBg),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Container(
                      decoration: BoxDecoration(
                        color: c.surface,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: c.border),
                      ),
                      padding: const EdgeInsets.all(6),
                      child: Row(children: [
                        Expanded(
                          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Container(height: 5, width: 46, color: c.textPrimary.withValues(alpha: 0.7)),
                            const SizedBox(height: 4),
                            Container(height: 4, width: 30, color: c.textMuted.withValues(alpha: 0.6)),
                          ]),
                        ),
                        Container(
                          width: 26,
                          height: 12,
                          decoration: BoxDecoration(color: c.brand, borderRadius: BorderRadius.circular(4)),
                        ),
                        const SizedBox(width: 4),
                        Container(width: 8, height: 8, decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle)),
                      ]),
                    ),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: Text(choice.label, style: TextStyle(color: t.textPrimary, fontSize: 13, fontWeight: FontWeight.w800))),
              if (selected) Icon(Icons.check_circle_rounded, color: c.brand, size: 18),
            ]),
            const SizedBox(height: 2),
            Text(
              _themeBlurbs[choice] ?? '',
              style: TextStyle(color: t.textSecondary, fontSize: 11, height: 1.25),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ]),
        ),
      ),
    );
  }

  void _showEditProfileDialog(BuildContext context, RoleThemeData t, Map<String, dynamic> userData, String userName, String email) {
    final nameController = TextEditingController(text: userName);
    final emailController = TextEditingController(text: email);
    final reasonController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Row(
          children: [
            Icon(Icons.edit_calendar_outlined, color: t.accent),
            const SizedBox(width: 12),
            Text(context.tr('edit_profile'), style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w900, fontSize: 18)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: roleInputDecoration(context, label: "Display Name", icon: Icons.person_outline_rounded),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: emailController,
              decoration: roleInputDecoration(context, label: "Email Address", icon: Icons.alternate_email_rounded),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: reasonController,
              decoration: roleInputDecoration(context, label: "Reason for name change (optional)", icon: Icons.help_outline_rounded),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.tr('cancel'), style: TextStyle(color: t.textTertiary, fontWeight: FontWeight.bold)),
          ),
          ElevatedButton(
            onPressed: () async {
              final newName = nameController.text.trim();
              final newEmail = emailController.text.trim();
              final newReason = reasonController.text.trim();
              if (newName.isEmpty || newEmail.isEmpty) return;

              final oldName = userName;
              final nameChanged = newName != oldName;

              if (nameChanged) {
                final history = List<Map<String, dynamic>>.from(userData['nameHistory'] ?? []);
                history.add({
                  'oldName': oldName,
                  'newName': newName,
                  'changedBy': userData['username'] ?? userData['email'] ?? 'User',
                  'changedAt': DateTime.now().toIso8601String(),
                  'how': 'Settings Page',
                  if (newReason.isNotEmpty) 'reason': newReason,
                });
                userData['nameHistory'] = history;
              }

              // Update in-memory state
              userData['name'] = newName;
              userData['username'] = newName;
              userData['email'] = newEmail;

              // Close dialog FIRST to avoid navigator lock
              if (context.mounted) Navigator.pop(context);

              // Show success snackbar using the outer (parent) context
              if (this.context.mounted) {
                setState(() {});  // Trigger rebuild with updated userData
                AppToast.showSnackBar(this.context, 
                  const SnackBar(
                    content: Text('✅ Profile updated and saved locally!'),
                    backgroundColor: SoftPalette.green400,
                  ),
                );
              }

              // Save to Hive users database & secure storage credentials cache
              await LocalStorageService.saveLocalUser(userData);
              await offline_auth.OfflineAuthService.updateCachedUserData(userData);
              await offline_auth.OfflineAuthService.updateCachedUserData(userData, usernameOrEmail: newEmail);
              await offline_auth.OfflineAuthService.updateCachedUserData(userData, usernameOrEmail: newName);
              final currentPw = userData['password'] as String? ?? '112233';
              await offline_auth.OfflineAuthService.saveCredentials(
                usernameOrEmail: newEmail,
                password: currentPw,
                userData: userData,
              );
              await offline_auth.OfflineAuthService.saveCredentials(
                usernameOrEmail: newName,
                password: currentPw,
                userData: userData,
              );

              // Sync over LAN Server if connected (fire-and-forget)
              try {
                final bId = userData['branchId']?.toString() ?? 'all';
                RealtimeManager().sendMessage(
                  RealtimeEvents.payload(
                    type: RealtimeEvents.saveUser,
                    branchId: bId,
                    data: Map<String, dynamic>.from(userData),
                  ),
                );
              } catch (e) {
                debugPrint('[SettingsPage] Realtime sync error: $e');
              }

              // Update online in Firebase Firestore (background, non-blocking)
              try {
                final uid = (FirebaseAuth.instance.currentUser?.uid ?? userData['uid'] ?? userData['id'])?.toString();
                if (uid != null && uid.isNotEmpty) {
                  final updateData = {
                    'name': newName,
                    'username': newName,
                    'email': newEmail,
                    'updatedAt': FieldValue.serverTimestamp(),
                    if (nameChanged) 'nameHistory': userData['nameHistory'],
                  };

                  unawaited(FirebaseFirestore.instance.collection('users').doc(uid).set(updateData, SetOptions(merge: true)).catchError((_) {}));

                  final branchId = userData['branchId']?.toString();
                  if (branchId != null && branchId.isNotEmpty && branchId != 'all' && branchId != 'unknown') {
                    unawaited(FirebaseFirestore.instance
                        .collection('branches')
                        .doc(branchId)
                        .collection('users')
                        .doc(uid)
                        .set(updateData, SetOptions(merge: true)).catchError((_) {}));
                  }

                  // CollectionGroup update in background (can be slow, do not block UI)
                  unawaited(Future(() async {
                    try {
                      final cgSnap = await FirebaseFirestore.instance
                          .collectionGroup('users')
                          .where('uid', isEqualTo: uid)
                          .get()
                          .timeout(const Duration(seconds: 4));
                      for (final doc in cgSnap.docs) {
                        await doc.reference.set(updateData, SetOptions(merge: true));
                      }
                    } catch (_) {}
                  }));
                }
              } catch (e) {
                debugPrint('[SettingsPage] Error syncing profile to Firebase: $e');
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: t.accent,
              foregroundColor: SoftPalette.gray50,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: Text(context.tr('confirm'), style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showChangePasswordDialog(BuildContext context, RoleThemeData t) {
    final oldPwCtrl = TextEditingController();
    final newPwCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();
    bool showOldPw = false;
    bool showNewPw = false;
    bool isSubmitting = false;

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: t.bgCard,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            title: Row(
              children: [
                Icon(Icons.lock_outline_rounded, color: t.accent),
                const SizedBox(width: 12),
                Text(
                  context.tr('change_password'),
                  style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w900, fontSize: 18),
                ),
              ],
            ),
            content: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: oldPwCtrl,
                    obscureText: !showOldPw,
                    style: TextStyle(color: t.textPrimary),
                    decoration: roleInputDecoration(
                      context, 
                      label: "Old Password", 
                      icon: Icons.lock_open_rounded
                    ).copyWith(
                      suffixIcon: IconButton(
                        icon: Icon(
                          showOldPw ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                          color: t.accent.withValues(alpha: 0.8),
                          size: 20,
                        ),
                        onPressed: () => setDialogState(() => showOldPw = !showOldPw),
                      ),
                    ),
                    validator: (v) => (v == null || v.trim().isEmpty) ? "Old password is required" : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: newPwCtrl,
                    obscureText: !showNewPw,
                    style: TextStyle(color: t.textPrimary),
                    decoration: roleInputDecoration(
                      context, 
                      label: "New Password", 
                      icon: Icons.lock_outline_rounded
                    ).copyWith(
                      suffixIcon: IconButton(
                        icon: Icon(
                          showNewPw ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                          color: t.accent.withValues(alpha: 0.8),
                          size: 20,
                        ),
                        onPressed: () => setDialogState(() => showNewPw = !showNewPw),
                      ),
                    ),
                    validator: (v) => (v == null || v.trim().length < 6) ? "Minimum 6 characters required" : null,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: isSubmitting ? null : () => Navigator.pop(context),
                child: Text(context.tr('cancel'), style: TextStyle(color: t.textTertiary, fontWeight: FontWeight.bold)),
              ),
              ElevatedButton(
                onPressed: isSubmitting ? null : () async {
                  if (!formKey.currentState!.validate()) return;
                  
                  final email = (widget.userData['email'] as String? ?? widget.userData['username'] as String? ?? '').trim();
                  if (email.isEmpty) {
                    AppToast.showSnackBar(context, 
                      const SnackBar(
                        content: Text("❌ Email/Username not found on this profile!"),
                        backgroundColor: SoftPalette.red400,
                      ),
                    );
                    return;
                  }

                  final oldPw = oldPwCtrl.text.trim();
                  final newPw = newPwCtrl.text.trim();

                  if (oldPw == newPw) {
                    AppToast.showSnackBar(context, 
                      const SnackBar(
                        content: Text("⚠️ New password must be different from old password!"),
                        backgroundColor: SoftPalette.amber300,
                      ),
                    );
                    return;
                  }

                  setDialogState(() => isSubmitting = true);

                  try {
                    // Check online authentication if current user is logged into Firebase
                    final currentUser = FirebaseAuth.instance.currentUser;
                    bool firebaseAuthUpdated = false;

                    if (currentUser != null && currentUser.email != null) {
                      try {
                        final cred = EmailAuthProvider.credential(
                          email: currentUser.email!,
                          password: oldPw,
                        );
                        await currentUser.reauthenticateWithCredential(cred);
                        await currentUser.updatePassword(newPw);
                        await offline_auth.OfflineAuthService.updateCachedPassword(newPw, usernameOrEmail: currentUser.email!);
                        firebaseAuthUpdated = true;
                      } on FirebaseAuthException catch (e) {
                        setDialogState(() => isSubmitting = false);
                        if (context.mounted) {
                          final errMsg = e.code == 'wrong-password' || e.code == 'invalid-credential'
                              ? "❌ Incorrect old password! Please re-type your current password."
                              : (e.message ?? "Failed to update Firebase Auth password.");
                          AppToast.showSnackBar(context, 
                            SnackBar(content: Text(errMsg), backgroundColor: SoftPalette.red400),
                          );
                        }
                        return;
                      }
                    } else {
                      // Validate against stored local credentials if Firebase currentUser is null or offline
                      final cachedPw = await offline_auth.OfflineAuthService.getStoredPassword(email);
                      final profilePw = widget.userData['password'] as String?;
                      
                      final expectedPw = (cachedPw != null && cachedPw.isNotEmpty) ? cachedPw : profilePw;
                      if (expectedPw != null && expectedPw.isNotEmpty && expectedPw != oldPw) {
                        setDialogState(() => isSubmitting = false);
                        if (context.mounted) {
                          AppToast.showSnackBar(context, 
                            const SnackBar(
                              content: Text("❌ Incorrect old password! Please check your credentials."),
                              backgroundColor: SoftPalette.red400,
                            ),
                          );
                        }
                        return;
                      }
                    }

                    // Sync to Firestore documents if online user ID exists
                    if (currentUser != null) {
                      final userId = currentUser.uid;
                      final branchId = widget.userData['branchId'] as String? ?? '';
                      final updateMap = {
                        'password': newPw,
                        'updatedAt': FieldValue.serverTimestamp(),
                      };
                      await FirebaseFirestore.instance.collection('users').doc(userId).update(updateMap).catchError((_) {});
                      if (branchId.isNotEmpty && branchId != 'all') {
                        await FirebaseFirestore.instance
                            .collection('branches')
                            .doc(branchId)
                            .collection('users')
                            .doc(userId)
                            .update(updateMap)
                            .catchError((_) {});
                      }
                    }

                    // Update local storage in Hive and FlutterSecureStorage
                    widget.userData['password'] = newPw;
                    widget.userData['passwordHash'] = LocalStorageService.hashPassword(newPw);
                    await LocalStorageService.saveLocalUser(widget.userData);
                    await offline_auth.OfflineAuthService.updateCachedPassword(newPw, usernameOrEmail: email);
                    await offline_auth.OfflineAuthService.saveCredentials(
                      usernameOrEmail: email, 
                      password: newPw, 
                      userData: widget.userData
                    );
                    final uname = (widget.userData['username'] ?? widget.userData['usernameLower'] ?? widget.userData['name'])?.toString().trim().toLowerCase();
                    if (uname != null && uname.isNotEmpty && uname != email.toLowerCase()) {
                      await offline_auth.OfflineAuthService.updateCachedPassword(newPw, usernameOrEmail: uname);
                      await offline_auth.OfflineAuthService.saveCredentials(
                        usernameOrEmail: uname, 
                        password: newPw, 
                        userData: widget.userData
                      );
                    }

                    // Sync over LAN Server if connected
                    try {
                      final bId = widget.userData['branchId']?.toString() ?? 'all';
                      RealtimeManager().sendMessage(
                        RealtimeEvents.payload(
                          type: RealtimeEvents.saveUser,
                          branchId: bId,
                          data: Map<String, dynamic>.from(widget.userData),
                        ),
                      );
                    } catch (e) {
                      debugPrint('[SettingsPage] Realtime sync error: $e');
                    }

                    if (context.mounted) {
                      Navigator.pop(context);
                      AppToast.showSnackBar(context, 
                        SnackBar(
                          content: Text(
                            firebaseAuthUpdated
                                ? "✅ Password changed successfully in Cloud & Local storage!"
                                : "✅ Password changed successfully in local database!"
                          ),
                          backgroundColor: SoftPalette.green400,
                          duration: const Duration(seconds: 4),
                        ),
                      );
                    }
                  } catch (e) {
                    setDialogState(() => isSubmitting = false);
                    if (context.mounted) {
                      AppToast.showSnackBar(context, 
                        SnackBar(content: Text("❌ Failed to change password: $e"), backgroundColor: SoftPalette.red400),
                      );
                    }
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: t.accent,
                  foregroundColor: SoftPalette.gray50,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: isSubmitting
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: SoftPalette.gray50))
                    : Text(context.tr('confirm'), style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final roleStr = (widget.userData['role'] as String? ?? 'admin').toLowerCase().trim();
    final isChairmanOrHq = ['chairman', 'hq manager', 'hq_manager', 'hq', 'headquarters manager', 'admin', 'global admin', 'super admin', 'ceo'].contains(roleStr);
    final roleTheme = RoleThemeData.fromString(roleStr);
    final userPrefKey = (widget.userData['uid'] ?? widget.userData['username'])?.toString();

    return RoleThemeScope(
      role: roleTheme,
      child: ValueListenableBuilder(
        valueListenable: Hive.box('app_settings').listenable(keys: [
          'custom_accent_color',
          'card_radius',
          'is_dark_mode',
          'visual_theme',
          'theme_choice',
          UserThemeService.getStorageKey(userPrefKey),
          UserThemeService.getVisualThemeKey(userPrefKey),
          UserThemeService.getThemeChoiceKey(userPrefKey),
          'language',
          'font_scale',
          'dialog_blur_enabled',
        ]),
        builder: (context, Box box, child) {
          final t = RoleThemeScope.dataOf(context, null, userPrefKey);
          final isDesktop = GBreakpoint.isDesktop(context);
          final userName = resolveUserDisplayName(widget.userData);
          final email = widget.userData['email'] ?? 'No email set';
          final rawRole = widget.userData['role'] as String? ?? 'staff';
          final role = rawRole.toLowerCase() == 'madrassa parent' ? 'GUARDIAN' : rawRole.toUpperCase();
          final branch = widget.userData['branchName'] ?? 'All Branches';

          final initials = userName.isNotEmpty
              ? userName.split(' ').map((e) => e[0]).take(2).join().toUpperCase()
              : 'U';

          final profileImgStr = (widget.userData['profileImage'] ?? widget.userData['profilePictureUrl'] ?? widget.userData['photoUrl'])?.toString();
          final profileProvider = _getProfileImageProvider(profileImgStr);

          final activeRadius = box.get('card_radius', defaultValue: 16.0) as double;
          final activeFontScale = box.get('font_scale', defaultValue: 1.0) as double;
          final isDarkMode = UserThemeService.isDarkMode(userPrefKey);
          final activeLanguage = UserLanguageService.getLanguage(userPrefKey);
          final isDialogBlur = box.get('dialog_blur_enabled', defaultValue: false) as bool;

          final c = context.comfort;
          return Directionality(
            textDirection: activeLanguage == 'ur' ? TextDirection.rtl : TextDirection.ltr,
            child: Scaffold(
              backgroundColor: widget.embedded ? c.background : t.bg,
              appBar: widget.embedded
                  ? null
                  : AppBar(
                      backgroundColor: t.bgCard,
                      elevation: 0,
                      surfaceTintColor: Colors.transparent,
                      automaticallyImplyLeading: roleStr != 'supervisor' && Navigator.canPop(context),
                      leading: (roleStr == 'supervisor' || !Navigator.canPop(context))
                          ? null
                          : IconButton(
                              icon: Icon(
                                Icons.arrow_back_rounded,
                                color: t.textSecondary,
                                size: 22,
                              ),
                              onPressed: () => Navigator.maybePop(context),
                            ),
                      title: Text(
                        context.tr('settings'),
                        style: TextStyle(
                          color: t.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.5,
                        ),
                      ),
                      bottom: PreferredSize(
                        preferredSize: const Size.fromHeight(1),
                        child: Divider(color: t.bgRule, height: 1),
                      ),
                    ),
              body: Builder(
                builder: (context) {
                  // Wrap each section into clean modular blocks so Desktop & Mobile
                  // can render distinct, purpose-built layouts.
                  final profileSection = GSection(
                    title: context.tr('account_profile'),
                    subtitle: '$role · $branch',
                    icon: GIcons.users,
                    iconColor: c.brand,
                    action: IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      icon: Icon(GIcons.edit, color: c.brand, size: 18),
                      onPressed: () => _showEditProfileDialog(context, t, widget.userData, userName, email),
                      tooltip: 'Edit Profile',
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            GestureDetector(
                              onTap: () => _pickProfilePicture(context),
                              child: Stack(
                                children: [
                                  CircleAvatar(
                                    radius: isDesktop ? 32 : 34,
                                    backgroundColor: c.brandSoft,
                                    backgroundImage: profileProvider,
                                    child: profileProvider == null
                                        ? Text(
                                            initials,
                                            style: GText.h3(c.brand),
                                          )
                                        : null,
                                  ),
                                  Positioned(
                                    bottom: 0,
                                    right: 0,
                                    child: Container(
                                      padding: const EdgeInsets.all(5),
                                      decoration: BoxDecoration(
                                        color: c.brand,
                                        shape: BoxShape.circle,
                                        border: Border.all(color: c.surface, width: 2),
                                      ),
                                      child: const Icon(
                                        Icons.camera_alt_rounded,
                                        color: Colors.white,
                                        size: 11,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: Gsp.sp3),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    userName,
                                    style: GText.h3(c.textPrimary),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    email,
                                    style: GText.caption(c.textSecondary),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: Gsp.sp2),
                                  Wrap(
                                    spacing: Gsp.sp2,
                                    runSpacing: Gsp.sp1,
                                    children: [
                                      AppChip(label: role, state: AppChipState.info, icon: Icons.badge_outlined),
                                      AppChip(label: branch, state: AppChipState.neutral, icon: GIcons.branch),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: Gsp.sp3),
                        Divider(height: 1, color: c.border),
                        const SizedBox(height: Gsp.sp2),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () => _showChangePasswordDialog(context, t),
                                icon: const Icon(Icons.lock_outline_rounded, size: 16),
                                label: Text(context.tr('change_password'), overflow: TextOverflow.ellipsis),
                              ),
                            ),
                            const SizedBox(width: Gsp.sp2),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () async {
                                  AppToast.showSnackBar(
                                    context,
                                    SnackBar(
                                      content: const Text('Checking for application updates...'),
                                      duration: const Duration(seconds: 2),
                                      backgroundColor: c.brand,
                                    ),
                                  );
                                  final info = await AutoUpdateService.checkForUpdates();
                                  if (context.mounted) {
                                    if (info != null && info.hasUpdate) {
                                      UpdateDialogWidget.showUpdateDialogIfNeeded(context, manualCheck: true);
                                    } else {
                                      AppToast.showSnackBar(
                                        context,
                                        SnackBar(
                                          content: Text('Your GMWF Platform is up to date (v${AutoUpdateService.currentVersion})!'),
                                          backgroundColor: c.success,
                                        ),
                                      );
                                    }
                                  }
                                },
                                icon: const Icon(Icons.system_update_rounded, size: 16),
                                label: Text('v${AutoUpdateService.currentVersion}', overflow: TextOverflow.ellipsis),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: Gsp.sp2),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: c.danger,
                              side: BorderSide(color: c.danger.withValues(alpha: 0.35)),
                            ),
                            onPressed: () async {
                              final confirmed = await showLogoutDialog(
                                context,
                                subtitle: 'Are you sure you want to sign out of your account?',
                              );
                              if (confirmed != true || !context.mounted) return;
                              await AuthService().signOut();
                              if (context.mounted) {
                                Navigator.pushNamedAndRemoveUntil(context, '/login', (_) => false);
                              }
                            },
                            icon: const Icon(GIcons.logout, size: 16),
                            label: Text(context.tr('logout')),
                          ),
                        ),
                        if (widget.userData['nameHistory'] != null && (widget.userData['nameHistory'] as List).isNotEmpty) ...[
                          const SizedBox(height: Gsp.sp2),
                          Theme(
                            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                            child: ExpansionTile(
                              tilePadding: EdgeInsets.zero,
                              dense: true,
                              iconColor: c.brand,
                              collapsedIconColor: c.textMuted,
                              title: Text('Profile Name History', style: GText.label(c.textPrimary)),
                              childrenPadding: EdgeInsets.zero,
                              children: (widget.userData['nameHistory'] as List).map((entry) {
                                final item = Map<String, dynamic>.from(entry as Map);
                                final oldName = item['oldName'] ?? '';
                                final newName = item['newName'] ?? '';
                                final changedBy = item['changedBy'] ?? '';
                                final how = item['how'] ?? '';
                                final whenStr = item['changedAt'] ?? '';
                                String timeFormatted = whenStr;
                                try {
                                  final dt = DateTime.parse(whenStr);
                                  timeFormatted = DateFormat('MMM dd, yyyy').format(dt.toLocal());
                                } catch (_) {}
                                return Container(
                                  margin: const EdgeInsets.only(bottom: Gsp.sp2),
                                  padding: const EdgeInsets.all(Gsp.sp2),
                                  decoration: BoxDecoration(
                                    color: c.surfaceSunken,
                                    borderRadius: Gr.input,
                                    border: Border.all(color: c.border),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          Expanded(
                                            child: Text(
                                              '$oldName ➔ $newName',
                                              style: GText.body2Bold(c.textPrimary),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          Text(timeFormatted, style: GText.caption(c.textMuted)),
                                        ],
                                      ),
                                      Text('By $changedBy via $how', style: GText.caption(c.textSecondary)),
                                    ],
                                  ),
                                );
                              }).toList().reversed.toList(),
                            ),
                          ),
                        ],
                      ],
                    ),
                  );

                  final isSchoolRole = roleStr.contains('school') ||
                      roleStr.contains('teacher') ||
                      roleStr.contains('principal') ||
                      roleStr.contains('headmaster') ||
                      roleStr.contains('headmistress') ||
                      roleStr.contains('educator');

                  // SCHOOL PROFILE & ABOUT / SUPPORT
                  final supportOrSchoolSection = isSchoolRole
                      ? GSection(
                          title: 'School & Institution',
                          subtitle: 'Taleem-wa-Tarbiyat School System',
                          icon: GIcons.student,
                          iconColor: c.brand,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'A Project of Gulzar Madina Welfare Foundation (GMWF)',
                                style: GText.body2(c.textSecondary),
                              ),
                              const SizedBox(height: Gsp.sp3),
                              SizedBox(
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                  icon: const Icon(Icons.info_outline_rounded, size: 16),
                                  label: const Text('About Taleem-wa-Tarbiyat School'),
                                  onPressed: () {
                                    final bId = widget.userData['branchId']?.toString() ?? 'all';
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => Scaffold(
                                          appBar: AppBar(
                                            title: const Text('About Taleem-wa-Tarbiyat School', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                            leading: const BackButton(),
                                          ),
                                          body: SchoolAboutView(branchId: bId),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        )
                      : GSection(
                          title: 'Support & Help Center',
                          subtitle: 'FAQs, diagnostics & technical helpdesk',
                          icon: Icons.support_agent_rounded,
                          iconColor: c.info,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Need assistance or want to report an issue? Open the helpdesk.',
                                style: GText.body2(c.textSecondary),
                              ),
                              const SizedBox(height: Gsp.sp3),
                              SizedBox(
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                  icon: const Icon(Icons.help_outline_rounded, size: 16),
                                  label: const Text('Open Support & Help Center'),
                                  onPressed: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => const SupportPage(),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        );

                  // CLOUD SYNC & OFFLINE STORAGE
                  final syncSection = ValueListenableBuilder<bool>(
                    valueListenable: QuotaService.isQuotaExhaustedNotifier,
                    builder: (context, _, _) => ValueListenableBuilder(
                      valueListenable: DebouncedBoxListenable.shared(Hive.box(LocalStorageService.syncBox)),
                      builder: (context, box, _) {
                        final pending = box.length;
                        final isPaused = QuotaService.isPausedForDailyReset;
                        final pausedUntil = QuotaService.dailyResetPauseUntil;
                        final isClean = pending == 0;
                        final statusColor = isPaused ? c.danger : (isClean ? c.success : c.warning);

                        return GSection(
                          title: 'Cloud Sync & Storage',
                          subtitle: isPaused
                              ? 'Daily quota paused until ${DateFormat('h:mm a').format(pausedUntil!.toLocal())}'
                              : (isClean ? 'All records synchronized' : '$pending offline records waiting'),
                          icon: isPaused
                              ? Icons.cloud_off_rounded
                              : (isClean ? Icons.cloud_done_rounded : Icons.cloud_sync_rounded),
                          iconColor: statusColor,
                          action: AppChip(
                            label: isPaused ? 'Paused' : (isClean ? 'Synced' : '$pending queued'),
                            state: isPaused ? AppChipState.danger : (isClean ? AppChipState.active : AppChipState.warning),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isPaused
                                    ? 'Uploads pause until daily reset. All local records remain 100% safe offline.'
                                    : (isClean
                                        ? 'Local offline queue is clean and backed up to Cloud Firestore.'
                                        : 'Unsynced records are stored safely on this device. Force an upload or inspect the queue.'),
                                style: GText.body2(c.textSecondary),
                              ),
                              const SizedBox(height: Gsp.sp3),
                              Row(
                                children: [
                                  Expanded(
                                    child: FilledButton.icon(
                                      icon: const Icon(Icons.rocket_launch_rounded, size: 16),
                                      label: const Text('Force Upload'),
                                      onPressed: () async {
                                        await HiddenForceUploader.instance.runSilentForceUpload();
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: Gsp.sp2),
                                  OutlinedButton.icon(
                                    icon: const Icon(Icons.medical_services_outlined, size: 16),
                                    label: const Text('Queue Doctor'),
                                    onPressed: () => QueueDoctorDialog.show(context),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  );

                  int boxCount(String name) => Hive.isBoxOpen(name) ? Hive.box(name).length : 0;
                  final cacheTiles = [
                    ('Patients', boxCount(LocalStorageService.patientsBox), GIcons.patient, c.chart1),
                    ('Donations', boxCount(LocalStorageService.donationsBox), GIcons.donation, c.chart2),
                    ('Employees', boxCount(LocalStorageService.employeesBox), GIcons.attendance, c.info),
                    ('School', boxCount(LocalStorageService.schoolStudentsBox), GIcons.student, c.brand),
                    ('Madrassa', boxCount(LocalStorageService.madrassaStudentsBox), GIcons.madrassa, c.success),
                    ('Sync Queue', boxCount(LocalStorageService.syncBox), GIcons.sync, c.warning),
                  ];

                  final storageSection = GSection(
                    title: 'Local Cache & Storage',
                    subtitle: 'Offline Hive records on this device',
                    icon: GIcons.inventory,
                    iconColor: c.chart3,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        const cols = 3;
                        final w = (constraints.maxWidth - Gsp.sp2 * (cols - 1)) / cols;
                        return Wrap(
                          spacing: Gsp.sp2,
                          runSpacing: Gsp.sp2,
                          children: [
                            for (final (label, count, icon, color) in cacheTiles)
                              Container(
                                width: w,
                                padding: const EdgeInsets.symmetric(horizontal: Gsp.sp2 + 2, vertical: Gsp.sp2),
                                decoration: BoxDecoration(
                                  color: c.surfaceSunken,
                                  borderRadius: Gr.input,
                                  border: Border.all(color: c.border),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Icon(icon, size: 13, color: color),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: Text(
                                            label,
                                            style: GText.caption(c.textMuted),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      GFormat.count(count),
                                      style: GText.body1Bold(c.textPrimary).copyWith(
                                        fontFeatures: const [FontFeature.tabularFigures()],
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

                  final devicesSection = GSection(
                    title: 'Devices & Diagnostics',
                    subtitle: 'Biometric terminals & system tools',
                    icon: Icons.fingerprint_rounded,
                    iconColor: c.accent,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        OutlinedButton.icon(
                          icon: const Icon(Icons.fingerprint_rounded, size: 16),
                          label: const Text('Biometric Devices'),
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => BiometricDeviceManagerPage(
                                  branchId: (widget.userData['branchId'] ?? 'main').toString(),
                                  currentUserRole: roleStr,
                                ),
                              ),
                            );
                          },
                        ),
                        if (isChairmanOrHq) ...[
                          const SizedBox(height: Gsp.sp2),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.terminal_rounded, size: 16),
                            label: const Text('Python Terminal'),
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(builder: (_) => const PythonTerminalScreen()),
                              );
                            },
                          ),
                        ],
                      ],
                    ),
                  );

                  // APPEARANCE: VISUAL THEME (Card 1) + LANGUAGE & INTERFACE (Card 2)
                  final visualThemeSection = GSection(
                    title: context.tr('visual_theme'),
                    subtitle: '${UserThemeService.getThemeChoice(userPrefKey).label} · ${UserThemeService.isDarkMode(userPrefKey) ? 'Dark' : 'Light'}',
                    icon: GIcons.palette,
                    iconColor: c.accent,
                    child: _buildThemeChoiceSelector(t, userPrefKey),
                  );

                  final personalizationSection = GSection(
                    title: 'Language & Interface',
                    subtitle: '${activeLanguage == 'ur' ? 'Urdu' : 'English'} · ${activeRadius.toInt()}px · ${(activeFontScale * 100).round()}%',
                    icon: GIcons.settings,
                    iconColor: c.brand,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                              // 0. Language Selector (Available for all roles)
                              _buildSegmentedSelector<String>(
                                t,
                                'language',
                                activeLanguage,
                                {
                                  'en': 'English',
                                  'ur': 'اردو (Urdu)',
                                },
                                (lang) async {
                                  await UserLanguageService.setLanguage(lang, explicitUserKey: userPrefKey);
                                  UserThemeService.notifyThemeChanged();
                                  setState(() {});
                                },
                              ),
                              _divider(t),

                              // Advanced Card Radius & Font Scaling (Only for Chairman & HQ Manager)
                              // Theme Color picker disabled: app uses unified visual themes.
                              if (isChairmanOrHq) ...[
                                // ignore: dead_code
                                if (false) ...[
                                  Row(
                                    children: [
                                      Icon(Icons.color_lens_outlined, color: t.accent),
                                      const SizedBox(width: 8),
                                      Text(
                                        context.tr('theme_color'),
                                        style: _getStyle(t, size: 14, weight: FontWeight.bold),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: Row(
                                      children: [
                                        _buildColorPill(t, 'Preset Default', null, t.accentGradient.colors.first),
                                        _buildColorPill(t, 'Jade Emerald', '#0F8A6B', SoftPalette.jadeEmerald),
                                        _buildColorPill(t, 'Royal Violet', '#7650CC', SoftPalette.royalViolet),
                                        _buildColorPill(t, 'Cobalt Blue', '#3D60DD', SoftPalette.cobaltBlue),
                                        _buildColorPill(t, 'CEO Steel Blue', '#4A7FB5', SoftPalette.blue500),
                                        _buildColorPill(t, 'Gold Authority', '#B8860B', SoftPalette.amber400),
                                        _buildColorPill(t, 'Electric Blue', '#0047AB', SoftPalette.blue600),
                                        _buildColorPill(t, 'Sapphire Indigo', '#2C4A8F', SoftPalette.blue600),
                                        _buildColorPill(t, 'Midnight Slate', '#3A5178', SoftPalette.blue600),
                                        _buildColorPill(t, 'Emerald Mint', '#00A86B', SoftPalette.emerald400),
                                        _buildColorPill(t, 'Forest Sage', '#2E7D5B', SoftPalette.emerald550),
                                        _buildColorPill(t, 'Executive Teal', '#0E6E63', SoftPalette.teal600),
                                        _buildColorPill(t, 'Clinical Cyan', '#0E7C90', SoftPalette.cyan550),
                                        _buildColorPill(t, 'Royal Indigo', '#4B0082', SoftPalette.violet750),
                                        _buildColorPill(t, 'Clinical Teal', '#008080', SoftPalette.teal550),
                                        _buildColorPill(t, 'Slate Plum', '#5E5490', SoftPalette.violet600),
                                        _buildColorPill(t, 'Warm Rose', '#C2185B', SoftPalette.pink550),
                                        _buildColorPill(t, 'Sunset Amber', '#D97706', SoftPalette.orange400),
                                        _buildColorPill(t, 'Crimson Red', '#DC2626', SoftPalette.red500),
                                        _buildCustomHexColorPill(t),
                                      ],
                                    ),
                                  ),
                                  _divider(t),
                                ],

                                // 2. Card corner radius choices
                                _buildSegmentedSelector<double>(
                                  t,
                                  'card_radius',
                                  activeRadius,
                                  {
                                    8.0: 'sharp',
                                    16.0: 'medium',
                                    24.0: 'round',
                                  },
                                  (radius) async {
                                    await box.put('card_radius', radius);
                                    UserThemeService.notifyThemeChanged();
                                    setState(() {});
                                  },
                                ),
                                _divider(t),

                                // 3. Text scaling scale slider/selector
                                _buildSegmentedSelector<double>(
                                  t, 
                                  'font_scale', 
                                  activeFontScale, 
                                  {
                                    0.85: 'small',
                                    1.0: 'medium',
                                    1.15: 'large',
                                    1.30: 'extra_large',
                                  }, 
                                  (scale) async {
                                    await box.put('font_scale', scale);
                                    UserThemeService.notifyThemeChanged();
                                    setState(() {});
                                  }
                                ),
                                _divider(t),
                              ],

                              // 4. Frosted Glass Dialog Blur
                              SwitchListTile(
                                value: isDialogBlur,
                                activeThumbColor: t.accent,
                                onChanged: (val) async {
                                  await box.put('dialog_blur_enabled', val);
                                  setState(() {});
                                },
                                secondary: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: t.accent.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Icon(
                                    Icons.blur_on_rounded,
                                    color: t.accent,
                                    size: 20,
                                  ),
                                ),
                                title: Text(
                                  'Frosted Dialog Backdrop Blur',
                                  style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 14),
                                ),
                                subtitle: Text(
                                  isDialogBlur
                                      ? 'Active: Softly blurs the app background when any dialog opens'
                                      : 'Disabled: Uses standard dimmed overlay backdrop',
                                  style: TextStyle(color: t.textSecondary, fontSize: 12),
                                ),
                                contentPadding: EdgeInsets.zero,
                              ),
                      ],
                    ),
                  );

                  final kpiStrip = ValueListenableBuilder(
                    valueListenable: DebouncedBoxListenable.shared(Hive.box(LocalStorageService.syncBox)),
                    builder: (context, syncBox, _) {
                      final pending = syncBox.length;
                      final isClean = pending == 0;
                      final isPaused = QuotaService.isPausedForDailyReset;
                      final tiles = [
                        GKpiTile(
                          label: 'Account Role',
                          value: role,
                          icon: Icons.badge_outlined,
                          color: c.brand,
                          caption: branch,
                        ),
                        GKpiTile(
                          label: 'Cloud Sync',
                          value: isPaused ? 'Paused' : (isClean ? 'Synced' : '$pending queued'),
                          icon: isPaused ? Icons.cloud_off_rounded : (isClean ? Icons.cloud_done_rounded : Icons.cloud_sync_rounded),
                          color: isPaused ? c.danger : (isClean ? c.success : c.warning),
                          caption: isClean ? 'Queue clean' : 'Offline records pending',
                          onTap: () => QueueDoctorDialog.show(context),
                        ),
                        GKpiTile(
                          label: 'Appearance',
                          value: isDarkMode ? 'Dark' : 'Light',
                          icon: isDarkMode ? GIcons.darkMode : GIcons.lightMode,
                          color: c.accent,
                          caption: '${activeLanguage == 'ur' ? 'Urdu' : 'English'} · ${activeRadius.toInt()}px radius',
                          onTap: () => UserThemeService.toggleDarkMode(),
                        ),
                        GKpiTile(
                          label: 'App Version',
                          value: 'v${AutoUpdateService.currentVersion}',
                          icon: Icons.system_update_rounded,
                          color: c.info,
                          caption: 'Scale ${(activeFontScale * 100).round()}% · Tap to check',
                          onTap: () async {
                            final info = await AutoUpdateService.checkForUpdates();
                            if (context.mounted) {
                              if (info != null && info.hasUpdate) {
                                UpdateDialogWidget.showUpdateDialogIfNeeded(context, manualCheck: true);
                              } else {
                                AppToast.showSnackBar(
                                  context,
                                  SnackBar(
                                    content: Text('Your GMWF Platform is up to date (v${AutoUpdateService.currentVersion})!'),
                                    backgroundColor: c.success,
                                  ),
                                );
                              }
                            }
                          },
                        ),
                      ];
                      if (isDesktop) {
                        return Row(
                          children: [
                            for (var i = 0; i < tiles.length; i++) ...[
                              if (i > 0) const SizedBox(width: Gsp.sp3),
                              Expanded(child: tiles[i]),
                            ],
                          ],
                        );
                      }
                      return GridView.count(
                        crossAxisCount: 2,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        mainAxisSpacing: Gsp.sp2,
                        crossAxisSpacing: Gsp.sp2,
                        childAspectRatio: 2.1,
                        children: tiles,
                      );
                    },
                  );

                  final footerWidget = Column(
                    children: [
                      const SizedBox(height: 28),
                      Center(
                        child: Text(
                          "GMWF System Hub v${AutoUpdateService.currentVersion}\nDesign & Theming by Antigravity Studio",
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: t.textTertiary,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            height: 1.5,
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],
                  );

                  if (isDesktop) {
                    return Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1440),
                        child: SingleChildScrollView(
                          physics: const BouncingScrollPhysics(),
                          padding: const EdgeInsets.symmetric(horizontal: Gsp.sp5, vertical: Gsp.sp4),
                          child: Column(
                            children: [
                              kpiStrip,
                              const SizedBox(height: Gsp.sp3),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    flex: 4,
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        profileSection,
                                        const SizedBox(height: Gsp.sp3),
                                        supportOrSchoolSection,
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: Gsp.sp4),
                                  Expanded(
                                    flex: 4,
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        syncSection,
                                        const SizedBox(height: Gsp.sp3),
                                        storageSection,
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: Gsp.sp4),
                                  Expanded(
                                    flex: 5,
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        personalizationSection,
                                        const SizedBox(height: Gsp.sp3),
                                        devicesSection,
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: Gsp.sp3),
                              visualThemeSection,
                              footerWidget,
                            ],
                          ),
                        ),
                      ),
                    );
                  }

                  // Mobile-first layout: compact category filter bar + single-column cards
                  final showAppearance = _mobileTab == 0 || _mobileTab == 1;
                  final showAccount = _mobileTab == 0 || _mobileTab == 2;
                  final showSystem = _mobileTab == 0 || _mobileTab == 3;

                  return Column(
                    children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                        decoration: BoxDecoration(
                          color: t.bgCard,
                          border: Border(
                            bottom: BorderSide(color: t.bgRule, width: 1),
                          ),
                        ),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (final tab in const [
                                (0, 'All', Icons.grid_view_rounded),
                                (1, 'Appearance', Icons.palette_outlined),
                                (2, 'Account', Icons.person_outline_rounded),
                                (3, 'Sync & Tools', Icons.sync_rounded),
                              ])
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: InkWell(
                                    onTap: () => setState(() => _mobileTab = tab.$1),
                                    borderRadius: BorderRadius.circular(20),
                                    child: AnimatedContainer(
                                      duration: const Duration(milliseconds: 180),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 7),
                                      decoration: BoxDecoration(
                                        color: _mobileTab == tab.$1
                                            ? t.accent
                                            : t.bgCardAlt,
                                        borderRadius: BorderRadius.circular(20),
                                        border: Border.all(
                                          color: _mobileTab == tab.$1
                                              ? t.accent
                                              : t.bgRule,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            tab.$3,
                                            size: 14,
                                            color: _mobileTab == tab.$1
                                                ? SoftPalette.gray50
                                                : t.textSecondary,
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            tab.$2,
                                            style: TextStyle(
                                              color: _mobileTab == tab.$1
                                                  ? SoftPalette.gray50
                                                  : t.textPrimary,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          physics: const BouncingScrollPhysics(),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (showAppearance) ...[
                                personalizationSection,
                                const SizedBox(height: Gsp.sp3),
                                visualThemeSection,
                                const SizedBox(height: Gsp.sp3),
                              ],
                              if (showAccount) ...[
                                profileSection,
                                const SizedBox(height: Gsp.sp3),
                                supportOrSchoolSection,
                                const SizedBox(height: Gsp.sp3),
                              ],
                              if (showSystem) ...[
                                syncSection,
                                const SizedBox(height: Gsp.sp3),
                                storageSection,
                                const SizedBox(height: Gsp.sp3),
                                devicesSection,
                              ],
                              footerWidget,
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// LOGOUT TILE
// ─────────────────────────────────────────────────────────────────────────────

class _LogoutTile extends StatefulWidget {
  final RoleThemeData t;
  const _LogoutTile({required this.t});

  @override
  State<_LogoutTile> createState() => _LogoutTileState();
}

class _LogoutTileState extends State<_LogoutTile> {
  bool _loading = false;

  Future<void> _confirmAndLogout() async {
    final confirmed = await showLogoutDialog(
      context,
      subtitle: 'Are you sure you want to sign out of your account?',
    );

    if (confirmed != true || !mounted) return;

    setState(() => _loading = true);
    try {
      await AuthService().signOut();
      if (mounted) {
        Navigator.pushNamedAndRemoveUntil(context, '/login', (_) => false);
        return;
      }
    } catch (e) {
      debugPrint('[SettingsPage] Logout error: $e');
      if (mounted) {
        AppToast.showSnackBar(context, 
          const SnackBar(content: Text('Sign-out failed. Please try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: _loading ? null : _confirmAndLogout,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: SoftPalette.red400.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: SoftPalette.red400.withValues(alpha: 0.15)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: SoftPalette.red400.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: _loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: SoftPalette.red400,
                          ),
                        )
                      : const Icon(Icons.logout_rounded, color: SoftPalette.red400, size: 20),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Sign Out',
                        style: TextStyle(
                          color: t.textPrimary,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Log out of your current session',
                        style: TextStyle(color: t.textSecondary, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: SoftPalette.red400.withValues(alpha: 0.5), size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
