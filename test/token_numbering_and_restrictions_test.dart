import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:hive/hive.dart';

/// Offline token blocks (desk slot N issues N*1000+1 ...) and the no-CNIC restriction fallback.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('gmwf_numbering_');
    Hive.init(dir.path);
    await Hive.openBox(LocalStorageService.entriesBox);
    await Hive.openBox('app_settings');
    await Hive.openBox('app_flags');
    await Hive.openBox(LocalStorageService.medicineRestrictionsBox);
  });

  tearDown(() async {
    await Hive.close();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  // ── Token numbering ──────────────────────────────────────────────────────
  group('token numbering', () {
    const branch = 'gujrat';
    const dateKey = '051126';

    Future<void> addToken(int seq) async {
      final s = '${dateKey}M-GUJ-${seq.toString().padLeft(3, '0')}';
      await Hive.box(LocalStorageService.entriesBox).put('$branch-$s', {
        'serial': s,
        'branchId': branch,
        'dateKey': dateKey,
        'session': 'morning',
        'dispensaryId': branch,
        'patientName': 'P$seq',
        'status': 'waiting',
      });
    }

    Future<int> next({int slot = 0, bool increment = false, int atLeast = 0}) =>
        LocalStorageService.getNextLocalSerialSequence(branch, dateKey,
            dispensaryId: branch,
            session: 'morning',
            offlineSlot: slot,
            increment: increment,
            atLeast: atLeast);

    test('shared sequence ignores offline-block tokens', () async {
      for (final s in [1, 2, 3, 1001, 1002, 2001]) {
        await addToken(s);
      }
      expect(await next(), 4);
    });

    test('each offline block continues only its own numbers', skip: 'Offline desk blocks removed: one shared 001..999 sequence (see getNextLocalSerialSequence)', () async {
      for (final s in [1, 2, 3, 1001, 1002, 2001]) {
        await addToken(s);
      }
      expect(await next(slot: 1), 1003);
      expect(await next(slot: 2), 2002);
      expect(await next(slot: 3), 3001);
    });

    test('two offline desks never produce the same number', skip: 'Offline desk blocks removed: one shared 001..999 sequence (see getNextLocalSerialSequence)', () async {
      final a = <int>{}, b = <int>{};
      for (var i = 0; i < 20; i++) {
        final na = await next(slot: 1, increment: true);
        await addToken(na);
        a.add(na);
        final nb = await next(slot: 2, increment: true);
        await addToken(nb);
        b.add(nb);
      }
      expect(a.length, 20);
      expect(b.length, 20);
      expect(a.intersection(b), isEmpty);
      expect(a.every((n) => n > 1000 && n < 2000), isTrue);
      expect(b.every((n) => n > 2000 && n < 3000), isTrue);
    });

    test('server-issued number is respected and the shared counter continues after it', () async {
      await addToken(1);
      expect(await next(increment: true, atLeast: 7), 7);
      expect(await next(), 8);
    });

    String counterKey([String suffix = '']) =>
        'counter_${branch}_${dateKey}_M_${CampSessionService.getDispensaryKeyword(branch)}$suffix';

    test('a shared counter left at an out-of-band value by an old build is ignored', () async {
      await addToken(1);
      await addToken(2);
      await Hive.box('app_settings').put(counterKey(), 1005);
      expect(await next(), 3);
    });

    test('a full offline block keeps counting instead of repeating a number', skip: 'Offline desk blocks removed: one shared 001..999 sequence (see getNextLocalSerialSequence)', () async {
      await Hive.box('app_settings').put(counterKey('_off1'), 1999);
      expect(await next(slot: 1, increment: true), 2000);
      expect(await next(slot: 1, increment: true), 2001);
    });

    test('offline desk slot only accepts 1..9', () async {
      expect(LocalStorageService.offlineDeskSlot, 0);
      await LocalStorageService.setOfflineDeskSlot(0);
      await LocalStorageService.setOfflineDeskSlot(10);
      expect(LocalStorageService.offlineDeskSlot, 0);
      await LocalStorageService.setOfflineDeskSlot(4);
      expect(LocalStorageService.offlineDeskSlot, 4);
    });

    test('device key is stable for this PC', () {
      final k1 = LocalStorageService.deskDeviceKey;
      final k2 = LocalStorageService.deskDeviceKey;
      expect(k1, isNotEmpty);
      expect(k1, k2);
    });
  });

  // ── Restriction fallback for no-CNIC patients ────────────────────────────
  group('medicine restriction fallback', () {
    const branch = 'gujrat';
    const g = '3520112345671';
    final future = DateTime.now().add(const Duration(days: 3));
    final past = DateTime.now().subtract(const Duration(days: 2));

    Future<void> restrict(String patientId,
        {String? name, String? guardian, String? phone, DateTime? lastDay}) async {
      await Hive.box(LocalStorageService.medicineRestrictionsBox).put('${branch}_$patientId', {
        'patientId': patientId,
        'branchId': branch,
        'daysCovered': 5,
        'lastBlockedDay': (lastDay ?? future).toIso8601String(),
        if (name != null) 'patientName': name,
        if (guardian != null) 'guardianCnic': guardian,
        if (phone != null) 'phone': phone,
      });
    }

    Map<String, dynamic>? check(String id, Map<String, dynamic> patient) =>
        LocalStorageService.isPatientBlockedByMedicine(branch, id, patient);

    test('a sibling is NOT blocked by her brother\'s restriction', () async {
      await restrict('${g}_child_ali', name: 'Ali', guardian: g);
      expect(check('${g}_child_sara', {'name': 'Sara', 'guardianCnic': g, 'cnic': ''}), isNull);
    });

    test('the guardian\'s own restriction does not block the child', () async {
      await restrict(g, name: 'Ahmed', guardian: g);
      expect(check('${g}_child_ali', {'name': 'Ali', 'guardianCnic': g, 'cnic': ''}), isNull);
    });

    test('the same child under a different id spelling IS blocked', () async {
      await restrict('${g}_child_ali_raza', name: 'Ali Raza', guardian: g);
      final r = check('${g}_child_aliraza', {'name': 'ali  raza', 'guardianCnic': g, 'cnic': ''});
      expect(r, isNotNull);
      expect(r!['patientId'], '${g}_child_ali_raza');
    });

    test('a restriction without a name never matches another record', () async {
      await restrict('${g}_child_x', guardian: g); // name only from id: "x"
      expect(check('${g}_child_sara', {'name': 'Sara', 'guardianCnic': g, 'cnic': ''}), isNull);
    });

    test('partial names do not match (Ali vs Ali Raza)', () async {
      await restrict('${g}_child_ali', name: 'Ali', guardian: g);
      expect(check('${g}_child_aliraza', {'name': 'Ali Raza', 'guardianCnic': g, 'cnic': ''}), isNull);
    });

    test('family phone + same name matches; phone alone does not', () async {
      await restrict('p_old_id', name: 'Zainab', phone: '0300-1234567');
      expect(check('p_new_id', {'name': 'Zainab', 'phone': '03001234567'}), isNotNull);
      expect(check('p_other', {'name': 'Fatima', 'phone': '03001234567'}), isNull);
    });

    test('an adult with an own CNIC is matched exactly, not by family', () async {
      await restrict('${g}_child_ali', name: 'Ali', guardian: g);
      expect(check('4210198765431', {'name': 'Ali', 'guardianCnic': g, 'cnic': '4210198765431'}), isNull);
    });

    test('exact id match still blocks', () async {
      await restrict('4210198765431', name: 'Bilal');
      expect(check('4210198765431', {'name': 'Bilal', 'cnic': '4210198765431'}), isNotNull);
    });

    test('an expired restriction found by the fallback clears THAT record', () async {
      await restrict('${g}_child_ali_raza', name: 'Ali Raza', guardian: g, lastDay: past);
      expect(check('${g}_child_aliraza', {'name': 'Ali Raza', 'guardianCnic': g, 'cnic': ''}), isNull);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(Hive.box(LocalStorageService.medicineRestrictionsBox).containsKey('${branch}_${g}_child_ali_raza'),
          isFalse);
    });
  });
}
