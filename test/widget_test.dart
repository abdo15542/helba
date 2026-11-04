import 'package:flutter_test/flutter_test.dart';
import 'package:helba/main.dart';

void main() {
  test('HELBA brand color is configured', () {
    expect(green.toARGB32(), 0xFF087A4B);
  });
}
