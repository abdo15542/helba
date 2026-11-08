/// Signal E2E sync-layer tests (`lib/src/signal_sync.dart`).
///
/// Tests the sync layer that bridges [SignalService] (the protocol)
/// and the bundle server: device-number mapping, message row/type
/// helpers, bundle publish/claim mapping, encrypt/decrypt round-trips
/// through [SignalSync], the offline-recipient flow, and the failure
/// paths (no bundle, garbage input, wrong sender device).
///
/// No live Supabase connection is used anywhere: bundles live in
/// [FakeSignalBundleStore] (in-memory, shaped exactly like the
/// `claim_prekey_bundle` RPC row) and protocol state lives in
/// in-memory [MemoryKvStore] backends (same pattern as
/// `test/signal_spike_test.dart`).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:helba/src/signal_service.dart';
import 'package:helba/src/signal_stores.dart';
import 'package:helba/src/signal_sync.dart';
import 'package:libsignal/libsignal.dart';

/// In-memory [SignalKvStore] backend for tests (same pattern as the
/// spike test: the store classes are the persistent ones, only the
/// backend is swapped so no platform channels are needed).
class MemoryKvStore implements SignalKvStore {
  final _map = <String, String>{};

  @override
  Future<String?> read(String key) async => _map[key];

  @override
  Future<void> write(String key, String value) async {
    _map[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _map.remove(key);
  }

  @override
  Future<Map<String, String>> readAll() async =>
      Map<String, String>.from(_map);

  @override
  Future<bool> containsKey(String key) async => _map.containsKey(key);
}

class _StoredPreKey {
  _StoredPreKey({required this.id, required this.publicKeyBase64});

  final int id;
  final String publicKeyBase64;
  bool consumed = false;
}

class _StoredKyberPreKey {
  _StoredKyberPreKey({
    required this.id,
    required this.publicKeyBase64,
    required this.signatureBase64,
    required this.isLastResort,
  });

  final int id;
  final String publicKeyBase64;
  final String signatureBase64;
  final bool isLastResort;
  bool consumed = false;
}

/// In-memory [SignalBundleStore] that behaves like the server side:
///
/// - [upsertBundle] stores the bundle row per user/device.
/// - One-time pre-keys and one-time Kyber pre-keys are consumed on
///   claim; when no one-time Kyber key remains, [claimBundle] falls
///   back to the last-resort Kyber key (never consumed), exactly like
///   the `claim_prekey_bundle` RPC.
/// - [claimBundle] returns a row shaped exactly like that RPC:
///   identity/registration/signed-pre-key fields, one claimed
///   one-time pre-key (`prekey_id`/`prekey_public`, NULL when none
///   remain), and one claimed Kyber pre-key.
class FakeSignalBundleStore implements SignalBundleStore {
  final _bundles = <String, Map<String, dynamic>>{};
  final _oneTime = <String, List<_StoredPreKey>>{};
  final _kyber = <String, List<_StoredKyberPreKey>>{};

  static String _key(String userId, String deviceId) =>
      '$userId::$deviceId';

  @override
  Future<void> upsertBundle({
    required String userId,
    required String deviceId,
    required String identityKeyBase64,
    required int registrationId,
    required int signedPreKeyId,
    required String signedPreKeyPublicBase64,
    required String signedPreKeySignatureBase64,
  }) async {
    _bundles[_key(userId, deviceId)] = {
      'identity_key': identityKeyBase64,
      'registration_id': registrationId,
      'signed_prekey_id': signedPreKeyId,
      'signed_prekey_public': signedPreKeyPublicBase64,
      'signed_prekey_signature': signedPreKeySignatureBase64,
      'signed_prekey_created_at': DateTime.now().toIso8601String(),
    };
  }

  @override
  Future<int> countUnconsumedOneTimePreKeys(
    String userId,
    String deviceId, {
    required int limit,
  }) async {
    final count = unconsumedOneTimeCount(userId, deviceId);
    return count > limit ? limit : count;
  }

  @override
  Future<int> countUnconsumedKyberPreKeys(
    String userId,
    String deviceId, {
    required int limit,
  }) async {
    final count = unconsumedKyberCount(userId, deviceId);
    return count > limit ? limit : count;
  }

  @override
  Future<void> uploadOneTimePreKeys(
    String userId,
    String deviceId,
    List<({int id, Uint8List publicKey})> keys,
  ) async {
    final list = _oneTime.putIfAbsent(_key(userId, deviceId), () => []);
    for (final key in keys) {
      list.removeWhere((k) => k.id == key.id);
      list.add(
        _StoredPreKey(
          id: key.id,
          publicKeyBase64: base64Encode(key.publicKey),
        ),
      );
    }
  }

