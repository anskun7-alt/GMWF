import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../realtime/connection_manager.dart';

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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('🟢 Connected to server at $ip'),
          backgroundColor: const Color(0xFF10B981),
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
      ScaffoldMessenger.of(context).showSnackBar(
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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('📋 Diagnostic log copied to clipboard & opened in Notepad!'),
              backgroundColor: Color(0xFF0F5B46),
              duration: Duration(seconds: 3),
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✅ No crash or error log found on this device.'),
              backgroundColor: Colors.blueGrey,
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error accessing log: $e'), backgroundColor: Colors.red),
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
        final status = snapshot.data ?? ConnectionManager().status;
        final isConnected = status.isConnected;
        final isSearching = status.isSearching || status.isConnecting;

        final Color badgeColor = isConnected
            ? const Color(0xFF10B981)
            : (isSearching ? const Color(0xFFF97316) : const Color(0xFFEF4444));

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
                      color: Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Status: ${status.message}',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1E293B),
                          ),
                        ),
                        if (status.ip != null && status.ip!.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            'Active Server: ${status.ip}:${status.port ?? 8080}',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Colors.grey.shade700,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  const SizedBox(height: 14),

                  // Manual IP override section
                  const Text(
                    'Manual Server Connection',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF334155)),
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
                            fillColor: Colors.grey.shade50,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide(color: Colors.grey.shade300),
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
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.link_rounded, size: 16),
                        label: Text(_isConnectingDirect ? 'Connecting...' : 'Connect Direct'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0F5B46),
                          foregroundColor: Colors.white,
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
                        const Icon(Icons.error_outline_rounded, color: Colors.red, size: 15),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _statusError!,
                            style: const TextStyle(color: Colors.red, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ],

                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Troubleshooting & Discovery Tips:',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF475569)),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '• Look at the top bar of the Server PC for its exact IP address.\n'
                          '• If auto-discovery does not connect, enter the Server IP above and tap "Connect Direct".\n'
                          '• Ensure both PCs are connected to the same clinic Wi-Fi or LAN switch.',
                          style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700, height: 1.4),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 22),

                  // Actions
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: _openOrCopyLog,
                        icon: const Icon(Icons.bug_report_outlined, size: 16),
                        label: const Text('View Log'),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.grey.shade700,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Close'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _isReconnecting ? null : _handleReconnect,
                        icon: _isReconnecting
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0F5B46)),
                              )
                            : const Icon(Icons.refresh_rounded, size: 18),
                        label: Text(_isReconnecting ? 'Scanning...' : 'Auto-Scan / Reconnect'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF0F5B46),
                          side: const BorderSide(color: Color(0xFF0F5B46)),
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
