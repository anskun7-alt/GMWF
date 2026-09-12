import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../services/donations_local_storage.dart';
import '../../models/donation_models.dart';
import 'package:flutter/foundation.dart'; // for kIsWeb
import 'dart:async';
import 'package:hive_flutter/hive_flutter.dart';




// ─────────────────────────────────────────────────────────────────────────────
// Config passed into the provider so it knows which branch/collection to load.
// ─────────────────────────────────────────────────────────────────────────────
class DonationFetchConfig {
  final String branchId; // 'all' → collectionGroup, otherwise branch sub-collection
  final int pageSize;
  const DonationFetchConfig({required this.branchId, this.pageSize = 50});

  @override
  bool operator ==(Object other) =>
      other is DonationFetchConfig && other.branchId == branchId && other.pageSize == pageSize;

  @override
  int get hashCode => Object.hash(branchId, pageSize);
}

// ─────────────────────────────────────────────────────────────────────────────
// Provider family — keyed by DonationFetchConfig
// ─────────────────────────────────────────────────────────────────────────────

  // Default: all branches. The dashboard overrides this by calling .family or
  // by calling reset() after mounting.
final donationPaginationProvider = StateNotifierProvider<DonationPaginationNotifier, AsyncValue<List<DonationRecord>>>((ref) {
  return DonationPaginationNotifier(branchId: 'all');
});

// Provider family for specific branch configurations
final donationPaginationFamily = StateNotifierProvider.family<DonationPaginationNotifier, AsyncValue<List<DonationRecord>>, DonationFetchConfig>((ref, config) => DonationPaginationNotifier(branchId: config.branchId));



