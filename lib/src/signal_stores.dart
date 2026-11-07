/// Signal Protocol stores persisted on secure storage (spike).
///
/// This file implements all six libsignal store interfaces on a small
/// key-value backend ([SignalKvStore]) so the same store classes run
/// against [FlutterSecureStorage] on a real device and against an
/// in-memory backend in tests. Nothing here is in-memory state that
/// must survive a restart: every record is serialized and written
/// through the backend, and every write is awaited before the store
/// method returns.
///
/// Key layout (all keys are `<prefix>:<kind>:<id>`; values are base64
/// of the record's [serialize] bytes unless noted):
/// - identity key pair: `<prefix>:identity_key_pair`
/// - registration id: `<prefix>:registration_id` (decimal string)
/// - remote identity: `<prefix>:remote_identity:<name>:<deviceId>`
/// - session: `<prefix>:session:<name>:<deviceId>`
/// - one-time pre-key: `<prefix>:prekey:<id>`
/// - signed pre-key: `<prefix>:signedprekey:<id>` (+ signature side key
///   `<prefix>:signedprekey_sig:<id>`, base64)
/// - Kyber pre-key: `<prefix>:kyberprekey:<id>` (+ kind side key
///   `<prefix>:kyberkind:<id>` = `onetime`|`lastresort`, + signature side
///   key `<prefix>:kyberprekey_sig:<id>`, base64)
/// - Kyber used-agreement marker:
///   `<prefix>:kyberused:<kyberId>:<signedId>:<base64(baseKey)>` = `1`
/// - sender key:
///   `<prefix>:senderkey:<name>:<deviceId>:<distributionId>`
///
/// Durability note (from libsignal's own store contracts): a session
/// write that is lost or rolled back rewinds the Double Ratchet and
/// reuses message keys. [FlutterSecureStorage] writes to the platform
/// keystore/keychain, which is durable once the write future completes;
/// the store methods below await every write, and the library awaits
/// the store callbacks before releasing ciphertext/plaintext, so the
/// "persist, then release" ordering holds by construction.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal/libsignal.dart';

/// Minimal async key-value backend the six stores write through.
///
/// Production uses [FlutterSecureStorageKvStore]; tests use an
/// in-memory implementation. The stores never touch platform storage
/// directly, so the persistence logic is identical in both cases.
abstract interface class SignalKvStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<Map<String, String>> readAll();
  Future<bool> containsKey(String key);
}

/// [SignalKvStore] backed by [FlutterSecureStorage].
class FlutterSecureStorageKvStore implements SignalKvStore {
  FlutterSecureStorageKvStore(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<Map<String, String>> readAll() => _storage.readAll();

  @override
  Future<bool> containsKey(String key) => _storage.containsKey(key: key);
}

/// The six Signal stores, wired to one backend under one [prefix].
class SignalStores {
  SignalStores({
    required this.session,
    required this.identity,
    required this.preKey,
    required this.signedPreKey,
    required this.kyberPreKey,
    required this.senderKey,
  });

  final SessionStore session;
  final IdentityKeyStore identity;
  final PreKeyStore preKey;
  final SignalSignedPreKeyStore signedPreKey;
  final SignalKyberPreKeyStore kyberPreKey;
  final SenderKeyStore senderKey;

  /// Wires all six stores to [storage] under [prefix].
  ///
  /// [prefix] namespaces the keys (for example `signal:<userId>`), so
  /// two local users never share a record.
  factory SignalStores.fromSecureStorage(
    FlutterSecureStorage storage, {
    required String prefix,
  }) {
    final backend = FlutterSecureStorageKvStore(storage);
    return SignalStores.fromKvStore(backend, prefix: prefix);
  }

  /// Wires all six stores to an explicit [SignalKvStore] backend.
  factory SignalStores.fromKvStore(
    SignalKvStore backend, {
    required String prefix,
  }) {
    return SignalStores(
      session: SignalSessionStore(backend, prefix: prefix),
      identity: SignalIdentityStore(backend, prefix: prefix),
      preKey: SignalPreKeyStore(backend, prefix: prefix),
      signedPreKey: SignalSignedPreKeyStore(backend, prefix: prefix),
      kyberPreKey: SignalKyberPreKeyStore(backend, prefix: prefix),
      senderKey: SignalSenderKeyStore(backend, prefix: prefix),
    );
  }
}

String _sessionKey(String prefix, ProtocolAddress address) =>
    '$prefix:session:${address.name()}:${address.deviceId()}';

/// [SessionStore] persisted on a [SignalKvStore] backend.
class SignalSessionStore implements SessionStore {
  SignalSessionStore(this._backend, {required this.prefix});

