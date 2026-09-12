import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;

enum TerminalLineType {
  stdout,
  stderr,
  system,
  prompt,
  success,
  error,
  warning,
  punch,
}

class PythonTerminalLine {
  final DateTime timestamp;
  final String text;
  final TerminalLineType type;

  PythonTerminalLine({
    required this.timestamp,
    required this.text,
    required this.type,
  });

  String get formattedTime {
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    final s = timestamp.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}

class PythonRunnerService extends ChangeNotifier {
  static final PythonRunnerService instance = PythonRunnerService._internal();
  PythonRunnerService._internal() {
    _initEnvironment();
  }

  Process? _process;
  String? _currentScript;
  String? _customPythonPath;
  DateTime? _startTime;
  Timer? _uptimeTimer;
  Timer? _watchdogTimer;
  Duration _uptime = Duration.zero;
  bool _isExplicitlyStopped = false;
  int _consecutiveCrashes = 0;

  final List<PythonTerminalLine> _lines = [];
  final StreamController<PythonTerminalLine> _lineStreamController =
      StreamController<PythonTerminalLine>.broadcast();

  // Getters
  bool get isRunning => _process != null;
  int? get runningPid => _process?.pid;
  String? get currentScript => _currentScript;
  DateTime? get startTime => _startTime;
  Duration get uptime => _uptime;
  List<PythonTerminalLine> get lines => List.unmodifiable(_lines);
  Stream<PythonTerminalLine> get lineStream => _lineStreamController.stream;
  String? get customPythonPath => _customPythonPath;

  bool get isAutoStartEnabled {
    if (Hive.isBoxOpen('app_settings')) {
      return Hive.box('app_settings').get('auto_start_python_sync', defaultValue: true) as bool;
    }
    return true;
  }

  Future<void> setAutoStartEnabled(bool enabled) async {
    if (Hive.isBoxOpen('app_settings')) {
      await Hive.box('app_settings').put('auto_start_python_sync', enabled);
    }
    notifyListeners();
    if (enabled && !isRunning) {
      _isExplicitlyStopped = false;
      await initAutoStart();
    }
  }

  /// Automatically initialize and start the background sync daemon on app or server launch
  Future<bool> initAutoStart() async {
    if (kIsWeb) return false;
    if (isRunning) return true;
    if (!isAutoStartEnabled) {
      debugPrint('[PythonRunner] Auto-start is disabled in settings.');
      return false;
    }

    _isExplicitlyStopped = false;
    debugPrint('[PythonRunner] Auto-starting ZKTeco background daemon...');
    _appendLine('🤖 [Auto-Start] Initiating background biometric sync daemon...', TerminalLineType.system);

    return await startScript('zkteco_sync_service.py', args: ['--config', 'config.json']);
  }

  // Resolved paths cache
  String? _resolvedPythonPath;
  String? _resolvedScriptsDir;
  String _pythonVersion = 'Checking...';

  String get pythonVersion => _pythonVersion;
  String? get resolvedPythonPath => _resolvedPythonPath;
  String? get resolvedScriptsDir => _resolvedScriptsDir;

  void setCustomPythonPath(String? path) {
    _customPythonPath = path;
    _resolvedPythonPath = null;
    notifyListeners();
    checkEnvironment();
  }

  Future<void> _initEnvironment() async {
    await checkEnvironment();
  }

