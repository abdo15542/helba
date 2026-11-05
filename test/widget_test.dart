import 'package:flutter_test/flutter_test.dart';
import 'package:helba/main.dart';

void main() {
  test('HELBA brand color is configured', () {
    expect(green.toARGB32(), 0xFF087A4B);
  });

  test('normalizeEmail strips spaces keyboards insert after dots', () {
    expect(normalizeEmail('Tagreby98@Gmail. com'), 'tagreby98@gmail.com');
    expect(normalizeEmail('  user @example.com '), 'user@example.com');
  });
}