  @override
  Future<void> uploadKyberPreKeys(
    String userId,
    String deviceId,
    List<
            ({
              int id,
              Uint8List publicKey,
              List<int> signature,
              bool isLastResort,
            })>
        keys,
  ) async {
    final list = _kyber.putIfAbsent(_key(userId, deviceId), () => []);
    for (final key in keys) {
      list.removeWhere((k) => k.id == key.id);
      list.add(
        _StoredKyberPreKey(
          id: key.id,
          publicKeyBase64: base64Encode(key.publicKey),
          signatureBase64: base64Encode(key.signature),
          isLastResort: key.isLastResort,
        ),
      );
    }
  }

  @override
  Future<Map<String, dynamic>?> claimBundle(
    String userId,
    String deviceId,
  ) async {
    final bundle = _bundles[_key(userId, deviceId)];
    if (bundle == null) return null;

    int? preKeyId;
    String? preKeyPublic;
    for (final key in _oneTime[_key(userId, deviceId)] ?? const []) {
      if (key.consumed) continue;
      key.consumed = true;
      preKeyId = key.id;
      preKeyPublic = key.publicKeyBase64;
      break;
    }

    _StoredKyberPreKey? kyber;
    for (final key in _kyber[_key(userId, deviceId)] ?? const []) {
      if (key.isLastResort || key.consumed) continue;
      key.consumed = true;
      kyber = key;
      break;
    }
    // No one-time Kyber key left: fall back to the last-resort key
    // (never consumed), like the real RPC.
    if (kyber == null) {
      for (final key in _kyber[_key(userId, deviceId)] ?? const []) {
        if (key.isLastResort) {
          kyber = key;
          break;
        }
      }
    }

    return {
      'identity_key': bundle['identity_key'],
      'registration_id': bundle['registration_id'],
      'signed_prekey_id': bundle['signed_prekey_id'],
      'signed_prekey_public': bundle['signed_prekey_public'],
      'signed_prekey_signature': bundle['signed_prekey_signature'],
      'signed_prekey_created_at': bundle['signed_prekey_created_at'],
      'prekey_id': preKeyId,
      'prekey_public': preKeyPublic,
      'kyber_prekey_id': kyber?.id,
      'kyber_prekey_public': kyber?.publicKeyBase64,
      'kyber_prekey_signature': kyber?.signatureBase64,
    };
  }

  // ---- Inspection helpers for the tests (not part of the interface).

  bool hasBundle(String userId, String deviceId) =>
      _bundles.containsKey(_key(userId, deviceId));

  Map<String, dynamic>? bundleRow(String userId, String deviceId) =>
      _bundles[_key(userId, deviceId)];

  int unconsumedOneTimeCount(String userId, String deviceId) =>
      _oneTime[_key(userId, deviceId)]
          ?.where((k) => !k.consumed)
          .length ??
      0;

  int unconsumedKyberCount(String userId, String deviceId) =>
      _kyber[_key(userId, deviceId)]
          ?.where((k) => !k.isLastResort && !k.consumed)
          .length ??
      0;

  bool hasLastResortKyber(String userId, String deviceId) =>
      _kyber[_key(userId, deviceId)]?.any((k) => k.isLastResort) ?? false;