  final SignalKvStore _backend;
  final String prefix;

  @override
  Future<SessionRecord?> loadSession(ProtocolAddress address) async {
    final raw = await _backend.read(_sessionKey(prefix, address));
    if (raw == null) return null;
    return SessionRecord.deserialize(bytes: base64Decode(raw));
  }

  @override
  Future<void> storeSession(
    ProtocolAddress address,
    SessionRecord record,
  ) async {
    await _backend.write(
      _sessionKey(prefix, address),
      base64Encode(record.serialize()),
    );
  }

  @override
  Future<bool> containsSession(ProtocolAddress address) async {
    return _backend.containsKey(_sessionKey(prefix, address));
  }

  @override
  Future<void> deleteSession(ProtocolAddress address) async {
    await _backend.delete(_sessionKey(prefix, address));
  }

  @override
  Future<void> deleteAllSessions(String name) async {
    final all = await _backend.readAll();
    final head = '$prefix:session:$name:';
    for (final key in all.keys) {
      if (key.startsWith(head)) {
        await _backend.delete(key);
      }
    }
  }

  @override
  Future<List<int>> getSubDeviceSessions(String name) async {
    final all = await _backend.readAll();
    final head = '$prefix:session:$name:';
    final ids = <int>[];
    for (final key in all.keys) {
      if (!key.startsWith(head)) continue;
      final id = int.tryParse(key.substring(head.length));
      if (id != null) ids.add(id);
    }
    return ids;
  }
}

/// [IdentityKeyStore] persisted on a [SignalKvStore] backend.
///
/// The identity key pair and registration id are generated lazily on
/// first access and persisted before being returned, so a fresh
/// install self-initializes exactly once.
class SignalIdentityStore implements IdentityKeyStore {
  SignalIdentityStore(this._backend, {required this.prefix});

  final SignalKvStore _backend;
  final String prefix;

  String get _pairKey => '$prefix:identity_key_pair';
  String get _registrationKey => '$prefix:registration_id';
  String _remoteKey(ProtocolAddress address) =>
      '$prefix:remote_identity:${address.name()}:${address.deviceId()}';

  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async {
    final raw = await _backend.read(_pairKey);
    if (raw != null) {
      return IdentityKeyPair.deserialize(bytes: base64Decode(raw));
    }
    final pair = IdentityKeyPair.generate();
    await _backend.write(_pairKey, base64Encode(pair.serialize()));
    return pair;
  }

  @override
  Future<int> getLocalRegistrationId() async {
    final raw = await _backend.read(_registrationKey);
    if (raw != null) {
      final id = int.tryParse(raw);
      if (id != null) return id;
    }
    // Signal registration IDs are 14-bit (1..16383).
    final id = Random.secure().nextInt(16383) + 1;
    await _backend.write(_registrationKey, id.toString());
    return id;
  }

  @override
  Future<bool> saveIdentity(
    ProtocolAddress address,
    PublicKey identityKey,
  ) async {
    final key = _remoteKey(address);
    final encoded = base64Encode(identityKey.serialize());
    final existing = await _backend.read(key);
    if (existing == encoded) return false;
    await _backend.write(key, encoded);
    return true;
  }

  @override
  Future<PublicKey?> getIdentity(ProtocolAddress address) async {
    final raw = await _backend.read(_remoteKey(address));
    if (raw == null) return null;
    return PublicKey.deserialize(bytes: base64Decode(raw));
  }

  @override
  Future<bool> isTrustedIdentity(
    ProtocolAddress address,
    PublicKey identityKey,
    Direction direction,
  ) async {
    // Trust-on-first-use: no stored identity means trusted; a stored
    // one must match byte-for-byte. (The ciphers enforce trust through
    // getIdentity, not this method; this is the documented policy.)
    final stored = await getIdentity(address);
    if (stored == null) return true;
    return base64Encode(stored.serialize()) ==
        base64Encode(identityKey.serialize());
  }
}

/// [PreKeyStore] persisted on a [SignalKvStore] backend.
class SignalPreKeyStore implements PreKeyStore {
  SignalPreKeyStore(this._backend, {required this.prefix});

