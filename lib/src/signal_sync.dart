/// Signal Protocol sync layer for Helba 1:1 chats (WhatsApp's exact
/// techniques: X3DH + PQXDH session establishment, Double Ratchet).
///
/// Bridges [SignalService] (the protocol) and Supabase (the bundle
/// server): publishes this device's pre-key bundle + one-time/Kyber
/// pre-keys, claims a peer's bundle to build a session, and encrypts /
/// decrypts 1:1 messages. The old E2E (`e2ee.dart`) is untouched — this
/// is the replacement for 1:1 chats; group chats keep the old path.
///
/// Design notes:
/// - Device numbers: libsignal `ProtocolAddress` deviceId must be
///   1..127; Helba device ids are UUID strings. [signalDeviceNumber]
///   maps a device uuid deterministically into 1..127 (FNV-1a hash).
///   Two different devices could theoretically collide; that is a
///   known limitation (documented, not over-engineered) — a collision
///   would surface as undecryptable messages, never a crash.
/// - Bundle storage is behind [SignalBundleStore] so tests can use a
///   fake in-memory store; production uses [SupabaseSignalBundleStore].
/// - All public methods are best-effort and never throw to the UI:
///   they return false/null on failure (no bundle, network error).
/// - [LibSignal.init] is called once (lazily, idempotent) before the
///   first protocol operation; the factory returns null when the
///   native library cannot initialise.
/// - Kyber pre-keys are mandatory in libsignal: a bundle without one
///   is rejected. The server therefore keeps a LAST-RESORT Kyber key
///   (never consumed) per device, so a bundle always carries one;
///   the claim RPC falls back to it when no one-time Kyber key
///   remains. The one-time (X3DH) pre-key is the only truly optional
///   part of a bundle.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal/libsignal.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'e2ee.dart' show getDeviceId;
import 'signal_service.dart';
import 'signal_stores.dart';

/// Deterministic Signal device number (1..127) for a Helba device uuid.
///
/// FNV-1a 32-bit hash of the UTF-8 bytes, mapped into 1..127. Same
/// input always yields the same number, on every device, so both sides
/// of a conversation agree on each other's ProtocolAddress without
/// exchanging the number. Known limitation: two different device uuids
/// can theoretically hash to the same number (1-in-127); the protocol
/// would then conflate their sessions. In practice each account has
/// one phone, and a collision surfaces as undecryptable messages (the
/// permanently-unreadable label), not a crash. Pure: unit-tested.
int signalDeviceNumber(String deviceUuid) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(deviceUuid)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return (hash % 127) + 1;
}

/// Signal message type stored in `messages.signal_msg_type`.
const signalMsgTypePreKey = 'prekey';
const signalMsgTypeSignal = 'signal';

/// True when a message row is a Signal Protocol row (as opposed to an
/// old-E2E row or plaintext): encrypted, with a Signal message type.
/// Signal rows carry their nonce inside the serialized ciphertext, so
/// their `nonce` column is NULL — that is what distinguishes them from
/// old-E2E rows (which always have a nonce). Pure: unit-tested.
bool isSignalMessageRow(Map<String, dynamic> row) {
  if (row['is_encrypted'] != true) return false;
  final type = row['signal_msg_type']?.toString();
  return type == signalMsgTypePreKey || type == signalMsgTypeSignal;
}

/// The Signal message type string for an encrypted [CiphertextMessage].
/// Pure: unit-tested.
String signalMsgTypeOf(CiphertextMessage message) =>
    message.isPreKeyMessage ? signalMsgTypePreKey : signalMsgTypeSignal;

/// Parses a stored `signal_msg_type` back to a [CiphertextMessageType].
/// Returns null for anything else (old rows, garbage). Pure:
/// unit-tested.
CiphertextMessageType? parseSignalMsgType(String? value) {
  return switch (value) {
    signalMsgTypePreKey => CiphertextMessageType.preKey,
    signalMsgTypeSignal => CiphertextMessageType.signal,
    _ => null,
  };
}

