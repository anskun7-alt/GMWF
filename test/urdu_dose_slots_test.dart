import 'package:flutter_test/flutter_test.dart';
import 'package:gmwf/pages/dispensary/dispensar/patient_form_helper.dart';

/// The doctor's timing box is "Morning+Evening+Night"; the patient's Urdu line must say the same.
void main() {
  String urdu(String timing) =>
      PatientFormHelper.buildUrduDosageLine({'name': 'Tab. X', 'type': 'Tablet', 'timing': timing});

  test('3 slots read morning / evening / night', () {
    expect(urdu('1+0+0'), '1 گولی صبح');
    expect(urdu('0+1+0'), '1 گولی شام');
    expect(urdu('0+0+1'), '1 گولی رات');
    expect(urdu('1+0+1'), '1 گولی صبح - 1 گولی رات');
    expect(urdu('1+1+1'), '1 گولی صبح - 1 گولی شام - 1 گولی رات');
  });

  test('four doses a day show all four on the slip', () {
    final four = PatientFormHelper.resolveCanonicalTiming('4').timing;
    expect(four, '1+1+1+1');
    expect(urdu(four), '1 گولی صبح - 1 گولی دوپہر - 1 گولی شام - 1 گولی رات');
  });
}
