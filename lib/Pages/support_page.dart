// lib/pages/support_page.dart
import 'package:flutter/material.dart';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import '../theme/app_theme.dart';
import '../theme/role_theme_provider.dart';
import '../utils/localization_helper.dart';
import '../services/auto_update_service.dart';
import '../design/design_system.dart';

class SupportPage extends StatefulWidget {
  const SupportPage({super.key});

  @override
  State<SupportPage> createState() => _SupportPageState();
}

class _SupportPageState extends State<SupportPage> {
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _bugController = TextEditingController();
  
  String _searchQuery = "";
  bool _submittingBug = false;
  final Set<int> _expandedFaqIndices = {};

  final List<Map<String, String>> _resources = [
    {
      'title': 'Manual',
      'subtitle': 'How to use',
      'icon': 'book',
      'url': 'https://www.gmwf.org/manual',
    },
    {
      'title': 'Videos',
      'subtitle': 'Tutorials',
      'icon': 'video',
      'url': 'https://www.gmwf.org/videos',
    },
    {
      'title': 'Changelog',
      'subtitle': "What's new",
      'icon': 'history',
      'url': 'https://www.gmwf.org/changelog',
    },
    {
      'title': 'Privacy',
      'subtitle': 'Data policy',
      'icon': 'privacy',
      'url': 'https://www.gmwf.org/privacy',
    },
  ];

  final List<Map<String, String>> _faqs = [
    {
      'question': 'How do I sync data manually?',
      'answer': 'Go to the Settings page, scroll down to the "Database & Sync" section, and click on the "Manual Sync (Upload)" button. This will push any pending local database updates to Firebase Firestore immediately.',
    },
    {
      'question': 'Printer not detected — what should I check?',
      'answer': '1. Ensure your thermal printer is turned on and connected via USB or local LAN.\n2. Go to Settings and verify the "Printer Mode" is set to "Thermal Receipt" and the width is correct (58mm or 80mm).\n3. Check if standard Windows printing queue drivers are active for the device.',
    },
    {
      'question': 'How do I change the receipt terminal ID?',
      'answer': 'Navigate to Settings, find the "DEVICES & PRINTERS" section, and enter your 4-digit alphanumeric code inside the "Terminal ID" field. The app remembers this code persistently on your disk.',
    },
    {
      'question': 'What does a factory wipe delete?',
      'answer': 'A factory data reset wipes all local cache data from the device, including unsynced local patient records, session credentials, and settings. Synced remote records in Firebase remain safe.',
    },
  ];

  @override
  void dispose() {
    _searchController.dispose();
    _bugController.dispose();
    super.dispose();
  }

  void _filterItems(String val) {
    setState(() {
      _searchQuery = val.toLowerCase().trim();
      _expandedFaqIndices.clear(); // Collapse all on search to avoid index mismatch
    });
  }

