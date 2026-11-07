import 'dart:io';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:gmwf/design/tokens/comfort_colors.dart';
import 'package:flutter/material.dart';
import 'package:gmwf/design/components/app_toast.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../realtime/connection_manager.dart';
import '../realtime/realtime_manager.dart';

class LanServerConfigDialog extends StatefulWidget {
  const LanServerConfigDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => const LanServerConfigDialog(),
    );
  }

  @override
  State<LanServerConfigDialog> createState() => _LanServerConfigDialogState();
}

class _LanServerConfigDialogState extends State<LanServerConfigDialog> {
  late final TextEditingController _ipCtrl;
  bool _isReconnecting = false;
  bool _isConnectingDirect = false;
  String? _statusError;

  @override
  void initState() {
    super.initState();
    _ipCtrl = TextEditingController(text: ConnectionManager().getSavedServerIp() ?? '');
  }

  @override
  void dispose() {
    _ipCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleConnectDirect() async {
    final ip = _ipCtrl.text.trim();
    if (ip.isEmpty) {
      setState(() => _statusError = 'Please enter a valid IP address (e.g. 192.168.1.15)');
      return;
    }
    setState(() {
      _isConnectingDirect = true;
      _statusError = null;
    });

    final ok = await ConnectionManager().connectDirectly(ip);
    if (!mounted) return;
    setState(() => _isConnectingDirect = false);

    if (ok) {
      Navigator.of(context).pop();
      AppToast.showSnackBar(context, 
        SnackBar(
          content: Text('🟢 Connected to server at $ip'),
          backgroundColor: SoftPalette.emerald350,
          duration: const Duration(seconds: 3),
        ),
      );
    } else {
      setState(() {
        _statusError = 'Could not connect to $ip. Ensure the Server is running on that PC.';
      });
    }
  }

  Future<void> _handleReconnect() async {
    setState(() {
      _isReconnecting = true;
      _statusError = null;
    });
    await ConnectionManager().reconnectNow();
    if (mounted) {
      setState(() => _isReconnecting = false);
      Navigator.of(context).pop();
      AppToast.showSnackBar(context, 
        const SnackBar(
          content: Text('🔄 Automatic LAN rediscovery initiated...'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _openOrCopyLog() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final logFile = File(p.join(dir.path, 'gmwf_crash.log'));
      if (await logFile.exists()) {
        final content = await logFile.readAsString();
        await Clipboard.setData(ClipboardData(text: content));
        if (Platform.isWindows) {
          Process.run('notepad.exe', [logFile.path]);
        }
        if (mounted) {
          AppToast.showSnackBar(context, 
            const SnackBar(
              content: Text('📋 Diagnostic log copied to clipboard & opened in Notepad!'),
              backgroundColor: SoftPalette.emerald600,
              duration: Duration(seconds: 3),
            ),
          );
        }
      } else {
        if (mounted) {
          AppToast.showSnackBar(context, 
            const SnackBar(
              content: Text('✅ No crash or error log found on this device.'),
              backgroundColor: SoftPalette.slate500,
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        AppToast.showSnackBar(context, 
          SnackBar(content: Text('Error accessing log: $e'), backgroundColor: SoftPalette.red400),
        );
      }
    }
  }

  Future<void> _runNetworkPressureTest() async {
    try {
      if (!Platform.isWindows) {
        AppToast.showSnackBar(context, 
          const SnackBar(content: Text('Network pressure testing is supported on Windows.')),
        );
        return;
      }

      const exeName = 'gmwf_pressure_test.exe';
      final currentExeDir = File(Platform.resolvedExecutable).parent.path;
      final candidatePaths = [
        p.join(currentExeDir, exeName),
        p.join(Directory.current.path, exeName),
        p.join(Directory.current.path, 'build', 'windows', 'x64', 'runner', 'Release', exeName),
        p.join('E:', 'GMWF', 'gmwf', exeName),
      ];

      File? targetExe;
      for (final cp in candidatePaths) {
        final f = File(cp);
        if (f.existsSync()) {
          targetExe = f;
          break;
        }
      }

      if (targetExe != null) {
        Process.run('cmd.exe', [
          '/c',
          'start',
          'GMWF LAN Network Pressure & Real Device Chaos Audit',
          'cmd.exe',
          '/k',
          targetExe.path,
          '--all',
        ]);
        if (mounted) {
          AppToast.showSnackBar(context, 
            const SnackBar(
              content: Text('🚀 Network Pressure Test launched! Report will be saved to Desktop & opened in Notepad.'),
              backgroundColor: SoftPalette.emerald600,
              duration: Duration(seconds: 4),
            ),
          );
        }
      } else {
        if (mounted) {
          AppToast.showSnackBar(context, 
            const SnackBar(
              content: Text('⚠️ gmwf_pressure_test.exe not found. Run Pressure_Test_Network.bat or compile it.'),
              backgroundColor: SoftPalette.amber300,
              duration: Duration(seconds: 4),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        AppToast.showSnackBar(context, 
          SnackBar(content: Text('Error launching pressure test: $e'), backgroundColor: SoftPalette.red400),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<ConnectionStatus>(
      stream: ConnectionManager().statusStream,
      initialData: ConnectionManager().status,
      builder: (context, snapshot) {
        final rm = RealtimeManager();
        final status = snapshot.data ?? ConnectionManager().status;
        final isConnected = status.isConnected || (rm.isConnected && rm.isServerIdentified);
        final isSearching = !isConnected && (status.isSearching || status.isConnecting);

        final Color badgeColor = isConnected
            ? SoftPalette.emerald350
            : (isSearching ? SoftPalette.orange350 : SoftPalette.red400);

        final String stateLabel = isConnected
            ? 'Connected'
            : (isSearching ? 'Searching / Connecting' : 'Disconnected');

        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title Row
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: badgeColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          isConnected
                              ? Icons.wifi_rounded
                              : (isSearching ? Icons.wifi_find_rounded : Icons.wifi_off_rounded),
                          color: badgeColor,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'LAN Connection Status',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: badgeColor,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  stateLabel,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    color: badgeColor,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),

                  // Connection info card
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: context.adapt(SoftPalette.gray50),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: context.adapt(SoftPalette.gray100)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Status: ${status.message}',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: context.adapt(SoftPalette.slate800),
                          ),
                        ),
                        if (status.ip != null && status.ip!.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            'Active Server: ${status.ip}:${status.port ?? 8080}',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: context.adapt(SoftPalette.gray550),
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  const SizedBox(height: 14),

                  // Manual IP override section
                  Text(
                    'Manual Server Connection',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.adapt(SoftPalette.slate700)),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _ipCtrl,
                          decoration: InputDecoration(
                            hintText: 'e.g. 192.168.1.15',
                            prefixIcon: const Icon(Icons.computer_rounded, size: 20),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                            filled: true,
                            fillColor: context.adapt(SoftPalette.gray50),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide(color: context.adapt(SoftPalette.gray150)),
                            ),
                          ),
                          onSubmitted: (_) => _handleConnectDirect(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed: _isConnectingDirect ? null : _handleConnectDirect,
                        icon: _isConnectingDirect
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2, color: SoftPalette.gray50),
                              )
                            : const Icon(Icons.link_rounded, size: 16),
                        label: Text(_isConnectingDirect ? 'Connecting...' : 'Connect Direct'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: SoftPalette.emerald600,
                          foregroundColor: SoftPalette.gray50,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ],
                  ),
                  if (_statusError != null) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Icon(Icons.error_outline_rounded, color: SoftPalette.red400, size: 15),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _statusError!,
                            style: const TextStyle(color: SoftPalette.red400, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ],

                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: context.adapt(SoftPalette.gray50),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: context.adapt(SoftPalette.slate150)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Troubleshooting & Discovery Tips:',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.adapt(SoftPalette.slate600)),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '• Look at the top bar of the Server PC for its exact IP address.\n'
                          '• If auto-discovery does not connect, enter the Server IP above and tap "Connect Direct".\n'
                          '• Ensure both PCs are connected to the same clinic Wi-Fi or LAN switch.',
                          style: TextStyle(fontSize: 11.5, color: context.adapt(SoftPalette.gray550), height: 1.4),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 22),

                  // Actions
                  Wrap(
                    spacing: 8,
                    runSpacing: 10,
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      TextButton.icon(
                        onPressed: _openOrCopyLog,
                        icon: const Icon(Icons.bug_report_outlined, size: 16),
                        label: const Text('View Log'),
                        style: TextButton.styleFrom(
                          foregroundColor: context.adapt(SoftPalette.gray550),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _runNetworkPressureTest,
                        icon: Icon(Icons.speed_rounded, size: 16, color: context.adapt(SoftPalette.emerald600)),
                        label: Text(
                          '⚡ Pressure Test',
                          style: TextStyle(color: context.adapt(SoftPalette.emerald600), fontWeight: FontWeight.bold),
                        ),
                        style: TextButton.styleFrom(
                          foregroundColor: context.adapt(SoftPalette.emerald600),
                        ),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Close'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _isReconnecting ? null : _handleReconnect,
                        icon: _isReconnecting
                            ? SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2, color: context.adapt(SoftPalette.emerald600)),
                              )
                            : const Icon(Icons.refresh_rounded, size: 18),
                        label: Text(_isReconnecting ? 'Scanning...' : 'Auto-Scan / Reconnect'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: context.adapt(SoftPalette.emerald600),
                          side: BorderSide(color: context.adapt(SoftPalette.emerald600)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