  final SignalKvStore _backend;
  final String prefix;

  String _key(int id) => '$prefix:prekey:$id';

  @override
  Future<PreKeyRecord?> loadPreKey(int preKeyId) async {
    final raw = await _backend.read(_key(preKeyId));
    if (raw == null) return null;
    return PreKeyRecord.deserialize(bytes: base64Decode(raw));
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record) async {
    await _backend.write(_key(preKeyId), base64Encode(record.serialize()));
  }

  @override
  Future<bool> containsPreKey(int preKeyId) async {
    return _backend.containsKey(_key(preKeyId));
  }

  @override
  Future<void> removePreKey(int preKeyId) async {
    await _backend.delete(_key(preKeyId));
  }

  @override
  Future<List<int>> getAllPreKeyIds() async {
    final all = await _backend.readAll();
    final head = '$prefix:prekey:';
    final ids = <int>[];
    for (final key in all.keys) {
      if (!key.startsWith(head)) continue;
      final id = int.tryParse(key.substring(head.length));
      if (id != null) ids.add(id);
    }
    return ids;
  }
}

/// [SignedPreKeyStore] persisted on a [SignalKvStore] backend.
class SignalSignedPreKeyStore implements SignedPreKeyStore {
  SignalSignedPreKeyStore(this._backend, {required this.prefix});

  final SignalKvStore _backend;
  final String prefix;

  String _key(int id) => '$prefix:signedprekey:$id';
  String _sigKey(int id) => '$prefix:signedprekey_sig:$id';

  @override
  Future<SignedPreKeyRecord?> loadSignedPreKey(int signedPreKeyId) async {
    final raw = await _backend.read(_key(signedPreKeyId));
    if (raw == null) return null;
    return SignedPreKeyRecord.deserialize(bytes: base64Decode(raw));
  }

  @override
  Future<void> storeSignedPreKey(
    int signedPreKeyId,
    SignedPreKeyRecord record,
  ) async {
    await _backend.write(
      _key(signedPreKeyId),
      base64Encode(record.serialize()),
    );
  }

  @override
  Future<bool> containsSignedPreKey(int signedPreKeyId) async {
    return _backend.containsKey(_key(signedPreKeyId));
  }

  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) async {
    await _backend.delete(_key(signedPreKeyId));
    await _backend.delete(_sigKey(signedPreKeyId));
  }

  @override
  Future<List<int>> getAllSignedPreKeyIds() async {
    final all = await _backend.readAll();
    final head = '$prefix:signedprekey:';
    final ids = <int>[];
    for (final key in all.keys) {
      if (!key.startsWith(head)) continue;
      final id = int.tryParse(key.substring(head.length));
      if (id != null) ids.add(id);
    }
    return ids;
  }

  /// Stores the identity signature for a signed pre-key, so a
  /// [PreKeyBundle] can be rebuilt from stored keys (the record
  /// itself exposes no signature getter).
  Future<void> storeSignature(int signedPreKeyId, List<int> signature) async {
    await _backend.write(_sigKey(signedPreKeyId), base64Encode(signature));
  }

  /// Loads the identity signature stored by [storeSignature].
  Future<List<int>?> loadSignature(int signedPreKeyId) async {
    final raw = await _backend.read(_sigKey(signedPreKeyId));
    if (raw == null) return null;
    return base64Decode(raw);
  }
}

/// [KyberPreKeyStore] persisted on a [SignalKvStore] backend.
///
/// One-time vs last-resort kind is remembered in a side key
/// (`kyberkind:<id>`); a key with no kind recorded is treated as
/// one-time (retired when marked used), which is the safe default.
/// The used-agreement triples are recorded under `kyberused:` keys,
/// so a replayed pre-key message is refused with `false`.
class SignalKyberPreKeyStore implements KyberPreKeyStore {
  SignalKyberPreKeyStore(this._backend, {required this.prefix});

  final SignalKvStore _backend;
  final String prefix;

