/// Signal Protocol 1:1 service (spike).
///
/// Small, focused API over the `libsignal` 9.0.0 package (Dart bindings
/// for Signal's Rust libsignal v0.106.0 — the protocol WhatsApp uses):
/// X3DH + PQXDH session establishment via pre-key bundles, then the
/// Double Ratchet for every message.
///
/// This file does not touch the old E2E code (`e2ee.dart` / `chat.dart`)
/// or any Supabase table: it is the new protocol layer. The server's
/// only job in the full rebuild is to store and hand out each device's
/// pre-key bundle (identity key, signed pre-key, one-time pre-keys,
/// Kyber pre-keys); the keys themselves never leave the device except
/// as public bundle material.
///
/// Call [LibSignal.init] once per isolate before using this service
/// (it loads the native library; it is idempotent).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal/libsignal.dart';

import 'signal_stores.dart';

/// 1:1 Signal Protocol service for one local device.
///
/// Holds the six [SignalStores] and this device's [ProtocolAddress].
/// All state lives in the stores (secure storage in production), so a
/// service rebuilt over the same backend resumes the same sessions —
/// nothing is kept in memory that must survive a restart.
class SignalService {
  SignalService({required this.stores, required this.localAddress});

  final SignalStores stores;
  final ProtocolAddress localAddress;

  /// Wires a service to [FlutterSecureStorage] under [prefix].
  ///
  /// [prefix] namespaces the stored keys (for example
  /// `signal:<userId>`). [localName] is this device's protocol name
  /// (the user's id); [localDeviceId] must be 1..127.
  factory SignalService.fromSecureStorage({
    required FlutterSecureStorage storage,
    required String prefix,
    required String localName,
    required int localDeviceId,
  }) {
    return SignalService(
      stores: SignalStores.fromSecureStorage(storage, prefix: prefix),
      localAddress: ProtocolAddress(name: localName, deviceId: localDeviceId),
    );
  }

  SessionCipher _cipher() => SessionCipher(
        localAddress: localAddress,
        sessionStore: stores.session,
        identityKeyStore: stores.identity,
        preKeyStore: stores.preKey,
        signedPreKeyStore: stores.signedPreKey,
        kyberPreKeyStore: stores.kyberPreKey,
      );

  /// Generates a fresh pre-key bundle for this device and persists
  /// every private part in the stores.
  ///
  /// The returned bundle is the public material to publish (to the
  /// server, so peers can build a session): identity public key,
  /// signed pre-key + signature, one one-time pre-key, and one
  /// one-time Kyber pre-key. libsignal v0.106.0 requires the Kyber
  /// part — a bundle without it is rejected.
  ///
  /// Ids come from monotonic counters in the backend, so calling this
  /// twice mints fresh keys instead of overwriting the published ones.
  Future<PreKeyBundle> generateBundle() async {
    final identity = await stores.identity.getIdentityKeyPair();
    final registrationId = await stores.identity.getLocalRegistrationId();
    final now = BigInt.from(DateTime.now().millisecondsSinceEpoch);

    final preKeyId = await _nextId('prekey');
    final preKeyPrivate = PrivateKey.generate();
    final preKeyRecord = PreKeyRecord(
      id: preKeyId,
      publicKey: preKeyPrivate.getPublicKey(),
      privateKey: preKeyPrivate,
    );
    await stores.preKey.storePreKey(preKeyId, preKeyRecord);

    final signedPreKeyId = await _nextId('signedprekey');
    final signedPrivate = PrivateKey.generate();
    final signedPublic = signedPrivate.getPublicKey();
    final signedSignature =
        identity.sign(message: signedPublic.serialize().toList());
    final signedRecord = SignedPreKeyRecord(
      id: signedPreKeyId,
      timestamp: now,
      publicKey: signedPublic,
      privateKey: signedPrivate,
      signature: signedSignature,
    );
    await stores.signedPreKey.storeSignedPreKey(signedPreKeyId, signedRecord);
    await stores.signedPreKey
        .storeSignature(signedPreKeyId, signedSignature);

    final kyberPreKeyId = await _nextId('kyberprekey');
    final kyberPair = KyberKeyPair.generate();
    final kyberSignature = identity.sign(
      message: kyberPair.getPublicKey().serialize().toList(),
    );
    final kyberRecord = KyberPreKeyRecord.create(
      id: kyberPreKeyId,
      timestamp: now,
      keyPair: kyberPair,
      signature: kyberSignature,
    );
    await stores.kyberPreKey.storeKyberPreKey(kyberPreKeyId, kyberRecord);
    await stores.kyberPreKey.setKyberPreKeyKind(
      kyberPreKeyId,
      isLastResort: false,
    );
    await stores.kyberPreKey.storeSignature(kyberPreKeyId, kyberSignature);

    return PreKeyBundle(
      registrationId: registrationId,
      deviceId: localAddress.deviceId(),
      preKeyId: preKeyId,
      preKeyPublic: preKeyRecord.publicKey(),
      signedPreKeyId: signedPreKeyId,
      signedPreKeyPublic: signedRecord.publicKey(),
      signedPreKeySignature: signedSignature,
      identityKey: identity.publicKey.toList(),
      kyberPreKeyId: kyberPreKeyId,
      kyberPreKeyPublic: kyberRecord.getPublicKey().serialize(),
      kyberPreKeySignature: kyberSignature,
    );
  }

