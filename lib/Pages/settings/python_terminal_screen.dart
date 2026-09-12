// lib/pages/settings/python_terminal_screen.dart - Terminal runner screen

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../services/python_runner_service.dart';

class PythonTerminalScreen extends StatelessWidget {
  final String? initialScript;
  final List<String>? initialArgs;
  final bool autoStart;
  final VoidCallback? onBack;

  const PythonTerminalScreen({
    super.key,
    this.initialScript,
    this.initialArgs,
    this.autoStart = false,
    this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: onBack == null && Navigator.canPop(context),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (onBack != null) {
          onBack!();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0B0F19), // Deepest Onyx/Slate
        appBar: AppBar(
          backgroundColor: const Color(0xFF0F172A), // Slate 900
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
            onPressed: () {
              if (onBack != null) {
                onBack!();
              } else if (Navigator.canPop(context)) {
                Navigator.pop(context);
              }
            },
          ),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color(0xFF38BDF8).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF38BDF8).withValues(alpha: 0.3)),
                ),
                child: const Icon(Icons.terminal_rounded, color: Color(0xFF38BDF8), size: 20),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Python Biometric & Hardware Terminal',
                    style: GoogleFonts.outfit(
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      fontSize: 17,
                    ),
                  ),
                  Text(
                    'Live execution console for ZKTeco hardware daemons & scripts',
                    style: GoogleFonts.inter(
                      color: const Color(0xFF94A3B8),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.help_outline_rounded, color: Color(0xFF94A3B8)),
              tooltip: 'Terminal Guide & Help',
              onPressed: () => _showHelpDialog(context),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: PythonTerminalView(
          initialScript: initialScript,
          initialArgs: initialArgs,
          autoStart: autoStart,
        ),
      ),
    );
  }

  void _showHelpDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.info_outline_rounded, color: Color(0xFF38BDF8)),
            const SizedBox(width: 10),
            Text(
              'Python Terminal Guide',
              style: GoogleFonts.outfit(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 18),
            ),
          ],
        ),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHelpItem(
                  '⚡ zkteco_sync_service.py',
                  'Background sync daemon that connects to all configured ZKTeco biometric devices over LAN, pulls live attendance punches, and syncs them to Cloud Firestore in real time.',
                ),
                const SizedBox(height: 12),
                _buildHelpItem(
                  '🧪 test_zkteco_sync.py',
                  'Diagnostic tool that tests direct TCP handshakes with ZKTeco hardware, retrieves device firmware/serial numbers, and tests punch downloads.',
                ),
                const SizedBox(height: 12),
                _buildHelpItem(
                  '🧹 dedupe_punches.py',
                  'Scans recent attendance logs and removes duplicate punches within a configured time threshold (e.g. 5 minutes).',
                ),
                const SizedBox(height: 12),
                _buildHelpItem(
                  '🗑️ clean_test_punches.py',
                  'Removes test/dummy punch records generated during hardware testing.',
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF334155)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.lightbulb_outline_rounded, color: Color(0xFFFBBF24), size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'The terminal runs in the background. You can navigate between pages while scripts continue running!',
                          style: GoogleFonts.inter(color: const Color(0xFFCBD5E1), fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              foregroundColor: Colors.white,
            ),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  Widget _buildHelpItem(String title, String desc) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: GoogleFonts.firaCode(fontWeight: FontWeight.bold, color: const Color(0xFF38BDF8), fontSize: 13)),
        const SizedBox(height: 3),
        Text(desc, style: GoogleFonts.inter(color: const Color(0xFF94A3B8), fontSize: 12)),
      ],
    );
  }
}

class PythonTerminalView extends StatefulWidget {
  final String? initialScript;
  final List<String>? initialArgs;
  final bool autoStart;

  const PythonTerminalView({
    super.key,
    this.initialScript,
    this.initialArgs,
    this.autoStart = false,
  });

  @override
  State<PythonTerminalView> createState() => _PythonTerminalViewState();
}