/// Key for the locally stored plaintext of a Signal message this
/// device sent.
///
/// The sender is the only party that can ever show its own sent
/// messages: a Signal sender cannot decrypt their own outgoing
/// ciphertext (the sending ratchet has moved on; the session holds
/// the receiving chain for the peer, not the sender's own outgoing
/// message keys). So the plaintext is kept ON-DEVICE ONLY, under a
/// key namespaced away from the protocol stores (`signal:<uid>:...`).
/// It is never sent to the server — the server only ever holds the
/// ciphertext. Pure: unit-tested.
String sentSignalPlaintextKey(String messageId) =>
    'helba:sent-signal:$messageId';

/// On-device-only store for the plaintext of Signal messages this
/// device sent, backed by a [SignalKvStore] (secure storage in
/// production, in-memory in tests). The chat shows an own sent Signal
/// message from this store (see `isOwnSignalRow`); without a stored
/// plaintext it shows the encrypted placeholder, never a decryption
/// failure. Never touches the server.
class SentSignalPlaintextStore {
  SentSignalPlaintextStore(this._backend);

  final SignalKvStore _backend;

  Future<void> save(String messageId, String plaintext) =>
      _backend.write(sentSignalPlaintextKey(messageId), plaintext);

  Future<String?> read(String messageId) =>
      _backend.read(sentSignalPlaintextKey(messageId));
}

/// Key for the persistent per-message Signal decrypt-attempt count.
String signalDecryptAttemptsKey(String messageId) =>
    'helba:signal-decrypt-attempts:$messageId';

/// Key marking that a message already triggered one automatic session
/// heal. A permanently undecryptable row must not rebuild the session
/// — consuming a one-time pre-key — on every chat open.
String signalDecryptHealedKey(String messageId) =>
    'helba:signal-decrypt-healed:$messageId';

/// On-device-only store for Signal decrypt attempts and auto-heal
/// markers, backed by a [SignalKvStore] (secure storage in
/// production, in-memory in tests). The attempt count is persistent
/// so the bounded retry budget ([maxSignalDecryptAttempts]) survives
/// closing and reopening the chat: a row that keeps failing reaches
/// the failed state instead of spinning on "جارٍ فك التشفير…" forever.
/// The heal marker bounds automatic healing to once per message, so
/// a row whose ciphertext is gone for good does not rebuild the
/// session on every open. Never touches the server. Backend errors
/// fall back to an in-memory map, so a storage hiccup never breaks
/// decryption — it only loses persistence for that run.
class SignalDecryptAttemptStore {
  SignalDecryptAttemptStore(this._backend);

  final SignalKvStore _backend;
  final _memoryFallback = <String, String>{};

  Future<String?> _read(String key) async {
    try {
      return await _backend.read(key);
    } catch (_) {
      return _memoryFallback[key];
    }
  }

  Future<void> _write(String key, String value) async {
    try {
      await _backend.write(key, value);
    } catch (_) {
      _memoryFallback[key] = value;
    }
  }

  Future<void> _delete(String key) async {
    try {
      await _backend.delete(key);
    } catch (_) {
      _memoryFallback.remove(key);
    }
  }

  /// Attempts recorded so far for [messageId] (0 when none).
  Future<int> attempts(String messageId) async {
    final raw = await _read(signalDecryptAttemptsKey(messageId));
    return int.tryParse(raw ?? '') ?? 0;
  }

  /// Records one more failed attempt; returns the new count.
  Future<int> recordAttempt(String messageId) async {
    final next = await attempts(messageId) + 1;
    await _write(signalDecryptAttemptsKey(messageId), next.toString());
    return next;
  }

  /// Clears the attempt count (on success, or when the session is
  /// healed so the row gets a fresh budget against it).
  Future<void> clear(String messageId) =>
      _delete(signalDecryptAttemptsKey(messageId));

  /// True when [messageId] already triggered one automatic heal.
  Future<bool> wasHealed(String messageId) async =>
      await _read(signalDecryptHealedKey(messageId)) == '1';

  /// Marks [messageId] as auto-healed.
  Future<void> markHealed(String messageId) =>
      _write(signalDecryptHealedKey(messageId), '1');

  /// Clears the heal marker (on success, or on a manual retry).
  Future<void> clearHealed(String messageId) =>
      _delete(signalDecryptHealedKey(messageId));
}

