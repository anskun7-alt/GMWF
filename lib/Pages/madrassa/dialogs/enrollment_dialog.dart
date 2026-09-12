// Imports
import 'dart:async';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../madrassa_strings.dart';
import '../widgets/madrassa_common_widgets.dart';
import '../../../services/auth_service.dart';
import '../../../../services/image_upload_service.dart';
import '../../../../services/zkteco_network_service.dart';
import '../../../../services/local_storage_service.dart';
import '../../../../realtime/realtime_manager.dart';
import '../../../../realtime/realtime_events.dart';
import '../../../../widgets/media_upload_tile.dart';
import '../../../utils/formatters.dart';
import '../utils/madrassa_local_storage.dart';
import '../../../services/user_theme_service.dart';
import '../../../../services/sync_service.dart';

void showAddStudentDialog(
  BuildContext context,
  String branchId, {
  dynamic student,
  required String username,
  required String role,
}) {
  final isEdit = student != null;
  final studentData = isEdit 
      ? (student is DocumentSnapshot 
          ? student.data() as Map<String, dynamic> 
          : Map<String, dynamic>.from(student as Map))
      : null;
  final studentId = isEdit 
      ? (student is DocumentSnapshot ? student.id : (student as Map)['id']?.toString() ?? '')
      : '';

  final nameCtrl = TextEditingController(text: studentData?['name']);
  final rollCtrl = TextEditingController(text: studentData?['rollNumber']);
  final studentCnicCtrl = TextEditingController(text: studentData?['studentCnic']);
  final initialPin = isEdit
      ? (ZkTecoNetworkService.getCredentialByEntityId(studentId)?.biometricPin ?? studentData?['biometricPin']?.toString() ?? '')
      : '';
  final pinCtrl = TextEditingController(text: initialPin);
  final guardianNameCtrl = TextEditingController(text: studentData?['guardianName']);
  final guardianCnicCtrl = TextEditingController(text: studentData?['guardianCnic']);
  final contactCtrl = TextEditingController(text: studentData?['contactPhone']);
  final gUsernameCtrl = TextEditingController();
  final gPassCtrl = TextEditingController();
  final prevMadrassaCtrl = TextEditingController(text: studentData?['prevMadrassaName']);
  final prevHifzCtrl = TextEditingController(text: studentData?['prevHifzLines']?.toString());

  DateTime joinDate = DateTime.now();
  final joinDateVal = studentData?['joinDate'];
  if (joinDateVal is Timestamp) {
    joinDate = joinDateVal.toDate();
  } else if (joinDateVal is String) {
    joinDate = DateTime.tryParse(joinDateVal) ?? DateTime.now();
  }
  bool hasPrevMadrassa = studentData?['hasPrevMadrassa'] ?? false;
  bool linkAccount = false;
  bool isSaving = false;
  bool isSearching = false;
  Map<String, dynamic>? foundGuardian;
  Timer? debounce;
  bool initializedGuardian = false;
  bool overrideGuardianCredentials = false;
  bool isUsernameSearching = false;
  Map<String, dynamic>? usernameMatchedGuardian;
  Timer? usernameDebounce;
  
  // Image handling for student avatar
  Uint8List? selectedImageBytes;
  String? studentPhotoBase64 = studentData?['photoUrl'];

  String? bFormBase64 = studentData?['bFormUrl'] ?? studentData?['bFormBase64'];
  String? guardianCnicBase64 = studentData?['guardianCnicUrl'] ?? studentData?['guardianCnicBase64'];
  String? hifzCertificateBase64 = studentData?['hifzCertificateUrl'] ?? studentData?['hifzCertificateBase64'];

  String? nameError;
  String? rollError;
  String? studentCnicError;
  String? guardianCnicError;
  String? guardianNameError;
  String? contactError;
  String? gUsernameError;
  String? gPassError;

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setDs) {
        if (isEdit && !initializedGuardian) {
          initializedGuardian = true;
          final cnic = guardianCnicCtrl.text.trim();
          final phone = contactCtrl.text.trim();
          final String sId = studentId ?? ((studentData != null) ? (studentData!['id']?.toString() ?? '') : '');

          WidgetsBinding.instance.addPostFrameCallback((_) async {
            setDs(() => isSearching = true);
            try {
              // 1. Check local Hive usersBox first (0ms, 0 quota)
              if (Hive.isBoxOpen(LocalStorageService.usersBox)) {
                final box = Hive.box(LocalStorageService.usersBox);
                for (final k in box.keys) {
                  final u = box.get(k);
                  if (u is Map) {
                    final uCnic = (u['cnic'] ?? '').toString().trim();
                    final uPhone = (u['phone'] ?? '').toString().trim();
                    final uStudentIds = List<String>.from(u['studentIds'] ?? []);

                    final matches = (sId.isNotEmpty && uStudentIds.contains(sId)) ||
                        (cnic.isNotEmpty && uCnic == cnic) ||
                        (phone.isNotEmpty && uPhone == phone);

                    if (matches) {
                      if (ctx.mounted) {
                        setDs(() {
                          foundGuardian = {'uid': u['uid']?.toString() ?? k.toString(), ...Map<String, dynamic>.from(u)};
                          gUsernameCtrl.text = u['username'] ?? '';
                          gPassCtrl.text = u['password'] ?? '';
                          isSearching = false;
                        });
                      }
                      return;
                    }
                  }
                }
              }

              // 2. Online fallback only if not in local cache
              QuerySnapshot? q;

              if (sId.isNotEmpty) {
                q = await FirebaseFirestore.instance
                    .collection('users')
                    .where('studentIds', arrayContains: sId)
                    .limit(1)
                    .get();
                if (q.docs.isEmpty) {
                  q = await FirebaseFirestore.instance
                      .collection('users')
                      .where('studentId', isEqualTo: sId)
                      .limit(1)
                      .get();
                }
              }

              if ((q == null || q.docs.isEmpty) && cnic.isNotEmpty) {
                q = await FirebaseFirestore.instance
                    .collection('users')
                    .where('role', isEqualTo: 'Madrassa Guardian')
                    .where('cnic', isEqualTo: cnic)
                    .limit(1)
                    .get();
              }

              if ((q == null || q.docs.isEmpty) && phone.isNotEmpty) {
                q = await FirebaseFirestore.instance
                    .collection('users')
                    .where('role', isEqualTo: 'Madrassa Guardian')
                    .where('phone', isEqualTo: phone)
                    .limit(1)
                    .get();
              }

              if (ctx.mounted && q != null && q.docs.isNotEmpty) {
                final g = q.docs.first;
                final data = g.data() as Map<String, dynamic>;
                setDs(() {
                  foundGuardian = {'uid': g.id, ...data};
                  gUsernameCtrl.text = data['username'] ?? '';
                  gPassCtrl.text = data['password'] ?? '';
                  isSearching = false;
                });
              } else if (ctx.mounted) {
                setDs(() => isSearching = false);
              }
            } catch (e) {
              if (ctx.mounted) setDs(() => isSearching = false);
            }
          });
        }

        // Helper to pick student image with Camera or Gallery option
        Future<void> pickStudentImage() async {
          final ImageSource? source = await showModalBottomSheet<ImageSource>(
            context: context,
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
            builder: (ctx) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Text(
                      context.isUrdu ? 'طالب علم کی تصویر منتخب کریں' : 'Choose Student Photo',
                      style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.camera_alt_outlined, color: Color(0xFF008080)),
                    title: Text(
                      context.isUrdu ? 'کیمرہ سے تصویر لیں' : 'Take Photo with Camera',
                      style: context.urduStyle(),
                    ),
                    onTap: () => Navigator.pop(ctx, ImageSource.camera),
                  ),
                  ListTile(
                    leading: const Icon(Icons.photo_library_outlined, color: Color(0xFF008080)),
                    title: Text(
                      context.isUrdu ? 'گیلری سے منتخب کریں' : 'Choose from Gallery',
                      style: context.urduStyle(),
                    ),
                    onTap: () => Navigator.pop(ctx, ImageSource.gallery),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          );

          if (source == null) return;
          final b64 = await ImageUploadService.pickAndProcessImage(source: source);
          if (b64 != null && b64.isNotEmpty) {
            setDs(() {
              studentPhotoBase64 = b64;
              selectedImageBytes = ImageUploadService.decodeBase64ToBytes(b64);
            });
          }
        }

        // Helper to check username uniqueness (Local Hive first, Firestore optimized)
        void checkUsernameUniqueness(String username) {
          usernameDebounce?.cancel();
          final usernameInput = username.trim().toLowerCase();
          if (usernameInput.isEmpty) {
            setDs(() {
              usernameMatchedGuardian = null;
              isUsernameSearching = false;
            });
            return;
          }
          
          usernameDebounce = Timer(const Duration(milliseconds: 300), () async {
            setDs(() => isUsernameSearching = true);
            try {
              // 1. Check local Hive usersBox first
              if (Hive.isBoxOpen(LocalStorageService.usersBox)) {
                final uBox = Hive.box(LocalStorageService.usersBox);
                for (final key in uBox.keys) {
                  final val = uBox.get(key);
                  if (val is Map) {
                    final map = Map<String, dynamic>.from(val);
                    final uLower = (map['usernameLower'] ?? map['username'] ?? '').toString().toLowerCase();
                    final email = (map['email'] ?? '').toString().toLowerCase();
                    if (uLower == usernameInput || email == '$usernameInput@gmwf.com') {
                      if (!ctx.mounted) return;
                      setDs(() {
                        usernameMatchedGuardian = {'uid': map['uid'] ?? map['id'] ?? key, ...map};
                        isUsernameSearching = false;
                      });
                      return;
                    }
                  }
                }
              }

              // 2. Query Firestore only if online and not found locally
              final targetEmail = '$usernameInput@gmwf.com';
              var q = await FirebaseFirestore.instance
                  .collection('users')
                  .where('usernameLower', isEqualTo: usernameInput)
                  .limit(1)
                  .get();

              if (q.docs.isEmpty) {
                q = await FirebaseFirestore.instance
                    .collection('users')
                    .where('email', isEqualTo: targetEmail)
                    .limit(1)
                    .get();
              }
                  
              if (!ctx.mounted) return;
              if (q.docs.isNotEmpty) {
                final doc = q.docs.first;
                final data = doc.data();
                if (Hive.isBoxOpen(LocalStorageService.usersBox)) {
                  Hive.box(LocalStorageService.usersBox).put('user:${data['email'] ?? usernameInput}', {'uid': doc.id, ...data});
                }
                setDs(() {
                  usernameMatchedGuardian = {'uid': doc.id, ...data};
                  isUsernameSearching = false;
                });
              } else {
                setDs(() {
                  usernameMatchedGuardian = null;
                  isUsernameSearching = false;
                });
              }
            } catch (_) {
              if (ctx.mounted) setDs(() => isUsernameSearching = false);
            }
          });
        }

        final isDark = UserThemeService.isDarkMode(username);
        final dialogBg = isDark ? const Color(0xFF1E293B) : Colors.white;
        final textPrimary = isDark ? Colors.white : const Color(0xFF1E293B);

        return AlertDialog(
          backgroundColor: dialogBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: Text(
            isEdit ? 'Edit Student Details' : context.l.enrollNewStudent,
            style: context.urduStyle(style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: textPrimary)),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Avatar picker
                Center(
                  child: GestureDetector(
                    onTap: pickStudentImage,
                    child: CircleAvatar(
                      radius: 44,
                      backgroundColor: const Color(0xFF008080).withValues(alpha: 0.08),
                      child: (studentPhotoBase64 != null && studentPhotoBase64!.trim().isNotEmpty)
                          ? ClipOval(
                              child: studentPhotoBase64!.startsWith('http')
                                  ? Image.network(
                                      studentPhotoBase64!,
                                      width: 88,
                                      height: 88,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => const Icon(Icons.camera_alt, size: 28, color: Color(0xFF008080)),
                                    )
                                  : (ImageUploadService.decodeBase64ToBytes(studentPhotoBase64) != null
                                      ? Image.memory(
                                          ImageUploadService.decodeBase64ToBytes(studentPhotoBase64)!,
                                          width: 88,
                                          height: 88,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, __, ___) => const Icon(Icons.camera_alt, size: 28, color: Color(0xFF008080)),
                                        )
                                      : const Icon(Icons.camera_alt, size: 28, color: Color(0xFF008080))),
                            )
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.camera_alt_outlined, size: 26, color: Color(0xFF008080)),
                                const SizedBox(height: 2),
                                Text(
                                  context.isUrdu ? 'تصویر شامل کریں' : 'Add Photo',
                                  style: context.urduStyle(
                                    style: const TextStyle(fontSize: 10, color: Color(0xFF008080), fontWeight: FontWeight.bold),
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                
                sectionLabel(context.l.studentInformation),
                const SizedBox(height: 10),
                buildTf(
                  nameCtrl,
                  context.l.studentFullName,
                  Icons.person,
                  context,
                  isRequired: true,
                  errorText: nameError,
                  onChanged: (v) {
                    if (nameError != null) setDs(() => nameError = null);
                  },
                ),
                const SizedBox(height: 10),
                buildTf(
                  rollCtrl,
                  context.l.rollNumber,
                  Icons.badge,
                  context,
                  isRequired: true,
                  errorText: rollError,
                  onChanged: (v) {
                    if (rollError != null) setDs(() => rollError = null);
                  },
                ),
                const SizedBox(height: 10),
                buildTf(
                  studentCnicCtrl,
                  '${context.l.studentCnic} (XXXXX-XXXXXXX-X)',
                  Icons.credit_card,
                  context,
                  formatters: [CNICInputFormatter(), LengthLimitingTextInputFormatter(15)],
                  inputType: TextInputType.number,
                  errorText: studentCnicError,
                  onChanged: (v) {
                    if (studentCnicError != null) setDs(() => studentCnicError = null);
                  },
                ),
                const SizedBox(height: 10),
                buildTf(
                  pinCtrl,
                  'Biometric Scanner PIN (Optional)',
                  Icons.fingerprint_rounded,
                  context,
                  hint: 'e.g. 3015',
                  inputType: TextInputType.number,
                  formatters: [FilteringTextInputFormatter.digitsOnly],
                ),
                const SizedBox(height: 10),
                InkWell(
                  onTap: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: joinDate,
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (d != null) setDs(() => joinDate = d);
                  },
                  child: IgnorePointer(
                    child: buildTf(
                      TextEditingController(text: DateFormat('dd MMMM yyyy').format(joinDate)),
                      context.l.joinDate,
                      Icons.calendar_today,
                      context,
                      enabled: false,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                buildTf(prevHifzCtrl, context.l.hifzBeforeJoining, Icons.auto_stories_outlined, context, inputType: TextInputType.number),
                const SizedBox(height: 16),
                SwitchListTile(
                  title: Text(context.l.previousMadrassa,
                      style: context.urduStyle(style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold))),
                  value: hasPrevMadrassa,
                  onChanged: (v) => setDs(() => hasPrevMadrassa = v),
                ),
                if (hasPrevMadrassa) ...[
                  buildTf(prevMadrassaCtrl, context.l.previousMadrassaName, Icons.school_outlined, context),
                ],
                const SizedBox(height: 20),
                sectionLabel(context.l.guardianInformation),
                const SizedBox(height: 4),
                Text(
                  context.t('Optional — leave blank if not applicable'),
                  style: const TextStyle(fontSize: 11, color: Colors.grey, fontStyle: FontStyle.italic),
                ),
                const SizedBox(height: 10),
                
                buildTf(
                  guardianCnicCtrl,
                  '${context.l.guardianCnic} (XXXXX-XXXXXXX-X)',
                  Icons.credit_card,
                  context,
                  errorText: guardianCnicError,
                  formatters: [CNICInputFormatter(), LengthLimitingTextInputFormatter(15)],
                  inputType: TextInputType.number,
                  onChanged: (v) {
                    if (guardianCnicError != null) setDs(() => guardianCnicError = null);
                    if (v.length == 15) {
                      debounce?.cancel();
                      debounce = Timer(const Duration(milliseconds: 300), () async {
                        setDs(() => isSearching = true);

                        // 1. Check local usersBox first
                        Map<String, dynamic>? localFound;
                        if (Hive.isBoxOpen(LocalStorageService.usersBox)) {
                          final uBox = Hive.box(LocalStorageService.usersBox);
                          for (final key in uBox.keys) {
                            final val = uBox.get(key);
                            if (val is Map) {
                              final map = Map<String, dynamic>.from(val);
                              final cnic = map['cnic']?.toString().replaceAll(RegExp(r'\D'), '') ?? '';
                              final searchCnic = v.replaceAll(RegExp(r'\D'), '');
                              final role = map['role']?.toString() ?? '';
                              if (cnic.isNotEmpty && cnic == searchCnic && (role == 'Madrassa Guardian' || role.contains('Guardian'))) {
                                localFound = {'uid': map['uid'] ?? map['id'] ?? key, ...map};
                                break;
                              }
                            }
                          }
                        }

                        if (localFound != null) {
                          if (!ctx.mounted) return;
                          setDs(() {
                            foundGuardian = localFound;
                            if (guardianNameCtrl.text.trim().isEmpty) {
                              guardianNameCtrl.text = localFound!['name'] ?? '';
                            }
                            if (contactCtrl.text.trim().isEmpty) {
                              contactCtrl.text = localFound!['phone'] ?? '';
                            }
                            gUsernameCtrl.text = localFound!['username'] ?? '';
                            gPassCtrl.text = localFound!['password'] ?? '';
                            isSearching = false;
                            guardianNameError = null;
                            contactError = null;
                          });
                          return;
                        }

                        try {
                          final q = await FirebaseFirestore.instance
                              .collection('users')
                              .where('role', isEqualTo: 'Madrassa Guardian')
                              .where('cnic', isEqualTo: v)
                              .limit(1)
                              .get();
                          
                          if (!ctx.mounted) return;
                          if (q.docs.isNotEmpty) {
                            final g = q.docs.first;
                            final data = g.data();
                            if (Hive.isBoxOpen(LocalStorageService.usersBox)) {
                              Hive.box(LocalStorageService.usersBox).put('user:${data['email'] ?? g.id}', {'uid': g.id, ...data});
                            }
                            setDs(() {
                              foundGuardian = {'uid': g.id, ...data};
                              if (guardianNameCtrl.text.trim().isEmpty) {
                                guardianNameCtrl.text = data['name'] ?? '';
                              }
                              if (contactCtrl.text.trim().isEmpty) {
                                contactCtrl.text = data['phone'] ?? '';
                              }
                              gUsernameCtrl.text = data['username'] ?? '';
                              gPassCtrl.text = data['password'] ?? '';
                              isSearching = false;
                              guardianNameError = null;
                              contactError = null;
                            });
                          } else {
                            setDs(() {
                              foundGuardian = null;
                              isSearching = false;
                              gUsernameCtrl.clear();
                              gPassCtrl.clear();
                            });
                          }
                        } catch (_) {
                          if (ctx.mounted) setDs(() => isSearching = false);
                        }
                      });
                    } else {
                      // CNIC no longer complete/matching - stop treating as a
                      // "found" guardian so fields go back to fully manual edit.
                      if (foundGuardian != null) {
                        setDs(() {
                          foundGuardian = null;
                        });
                      }
                    }
                  },
                ),
                if (isSearching) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator(minHeight: 2)),
                if (foundGuardian != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        const Icon(Icons.check_circle, color: Colors.green, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Existing Guardian Found: ${foundGuardian!['name']} (fields below are editable)',
                            style: const TextStyle(color: Colors.green, fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 10),
                buildTf(
                  guardianNameCtrl,
                  context.l.guardianFullName,
                  Icons.family_restroom,
                  context,
                  errorText: guardianNameError,
                  onChanged: (v) {
                    if (guardianNameError != null) setDs(() => guardianNameError = null);
                  },
                ),
                const SizedBox(height: 10),
                buildTf(
                  contactCtrl,
                  context.l.contactPhone,
                  Icons.phone,
                  context,
                  errorText: contactError,
                  inputType: TextInputType.phone,
                  formatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(11)],
                  onChanged: (v) {
                    if (contactError != null) setDs(() => contactError = null);
                  },
                ),
                
                const SizedBox(height: 16),
                sectionLabel('Student & Guardian Documents'),
                const SizedBox(height: 10),
                MediaUploadTile(
                  label: 'Guardian CNIC Document',
                  icon: Icons.badge_outlined,
                  initialValue: guardianCnicBase64,
                  isDocument: true,
                  onChanged: (val) => setDs(() => guardianCnicBase64 = val),
                ),
                const SizedBox(height: 8),
                MediaUploadTile(
                  label: 'B-Form / Birth Certificate',
                  icon: Icons.assignment_ind_outlined,
                  initialValue: bFormBase64,
                  isDocument: true,
                  onChanged: (val) => setDs(() => bFormBase64 = val),
                ),
                const SizedBox(height: 8),
                MediaUploadTile(
                  label: 'Certificate of Hifz Completion',
                  icon: Icons.workspace_premium_outlined,
                  initialValue: hifzCertificateBase64,
                  isDocument: true,
                  onChanged: (val) => setDs(() => hifzCertificateBase64 = val),
                ),
                
                const SizedBox(height: 16),
                const Divider(),
                if (foundGuardian != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.green.shade200),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.check_circle_rounded, color: Colors.green.shade700, size: 20),
                            const SizedBox(width: 8),
                            Text(
                              context.t('Parent Account Exists & Linked (via CNIC)'),
                              style: TextStyle(
                                color: Colors.green.shade800,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${context.t('Username')}: ${foundGuardian!['username']}',
                          style: TextStyle(color: Colors.green.shade900, fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  sectionLabel('Parent Account Details'),
                  const SizedBox(height: 10),
                  buildTf(
                    gUsernameCtrl,
                    context.l.loginUsername,
                    Icons.badge_outlined,
                    context,
                    enabled: overrideGuardianCredentials,
                    hint: context.l.loginUsernameHint,
                    isRequired: true,
                    errorText: gUsernameError,
                    onChanged: (v) {
                      if (gUsernameError != null) setDs(() => gUsernameError = null);
                    },
                  ),
                  const SizedBox(height: 10),
                  PasswordField(
                    controller: gPassCtrl,
                    label: context.l.loginPassword,
                    isRequired: true,
                    enabled: overrideGuardianCredentials,
                    errorText: gPassError,
                    onChanged: (v) {
                      if (gPassError != null) setDs(() => gPassError = null);
                    },
                  ),
                  const SizedBox(height: 10),
                  CheckboxListTile(
                    title: Text(
                      context.t('Override parent credentials'),
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      context.t('Warning: Overriding will update login credentials for all children linked to this parent.'),
                      style: TextStyle(fontSize: 11, color: Colors.red.shade700),
                    ),
                    value: overrideGuardianCredentials,
                    onChanged: (v) => setDs(() => overrideGuardianCredentials = v ?? false),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                  ),
                ] else ...[
                  SwitchListTile(
                    title: Text(context.l.createLinkAccount, style: context.urduStyle(style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold))),
                    subtitle: Text(context.l.createLinkSubtitle, style: const TextStyle(fontSize: 11)),
                    value: linkAccount,
                    activeThumbColor: const Color(0xFF4F46E5),
                    onChanged: (v) => setDs(() => linkAccount = v),
                  ),
                  if (linkAccount) ...[
                    const SizedBox(height: 10),
                    buildTf(
                      gUsernameCtrl,
                      context.l.loginUsername,
                      Icons.badge_outlined,
                      context,
                      hint: context.l.loginUsernameHint,
                      isRequired: true,
                      errorText: gUsernameError,
                      onChanged: (v) {
                        if (gUsernameError != null) setDs(() => gUsernameError = null);
                        checkUsernameUniqueness(v);
                      },
                    ),
                    if (isUsernameSearching)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 4),
                        child: LinearProgressIndicator(minHeight: 2),
                      ),
                    if (usernameMatchedGuardian != null) ...[
                      const SizedBox(height: 6),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.amber.shade50,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.amber.shade200),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.warning_amber_rounded, color: Colors.amber.shade800, size: 20),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    context.t('Account Exists: Username registered to ${usernameMatchedGuardian!['name']}.'),
                                    style: TextStyle(
                                      color: Colors.amber.shade900,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              context.t('Enrolling will automatically link this student to their existing family portal.'),
                              style: TextStyle(color: Colors.amber.shade800, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    ] else if (gUsernameCtrl.text.trim().isNotEmpty && !isUsernameSearching) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Icon(Icons.check_circle, color: Colors.green, size: 16),
                          const SizedBox(width: 6),
                          Text(
                            context.t('New Parent Account will be created'),
                            style: const TextStyle(color: Colors.green, fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 10),
                    PasswordField(
                      controller: gPassCtrl,
                      label: context.l.loginPassword,
                      isRequired: true,
                      enabled: usernameMatchedGuardian == null, // disable password input if linking to existing username
                      errorText: gPassError,
                      onChanged: (v) {
                        if (gPassError != null) setDs(() => gPassError = null);
                      },
                    ),
                  ],
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(context.l.cancel, style: context.urduStyle())),
            ElevatedButton(
              onPressed: isSaving ? null : () async {
                final nav = Navigator.of(ctx);
                bool isValid = true;
                if (nameCtrl.text.trim().isEmpty) {
                  nameError = context.t('Student name is required');
                  isValid = false;
                } else {
                  nameError = null;
                }

                if (rollCtrl.text.trim().isEmpty) {
                  rollError = context.t('Roll number is required');
                  isValid = false;
                } else {
                  rollError = null;
                }

                if (studentCnicCtrl.text.trim().isNotEmpty && studentCnicCtrl.text.length != 15) {
                  studentCnicError = context.t('Enter a valid 15-character CNIC (e.g. 12345-1234567-1)');
                  isValid = false;
                } else {
                  studentCnicError = null;
                }

                // Guardian info is entirely optional. We only format-validate
                // fields that have actually been filled in - we never force
                // the guardian section to be completed.
                if (guardianCnicCtrl.text.trim().isNotEmpty && guardianCnicCtrl.text.length != 15) {
                  guardianCnicError = context.t('Enter a valid 15-character CNIC (e.g. 12345-1234567-1)');
                  isValid = false;
                } else {
                  guardianCnicError = null;
                }

                guardianNameError = null;

                if (contactCtrl.text.trim().isNotEmpty && contactCtrl.text.trim().length != 11) {
                  contactError = context.t('Enter a valid 11-digit phone number');
                  isValid = false;
                } else {
                  contactError = null;
                }

                // Username/password are only relevant when we're actually
                // creating or updating a guardian login - i.e. an existing
                // guardian was matched, or the teacher opted to link a new
                // account. If no guardian info was entered at all, skip this
                // entirely.
                final hasAnyGuardianInfo = guardianNameCtrl.text.trim().isNotEmpty ||
                    guardianCnicCtrl.text.trim().isNotEmpty ||
                    contactCtrl.text.trim().isNotEmpty;
                final bool isGuardianLinkedOrCreating =
                    (foundGuardian != null || linkAccount) && hasAnyGuardianInfo;

                 if (isGuardianLinkedOrCreating) {
                  if (gUsernameCtrl.text.trim().isEmpty) {
                    gUsernameError = context.t('Username is required');
                    isValid = false;
                  } else {
                    gUsernameError = null;
                  }

                  // Password is required ONLY if we are creating a NEW guardian account (no CNIC match AND no username match),
                  // or if we are overriding the matched guardian credentials.
                  final bool passwordRequired = (foundGuardian == null && usernameMatchedGuardian == null) ||
                      (foundGuardian != null && overrideGuardianCredentials);

                  if (passwordRequired && gPassCtrl.text.trim().isEmpty) {
                    gPassError = context.t('Password is required');
                    isValid = false;
                  } else {
                    gPassError = null;
                  }
                } else {
                  gUsernameError = null;
                  gPassError = null;
                }

                final enteredPin = pinCtrl.text.trim();
                if (enteredPin.isNotEmpty) {
                  final targetEntityId = isEdit ? studentId : '';
                  final conflict = ZkTecoNetworkService.findPinConflict(enteredPin, excludeEntityId: targetEntityId.isNotEmpty ? targetEntityId : null);
                  if (conflict != null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('❌ PIN $enteredPin is already assigned to "${conflict.entityName}" (${conflict.branchId.toUpperCase()} • ${conflict.entityType.toUpperCase()}). Please choose a unique PIN.'),
                        backgroundColor: Colors.red,
                      ),
                    );
                    return;
                  }
                }

                if (!isValid) {
                  setDs(() {});
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        context.t('Please correct all validation errors to continue'),
                        style: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null),
                      ),
                      backgroundColor: Colors.red,
                    ),
                  );
                  return;
                }

                setDs(() => isSaving = true);
                try {
                  String? gUid;
                  String bId = branchId.toLowerCase().trim();
                  DocumentReference? sRef;
                  if (isGuardianLinkedOrCreating) {
                    if (foundGuardian != null) {
                      gUid = foundGuardian!['uid'];
                      final gUpdates = <String, dynamic>{
                        ...foundGuardian!,
                        'uid': gUid,
                        'phone': contactCtrl.text.trim(),
                        'name': guardianNameCtrl.text.trim(),
                        'cnic': guardianCnicCtrl.text.trim(),
                        'role': 'Madrassa Guardian',
                        'branchId': branchId,
                        if (overrideGuardianCredentials) ...{
                          'username': gUsernameCtrl.text.trim(),
                          'usernameLower': gUsernameCtrl.text.trim().toLowerCase(),
                          'password': gPassCtrl.text.trim(),
                        },
                        if (isEdit) 'studentIds': (foundGuardian!['studentIds'] is List ? List.from(foundGuardian!['studentIds']) : [])..add(studentId),
                      };

                      if (Hive.isBoxOpen(LocalStorageService.usersBox)) {
                        final key = gUpdates['email'] != null ? 'user:${gUpdates['email']}' : 'user:$gUid';
                        await Hive.box(LocalStorageService.usersBox).put(key, gUpdates);
                        await Hive.box(LocalStorageService.usersBox).flush();
                      }

                      try {
                        RealtimeManager().sendMessage(RealtimeEvents.payload(
                          type: RealtimeEvents.saveUser,
                          data: gUpdates,
                          branchId: branchId,
                        ));
                      } catch (_) {}

                      await LocalStorageService.enqueueSync({
                        'type': 'save_user',
                        'uid': gUid,
                        'branchId': branchId,
                        'data': gUpdates,
                      });
                      unawaited(SyncService().triggerUpload());
                    } else if (usernameMatchedGuardian != null) {
                      gUid = usernameMatchedGuardian!['uid'];
                      final gUpdates = <String, dynamic>{
                        ...usernameMatchedGuardian!,
                        'uid': gUid,
                        'phone': contactCtrl.text.trim(),
                        'name': guardianNameCtrl.text.trim(),
                        'cnic': guardianCnicCtrl.text.trim(),
                        'role': 'Madrassa Guardian',
                        'branchId': branchId,
                        if (isEdit) 'studentIds': (usernameMatchedGuardian!['studentIds'] is List ? List.from(usernameMatchedGuardian!['studentIds']) : [])..add(studentId),
                      };

                      if (Hive.isBoxOpen(LocalStorageService.usersBox)) {
                        final key = gUpdates['email'] != null ? 'user:${gUpdates['email']}' : 'user:$gUid';
                        await Hive.box(LocalStorageService.usersBox).put(key, gUpdates);
                        await Hive.box(LocalStorageService.usersBox).flush();
                      }

                      try {
                        RealtimeManager().sendMessage(RealtimeEvents.payload(
                          type: RealtimeEvents.saveUser,
                          data: gUpdates,
                          branchId: branchId,
                        ));
                      } catch (_) {}

                      await LocalStorageService.enqueueSync({
                        'type': 'save_user',
                        'uid': gUid,
                        'branchId': branchId,
                        'data': gUpdates,
                      });
                      unawaited(SyncService().triggerUpload());
                    } else if (linkAccount) {
                      final usernameInput = gUsernameCtrl.text.trim().toLowerCase();
                      final targetEmail = '$usernameInput@gmwf.com';
                      gUid = 'guardian_$usernameInput';

                      final gUpdates = <String, dynamic>{
                        'uid': gUid,
                        'username': usernameInput,
                        'usernameLower': usernameInput,
                        'email': targetEmail,
                        'password': gPassCtrl.text.trim(),
                        'role': 'Madrassa Guardian',
                        'branchId': branchId,
                        'branchName': 'Madrassa',
                        'phone': contactCtrl.text.trim(),
                        'name': guardianNameCtrl.text.trim(),
                        'cnic': guardianCnicCtrl.text.trim(),
                        'createdAt': DateTime.now().toIso8601String(),
                        'studentIds': isEdit ? [studentId] : [],
                      };

                      try {
                        final createdUid = await AuthService().signUp(
                          email: targetEmail,
                          password: gPassCtrl.text.trim(),
                          username: usernameInput,
                          role: 'Madrassa Guardian',
                          branchId: branchId,
                          branchName: 'Madrassa',
                          phone: contactCtrl.text.trim(),
                          name: guardianNameCtrl.text.trim(),
                          cnic: guardianCnicCtrl.text.trim(),
                          studentIds: isEdit ? [studentId] : [],
                        ).timeout(const Duration(seconds: 3));
                        if (createdUid.isNotEmpty) {
                          gUid = createdUid;
                          gUpdates['uid'] = createdUid;
                        }
                      } catch (_) {
                        gUid ??= 'g_${DateTime.now().millisecondsSinceEpoch}';
                        gUpdates['uid'] = gUid;
                      }

                      if (Hive.isBoxOpen(LocalStorageService.usersBox)) {
                        await Hive.box(LocalStorageService.usersBox).put('user:$targetEmail', gUpdates);
                        await Hive.box(LocalStorageService.usersBox).flush();
                      }

                      try {
                        RealtimeManager().sendMessage(RealtimeEvents.payload(
                          type: RealtimeEvents.saveUser,
                          data: gUpdates,
                          branchId: branchId,
                        ));
                      } catch (_) {}

                      await LocalStorageService.enqueueSync({
                        'type': 'save_user',
                        'uid': gUid,
                        'branchId': branchId,
                        'data': gUpdates,
                      });
                      unawaited(SyncService().triggerUpload());
                    }
                  }

                  String photoUrl = studentPhotoBase64 ?? studentData?['photoUrl'] ?? '';
                  if (selectedImageBytes != null) {
                    final b64 = ImageUploadService.processBytesToBase64(selectedImageBytes!);
                    if (b64 != null && b64.isNotEmpty) {
                      photoUrl = b64;
                    }
                  }

                  final finalData = {
                    'name': nameCtrl.text.trim(),
                    'rollNumber': rollCtrl.text.trim(),
                    'studentCnic': studentCnicCtrl.text.trim(),
                    'biometricPin': enteredPin,
                    'guardianName': guardianNameCtrl.text.trim(),
                    'guardianCnic': guardianCnicCtrl.text.trim(),
                    'contactPhone': contactCtrl.text.trim(),
                    'joinDate': Timestamp.fromDate(joinDate),
                    'hasPrevMadrassa': hasPrevMadrassa,
                    'prevMadrassaName': prevMadrassaCtrl.text.trim(),
                    'prevHifzLines': int.tryParse(prevHifzCtrl.text.trim()) ?? 0,
                    'photoUrl': photoUrl,
                    'photoBase64': photoUrl,
                    'studentPhotoBase64': photoUrl,
                    'bFormUrl': bFormBase64 ?? '',
                    'bFormBase64': bFormBase64 ?? '',
                    'guardianCnicUrl': guardianCnicBase64 ?? '',
                    'guardianCnicBase64': guardianCnicBase64 ?? '',
                    'hifzCertificateUrl': hifzCertificateBase64 ?? '',
                    'hifzCertificateBase64': hifzCertificateBase64 ?? '',
                  };

                  final now = DateTime.now();
                  final finalStudentId = await MadrassaLocalStorage.saveStudentLocalAndSync(
                    branchId: branchId,
                    studentId: isEdit ? studentId : '',
                    data: {
                      ...finalData,
                      'branchId': branchId,
                      'status': studentData?['status'] ?? 'active',
                      'batch': studentData?['batch'] ?? 'active',
                      if (!isEdit) ...{
                        'currentLines': 0,
                        'enrolledMonth': DateFormat('yyyy-MM').format(now),
                        'createdAt': now.toIso8601String(),
                        'auditLog': [
                          {
                            'status': 'active',
                            'type': 'enrollment',
                            'date': joinDate.toIso8601String(),
                            'reason': 'Initial Enrollment',
                          }
                        ],
                      },
                    },
                    isNew: !isEdit,
                  );

                  // Central audit log - run in background so UI never blocks
                  unawaited(MadrassaAuditService.logAction(
                    branchId: branchId,
                    editor: username,
                    role: role,
                    type: isEdit ? 'student_edit' : 'student_enrollment',
                    message: isEdit
                        ? 'Updated details for student ${finalData['name']} (Roll: ${finalData['rollNumber']})'
                        : 'Enrolled new student ${finalData['name']} (Roll: ${finalData['rollNumber']})',
                    studentId: finalStudentId,
                    studentName: finalData['name'] as String?,
                  ));

                  if (enteredPin.isNotEmpty) {
                    unawaited(ZkTecoNetworkService.assignPinToEntity(
                      entityId: finalStudentId,
                      entityName: nameCtrl.text.trim(),
                      entityType: 'madrassa_student',
                      branchId: branchId,
                      customPin: enteredPin,
                    ));
                  }

                  if (gUid != null) {
                    if (Hive.isBoxOpen(LocalStorageService.usersBox)) {
                      final uBox = Hive.box(LocalStorageService.usersBox);
                      for (final key in uBox.keys) {
                        final val = uBox.get(key);
                        if (val is Map) {
                          final map = Map<String, dynamic>.from(val);
                          if ((map['uid'] ?? map['id']) == gUid) {
                            final studentIds = List<String>.from(map['studentIds'] ?? []);
                            if (!studentIds.contains(finalStudentId)) {
                              studentIds.add(finalStudentId);
                              map['studentIds'] = studentIds;
                              await uBox.put(key, map);
                              await uBox.flush();

                              try {
                                RealtimeManager().sendMessage(RealtimeEvents.payload(
                                  type: RealtimeEvents.saveUser,
                                  data: map,
                                  branchId: branchId,
                                ));
                              } catch (_) {}

                              await LocalStorageService.enqueueSync({
                                'type': 'save_user',
                                'uid': gUid,
                                'branchId': branchId,
                                'data': map,
                              });
                              unawaited(SyncService().triggerUpload());
                            }
                            break;
                          }
                        }
                      }
                    }
                  }

                  String successMessage = isEdit 
                      ? context.t('Student details updated successfully!')
                      : context.t('Student enrolled successfully!');
                  
                  if (isGuardianLinkedOrCreating) {
                    if (foundGuardian != null) {
                      successMessage += ' ' + context.t('Guardian account updated successfully.');
                    } else if (linkAccount) {
                      successMessage += ' ' + context.t('Guardian account created and linked successfully.');
                    }
                  }
                  
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(successMessage, style: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null)),
                        backgroundColor: Colors.green,
                      ),
                    );
                  });
                  nav.pop();
                } catch (e) {
                  setDs(() => isSaving = false);
                  final msg = e.toString();
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(msg, style: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null)),
                        backgroundColor: Colors.red,
                      ),
                    );
                  });
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4F46E5),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: isSaving
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text(
                      isEdit ? context.l.save : context.l.enrollAndLink,
                      style: context.urduStyle(style: const TextStyle(color: Colors.white)),
                    ),
            ),
          ],
        );
      },
    ),
  );
}