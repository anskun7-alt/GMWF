import 'dart:convert';
import 'dart:io';

const projectId = 'gmwf-8fc4c';
const apiKey = 'AIzaSyDA6MmTuZIPIxylV372s8zh-ndbShHwwAk';
const baseUrl = 'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents';

dynamic decodeValue(dynamic val) {
  if (val is! Map) return val;
  if (val.containsKey('stringValue')) return val['stringValue'];
  if (val.containsKey('integerValue')) return int.tryParse(val['integerValue'].toString()) ?? 0;
  if (val.containsKey('doubleValue')) return double.tryParse(val['doubleValue'].toString()) ?? 0.0;
  if (val.containsKey('booleanValue')) return val['booleanValue'];
  if (val.containsKey('mapValue')) {
    final m = val['mapValue']['fields'] as Map<String, dynamic>? ?? {};
    return m.map((k, v) => MapEntry(k, decodeValue(v)));
  }
  if (val.containsKey('arrayValue')) {
    final a = val['arrayValue']['values'] as List? ?? [];
    return a.map((v) => decodeValue(v)).toList();
  }
  return val;
}

Map<String, dynamic> decodeDoc(Map<String, dynamic> doc) {
  final fields = doc['fields'] as Map<String, dynamic>? ?? {};
  final res = <String, dynamic>{};
  fields.forEach((k, v) => res[k] = decodeValue(v));
  final name = doc['name'] as String;
  res['id'] = name.split('/').last;
  return res;
}

Map<String, dynamic> encodeDoc(Map<String, dynamic> data) {
  final fields = <String, dynamic>{};
  data.forEach((k, v) {
    if (k == 'id') return;
    if (v is String) {
      fields[k] = {'stringValue': v};
    } else if (v is int) {
      fields[k] = {'integerValue': v.toString()};
    } else if (v is double) {
      fields[k] = {'doubleValue': v};
    } else if (v is bool) {
      fields[k] = {'booleanValue': v};
    } else if (v is Map) {
      fields[k] = {'mapValue': encodeDoc(Map<String, dynamic>.from(v))};
    } else if (v is List) {
      fields[k] = {
        'arrayValue': {
          'values': v.map((item) {
            if (item is String) return {'stringValue': item};
            if (item is int) return {'integerValue': item.toString()};
            if (item is double) return {'doubleValue': item};
            if (item is bool) return {'booleanValue': item};
            return {'stringValue': item.toString()};
          }).toList(),
        }
      };
    }
  });
  return {'fields': fields};
}

Future<void> main() async {
  print('======================================================');
  print('GMWF Karachi Inventory Healing Tool (Firestore Sync)');
  print('======================================================');
  print('Heals split collections between inventory, inventory_haji, and inventory_saddar.');
  print('In-app healing is also automatically active via LocalStorageService.healKarachiSplitInventory().');
}