  /// Automatically discover the valid Python executable on the system.
  Future<String?> resolvePythonExecutable() async {
    if (_customPythonPath != null && _customPythonPath!.isNotEmpty) {
      if (await File(_customPythonPath!).exists()) {
        _resolvedPythonPath = _customPythonPath;
        return _resolvedPythonPath;
      }
    }

    if (_resolvedPythonPath != null && await File(_resolvedPythonPath!).exists()) {
      return _resolvedPythonPath;
    }

    // List of candidate paths to check on Windows and Unix
    final List<String> candidatePaths = [];

    if (Platform.isWindows) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      // 1. Top priority: bundled portable Python with the application / GMWF installation
      candidatePaths.add(r'C:\Program Files\GMWF\python\python.exe');
      candidatePaths.add(r'C:\Program Files (x86)\GMWF\python\python.exe');
      candidatePaths.add(r'E:\Program Files\GMWF\python\python.exe');
      candidatePaths.add(p.join(exeDir, 'python', 'python.exe'));
      candidatePaths.add(p.join(exeDir, '..', 'python', 'python.exe'));
      candidatePaths.add(p.join(Directory.current.path, 'Installer', 'python-3.12.10-embed-amd64', 'python.exe'));
      candidatePaths.add(p.join(Directory.current.path, 'Installer', 'python-3.12.10-embed-win32', 'python.exe'));
      candidatePaths.add(p.join(Directory.current.path, 'python', 'python.exe'));
      candidatePaths.add(p.join(Directory.current.path, '..', 'python', 'python.exe'));

      final progFiles = Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
      final progFilesX86 = Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
      candidatePaths.add(p.join(progFiles, 'GMWF', 'python', 'python.exe'));
      candidatePaths.add(p.join(progFilesX86, 'GMWF', 'python', 'python.exe'));

      final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
      final appData = Platform.environment['APPDATA'] ?? '';
      final userProfile = Platform.environment['USERPROFILE'] ?? '';

      if (localAppData.isNotEmpty) {
        candidatePaths.add(p.join(localAppData, 'GMWF', 'python', 'python.exe'));
        candidatePaths.add(p.join(localAppData, 'Python', 'bin', 'python.exe'));
        candidatePaths.add(p.join(localAppData, 'Programs', 'Python', 'Python314', 'python.exe'));
        candidatePaths.add(p.join(localAppData, 'Programs', 'Python', 'Python313', 'python.exe'));
        candidatePaths.add(p.join(localAppData, 'Programs', 'Python', 'Python312', 'python.exe'));
        candidatePaths.add(p.join(localAppData, 'Programs', 'Python', 'Python311', 'python.exe'));
        candidatePaths.add(p.join(localAppData, 'Programs', 'Python', 'Python310', 'python.exe'));
        candidatePaths.add(p.join(localAppData, 'Programs', 'Python', 'Python39', 'python.exe'));
      }

      if (appData.isNotEmpty) {
        candidatePaths.add(p.join(appData, 'GMWF', 'python', 'python.exe'));
        candidatePaths.add(p.join(appData, 'Python', 'bin', 'python.exe'));
      }

      if (userProfile.isNotEmpty) {
        candidatePaths.add(p.join(userProfile, '.pyenv', 'pyenv-win', 'shims', 'python.exe'));
      }

      candidatePaths.add(r'C:\Python314\python.exe');
      candidatePaths.add(r'C:\Python313\python.exe');
      candidatePaths.add(r'C:\Python312\python.exe');
      candidatePaths.add(r'C:\Python311\python.exe');
      candidatePaths.add(r'C:\Python310\python.exe');
      candidatePaths.add(r'C:\Program Files\Python314\python.exe');
      candidatePaths.add(r'C:\Program Files\Python313\python.exe');
      candidatePaths.add(r'C:\Program Files\Python312\python.exe');
      candidatePaths.add(r'C:\Program Files\Python311\python.exe');
      candidatePaths.add(r'C:\Program Files\Python310\python.exe');
    }

    for (final candidate in candidatePaths) {
      try {
        if (await File(candidate).exists()) {
          _resolvedPythonPath = candidate;
          return candidate;
        }
      } catch (_) {}
    }

    // Try standard commands: python, py, python3
    final commandsToTry = ['python', 'py', 'python3'];
    for (final cmd in commandsToTry) {
      try {
        final result = await Process.run(cmd, ['--version']);
        if (result.exitCode == 0) {
          _resolvedPythonPath = cmd;
          return cmd;
        }
      } catch (_) {}
    }

    return null;
  }

  /// Automatically discover the scripts directory.
  Future<String> resolveScriptsDirectory() async {
    if (_resolvedScriptsDir != null && await Directory(_resolvedScriptsDir!).exists()) {
      return _resolvedScriptsDir!;
    }

    final searchRoots = <String>{
      Directory.current.path,
      File(Platform.resolvedExecutable).parent.path,
      p.dirname(File(Platform.resolvedExecutable).parent.path),
      p.dirname(p.dirname(File(Platform.resolvedExecutable).parent.path)),
      Platform.environment['USERPROFILE'] ?? '',
      Platform.environment['ProgramFiles'] ?? '',
      Platform.environment['ProgramFiles(x86)'] ?? '',
      'E:/GMWF',
      'E:/GMWF/gmwf',
      'E:/Program Files',
      'C:/Program Files',
      'C:/Program Files (x86)',
    }..removeWhere((s) => s.trim().isEmpty);

    for (final root in searchRoots) {
      String? found = await _findScriptsDirUnder(root);
      if (found != null) {
        _resolvedScriptsDir = found;
        return found;
      }
    }

    final fallback = p.join(Directory.current.path, 'scripts');
    _resolvedScriptsDir = fallback;
    return fallback;
  }