  /// Rebuilds a publishable bundle from the keys already stored
  /// (after a restart, or to re-publish). Picks the newest signed
  /// pre-key, the newest Kyber pre-key, and the first unconsumed
  /// one-time pre-key. Throws [StateError] when a piece is missing.
  Future<PreKeyBundle> buildBundleFromStoredKeys() async {
    final identity = await stores.identity.getIdentityKeyPair();
    final registrationId = await stores.identity.getLocalRegistrationId();

    final signedIds = await stores.signedPreKey.getAllSignedPreKeyIds();
    if (signedIds.isEmpty) throw StateError('no signed pre-key stored');
    signedIds.sort();
    final signedId = signedIds.last;
    final signedRecord =
        await stores.signedPreKey.loadSignedPreKey(signedId);
    final signedSig = await stores.signedPreKey.loadSignature(signedId);
    if (signedRecord == null || signedSig == null) {
      throw StateError('stored signed pre-key $signedId is incomplete');
    }

    final kyberIds = await stores.kyberPreKey.getAllKyberPreKeyIds();
    if (kyberIds.isEmpty) throw StateError('no Kyber pre-key stored');
    kyberIds.sort();
    final kyberId = kyberIds.last;
    final kyberRecord = await stores.kyberPreKey.loadKyberPreKey(kyberId);
    final kyberSig = await stores.kyberPreKey.loadSignature(kyberId);
    if (kyberRecord == null || kyberSig == null) {
      throw StateError('stored Kyber pre-key $kyberId is incomplete');
    }

    int? preKeyId;
    Uint8List? preKeyPublic;
    final preKeyIds = await stores.preKey.getAllPreKeyIds();
    preKeyIds.sort();
    for (final id in preKeyIds) {
      final record = await stores.preKey.loadPreKey(id);
      if (record != null) {
        preKeyId = id;
        preKeyPublic = record.publicKey();
        break;
      }
    }

    return PreKeyBundle(
      registrationId: registrationId,
      deviceId: localAddress.deviceId(),
      preKeyId: preKeyId,
      preKeyPublic: preKeyPublic,
      signedPreKeyId: signedId,
      signedPreKeyPublic: signedRecord.publicKey(),
      signedPreKeySignature: signedSig,
      identityKey: identity.publicKey.toList(),
      kyberPreKeyId: kyberId,
      kyberPreKeyPublic: kyberRecord.getPublicKey().serialize(),
      kyberPreKeySignature: kyberSig,
    );
  }

  /// Builds a session to [remote] from their pre-key bundle (X3DH +
  /// PQXDH). After this, [encrypt] can send to them.
  Future<void> buildSession(
    ProtocolAddress remote,
    PreKeyBundle bundle,
  ) async {
    final builder = SessionBuilder(
      localAddress: localAddress,
      sessionStore: stores.session,
      identityKeyStore: stores.identity,
    );
    await builder.processPreKeyBundle(remote, bundle);
  }

  /// Encrypts [plaintext] for [remote]. The first message on a fresh
  /// session is a pre-key message ([CiphertextMessage.isPreKeyMessage]
  /// is true); later ones are regular Signal messages.
  Future<CiphertextMessage> encrypt(
    ProtocolAddress remote,
    Uint8List plaintext,
  ) {
    return _cipher().encrypt(remote, plaintext);
  }

  /// Encrypts UTF-8 [text] for [remote].
  Future<CiphertextMessage> encryptText(ProtocolAddress remote, String text) {
    return encrypt(remote, utf8.encode(text));
  }

  /// Decrypts [message] from [remote], auto-detecting a pre-key
  /// message (first message, establishes the session and consumes the
  /// one-time pre-keys) versus a regular Signal message.
  Future<Uint8List> decrypt(
    ProtocolAddress remote,
    CiphertextMessage message,
  ) {
    return _cipher().decrypt(remote, message);
  }

  /// Decrypts a pre-key message's raw [bytes] from [remote].
  Future<Uint8List> decryptPreKeyMessage(
    ProtocolAddress remote,
    Uint8List bytes,
  ) {
    return _cipher().decryptPreKeyMessage(remote, bytes);
  }

  /// Decrypts a regular Signal message's raw [bytes] from [remote].
  Future<Uint8List> decryptSignalMessage(
    ProtocolAddress remote,
    Uint8List bytes,
  ) {
    return _cipher().decryptSignalMessage(remote, bytes);
  }

