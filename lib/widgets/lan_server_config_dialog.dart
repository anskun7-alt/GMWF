import 'package:flutter/material.dart';
import '../realtime/connection_manager.dart';
import '../config/constants.dart';

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
  late TextEditingController _ipCtrl;
  bool _isConnecting = false;
  String? _statusError;

  @override
  void initState() {
    super.initState();
    final saved = ConnectionManager().getSavedServerIp() ?? 
        ConnectionManager().status.ip ?? 
        '192.168.1.15';
    _ipCtrl = TextEditingController(text: saved);
  }

  @override
  void dispose() {
    _ipCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleConnect() async {
    final ip = _ipCtrl.text.trim();
    if (ip.isEmpty) {
      setState(() => _statusError = 'Please enter a valid IP address');
      return;
    }
    setState(() {
      _isConnecting = true;
      _statusError = null;
    });

    final ok = await ConnectionManager().connectDirectly(ip);
    if (!mounted) return;

    setState(() => _isConnecting = false);
    if (ok) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ Connected directly to LAN Server at $ip'),
          backgroundColor: const Color(0xFF0F5B46),
        ),
      );
    } else {
      setState(() {
        _statusError = 'Failed to reach server at $ip:${AppNetwork.websocketPort}. Check IP and firewall.';
      });
    }
  }

  Future<void> _handleAutoScan() async {
    setState(() {
      _isConnecting = true;
      _statusError = null;
    });
    await ConnectionManager().reconnectNow();
    if (!mounted) return;
    setState(() => _isConnecting = false);
    Navigator.of(context).pop();
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

        Color badgeColor = isConnected
            ? const Color(0xFF10B981)
            : (isSearching ? const Color(0xFFF97316) : const Color(0xFFEF4444));

        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
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
                        child: Icon(Icons.router_rounded, color: badgeColor, size: 24),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'LAN Server Connection',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              status.message,
                              style: TextStyle(
                                fontSize: 12.5,
                                color: badgeColor,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // IP input field
                  const Text(
                    'Server IP Address',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF334155)),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _ipCtrl,
                    decoration: InputDecoration(
                      hintText: 'e.g. 192.168.1.15',
                      prefixIcon: const Icon(Icons.computer_rounded, size: 20),
                      filled: true,
                      fillColor: Colors.grey.shade50,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.grey.shade300),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.grey.shade300),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFF0F5B46), width: 1.5),
                      ),
                    ),
                  ),

                  if (_statusError != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.error_outline, color: Colors.red, size: 16),
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
                          'Troubleshooting checklist:',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF475569)),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '• Look at the top bar of the Server PC for its exact IP address.\n'
                          '• Make sure this PC and Server PC are on the same Wi-Fi network.\n'
                          '• If using a router, verify "AP Isolation" or "Guest Wi-Fi" is disabled.',
                          style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700, height: 1.4),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 22),

                  // Actions
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: _isConnecting ? null : () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _isConnecting ? null : _handleAutoScan,
                        icon: const Icon(Icons.radar_rounded, size: 16),
                        label: const Text('Auto-Scan'),
                        style: OutlinedButton.styleFrom(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed: _isConnecting ? null : _handleConnect,
                        icon: _isConnecting
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.link_rounded, size: 18),
                        label: Text(_isConnecting ? 'Connecting...' : 'Connect Direct'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0F5B46),
                          foregroundColor: Colors.white,
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