  Future<String?> _findScriptsDirUnder(String startPath) async {
    final roots = <String>{
      startPath,
      p.join(startPath, 'scripts'),
    };

    for (final root in roots) {
      final candidate = Directory(root);
      if (!await candidate.exists()) continue;

      final directScript = p.join(root, 'zkteco_sync_service.py');
      if (await File(directScript).exists()) {
        return root;
      }

      final scriptsDir = p.join(root, 'scripts');
      if (await Directory(scriptsDir).exists()) {
        final scriptInScripts = p.join(scriptsDir, 'zkteco_sync_service.py');
        if (await File(scriptInScripts).exists()) {
          return scriptsDir;
        }
      }
    }

    var current = startPath;
    while (true) {
      final scriptsCandidate = p.join(current, 'scripts');
      final scriptPath = p.join(scriptsCandidate, 'zkteco_sync_service.py');
      if (await File(scriptPath).exists()) {
        return scriptsCandidate;
      }

      final parent = p.dirname(current);
      if (parent == current) break;
      current = parent;
    }

    return null;
  }

  /// Checks the Python environment status and reports details.
  Future<Map<String, dynamic>> checkEnvironment() async {
    final pyPath = await resolvePythonExecutable();
    final scriptsDir = await resolveScriptsDirectory();

    if (pyPath == null) {
      _pythonVersion = 'Not Detected';
      notifyListeners();
      return {
        'installed': false,
        'version': 'Not Detected',
        'pythonPath': null,
        'scriptsDir': scriptsDir,
        'hasPyzk': false,
        'hasFirebaseAdmin': false,
      };
    }

    String ver = 'Unknown';
    bool hasPyzk = false;
    bool hasFirebaseAdmin = false;

    try {
      final res = await Process.run(pyPath, ['--version']);
      ver = (res.stdout.toString().trim().isNotEmpty
              ? res.stdout.toString()
              : res.stderr.toString())
          .trim();
      _pythonVersion = ver;
    } catch (e) {
      ver = 'Error: $e';
      _pythonVersion = ver;
    }

    try {
      final pyzkCheck = await Process.run(pyPath, ['-c', 'import zk; print("OK")']);
      hasPyzk = pyzkCheck.stdout.toString().trim() == 'OK';
    } catch (_) {}

    try {
      final fbCheck = await Process.run(pyPath, ['-c', 'import firebase_admin; print("OK")']);
      hasFirebaseAdmin = fbCheck.stdout.toString().trim() == 'OK';
    } catch (_) {}

    notifyListeners();

    return {
      'installed': true,
      'version': ver,
      'pythonPath': pyPath,
      'scriptsDir': scriptsDir,
      'hasPyzk': hasPyzk,
      'hasFirebaseAdmin': hasFirebaseAdmin,
    };
  }