class _PythonTerminalViewState extends State<PythonTerminalView> {
  final PythonRunnerService _runner = PythonRunnerService.instance;
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _inputController = TextEditingController();
  final TextEditingController _argsController = TextEditingController();
  final TextEditingController _searchFilterController = TextEditingController();

  final List<Map<String, String>> _availableScripts = [
    {
      'file': 'zkteco_sync_service.py',
      'label': 'zkteco_sync_service.py (Biometric Live Sync Daemon)',
      'defaultArgs': '--config config.json',
      'desc': 'Live daemon polling ZKTeco devices and pushing attendance to Firestore',
    },
    {
      'file': 'test_zkteco_sync.py',
      'label': 'test_zkteco_sync.py (Hardware Diagnostics & Ping)',
      'defaultArgs': '',
      'desc': 'Tests LAN communication and reads terminal firmware info',
    },
    {
      'file': 'dedupe_punches.py',
      'label': 'dedupe_punches.py (Attendance Deduplicator)',
      'defaultArgs': '',
      'desc': 'Deduplicates punch logs in database and local queues',
    },
    {
      'file': 'clean_test_punches.py',
      'label': 'clean_test_punches.py (Purge Test Records)',
      'defaultArgs': '',
      'desc': 'Cleans simulated test records from attendance logs',
    },
    {
      'file': 'excel_data_importer.py',
      'label': 'excel_data_importer.py (Excel Biometric Importer)',
      'defaultArgs': '',
      'desc': 'Imports employee rosters and maps biometric PINs from Excel',
    },
  ];

  late String _selectedScript;
  bool _autoScroll = true;
  String _searchFilter = '';
  StreamSubscription? _lineSubscription;

