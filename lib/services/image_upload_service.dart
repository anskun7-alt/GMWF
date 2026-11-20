import 'dart:convert';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:gmwf/design/tokens/comfort_colors.dart';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;

/// Centralized Image & Document Upload Service.
///
/// Converts captured/picked images into compressed Base64 data strings
/// (`data:image/jpeg;base64,...`) for fast offline storage & instant sync
/// without requiring external storage buckets.
class ImageUploadService {
  static final ImagePicker _picker = ImagePicker();

  /// Prompts user to choose between Capture (Camera) and Browse (Gallery / File).
  static Future<ImageSource?> showSourceDialog(BuildContext context, {String title = 'Select Image Source'}) async {
    return showModalBottomSheet<ImageSource>(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
            ListTile(
              leading: Icon(Icons.camera_alt_outlined, color: ctx.adapt(SoftPalette.teal550)),
              title: const Text('Capture (Camera)'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: Icon(Icons.photo_library_outlined, color: ctx.adapt(SoftPalette.teal550)),
              title: const Text('Browse (Gallery / File)'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Picks an image from Camera or Gallery, compresses it, and returns a Base64 string.
  /// Includes graceful fallback to Gallery / FilePicker if Camera plugin is unavailable on desktop platforms.
  static Future<String?> pickAndProcessImage({
    ImageSource source = ImageSource.gallery,
    int maxWidth = 600,
    int maxHeight = 600,
    int quality = 65,
  }) async {
    try {
      bool isDesktop = false;
      try {
        if (!kIsWeb) {
          isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
        }
      } catch (_) {}

      XFile? file;
      if (isDesktop && source == ImageSource.camera) {
        debugPrint('[ImageUploadService] Camera hardware capture is unsupported natively on desktop. Directing to FilePicker.');
        return await pickDocumentFile(allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp']);
      }

      try {
        file = await _picker.pickImage(
          source: source,
          maxWidth: maxWidth.toDouble(),
          maxHeight: maxHeight.toDouble(),
          imageQuality: quality,
        ).timeout(const Duration(seconds: 12));
      } catch (e) {
        debugPrint('[ImageUploadService] Primary pick image failed for source $source: $e. Falling back to FilePicker...');
        try {
          if (source == ImageSource.camera) {
            file = await _picker.pickImage(
              source: ImageSource.gallery,
              maxWidth: maxWidth.toDouble(),
              maxHeight: maxHeight.toDouble(),
              imageQuality: quality,
            ).timeout(const Duration(seconds: 10));
          }
        } catch (_) {}
      }

      if (file != null) {
        final bytes = await file.readAsBytes();
        return processBytesToBase64(bytes, quality: quality, maxWidth: maxWidth, maxHeight: maxHeight);
      }

      // Secondary fallback via FilePicker for Desktop/Web if ImagePicker returned null/failed
      return await pickDocumentFile(allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp']);
    } catch (e) {
      debugPrint('[ImageUploadService] Pick image error: $e');
      return null;
    }
  }

  /// Maximum allowed byte size for non-image documents (e.g. PDF) stored directly in Firestore
  static const int maxDocumentByteSize = 350 * 1024; // 350 KB

  /// Picks any file using FilePicker, compresses image if applicable, and returns Base64 data URI.
  static Future<String?> pickDocumentFile({
    List<String>? allowedExtensions,
  }) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: allowedExtensions != null ? FileType.custom : FileType.any,
        allowedExtensions: allowedExtensions,
        withData: true,
      );

      if (result == null || result.files.isEmpty) return null;
      final file = result.files.first;

      Uint8List? bytes = file.bytes;
      if (bytes == null && file.path != null) {
        bytes = await File(file.path!).readAsBytes();
      }

      if (bytes == null) return null;

      final ext = file.extension?.toLowerCase() ?? 'jpg';
      if (['jpg', 'jpeg', 'png', 'webp', 'bmp'].contains(ext)) {
        return processBytesToBase64(bytes, quality: 60, maxWidth: 700, maxHeight: 700);
      } else {
        // Enforce document byte size ceiling so it never exceeds Firestore document limits
        if (bytes.lengthInBytes > maxDocumentByteSize) {
          debugPrint('[ImageUploadService] ⚠️ Document file (${bytes.lengthInBytes} bytes) exceeds $maxDocumentByteSize limit.');
          return null;
        }
        // PDF or non-image document -> Base64 data URI
        final b64 = base64Encode(bytes);
        return 'data:application/$ext;base64,$b64';
      }
    } catch (e) {
      debugPrint('[ImageUploadService] Pick document file error: $e');
      return null;
    }
  }

  /// Processes raw image bytes: resizes, compresses JPEG quality, and returns a Base64 data URI string.
  static String? processBytesToBase64(
    Uint8List rawBytes, {
    int quality = 65,
    int maxWidth = 600,
    int maxHeight = 600,
  }) {
    try {
      final decoded = img.decodeImage(rawBytes);
      if (decoded == null) {
        // Fallback: encode raw bytes directly if image package fails to parse
        return 'data:image/jpeg;base64,${base64Encode(rawBytes)}';
      }

      // Resize if dimensions exceed maxWidth/maxHeight while preserving aspect ratio
      img.Image resized = decoded;
      if (decoded.width > maxWidth || decoded.height > maxHeight) {
        resized = img.copyResize(
          decoded,
          width: decoded.width > decoded.height ? maxWidth : null,
          height: decoded.height >= decoded.width ? maxHeight : null,
        );
      }

      // Encode to compressed JPEG
      final compressed = img.encodeJpg(resized, quality: quality);
      final b64 = base64Encode(compressed);
      return 'data:image/jpeg;base64,$b64';
    } catch (e) {
      debugPrint('[ImageUploadService] Image compression error: $e');
      return 'data:image/jpeg;base64,${base64Encode(rawBytes)}';
    }
  }

  static final Map<int, Uint8List> _b64Cache = {};

  /// Fast path keyed by the raw input string. Strings read from Hive are the
  /// same objects on every build, and Dart caches a string's hash, so a hit
  /// costs O(1) instead of trimming / splitting / regex-cleaning tens of KB of
  /// text per image per rebuild (that cleaning was a visible lag on lists of
  /// photos and book covers).
  static final Map<String, Uint8List> _rawCache = {};
  static const int _cacheLimit = 300;

  /// Decodes Base64 data URI or raw Base64 string to Uint8List bytes.
  /// Caches decoded bytes by content hash so Flutter's MemoryImage sees identical
  /// object references and avoids disposing/re-decoding textures on every build pass.
  static Uint8List? decodeBase64ToBytes(String? input) {
    if (input == null || input.isEmpty) return null;
    final hit = _rawCache[input];
    if (hit != null) return hit;
    final bytes = _decodeUncached(input);
    if (bytes != null) {
      if (_rawCache.length >= _cacheLimit) _rawCache.remove(_rawCache.keys.first);
      _rawCache[input] = bytes;
    }
    return bytes;
  }

  static Uint8List? _decodeUncached(String input) {
    try {
      String clean = input.trim();
      if (clean.contains(',')) {
        clean = clean.split(',').last;
      }
      clean = clean.replaceAll(RegExp(r'\s+'), '');
      if (clean.isEmpty) return null;

      final hash = clean.hashCode;
      final cached = _b64Cache[hash];
      if (cached != null) return cached;

      final decoded = base64Decode(base64.normalize(clean));
      if (_b64Cache.length > _cacheLimit) {
        _b64Cache.remove(_b64Cache.keys.first);
      }
      _b64Cache[hash] = decoded;
      return decoded;
    } catch (e) {
      debugPrint('[ImageUploadService] Base64 decode error: $e');
      return null;
    }
  }

  /// Returns true if the string is a valid Base64 image/document string or HTTP URL.
  static bool isValidMediaString(String? str) {
    if (str == null || str.trim().isEmpty) return false;
    final s = str.trim();
    return s.startsWith('http://') ||
        s.startsWith('https://') ||
        s.startsWith('data:image') ||
        s.startsWith('data:application') ||
        s.length > 100;
  }
}
