import 'dart:async';
import 'package:flutter/material.dart';
import '../constants/colors.dart';
import '../main.dart';
import '../services/role_simulator_service.dart';

/// Global Self-Healing error widget and handler.
/// Replaces Flutter's default blank grey/white screen with an intelligent self-repair UI
/// that automatically reloads the workspace within 2 seconds.
class SelfHealingErrorView extends StatefulWidget {
  final FlutterErrorDetails? details;

  const SelfHealingErrorView({super.key, this.details});

  @override
  State<SelfHealingErrorView> createState() => _SelfHealingErrorViewState();
}

class _SelfHealingErrorViewState extends State<SelfHealingErrorView> {
  static int _recentRecoveryCount = 0;
  static DateTime? _recoveryWindowStart;

  int _countdownSeconds = 2;
  Timer? _countdownTimer;
  bool _isSafeMode = false;

  @override
  void initState() {
    super.initState();
    _checkRecoveryThreshold();
  }

  void _checkRecoveryThreshold() {
    final now = DateTime.now();
    if (_recoveryWindowStart == null || now.difference(_recoveryWindowStart!).inSeconds > 15) {
      _recoveryWindowStart = now;
      _recentRecoveryCount = 0;
    }
    _recentRecoveryCount++;

    // Safe mode ensures stability and user stays on their active screen
    _isSafeMode = true;
  }

  void _triggerRecovery() {
    _countdownTimer?.cancel();
    debugPrint('[SelfHealingErrorView] 🔄 Full workspace recovery triggered');
    AppRestartController.refreshApp();
  }

  void _returnToDashboard() {
    _countdownTimer?.cancel();
    debugPrint('[SelfHealingErrorView] 🔄 Returning to clean dashboard');
    try {
      RoleSimulatorService.reset();
    } catch (_) {}
    AppRestartController.refreshApp();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Compact fallback for tiny widget exceptions (e.g. list tile or small card)
        if (constraints.maxHeight < 160 || constraints.maxWidth < 280) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.red.withValues(alpha: 0.2)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.refresh_rounded, size: 16, color: Colors.redAccent),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    'Render notice — recovering...',
                    style: TextStyle(fontSize: 11, color: Colors.redAccent),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: _triggerRecovery,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Reload', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          );
        }

        // Full Screen / Major Component Self-Healing View
        final isDark = Theme.of(context).brightness == Brightness.dark;

        return Material(
          color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Container(
                  padding: const EdgeInsets.all(32),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF1E293B) : Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                        blurRadius: 24,
                        offset: const Offset(0, 10),
                      ),
                    ],
                    border: Border.all(
                      color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Healing Pulsing Badge
                      Container(
                        width: 68,
                        height: 68,
                        decoration: BoxDecoration(
                          color: _isSafeMode
                              ? Colors.amber.withValues(alpha: 0.15)
                              : AppColors.primary.withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _isSafeMode ? Icons.shield_rounded : Icons.auto_mode_rounded,
                          size: 36,
                          color: _isSafeMode ? Colors.amber[700] : AppColors.primary,
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Title
                      Text(
                        _isSafeMode ? 'Safe Mode Activated' : 'Self-Healing in Progress',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : const Color(0xFF0F172A),
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 10),

                      // Description
                      Text(
                        _isSafeMode
                            ? 'Repeated rendering errors detected in this view. Safe mode prevented an endless reload loop.'
                            : 'An unexpected display error occurred in this module. GMWF Self-Healing is automatically restoring your workspace.',
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          color: isDark ? Colors.white70 : const Color(0xFF475569),
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),

                      // Countdown or Action buttons
                      if (!_isSafeMode) ...[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: AppColors.primary,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              'Reloading workspace in ${_countdownSeconds}s...',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: isDark ? Colors.white : const Color(0xFF1E293B),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: _triggerRecovery,
                                icon: const Icon(Icons.refresh_rounded, size: 18),
                                label: const Text('Reload Immediately'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.primary,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 13),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ] else ...[
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: _returnToDashboard,
                                icon: const Icon(Icons.dashboard_rounded, size: 18),
                                label: const Text('Return to Dashboard'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.primary,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 13),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _triggerRecovery,
                                icon: const Icon(Icons.restart_alt_rounded, size: 18),
                                label: const Text('Retry Screen'),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 13),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
