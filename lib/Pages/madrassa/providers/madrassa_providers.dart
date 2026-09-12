import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:collection/collection.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../utils/madrassa_local_storage.dart';
import '../../../services/local_storage_service.dart';
import '../models/madrassa_config.dart';

// Selected Date Provider for the daily log (keyed by branchId)
final madrassaSelectedDateProvider = StateProvider.family<DateTime, String>((ref, branchId) => DateTime.now());

// Config Stream Provider (from Hive local storage)
final madrassaConfigProvider = StreamProvider.family<MadrassaConfig, String>((ref, branchId) {
  return MadrassaLocalStorage.streamConfigCached(branchId);
});

// Students List Stream Provider (from Hive local storage)
final madrassaStudentsProvider = StreamProvider.family<List<Map<String, dynamic>>, String>((ref, branchId) {
  return MadrassaLocalStorage.streamStudentsCached(branchId);
});

// Holidays List Stream Provider (from Hive local storage)
final madrassaHolidaysProvider = StreamProvider.family<List<Map<String, dynamic>>, String>((ref, branchId) {
  return MadrassaLocalStorage.streamHolidaysCached(branchId);
});

// Daily Log Stream Provider (from Hive local storage)
final madrassaDailyLogProvider = StreamProvider.family<Map<String, dynamic>, ({String branchId, String dateKey})>((ref, arg) {
  return MadrassaLocalStorage.streamLogCached(arg.branchId, arg.dateKey);
});

// Monthly Logs Stream Provider (from Hive local storage)
final madrassaMonthlyLogsProvider = StreamProvider.family<List<Map<String, dynamic>>, ({String branchId, int year, int month})>((ref, arg) {
  return MadrassaLocalStorage.streamLogsForMonthCached(arg.branchId, arg.year, arg.month);
});

// Monthly Fee Payments Stream Provider (from Hive local storage)
final madrassaFeePaymentsProvider = StreamProvider.family<Map<String, Map<String, dynamic>>, ({String branchId, int year, int month})>((ref, arg) {
  return MadrassaLocalStorage.streamFeePaymentsForMonthCached(arg.branchId, arg.year, arg.month);
});

// Filtered Students Provider for Daily Attendance Log (combines students roster, selected date, and log maps reactively)
final madrassaFilteredStudentsProvider = Provider.family<AsyncValue<List<Map<String, dynamic>>>, ({String branchId, DateTime selectedDate})>((ref, arg) {
  final studentsAsync = ref.watch(madrassaStudentsProvider(arg.branchId));
  final dateKey = DateFormat('yyyy-MM-dd').format(arg.selectedDate);
  final logAsync = ref.watch(madrassaDailyLogProvider((branchId: arg.branchId, dateKey: dateKey)));

  return studentsAsync.when(
    loading: () => const AsyncValue.loading(),
    error: (e, st) => AsyncValue.error(e, st),
    data: (allStudents) {
      return logAsync.when(
        loading: () => const AsyncValue.loading(),
        error: (e, st) => AsyncValue.error(e, st),
        data: (activeLogData) {
          final endOfSelected = DateTime(
            arg.selectedDate.year,
            arg.selectedDate.month,
            arg.selectedDate.day,
            23, 59, 59, 999,
          );
          
          final filtered = allStudents.where((d) {
            final statusVal = (d['status'] ?? (d['active'] == true ? 'active' : 'inactive')).toString().toLowerCase().trim();

            final isInactiveOrDropped = statusVal == 'dropped' ||
                statusVal == 'dropped_out' ||
                statusVal == 'left' ||
                statusVal == 'archived' ||
                statusVal == 'inactive' ||
                statusVal == 'hifz_completed' ||
                statusVal == 'hifz_complete';

            if (statusVal == 'active') {
              final joinDateVal = d['joinDate'];
              DateTime? joinDateTime;
              if (joinDateVal is String) {
                joinDateTime = DateTime.tryParse(joinDateVal);
              } else if (joinDateVal is Timestamp) {
                joinDateTime = joinDateVal.toDate();
              }
              if (joinDateTime != null) {
                return !joinDateTime.isAfter(endOfSelected);
              }
              return true;
            }

            if (isInactiveOrDropped) {
              DateTime? statusChangeDate;
              final dynamic dateField = d['leftDate'] ?? d['droppedDate'] ?? d['archivedDate'] ?? d['hifzCompletedDate'];
              if (dateField is Timestamp) {
                statusChangeDate = dateField.toDate();
              } else if (dateField is String) {
                statusChangeDate = DateTime.tryParse(dateField);
              }

              final startOfSelected = DateTime(arg.selectedDate.year, arg.selectedDate.month, arg.selectedDate.day);

              if (statusChangeDate != null) {
                final statusDay = DateTime(statusChangeDate.year, statusChangeDate.month, statusChangeDate.day);
                // Included ONLY for past dates strictly before the status change date
                return startOfSelected.isBefore(statusDay);
              }
              // If no status change date recorded, do NOT show dropped/left student in daily log
              return false;
            }

            return false;
          }).toList();

          filtered.sort((a, b) {
            final aVal = int.tryParse(a['rollNumber']?.toString() ?? '') ?? 999999;
            final bVal = int.tryParse(b['rollNumber']?.toString() ?? '') ?? 999999;
            return aVal.compareTo(bVal);
          });

          return AsyncValue.data(filtered);
        },
      );
    },
  );
});

// All Logs Stream Provider
final madrassaAllLogsProvider = StreamProvider.family<List<Map<String, dynamic>>, String>((ref, branchId) {
  final Stream<List<Map<String, dynamic>>> hiveSource = () async* {
    final box = await LocalStorageService.ensureBoxOpen(MadrassaLocalStorage.logsBox);
    yield MadrassaLocalStorage.getAllLogsCached(branchId);
    final prefix = '${branchId.toLowerCase().trim()}__log__';
    await for (final event in box.watch()) {
      final key = event.key?.toString() ?? '';
      if (key.isEmpty || key.startsWith(prefix)) {
        yield MadrassaLocalStorage.getAllLogsCached(branchId);
      }
    }
  }();
  return hiveSource.distinct((a, b) => const DeepCollectionEquality().equals(a, b));
});
