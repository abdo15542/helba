// Tests for the Child-C E2E + push fixes (findings #15-#30).
//
// Only pure-Dart helpers are tested here: key validation, KEK derivation
// with conversation binding (+ legacy fallback), malformed-message
// detection, the stable notification id, the push UUID check, and
// ensureKeyPair memoisation / corrupt-key replacement (via a mocked
// flutter_secure_storage method channel). Anything needing Supabase or
// Firebase (loadOrCreateConversationKey election/polling, token upsert
// retries, sign-out pruning) is NOT unit-testable here and must be
// verified on device / against the live project.
//
// NOTE on canEncryptFor: the pre-fix matrix in test/widget_test.dart
// expects {'a': 'key-a'} to be encryptable. That is now FALSE on
// purpose (finding #24): 'key-a' is not a 32-byte base64 X25519 key.
// widget_test.dart:811 must be updated by the coordinator to use real
// keys (see validKey below) — this file asserts the new behaviour.

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helba/src/e2ee.dart';
import 'package:helba/src/push.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SimpleKeyPair> newPair() => X25519().newKeyPair();
  Future<String> pubOf(SimpleKeyPair pair) async =>
      base64Encode((await pair.extractPublicKey()).bytes);
  Future<List<int>> privOf(SimpleKeyPair pair) =>
      pair.extractPrivateKeyBytes();

  /// A valid 32-byte base64 public key (all-zero bytes decode fine).
  final validKey = base64Encode(List<int>.filled(32, 7));
  final otherValidKey = base64Encode(List<int>.filled(32, 9));

  group('key validation (findings #24, #28)', () {
    test('isValidPublicKey accepts only 32-byte base64 keys', () {
      expect(isValidPublicKey(validKey), isTrue);
      expect(isValidPublicKey(otherValidKey), isTrue);
      expect(isValidPublicKey(null), isFalse);
      expect(isValidPublicKey(''), isFalse);
      expect(isValidPublicKey('   '), isFalse);
      expect(isValidPublicKey('key-a'), isFalse);
      expect(isValidPublicKey('not base64!!!'), isFalse);
      // 31 bytes and 33 bytes are not X25519 keys.
      expect(isValidPublicKey(base64Encode(List<int>.filled(31, 1))),
          isFalse);
      expect(isValidPublicKey(base64Encode(List<int>.filled(33, 1))),
          isFalse);
    });

    test('canEncryptFor requires a valid key for every member', () {
      expect(canEncryptFor({'a': validKey, 'b': otherValidKey}), isTrue);
      expect(canEncryptFor({'a': validKey, 'b': 'key-a'}), isFalse);
      expect(canEncryptFor({'a': validKey, 'b': null}), isFalse);
      expect(canEncryptFor({'a': validKey, 'b': ''}), isFalse);
      expect(canEncryptFor({}), isFalse);
    });

    test('deriveSharedSecret rejects a garbage peer key', () async {
      final alice = await newPair();
      await expectLater(
        deriveSharedSecret(await privOf(alice), 'key-a'),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        deriveSharedSecret(
            await privOf(alice), base64Encode(List<int>.filled(16, 1))),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        deriveSharedSecret(await privOf(alice), 'not base64!!!'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('KEK conversation binding (finding #26)', () {
    test('same secret + same conversation => same KEK; different => different',
        () async {
      final secret = List<int>.generate(32, (i) => i);
      final a1 = await deriveKeyEncryptionKey(secret,
          conversationId: 'conv-1');
      final a2 = await deriveKeyEncryptionKey(secret,
          conversationId: 'conv-1');
      final b = await deriveKeyEncryptionKey(secret,
          conversationId: 'conv-2');
      final legacy =
          await deriveKeyEncryptionKey(secret);
      expect(a1, a2);
      expect(a1, isNot(b));
      expect(a1, isNot(legacy));
      expect(a1, hasLength(32));
    });

    test('wrap/unwrap round-trip with a bound KEK', () async {
      final alice = await newPair();
      final bob = await newPair();
      final convKey = generateConversationKey();
      final wrapped = await wrapConversationKey(
        convKey,
        await privOf(alice),
        await pubOf(bob),
        conversationId: 'conv-abc',
      );
      final unwrapped = await unwrapConversationKey(
        wrapped,
        await privOf(bob),
        await pubOf(alice),
        conversationId: 'conv-abc',
      );
      expect(unwrapped, convKey);
    });

    test('legacy-wrapped rows still unwrap with a conversation id',
        () async {
      final alice = await newPair();
      final bob = await newPair();
      final convKey = generateConversationKey();
      // Wrapped WITHOUT a conversation id (pre-fix code).
      final wrapped = await wrapConversationKey(
          convKey, await privOf(alice), await pubOf(bob));
      // Unwrapped WITH one: bound KEK fails, legacy fallback succeeds.
      final unwrapped = await unwrapConversationKey(
        wrapped,
        await privOf(bob),
        await pubOf(alice),
        conversationId: 'conv-abc',
      );
      expect(unwrapped, convKey);
    });

    test('bound-wrapped rows do not unwrap with the legacy KEK alone',
        () async {
      final alice = await newPair();
      final bob = await newPair();
      final wrapped = await wrapConversationKey(
        generateConversationKey(),
        await privOf(alice),
        await pubOf(bob),
        conversationId: 'conv-abc',
      );
      await expectLater(
        unwrapConversationKey(
            wrapped, await privOf(bob), await pubOf(alice)),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });
  });

  group('malformed messages (finding #30)', () {
    test('decryptText distinguishes malformed rows from wrong keys',
        () async {
      final key = generateConversationKey();
      final enc = await encryptText('secret', key);
      // Malformed: missing / invalid / wrong-length inputs.
      await expectLater(
        decryptText('', enc.nonce, key),
        throwsA(isA<MalformedEncryptedMessageException>()),
      );
      await expectLater(
        decryptText(enc.ciphertext, '', key),
        throwsA(isA<MalformedEncryptedMessageException>()),
      );
      await expectLater(
        decryptText('not base64!!!', enc.nonce, key),
        throwsA(isA<MalformedEncryptedMessageException>()),
      );
      await expectLater(
        decryptText(enc.ciphertext, base64Encode(List<int>.filled(5, 0)),
            key),
        throwsA(isA<MalformedEncryptedMessageException>()),
      );
      await expectLater(
        decryptText(base64Encode([1, 2, 3]), enc.nonce, key),
        throwsA(isA<MalformedEncryptedMessageException>()),
      );
      // Malformed is still a FormatException for existing handlers.
      await expectLater(
        decryptText('', enc.nonce, key),
        throwsA(isA<FormatException>()),
      );
      // A well-formed row with the wrong key is NOT malformed.
      await expectLater(
        decryptText(enc.ciphertext, enc.nonce, generateConversationKey()),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });
  });

  group('push pure helpers (findings #17, F7/F8)', () {
    test('stableNotificationId is deterministic, positive, distinct', () {
      const id1 = '11111111-1111-4111-8111-111111111111';
      const id2 = '22222222-2222-4222-8222-222222222222';
      expect(stableNotificationId(id1), stableNotificationId(id1));
      expect(stableNotificationId(id1), isNot(stableNotificationId(id2)));
      expect(stableNotificationId(id1), greaterThanOrEqualTo(0));
      expect(stableNotificationId(id1), lessThanOrEqualTo(0x7fffffff));
    });

    test('isValidPushConversationId accepts only UUIDs', () {
      expect(
          isValidPushConversationId(
              '11111111-1111-4111-8111-111111111111'),
          isTrue);
      expect(isValidPushConversationId('not-a-uuid'), isFalse);
      expect(isValidPushConversationId(''), isFalse);
      expect(isValidPushConversationId('11111111-1111-4111-8111'), isFalse);
    });
  });

  group('ensureKeyPair memoisation + corrupt-key replacement (#21, #22)',
      () {
    // Mock flutter_secure_storage: read returns mockStoredKey, write
    // succeeds silently. Declared first in this group on purpose: the
    // corrupt-key test must run before the memoised pair exists.
    String? mockStoredKey;
    setUpAll(() {
      const channel =
          MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'read') return mockStoredKey;
        return null;
      });
    });

    test('corrupt stored bytes generate a fresh pair and flag replacement',
        () async {
      mockStoredKey = '!!!not-base64!!!';
      final pair = await ensureKeyPair();
      expect(e2eKeyWasReplaced, isTrue);
      final publicKey = await pair.extractPublicKey();
      expect(publicKey.bytes, hasLength(32));
      final privateBytes = await pair.extractPrivateKeyBytes();
      expect(privateBytes, hasLength(32));
    });

    test('concurrent ensureKeyPair calls share one pair', () async {
      mockStoredKey = null;
      final results = await Future.wait([
        ensureKeyPair(),
        ensureKeyPair(),
        ensureKeyPair(),
      ]);
      expect(identical(results[0], results[1]), isTrue);
      expect(identical(results[1], results[2]), isTrue);
      final again = await ensureKeyPair();
      expect(identical(again, results[0]), isTrue);
    });
  });
}