// ─────────────────────────────────────────────────────────────────────────────
// Notifier
// ─────────────────────────────────────────────────────────────────────────────
class DonationPaginationNotifier
    extends StateNotifier<AsyncValue<List<DonationRecord>>> {
  final String branchId;
  final int _pageSize = kIsWeb ? 10000 : 50;

  DocumentSnapshot? _lastDocument;
  bool _hasMore = true;
  bool _loading = false;

  StreamSubscription? _hiveSubscription;

  DonationPaginationNotifier({required this.branchId})
      : super(const AsyncValue.loading()) {
    // Load only the first page on init — local Hive cache shows immediately and
    // subsequent pages load on scroll. Loading all pages on every boot is a
    // major Firestore read quota burner.
    _loadFirstPage();
    _listenToHive();
  }

  void _listenToHive() {
    _hiveSubscription?.cancel();
    _hiveSubscription = Hive.box(DonationsLocalStorage.donationsBox).watch().listen((event) {
      if (!mounted) return;
      final local = DonationsLocalStorage.getAllDonations(branchId);
      final currentData = state.valueOrNull ?? [];
      final merged = _dedup(currentData, local);
      state = AsyncValue.data(merged);
    });
  }

  @override
  void dispose() {
    _hiveSubscription?.cancel();
    super.dispose();
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  Query<Map<String, dynamic>> _baseQuery() {
    if (branchId == 'all' || branchId.isEmpty) {
      return FirebaseFirestore.instance
          .collectionGroup('donations')
          .orderBy('date', descending: true);
    }
    return FirebaseFirestore.instance
        .collection('branches')
        .doc(branchId)
        .collection('donations')
        .orderBy('date', descending: true);
  }

  Future<void> _loadFirstPage() async {
    state = const AsyncValue.loading();
    _lastDocument = null;
    _hasMore = true;

    // Show local cached data immediately for a snappy feel
    final local = DonationsLocalStorage.getAllDonations(branchId);
    if (local.isNotEmpty && mounted) {
      state = AsyncValue.data(_dedup([], local));
    }

    // Load only the first page; caller can decide to load more.
    await _fetchPage(replace: true);
  }

  // Load all pages sequentially — call explicitly (e.g. from a force-refresh action)
  // but NOT from the constructor to avoid burning Firestore quota on every app start.
  Future<void> loadAllPages() async {
    debugPrint('[DonPagination] _loadAllPages START (branchId=$branchId, pageSize=$_pageSize)');
    await _loadFirstPage();
    int pageNum = 1;
    // Continue fetching while more pages exist.
    while (_hasMore && mounted) {
      pageNum++;
      debugPrint('[DonPagination] _loadAllPages fetching page $pageNum ...');
      await _fetchPage(replace: false);
    }
    final total = state.whenOrNull(data: (list) => list.length) ?? 0;
    debugPrint('[DonPagination] _loadAllPages DONE — total records: $total');
  }

  Future<void> _fetchPage({bool replace = false}) async {
    if (_loading || !_hasMore) return;
    _loading = true;

    try {
      var query = _baseQuery().limit(_pageSize);
      if (_lastDocument != null) {
        query = query.startAfterDocument(_lastDocument!);
      }

      final snapshot = await query.get();

      if (!mounted) return;

      if (snapshot.docs.isEmpty) {
        _hasMore = false;
        _loading = false;
        debugPrint('[DonPagination] Firestore returned empty (branchId=$branchId). Keeping local data.');
        // When Firestore is empty, keep showing local Hive data
        // This handles offline scenarios where donations are only in local cache
        if (state is AsyncLoading) {
          // Get the local data that was shown before
          final local = DonationsLocalStorage.getAllDonations(branchId);
          state = local.isEmpty ? const AsyncValue.data([]) : AsyncValue.data(local);
        }
        return;
      }

      _lastDocument = snapshot.docs.last;
      if (snapshot.docs.length < _pageSize) _hasMore = false;
      debugPrint('[DonPagination] _fetchPage got ${snapshot.docs.length} docs (hasMore=$_hasMore, replace=$replace)');

      final newDocs = snapshot.docs.map((doc) {
        final data = Map<String, dynamic>.from(doc.data());
        // Ensure branchId is populated for collectionGroup queries
        if ((data['branchId'] == null || data['branchId'].toString().isEmpty) &&
            branchId != 'all') {
          data['branchId'] = branchId;
        } else if (data['branchId'] == null || data['branchId'].toString().isEmpty) {
          data['branchId'] = doc.reference.parent.parent?.id ?? '';
        }
        return DonationRecord.fromMap(data, doc.id);
      }).toList();

      final existing = state.whenOrNull(data: (list) => list) ?? [];
      final merged = replace ? _dedup([], newDocs) : _dedup(existing, newDocs);

      state = AsyncValue.data(merged);
    } catch (e, st) {
      if (mounted) state = AsyncValue.error(e, st);
    } finally {
      _loading = false;
    }
  }

  /// Merge [existing] with [incoming], cloud wins on conflict, then sort by date desc.
  List<DonationRecord> _dedup(
      List<DonationRecord> existing, List<DonationRecord> incoming) {
    final map = <String, DonationRecord>{};
    for (final d in existing) {
      map['${d.branchId}_${d.localId}'] = d;
    }
    for (final d in incoming) {
      final key = '${d.branchId}_${d.localId}';
      final current = map[key];
      if (current == null) {
        map[key] = d;
      } else {
        // Prefer whichever has the newer lastUpdatedAt timestamp
        final tNew = _ts(d);
        final tExisting = _ts(current);
        if (!tNew.isBefore(tExisting)) map[key] = d;
      }
    }
    final result = map.values.where((d) => d.syncStatus != 'deleted').toList();
    result.sort((a, b) {
      final c = b.date.compareTo(a.date);
      return c != 0 ? c : b.localId.compareTo(a.localId);
    });
    return result;
  }

  DateTime _ts(DonationRecord r) {
    final raw = r.lastUpdatedAt ?? r.timestamp;
    if (raw != null) {
      final parsed = DateTime.tryParse(raw);
      if (parsed != null) return parsed;
    }
    final ms = int.tryParse(r.localId);
    if (ms != null && ms > 1000000000000) {
      return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Load the next page (called on scroll-near-bottom).
  Future<void> fetchNextPage() => _fetchPage();

  /// Full reset — re-fetch from scratch (used when filters change).
  Future<void> reset() => _loadFirstPage();

  bool get hasMore => _hasMore;
}