/// Server-side bundle storage for one Signal device.
///
/// The production implementation is [SupabaseSignalBundleStore]; tests
/// use a fake. All methods are best-effort from the caller's point of
/// view — implementations may throw, and [SignalSync] converts that
/// into a false/null return.
abstract interface class SignalBundleStore {
  /// Upserts this device's bundle row (`signal_bundles`). The signed
  /// pre-key creation time is left to the database default on insert
  /// and unchanged on update.
  Future<void> upsertBundle({
    required String userId,
    required String deviceId,
    required String identityKeyBase64,
    required int registrationId,
    required int signedPreKeyId,
    required String signedPreKeyPublicBase64,
    required String signedPreKeySignatureBase64,
  });

  /// Number of unconsumed one-time pre-keys on the server, capped at
  /// [limit] (only whether the count reaches the refill threshold
  /// matters, so fetching more is wasteful).
  Future<int> countUnconsumedOneTimePreKeys(
    String userId,
    String deviceId, {
    required int limit,
  });

  /// Number of unconsumed one-time Kyber pre-keys on the server
  /// (excluding the last-resort key), capped at [limit].
  Future<int> countUnconsumedKyberPreKeys(
    String userId,
    String deviceId, {
    required int limit,
  });

  /// Uploads one-time pre-keys (`signal_one_time_prekeys`).
  /// Idempotent (upsert on the natural key).
  Future<void> uploadOneTimePreKeys(
    String userId,
    String deviceId,
    List<({int id, Uint8List publicKey})> keys,
  );

  /// Uploads Kyber pre-keys (`signal_kyber_prekeys`). [isLastResort]
  /// marks the key that is never consumed. Idempotent (upsert).
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
  );

  /// Calls the `claim_prekey_bundle` RPC and returns the raw row, or
  /// null when the recipient never published a bundle. The row carries
  /// the bundle fields plus one claimed one-time pre-key and one
  /// claimed Kyber pre-key (NULLs when none remain).
  Future<Map<String, dynamic>?> claimBundle(
    String userId,
    String deviceId,
  );
}

/// [SignalBundleStore] backed by Supabase.
class SupabaseSignalBundleStore implements SignalBundleStore {
  SupabaseSignalBundleStore(this._client);

  final SupabaseClient _client;

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
    await _client.from('signal_bundles').upsert(
      {
        'user_id': userId,
        'device_id': deviceId,
        'identity_key': identityKeyBase64,
        'registration_id': registrationId,
        'signed_prekey_id': signedPreKeyId,
        'signed_prekey_public': signedPreKeyPublicBase64,
        'signed_prekey_signature': signedPreKeySignatureBase64,
        'updated_at': DateTime.now().toIso8601String(),
      },
      onConflict: 'user_id,device_id',
    );
  }

  @override
  Future<int> countUnconsumedOneTimePreKeys(
    String userId,
    String deviceId, {
    required int limit,
  }) async {
    final rows = await _client
        .from('signal_one_time_prekeys')
        .select('prekey_id')
        .eq('user_id', userId)
        .eq('device_id', deviceId)
        .isFilter('consumed_at', null)
        .limit(limit);
    return (rows as List).length;
  }

  @override
  Future<int> countUnconsumedKyberPreKeys(
    String userId,
    String deviceId, {
    required int limit,
  }) async {
    final rows = await _client
        .from('signal_kyber_prekeys')
        .select('prekey_id')
        .eq('user_id', userId)
        .eq('device_id', deviceId)
        .eq('is_last_resort', false)
        .isFilter('consumed_at', null)
        .limit(limit);
    return (rows as List).length;
  }

  @override
  Future<void> uploadOneTimePreKeys(
    String userId,
    String deviceId,
    List<({int id, Uint8List publicKey})> keys,
  ) async {
    if (keys.isEmpty) return;
    await _client.from('signal_one_time_prekeys').upsert(
          keys
              .map((k) => {
                    'user_id': userId,
                    'device_id': deviceId,
                    'prekey_id': k.id,
                    'public_key': base64Encode(k.publicKey),
                  })
              .toList(),
          onConflict: 'user_id,device_id,prekey_id',
        );
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
    if (keys.isEmpty) return;
    await _client.from('signal_kyber_prekeys').upsert(
          keys
              .map((k) => {
                    'user_id': userId,
                    'device_id': deviceId,
                    'prekey_id': k.id,
                    'public_key': base64Encode(k.publicKey),
                    'signature': base64Encode(k.signature),
                    'is_last_resort': k.isLastResort,
                  })
              .toList(),
          onConflict: 'user_id,device_id,prekey_id',
        );
  }

  @override
  Future<Map<String, dynamic>?> claimBundle(
    String userId,
    String deviceId,
  ) async {
    final res = await _client.rpc(
      'claim_prekey_bundle',
      params: {'p_user_id': userId, 'p_device_id': deviceId},
    );
    if (res is List && res.isNotEmpty && res.first is Map) {
      return Map<String, dynamic>.from(res.first as Map);
    }
    if (res is Map) return Map<String, dynamic>.from(res);
    return null;
  }
}