  Future<void> _launchURL(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  Future<void> _submitBugReport(BuildContext context, RoleThemeData t) async {
    final text = _bugController.text.trim();
    if (text.isEmpty) {
      AppToast.showSnackBar(context, 
        const SnackBar(content: Text("Please write a description of the issue first."), backgroundColor: SoftPalette.red400),
      );
      return;
    }

    setState(() => _submittingBug = true);

    try {
      // Send message to Sentry
      await Sentry.captureMessage(
        "User Bug Report: $text\nDevice: Windows Desktop\nTimestamp: ${DateTime.now().toIso8601String()}",
        level: SentryLevel.error,
      );

      if (mounted) {
        _bugController.clear();
        AppToast.fromSnackBar(
          const SnackBar(
            content: Text("✅ Bug report submitted to developer dashboard. Thank you!"),
            backgroundColor: SoftPalette.green400,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        AppToast.fromSnackBar(
          SnackBar(content: Text("Failed to submit report: $e"), backgroundColor: SoftPalette.red400),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _submittingBug = false);
      }
    }
  }

  Widget _sectionLabel(RoleThemeData t, String label) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 12, top: 20),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: t.textTertiary,
          fontSize: 10,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  Widget _divider(RoleThemeData t) {
    return Divider(color: t.bgRule, height: 1);
  }

  IconData _getResourceIcon(String key) {
    switch (key) {
      case 'book':
        return Icons.menu_book_rounded;
      case 'video':
        return Icons.videocam_outlined;
      case 'history':
        return Icons.history_toggle_off_rounded;
      case 'privacy':
        return Icons.security_rounded;
      default:
        return Icons.help_outline_rounded;
    }
  }

  Color _getResourceColor(String key) {
    switch (key) {
      case 'book':
        return SoftPalette.red500;
      case 'video':
        return SoftPalette.purple550;
      case 'history':
        return SoftPalette.amber300;
      case 'privacy':
        return SoftPalette.teal500;
      default:
        return SoftPalette.gray350;
    }
  }

  Widget _buildSupportTile({
    required RoleThemeData t,
    required IconData icon,
    required String title,
    required String subtitle,
    required Color iconColor,
    String? replyTime,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(color: t.textPrimary, fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(color: t.textTertiary, fontSize: 13),
                  ),
                ],
              ),
            ),
            if (replyTime != null) ...[
              Text(
                replyTime,
                style: TextStyle(color: t.textTertiary, fontSize: 12),
              ),
              const SizedBox(width: 8),
            ],
            Icon(Icons.open_in_new_rounded, color: t.textTertiary, size: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildResourceCard({
    required RoleThemeData t,
    required IconData icon,
    required String title,
    required String subtitle,
    required Color iconColor,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: t.bgCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: t.bgRule),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(height: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 14),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(color: t.textTertiary, fontSize: 11),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    final isDesktop = GBreakpoint.isDesktop(context);

    // Filter items based on search query
    final filteredResources = _resources.where((res) {
      if (_searchQuery.isEmpty) return true;
      return res['title']!.toLowerCase().contains(_searchQuery) ||
          res['subtitle']!.toLowerCase().contains(_searchQuery);
    }).toList();

    final filteredFaqs = _faqs.where((faq) {
      if (_searchQuery.isEmpty) return true;
      return faq['question']!.toLowerCase().contains(_searchQuery) ||
          faq['answer']!.toLowerCase().contains(_searchQuery);
    }).toList();

    return Directionality(
      textDirection: TextDirection.ltr,
      child: Scaffold(
        backgroundColor: t.bg,
        appBar: AppBar(
          backgroundColor: t.bgCard,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          leading: IconButton(
            icon: Icon(Icons.arrow_back_rounded, color: t.textSecondary, size: 22),
            onPressed: () => Navigator.maybePop(context),
          ),
          title: Text(
            context.tr('Support & Help'),
            style: TextStyle(
              color: t.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
            ),
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Divider(color: t.bgRule, height: 1),
          ),
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: isDesktop ? 680 : double.infinity),
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // HERO CARD
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: SoftPalette.pink550, // Brand Pink Banner
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: SoftPalette.pink550.withValues(alpha: 0.25),
                          blurRadius: 20,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: SoftPalette.gray50.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Icon(Icons.volunteer_activism_rounded, color: SoftPalette.gray50, size: 36),
                        ),
                        const SizedBox(width: 20),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                "About GMWF",
                                style: TextStyle(color: SoftPalette.gray50, fontSize: 20, fontWeight: FontWeight.w900),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                "Gulzar Madina Welfare Foundation — providing free medical assistance and social welfare services to those in need.",
                                style: TextStyle(color: SoftPalette.gray50.withValues(alpha: 0.9), fontSize: 13, height: 1.4, fontWeight: FontWeight.w500),
                              ),
                              const SizedBox(height: 14),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color: SoftPalette.gray50.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 8,
                                      height: 8,
                                      decoration: const BoxDecoration(color: SoftPalette.emerald200, shape: BoxShape.circle),
                                    ),
                                    const SizedBox(width: 8),
                                    const Text(
                                      "All systems operational",
                                      style: TextStyle(color: SoftPalette.gray50, fontSize: 11, fontWeight: FontWeight.w700),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // SEARCH HELP
                  TextField(
                    controller: _searchController,
                    onChanged: _filterItems,
                    style: TextStyle(color: t.textPrimary),
                    decoration: roleInputDecoration(
                      context,
                      label: "Search for help — e.g. printer, sync, receipt...",
                      icon: Icons.search_rounded,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // CONTACT SUPPORT SECTION
                  _sectionLabel(t, "Contact support"),
                  RoleCard(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Column(
                      children: [
                        _buildSupportTile(
                          t: t,
                          icon: Icons.chat_bubble_outline_rounded,
                          title: "WhatsApp support",
                          subtitle: "+92 331 8525333",
                          iconColor: SoftPalette.green400,
                          replyTime: "~ 2 hr reply",
                          onTap: () => _launchURL("https://wa.me/923318525333"),
                        ),
                        _divider(t),
                        _buildSupportTile(
                          t: t,
                          icon: Icons.alternate_email_rounded,
                          title: "Email support",
                          subtitle: "gulzarmadina@gmail.com",
                          iconColor: SoftPalette.blue400,
                          replyTime: "~ 1 day reply",
                          onTap: () => _launchURL("mailto:gulzarmadina@gmail.com"),
                        ),
                        _divider(t),
                        _buildSupportTile(
                          t: t,
                          icon: Icons.public_rounded,
                          title: "Official website",
                          subtitle: "gmwf.pk",
                          iconColor: t.accent,
                          onTap: () => _launchURL("https://gmwf.pk"),
                        ),
                      ],
                    ),
                  ),

                  // HELPFUL RESOURCES SECTION
                  if (filteredResources.isNotEmpty) ...[
                    _sectionLabel(t, "Helpful resources"),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final width = constraints.maxWidth;
                        final crossAxisCount = width >= 550 ? 4 : 2;
                        return GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: crossAxisCount,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                            childAspectRatio: crossAxisCount == 4 ? 1.05 : 1.35,
                          ),
                          itemCount: filteredResources.length,
                          itemBuilder: (context, index) {
                            final res = filteredResources[index];
                            return _buildResourceCard(
                              t: t,
                              icon: _getResourceIcon(res['icon']!),
                              title: res['title']!,
                              subtitle: res['subtitle']!,
                              iconColor: _getResourceColor(res['icon']!),
                              onTap: () => _launchURL(res['url']!),
                            );
                          },
                        );
                      },
                    ),
                  ],

                  // COMMON QUESTIONS SECTION
                  if (filteredFaqs.isNotEmpty) ...[
                    _sectionLabel(t, "Common questions"),
                    RoleCard(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Column(
                        children: List.generate(filteredFaqs.length, (index) {
                          final faq = filteredFaqs[index];
                          final isExpanded = _expandedFaqIndices.contains(index);
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              InkWell(
                                onTap: () {
                                  setState(() {
                                    if (isExpanded) {
                                      _expandedFaqIndices.remove(index);
                                    } else {
                                      _expandedFaqIndices.add(index);
                                    }
                                  });
                                },
                                borderRadius: BorderRadius.circular(8),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.help_outline_rounded,
                                        color: t.accent,
                                        size: 18,
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Text(
                                          faq['question']!,
                                          style: TextStyle(
                                            color: t.textPrimary,
                                            fontSize: 14,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      Icon(
                                        isExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                                        color: t.textTertiary,
                                        size: 20,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              AnimatedCrossFade(
                                firstChild: const SizedBox.shrink(),
                                secondChild: Padding(
                                  padding: const EdgeInsets.fromLTRB(38, 0, 16, 14),
                                  child: Text(
                                    faq['answer']!,
                                    style: TextStyle(
                                      color: t.textSecondary,
                                      fontSize: 13,
                                      height: 1.5,
                                    ),
                                  ),
                                ),
                                crossFadeState: isExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                                duration: const Duration(milliseconds: 200),
                              ),
                              if (index < filteredFaqs.length - 1) _divider(t),
                            ],
                          );
                        }),
                      ),
                    ),
                  ],

                  // EMPTY STATE
                  if (filteredFaqs.isEmpty && filteredResources.isEmpty) ...[
                    const SizedBox(height: 24),
                    Center(
                      child: Column(
                        children: [
                          const GEmptyIllustration(
                            GEmptyIllustrationKind.search,
                            size: 140,
                            fallbackIcon: Icons.search_off_rounded,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            "No results found",
                            style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            "We couldn't find anything matching your search query.",
                            style: TextStyle(color: t.textTertiary, fontSize: 13),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),

                  // REPORT A BUG CARD
                  _sectionLabel(t, "Report a bug"),
                  RoleCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: context.adapt(SoftPalette.pink550).withValues(alpha: 0.1),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(Icons.bug_report_outlined, color: context.adapt(SoftPalette.pink550), size: 20),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    "Report a bug",
                                    style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 15),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    "Describe what happened and we'll look into it. Include steps to reproduce if possible.",
                                    style: TextStyle(color: t.textTertiary, fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _bugController,
                          maxLines: 4,
                          style: TextStyle(color: t.textPrimary),
                          decoration: roleInputDecoration(
                            context,
                            label: "e.g. App crashed when I tapped Sync after adding a new patient...",
                            icon: Icons.edit_note_rounded,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                "Attached logs will be included automatically",
                                style: TextStyle(color: t.textTertiary, fontSize: 11),
                              ),
                            ),
                            const SizedBox(width: 12),
                            ElevatedButton(
                              onPressed: _submittingBug ? null : () => _submitBugReport(context, t),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: SoftPalette.pink550,
                                foregroundColor: SoftPalette.gray50,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              ),
                              child: _submittingBug
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: SoftPalette.gray50),
                                    )
                                  : const Text("Send report"),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 36),

                  // FOOTER
                  Center(
                    child: Text(
                      "GMWF Platform · v${AutoUpdateService.resolvedVersion}",
                      style: TextStyle(color: t.textTertiary, fontSize: 11, fontWeight: FontWeight.w500),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
