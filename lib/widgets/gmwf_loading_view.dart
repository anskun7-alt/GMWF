// lib/widgets/gmwf_loading_view.dart
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lottie/lottie.dart';
import '../constants/navigator_key.dart';

class GmwfLoadingView extends StatefulWidget {
  final String? message;
  final String? subMessage;
  final bool isFullPage;

  const GmwfLoadingView({
    super.key,
    this.message,
    this.subMessage,
    this.isFullPage = true,
  });

  @override
  State<GmwfLoadingView> createState() => _GmwfLoadingViewState();
}

class _GmwfLoadingViewState extends State<GmwfLoadingView>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late AnimationController _entryController;
  late AnimationController _shimmerController;
  late AnimationController _dotController;

  late Animation<double> _pulseAnim;
  late Animation<double> _fadeIn;
  late Animation<double> _slideUp;
  late Animation<double> _logoScale;
  late Animation<double> _shimmerAnim;
  late Animation<double> _dotAnim;

  Timer? _messageTimer;
  Timer? _emergencyTimer;
  bool _showEmergencyButton = false;
  int _messageIndex = 0;

  final List<String> _defaultMessages = [
    "Initializing system...",
    "Syncing branch data...",
    "Preparing your dashboard...",
    "Loading configuration...",
  ];

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);

    _pulseAnim = Tween<double>(begin: 0.35, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _entryController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
      value: 1.0, // Instantly visible on first frame so screen is NEVER blank
    );

    _fadeIn = CurvedAnimation(parent: _entryController, curve: Curves.easeOut);

    _slideUp = Tween<double>(begin: 30.0, end: 0.0).animate(
      CurvedAnimation(parent: _entryController, curve: Curves.easeOutCubic),
    );

    _logoScale = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(
        parent: _entryController,
        curve: const Interval(0.0, 0.6, curve: Curves.elasticOut),
      ),
    );

    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();

    _shimmerAnim = Tween<double>(begin: -1.0, end: 2.0).animate(
      CurvedAnimation(parent: _shimmerController, curve: Curves.easeInOut),
    );

    _dotController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();

    _dotAnim = CurvedAnimation(parent: _dotController, curve: Curves.easeInOut);

    if (widget.message == null) {
      _messageTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        if (mounted) {
          setState(() {
            _messageIndex = (_messageIndex + 1) % _defaultMessages.length;
          });
        }
      });
    }

    _emergencyTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _showEmergencyButton = true);
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _entryController.dispose();
    _shimmerController.dispose();
    _dotController.dispose();
    _messageTimer?.cancel();
    _emergencyTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isDesktop = size.width >= 900;
    final isTablet = size.width >= 600;
    final logoSize = isDesktop
        ? 120.0
        : (size.shortestSide * 0.18).clamp(72.0, 110.0);

    final isDark = Theme.of(context).brightness == Brightness.dark;

    // ── Design tokens (matching LoginPage) ───────────────────────────────────
    final bgColor   = isDark ? const Color(0xFF031611) : const Color(0xFFEFF6F0);
    final cardBg    = isDark ? const Color(0xFF041C16).withValues(alpha: 0.95) : Colors.white;
    final cardBorder= isDark ? const Color(0xFF10B981).withValues(alpha: 0.25) : const Color(0xFFD1FAE5);
    final cardShadow= isDark ? Colors.black.withValues(alpha: 0.45) : const Color(0xFF047857).withValues(alpha: 0.08);
    final badgeColor= isDark ? const Color(0xFF34D399) : const Color(0xFF059669);
    final badgeDivider= isDark ? const Color(0xFF047857) : const Color(0xFFA7F3D0);
    final titleMain = isDark ? Colors.white : const Color(0xFF064E3B);
    final titleAccent= isDark ? const Color(0xFF34D399) : const Color(0xFF059669);
    final subtitleColor= isDark ? Colors.white.withValues(alpha: 0.5) : const Color(0xFF4B5563);
    final shimmerColor= isDark ? const Color(0xFF34D399) : const Color(0xFF059669);
    final shimmerTrack= isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFF059669).withValues(alpha: 0.12);
    final glowColor = isDark ? const Color(0xFF10B981) : const Color(0xFF059669);
    final panelBg   = isDark ? const Color(0xFF02100C) : const Color(0xFF064E3B);

    final displayMessage = widget.message ?? _defaultMessages[_messageIndex];

    // ── Loading card ─────────────────────────────────────────────────────────
    final loadingCard = AnimatedBuilder(
      animation: _entryController,
      builder: (_, child) => Opacity(
        opacity: _fadeIn.value,
        child: Transform.translate(
          offset: Offset(0, _slideUp.value),
          child: child,
        ),
      ),
      child: Container(
        constraints: BoxConstraints(maxWidth: isDesktop ? 420 : 400),
        padding: EdgeInsets.symmetric(
          horizontal: isDesktop ? 40 : 28,
          vertical: isDesktop ? 44 : 32,
        ),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: cardBorder, width: 1.5),
          boxShadow: [
            BoxShadow(color: cardShadow, blurRadius: 32, offset: const Offset(0, 12)),
            BoxShadow(color: glowColor.withValues(alpha: isDark ? 0.10 : 0.05), blurRadius: 40, spreadRadius: 2),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Logo
            AnimatedBuilder(
              animation: Listenable.merge([_pulseController, _entryController]),
              builder: (_, child) => Transform.scale(
                scale: _logoScale.value,
                child: Container(
                  width: logoSize + 32,
                  height: logoSize + 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: glowColor.withValues(alpha: 0.28 * _pulseAnim.value),
                        blurRadius: 44 * _pulseAnim.value,
                        spreadRadius: 6 * _pulseAnim.value,
                      ),
                    ],
                  ),
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isDark ? const Color(0xFF02140F) : Colors.white,
                      border: Border.all(
                        color: glowColor.withValues(alpha: 0.35 + 0.30 * _pulseAnim.value),
                        width: 2,
                      ),
                    ),
                    padding: const EdgeInsets.all(12),
                    child: child,
                  ),
                ),
              ),
              child: Hero(
                tag: 'gmwf_app_logo',
                child: Image.asset(
                  'assets/logo/gmwf-1.webp',
                  width: logoSize,
                  height: logoSize,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => Icon(Icons.local_pharmacy, size: logoSize * 0.6, color: glowColor),
                ),
              ),
            ),

            const SizedBox(height: 24),

            // Tagline badge
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(width: 18, child: Divider(color: badgeDivider, thickness: 1.5)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    "GMWF SYSTEM",
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2.0,
                      color: badgeColor,
                    ),
                  ),
                ),
                SizedBox(width: 18, child: Divider(color: badgeDivider, thickness: 1.5)),
              ],
            ),

            const SizedBox(height: 14),

            // Title
            RichText(
              textAlign: TextAlign.center,
              text: TextSpan(
                style: GoogleFonts.inter(fontSize: isDesktop ? 30 : 26, fontWeight: FontWeight.w800),
                children: [
                  TextSpan(text: "Gulzar ", style: TextStyle(color: titleMain)),
                  TextSpan(text: "Madina", style: TextStyle(color: titleAccent)),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Welfare Foundation',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: subtitleColor,
                letterSpacing: 0.4,
              ),
            ),

            const SizedBox(height: 28),

            // Lottie / shimmer bar
            SizedBox(
              width: isTablet ? 240 : 200,
              height: 56,
              child: Lottie.asset(
                'assets/animations/loading (2).json',
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => Lottie.asset(
                  'assets/animations/loading (1).json',
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => _ShimmerBar(
                    progress: _shimmerAnim,
                    color: shimmerColor,
                    track: shimmerTrack,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 12),

            // Status dots + message
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedBuilder(
                  animation: _dotAnim,
                  builder: (_, _) {
                    return Row(
                      children: List.generate(3, (i) {
                        final delay = i * 0.33;
                        final v = (((_dotAnim.value - delay) % 1.0 + 1.0) % 1.0);
                        final scale = 0.6 + 0.7 * sin(v * pi);
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: Transform.scale(
                            scale: scale.clamp(0.6, 1.3),
                            child: Container(
                              width: 5, height: 5,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: badgeColor.withValues(alpha: (0.4 + 0.6 * scale).clamp(0.0, 1.0)),
                              ),
                            ),
                          ),
                        );
                      }),
                    );
                  },
                ),
                const SizedBox(width: 8),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  switchInCurve: Curves.easeOut,
                  child: Text(
                    displayMessage,
                    key: ValueKey(displayMessage),
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: badgeColor,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ],
            ),

            if (widget.subMessage != null) ...[
              const SizedBox(height: 6),
              Text(
                widget.subMessage!,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(fontSize: 11, color: subtitleColor),
              ),
            ],

            // Emergency button
            if (_showEmergencyButton) ...[
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: isDark ? 0.10 : 0.06),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      "Taking longer than expected?",
                      style: GoogleFonts.inter(
                        fontWeight: FontWeight.w700,
                        color: Colors.orangeAccent,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "Initializing local database & sync engine...",
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(fontSize: 11, color: subtitleColor),
                    ),
                    const SizedBox(height: 10),
                    ElevatedButton.icon(
                      onPressed: () {
                        if (navigatorKey.currentState != null) {
                          navigatorKey.currentState!.pushReplacementNamed('/home');
                        } else {
                          Navigator.pushReplacementNamed(context, '/home');
                        }
                      },
                      icon: const Icon(Icons.bolt, size: 15),
                      label: Text(
                        "Launch Dashboard",
                        style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w700),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF059669),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );

    if (!widget.isFullPage) {
      return Container(
        color: bgColor,
        child: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: loadingCard)),
      );
    }

    // ── Full page scaffold ────────────────────────────────────────────────────
    return Scaffold(
      backgroundColor: bgColor,
      body: Stack(
        children: [
          // Background arch image — responsive width & fast bounded decode
          Positioned(
            top: 0, bottom: 0, left: 0,
            width: isDesktop ? 560 : (size.width * 0.75).clamp(240.0, 420.0),
            child: Opacity(
              opacity: isDark ? 0.22 : 0.15,
              child: Image.asset(
                'assets/images/2.webp',
                fit: BoxFit.fitHeight,
                alignment: Alignment.topLeft,
                gaplessPlayback: true,
                cacheWidth: isDesktop ? 600 : 360,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),

          // Ambient luminous auroras
          Positioned(
            top: -80, left: -80,
            child: Container(
              width: 340, height: 340,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: glowColor.withValues(alpha: isDark ? 0.10 : 0.06),
              ),
            ),
          ),
          Positioned(
            bottom: -80, right: -80,
            child: Container(
              width: 360, height: 360,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: glowColor.withValues(alpha: isDark ? 0.13 : 0.07),
              ),
            ),
          ),

          // ── Desktop: luxury side panel + card ──────────────────────────────────────
          if (isDesktop)
            Row(
              children: [
                // Left panel — brand identity & programs
                Container(
                  width: 420,
                  color: Colors.transparent,
                  child: AnimatedBuilder(
                    animation: _entryController,
                    builder: (_, child) => Opacity(
                      opacity: _fadeIn.value,
                      child: Transform.translate(
                        offset: Offset(-20 * (1 - _fadeIn.value), 0),
                        child: child,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 40),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // Large glowing GMWF emblem
                          Container(
                            width: 84, height: 84,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: panelBg.withValues(alpha: 0.4),
                              border: Border.all(color: glowColor.withValues(alpha: 0.35), width: 1.5),
                              boxShadow: [
                                BoxShadow(
                                  color: glowColor.withValues(alpha: isDark ? 0.25 : 0.12),
                                  blurRadius: 28,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                            padding: const EdgeInsets.all(12),
                            child: Image.asset(
                              'assets/logo/gmwf-1.webp',
                              fit: BoxFit.contain,
                              gaplessPlayback: true,
                              errorBuilder: (_, _, _) => Icon(Icons.local_pharmacy, color: glowColor),
                            ),
                          ),
                          const SizedBox(height: 28),
                          Text(
                            'Gulzar Madina',
                            style: GoogleFonts.inter(
                              fontSize: 36,
                              fontWeight: FontWeight.w800,
                              color: titleAccent,
                              letterSpacing: -0.5,
                            ),
                          ),
                          Text(
                            'Welfare Foundation',
                            style: GoogleFonts.inter(
                              fontSize: 20,
                              fontWeight: FontWeight.w400,
                              color: isDark ? Colors.white.withValues(alpha: 0.7) : const Color(0xFF064E3B),
                            ),
                          ),
                          const SizedBox(height: 28),
                          _DesktopProgramPill(icon: Icons.soup_kitchen_outlined, label: 'Free Dasterkhawaan', color: glowColor, isDark: isDark),
                          const SizedBox(height: 10),
                          _DesktopProgramPill(icon: Icons.shopping_bag_outlined, label: 'Free Ration', color: glowColor, isDark: isDark),
                          const SizedBox(height: 10),
                          _DesktopProgramPill(icon: Icons.medical_services_outlined, label: 'Free Dispensary', color: glowColor, isDark: isDark),
                          const SizedBox(height: 10),
                          _DesktopProgramPill(icon: Icons.checkroom_outlined, label: 'Free Libaas', color: glowColor, isDark: isDark),
                          const SizedBox(height: 10),
                          _DesktopProgramPill(icon: Icons.menu_book_outlined, label: 'Free Madrassa', color: glowColor, isDark: isDark),
                        ],
                      ),
                    ),
                  ),
                ),

                // Right card
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(40),
                      child: loadingCard,
                    ),
                  ),
                ),
              ],
            )
          else
            // ── Mobile / Tablet: luxury centered card + bottom program tags ────
            SafeArea(
              child: Column(
                children: [
                  Expanded(
                    child: Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                        child: loadingCard,
                      ),
                    ),
                  ),
                  _buildMobileProgramsFooter(isDark, glowColor),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMobileProgramsFooter(bool isDark, Color glowColor) {
    final items = const [
      (Icons.soup_kitchen_outlined, 'Dasterkhawaan'),
      (Icons.shopping_bag_outlined, 'Ration'),
      (Icons.medical_services_outlined, 'Dispensary'),
      (Icons.checkroom_outlined, 'Free Libaas'),
      (Icons.menu_book_outlined, 'Madrassa'),
    ];

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12, left: 16, right: 16),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: items.map((it) {
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF041C16).withValues(alpha: 0.8)
                      : Colors.white.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: glowColor.withValues(alpha: isDark ? 0.2 : 0.15),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(it.$1, size: 12, color: glowColor),
                    const SizedBox(width: 5),
                    Text(
                      it.$2,
                      style: GoogleFonts.inter(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white70 : const Color(0xFF064E3B),
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}

// ── Desktop program pill ──────────────────────────────────────────────────────
class _DesktopProgramPill extends StatelessWidget {
  const _DesktopProgramPill({
    required this.icon,
    required this.label,
    required this.color,
    required this.isDark,
  });
  final IconData icon;
  final String label;
  final Color color;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 28, height: 28,
          decoration: BoxDecoration(
            color: color.withValues(alpha: isDark ? 0.15 : 0.10),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 14, color: color),
        ),
        const SizedBox(width: 10),
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: isDark ? Colors.white.withValues(alpha: 0.75) : const Color(0xFF064E3B).withValues(alpha: 0.8),
          ),
        ),
      ],
    );
  }
}

