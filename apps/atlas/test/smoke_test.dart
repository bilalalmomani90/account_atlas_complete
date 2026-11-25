import 'package:flutter_test/flutter_test.dart';
import 'package:atlas/strings.dart';

void main() {
  test('Arabic and English string sets have identical keys', () {
    expect(S.keys('ar'), S.keys('en'));
  });
}
