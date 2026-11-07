import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'dart:io';

import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/utils/token_order.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('gmwf_token_test_');
    Hive.init(tempDir.path);
    await Hive.openBox('app_settings');
    await Hive.openBox(LocalStorageService.entriesBox);
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  setUp(() async {
    await Hive.box('app_settings').clear();
    await Hive.box(LocalStorageService.entriesBox).clear();
  });

  group('Token Numbering Criteria (Strictly 001 to 999 for Both Online and Offline)', () {
    test('Offline generation strictly produces sequence 001..999 without 1000+ or 2000+ bands', () async {
      final dateKey = '071126';
      final branchId = 'karachi';
      final dispensaryId = 'haji_camp';
      final session = 'evening';

      // 1. Issue first token offline
      final seq1 = await LocalStorageService.getNextLocalSerialSequence(
        branchId,
        dateKey,
        dispensaryId: dispensaryId,
        session: session,
        increment: true,
      );
      expect(seq1, 1);
      final serial1 = '071126E-HAJI-${seq1.toString().padLeft(3, '0')}';
      expect(serial1, '071126E-HAJI-001');

      await LocalStorageService.saveEntryLocal(branchId, serial1, {
        'serial': serial1,
        'dateKey': dateKey,
        'session': session,
        'dispensaryTag': 'HAJI',
        'status': 'waiting',
      });

      // 2. Issue second token offline
      final seq2 = await LocalStorageService.getNextLocalSerialSequence(
        branchId,
        dateKey,
        dispensaryId: dispensaryId,
        session: session,
        increment: true,
      );
      expect(seq2, 2);
      final serial2 = '071126E-HAJI-${seq2.toString().padLeft(3, '0')}';
      expect(serial2, '071126E-HAJI-002');

      // 3. Issue third token offline
      final seq3 = await LocalStorageService.getNextLocalSerialSequence(
        branchId,
        dateKey,
        dispensaryId: dispensaryId,
        session: session,
        increment: true,
      );
      expect(seq3, 3);
      final serial3 = '071126E-HAJI-${seq3.toString().padLeft(3, '0')}';
      expect(serial3, '071126E-HAJI-003');

      // Verify isOfflineBandSeq returns false for all tokens
      expect(LocalStorageService.isOfflineBandSeq(seq1), false);
      expect(LocalStorageService.isOfflineBandSeq(seq2), false);
      expect(LocalStorageService.isOfflineBandSeq(seq3), false);
      expect(LocalStorageService.isOfflineBandSeq(2001), false);
    });

    test('Tokens stay bounded within 999 even if past 999 attempts', () async {
      final dateKey = '071126';
      final branchId = 'karachi';
      final dispensaryId = 'haji_camp';
      final session = 'evening';

      final seq = await LocalStorageService.getNextLocalSerialSequence(
        branchId,
        dateKey,
        dispensaryId: dispensaryId,
        session: session,
        atLeast: 1005,
        increment: true,
      );
      expect(seq, lessThanOrEqualTo(999));
    });

    test('Legacy 1000+ or 2000+ tokens are cleanly normalized to 001..999 display', () {
      expect(LocalStorageService.formatCanonicalSerialForDisplay('071126E-HAJI-2003'), '071126E-HAJI-003');
      expect(LocalStorageService.formatCanonicalSerialForDisplay('071126E-HAJI-2001'), '071126E-HAJI-001');
      expect(LocalStorageService.formatCanonicalSerialForDisplay('071126E-HAJI-1005'), '071126E-HAJI-005');
      expect(LocalStorageService.formatCanonicalSerialForDisplay('071126E-HAJI-042'), '071126E-HAJI-042');

      expect(LocalStorageService.formatTokenDisplay('071126E-HAJI-2003'), '003');
      expect(LocalStorageService.formatTokenDisplay('071126E-HAJI-2001'), '001');
      expect(LocalStorageService.formatTokenDisplay('071126E-HAJI-1005'), '005');
      expect(LocalStorageService.formatTokenDisplay('071126E-HAJI-042'), '042');
    });

    test('UDP discovery branch matching recognizes Haji Camp as Karachi branch', () {
      expect(CampSessionService.areBranchesMatching('haji_camp', 'karachi'), true);
      expect(CampSessionService.areBranchesMatching('haji', 'karachi'), true);
      expect(CampSessionService.areBranchesMatching('saddar', 'karachi'), true);
      expect(CampSessionService.areBranchesMatching('kapayya', 'karachi'), true);
      expect(CampSessionService.areBranchesMatching('gujrat', 'gujrat'), true);
      expect(CampSessionService.areBranchesMatching('lahore', 'karachi'), false);
    });
  });
}