/// 1:1 Signal sync for one local device.
///
/// Owns a [SignalService] (protocol state in secure storage) and a
/// [SignalBundleStore] (the server). Construct with [forCurrentUser]
/// in the app; tests construct it directly with an in-memory store
/// backend and a fake bundle store.
class SignalSync {
  SignalSync({
    required this.service,
    required this.store,
    required this.userId,
    required this.deviceUuid,
    required this.sentPlaintexts,
    required this.decryptAttempts,
  });

  final SignalService service;
  final SignalBundleStore store;
  final String userId;
  final String deviceUuid;

  /// On-device-only plaintexts of Signal messages this device sent.
  final SentSignalPlaintextStore sentPlaintexts;

  /// On-device-only Signal decrypt attempts and auto-heal markers.
  final SignalDecryptAttemptStore decryptAttempts;

  /// Serializes Signal operations per peer address: a session build
  /// (claim + `processPreKeyBundle`) and a decrypt (`decryptPreKey`
  /// / `decryptSignal`) for the SAME peer must not interleave, or the
  /// session store can be left mid-write and the first pre-key
  /// message fails to decrypt on arrival (the 13:27 race: both phones
  /// built sessions at the same moment). The protocol itself handles
  /// simultaneous initiation fine when operations are sequential
  /// (verified by test); this lock keeps them sequential on-device.
  /// Each operation waits only for the previous one for that peer to
  /// finish (success or failure) — a failure never blocks the queue.
  final Map<String, Future<void>> _peerQueues = {};

  String _peerKey(String peerUserId, String peerDeviceUuid) =>
      '$peerUserId::$peerDeviceUuid';

  Future<T> _withPeerLock<T>(
    String peerKey,
    Future<T> Function() task,
  ) async {
    final previous = _peerQueues[peerKey];
    final done = Completer<void>();
    _peerQueues[peerKey] = done.future;
    if (previous != null) {
      try {
        await previous;
      } catch (_) {
        // The previous operation's own caller saw its error; the
        // queue itself always completes normally.
      }
    }
    try {
      return await task();
    } finally {
      if (identical(_peerQueues[peerKey], done.future)) {
        _peerQueues.remove(peerKey);
      }
      done.complete();
    }
  }

  static bool _libSignalReady = false;

