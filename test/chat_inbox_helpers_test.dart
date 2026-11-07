import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:helba/src/chat.dart';
import 'package:helba/src/e2ee.dart';
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

    test('isMalformedEncryptedRow: Signal rows need no nonce', () {
      // Signal rows carry the nonce inside the serialized ciphertext,
      // so their nonce column is NULL by design — that is not
      // malformed. Only an empty ciphertext (or a missing/invalid
      // signal_msg_type) is malformed for a Signal row.
      expect(
          isMalformedEncryptedRow({
            'is_encrypted': true,
            'ciphertext': 'abc',
            'signal_msg_type': 'prekey',
          }),
          isFalse);
      expect(
          isMalformedEncryptedRow({
            'is_encrypted': true,
            'ciphertext': 'abc',
            'signal_msg_type': 'signal',
          }),
          isFalse);
      expect(
          isMalformedEncryptedRow({
            'is_encrypted': true,
            'ciphertext': '',
            'signal_msg_type': 'prekey',
          }),
          isTrue);
      // An encrypted row with no signal type and no nonce is an old
      // E2E row missing its nonce — still malformed.
      expect(
          isMalformedEncryptedRow(
              {'is_encrypted': true, 'ciphertext': 'abc'}),
          isTrue);
    });

    test('asUuidOrNull rejects null and the literal string "null"', () {
      expect(asUuidOrNull(null), isNull);
      expect(asUuidOrNull('null'), isNull);
      expect(asUuidOrNull(''), isNull);
      expect(asUuidOrNull('123e4567-e89b-12d3-a456-426614174000'),
          '123e4567-e89b-12d3-a456-426614174000');
    });

    test('plaintextBannerMessage names the real cause', () {
      // A 32-byte base64 key is valid; anything else means "no key".
      // Members map to their device keys (deviceId null = legacy entry).
      final validKey = base64Encode(List<int>.filled(32, 7));
      // Every member has a key but the conversation key failed to
      // load: blame the key load, not a member key.
      expect(
          plaintextBannerMessage({
            'a': [(deviceId: 'd1', publicKey: validKey)],
            'b': [(deviceId: 'd2', publicKey: validKey)],
          }),
          '🔓 غير مشفّرة — تعذّر تحميل مفتاح التشفير');
      // A member without a key: blame the missing member key.
      expect(
          plaintextBannerMessage({
            'a': [(deviceId: 'd1', publicKey: validKey)],
            'b': <DeviceKey>[],
          }),
          '🔓 غير مشفّرة — أحد الأعضاء بلا مفتاح');
      expect(
          plaintextBannerMessage({
            'a': [(deviceId: 'd1', publicKey: validKey)],
            'b': [(deviceId: null, publicKey: 'key-a')],
          }),
          '🔓 غير مشفّرة — أحد الأعضاء بلا مفتاح');
      expect(plaintextBannerMessage({}),
          '🔓 غير مشفّرة — أحد الأعضاء بلا مفتاح');
    });

    test('isOwnSignalRow: only own Signal rows', () {
      const me = 'user-me';
      const peer = 'user-peer';
      final ownSignal = {
        'id': 'm1',
        'sender_id': me,
        'is_encrypted': true,
        'signal_msg_type': 'prekey',
        'ciphertext': 'abc',
      };
      expect(isOwnSignalRow(ownSignal, me), isTrue);
      // The peer's Signal row is not own.
      expect(
          isOwnSignalRow({...ownSignal, 'sender_id': peer}, me), isFalse);
      // Own OLD-E2E row is not a Signal row (shared key: the sender
      // CAN decrypt it), so it must still go through decryption.
      expect(
          isOwnSignalRow({
            'id': 'm2',
            'sender_id': me,
            'is_encrypted': true,
            'ciphertext': 'abc',
            'nonce': 'xyz',
          }, me),
          isFalse);
      // Plaintext and no-user cases are not own Signal rows.
      expect(isOwnSignalRow({'sender_id': me}, me), isFalse);
      expect(isOwnSignalRow(ownSignal, null), isFalse);
      expect(isOwnSignalRow(ownSignal, ''), isFalse);
      expect(isOwnSignalRow(ownSignal, peer), isFalse);
    });

    test('signalDecryptShouldRetry: bounded budget', () {
      expect(signalDecryptShouldRetry(0), isTrue);
      expect(signalDecryptShouldRetry(1), isTrue);
      expect(signalDecryptShouldRetry(maxSignalDecryptAttempts - 1),
          isTrue);
      expect(signalDecryptShouldRetry(maxSignalDecryptAttempts), isFalse);
      expect(signalDecryptShouldRetry(maxSignalDecryptAttempts + 5),
          isFalse);
    });

    test('shouldRefreshMessagesOnResume: only resumed refreshes', () {
      // A silently disconnected Realtime stream freezes the list
      // (rows that arrived while away never appear); rebuilding it on
      // resume re-runs the initial query so the list catches up.
      expect(shouldRefreshMessagesOnResume(AppLifecycleState.resumed),
          isTrue);
      expect(shouldRefreshMessagesOnResume(AppLifecycleState.inactive),
          isFalse);
      expect(shouldRefreshMessagesOnResume(AppLifecycleState.paused),
          isFalse);
      expect(shouldRefreshMessagesOnResume(AppLifecycleState.hidden),
          isFalse);
      expect(shouldRefreshMessagesOnResume(AppLifecycleState.detached),
          isFalse);
    });

    test('encryptedRowBody: own Signal rows never show a failure', () {
      const me = 'user-me';
      const peer = 'user-peer';
      final ownSignal = {
        'id': 'm1',
        'sender_id': me,
        'is_encrypted': true,
        'signal_msg_type': 'signal',
        'ciphertext': 'abc',
      };
      EncryptedRowBody body(Map<String, dynamic> row,
              {Map<String, String> own = const {},
              Set<String> permanent = const {},
              Set<String> failed = const {},
              Map<String, String> decrypted = const {}}) =>
          encryptedRowBody(
            row: row,
            currentUserId: me,
            decrypted: decrypted,
            ownSentPlaintext: own,
            malformedIds: const {},
            permanentlyUnreadable: permanent,
            decryptFailed: failed,
          );

      // Own Signal row WITH a stored plaintext: show it.
      expect(body(ownSignal, own: {'m1': 'hello'}),
          EncryptedRowBody.ownPlaintext);
      // Own Signal row WITHOUT a stored plaintext: placeholder, not a
      // failure — even if it somehow landed in a failure set.
      expect(body(ownSignal), EncryptedRowBody.ownPlaceholder);
      expect(body(ownSignal, permanent: {'m1'}),
          EncryptedRowBody.ownPlaceholder);
      expect(body(ownSignal, failed: {'m1'}),
          EncryptedRowBody.ownPlaceholder);
      // A peer Signal row with a decrypted body shows it.
      final peerSignal = {...ownSignal, 'sender_id': peer};
      expect(body(peerSignal, decrypted: {'m1': 'hi'}),
          EncryptedRowBody.decrypted);
      // A peer Signal row with no decrypted body is still decrypting
      // (pending), not permanently unreadable.
      expect(body(peerSignal), EncryptedRowBody.decrypting);
      // ...unless it is in a failure set: failed (retryable) or, for
      // old-E2E rows, permanently unreadable.
      expect(body(peerSignal, failed: {'m1'}), EncryptedRowBody.failed);
      expect(body(peerSignal, permanent: {'m1'}),
          EncryptedRowBody.permanentlyUnreadable);
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
