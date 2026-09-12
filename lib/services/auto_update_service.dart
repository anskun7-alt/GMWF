// lib/services/auto_update_service.dart

import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:open_filex/open_filex.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

class UpdateInfo {
  final String latestVersion;
  final String minRequiredVersion;
  final String downloadUrl;
  final String releaseNotes;
  final bool forceUpdate;
  final bool hasUpdate;

  UpdateInfo({
    required this.latestVersion,
    required this.minRequiredVersion,
    required this.downloadUrl,
    required this.releaseNotes,
    required this.forceUpdate,
    required this.hasUpdate,
  });
}

class AutoUpdateService {
  /// Default fallback version of the GMWF application if PackageInfo is unavailable.
  static const String currentVersion = '1.5.0';
  static const int protocolVersion = 2;
  static const String minSupportedVersion = '1.4.8';

  /// Default GitHub repository configuration for auto-updates.
  static const String defaultRepoOwner = 'gmwf-1122';
  static const String defaultRepoName = 'GMWF';

  static String _cachedVersion = '';

  /// Dynamically retrieves current installed application version from package_info_plus.
  static Future<String> getAppVersion() async {
    if (_cachedVersion.isNotEmpty) return _cachedVersion;
    try {
      final info = await PackageInfo.fromPlatform();
      if (info.version.isNotEmpty) {
        _cachedVersion = info.version;
        return _cachedVersion;
      }
    } catch (e) {
      debugPrint('[AutoUpdateService] Error fetching PackageInfo: $e');
    }
    return currentVersion;
  }

  /// Compares two semver strings (e.g. "1.2.4" vs "1.2.5").
  /// Returns 1 if v2 > v1 (update available), -1 if v1 > v2, 0 if equal.
  static int compareVersions(String v1, String v2) {
    try {
      final cleanV1 = v1.split('+').first.split('-').first.replaceAll(RegExp(r'^[vV]'), '').trim();
      final cleanV2 = v2.split('+').first.split('-').first.replaceAll(RegExp(r'^[vV]'), '').trim();

      final parts1 = cleanV1.split('.').where((s) => s.isNotEmpty).map((s) => int.tryParse(s) ?? 0).toList();
      final parts2 = cleanV2.split('.').where((s) => s.isNotEmpty).map((s) => int.tryParse(s) ?? 0).toList();

      final maxLength = parts1.length > parts2.length ? parts1.length : parts2.length;
      for (int i = 0; i < maxLength; i++) {
        final val1 = i < parts1.length ? parts1[i] : 0;
        final val2 = i < parts2.length ? parts2[i] : 0;
        if (val2 > val1) return 1;
        if (val1 > val2) return -1;
      }
    } catch (e) {
      debugPrint('[AutoUpdateService] Version comparison error: $e');
    }
    return 0;
  }

  /// Primary update check method: checks GitHub Releases first, then Firestore fallback, then raw GitHub repository fallback.
  static Future<UpdateInfo?> checkForUpdates({
    String? repoOwner,
    String? repoName,
    String? personalAccessToken,
  }) async {
    // Web users run in the browser and do not use binary desktop/mobile installers.
    if (kIsWeb) {
      return null;
    }

    final owner = repoOwner ?? defaultRepoOwner;
    final name = repoName ?? defaultRepoName;

    try {
      // 1. Try checking GitHub Releases (gmwf-1122/GMWF)
      final ghInfo = await checkGitHubReleases(
        repoOwner: owner,
        repoName: name,
        personalAccessToken: personalAccessToken,
      );

      if (ghInfo != null && ghInfo.hasUpdate) {
        return ghInfo;
      }

      // 2. Fallback to Firestore app_config/version
      final fsInfo = await checkFirestoreVersion();
      if (fsInfo != null && fsInfo.hasUpdate) {
        return fsInfo;
      }

      // 3. Fallback to Raw GitHub pubspec repository check (immune to GitHub API 60 req/hr rate limits)
      final rawInfo = await checkRawGitHubFallback(
        repoOwner: owner,
        repoName: name,
      );
      if (rawInfo != null && rawInfo.hasUpdate) {
        return rawInfo;
      }

      // If checks succeeded but no update was available, return the latest release info (hasUpdate == false)
      return ghInfo ?? fsInfo ?? rawInfo;
    } catch (e) {
      debugPrint('[AutoUpdateService] General checkForUpdates error: $e');
      return null;
    }
  }

