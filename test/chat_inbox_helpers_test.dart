import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:helba/src/chat.dart';
import 'package:helba/src/inbox.dart';
import 'package:helba/src/utils.dart';

void main() {
  group('chat helpers', () {
    test('formatChatTime shows HH:mm today, date otherwise', () {
      final now = DateTime(2026, 11, 6, 14, 30);
      expect(formatChatTime(DateTime(2026, 11, 6, 9, 5), now: now), '09:05');
      expect(formatChatTime(DateTime(2026, 11, 5, 9, 5), now: now),
          '2026-11-05 09:05');
    });

    test('isMalformedEncryptedRow needs ciphertext and nonce', () {
      expect(
          isMalformedEncryptedRow(
              {'is_encrypted': true, 'ciphertext': 'abc', 'nonce': 'xyz'}),
          isFalse);
      expect(
          isMalformedEncryptedRow(
              {'is_encrypted': true, 'ciphertext': '', 'nonce': 'xyz'}),
          isTrue);
      expect(
          isMalformedEncryptedRow(
              {'is_encrypted': true, 'ciphertext': 'abc'}),
          isTrue);
      expect(isMalformedEncryptedRow({'body': 'plain'}), isFalse);
      expect(isMalformedEncryptedRow({'ciphertext': ''}), isFalse);
    });

    test('asUuidOrNull rejects null and the literal string "null"', () {
      expect(asUuidOrNull(null), isNull);
      expect(asUuidOrNull('null'), isNull);
      expect(asUuidOrNull(''), isNull);
      expect(asUuidOrNull('123e4567-e89b-12d3-a456-426614174000'),
          '123e4567-e89b-12d3-a456-426614174000');
    });
  });

  group('inbox helpers', () {
    test('normalizeArabicForSearch unifies alef/teh/yeh and strips diacritics',
        () {
      expect(normalizeArabicForSearch('أحمد'), 'احمد');
      expect(normalizeArabicForSearch('إيمان'), 'اىمان');
      expect(normalizeArabicForSearch('آية'), 'اىه');
      expect(normalizeArabicForSearch('مدرسة'), 'مدرسه');
      expect(normalizeArabicForSearch('مُحَمَّد'), 'محمد');
      expect(normalizeArabicForSearch('علي'), 'على');
    });

    test('displayNameForUser falls back instead of a blank tile', () {
      expect(displayNameForUser({'display_name': '  أحمد  '}), 'أحمد');
      expect(displayNameForUser({'display_name': '', 'username': 'ahmed'}),
          '@ahmed');
      expect(displayNameForUser({'display_name': null, 'username': null}),
          'مستخدم');
      expect(displayNameForUser({}), 'مستخدم');
    });

    test('latestMessageByConversation keeps the newest per conversation',
        () {
      final rows = [
        {'conversation_id': 'c1', 'body': 'newest c1'},
        {'conversation_id': 'c2', 'body': 'only c2'},
        {'conversation_id': 'c1', 'body': 'older c1'},
      ];
      final latest = latestMessageByConversation(rows);
      expect(latest['c1']!['body'], 'newest c1');
      expect(latest['c2']!['body'], 'only c2');
      expect(latest, hasLength(2));
    });

    test('inboxErrorMessage maps TimeoutException to Arabic', () {
      expect(inboxErrorMessage(TimeoutException('timed out')),
          contains('انتهت المهلة'));
      expect(inboxErrorMessage(Exception('something else')),
          contains('تعذر تحميل المحادثات'));
    });
  });
}