  /// Execute a specific Python script in the terminal.
  Future<bool> startScript(
    String scriptFileName, {
    List<String> args = const [],
    String? customWorkingDir,
  }) async {
    if (isRunning) {
      _appendLine(
        '⚠️ A process is already running (PID: ${_process!.pid}). Please stop it first.',
        TerminalLineType.warning,
      );
      return false;
    }

    final pyPath = await resolvePythonExecutable();
    final scriptsDir = customWorkingDir ?? await resolveScriptsDirectory();

    if (pyPath == null) {
      _appendLine(
        '❌ Python was not detected on this system. Please specify the Python path in Settings or install Python 3.',
        TerminalLineType.error,
      );
      return false;
    }

    final scriptFullPath = p.join(scriptsDir, scriptFileName);
    final scriptFile = File(scriptFullPath);

    if (!await scriptFile.exists()) {
      _appendLine(
        '❌ Script file not found at: $scriptFullPath',
        TerminalLineType.error,
      );
      return false;
    }

    _currentScript = scriptFileName;
    _startTime = DateTime.now();
    _uptime = Duration.zero;

    _uptimeTimer?.cancel();
    _uptimeTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_startTime != null) {
        _uptime = DateTime.now().difference(_startTime!);
        notifyListeners();
      }
    });

    _appendLine(
      '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━',
      TerminalLineType.system,
    );
    _appendLine(
      '🚀 Launching: $scriptFileName',
      TerminalLineType.system,
    );
    _appendLine(
      '📁 Working Directory: $scriptsDir',
      TerminalLineType.system,
    );
    _appendLine(
      '🐍 Python: $pyPath',
      TerminalLineType.system,
    );
    if (args.isNotEmpty) {
      _appendLine(
        '⚙️ Arguments: ${args.join(' ')}',
        TerminalLineType.system,
      );
    }
    _appendLine(
      '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━',
      TerminalLineType.system,
    );

    try {
      final processArgs = [
        '-u', // Unbuffered binary stdout and stderr so logs stream immediately
        scriptFullPath,
        ...args,
      ];

      _process = await Process.start(
        pyPath,
        processArgs,
        workingDirectory: scriptsDir,
        environment: {
          'PYTHONUNBUFFERED': '1',
          'PYTHONIOENCODING': 'utf-8',
        },
      );

      final pid = _process!.pid;
      _appendLine('🟢 Process started successfully [PID: $pid]', TerminalLineType.success);
      notifyListeners();

      // Listen to stdout
      _process!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        _parseAndAppendLine(line, isStderr: false);
      });

      // Listen to stderr
      _process!.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        _parseAndAppendLine(line, isStderr: true);
      });

      _isExplicitlyStopped = false;
      _watchdogTimer?.cancel();

      // Handle process exit
      _process!.exitCode.then((exitCode) {
        _uptimeTimer?.cancel();
        final durationStr = _uptime.toString().split('.').first;
        final wasDaemon = _currentScript == 'zkteco_sync_service.py';

        if (exitCode == 0) {
          _consecutiveCrashes = 0;
          _appendLine(
            '🏁 Process finished with exit code 0 (Success) [Ran for $durationStr]',
            TerminalLineType.success,
          );
        } else {
          _appendLine(
            '🛑 Process exited with code $exitCode [Ran for $durationStr]',
            TerminalLineType.error,
          );
        }
        _process = null;
        _startTime = null;
        notifyListeners();

        // Watchdog: If background daemon was active and not explicitly stopped by user, auto-recover!
        if (wasDaemon && !_isExplicitlyStopped && isAutoStartEnabled) {
          _consecutiveCrashes++;
          if (_consecutiveCrashes > 5) {
            _appendLine(
              '⚠️ [Watchdog] Python daemon crashed 5 consecutive times. Pausing auto-restart. '
              'Please check Python installation and required libraries (pyzk, firebase-admin) in Settings.',
              TerminalLineType.error,
            );
          } else {
            final backoffSeconds = (_consecutiveCrashes < 3) ? 5 : 15;
            _appendLine(
              '🔄 [Watchdog] Python daemon exited. Auto-restarting in ${backoffSeconds}s (recovery attempt #$_consecutiveCrashes)...',
              TerminalLineType.warning,
            );
            _watchdogTimer?.cancel();
            _watchdogTimer = Timer(Duration(seconds: backoffSeconds), () {
              if (!_isExplicitlyStopped && !isRunning && isAutoStartEnabled) {
                initAutoStart();
              }
            });
          }
        }
      });

      return true;
    } catch (e) {
      _uptimeTimer?.cancel();
      _process = null;
      _startTime = null;
      _appendLine('❌ Failed to start process: $e', TerminalLineType.error);
      notifyListeners();
      return false;
    }
  }

  /// Run a custom raw command (e.g. `pip install pyzk firebase-admin` or custom python flags)
  Future<bool> runCustomCommand(String commandLine) async {
    if (isRunning) {
      _appendLine(
        '⚠️ A process is already running (PID: ${_process!.pid}). Please stop it first.',
        TerminalLineType.warning,
      );
      return false;
    }

    final trimmed = commandLine.trim();
    if (trimmed.isEmpty) return false;

    final scriptsDir = await resolveScriptsDirectory();
    final pyPath = await resolvePythonExecutable() ?? 'python';

    _appendLine('❯ $trimmed', TerminalLineType.prompt);

    final parts = trimmed.split(RegExp(r'\s+'));
    String executable = parts.first;
    List<String> cmdArgs = parts.sublist(1);

    if (executable.toLowerCase() == 'python' || executable.toLowerCase() == 'py') {
      executable = pyPath;
    } else if (executable.toLowerCase() == 'pip') {
      // Use python -m pip
      cmdArgs = ['-m', 'pip', ...cmdArgs];
      executable = pyPath;
    }

    _startTime = DateTime.now();
    _uptime = Duration.zero;
    _currentScript = trimmed;

    _uptimeTimer?.cancel();
    _uptimeTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_startTime != null) {
        _uptime = DateTime.now().difference(_startTime!);
        notifyListeners();
      }
    });

    try {
      _process = await Process.start(
        executable,
        cmdArgs,
        workingDirectory: scriptsDir,
        environment: {
          'PYTHONUNBUFFERED': '1',
          'PYTHONIOENCODING': 'utf-8',
        },
      );

      final pid = _process!.pid;
      _appendLine('🟢 Command running [PID: $pid]', TerminalLineType.success);
      notifyListeners();

      _process!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        _parseAndAppendLine(line, isStderr: false);
      });

      _process!.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        _parseAndAppendLine(line, isStderr: true);
      });

      _process!.exitCode.then((code) {
        _uptimeTimer?.cancel();
        _appendLine('🏁 Command finished with exit code $code', code == 0 ? TerminalLineType.success : TerminalLineType.error);
        _process = null;
        _startTime = null;
        notifyListeners();
      });

      return true;
    } catch (e) {
      _uptimeTimer?.cancel();
      _process = null;
      _startTime = null;
      _appendLine('❌ Failed to execute command: $e', TerminalLineType.error);
      notifyListeners();
      return false;
    }
  }

  /// Installs the required Python packages (`pip install -r requirements.txt` or fallback to direct install)
  Future<void> installRequirements() async {
    final scriptsDir = await resolveScriptsDirectory();
    final reqPath = p.join(scriptsDir, 'requirements.txt');
    final hasReqFile = await File(reqPath).exists();

    if (hasReqFile) {
      await runCustomCommand('pip install -r requirements.txt');
    } else {
      await runCustomCommand('pip install pyzk firebase-admin');
    }
  }

  /// Send standard input text to the running process
  void sendInput(String input) {
    if (!isRunning || _process == null) {
      _appendLine('⚠️ No process is currently running to receive input.', TerminalLineType.warning);
      return;
    }

    _appendLine('❯ $input', TerminalLineType.prompt);
    try {
      _process!.stdin.writeln(input);
    } catch (e) {
      _appendLine('❌ Error writing to stdin: $e', TerminalLineType.error);
    }
  }

  /// Safely terminates the running process
  Future<void> stopProcess() async {
    if (!isRunning || _process == null) return;

    final pid = _process!.pid;
    _appendLine('🛑 Stopping process [PID: $pid]...', TerminalLineType.warning);

    try {
      if (Platform.isWindows) {
        // Kill process tree on Windows
        await Process.run('taskkill', ['/F', '/T', '/PID', '$pid']);
      } else {
        _process!.kill(ProcessSignal.sigterm);
      }
    } catch (_) {
      _process?.kill(ProcessSignal.sigkill);
    }

    _isExplicitlyStopped = true;
    _watchdogTimer?.cancel();
    _consecutiveCrashes = 0;
    _uptimeTimer?.cancel();
    _process = null;
    _startTime = null;
    _appendLine('⏹️ Process stopped.', TerminalLineType.system);
    notifyListeners();
  }

  /// Restarts the last executed script
  Future<void> restartProcess() async {
    final lastScript = _currentScript;
    if (isRunning) {
      await stopProcess();
      await Future.delayed(const Duration(milliseconds: 600));
    }
    if (lastScript != null && lastScript.isNotEmpty) {
      if (lastScript.endsWith('.py')) {
        await startScript(lastScript);
      } else {
        await runCustomCommand(lastScript);
      }
    }
  }

  /// Clear the terminal output buffer
  void clearLogs() {
    _lines.clear();
    notifyListeners();
  }

  void _parseAndAppendLine(String rawLine, {required bool isStderr}) {
    TerminalLineType type = isStderr ? TerminalLineType.stderr : TerminalLineType.stdout;
    final lower = rawLine.toLowerCase();

    if (lower.contains('[error]') || lower.contains('exception') || lower.contains('traceback') || lower.contains('failed')) {
      type = TerminalLineType.error;
    } else if (lower.contains('[warn]') || lower.contains('[warning]') || lower.contains('offline')) {
      type = TerminalLineType.warning;
    } else if (lower.contains('[success]') || lower.contains('connected') || lower.contains('synced') || lower.contains('successfully')) {
      type = TerminalLineType.success;
    } else if (lower.contains('[punch]') || lower.contains('punch:') || lower.contains('attendance:')) {
      type = TerminalLineType.punch;
    } else if (lower.contains('[info]')) {
      type = TerminalLineType.stdout;
    }

    _appendLine(rawLine, type);
  }

  void _appendLine(String text, TerminalLineType type) {
    final line = PythonTerminalLine(
      timestamp: DateTime.now(),
      text: text,
      type: type,
    );

    _lines.add(line);
    if (_lines.length > 2000) {
      _lines.removeAt(0);
    }

    _lineStreamController.add(line);
    notifyListeners();
  }

  @override
  void dispose() {
    _uptimeTimer?.cancel();
    _lineStreamController.close();
    super.dispose();
  }
}