  /// Tier 3 fallback: Checks raw GitHub repository files when GitHub API is rate limited (HTTP 403) and Firestore is offline.
  static Future<UpdateInfo?> checkRawGitHubFallback({
    required String repoOwner,
    required String repoName,
  }) async {
    try {
      final url = Uri.parse('https://raw.githubusercontent.com/$repoOwner/$repoName/main/pubspec.yaml');
      final response = await http.get(url).timeout(const Duration(seconds: 6));
      if (response.statusCode == 200) {
        final content = response.body;
        final match = RegExp(r'version:\s*([\d.]+)(?:\+(\d+))?').firstMatch(content);
        if (match != null) {
          final rawVer = match.group(1)?.trim() ?? '';
          if (rawVer.isNotEmpty) {
            final installedVer = await getAppVersion();
            if (compareVersions(installedVer, rawVer) > 0) {
              final cleanTag = rawVer.startsWith('v') ? rawVer : 'v$rawVer';
              String downloadUrl = '';
              if (defaultTargetPlatform == TargetPlatform.windows) {
                downloadUrl = 'https://github.com/$repoOwner/$repoName/releases/download/$cleanTag/GMWF-$cleanTag-x64.exe';
              } else if (defaultTargetPlatform == TargetPlatform.android) {
                downloadUrl = 'https://github.com/$repoOwner/$repoName/releases/download/$cleanTag/app-arm64-v8a-release.apk';
              } else if (defaultTargetPlatform == TargetPlatform.macOS) {
                downloadUrl = 'https://github.com/$repoOwner/$repoName/releases/download/$cleanTag/GMWF-$cleanTag.dmg';
              }

              return UpdateInfo(
                latestVersion: rawVer,
                minRequiredVersion: installedVer,
                downloadUrl: downloadUrl,
                releaseNotes: 'Performance improvements, stability updates, and feature enhancements.',
                forceUpdate: false,
                hasUpdate: downloadUrl.isNotEmpty,
              );
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[AutoUpdateService] Raw GitHub fallback check error: $e');
    }
    return null;
  }

  /// Checks Firestore `app_config/version` for available updates with platform-specific fallback.
  static Future<UpdateInfo?> checkFirestoreVersion() async {
    try {
      final doc = await FirebaseFirestore.instance.collection('app_config').doc('version').get();
      if (!doc.exists) {
        debugPrint('[AutoUpdateService] app_config/version document does not exist yet');
        return null;
      }

      final installedVer = await getAppVersion();
      final data = doc.data()!;
      final latestVersion = (data['latestVersion'] ?? installedVer).toString();
      final minRequiredVersion = (data['minRequiredVersion'] ?? installedVer).toString();
      final releaseNotes = (data['releaseNotes'] ?? 'Bug fixes and performance improvements.').toString();
      final forceUpdateFlag = data['forceUpdate'] as bool? ?? false;

      // Check platform-specific download URLs first, fallback to generic downloadUrl
      String rawUrl = '';
      if (defaultTargetPlatform == TargetPlatform.windows) {
        rawUrl = (data['windowsDownloadUrl'] ?? data['downloadUrl'] ?? '').toString();
      } else if (defaultTargetPlatform == TargetPlatform.android) {
        rawUrl = (data['androidDownloadUrl'] ?? data['downloadUrl'] ?? '').toString();
      } else if (defaultTargetPlatform == TargetPlatform.macOS) {
        rawUrl = (data['macOSDownloadUrl'] ?? data['downloadUrl'] ?? '').toString();
      } else {
        rawUrl = (data['downloadUrl'] ?? '').toString();
      }

      // Sanitize URL if Firestore has cross-platform extension mismatch
      String downloadUrl = rawUrl;
      final cleanTag = latestVersion.startsWith('v') ? latestVersion : 'v$latestVersion';
      if (defaultTargetPlatform == TargetPlatform.windows && downloadUrl.toLowerCase().endsWith('.apk')) {
        downloadUrl = 'https://github.com/$defaultRepoOwner/$defaultRepoName/releases/download/$cleanTag/GMWF-$cleanTag-x64.exe';
      } else if (defaultTargetPlatform == TargetPlatform.android && downloadUrl.toLowerCase().endsWith('.exe')) {
        downloadUrl = 'https://github.com/$defaultRepoOwner/$defaultRepoName/releases/download/$cleanTag/GMWF-$cleanTag.apk';
      }

      final isHigher = compareVersions(installedVer, latestVersion) > 0;
      final isMinRequiredHigher = compareVersions(installedVer, minRequiredVersion) > 0;
      final forceUpdate = forceUpdateFlag || isMinRequiredHigher;

      return UpdateInfo(
        latestVersion: latestVersion,
        minRequiredVersion: minRequiredVersion,
        downloadUrl: downloadUrl,
        releaseNotes: releaseNotes,
        forceUpdate: forceUpdate,
        hasUpdate: isHigher && downloadUrl.isNotEmpty,
      );
    } catch (e) {
      debugPrint('[AutoUpdateService] Failed to check Firestore version: $e');
    }
    return null;
  }

  /// Checks GitHub Releases API for updates (supports public or private repo with token).
  static Future<UpdateInfo?> checkGitHubReleases({
    required String repoOwner,
    required String repoName,
    String? personalAccessToken,
  }) async {
    try {
      final installedVer = await getAppVersion();
      final url = Uri.parse('https://api.github.com/repos/$repoOwner/$repoName/releases/latest');
      final headers = <String, String>{
        'Accept': 'application/vnd.github.v3+json',
        'User-Agent': 'GMWF-App/1.0',
        if (personalAccessToken != null && personalAccessToken.isNotEmpty)
          'Authorization': 'Bearer $personalAccessToken',
      };

      final response = await http.get(url, headers: headers).timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final rawTag = (data['tag_name'] ?? '').toString();
        final tag = rawTag.replaceAll('v', '');
        final notes = (data['body'] ?? 'Performance improvements and security updates.').toString();

        String downloadUrl = '';
        final assets = data['assets'] as List?;
        if (assets != null && assets.isNotEmpty) {
          if (defaultTargetPlatform == TargetPlatform.android) {
            final apkAssets = assets.where(
              (a) => (a['name'] ?? '').toString().toLowerCase().endsWith('.apk'),
            ).toList();

            if (apkAssets.isNotEmpty) {
              // Architecture-aware APK matching for split-per-abi builds
              List<String> supportedAbis = [];
              try {
                final androidInfo = await DeviceInfoPlugin().androidInfo;
                supportedAbis = androidInfo.supportedAbis;
              } catch (_) {}

              // 1. First look for universal APK (GMWF-*.apk or app-release.apk without split ABI tags)
              Map<String, dynamic>? selectedApk = apkAssets.firstWhere(
                (a) {
                  final name = (a['name'] ?? '').toString().toLowerCase();
                  return (!name.contains('arm') && !name.contains('x86') && !name.contains('v7a') && !name.contains('v8a')) ||
                      name.contains('universal') ||
                      name == 'app-release.apk' ||
                      name.startsWith('gmwf-');
                },
                orElse: () => null,
              );

              // 2. If no universal APK, match device supported ABIs
              if (selectedApk == null && supportedAbis.isNotEmpty) {
                for (final abi in supportedAbis) {
                  final abiClean = abi.toLowerCase();
                  final match = apkAssets.firstWhere(
                    (a) {
                      final name = (a['name'] ?? '').toString().toLowerCase();
                      return name.contains(abiClean) ||
                          (abiClean.contains('arm64') && (name.contains('arm64') || name.contains('arm64-v8a'))) ||
                          (abiClean.contains('v7a') && (name.contains('v7a') || name.contains('armv7') || name.contains('armeabi'))) ||
                          (abiClean.contains('x86_64') && name.contains('x86_64'));
                    },
                    orElse: () => null,
                  );
                  if (match != null) {
                    selectedApk = match;
                    break;
                  }
                }
              }

              // 3. Fallback to first available APK
              selectedApk ??= apkAssets.first;

              downloadUrl = (selectedApk?['browser_download_url'] ?? selectedApk?['url'] ?? '').toString();
            }
          } else if (defaultTargetPlatform == TargetPlatform.windows) {
            final exeAssets = assets.where(
              (a) => (a['name'] ?? '').toString().toLowerCase().endsWith('.exe') ||
                     (a['name'] ?? '').toString().toLowerCase().endsWith('.msi'),
            ).toList();

            if (exeAssets.isNotEmpty) {
              Map<String, dynamic>? selectedExe = exeAssets.firstWhere(
                (a) {
                  final name = (a['name'] ?? '').toString().toLowerCase();
                  return name.contains('x64') || name.contains('win64') || name.contains('64bit') || name.contains('setup');
                },
                orElse: () => exeAssets.first,
              );

              downloadUrl = (selectedExe?['browser_download_url'] ?? selectedExe?['url'] ?? '').toString();
            }
          } else if (defaultTargetPlatform == TargetPlatform.macOS) {
            final macAsset = assets.firstWhere(
              (a) => (a['name'] ?? '').toString().toLowerCase().endsWith('.dmg') ||
                     (a['name'] ?? '').toString().toLowerCase().endsWith('.pkg'),
              orElse: () => null,
            );
            if (macAsset != null) {
              downloadUrl = (macAsset['browser_download_url'] ?? macAsset['url'] ?? '').toString();
            }
          }
        }

        // Direct binary release URL fallback per platform if asset is missing or html URL was returned
        if (downloadUrl.isEmpty || downloadUrl.contains('/releases/tag/') || downloadUrl.endsWith('/releases/latest')) {
          final cleanTag = rawTag.isNotEmpty ? rawTag : 'v$tag';
          if (defaultTargetPlatform == TargetPlatform.android) {
            downloadUrl = 'https://github.com/$repoOwner/$repoName/releases/download/$cleanTag/GMWF-$cleanTag.apk';
          } else if (defaultTargetPlatform == TargetPlatform.windows) {
            downloadUrl = 'https://github.com/$repoOwner/$repoName/releases/download/$cleanTag/GMWF-$cleanTag-x64.exe';
          } else {
            downloadUrl = 'https://github.com/$repoOwner/$repoName/releases/download/$cleanTag/GMWF-$cleanTag.dmg';
          }
        }

        final isHigher = compareVersions(installedVer, tag) > 0;
        final hasUpdate = isHigher;

        return UpdateInfo(
          latestVersion: tag,
          minRequiredVersion: installedVer,
          downloadUrl: downloadUrl,
          releaseNotes: notes,
          forceUpdate: false,
          hasUpdate: hasUpdate,
        );
      }
    } catch (e) {
      debugPrint('[AutoUpdateService] Failed to fetch GitHub Release: $e');
    }
    return null;
  }

  /// Opens the installer or update download URL in external application if needed.
  static Future<bool> launchUpdateUrl(String url) async {
    final targetUrl = url.isNotEmpty ? url : 'https://github.com/gmwf-1122/GMWF/releases/latest';
    try {
      final uri = Uri.parse(targetUrl);
      if (await canLaunchUrl(uri)) {
        return await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('[AutoUpdateService] Failed to launch update URL: $e');
    }
    return false;
  }

  /// Downloads binary asset directly using HttpClient (handles HTTP 302/301 redirects and streams to file).
  static Future<File?> _downloadFileWithHttpClient(
    String url,
    String targetFilePath, {
    required Function(double progress, String statusMessage) onProgress,
  }) async {
    try {
      final httpClient = HttpClient();
      httpClient.connectionTimeout = const Duration(seconds: 20);
      httpClient.userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

      String currentUrl = url;
      HttpClientResponse? response;
      int redirects = 0;

      while (redirects < 8) {
        final uri = Uri.parse(currentUrl);
        final request = await httpClient.getUrl(uri);
        request.headers.set('User-Agent', 'GMWF-App/1.0 (Windows; Android)');
        request.headers.set('Accept', '*/*');
        request.followRedirects = true;

        response = await request.close();

        if (response.statusCode >= 300 && response.statusCode < 400) {
          final location = response.headers.value('location');
          if (location != null && location.isNotEmpty) {
            currentUrl = Uri.parse(currentUrl).resolve(location).toString();
            redirects++;
            debugPrint('[AutoUpdateService] Following redirect ($redirects) to: $currentUrl');
            continue;
          }
        }
        break;
      }

      if (response == null) {
        onProgress(0.0, 'Download Failed: Server did not respond. Check network connection.');
        httpClient.close();
        return null;
      }

      if (response.statusCode != 200) {
        String msg;
        if (response.statusCode == 404) {
          msg = 'Download Failed (HTTP 404): Update binary file not found on GitHub release server.';
        } else if (response.statusCode == 403) {
          msg = 'Download Failed (HTTP 403): GitHub API access forbidden or rate limit reached.';
        } else if (response.statusCode >= 500) {
          msg = 'Download Failed (HTTP ${response.statusCode}): Release server is temporarily unavailable.';
        } else {
          msg = 'Download Failed: Server returned status HTTP ${response.statusCode}.';
        }
        onProgress(0.0, msg);
        httpClient.close();
        return null;
      }

      final contentLength = response.contentLength;
      int receivedBytes = 0;
      final file = File(targetFilePath);
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {}
      }
      final sink = file.openWrite();

      await response.forEach((chunk) {
        receivedBytes += chunk.length;
        sink.add(chunk);

        if (contentLength > 0) {
          final progress = (receivedBytes / contentLength).clamp(0.0, 1.0);
          final percent = (progress * 100).toInt();
          final mbReceived = (receivedBytes / (1024 * 1024)).toStringAsFixed(1);
          final mbTotal = (contentLength / (1024 * 1024)).toStringAsFixed(1);
          onProgress(progress, 'Downloading update... $percent% ($mbReceived MB / $mbTotal MB)');
        } else {
          final mbReceived = (receivedBytes / (1024 * 1024)).toStringAsFixed(1);
          onProgress(0.5, 'Downloading update... $mbReceived MB');
        }
      });

      await sink.flush();
      await sink.close();
      httpClient.close();

      // Integrity Check: Reject empty or tiny HTML error responses
      final fileSize = await file.length();
      if (fileSize < 1024 * 500) {
        onProgress(0.0, 'Download Failed: File size is invalid ($fileSize bytes). Please try again or download via browser.');
        try {
          await file.delete();
        } catch (_) {}
        return null;
      }

      return file;
    } on SocketException catch (e) {
      onProgress(0.0, 'Network Connection Error: Unable to reach update server (${e.message}). Please check internet or firewall.');
    } on HandshakeException catch (e) {
      onProgress(0.0, 'SSL Security Error: Handshake failed (${e.message}). Check device date & time settings.');
    } on TimeoutException {
      onProgress(0.0, 'Connection Timeout: Update server took too long to respond. Network connection is unstable.');
    } on FileSystemException catch (e) {
      onProgress(0.0, 'Storage Error: Could not write update file (${e.message}). Ensure sufficient free disk space.');
    } catch (e) {
      onProgress(0.0, 'Download Failed: Unexpected error ($e)');
    }
    return null;
  }

  /// Direct in-app stream download with progress callback and silent installer launch.
  static Future<bool> downloadAndInstallUpdate(
    String downloadUrl, {
    required Function(double progress, String statusMessage) onProgress,
  }) async {
    if (kIsWeb) {
      onProgress(1.0, 'Updates are not applicable for web version.');
      return false;
    }

    String effectiveUrl = downloadUrl;

    // Resolve URL if it's pointing to HTML release tag or empty
    if (effectiveUrl.isEmpty || effectiveUrl.endsWith('/releases/latest') || effectiveUrl.contains('/releases/tag/')) {
      final info = await checkForUpdates();
      if (info != null && info.downloadUrl.isNotEmpty && !info.downloadUrl.contains('/releases/tag/')) {
        effectiveUrl = info.downloadUrl;
      }
    }

    onProgress(0.01, 'Connecting to update server...');

    String fileName = 'GMWF_Setup_Update.exe';
    if (defaultTargetPlatform == TargetPlatform.android) {
      fileName = 'GMWF_Update.apk';
    } else if (defaultTargetPlatform == TargetPlatform.macOS) {
      fileName = 'GMWF_Update.dmg';
    }

    final tempDir = await getTemporaryDirectory();
    String filePath = path.join(tempDir.path, fileName);

    // Safeguard: If previous installer is still locked by OS or antivirus, use timestamped file
    try {
      final existing = File(filePath);
      if (await existing.exists()) {
        await existing.delete();
      }
    } catch (_) {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final ext = path.extension(fileName);
      final base = path.basenameWithoutExtension(fileName);
      filePath = path.join(tempDir.path, '${base}_$ts$ext');
    }

    final downloadedFile = await _downloadFileWithHttpClient(
      effectiveUrl,
      filePath,
      onProgress: onProgress,
    );

    if (downloadedFile == null || !await downloadedFile.exists()) {
      return false;
    }

    onProgress(1.0, 'Installing update... Please wait.');
    await Future.delayed(const Duration(milliseconds: 800));

    try {
      if (defaultTargetPlatform == TargetPlatform.windows) {
        debugPrint('[AutoUpdateService] Launching Windows installer: $filePath');
        bool processStarted = false;
        String winErr = '';
        try {
          // Launch detached so setup window appears and requests UAC elevation without locking the app
          await Process.start(
            filePath,
            ['/sp-'],
            mode: ProcessStartMode.detached,
          );
          processStarted = true;
        } catch (e) {
          winErr = e.toString();
          debugPrint('[AutoUpdateService] Process.start failed ($e), attempting OpenFilex launch...');
          final result = await OpenFilex.open(filePath);
          processStarted = result.type == ResultType.done;
          if (!processStarted) winErr = result.message;
        }

        if (processStarted) {
          onProgress(1.0, 'Installer launched! Please complete the setup window to finish updating.');
          return true;
        } else {
          onProgress(0.0, 'Windows Installation Failed: $winErr. Please run the setup manually.');
          return false;
        }
      } else if (defaultTargetPlatform == TargetPlatform.android) {
        debugPrint('[AutoUpdateService] Launching Android Package Installer for: $filePath');
        onProgress(1.0, 'Launching Package Installer...');

        final result = await OpenFilex.open(filePath, type: "application/vnd.android.package-archive");
        debugPrint('[AutoUpdateService] OpenFilex result: ${result.type} - ${result.message}');

        if (result.type == ResultType.done) {
          onProgress(1.0, 'Package installer opened. Complete installation on your screen.');
          return true;
        } else if (result.type == ResultType.permissionDenied) {
          onProgress(0.0, 'Permission Denied: Android blocked installation. Please enable "Install Unknown Apps" for GMWF in Android Settings.');
          try {
            final uri = Uri.parse(effectiveUrl);
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          } catch (_) {}
          return false;
        } else if (result.type == ResultType.fileNotFound) {
          onProgress(0.0, 'File Error: Downloaded APK file was not found at $filePath.');
          return false;
        } else {
          onProgress(0.0, 'Installation prompt could not open automatically: ${result.message}. Opening direct download...');
          try {
            final uri = Uri.parse(effectiveUrl);
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          } catch (_) {}
          return false;
        }
      } else {
        final result = await OpenFilex.open(filePath);
        if (result.type != ResultType.done) {
          onProgress(0.0, 'Installation Failed: ${result.message}');
          return false;
        }
        return true;
      }
    } catch (e) {
      debugPrint('[AutoUpdateService] Installation trigger error: $e');
      onProgress(0.0, 'Installation System Error: $e');
      return false;
    }
  }

  /// Downloads and executes silent installer for headless server instances.
  static Future<bool> performSilentHeadlessUpdate(String downloadUrl) async {
    if (kIsWeb) return false;
    try {
      debugPrint('[AutoUpdateService] Starting silent headless update from: $downloadUrl');
      final tempDir = await getTemporaryDirectory();
      final filePath = path.join(tempDir.path, 'gmwf_update_installer.exe');

      String effectiveUrl = downloadUrl;
      if (effectiveUrl.isEmpty || effectiveUrl.contains('/releases/tag/') || effectiveUrl.endsWith('/releases/latest')) {
        final info = await checkForUpdates();
        if (info != null && info.downloadUrl.isNotEmpty) {
          effectiveUrl = info.downloadUrl;
        }
      }

      final downloadedFile = await _downloadFileWithHttpClient(
        effectiveUrl,
        filePath,
        onProgress: (progress, statusMessage) {
          debugPrint('[SilentHeadlessUpdate] $statusMessage');
        },
      );

      if (downloadedFile != null && await downloadedFile.exists()) {
        debugPrint('[AutoUpdateService] Silent installer downloaded to: $filePath');
        if (defaultTargetPlatform == TargetPlatform.windows) {
          debugPrint('[AutoUpdateService] Executing Inno Setup silent install flags...');
          await Process.start(filePath, ['/verysilent', '/suppressmsgboxes', '/norestart', '/sp-']);
          return true;
        }
      }
    } catch (e) {
      debugPrint('[AutoUpdateService] Silent headless update failed: $e');
    }
    return false;
  }
}

