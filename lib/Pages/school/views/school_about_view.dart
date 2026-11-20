// lib/pages/school/views/school_about_view.dart
//
// About Taleem o Tarbiyat School System (Phase 6: migrated to gmwf_ui tokens,
// GLogo, GText and GIcons).

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';

import '../../../services/local_storage_service.dart';
import '../widgets/erp/school_erp.dart';

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
    final c = context.comfort;
    final mobile = GBreakpoint.isMobile(context);
    final campus = branchName ?? LocalStorageService.getBranchName(branchId);

    final features = const [
      (GIcons.attendance, 'Daily log & PTM', 'Six-rule daily tracking, holidays, PTM and bimonthly events'),
      (GIcons.library, 'Library inventory', 'Catalogue, covers, loans, members and overdue tracking'),
      (GIcons.exam, 'Grades & reports', 'Class marks entry, exam attachments and printable report cards'),
      (GIcons.fees, 'Deduction fee engine', 'Per-month config, month close, append-only payments and receipts'),
      (GIcons.sync, 'Offline-first sync', 'Instant local Hive saves with LAN & Firestore conflict merging'),
      (GIcons.audit, 'Audit trail', 'Role-gated operations with before/after change history'),
    ];

    return SingleChildScrollView(
      padding: EdgeInsets.all(mobile ? Gsp.sp4 : Gsp.sp6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header banner
          Container(
            padding: EdgeInsets.all(mobile ? Gsp.sp4 : Gsp.sp6),
            decoration: BoxDecoration(
              color: c.brand,
              borderRadius: Gr.card,
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  padding: const EdgeInsets.all(Gsp.sp1),
                  decoration: BoxDecoration(color: c.surface, borderRadius: Gr.button),
                  child: const GLogo(GBrand.gmwf, size: 42),
                ),
                const SizedBox(width: Gsp.sp3),
                Container(
                  width: 50,
                  height: 50,
                  padding: const EdgeInsets.all(Gsp.sp1),
                  decoration: BoxDecoration(color: c.surface, borderRadius: Gr.button),
                  child: Image.asset(
                    'assets/logo/twt.webp',
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => Icon(GIcons.student, color: c.brand),
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3, vertical: Gsp.sp1),
                  decoration: BoxDecoration(
                    color: c.onBrand.withValues(alpha: 0.14),
                    borderRadius: Gr.chip,
                  ),
                  child: Text('GMWF Project', style: GText.label(c.onBrand)),
                ),
              ]),
              const SizedBox(height: Gsp.sp4),
              Text('Taleem o Tarbiyat School System', style: GText.h2(c.onBrand)),
              const SizedBox(height: Gsp.sp1),
              Text(
                'An educational initiative of Gulzar Madina Welfare Foundation',
                style: GText.body2(c.onBrand.withValues(alpha: 0.88)),
              ),
              const SizedBox(height: Gsp.sp3),
              Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(GIcons.location, color: c.onBrand.withValues(alpha: 0.9), size: GIconSize.sm),
                const SizedBox(width: Gsp.sp2),
                Text('Campus branch: $campus', style: GText.label(c.onBrand)),
              ]),
            ]),
          ),
          const SizedBox(height: Gsp.sp5),

          // Vision & Mission
          Text('About the institution', style: GText.h3(c.textPrimary)),
          const SizedBox(height: Gsp.sp3),
          LayoutBuilder(builder: (context, box) {
            final cards = [
              _AboutCard(
                title: 'Our vision',
                icon: GIcons.visibility,
                color: c.brand,
                body: 'To foster academic excellence, Islamic values, and moral discipline (Tarbiyat) in every student through an inclusive environment backed by welfare support.',
              ),
              _AboutCard(
                title: 'Our mission',
                icon: GIcons.star,
                color: c.accentStrong,
                body: 'Delivering holistic education with reliable campus digitization, parent cooperation through the fee-deduction programme, and well-equipped school libraries.',
              ),
            ];
            if (box.maxWidth < 720) {
              return Column(children: [cards[0], const SizedBox(height: Gsp.sp3), cards[1]]);
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: cards[0]),
                const SizedBox(width: Gsp.sp4),
                Expanded(child: cards[1]),
              ],
            );
          }),
          const SizedBox(height: Gsp.sp5),

          // Modules
          Text('Integrated ERP modules', style: GText.h3(c.textPrimary)),
          const SizedBox(height: Gsp.sp3),
          Wrap(
            spacing: Gsp.sp3,
            runSpacing: Gsp.sp3,
            children: [
              for (final f in features)
                Container(
                  width: mobile ? double.infinity : 290,
                  padding: const EdgeInsets.all(Gsp.sp4),
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: SchoolErp.radius,
                    border: Border.all(color: c.border),
                  ),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    GModuleTile(icon: f.$1, size: 36),
                    const SizedBox(width: Gsp.sp3),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(f.$2, style: GText.body2Bold(c.textPrimary)),
                        const SizedBox(height: 2),
                        Text(f.$3, style: GText.caption(c.textMuted)),
                      ]),
                    ),
                  ]),
                ),
            ],
          ),
          const SizedBox(height: Gsp.sp5),

          // Governance notice
          Container(
            padding: const EdgeInsets.all(Gsp.sp4),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: SchoolErp.radius,
              border: Border.all(color: c.border),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(GIcons.shield, color: c.brand, size: GIconSize.sm),
                const SizedBox(width: Gsp.sp2),
                Text('Data governance & ownership', style: GText.body1Bold(c.textPrimary)),
              ]),
              const SizedBox(height: Gsp.sp2),
              Text(
                'Taleem o Tarbiyat School System is managed and supported by Gulzar Madina Welfare Foundation (GMWF). '
                'Student, attendance, examination, library and fee records are governed under GMWF IT policies.\n'
                '© ${DateTime.now().year} Gulzar Madina Welfare Foundation. All rights reserved.',
                style: GText.caption(c.textSecondary),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

class _AboutCard extends StatelessWidget {
  const _AboutCard({required this.title, required this.icon, required this.color, required this.body});
  final String title;
  final IconData icon;
  final Color color;
  final String body;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    return Container(
      padding: const EdgeInsets.all(Gsp.sp4),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: SchoolErp.radius,
        border: Border.all(color: c.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.all(Gsp.sp2),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: Gr.button),
            child: Icon(icon, color: color, size: GIconSize.sm),
          ),
          const SizedBox(width: Gsp.sp2 + 2),
          Text(title, style: GText.body1Bold(c.textPrimary)),
        ]),
        const SizedBox(height: Gsp.sp2 + 2),
        Text(body, style: GText.body2(c.textSecondary)),
      ]),
    );
  }
}
