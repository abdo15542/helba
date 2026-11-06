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

    test('canEncryptFor requires a valid key on some device per member',
        () {
      // Device shape: each member maps to their device keys; a member
      // needs >= 1 valid device key (the legacy per-user entry has
      // deviceId null).
      expect(
          canEncryptFor({
            'a': [(deviceId: 'd1', publicKey: validKey)],
            'b': [(deviceId: 'd2', publicKey: otherValidKey)],
          }),
          isTrue);
      expect(
          canEncryptFor({
            'a': [(deviceId: 'd1', publicKey: validKey)],
            'b': [(deviceId: null, publicKey: otherValidKey)],
          }),
          isTrue);
      // One valid device is enough even if another device key is bad.
      expect(
          canEncryptFor({
            'a': [
              (deviceId: 'd1', publicKey: 'key-a'),
              (deviceId: 'd2', publicKey: validKey),
            ],
            'b': [(deviceId: 'd2', publicKey: otherValidKey)],
          }),
          isTrue);
      expect(
          canEncryptFor({
            'a': [(deviceId: 'd1', publicKey: validKey)],
            'b': [(deviceId: 'd2', publicKey: 'key-a')],
          }),
          isFalse);
      expect(
          canEncryptFor({
            'a': [(deviceId: 'd1', publicKey: validKey)],
            'b': <DeviceKey>[],
          }),
          isFalse);
      expect(
          canEncryptFor({
            'a': [(deviceId: 'd1', publicKey: validKey)],
            'b': [(deviceId: null, publicKey: '')],
          }),
          isFalse);
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

    test('unwrapWrappedKeyWithFallback reports the legacy origin', () async {
      final alice = await newPair();
      final bob = await newPair();
      final convKey = generateConversationKey();
      // Wrapped WITHOUT a conversation id (pre-fix code): the bound
      // attempt fails, the legacy attempt succeeds and says so.
      final legacyWrapped = await wrapConversationKey(
          convKey, await privOf(alice), await pubOf(bob));
      final legacyLoaded = await unwrapWrappedKeyWithFallback(
        legacyWrapped,
        await privOf(bob),
        await pubOf(alice),
        'conv-abc',
      );
      expect(legacyLoaded.key, convKey);
      expect(legacyLoaded.fromLegacy, isTrue);
      // Wrapped WITH a conversation id: the bound attempt succeeds.
      final boundWrapped = await wrapConversationKey(
        convKey,
        await privOf(alice),
        await pubOf(bob),
        conversationId: 'conv-abc',
      );
      final boundLoaded = await unwrapWrappedKeyWithFallback(
        boundWrapped,
        await privOf(bob),
        await pubOf(alice),
        'conv-abc',
      );
      expect(boundLoaded.key, convKey);
      expect(boundLoaded.fromLegacy, isFalse);
    });

    test('unwrapWrappedKeyWithFallback throws when neither KEK works',
        () async {
      final alice = await newPair();
      final bob = await newPair();
      final carol = await newPair();
      final wrapped = await wrapConversationKey(
        generateConversationKey(),
        await privOf(alice),
        await pubOf(bob),
        conversationId: 'conv-abc',
      );
      // Carol holds a different private key: the bound KEK and the
      // legacy KEK both fail — at the _loadMyWrappedKey level this
      // becomes the definitive "blocked" outcome.
      await expectLater(
        unwrapWrappedKeyWithFallback(
          wrapped,
          await privOf(carol),
          await pubOf(alice),
          'conv-abc',
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });
  });

  group('key creation guard (afterReset)', () {
    test('shouldCreateKey refuses a competing key when messages exist',
        () {
      expect(
          shouldCreateKey(
              hasEncryptedMessages: true, afterReset: false),
          isFalse);
    });

    test('shouldCreateKey allows creation after an explicit reset', () {
      expect(
          shouldCreateKey(
              hasEncryptedMessages: true, afterReset: true),
          isTrue);
    });

    test('shouldCreateKey allows creation when nothing is encrypted', () {
      expect(
          shouldCreateKey(
              hasEncryptedMessages: false, afterReset: false),
          isTrue);
      expect(
          shouldCreateKey(
              hasEncryptedMessages: false, afterReset: true),
          isTrue);
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

  group('per-device keys (migration 023)', () {
    // Key-aware flutter_secure_storage mock with a backing map, so a
    // pre-stored device id is really read back. Registered here (after
    // the ensureKeyPair group above) so it replaces that group's
    // single-value mock for the rest of the file.
    final store = <String, String>{};
    setUpAll(() {
      const channel =
          MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        final args = call.arguments;
        final key = args is Map ? args['key']?.toString() : null;
        if (call.method == 'read') return key == null ? null : store[key];
        if (call.method == 'write' && key != null) {
          store[key] = args['value']?.toString() ?? '';
        }
        return null;
      });
    });

    test('generateDeviceId makes valid, distinct UUID v4 ids', () {
      final uuidV4 = RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
          r'[0-9a-f]{12}$');
      final first = generateDeviceId();
      final second = generateDeviceId();
      expect(uuidV4.hasMatch(first), isTrue);
      expect(uuidV4.hasMatch(second), isTrue);
      expect(first, isNot(second));
    });

    test('getDeviceId reuses the stored id and is stable across calls',
        () async {
      const stored = '11111111-2222-4333-8444-555555555555';
      store['helba_device_id'] = stored;
      expect(await getDeviceId(), stored);
      expect(await getDeviceId(), stored);
    });

    test('mergeMemberDeviceKeys lists devices plus the legacy entry', () {
      final merged = mergeMemberDeviceKeys(
        {'a': validKey, 'b': otherValidKey, 'c': null},
        [
          {'user_id': 'a', 'device_id': 'd1', 'public_key': validKey},
          {'user_id': 'a', 'device_id': 'd2', 'public_key': otherValidKey},
          {'user_id': 'b', 'device_id': 'd9', 'public_key': validKey},
          // Rows for non-members and rows with empty fields are ignored.
          {'user_id': 'zzz', 'device_id': 'd1', 'public_key': validKey},
          {'user_id': 'b', 'device_id': '', 'public_key': validKey},
          {'user_id': 'b', 'device_id': 'd8', 'public_key': ''},
        ],
      );
      expect(merged['a'], hasLength(3)); // d1, d2, legacy
      expect(merged['a']!.first.deviceId, 'd1');
      expect(merged['a']!.last.deviceId, isNull); // legacy entry last
      expect(merged['b'], hasLength(2)); // d9, legacy
      expect(merged['c'], isEmpty); // no devices, no profiles key
      expect(merged.containsKey('zzz'), isFalse);
    });

    test('mergeMemberDeviceKeys keeps the legacy-only member working',
        () {
      final merged = mergeMemberDeviceKeys(
        {'a': validKey},
        <Map<String, dynamic>>[],
      );
      expect(merged['a'], hasLength(1));
      expect(merged['a']!.single.deviceId, isNull);
      expect(canEncryptFor(merged), isTrue);
    });

    test('pickMyWrappedRow prefers my device row, then the legacy row',
        () {
      const legacy = {
        'device_id': null,
        'wrapped_key': 'legacy-wrap',
        'wrapped_by': 'w',
      };
      const mine = {
        'device_id': 'my-device',
        'wrapped_key': 'device-wrap',
        'wrapped_by': 'w',
      };
      const otherDevice = {
        'device_id': 'other-device',
        'wrapped_key': 'other-wrap',
        'wrapped_by': 'w',
      };
      expect(pickMyWrappedRow([legacy, mine], 'my-device'), mine);
      expect(pickMyWrappedRow([mine, legacy], 'my-device'), mine);
      expect(pickMyWrappedRow([legacy, otherDevice], 'my-device'), legacy);
      expect(pickMyWrappedRow([otherDevice], 'my-device'), isNull);
      expect(pickMyWrappedRow([], 'my-device'), isNull);
    });
  });
}