  String _key(int id) => '$prefix:kyberprekey:$id';
  String _kindKey(int id) => '$prefix:kyberkind:$id';
  String _sigKey(int id) => '$prefix:kyberprekey_sig:$id';
  String _usedKey(int kyberPreKeyId, int signedPreKeyId, String baseKeyB64) =>
      '$prefix:kyberused:$kyberPreKeyId:$signedPreKeyId:$baseKeyB64';

  @override
  Future<KyberPreKeyRecord?> loadKyberPreKey(int kyberPreKeyId) async {
    final raw = await _backend.read(_key(kyberPreKeyId));
    if (raw == null) return null;
    return KyberPreKeyRecord.deserialize(bytes: base64Decode(raw));
  }

  @override
  Future<void> storeKyberPreKey(
    int kyberPreKeyId,
    KyberPreKeyRecord record,
  ) async {
    await _backend.write(
      _key(kyberPreKeyId),
      base64Encode(record.serialize()),
    );
  }

  @override
  Future<bool> containsKyberPreKey(int kyberPreKeyId) async {
    return _backend.containsKey(_key(kyberPreKeyId));
  }

  @override
  Future<bool> markKyberPreKeyUsed(
    int kyberPreKeyId,
    int signedPreKeyId,
    PublicKey baseKey,
  ) async {
    // Refuse with false, never by throwing (a store callback that
    // throws panics the Rust worker thread).
    try {
      final marker = _usedKey(
        kyberPreKeyId,
        signedPreKeyId,
        base64Encode(baseKey.serialize()),
      );
      if (await _backend.containsKey(marker)) return false;
      await _backend.write(marker, '1');
      final kind = await _backend.read(_kindKey(kyberPreKeyId));
      if (kind != 'lastresort') {
        // One-time key: retire it so loadKyberPreKey refuses to
        // serve it again. Last-resort keys keep serving; the
        // recorded triples are their replay defence.
        await _backend.delete(_key(kyberPreKeyId));
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> removeKyberPreKey(int kyberPreKeyId) async {
    await _backend.delete(_key(kyberPreKeyId));
    await _backend.delete(_kindKey(kyberPreKeyId));
    await _backend.delete(_sigKey(kyberPreKeyId));
  }

  @override
  Future<List<int>> getAllKyberPreKeyIds() async {
    final all = await _backend.readAll();
    final head = '$prefix:kyberprekey:';
    final ids = <int>[];
    for (final key in all.keys) {
      if (!key.startsWith(head)) continue;
      final id = int.tryParse(key.substring(head.length));
      if (id != null) ids.add(id);
    }
    return ids;
  }

  /// Records whether a Kyber pre-key is one-time (default) or the
  /// last-resort key. Call right after [storeKyberPreKey].
  Future<void> setKyberPreKeyKind(
    int kyberPreKeyId, {
    required bool isLastResort,
  }) async {
    await _backend.write(
      _kindKey(kyberPreKeyId),
      isLastResort ? 'lastresort' : 'onetime',
    );
  }

  /// Stores the identity signature for a Kyber pre-key, so a
  /// [PreKeyBundle] can be rebuilt from stored keys (the record
  /// itself exposes no signature getter).
  Future<void> storeSignature(int kyberPreKeyId, List<int> signature) async {
    await _backend.write(_sigKey(kyberPreKeyId), base64Encode(signature));
  }

  /// Loads the identity signature stored by [storeSignature].
  Future<List<int>?> loadSignature(int kyberPreKeyId) async {
    final raw = await _backend.read(_sigKey(kyberPreKeyId));
    if (raw == null) return null;
    return base64Decode(raw);
  }
}

/// [SenderKeyStore] persisted on a [SignalKvStore] backend.
class SignalSenderKeyStore implements SenderKeyStore {
  SignalSenderKeyStore(this._backend, {required this.prefix});

  final SignalKvStore _backend;
  final String prefix;

  String _key(SenderKeyName name) =>
      '$prefix:senderkey:${name.sender.name()}:${name.sender.deviceId()}:${name.distributionId}';

  @override
  Future<Uint8List?> loadSenderKey(SenderKeyName senderKeyName) async {
    final raw = await _backend.read(_key(senderKeyName));
    if (raw == null) return null;
    return base64Decode(raw);
  }

  @override
  Future<void> storeSenderKey(
    SenderKeyName senderKeyName,
    Uint8List record,
  ) async {
    await _backend.write(_key(senderKeyName), base64Encode(record));
  }
}