  static Future<bool> _ensureLibSignalInit() async {
    if (_libSignalReady) return true;
    try {
      await LibSignal.init();
      _libSignalReady = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Wires a [SignalSync] for the currently signed-in user, or null
  /// when there is no signed-in user or the native library cannot
  /// initialise. The Signal identity is namespaced per user
  /// (`signal:<userId>`) and the local device number is derived from
  /// this install's device uuid.
  static Future<SignalSync?> forCurrentUser({
    SupabaseClient? client,
    FlutterSecureStorage? storage,
  }) async {
    final supabase = client ?? Supabase.instance.client;
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return null;
    if (!await _ensureLibSignalInit()) return null;
    final deviceUuid = await getDeviceId();
    final secureStorage = storage ?? const FlutterSecureStorage();
    final service = SignalService.fromSecureStorage(
      storage: secureStorage,
      prefix: 'signal:$uid',
      localName: uid,
      localDeviceId: signalDeviceNumber(deviceUuid),
    );
    return SignalSync(
      service: service,
      store: SupabaseSignalBundleStore(supabase),
      userId: uid,
      deviceUuid: deviceUuid,
      sentPlaintexts: SentSignalPlaintextStore(
        FlutterSecureStorageKvStore(secureStorage),
      ),
      decryptAttempts: SignalDecryptAttemptStore(
        FlutterSecureStorageKvStore(secureStorage),
      ),
    );
  }

  /// ProtocolAddress for a peer device.
  ProtocolAddress addressFor(String peerUserId, String peerDeviceUuid) =>
      ProtocolAddress(
        name: peerUserId,
        deviceId: signalDeviceNumber(peerDeviceUuid),
      );

  /// Publishes this device's bundle and tops up one-time pre-keys.
  /// Best-effort: never throws (a publish failure is logged by the
  /// caller via the returned bool when it matters — here it is
  /// swallowed because the chat must open even when offline; the next
  /// chat open retries).
  ///
  /// - Rebuilds the bundle from stored keys, or generates a first
  ///   bundle on a fresh install, and upserts it.
  /// - Ensures a last-resort Kyber pre-key exists and uploads it.
  /// - Tops one-time pre-keys up to [minOneTimePreKeys] and one-time
  ///   Kyber pre-keys up to [minKyberPreKeys] (one batch mints both
  ///   kinds, sized to the larger shortfall).
  Future<void> ensurePublished({
    int minOneTimePreKeys = 100,
    int minKyberPreKeys = 20,
  }) async {
    try {
      PreKeyBundle bundle;
      try {
        bundle = await service.buildBundleFromStoredKeys();
      } catch (_) {
        bundle = await service.generateBundle();
      }
      await store.upsertBundle(
        userId: userId,
        deviceId: deviceUuid,
        identityKeyBase64: base64Encode(bundle.identityKey()),
        registrationId: bundle.registrationId(),
        signedPreKeyId: bundle.signedPreKeyId(),
        signedPreKeyPublicBase64:
            base64Encode(bundle.signedPreKeyPublic()),
        signedPreKeySignatureBase64:
            base64Encode(bundle.signedPreKeySignature()),
      );

      final lastResort = await service.ensureLastResortKyberPreKey();
      await store.uploadKyberPreKeys(userId, deviceUuid, [
        (
          id: lastResort.id,
          publicKey: lastResort.publicKey,
          signature: lastResort.signature,
          isLastResort: true,
        ),
      ]);

      final oneTimeCount = await store.countUnconsumedOneTimePreKeys(
        userId,
        deviceUuid,
        limit: minOneTimePreKeys,
      );
      final kyberCount = await store.countUnconsumedKyberPreKeys(
        userId,
        deviceUuid,
        limit: minKyberPreKeys,
      );
      final oneTimeNeeded = minOneTimePreKeys - oneTimeCount;
      final kyberNeeded = minKyberPreKeys - kyberCount;
      final batchSize = oneTimeNeeded > kyberNeeded
          ? oneTimeNeeded
          : kyberNeeded;
      if (batchSize > 0) {
        final batch = await service.generateOneTimePreKeyBatch(
          count: batchSize,
        );
        await store.uploadOneTimePreKeys(userId, deviceUuid, batch.preKeys);
        await store.uploadKyberPreKeys(
          userId,
          deviceUuid,
          batch.kyberPreKeys
              .map((k) => (
                    id: k.id,
                    publicKey: k.publicKey,
                    signature: k.signature,
                    isLastResort: false,
                  ))
              .toList(),
        );
      }
    } catch (_) {
      // Best-effort: publishing must never break opening a chat.
    }
  }

  /// Fetches a peer's pre-key bundle via the claim RPC and maps it to
  /// a libsignal [PreKeyBundle]. Returns null when the peer never
  /// published a bundle, when the bundle is incomplete (no Kyber
  /// pre-key — libsignal rejects a bundle without one), or on any
  /// error. The one-time pre-key is optional and omitted when the RPC
  /// returned NULL for it. Claiming consumes one one-time pre-key and
  /// one one-time Kyber pre-key on the server (or the last-resort
  /// Kyber key when none remains).
  Future<PreKeyBundle?> fetchPreKeyBundle(
    String recipientUserId,
    String recipientDeviceUuid,
  ) async {
    try {
      final row = await store.claimBundle(
        recipientUserId,
        recipientDeviceUuid,
      );
      if (row == null) return null;
      final identityKey = _decodeBase64(row['identity_key']);
      final registrationId = _asInt(row['registration_id']);
      final signedId = _asInt(row['signed_prekey_id']);
      final signedPublic = _decodeBase64(row['signed_prekey_public']);
      final signedSig = _decodeBase64(row['signed_prekey_signature']);
      final kyberId = _asInt(row['kyber_prekey_id']);
      final kyberPublic = _decodeBase64(row['kyber_prekey_public']);
      final kyberSig = _decodeBase64(row['kyber_prekey_signature']);
      if (identityKey == null ||
          registrationId == null ||
          signedId == null ||
          signedPublic == null ||
          signedSig == null ||
          kyberId == null ||
          kyberPublic == null ||
          kyberSig == null) {
        return null;
      }
      final preKeyId = _asInt(row['prekey_id']);
      final preKeyPublic = _decodeBase64(row['prekey_public']);
      final hasOneTime = preKeyId != null && preKeyPublic != null;
      return PreKeyBundle(
        registrationId: registrationId,
        deviceId: signalDeviceNumber(recipientDeviceUuid),
        preKeyId: hasOneTime ? preKeyId : null,
        preKeyPublic: hasOneTime ? preKeyPublic : null,
        signedPreKeyId: signedId,
        signedPreKeyPublic: signedPublic,
        signedPreKeySignature: signedSig,
        identityKey: identityKey,
        kyberPreKeyId: kyberId,
        kyberPreKeyPublic: kyberPublic,
        kyberPreKeySignature: kyberSig,
      );
    } catch (_) {
      return null;
    }
  }

  /// True when a usable session already exists for the peer device.
  Future<bool> hasSessionFor(
    String recipientUserId,
    String recipientDeviceUuid,
  ) async {
    try {
      return await service.stores.session.containsSession(
        addressFor(recipientUserId, recipientDeviceUuid),
      );
    } catch (_) {
      return false;
    }
  }

  /// Ensures a session exists for the peer device: returns true at
  /// once when one is already stored, otherwise claims the peer's
  /// bundle and builds a session from it (X3DH + PQXDH). Returns
  /// false when the peer never published a bundle or on any error —
  /// never throws. A sender can therefore encrypt for a recipient who
  /// is OFFLINE, with no manual reset. Serialized per peer (see
  /// [_withPeerLock]) so it cannot interleave with a decrypt for the
  /// same peer.
  Future<bool> ensureSessionFor(
    String recipientUserId,
    String recipientDeviceUuid,
  ) {
    return _withPeerLock(
      _peerKey(recipientUserId, recipientDeviceUuid),
      () => _ensureSessionForInternal(
        recipientUserId,
        recipientDeviceUuid,
      ),
    );
  }

  /// The unlocked session-ensure logic. Called directly only by
  /// [ensureSessionFor] and [encryptFor], which already hold the
  /// peer lock — never call it from outside the lock.
  Future<bool> _ensureSessionForInternal(
    String recipientUserId,
    String recipientDeviceUuid,
  ) async {
    try {
      final address = addressFor(recipientUserId, recipientDeviceUuid);
      if (await service.stores.session.containsSession(address)) {
        return true;
      }
      final bundle =
          await fetchPreKeyBundle(recipientUserId, recipientDeviceUuid);
      if (bundle == null) return false;
      await service.buildSession(address, bundle);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Encrypts [plaintext] for the peer device. Returns the base64
  /// Signal ciphertext plus whether it is a pre-key message (the
  /// first message on a fresh session), or null when no session can
  /// be established. Never throws. The ensure + encrypt run under
  /// one peer lock so a concurrent decrypt cannot interleave with
  /// the session ratchet.
  Future<({String ciphertextBase64, bool isPreKeyMessage})?> encryptFor(
    String recipientUserId,
    String recipientDeviceUuid,
    String plaintext,
  ) {
    return _withPeerLock(
      _peerKey(recipientUserId, recipientDeviceUuid),
      () async {
        try {
          final ready = await _ensureSessionForInternal(
            recipientUserId,
            recipientDeviceUuid,
          );
          if (!ready) return null;
          final address =
              addressFor(recipientUserId, recipientDeviceUuid);
          final message = await service.encryptText(address, plaintext);
          return (
            ciphertextBase64: base64Encode(message.ciphertext),
            isPreKeyMessage: message.isPreKeyMessage,
          );
        } catch (_) {
          return null;
        }
      },
    );
  }

  /// Decrypts a Signal message from the peer device. [isPreKeyMessage]
  /// selects the pre-key vs regular Signal decryption; when that
  /// fails, the other type is tried once (a stored type can be stale).
  /// Returns the plaintext, or null on failure. Never throws to the UI.
  /// Serialized per peer (see [_withPeerLock]) so it cannot interleave
  /// with a session build for the same peer.
  ///
  /// A failed attempt does NOT poison a later retry: the one-time
  /// pre-key is only consumed on a successful decrypt, so a transient
  /// failure (e.g. the simultaneous-initiation race) can be retried
  /// and still succeeds — verified by test.
  Future<String?> decryptFrom(
    String senderUserId,
    String senderDeviceUuid,
    String ciphertextBase64,
    bool isPreKeyMessage,
  ) {
    return _withPeerLock(
      _peerKey(senderUserId, senderDeviceUuid),
      () async {
        try {
          final bytes = base64Decode(ciphertextBase64);
          final address = addressFor(senderUserId, senderDeviceUuid);
          final firstType = isPreKeyMessage
              ? CiphertextMessageType.preKey
              : CiphertextMessageType.signal;
          final secondType = isPreKeyMessage
              ? CiphertextMessageType.signal
              : CiphertextMessageType.preKey;
          try {
            final plain = await service.decrypt(
              address,
              CiphertextMessage(type: firstType, ciphertext: bytes),
            );
            return utf8.decode(plain);
          } catch (_) {
            final plain = await service.decrypt(
              address,
              CiphertextMessage(type: secondType, ciphertext: bytes),
            );
            return utf8.decode(plain);
          }
        } catch (_) {
          return null;
        }
      },
    );
  }

  /// Deletes the session for a peer device (the reset action for a
  /// 1:1 Signal chat): the next send establishes a fresh session from
  /// the peer's current bundle. Best-effort, never throws.
  Future<void> resetSessionFor(
    String recipientUserId,
    String recipientDeviceUuid,
  ) {
    return _withPeerLock(
      _peerKey(recipientUserId, recipientDeviceUuid),
      () async {
        try {
          await service.stores.session.deleteSession(
            addressFor(recipientUserId, recipientDeviceUuid),
          );
        } catch (_) {}
      },
    );
  }

  /// Heals a desynced session for a peer device: deletes the current
  /// (mismatched) session, then rebuilds it from the peer's current
  /// bundle — all under one peer lock, so no decrypt can interleave
  /// between the delete and the rebuild. Returns true when a session
  /// is now stored. Best-effort, never throws.
  ///
  /// The already-failed messages stay undecryptable (they were
  /// encrypted under the lost session); the heal is for NEW messages,
  /// whose first send after the heal is a pre-key message that
  /// re-syncs the peer.
  Future<bool> healSessionFor(
    String recipientUserId,
    String recipientDeviceUuid,
  ) {
    return _withPeerLock(
      _peerKey(recipientUserId, recipientDeviceUuid),
      () async {
        try {
          await service.stores.session.deleteSession(
            addressFor(recipientUserId, recipientDeviceUuid),
          );
        } catch (_) {}
        return _ensureSessionForInternal(
          recipientUserId,
          recipientDeviceUuid,
        );
      },
    );
  }
}

Uint8List? _decodeBase64(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  try {
    return base64Decode(trimmed);
  } catch (_) {
    return null;
  }
}

/// Reads a JSON number as an int (PostgREST may return ints as int or,
/// for large values, as double). Returns null for anything else.
int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}