// ── Shimmer bar fallback ──────────────────────────────────────────────────────
class _ShimmerBar extends StatelessWidget {
  const _ShimmerBar({required this.progress, required this.color, required this.track});
  final Animation<double> progress;
  final Color color;
  final Color track;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        height: 4,
        child: AnimatedBuilder(
          animation: progress,
          builder: (_, _) => Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(2),
              color: track,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: CustomPaint(
                painter: _ShimmerBarPainter(progress: progress.value, color: color),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Shimmer bar painter ───────────────────────────────────────────────────────
class _ShimmerBarPainter extends CustomPainter {
  final double progress;
  final Color color;

  _ShimmerBarPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final barWidth = size.width * 0.45;
    final x = (progress * size.width) - barWidth / 2;

    final paint = Paint()
      ..shader = LinearGradient(
        colors: [
          color.withValues(alpha: 0.0),
          color.withValues(alpha: 0.7),
          color,
          color.withValues(alpha: 0.7),
          color.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.3, 0.5, 0.7, 1.0],
      ).createShader(Rect.fromLTWH(x, 0, barWidth, size.height));

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(max(0, x), 0, min(barWidth, size.width - max(0, x)), size.height),
        const Radius.circular(2),
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _ShimmerBarPainter old) => old.progress != progress;
}