  int? lastResortKyberId(String userId, String deviceId) {
    for (final key in _kyber[_key(userId, deviceId)] ?? const []) {
      if (key.isLastResort) return key.id;
    }
    return null;
  }
}

/// Builds a [SignalSync] over an in-memory backend for tests.
SignalSync _makeSync(
  SignalKvStore backend, {
  required String userId,
  required String deviceUuid,
  required SignalBundleStore store,
}) {
  return SignalSync(
    service: SignalService(
      stores: SignalStores.fromKvStore(backend, prefix: 'signal:$userId'),
      localAddress: ProtocolAddress(
        name: userId,
        deviceId: signalDeviceNumber(deviceUuid),
      ),
    ),
    store: store,
    userId: userId,
    deviceUuid: deviceUuid,
    sentPlaintexts: SentSignalPlaintextStore(backend),
    decryptAttempts: SignalDecryptAttemptStore(backend),
  );
}

void main() {
  group('signalDeviceNumber', () {
    test('is deterministic and always in 1..127', () {
      const uuid = 'a95826046-1111-2222-3333-444455556666';
      expect(signalDeviceNumber(uuid), signalDeviceNumber(uuid));
      expect(signalDeviceNumber(uuid), signalDeviceNumber(uuid));
      for (final u in [
        'device-1',
        'device-2',
        'device-3',
        'device-4',
        'device-5',
        'device-6',
        '550e8400-e29b-41d4-a716-446655440000',
        '',
      ]) {
        final n = signalDeviceNumber(u);
        expect(n, greaterThanOrEqualTo(1));
        expect(n, lessThanOrEqualTo(127));
      }
    });

    test('different uuids usually differ', () {
      final outputs = {
        'uuid-1',
        'uuid-2',
        'uuid-3',
        'uuid-4',
        'uuid-5',
        'uuid-6',
        'uuid-7',
        'uuid-8',
      }.map(signalDeviceNumber).toSet();
      expect(outputs.length, greaterThanOrEqualTo(2));
    });

    test('maps the same uuid consistently across calls', () {
      const uuid = 'f6b2be96-aaaa-bbbb-cccc-ddddeeeeffff';
      final first = signalDeviceNumber(uuid);
      for (var i = 0; i < 5; i++) {
        expect(signalDeviceNumber(uuid), first);
      }
    });
  });

  group('message row/type helpers', () {
    test('isSignalMessageRow recognises Signal rows only', () {
      expect(
        isSignalMessageRow({
          'is_encrypted': true,
          'signal_msg_type': 'prekey',
        }),
        isTrue,
      );
      expect(
        isSignalMessageRow({
          'is_encrypted': true,
          'signal_msg_type': 'signal',
        }),
        isTrue,
      );
      // Plaintext.
      expect(isSignalMessageRow({'is_encrypted': false}), isFalse);
      expect(
        isSignalMessageRow({
          'is_encrypted': false,
          'signal_msg_type': 'prekey',
        }),
        isFalse,
      );
      expect(isSignalMessageRow({}), isFalse);
      // Old-E2E rows: encrypted but no Signal type (nonce column set).
      expect(isSignalMessageRow({'is_encrypted': true}), isFalse);
      expect(
        isSignalMessageRow({'is_encrypted': true, 'nonce': 'abc123'}),
        isFalse,
      );
      // Unknown type.
      expect(
        isSignalMessageRow({
          'is_encrypted': true,
          'signal_msg_type': 'garbage',
        }),
        isFalse,
      );
    });

    test('signalMsgTypeOf + parseSignalMsgType round-trip', () {
      final preKey = CiphertextMessage(
        type: CiphertextMessageType.preKey,
        ciphertext: Uint8List.fromList([1, 2, 3]),
      );
      final signal = CiphertextMessage(
        type: CiphertextMessageType.signal,
        ciphertext: Uint8List.fromList([4, 5, 6]),
      );
      expect(signalMsgTypeOf(preKey), 'prekey');
      expect(signalMsgTypeOf(signal), 'signal');
      expect(parseSignalMsgType(signalMsgTypeOf(preKey)),
          CiphertextMessageType.preKey);
      expect(parseSignalMsgType(signalMsgTypeOf(signal)),
          CiphertextMessageType.signal);
      expect(parseSignalMsgType('prekey'), CiphertextMessageType.preKey);
      expect(parseSignalMsgType('signal'), CiphertextMessageType.signal);
      expect(parseSignalMsgType(null), isNull);
      expect(parseSignalMsgType('garbage'), isNull);
      expect(parseSignalMsgType(''), isNull);
      expect(parseSignalMsgType('PREKEY'), isNull);
    });
  });

  group('bundle publish/claim', () {
    test('ensurePublished publishes bundle + one-time + Kyber + last-resort',
        timeout: const Timeout(Duration(minutes: 2)), () async {
      await LibSignal.init();

      final store = FakeSignalBundleStore();
      const bobDevice = 'bob-device-uuid-0001';
      final bob = _makeSync(
        MemoryKvStore(),
        userId: 'bob',
        deviceUuid: bobDevice,
        store: store,
      );
      await bob.ensurePublished(minOneTimePreKeys: 2, minKyberPreKeys: 1);

      expect(store.hasBundle('bob', bobDevice), isTrue);
      expect(
        store.unconsumedOneTimeCount('bob', bobDevice),
        greaterThanOrEqualTo(1),
      );
      expect(
        store.unconsumedKyberCount('bob', bobDevice),
        greaterThanOrEqualTo(1),
      );
      expect(store.hasLastResortKyber('bob', bobDevice), isTrue);
      expect(store.lastResortKyberId('bob', bobDevice), isNotNull);

      // The stored bundle matches the keys the service actually holds.
      final stored = store.bundleRow('bob', bobDevice)!;
      final bundle = await bob.service.buildBundleFromStoredKeys();
      expect(base64Encode(bundle.identityKey()), stored['identity_key']);
      expect(bundle.registrationId(), stored['registration_id']);
      expect(bundle.signedPreKeyId(), stored['signed_prekey_id']);
      expect(
        base64Encode(bundle.signedPreKeyPublic()),
        stored['signed_prekey_public'],
      );
      expect(
        base64Encode(bundle.signedPreKeySignature()),
        stored['signed_prekey_signature'],
      );
    });

    test('fetchPreKeyBundle maps the claimed row; one-time pre-key exhausts',
        timeout: const Timeout(Duration(minutes: 2)), () async {
      await LibSignal.init();

      final store = FakeSignalBundleStore();
      const bobDevice = 'bob-device-uuid-0002';
      final bob = _makeSync(
        MemoryKvStore(),
        userId: 'bob',
        deviceUuid: bobDevice,
        store: store,
      );
      await bob.ensurePublished(minOneTimePreKeys: 2, minKyberPreKeys: 1);

      final alice = _makeSync(
        MemoryKvStore(),
        userId: 'alice',
        deviceUuid: 'alice-device-uuid-0001',
        store: store,
      );
      final published = store.bundleRow('bob', bobDevice)!;
      final lastResortId = store.lastResortKyberId('bob', bobDevice);

      // First claim: one-time pre-key present, one-time Kyber present.
      final first = await alice.fetchPreKeyBundle('bob', bobDevice);
      expect(first, isNotNull);
      expect(base64Encode(first!.identityKey()), published['identity_key']);
      expect(first.registrationId(), published['registration_id']);
      expect(first.deviceId(), signalDeviceNumber(bobDevice));
      expect(first.signedPreKeyId(), published['signed_prekey_id']);
      expect(
        base64Encode(first.signedPreKeyPublic()),
        published['signed_prekey_public'],
      );
      expect(
        base64Encode(first.signedPreKeySignature()),
        published['signed_prekey_signature'],
      );
      expect(first.preKeyId(), isNotNull);
      expect(first.preKeyPublic(), isNotNull);
      expect(first.kyberPreKeyId(), greaterThan(0));
      expect(first.kyberPreKeyPublic(), isNotEmpty);
      expect(first.kyberPreKeySignature(), isNotEmpty);
      // The first claim serves a one-time Kyber key, not last-resort.
      expect(first.kyberPreKeyId(), isNot(lastResortId));

      // Second claim: the last one-time pre-key is still there.
      final second = await alice.fetchPreKeyBundle('bob', bobDevice);
      expect(second, isNotNull);
      expect(second!.preKeyId(), isNotNull);
      expect(second.preKeyPublic(), isNotNull);
      expect(second.kyberPreKeyId(), greaterThan(0));

      // Third claim: one-time pre-keys exhausted -> null pre-key, but
      // the bundle is still usable via the last-resort Kyber key.
      final third = await alice.fetchPreKeyBundle('bob', bobDevice);
      expect(third, isNotNull);
      expect(third!.preKeyId(), isNull);
      expect(third.preKeyPublic(), isNull);
      expect(third.kyberPreKeyId(), lastResortId);
      expect(third.kyberPreKeyPublic(), isNotEmpty);
    });

    test('fetchPreKeyBundle returns null with no published bundle',
        timeout: const Timeout(Duration(minutes: 2)), () async {
      await LibSignal.init();

      final store = FakeSignalBundleStore();
      final alice = _makeSync(
        MemoryKvStore(),
        userId: 'alice',
        deviceUuid: 'alice-device-uuid-0002',
        store: store,
      );
      expect(
        await alice.fetchPreKeyBundle('ghost', 'ghost-device-uuid-1'),
        isNull,
      );
      expect(
        await alice.fetchPreKeyBundle('bob', 'bob-never-published-uuid'),
        isNull,
      );
    });
  });

  group('encrypt/decrypt through SignalSync', () {
    test('round-trip: pre-key first message, then Signal messages',
        timeout: const Timeout(Duration(minutes: 2)), () async {
      await LibSignal.init();

      final store = FakeSignalBundleStore();
      const aliceDevice = 'alice-device-uuid-1001';
      const bobDevice = 'bob-device-uuid-1001';
      final alice = _makeSync(
        MemoryKvStore(),
        userId: 'alice',
        deviceUuid: aliceDevice,
        store: store,
      );
      final bob = _makeSync(
        MemoryKvStore(),
        userId: 'bob',
        deviceUuid: bobDevice,
        store: store,
      );
      await alice.ensurePublished(minOneTimePreKeys: 2, minKyberPreKeys: 1);
      await bob.ensurePublished(minOneTimePreKeys: 2, minKyberPreKeys: 1);

      expect(await alice.hasSessionFor('bob', bobDevice), isFalse);

      // First message: a pre-key message (establishes Bob's session).
      final first = await alice.encryptFor(
        'bob',
        bobDevice,
        'Hello Bob, Signal!',
      );
      expect(first, isNotNull);
      expect(first!.isPreKeyMessage, isTrue);
      expect(base64Decode(first.ciphertextBase64), isNotEmpty);
      expect(await alice.hasSessionFor('bob', bobDevice), isTrue);
      expect(
        await bob.decryptFrom(
          'alice',
          aliceDevice,
          first.ciphertextBase64,
          first.isPreKeyMessage,
        ),
        'Hello Bob, Signal!',
      );

      // Bob replies, so the handshake is confirmed on both sides.
      final reply = await bob.encryptFor('alice', aliceDevice, 'Hello Alice');
      expect(reply, isNotNull);
      expect(reply!.isPreKeyMessage, isFalse);
      expect(
        await alice.decryptFrom(
          'bob',
          bobDevice,
          reply.ciphertextBase64,
          reply.isPreKeyMessage,
        ),
        'Hello Alice',
      );

      // Second message each way: regular Signal messages now.
      final second = await alice.encryptFor('bob', bobDevice, 'second message');
      expect(second, isNotNull);
      expect(second!.isPreKeyMessage, isFalse);
      expect(
        await bob.decryptFrom(
          'alice',
          aliceDevice,
          second.ciphertextBase64,
          second.isPreKeyMessage,
        ),
        'second message',
      );

      // Tampered ciphertext: null, never throws.
      final tampered = base64Decode(second.ciphertextBase64);
      tampered[tampered.length ~/ 2] ^= 0xFF;
      expect(
        await bob.decryptFrom(
          'alice',
          aliceDevice,
          base64Encode(tampered),
          second.isPreKeyMessage,
        ),
        isNull,
      );
    });

    test('offline recipient: encrypt from the published bundle, '
        'fresh Bob service decrypts', timeout: const Timeout(Duration(minutes: 2)), () async {
      await LibSignal.init();

      final store = FakeSignalBundleStore();
      const aliceDevice = 'alice-device-uuid-2001';
      const bobDevice = 'bob-device-uuid-2001';

      // Bob publishes, then goes offline: his SignalSync /
      // SignalService is discarded. Only his backend (private keys +
      // sessions) and the fake server store survive.
      final bobBackend = MemoryKvStore();
      final bob = _makeSync(
        bobBackend,
        userId: 'bob',
        deviceUuid: bobDevice,
        store: store,
      );
      await bob.ensurePublished(minOneTimePreKeys: 2, minKyberPreKeys: 1);

      // Alice never needs Bob online: she builds the session from his
      // published bundle alone.
      final alice = _makeSync(
        MemoryKvStore(),
        userId: 'alice',
        deviceUuid: aliceDevice,
        store: store,
      );
      final encrypted = await alice.encryptFor(
        'bob',
        bobDevice,
        'message while you were away',
      );
      expect(encrypted, isNotNull);
      expect(encrypted!.isPreKeyMessage, isTrue);

      // Bob reopens the app: a fresh service over the ORIGINAL
      // backend, so his private keys survived the "restart".
      final bobAgain = _makeSync(
        bobBackend,
        userId: 'bob',
        deviceUuid: bobDevice,
        store: store,
      );
      expect(
        await bobAgain.decryptFrom(
          'alice',
          aliceDevice,
          encrypted.ciphertextBase64,
          encrypted.isPreKeyMessage,
        ),
        'message while you were away',
      );
    });

    test('resetSessionFor drops the session; next send re-establishes it',
        timeout: const Timeout(Duration(minutes: 2)), () async {
      await LibSignal.init();

      final store = FakeSignalBundleStore();
      const aliceDevice = 'alice-device-uuid-4001';
      const bobDevice = 'bob-device-uuid-4001';
      final alice = _makeSync(
        MemoryKvStore(),
        userId: 'alice',
        deviceUuid: aliceDevice,
        store: store,
      );
      final bob = _makeSync(
        MemoryKvStore(),
        userId: 'bob',
        deviceUuid: bobDevice,
        store: store,
      );
      await bob.ensurePublished(minOneTimePreKeys: 5, minKyberPreKeys: 2);

      final first = await alice.encryptFor('bob', bobDevice, 'before reset');
      expect(first, isNotNull);
      expect(await alice.hasSessionFor('bob', bobDevice), isTrue);
      expect(
        await bob.decryptFrom(
          'alice',
          aliceDevice,
          first!.ciphertextBase64,
          first.isPreKeyMessage,
        ),
        'before reset',
      );

      await alice.resetSessionFor('bob', bobDevice);
      expect(await alice.hasSessionFor('bob', bobDevice), isFalse);

      final second = await alice.encryptFor('bob', bobDevice, 'after reset');
      expect(second, isNotNull);
      expect(second!.isPreKeyMessage, isTrue);
      expect(await alice.hasSessionFor('bob', bobDevice), isTrue);
      expect(
        await bob.decryptFrom(
          'alice',
          aliceDevice,
          second.ciphertextBase64,
          second.isPreKeyMessage,
        ),
        'after reset',
      );
    });

    test('healSessionFor rebuilds a desynced session in one call',
        timeout: const Timeout(Duration(minutes: 2)), () async {
      await LibSignal.init();

      final store = FakeSignalBundleStore();
      const aliceDevice = 'alice-device-uuid-4002';
      const bobDevice = 'bob-device-uuid-4002';
      final alice = _makeSync(
        MemoryKvStore(),
        userId: 'alice',
        deviceUuid: aliceDevice,
        store: store,
      );
      final bob = _makeSync(
        MemoryKvStore(),
        userId: 'bob',
        deviceUuid: bobDevice,
        store: store,
      );
      await bob.ensurePublished(minOneTimePreKeys: 5, minKyberPreKeys: 2);

      final first = await alice.encryptFor('bob', bobDevice, 'before heal');
      expect(first, isNotNull);
      expect(await alice.hasSessionFor('bob', bobDevice), isTrue);

      // The auto-heal: one call deletes the desynced session and
      // rebuilds it from Bob's current bundle.
      expect(await alice.healSessionFor('bob', bobDevice), isTrue);
      expect(await alice.hasSessionFor('bob', bobDevice), isTrue);

      // The next send is a pre-key message (first on the fresh
      // session) and Bob decrypts it — the peer re-syncs.
      final second = await alice.encryptFor('bob', bobDevice, 'after heal');
      expect(second, isNotNull);
      expect(second!.isPreKeyMessage, isTrue);
      expect(
        await bob.decryptFrom(
          'alice',
          aliceDevice,
          second.ciphertextBase64,
          second.isPreKeyMessage,
        ),
        'after heal',
      );
    });
  });

  group('failure paths', () {
    test('no bundle: ensureSessionFor false, encryptFor null; '
        'decryptFrom null on garbage and wrong sender device',
        timeout: const Timeout(Duration(minutes: 2)), () async {
      await LibSignal.init();

      final store = FakeSignalBundleStore();
      const aliceDevice = 'alice-device-uuid-3001';
      const bobDevice = 'bob-device-uuid-3001';
      final alice = _makeSync(
        MemoryKvStore(),
        userId: 'alice',
        deviceUuid: aliceDevice,
        store: store,
      );
      final bob = _makeSync(
        MemoryKvStore(),
        userId: 'bob',
        deviceUuid: bobDevice,
        store: store,
      );

      // Recipient never published: false / null, never a throw.
      expect(await alice.ensureSessionFor('ghost', 'ghost-device-uuid-1'),
          isFalse);
      expect(await alice.hasSessionFor('ghost', 'ghost-device-uuid-1'),
          isFalse);
      expect(
        await alice.encryptFor('ghost', 'ghost-device-uuid-1', 'hello?'),
        isNull,
      );

      // Garbage input to decryptFrom: null, never throws.
      expect(
        await alice.decryptFrom('bob', bobDevice, '!!!not-base64!!!', true),
        isNull,
      );
      expect(
        await alice.decryptFrom(
          'bob',
          bobDevice,
          base64Encode(utf8.encode('garbage bytes')),
          false,
        ),
        isNull,
      );

      // Wrong sender device: establish a confirmed session, send a
      // regular Signal message, then decrypt it as if it came from a
      // different device of Alice's — no session exists for that
      // address, so it must be null (and the attempt must not corrupt
      // the real session: the same message still decrypts fine).
      await alice.ensurePublished(minOneTimePreKeys: 2, minKyberPreKeys: 1);
      await bob.ensurePublished(minOneTimePreKeys: 2, minKyberPreKeys: 1);
      final first = await alice.encryptFor('bob', bobDevice, 'first');
      expect(first, isNotNull);
      expect(
        await bob.decryptFrom(
          'alice',
          aliceDevice,
          first!.ciphertextBase64,
          first.isPreKeyMessage,
        ),
        'first',
      );
      final reply = await bob.encryptFor('alice', aliceDevice, 'reply');
      expect(reply, isNotNull);
      expect(
        await alice.decryptFrom(
          'bob',
          bobDevice,
          reply!.ciphertextBase64,
          reply.isPreKeyMessage,
        ),
        'reply',
      );
      final signalMsg = await alice.encryptFor('bob', bobDevice, 'signal msg');
      expect(signalMsg, isNotNull);
      expect(signalMsg!.isPreKeyMessage, isFalse);
      expect(
        await bob.decryptFrom(
          'alice',
          'some-other-device-uuid-9999',
          signalMsg.ciphertextBase64,
          signalMsg.isPreKeyMessage,
        ),
        isNull,
      );
      expect(
        await bob.decryptFrom(
          'alice',
          aliceDevice,
          signalMsg.ciphertextBase64,
          signalMsg.isPreKeyMessage,
        ),
        'signal msg',
      );
    });
  });

  group('sent plaintext store', () {
    test('save/read round-trip; missing id is null', () async {
      final backend = MemoryKvStore();
      final store = SentSignalPlaintextStore(backend);
      expect(await store.read('msg-1'), isNull);
      await store.save('msg-1', 'hello from me');
      expect(await store.read('msg-1'), 'hello from me');
      // A different id is unaffected.
      expect(await store.read('msg-2'), isNull);
      await store.save('msg-2', 'second');
      expect(await store.read('msg-1'), 'hello from me');
      expect(await store.read('msg-2'), 'second');
    });

    test('keys are namespaced away from the protocol stores', () {
      expect(sentSignalPlaintextKey('abc'), 'helba:sent-signal:abc');
      expect(sentSignalPlaintextKey('abc'),
          isNot(sentSignalPlaintextKey('def')));
      expect(sentSignalPlaintextKey('abc'), isNot(startsWith('signal:')));
    });
  });

  group('decrypt attempt store (persistent budget + one heal)', () {
    test('attempts persist across store instances (chat reopen)',
        () async {
      final backend = MemoryKvStore();
      // First "chat open": two failed attempts.
      final first = SignalDecryptAttemptStore(backend);
      expect(await first.attempts('msg-1'), 0);
      expect(await first.recordAttempt('msg-1'), 1);
      expect(await first.recordAttempt('msg-1'), 2);
      // Second "chat open": a new store over the SAME backend still
      // sees the two attempts — the budget is not reset by reopening.
      final second = SignalDecryptAttemptStore(backend);
      expect(await second.attempts('msg-1'), 2);
      expect(await second.recordAttempt('msg-1'), 3);
      // A different message is unaffected.
      expect(await second.attempts('msg-2'), 0);
    });

    test('clear prunes attempts and heal marker', () async {
      final backend = MemoryKvStore();
      final store = SignalDecryptAttemptStore(backend);
      await store.recordAttempt('msg-1');
      await store.markHealed('msg-1');
      expect(await store.attempts('msg-1'), 1);
      expect(await store.wasHealed('msg-1'), isTrue);
      await store.clear('msg-1');
      await store.clearHealed('msg-1');
      expect(await store.attempts('msg-1'), 0);
      expect(await store.wasHealed('msg-1'), isFalse);
    });

    test('heal marker is per message', () async {
      final backend = MemoryKvStore();
      final store = SignalDecryptAttemptStore(backend);
      expect(await store.wasHealed('msg-1'), isFalse);
      await store.markHealed('msg-1');
      expect(await store.wasHealed('msg-1'), isTrue);
      expect(await store.wasHealed('msg-2'), isFalse);
    });

    test('keys are namespaced away from the protocol stores', () {
      expect(
        signalDecryptAttemptsKey('abc'),
        'helba:signal-decrypt-attempts:abc',
      );
      expect(
        signalDecryptHealedKey('abc'),
        'helba:signal-decrypt-healed:abc',
      );
      expect(signalDecryptAttemptsKey('abc'), isNot(startsWith('signal:')));
      expect(signalDecryptHealedKey('abc'), isNot(startsWith('signal:')));
    });
  });

  group('simultaneous initiation (13:27 race)', () {
    test('both sides claim first, then cross messages all decrypt',
        timeout: const Timeout(Duration(minutes: 2)), () async {
      await LibSignal.init();

      final store = FakeSignalBundleStore();
      const aliceDevice = 'alice-race-device-uuid-0001';
      const bobDevice = 'bob-race-device-uuid-0001';
      final alice = _makeSync(MemoryKvStore(),
          userId: 'alice', deviceUuid: aliceDevice, store: store);
      final bob = _makeSync(MemoryKvStore(),
          userId: 'bob', deviceUuid: bobDevice, store: store);
      await alice.ensurePublished(minOneTimePreKeys: 5, minKyberPreKeys: 2);
      await bob.ensurePublished(minOneTimePreKeys: 5, minKyberPreKeys: 2);

      // 13:27:37 — Alice claims Bob's bundle (initiator session).
      expect(await alice.ensureSessionFor('bob', bobDevice), isTrue);
      // 13:27:43 — Bob claims Alice's bundle (initiator session).
      expect(await bob.ensureSessionFor('alice', aliceDevice), isTrue);

      // 13:27:46 — Bob's first (pre-key) message decrypts on Alice.
      final bobFirst =
          await bob.encryptFor('alice', aliceDevice, 'first from bob');
      expect(bobFirst, isNotNull);
      expect(
        await alice.decryptFrom('bob', bobDevice, bobFirst!.ciphertextBase64,
            bobFirst.isPreKeyMessage),
        'first from bob',
      );

      // 13:27:57 — Alice's message decrypts on Bob.
      final aliceFirst =
          await alice.encryptFor('bob', bobDevice, 'first from alice');
      expect(aliceFirst, isNotNull);
      expect(
        await bob.decryptFrom('alice', aliceDevice,
            aliceFirst!.ciphertextBase64, aliceFirst.isPreKeyMessage),
        'first from alice',
      );

      // 13:51 — follow-ups both ways still decrypt.
      final bobSecond =
          await bob.encryptFor('alice', aliceDevice, 'second from bob');
      expect(
        await alice.decryptFrom('bob', bobDevice,
            bobSecond!.ciphertextBase64, bobSecond.isPreKeyMessage),
        'second from bob',
      );
      final aliceSecond =
          await alice.encryptFor('bob', bobDevice, 'second from alice');
      expect(
        await bob.decryptFrom('alice', aliceDevice,
            aliceSecond!.ciphertextBase64, aliceSecond.isPreKeyMessage),
        'second from alice',
      );
    });

    test('a never-decrypted pre-key message is still recoverable later',
        timeout: const Timeout(Duration(minutes: 2)), () async {
      await LibSignal.init();

      final store = FakeSignalBundleStore();
      const aliceDevice = 'alice-rec-device-uuid-0001';
      const bobDevice = 'bob-rec-device-uuid-0001';
      final alice = _makeSync(MemoryKvStore(),
          userId: 'alice', deviceUuid: aliceDevice, store: store);
      final bob = _makeSync(MemoryKvStore(),
          userId: 'bob', deviceUuid: bobDevice, store: store);
      await alice.ensurePublished(minOneTimePreKeys: 5, minKyberPreKeys: 2);
      await bob.ensurePublished(minOneTimePreKeys: 5, minKyberPreKeys: 2);

      // Bob initiates; Alice does NOT decrypt M1 yet (the transient
      // on-device failure).
      final m1 = await bob.encryptFor('alice', aliceDevice, 'M1 prekey');
      expect(m1, isNotNull);

      // Meanwhile Alice builds an initiator session and sends; Bob
      // decrypts it; Bob sends M2 and Alice decrypts it (the session
      // ratchets forward).
      expect(await alice.ensureSessionFor('bob', bobDevice), isTrue);
      final a1 = await alice.encryptFor('bob', bobDevice, 'A1 from alice');
      expect(
        await bob.decryptFrom('alice', aliceDevice, a1!.ciphertextBase64,
            a1.isPreKeyMessage),
        'A1 from alice',
      );
      final m2 = await bob.encryptFor('alice', aliceDevice, 'M2 signal');
      expect(
        await alice.decryptFrom('bob', bobDevice, m2!.ciphertextBase64,
            m2.isPreKeyMessage),
        'M2 signal',
      );

      // Retrying M1 now still succeeds: a failed/deferred first
      // decrypt does not make the message unrecoverable.
      expect(
        await alice.decryptFrom('bob', bobDevice, m1!.ciphertextBase64,
            m1.isPreKeyMessage),
        'M1 prekey',
      );
    });

    test('a failed pre-key decrypt attempt does not poison the retry',
        timeout: const Timeout(Duration(minutes: 2)), () async {
      await LibSignal.init();

      final store = FakeSignalBundleStore();
      const aliceDevice = 'alice-poison-device-uuid-0001';
      const bobDevice = 'bob-poison-device-uuid-0001';
      final alice = _makeSync(MemoryKvStore(),
          userId: 'alice', deviceUuid: aliceDevice, store: store);
      final bob = _makeSync(MemoryKvStore(),
          userId: 'bob', deviceUuid: bobDevice, store: store);
      await alice.ensurePublished(minOneTimePreKeys: 5, minKyberPreKeys: 2);
      await bob.ensurePublished(minOneTimePreKeys: 5, minKyberPreKeys: 2);

      final m1 = await bob.encryptFor('alice', aliceDevice, 'M1 prekey');
      expect(m1, isNotNull);
      // Tampered ciphertext fails (both types tried, both fail).
      final bytes = base64Decode(m1!.ciphertextBase64);
      final tampered = Uint8List.fromList(bytes);
      tampered[tampered.length - 1] ^= 0xFF;
      expect(
        await alice.decryptFrom(
            'bob', bobDevice, base64Encode(tampered), m1.isPreKeyMessage),
        isNull,
      );
      // Retrying the ORIGINAL ciphertext still succeeds: the failed
      // attempt did not consume the one-time pre-key.
      expect(
        await alice.decryptFrom('bob', bobDevice, m1.ciphertextBase64,
            m1.isPreKeyMessage),
        'M1 prekey',
      );

      // The wrong-type flag still decrypts via the fallback attempt.
      final m2 = await bob.encryptFor('alice', aliceDevice, 'M2 prekey');
      expect(
        await alice.decryptFrom(
            'bob', bobDevice, m2!.ciphertextBase64, false),
        'M2 prekey',
      );
    });

    test('concurrent encrypts for the same peer all stay decryptable',
        timeout: const Timeout(Duration(minutes: 2)), () async {
      await LibSignal.init();

      final store = FakeSignalBundleStore();
      const aliceDevice = 'alice-conc-device-uuid-0001';
      const bobDevice = 'bob-conc-device-uuid-0001';
      final alice = _makeSync(MemoryKvStore(),
          userId: 'alice', deviceUuid: aliceDevice, store: store);
      final bob = _makeSync(MemoryKvStore(),
          userId: 'bob', deviceUuid: bobDevice, store: store);
      await alice.ensurePublished(minOneTimePreKeys: 5, minKyberPreKeys: 2);
      await bob.ensurePublished(minOneTimePreKeys: 5, minKyberPreKeys: 2);

      // Fire five encrypts concurrently (the per-peer lock serializes
      // the session ratchet writes); every message must still decrypt
      // in order on Bob.
      final encrypted = await Future.wait([
        for (var i = 0; i < 5; i++)
          alice.encryptFor('bob', bobDevice, 'concurrent $i'),
      ]);
      for (final e in encrypted) {
        expect(e, isNotNull);
      }
      for (var i = 0; i < 5; i++) {
        final e = encrypted[i]!;
        expect(
          await bob.decryptFrom(
              'alice', aliceDevice, e.ciphertextBase64, e.isPreKeyMessage),
          'concurrent $i',
        );
      }
    });
  });
}
