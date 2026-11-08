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
          'لم يتم تحميل مفتاح التشفير بعد');
      // A member without a key: blame the missing member key.
      expect(
          plaintextBannerMessage({
            'a': [(deviceId: 'd1', publicKey: validKey)],
            'b': <DeviceKey>[],
          }),
          'أحد الأعضاء بلا مفتاح تشفير');
      expect(
          plaintextBannerMessage({
            'a': [(deviceId: 'd1', publicKey: validKey)],
            'b': [(deviceId: null, publicKey: 'key-a')],
          }),
          'أحد الأعضاء بلا مفتاح تشفير');
      expect(plaintextBannerMessage({}),
          'أحد الأعضاء بلا مفتاح تشفير');
    });

    test('plaintext-only display: encrypted rows show the placeholder, '
        'plaintext rows show their body (encryption removed)', () {
      // An old encrypted row is recognised as encrypted and renders
      // as the placeholder only — no decrypt attempt, no spinner,
      // no failure state.
      final encryptedRow = <String, dynamic>{
        'id': 'row-1',
        'body': encryptedMessagePlaceholder,
        'is_encrypted': true,
        'ciphertext': 'AAAACiphertext',
        'signal_msg_type': 'signal',
      };
      expect(isEncryptedMessage(encryptedRow), isTrue);
      expect(encryptedMessagePlaceholder, '🔒 رسالة مشفّرة');
      // A new plaintext row is not encrypted, so the chat shows its
      // body text as-is, with no "not encrypted" label.
      final plainRow = <String, dynamic>{
        'id': 'row-2',
        'body': 'مرحباً بالجميع',
        'is_encrypted': false,
        'message_type': 'text',
      };
      expect(isEncryptedMessage(plainRow), isFalse);
      expect(plainRow['body'], 'مرحباً بالجميع');
      // A row with no is_encrypted field at all (the plaintext
      // insert omits it, so it defaults to false) is plaintext too.
      expect(isEncryptedMessage({'body': 'نص عادي'}), isFalse);
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

    test('shouldHealSessionAfterFailure: only once, only at budget', () {
      // Below the budget: no heal (the session may still converge).
      expect(
        shouldHealSessionAfterFailure(attempts: 0, wasHealed: false),
        isFalse,
      );
      expect(
        shouldHealSessionAfterFailure(
          attempts: maxSignalDecryptAttempts - 1,
          wasHealed: false,
        ),
        isFalse,
      );
      // Budget spent and never healed: heal once.
      expect(
        shouldHealSessionAfterFailure(
          attempts: maxSignalDecryptAttempts,
          wasHealed: false,
        ),
        isTrue,
      );
      // Already healed: never heal again for the same row.
      expect(
        shouldHealSessionAfterFailure(
          attempts: maxSignalDecryptAttempts,
          wasHealed: true,
        ),
        isFalse,
      );
      expect(
        shouldHealSessionAfterFailure(
          attempts: maxSignalDecryptAttempts + 5,
          wasHealed: true,
        ),
        isFalse,
      );
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

    test('shouldPollFallbackMessages: only when fallback active and foregrounded',
        () {
      // The fallback poll keeps the list fresh while the Realtime
      // stream is down; it must not run when the stream is healthy
      // (no fallback) or while the app is in the background.
      expect(fallbackPollInterval, const Duration(seconds: 5));
      expect(
          shouldPollFallbackMessages(
              fallbackActive: true, isForeground: true),
          isTrue);
      expect(
          shouldPollFallbackMessages(
              fallbackActive: false, isForeground: true),
          isFalse);
      expect(
          shouldPollFallbackMessages(
              fallbackActive: true, isForeground: false),
          isFalse);
      expect(
          shouldPollFallbackMessages(
              fallbackActive: false, isForeground: false),
          isFalse);
    });

    test('shouldRunFallbackPollTick: skips while a fetch is in flight', () {
      // A second tick while one fetch is loading is skipped — no
      // overlapping fetches.
      expect(
          shouldRunFallbackPollTick(
              fallbackActive: true,
              validConversationId: true,
              fallbackLoading: false),
          isTrue);
      expect(
          shouldRunFallbackPollTick(
              fallbackActive: true,
              validConversationId: true,
              fallbackLoading: true),
          isFalse);
      // No fallback active (stream healthy) or bad conversation id:
      // no tick.
      expect(
          shouldRunFallbackPollTick(
              fallbackActive: false,
              validConversationId: true,
              fallbackLoading: false),
          isFalse);
      expect(
          shouldRunFallbackPollTick(
              fallbackActive: true,
              validConversationId: false,
              fallbackLoading: false),
          isFalse);
    });

    test('fallbackRowsChanged: ids and count only', () {
      Map<String, dynamic> row(String id) => {'id': id};
      final a = [row('m1'), row('m2')];
      // Identical rows: no update (no rebuild, no decryption re-run).
      expect(fallbackRowsChanged(a, [row('m1'), row('m2')]), isFalse);
      expect(fallbackRowsChanged(<Map<String, dynamic>>[], []), isFalse);
      // A new row appended: update.
      expect(fallbackRowsChanged(a, [row('m1'), row('m2'), row('m3')]),
          isTrue);
      // A row removed: update.
      expect(fallbackRowsChanged(a, [row('m1')]), isTrue);
      // Same count but a different id (row replaced): update.
      expect(fallbackRowsChanged(a, [row('m1'), row('m9')]), isTrue);
      // Same ids in a different order: update (order is by
      // created_at; a reorder means the list changed).
      expect(fallbackRowsChanged(a, [row('m2'), row('m1')]), isTrue);
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