  @override
  void initState() {
    super.initState();
    _selectedScript = widget.initialScript ?? _availableScripts.first['file']!;
    
    final matching = _availableScripts.firstWhere(
      (s) => s['file'] == _selectedScript,
      orElse: () => _availableScripts.first,
    );
    _argsController.text = widget.initialArgs?.join(' ') ?? matching['defaultArgs'] ?? '';

    _runner.addListener(_onRunnerUpdate);

    // Auto-scroll on new lines if enabled
    _lineSubscription = _runner.lineStream.listen((_) {
      if (_autoScroll && _scrollController.hasClients) {
        Future.delayed(const Duration(milliseconds: 30), () {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
            );
          }
        });
      }
    });

    if (widget.autoStart && !_runner.isRunning) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _startSelectedScript();
      });
    }
  }

  @override
  void dispose() {
    _runner.removeListener(_onRunnerUpdate);
    _lineSubscription?.cancel();
    _scrollController.dispose();
    _inputController.dispose();
    _argsController.dispose();
    _searchFilterController.dispose();
    super.dispose();
  }

  void _onRunnerUpdate() {
    if (mounted) setState(() {});
  }

  Future<void> _startSelectedScript() async {
    final rawArgs = _argsController.text.trim();
    final argsList = rawArgs.isEmpty ? <String>[] : rawArgs.split(RegExp(r'\s+'));
    await _runner.startScript(_selectedScript, args: argsList);
  }

  Future<void> _stopScript() async {
    await _runner.stopProcess();
  }

  Future<void> _restartScript() async {
    await _runner.restartProcess();
  }

  void _sendStdinInput() {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    _runner.sendInput(text);
    _inputController.clear();
  }

  void _copyAllLogs() {
    final buffer = StringBuffer();
    for (final l in _runner.lines) {
      buffer.writeln('[${l.formattedTime}] ${l.text}');
    }
    Clipboard.setData(ClipboardData(text: buffer.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('📋 Terminal output copied to clipboard!'),
        backgroundColor: Color(0xFF0F766E),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isRunning = _runner.isRunning;
    final filteredLines = _searchFilter.isEmpty
        ? _runner.lines
        : _runner.lines
            .where((l) => l.text.toLowerCase().contains(_searchFilter.toLowerCase()))
            .toList();

    return Container(
      color: const Color(0xFF0B0F19), // Ultra-dark modern terminal background
      child: Column(
        children: [
          _buildStatusBar(isRunning),
          _buildControlToolbar(isRunning),
          Expanded(
            child: _buildTerminalConsole(filteredLines),
          ),
          _buildQuickCommandChips(),
          _buildInputPromptBar(isRunning),
        ],
      ),
    );
  }

  Widget _buildStatusBar(bool isRunning) {
    final uptimeStr = _runner.uptime.toString().split('.').first;
    final pid = _runner.runningPid;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFF0F172A),
        border: Border(
          bottom: BorderSide(color: Color(0xFF1E293B), width: 1),
        ),
      ),
      child: Row(
        children: [
          // Live status pill
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: isRunning ? const Color(0xFF065F46) : const Color(0xFF334155),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isRunning ? const Color(0xFF10B981) : const Color(0xFF64748B),
                width: 1.2,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: isRunning ? const Color(0xFF34D399) : const Color(0xFF94A3B8),
                    shape: BoxShape.circle,
                    boxShadow: isRunning
                        ? [
                            BoxShadow(
                              color: const Color(0xFF34D399).withValues(alpha: 0.8),
                              blurRadius: 6,
                              spreadRadius: 2,
                            ),
                          ]
                        : null,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  isRunning ? 'RUNNING' : 'STOPPED',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: isRunning ? const Color(0xFFECFDF5) : const Color(0xFFCBD5E1),
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),

          // Process info
          if (isRunning) ...[
            Text(
              'PID: $pid',
              style: GoogleFonts.firaCode(fontSize: 12, color: const Color(0xFF38BDF8), fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 12),
            Container(width: 1, height: 14, color: const Color(0xFF334155)),
            const SizedBox(width: 12),
            Row(
              children: [
                const Icon(Icons.timer_outlined, size: 14, color: Color(0xFF94A3B8)),
                const SizedBox(width: 4),
                Text(
                  uptimeStr,
                  style: GoogleFonts.firaCode(fontSize: 12, color: const Color(0xFFE2E8F0)),
                ),
              ],
            ),
          ],

          const Spacer(),

          // Auto-start on boot toggle badge
          InkWell(
            onTap: () async {
              final current = _runner.isAutoStartEnabled;
              await _runner.setAutoStartEnabled(!current);
            },
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: _runner.isAutoStartEnabled ? const Color(0xFF065F46).withValues(alpha: 0.3) : const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: _runner.isAutoStartEnabled ? const Color(0xFF10B981) : const Color(0xFF334155),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _runner.isAutoStartEnabled ? Icons.bolt_rounded : Icons.flash_off_rounded,
                    size: 14,
                    color: _runner.isAutoStartEnabled ? const Color(0xFF34D399) : const Color(0xFF94A3B8),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    _runner.isAutoStartEnabled ? 'Auto-Start: ON' : 'Auto-Start: OFF',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      color: _runner.isAutoStartEnabled ? const Color(0xFF6EE7B7) : const Color(0xFF94A3B8),
                      fontWeight: _runner.isAutoStartEnabled ? FontWeight.bold : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),

          // Python version badge & Environment Settings
          InkWell(
            onTap: _showEnvironmentDialog,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.settings_suggest_rounded, size: 14, color: Color(0xFF38BDF8)),
                  const SizedBox(width: 6),
                  Text(
                    'Python: ${_runner.pythonVersion}',
                    style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF94A3B8), fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControlToolbar(bool isRunning) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF131C2E),
        border: Border(
          bottom: BorderSide(color: Color(0xFF1E293B), width: 1),
        ),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // Script Selector Dropdown
          Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _selectedScript,
                dropdownColor: const Color(0xFF1E293B),
                icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Color(0xFF94A3B8), size: 18),
                style: GoogleFonts.firaCode(color: Colors.white, fontSize: 12),
                items: _availableScripts.map((s) {
                  return DropdownMenuItem<String>(
                    value: s['file'],
                    child: Text(s['file']!, style: const TextStyle(color: Color(0xFFE2E8F0))),
                  );
                }).toList(),
                onChanged: isRunning
                    ? null
                    : (val) {
                        if (val != null) {
                          setState(() {
                            _selectedScript = val;
                            final matching = _availableScripts.firstWhere((s) => s['file'] == val);
                            _argsController.text = matching['defaultArgs'] ?? '';
                          });
                        }
                      },
              ),
            ),
          ),

          // Arguments Input
          SizedBox(
            width: 170,
            height: 38,
            child: TextField(
              controller: _argsController,
              enabled: !isRunning,
              style: GoogleFonts.firaCode(color: const Color(0xFFE2E8F0), fontSize: 11),
              decoration: InputDecoration(
                hintText: 'Arguments (e.g. --once)',
                hintStyle: GoogleFonts.firaCode(color: const Color(0xFF64748B), fontSize: 11),
                filled: true,
                fillColor: const Color(0xFF1E293B),
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFF334155)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFF334155)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFF38BDF8)),
                ),
              ),
            ),
          ),

          // Start / Run Button
          ElevatedButton.icon(
            onPressed: isRunning ? null : _startSelectedScript,
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: const Text('Start Daemon'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF059669),
              foregroundColor: Colors.white,
              disabledBackgroundColor: const Color(0xFF064E3B).withValues(alpha: 0.4),
              disabledForegroundColor: const Color(0xFF6EE7B7).withValues(alpha: 0.4),
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),

          // Stop Button
          ElevatedButton.icon(
            onPressed: isRunning ? _stopScript : null,
            icon: const Icon(Icons.stop_rounded, size: 18),
            label: const Text('Stop'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              foregroundColor: Colors.white,
              disabledBackgroundColor: const Color(0xFF7F1D1D).withValues(alpha: 0.3),
              disabledForegroundColor: const Color(0xFFFCA5A5).withValues(alpha: 0.3),
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),

          // Restart Button
          IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 18, color: Color(0xFF94A3B8)),
            tooltip: 'Restart Process',
            onPressed: _restartScript,
          ),

          // Clear Output
          IconButton(
            icon: const Icon(Icons.delete_sweep_rounded, size: 18, color: Color(0xFF94A3B8)),
            tooltip: 'Clear Console Output',
            onPressed: () => _runner.clearLogs(),
          ),

          // Copy Output
          IconButton(
            icon: const Icon(Icons.copy_rounded, size: 16, color: Color(0xFF94A3B8)),
            tooltip: 'Copy All Logs to Clipboard',
            onPressed: _copyAllLogs,
          ),

          // Auto-scroll toggle
          InkWell(
            onTap: () => setState(() => _autoScroll = !_autoScroll),
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: _autoScroll ? const Color(0xFF2563EB).withValues(alpha: 0.2) : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: _autoScroll ? const Color(0xFF3B82F6) : const Color(0xFF334155),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.vertical_align_bottom_rounded,
                    size: 14,
                    color: _autoScroll ? const Color(0xFF60A5FA) : const Color(0xFF94A3B8),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Auto-scroll',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      color: _autoScroll ? const Color(0xFF93C5FD) : const Color(0xFF94A3B8),
                      fontWeight: _autoScroll ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Search Filter in Output
          SizedBox(
            width: 140,
            height: 34,
            child: TextField(
              controller: _searchFilterController,
              style: GoogleFonts.inter(color: Colors.white, fontSize: 11),
              onChanged: (v) => setState(() => _searchFilter = v),
              decoration: InputDecoration(
                hintText: 'Filter logs...',
                hintStyle: GoogleFonts.inter(color: const Color(0xFF64748B), fontSize: 11),
                prefixIcon: const Icon(Icons.search_rounded, size: 14, color: Color(0xFF64748B)),
                prefixIconConstraints: const BoxConstraints(minWidth: 26),
                filled: true,
                fillColor: const Color(0xFF1E293B),
                contentPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTerminalConsole(List<PythonTerminalLine> lines) {
    if (lines.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: const Icon(Icons.terminal_rounded, size: 36, color: Color(0xFF64748B)),
            ),
            const SizedBox(height: 16),
            Text(
              'Terminal Console Ready',
              style: GoogleFonts.outfit(
                color: const Color(0xFFE2E8F0),
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Select a script above and click "Start Daemon" to begin live execution.',
              style: GoogleFonts.inter(color: const Color(0xFF94A3B8), fontSize: 12),
            ),
          ],
        ),
      );
    }

    return SelectionArea(
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.all(12),
        itemCount: lines.length,
        itemBuilder: (context, index) {
          final line = lines[index];
          return _buildConsoleLine(line, index + 1);
        },
      ),
    );
  }

  Widget _buildConsoleLine(PythonTerminalLine line, int lineNumber) {
    Color textColor;
    FontWeight fontWeight = FontWeight.normal;
    Color? backgroundColor;

    switch (line.type) {
      case TerminalLineType.system:
        textColor = const Color(0xFF38BDF8); // Cyan
        fontWeight = FontWeight.w600;
        break;
      case TerminalLineType.prompt:
        textColor = const Color(0xFFFBBF24); // Amber
        fontWeight = FontWeight.bold;
        break;
      case TerminalLineType.success:
        textColor = const Color(0xFF34D399); // Emerald
        fontWeight = FontWeight.w600;
        break;
      case TerminalLineType.error:
        textColor = const Color(0xFFF87171); // Red
        fontWeight = FontWeight.w600;
        backgroundColor = const Color(0xFF7F1D1D).withValues(alpha: 0.15);
        break;
      case TerminalLineType.warning:
        textColor = const Color(0xFFFBBF24); // Yellow/Amber
        break;
      case TerminalLineType.punch:
        textColor = const Color(0xFFA78BFA); // Purple
        fontWeight = FontWeight.bold;
        break;
      case TerminalLineType.stderr:
        textColor = const Color(0xFFFB923C); // Orange
        break;
      case TerminalLineType.stdout:
        textColor = const Color(0xFFE2E8F0); // Off-white / light slate
        break;
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 1),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Line Number
          SizedBox(
            width: 38,
            child: Text(
              '$lineNumber',
              style: GoogleFonts.firaCode(
                color: const Color(0xFF475569),
                fontSize: 11,
              ),
              textAlign: TextAlign.right,
            ),
          ),
          const SizedBox(width: 8),

          // Timestamp
          Text(
            '[${line.formattedTime}]',
            style: GoogleFonts.firaCode(
              color: const Color(0xFF64748B),
              fontSize: 11,
            ),
          ),
          const SizedBox(width: 8),

          // Content
          Expanded(
            child: Text(
              line.text,
              style: GoogleFonts.firaCode(
                color: textColor,
                fontSize: 12,
                fontWeight: fontWeight,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickCommandChips() {
    final chips = [
      {'label': '📦 Install Dependencies', 'cmd': 'pip install -r requirements.txt'},
      {'label': '⚡ Run Sync Once (--once)', 'script': 'zkteco_sync_service.py', 'args': '--once'},
      {'label': '🔍 Diagnostics Ping', 'script': 'test_zkteco_sync.py', 'args': ''},
      {'label': '🧹 Clear Terminal', 'action': 'clear'},
    ];

    return Container(
      height: 36,
      color: const Color(0xFF0F172A),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: chips.length,
        separatorBuilder: (_, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final c = chips[index];
          return ActionChip(
            label: Text(c['label']!),
            labelStyle: GoogleFonts.inter(color: const Color(0xFF94A3B8), fontSize: 11),
            backgroundColor: const Color(0xFF1E293B),
            side: const BorderSide(color: Color(0xFF334155)),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            onPressed: () {
              if (c['action'] == 'clear') {
                _runner.clearLogs();
              } else if (c['cmd'] != null) {
                _runner.runCustomCommand(c['cmd']!);
              } else if (c['script'] != null) {
                setState(() {
                  _selectedScript = c['script']!;
                  _argsController.text = c['args'] ?? '';
                });
                _startSelectedScript();
              }
            },
          );
        },
      ),
    );
  }

  Widget _buildInputPromptBar(bool isRunning) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        color: Color(0xFF0F172A),
        border: Border(
          top: BorderSide(color: Color(0xFF1E293B), width: 1),
        ),
      ),
      child: Row(
        children: [
          Text(
            '❯',
            style: GoogleFonts.firaCode(
              color: const Color(0xFF10B981),
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _inputController,
              onSubmitted: (_) => _sendStdinInput(),
              style: GoogleFonts.firaCode(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                hintText: isRunning
                    ? 'Send stdin input to running script...'
                    : 'Run custom command (e.g. pip install pyzk)...',
                hintStyle: GoogleFonts.firaCode(color: const Color(0xFF64748B), fontSize: 12),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                border: InputBorder.none,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.send_rounded, color: Color(0xFF38BDF8), size: 18),
            tooltip: 'Send Input / Command',
            onPressed: () {
              if (isRunning) {
                _sendStdinInput();
              } else {
                final cmd = _inputController.text.trim();
                if (cmd.isNotEmpty) {
                  _runner.runCustomCommand(cmd);
                  _inputController.clear();
                }
              }
            },
          ),
        ],
      ),
    );
  }

  void _showEnvironmentDialog() async {
    final env = await _runner.checkEnvironment();

    if (!mounted) return;

    final customPathCtrl = TextEditingController(text: _runner.customPythonPath ?? '');

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF0F172A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              const Icon(Icons.memory_rounded, color: Color(0xFF38BDF8)),
              const SizedBox(width: 10),
              Text(
                'Python Environment & Packages',
                style: GoogleFonts.outfit(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 18),
              ),
            ],
          ),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildEnvRow('Status', env['installed'] == true ? '✅ Installed' : '❌ Not Detected'),
                  _buildEnvRow('Version', '${env['version']}'),
                  _buildEnvRow('Executable', '${env['pythonPath'] ?? "None"}'),
                  _buildEnvRow('Scripts Dir', '${env['scriptsDir']}'),
                  _buildEnvRow('pyzk Library', env['hasPyzk'] == true ? '✅ Installed' : '❌ Missing'),
                  _buildEnvRow('firebase-admin', env['hasFirebaseAdmin'] == true ? '✅ Installed' : '❌ Missing'),
                  const SizedBox(height: 16),
                  Text(
                    'Custom Python Executable Path (Optional):',
                    style: GoogleFonts.inter(color: const Color(0xFF94A3B8), fontSize: 12),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: customPathCtrl,
                    style: GoogleFonts.firaCode(color: Colors.white, fontSize: 12),
                    decoration: InputDecoration(
                      hintText: 'C:\\Python314\\python.exe',
                      hintStyle: GoogleFonts.firaCode(color: const Color(0xFF64748B), fontSize: 11),
                      filled: true,
                      fillColor: const Color(0xFF1E293B),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFF334155)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _runner.installRequirements();
                    },
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: const Text('Install Required Packages (pip install)'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2563EB),
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(40),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: Color(0xFF94A3B8))),
            ),
            ElevatedButton(
              onPressed: () {
                _runner.setCustomPythonPath(customPathCtrl.text.trim().isEmpty ? null : customPathCtrl.text.trim());
                Navigator.pop(ctx);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF10B981),
                foregroundColor: Colors.white,
              ),
              child: const Text('Save & Re-detect'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEnvRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: GoogleFonts.inter(color: const Color(0xFF64748B), fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: GoogleFonts.firaCode(color: const Color(0xFFE2E8F0), fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
