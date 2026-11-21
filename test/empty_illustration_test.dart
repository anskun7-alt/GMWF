import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gmwf/design/components/app_empty_state.dart' as app_ds;
import 'package:gmwf_ui/gmwf_ui.dart';

void main() {
  group('GEmptyIllustration assets & inference', () {
    test('every GEmptyIllustrationKind PNG exists in gmwf_ui/assets/illustrations', () {
      for (final kind in GEmptyIllustrationKind.values) {
        final file = File('../gmwf_ui/${kind.asset}');
        expect(
          file.existsSync(),
          isTrue,
          reason: 'Missing bundled illustration asset: ${file.path}',
        );
        expect(
          file.lengthSync(),
          greaterThan(10 * 1024),
          reason: 'Asset looks unexpectedly tiny/corrupt: ${file.path}',
        );
      }
    });

    test('GEmptyIllustrationKind.infer routes domain screens accurately', () {
      expect(
        GEmptyIllustrationKind.infer(title: 'No pending edit requests'),
        GEmptyIllustrationKind.requests,
      );
      expect(
        GEmptyIllustrationKind.infer(title: 'No approved edit requests'),
        GEmptyIllustrationKind.requests,
      );
      expect(
        GEmptyIllustrationKind.infer(
          title: 'No activity yet.\nStock updates will appear here.',
          icon: Icons.history_edu_rounded,
        ),
        GEmptyIllustrationKind.activity,
      );
      expect(
        GEmptyIllustrationKind.infer(title: 'No Medicines in Saddar Stock'),
        GEmptyIllustrationKind.inventory,
      );
      expect(
        GEmptyIllustrationKind.infer(
          title: 'Nothing matches',
          icon: GIcons.searchOff,
        ),
        GEmptyIllustrationKind.search,
      );
      expect(
        GEmptyIllustrationKind.infer(title: 'No notifications yet'),
        GEmptyIllustrationKind.notifications,
      );
      expect(
        GEmptyIllustrationKind.infer(title: 'No Donations Recorded'),
        GEmptyIllustrationKind.finance,
      );
      expect(
        GEmptyIllustrationKind.infer(title: 'No books yet', icon: GIcons.book),
        GEmptyIllustrationKind.education,
      );
      expect(
        GEmptyIllustrationKind.infer(title: 'No patients in queue'),
        GEmptyIllustrationKind.people,
      );
      expect(
        GEmptyIllustrationKind.infer(title: 'No food logs found for this date'),
        GEmptyIllustrationKind.kitchen,
      );
      expect(
        GEmptyIllustrationKind.infer(title: 'Select a branch to continue'),
        GEmptyIllustrationKind.general,
      );
    });
  });

  group('Empty state widgets render illustrations cleanly in light & dark themes', () {
    testWidgets('gmwf_ui AppEmptyState renders GEmptyIllustration without overflow',
        (tester) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: GTheme.build(brightness: brightness),
            home: const Scaffold(
              body: AppEmptyState(
                icon: Icons.pending_actions_rounded,
                title: 'No pending edit requests',
                subtitle: 'New edit requests will appear here.',
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.byType(GEmptyIllustration), findsOneWidget);
        expect(find.text('No pending edit requests'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('gmwf design system AppEmptyState renders GEmptyIllustration cleanly',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: GTheme.build(brightness: Brightness.light),
          home: const Scaffold(
            body: app_ds.AppEmptyState(
              icon: Icons.history_edu_rounded,
              title: 'No activity yet',
              subtitle: 'Stock updates will appear here.',
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(GEmptyIllustration), findsOneWidget);
      expect(find.text('No activity yet'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
