// lib/pages/school/views/school_about_view.dart

import 'package:flutter/material.dart';
import '../../../theme/role_theme_provider.dart';
import '../../../theme/app_theme.dart';

class SchoolAboutView extends StatelessWidget {
  final String branchId;
  final String? branchName;

  const SchoolAboutView({
    super.key,
    required this.branchId,
    this.branchName,
  });

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    final isMobile = MediaQuery.of(context).size.width < 700;

    return SingleChildScrollView(
      padding: EdgeInsets.all(isMobile ? 16 : 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Hero Banner with Dual Branding ───────────────────────────────
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(isMobile ? 20 : 32),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF0F172A), Color(0xFF1E293B), Color(0xFF1E1B4B)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // GMWF Logo
                    Container(
                      width: 52,
                      height: 52,
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.1),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Image.asset('assets/logo/gmwf-1.webp', fit: BoxFit.contain),
                    ),
                    const SizedBox(width: 14),
                    const Text('•', style: TextStyle(color: Colors.white38, fontSize: 24)),
                    const SizedBox(width: 14),

                    // TWT Official Logo
                    Container(
                      width: 52,
                      height: 52,
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.1),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Image.asset(
                        'assets/logo/twt.webp',
                        fit: BoxFit.contain,
                        errorBuilder: (ctx, error, stackTrace) => const Icon(Icons.school_rounded, color: Color(0xFF1E3A8A)),
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
                      ),
                      child: const Text(
                        'GMWF Project',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                const Text(
                  'Taleem-wa-Tarbiyat School System',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'A Prestigious Educational Initiative by Gulzar Madina Welfare Foundation (GMWF)',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.location_on_rounded, color: Color(0xFF38BDF8), size: 16),
                      const SizedBox(width: 8),
                      Text(
                        'Campus Branch: ${branchName ?? branchId.toUpperCase()}',
                        style: const TextStyle(
                          color: Color(0xFFE2E8F0),
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 28),

          // ── Vision & Mission Section ─────────────────────────────────────
          Text(
            'About the Institution',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: t.textPrimary,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 12),

          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _InfoCard(
                  t: t,
                  title: 'Our Vision',
                  icon: Icons.visibility_rounded,
                  iconColor: const Color(0xFF6366F1),
                  content: 'To foster intellectual excellence, religious values, and moral discipline (Tarbiyat) in every student, providing an inclusive learning environment backed by charitable welfare support.',
                ),
              ),
              if (!isMobile) const SizedBox(width: 16),
              if (!isMobile)
                Expanded(
                  child: _InfoCard(
                    t: t,
                    title: 'Our Mission',
                    icon: Icons.track_changes_rounded,
                    iconColor: const Color(0xFF10B981),
                    content: 'Delivering holistic secular and Islamic education with state-of-the-art campus digitization, continuous teacher training, merit scholarships, and well-equipped digital libraries.',
                  ),
                ),
            ],
          ),

          if (isMobile) ...[
            const SizedBox(height: 12),
            _InfoCard(
              t: t,
              title: 'Our Mission',
              icon: Icons.track_changes_rounded,
              iconColor: const Color(0xFF10B981),
              content: 'Delivering holistic secular and Islamic education with state-of-the-art campus digitization, continuous teacher training, merit scholarships, and well-equipped digital libraries.',
            ),
          ],

          const SizedBox(height: 28),

          // ── Digital Campus Highlights ────────────────────────────────────
          Text(
            'Integrated Campus Modules',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: t.textPrimary,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 12),

          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _FeatureTile(t: t, icon: Icons.how_to_reg_rounded, title: 'Live Attendance', subtitle: 'Students & Faculty log with instant offline caching'),
              _FeatureTile(t: t, icon: Icons.local_library_rounded, title: 'Library Management', subtitle: 'Track book registry, active loans & returns'),
              _FeatureTile(t: t, icon: Icons.grade_rounded, title: 'Grading & Exams', subtitle: 'Class-wise marksheets & performance metrics'),
              _FeatureTile(t: t, icon: Icons.payments_rounded, title: 'Fee Management', subtitle: 'Voucher tracking, waivers & financial records'),
              _FeatureTile(t: t, icon: Icons.sync_rounded, title: 'LAN & Cloud Sync', subtitle: 'Dual-path offline local server & Firestore sync'),
              _FeatureTile(t: t, icon: Icons.security_rounded, title: 'Audit Trail', subtitle: 'Role-based action auditing and security logs'),
            ],
          ),

          const SizedBox(height: 32),

          // ── Legal & Copyright Statement ──────────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: t.bgCard,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: t.bgRule),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.verified_user_rounded, color: t.accent, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      'Legal & Data Integrity Notice',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: t.textPrimary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  'Taleem-wa-Tarbiyat School System (TWT) is owned, managed, and financially patronized by Gulzar Madina Welfare Foundation (GMWF).\n\n'
                  'All educational data, student records, examination archives, faculty profiles, and institutional information are securely encrypted and protected under GMWF IT governance policies.\n\n'
                  '© ${DateTime.now().year} Gulzar Madina Welfare Foundation (GMWF). All Rights Reserved.',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: t.textSecondary,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final RoleThemeData t;
  final String title;
  final IconData icon;
  final Color iconColor;
  final String content;

  const _InfoCard({
    required this.t,
    required this.title,
    required this.icon,
    required this.iconColor,
    required this.content,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: t.bgRule),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: iconColor, size: 20),
              ),
              const SizedBox(width: 10),
              Text(
                title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: t.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            content,
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              color: t.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _FeatureTile extends StatelessWidget {
  final RoleThemeData t;
  final IconData icon;
  final String title;
  final String subtitle;

  const _FeatureTile({
    required this.t,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 700;
    return Container(
      width: isMobile ? double.infinity : 280,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.bgRule),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: t.accent.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: t.accent, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: t.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11,
                    color: t.textTertiary,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