  /// Decrypts [message] from [remote] and decodes it as UTF-8 text.
  Future<String> decryptText(
    ProtocolAddress remote,
    CiphertextMessage message,
  ) async {
    return utf8.decode(await decrypt(remote, message));
  }

  /// Generates [count] fresh one-time pre-keys and [count] fresh
  /// one-time Kyber pre-keys, stores the private parts, and returns
  /// the public material to publish (to the server, so senders can
  /// claim them). Ids come from the same monotonic counters as
  /// [generateBundle], so a batch never overwrites keys already
  /// published. Used by the sync layer to top the server up to a
  /// healthy one-time pre-key count without minting a new signed
  /// pre-key for every key.
  Future<({
    List<({int id, Uint8List publicKey})> preKeys,
    List<({int id, Uint8List publicKey, List<int> signature})>
        kyberPreKeys,
  })> generateOneTimePreKeyBatch({required int count}) async {
    final identity = await stores.identity.getIdentityKeyPair();
    final now = BigInt.from(DateTime.now().millisecondsSinceEpoch);
    final preKeys = <({int id, Uint8List publicKey})>[];
    for (var i = 0; i < count; i++) {
      final id = await _nextId('prekey');
      final private = PrivateKey.generate();
      await stores.preKey.storePreKey(
        id,
        PreKeyRecord(
          id: id,
          publicKey: private.getPublicKey(),
          privateKey: private,
        ),
      );
      preKeys.add((id: id, publicKey: private.getPublicKey().serialize()));
    }
    final kyberPreKeys =
        <({int id, Uint8List publicKey, List<int> signature})>[];
    for (var i = 0; i < count; i++) {
      final id = await _nextId('kyberprekey');
      final pair = KyberKeyPair.generate();
      final signature = identity.sign(
        message: pair.getPublicKey().serialize().toList(),
      );
      await stores.kyberPreKey.storeKyberPreKey(
        id,
        KyberPreKeyRecord.create(
          id: id,
          timestamp: now,
          keyPair: pair,
          signature: signature,
        ),
      );
      await stores.kyberPreKey.setKyberPreKeyKind(id, isLastResort: false);
      await stores.kyberPreKey.storeSignature(id, signature);
      kyberPreKeys.add((
        id: id,
        publicKey: pair.getPublicKey().serialize(),
        signature: signature,
      ));
    }
    return (preKeys: preKeys, kyberPreKeys: kyberPreKeys);
  }

  /// Ensures a last-resort Kyber pre-key exists and returns its public
  /// material: a Kyber key that is never consumed, so a bundle always
  /// carries a Kyber pre-key even after every one-time Kyber key is
  /// claimed (libsignal rejects a bundle without one). Returns the
  /// existing last-resort key when one is already stored instead of
  /// minting a second one.
  Future<({int id, Uint8List publicKey, List<int> signature})>
      ensureLastResortKyberPreKey() async {
    final ids = await stores.kyberPreKey.getAllKyberPreKeyIds();
    ids.sort();
    for (final id in ids) {
      if (!await stores.kyberPreKey.isLastResortKyberPreKey(id)) continue;
      final record = await stores.kyberPreKey.loadKyberPreKey(id);
      final signature = await stores.kyberPreKey.loadSignature(id);
      if (record != null && signature != null) {
        return (
          id: id,
          publicKey: record.getPublicKey().serialize(),
          signature: signature,
        );
      }
    }
    final identity = await stores.identity.getIdentityKeyPair();
    final now = BigInt.from(DateTime.now().millisecondsSinceEpoch);
    final id = await _nextId('kyberprekey');
    final pair = KyberKeyPair.generate();
    final signature = identity.sign(
      message: pair.getPublicKey().serialize().toList(),
    );
    await stores.kyberPreKey.storeKyberPreKey(
      id,
      KyberPreKeyRecord.create(
        id: id,
        timestamp: now,
        keyPair: pair,
        signature: signature,
      ),
    );
    await stores.kyberPreKey.setKyberPreKeyKind(id, isLastResort: true);
    await stores.kyberPreKey.storeSignature(id, signature);
    return (
      id: id,
      publicKey: pair.getPublicKey().serialize(),
      signature: signature,
    );
  }

  /// Next id for a pre-key kind: one past the highest id already
  /// stored, so a fresh bundle mints new keys instead of overwriting
  /// the published ones. Starts at 1.
  Future<int> _nextId(String kind) async {
    final existing = switch (kind) {
      'prekey' => await stores.preKey.getAllPreKeyIds(),
      'signedprekey' => await stores.signedPreKey.getAllSignedPreKeyIds(),
      'kyberprekey' => await stores.kyberPreKey.getAllKyberPreKeyIds(),
      _ => <int>[],
    };
    var maxId = 0;
    for (final id in existing) {
      if (id > maxId) maxId = id;
    }
    return maxId + 1;
  }
}
