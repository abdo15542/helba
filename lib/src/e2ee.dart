// HELBA end-to-end encryption (Feature 6).
//
// HONEST LIMITS — read before trusting this:
//   * Simplified sender-key style scheme, NOT the Signal protocol.
//   * No forward secrecy and no ratchet: one AES-256-GCM conversation key
//     per conversation, shared by all members. If a member's device (or a
//     wrapped key row) is compromised, past messages encrypted with that
//     conversation key can be read.
//   * No group key rotation: when a member leaves, the key is NOT rotated,
//     so a removed member who kept the key can still decrypt messages sent
//     afterwards. (Membership removal only stops them receiving new rows.)
//   * Messages sent before a member had a key are plaintext, and stay
//     plaintext; a member who joins later cannot decrypt messages sent
//     before anyone wrapped the key for them.
//   * Attachments (files in Storage) are NOT end-to-end encrypted by this
//     scheme — only text message bodies are. sendAttachment() is unchanged.
//     The UI label for that (finding #29) is the chat agent's job
//     (chat.dart), not this file's.
//   * The server still sees who talks to whom, when, and message metadata;
//     only the text body is opaque to it.
//
// How it works:
//   * Each device holds one X25519 keypair. The private key never leaves
//     the device (flutter_secure_storage); the public key is published to
//     profiles.public_key.
//   * Each conversation has one random 32-byte AES-256-GCM key. It is
//     wrapped (AES-256-GCM, fresh nonce) once per member with a
//     key-encryption key derived from the X25519 shared secret between the
//     wrapper and that member (HKDF-SHA256, info
//     'helba-e2e-kek-v1:<conversationId>'), and
//     stored in public.conversation_keys (one row per member, RLS: each
//     user reads only their own row). Rows wrapped by the pre-fix code
//     used the unbound info 'helba-e2e-kek-v1'; unwrapConversationKey()
//     falls back to that legacy KEK once when the bound KEK fails, so
//     existing encrypted conversations keep working. New wraps always
//     use the conversation-bound KEK.
//   * Message storage format (defined in exactly one place, here):
//     messages.nonce = base64(12-byte random GCM nonce, fresh per message)
//     messages.ciphertext = base64(cipherText || mac) where mac is the
//     16-byte GCM tag appended to the raw ciphertext. decryptText() splits
//     the last 16 bytes back off as the tag.
//     messages.body = the constant placeholder '🔒 رسالة مشفّرة' — never
//     plaintext (the messages CHECK requires a non-empty body, and a
//     plaintext preview would leak content to the server).
//   * Wrapped-key storage format: conversation_keys.wrapped_key =
//     base64(nonce || cipherText || mac) with the same 12-byte nonce and
//     16-byte tag layout (nonce first, so unwrap can split it off).

import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';

/// Constant body stored for encrypted messages — never plaintext.
const encryptedMessagePlaceholder = '🔒 رسالة مشفّرة';

const _privateKeyStorageKey = 'helba_e2e_private_key';

/// HKDF info string binding the derived key-encryption key to this app
/// and scheme version. Changing it makes old wrapped keys undecryptable
/// (see the legacy fallback in [unwrapConversationKey]).
const _kekInfo = 'helba-e2e-kek-v1';

/// HKDF info for a conversation: the KEK is bound to the conversation
/// id (finding #26), so a wrapped row cannot be transplanted into another
/// conversation and one pairwise KEK compromise does not expose every
/// conversation between the same two users. A null/empty id keeps the
/// legacy unbound info, for callers (and tests) that predate binding.
String _kekInfoFor(String? conversationId) =>
    conversationId == null || conversationId.isEmpty
        ? _kekInfo
        : '$_kekInfo:$conversationId';

/// Thrown by [decryptText] when the stored row is malformed — missing
/// ciphertext/nonce, invalid base64, a nonce of the wrong length, or a
/// ciphertext shorter than the GCM tag — as opposed to a wrong key or
/// tampered data (which throws [SecretBoxAuthenticationError]).
///
/// Extends [FormatException], so existing `catch (FormatException)`
/// handlers still work; the UI layer can distinguish it with
/// `is MalformedEncryptedMessageException` and show "رسالة تالفة"
/// instead of "تعذّر فك تشفير هذه الرسالة" (finding #30).
class MalformedEncryptedMessageException extends FormatException {
  const MalformedEncryptedMessageException([
    super.message = 'malformed encrypted message',
  ]);
}

/// True only when [key] is a usable X25519 public key: valid base64
/// decoding to exactly 32 bytes. Any other non-empty string (a truncated
/// profile value, a typo, a key from another scheme) is NOT usable —
/// [canEncryptFor] and [wrapKeyForMembers] reject it instead of silently
/// excluding that member forever (finding #24). Never logs the key.
bool isValidPublicKey(String? key) {
  if (key == null) return false;
  final trimmed = key.trim();
  if (trimmed.isEmpty) return false;
  try {
    return decodeBase64(trimmed).length == 32;
  } catch (_) {
    return false;
  }
}

/// GCM tag (MAC) length in bytes, appended to the ciphertext.
const _gcmTagLength = 16;

/// GCM nonce length in bytes (12, the default for AES-GCM).
const _aesGcmNonceLength = 12;

final _x25519 = X25519();
final _aesGcm = AesGcm.with256bits();
final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

// ---------------------------------------------------------------------------
// Pure helpers (no Supabase; unit-tested in test/widget_test.dart).
// ---------------------------------------------------------------------------

String encodeBase64(List<int> bytes) => base64Encode(bytes);

List<int> decodeBase64(String value) => base64Decode(value);

/// True when a message row carries an encrypted body.
bool isEncryptedMessage(Map<String, dynamic> row) {
  if (row['is_encrypted'] == true) return true;
  final ciphertext = row['ciphertext'];
  return ciphertext is String && ciphertext.isNotEmpty;
}

/// True only when EVERY member (including me) has a valid public key
/// (see [isValidPublicKey]: base64, exactly 32 bytes). An empty member
/// list can never be encrypted (nothing proves who the members even
/// are). NOTE: a placeholder string such as 'key-a' is NOT valid — the
/// pre-fix test matrix that treated any non-empty string as a key is
/// outdated; see test/e2ee_push_fix_test.dart.
bool canEncryptFor(Map<String, String?> memberPublicKeys) {
  if (memberPublicKeys.isEmpty) return false;
  return memberPublicKeys.values.every(isValidPublicKey);
}

/// A fresh random 32-byte conversation key.
List<int> generateConversationKey() {
  final bytes = Uint8List(32);
  final random = Random.secure();
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes;
}

/// Derives the 32-byte key-encryption key from a raw X25519 shared secret
/// with HKDF-SHA256. When [conversationId] is given, the HKDF info is
/// `helba-e2e-kek-v1:<conversationId>` (finding #26: the KEK is bound to
/// the conversation); without it the legacy unbound info is used, so
/// pre-binding callers and tests keep working. The raw shared secret is
/// never used directly as an encryption key.
Future<List<int>> deriveKeyEncryptionKey(
  List<int> sharedSecretBytes, {
  String? conversationId,
}) async {
  final derived = await _hkdf.deriveKey(
    secretKey: SecretKeyData(sharedSecretBytes),
    nonce: const <int>[],
    info: utf8.encode(_kekInfoFor(conversationId)),
  );
  return derived.extractBytes();
}

/// X25519 shared secret between my private key and their public key.
/// The two sides compute the same bytes (tested: symmetry).
///
/// Validates the peer key first (finding #28): it must be valid base64
/// decoding to exactly 32 bytes, otherwise a clear [FormatException]
/// is thrown instead of a cryptic failure deep inside the X25519 call.
/// A single garbage profiles.public_key must not silently poison every
/// wrap/unwrap that touches it.
Future<List<int>> deriveSharedSecret(
  List<int> myPrivateKeyBytes,
  String theirPublicKeyBase64,
) async {
  List<int> theirPublicKeyBytes;
  try {
    theirPublicKeyBytes = decodeBase64(theirPublicKeyBase64.trim());
  } catch (_) {
    throw const FormatException(
      'Invalid peer public key: not valid base64 (expected a 32-byte '
      'X25519 public key)',
    );
  }
  if (theirPublicKeyBytes.length != 32) {
    throw FormatException(
      'Invalid peer public key: decoded to '
      '${theirPublicKeyBytes.length} bytes, expected 32 (X25519)',
    );
  }
  final keyPair =
      await _x25519.newKeyPairFromSeed(myPrivateKeyBytes);
  final theirPublicKey = SimplePublicKey(
    theirPublicKeyBytes,
    type: KeyPairType.x25519,
  );
  final shared = await _x25519.sharedSecretKey(
    keyPair: keyPair,
    remotePublicKey: theirPublicKey,
  );
  return shared.extractBytes();
}

/// Wraps a conversation key for one recipient: AES-256-GCM under the KEK
/// derived from my private key + their public key. Result is
/// base64(nonce || cipherText || mac) with a fresh random nonce.
/// Throws on bad input; callers treat failure as "cannot wrap for them".
/// When [conversationId] is given the KEK is bound to that conversation
/// (finding #26); new wraps should always pass it.
Future<String> wrapConversationKey(
  List<int> convKeyBytes,
  List<int> myPrivateKeyBytes,
  String theirPublicKeyBase64, {
  String? conversationId,
}) async {
  final shared =
      await deriveSharedSecret(myPrivateKeyBytes, theirPublicKeyBase64);
  final kek =
      await deriveKeyEncryptionKey(shared, conversationId: conversationId);
  final box = await _aesGcm.encrypt(
    convKeyBytes,
    secretKey: SecretKeyData(kek),
  );
  final out = Uint8List(
      _aesGcmNonceLength + box.cipherText.length + box.mac.bytes.length);
  out.setAll(0, box.nonce);
  out.setAll(_aesGcmNonceLength, box.cipherText);
  out.setAll(_aesGcmNonceLength + box.cipherText.length, box.mac.bytes);
  return base64Encode(out);
}

/// Unwraps a conversation key wrapped for me: the wrapper's public key is
/// needed to derive the same shared secret. Throws (including
/// SecretBoxAuthenticationError) on a wrong key or tampered data — callers
/// treat any throw as "cannot decrypt".
///
/// When [conversationId] is given, the conversation-bound KEK is tried
/// first; if that fails, the legacy unbound KEK ('helba-e2e-kek-v1') is
/// tried once, so wrapped rows created before conversation binding
/// (finding #26) keep unwrapping. This fallback is deliberate and
/// documented — it is what makes the KEK change non-breaking for
/// existing encrypted conversations. Without [conversationId] only the
/// legacy KEK is tried (pre-binding behaviour).
///
/// Pass [legacyFallback] false to try ONLY the bound KEK: callers that
/// need to know which KEK worked (see [unwrapWrappedKeyWithFallback])
/// disable the silent fallback here and attempt the legacy KEK
/// explicitly as a second, separately reported step.
Future<List<int>> unwrapConversationKey(
  String wrappedBase64,
  List<int> myPrivateKeyBytes,
  String wrapperPublicKeyBase64, {
  String? conversationId,
  bool legacyFallback = true,
}) async {
  final wrapped = decodeBase64(wrappedBase64);
  if (wrapped.length <= _aesGcmNonceLength + _gcmTagLength) {
    throw const FormatException('Wrapped key too short');
  }
  final nonce = wrapped.sublist(0, _aesGcmNonceLength);
  final cipherAndTag = wrapped.sublist(_aesGcmNonceLength);
  final cipherText =
      cipherAndTag.sublist(0, cipherAndTag.length - _gcmTagLength);
  final mac = Mac(cipherAndTag.sublist(cipherAndTag.length - _gcmTagLength));
  final shared =
      await deriveSharedSecret(myPrivateKeyBytes, wrapperPublicKeyBase64);
  Future<List<int>> tryUnwrap({String? convId}) async {
    final kek =
        await deriveKeyEncryptionKey(shared, conversationId: convId);
    return _aesGcm.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: mac),
      secretKey: SecretKeyData(kek),
    );
  }

  if (conversationId == null || conversationId.isEmpty) {
    return tryUnwrap();
  }
  try {
    return await tryUnwrap(convId: conversationId);
  } catch (_) {
    // Bound KEK failed: this row may predate conversation binding.
    // One legacy attempt; its error (if any) is the one reported —
    // unless the caller disabled the silent fallback so it can report
    // the legacy origin itself (see unwrapWrappedKeyWithFallback).
    if (!legacyFallback) rethrow;
    return tryUnwrap();
  }
}

/// Unwraps a wrapped conversation key, trying the conversation-bound KEK
/// first and the legacy unbound KEK second, and reports which one
/// worked. Pure (no Supabase): unit-tested.
///
/// The bound attempt is made with the silent fallback disabled, so a
/// legacy success is observable: [fromLegacy] is true exactly when the
/// row was wrapped before conversation binding (finding #26). Callers
/// use that to heal the row (re-wrap it with the bound KEK) instead of
/// leaving a pre-binding row in place forever. Throws
/// (including [SecretBoxAuthenticationError]) when neither KEK unwraps
/// — i.e. the row is corrupt, or was wrapped for a different key.
Future<({List<int> key, bool fromLegacy})> unwrapWrappedKeyWithFallback(
  String wrappedBase64,
  List<int> myPrivateKeyBytes,
  String wrapperPublicKeyBase64,
  String conversationId,
) async {
  try {
    final key = await unwrapConversationKey(
      wrappedBase64,
      myPrivateKeyBytes,
      wrapperPublicKeyBase64,
      conversationId: conversationId,
      legacyFallback: false,
    );
    return (key: key, fromLegacy: false);
  } catch (_) {
    // Bound KEK failed: one explicit legacy attempt (no conversation
    // id => unbound KEK). Its error, if any, is the one reported.
    final key = await unwrapConversationKey(
      wrappedBase64,
      myPrivateKeyBytes,
      wrapperPublicKeyBase64,
    );
    return (key: key, fromLegacy: true);
  }
}

/// Encrypts one text message body with the conversation key.
/// Returns the stored format: ciphertext = base64(cipherText || mac)
/// (16-byte GCM tag appended) and nonce = base64(12-byte fresh nonce).
Future<({String ciphertext, String nonce})> encryptText(
  String plaintext,
  List<int> convKeyBytes,
) async {
  final box = await _aesGcm.encrypt(
    utf8.encode(plaintext),
    secretKey: SecretKeyData(convKeyBytes),
  );
  final cipherAndTag = Uint8List(box.cipherText.length + box.mac.bytes.length);
  cipherAndTag.setAll(0, box.cipherText);
  cipherAndTag.setAll(box.cipherText.length, box.mac.bytes);
  return (
    ciphertext: base64Encode(cipherAndTag),
    nonce: base64Encode(box.nonce),
  );
}

/// Decrypts a message body stored by [encryptText]. Splits the last 16
/// bytes of the ciphertext back off as the GCM tag. Throws
/// (SecretBoxAuthenticationError on a wrong key or tampered data,
/// [MalformedEncryptedMessageException] — a [FormatException] — on
/// malformed input, finding #30) — callers show
/// 'تعذّر فك تشفير هذه الرسالة' instead of the body, and can show
/// 'رسالة تالفة' for the malformed case.
Future<String> decryptText(
  String ciphertextBase64,
  String nonceBase64,
  List<int> convKeyBytes,
) async {
  // Pre-validate (finding #30): a row with a missing/empty ciphertext or
  // nonce, invalid base64, or a wrong-length nonce is malformed, not a
  // wrong key — report it distinctly instead of letting it surface as a
  // generic decrypt failure.
  if (ciphertextBase64.trim().isEmpty || nonceBase64.trim().isEmpty) {
    throw const MalformedEncryptedMessageException(
      'malformed encrypted message: missing ciphertext or nonce',
    );
  }
  List<int> cipherAndTag;
  List<int> nonceBytes;
  try {
    cipherAndTag = decodeBase64(ciphertextBase64.trim());
    nonceBytes = decodeBase64(nonceBase64.trim());
  } on FormatException {
    throw const MalformedEncryptedMessageException(
      'malformed encrypted message: ciphertext or nonce is not valid base64',
    );
  }
  if (cipherAndTag.length < _gcmTagLength) {
    throw const MalformedEncryptedMessageException(
      'malformed encrypted message: ciphertext too short',
    );
  }
  if (nonceBytes.length != _aesGcmNonceLength) {
    throw MalformedEncryptedMessageException(
      'malformed encrypted message: nonce is ${nonceBytes.length} bytes, '
      'expected $_aesGcmNonceLength',
    );
  }
  final cipherText =
      cipherAndTag.sublist(0, cipherAndTag.length - _gcmTagLength);
  final mac = Mac(cipherAndTag.sublist(cipherAndTag.length - _gcmTagLength));
  final plain = await _aesGcm.decrypt(
    SecretBox(cipherText, nonce: nonceBytes, mac: mac),
    secretKey: SecretKeyData(convKeyBytes),
  );
  return utf8.decode(plain);
}

// ---------------------------------------------------------------------------
// Keypair management (secure storage + profiles.public_key).
// ---------------------------------------------------------------------------

/// Memoised in-flight/completed keypair load (finding #22): concurrent
/// callers share one [Future], so two racing callers can never generate
/// two different keypairs. Cleared on failure so a later call retries.
Future<SimpleKeyPair>? _pairFuture;

/// True when the stored private key was corrupt and [ensureKeyPair]
/// generated a replacement pair. The profile's public key then has to be
/// republished (see [publishPublicKeyIfNeeded], which now compares
/// instead of only filling an empty slot). Stays true until a publish
/// succeeds, so a failed (e.g. offline) republish is retried by the
/// next [publishPublicKeyIfNeeded] call instead of being forgotten.
bool _keyWasReplaced = false;

/// Whether the local keypair was replaced because the stored private key
/// was corrupt/unparseable. Callers (chat) can use this to force a
/// [publishPublicKeyIfNeeded] after [ensureKeyPair]; the publish itself
/// is also attempted inside [ensureKeyPair] (best-effort) and retried by
/// [publishPublicKeyIfNeeded] whenever the profile key differs.
bool get e2eKeyWasReplaced => _keyWasReplaced;

/// Loads my X25519 keypair from secure storage, generating and storing a
/// fresh one (private key bytes, base64) when absent. The private key
/// never leaves the device. Restoring re-derives the same public key:
/// the stored bytes are the clamped private-key bytes returned by
/// extractPrivateKeyBytes(), which newKeyPairFromSeed() accepts as-is.
///
/// Memoised (finding #22): concurrent callers share one future. If the
/// stored bytes are corrupt, a fresh pair is generated AND the new
/// public key is republished to the profile (finding #21) — the old
/// code generated a fresh private key but left the OLD public key in
/// the profile, permanently bricking E2E on that device.
Future<SimpleKeyPair> ensureKeyPair() {
  final existing = _pairFuture;
  if (existing != null) return existing;
  final future = _ensureKeyPairUncached();
  _pairFuture = future;
  // A failed attempt must not poison the memo: clear it so a retry is
  // possible (finding #22).
  future.then(
    (_) {},
    onError: (_) {
      if (identical(_pairFuture, future)) _pairFuture = null;
    },
  );
  return future;
}

Future<SimpleKeyPair> _ensureKeyPairUncached() async {
  final stored = await secureStore.read(key: _privateKeyStorageKey);
  if (stored != null && stored.isNotEmpty) {
    try {
      return await _x25519.newKeyPairFromSeed(decodeBase64(stored));
    } catch (_) {
      // A corrupt stored key must not brick messaging: fall through and
      // generate a fresh pair (old wrapped rows become unreadable on this
      // device, which the reader reports honestly) — but the profile
      // MUST learn the new public key (finding #21), or nobody can wrap
      // anything for this device ever again.
      _keyWasReplaced = true;
    }
  }
  final pair = await _x25519.newKeyPair();
  final privateBytes = await pair.extractPrivateKeyBytes();
  await secureStore.write(
    key: _privateKeyStorageKey,
    value: base64Encode(privateBytes),
  );
  if (_keyWasReplaced) {
    // Best-effort, never throws: if there is no signed-in user or no
    // network, publishPublicKeyIfNeeded() (which compares keys) republishes
    // on the next chat/send attempt.
    await _publishReplacedPublicKey(pair);
  }
  return pair;
}

/// Publishes [pair]'s public key to profiles.public_key when the stored
/// profile key differs from it (including when it is empty). Shared by
/// [publishPublicKeyIfNeeded] and the corrupt-key replacement path in
/// [_ensureKeyPairUncached]; never calls [ensureKeyPair] itself, so
/// there is no recursion. Never throws.
Future<void> _publishReplacedPublicKey(SimpleKeyPair pair) async {
  try {
    final client = Supabase.instance.client;
    final uid = client.auth.currentUser?.id;
    if (uid == null) return;
    final publicKey = await myPublicKeyBase64(pair);
    final row = await client
        .from('profiles')
        .select('public_key')
        .eq('id', uid)
        .maybeSingle();
    final existing = row?['public_key']?.toString() ?? '';
    if (existing.trim() == publicKey) {
      _keyWasReplaced = false;
      return;
    }
    await client
        .from('profiles')
        .update({'public_key': publicKey})
        .eq('id', uid);
    _keyWasReplaced = false;
  } catch (_) {
    // Best-effort: the flag stays set and publishPublicKeyIfNeeded()
    // retries on the next call.
  }
}

/// Base64 of the public key bytes of [pair].
Future<String> myPublicKeyBase64(SimpleKeyPair pair) async {
  final publicKey = await pair.extractPublicKey();
  return base64Encode(publicKey.bytes);
}

/// Publishes my public key to profiles.public_key when the profile key
/// differs from my CURRENT local public key — not merely when it is
/// empty (finding #21). After a corrupt-key replacement or a reinstall,
/// the profile still holds the OLD public key while the device holds a
/// NEW private key; comparing and updating here is what heals that.
/// Best-effort by callers: a failure must never block sending.
/// Requires migration 012's extended column-level UPDATE grant.
Future<void> publishPublicKeyIfNeeded({SimpleKeyPair? pair}) async {
  final client = Supabase.instance.client;
  final uid = client.auth.currentUser?.id;
  if (uid == null) return;
  final keyPair = pair ?? await ensureKeyPair();
  final publicKey = await myPublicKeyBase64(keyPair);
  final row = await client
      .from('profiles')
      .select('public_key')
      .eq('id', uid)
      .maybeSingle();
  final existing = row?['public_key']?.toString() ?? '';
  if (existing.trim() == publicKey) {
    _keyWasReplaced = false;
    return;
  }
  await client.from('profiles').update({'public_key': publicKey}).eq('id', uid);
  _keyWasReplaced = false;
}

// ---------------------------------------------------------------------------
// Conversation key flow (Supabase).
// ---------------------------------------------------------------------------

/// Wraps [convKeyBytes] for every member in [memberPublicKeys] who has a
/// public key (including myself) and upserts their conversation_keys rows.
/// The RLS INSERT policy allows any member to wrap for other members.
/// Best-effort per member: one member's failure must not block the rest.
Future<void> wrapKeyForMembers(
  String conversationId,
  List<int> convKeyBytes,
  Map<String, String?> memberPublicKeys,
) async {
  final client = Supabase.instance.client;
  final myId = client.auth.currentUser?.id;
  if (myId == null) return;
  final pair = await ensureKeyPair();
  final myPrivate = await pair.extractPrivateKeyBytes();
  for (final entry in memberPublicKeys.entries) {
    final userId = entry.key;
    final publicKey = entry.value;
    if (!isValidPublicKey(publicKey)) {
      // Log the user id only — never key material (finding #24/#28).
      // A member with a corrupt profile key is skipped, not wrapped for;
      // canEncryptFor() reports the same member as unencryptable, so the
      // sender falls back to plaintext with the 🔓 label instead of
      // silently encrypting for everyone-but-them.
      debugPrint(
        'Helba E2E: skipping wrap for member $userId: invalid public key',
      );
      continue;
    }
    try {
      final wrapped = await wrapConversationKey(
        convKeyBytes,
        myPrivate,
        publicKey!,
        conversationId: conversationId,
      );
      await client.from('conversation_keys').upsert(
        {
          'conversation_id': conversationId,
          'user_id': userId,
          'wrapped_key': wrapped,
          'wrapped_by': myId,
        },
        onConflict: 'conversation_id,user_id',
      );
    } catch (e) {
      // One member unwrappable now (bad key, network blip) — the next
      // send retries via the same lazy re-wrap. Log the user id only,
      // never key material.
      debugPrint('Helba E2E: wrap failed for member $userId: $e');
    }
  }
}

/// Outcome of looking up my own wrapped conversation-key row.
enum _MyKeyOutcome {
  /// No row for me (yet).
  noRow,

  /// Row exists and unwrapped successfully.
  loaded,

  /// Row exists but cannot be used (no wrapper public key, or it does
  /// not unwrap): creating a fresh key over it would orphan the old
  /// messages, so the caller must NOT create one.
  blocked,
}

/// Loads my wrapped conversation-key row and unwraps it (conversation-
/// bound KEK, legacy fallback). Throws on a Supabase/network error so
/// the caller can distinguish "no row" from "could not check".
///
/// [fromLegacy] is true exactly when the row was wrapped before
/// conversation binding (finding #26) — the caller heals such rows by
/// re-wrapping them with the bound KEK. It is false for bound rows and
/// for every non-loaded outcome.
Future<({_MyKeyOutcome outcome, List<int>? key, bool fromLegacy})>
    _loadMyWrappedKey(
  String conversationId,
  List<int> myPrivate,
) async {
  final client = Supabase.instance.client;
  final myId = client.auth.currentUser?.id;
  if (myId == null) {
    return (outcome: _MyKeyOutcome.blocked, key: null, fromLegacy: false);
  }
  final rows = await client
      .from('conversation_keys')
      .select('wrapped_key, wrapped_by')
      .eq('conversation_id', conversationId)
      .eq('user_id', myId)
      .limit(1);
  if (rows.isEmpty) {
    return (outcome: _MyKeyOutcome.noRow, key: null, fromLegacy: false);
  }
  final row = rows.first;
  final wrappedBy = row['wrapped_by']?.toString() ?? '';
  final wrapped = row['wrapped_key']?.toString() ?? '';
  if (wrappedBy.isEmpty || wrapped.isEmpty) {
    return (outcome: _MyKeyOutcome.blocked, key: null, fromLegacy: false);
  }
  final profile = await client
      .from('profiles')
      .select('public_key')
      .eq('id', wrappedBy)
      .maybeSingle();
  final wrapperPublic = profile?['public_key']?.toString() ?? '';
  if (wrapperPublic.trim().isEmpty) {
    return (outcome: _MyKeyOutcome.blocked, key: null, fromLegacy: false);
  }
  try {
    final loaded = await unwrapWrappedKeyWithFallback(
      wrapped,
      myPrivate,
      wrapperPublic,
      conversationId,
    );
    return (
      outcome: _MyKeyOutcome.loaded,
      key: loaded.key,
      fromLegacy: loaded.fromLegacy,
    );
  } catch (_) {
    // My row exists but does not unwrap with either KEK (corrupt /
    // wrong key): do NOT create a fresh key over it — that would
    // orphan the old messages for everyone. Report "no key".
    return (outcome: _MyKeyOutcome.blocked, key: null, fromLegacy: false);
  }
}

/// True when the conversation already has encrypted messages: either
/// `is_encrypted = true` OR a non-empty `ciphertext` (finding #27 —
/// the old guard only checked `is_encrypted`, so a row with ciphertext
/// but `is_encrypted = false` could be overwritten by a competing key).
/// Throws on a Supabase/network error.
Future<bool> _hasEncryptedMessages(String conversationId) async {
  final client = Supabase.instance.client;
  final flagged = await client
      .from('messages')
      .select('id')
      .eq('conversation_id', conversationId)
      .eq('is_encrypted', true)
      .limit(1);
  if (flagged.isNotEmpty) return true;
  final withCiphertext = await client
      .from('messages')
      .select('id')
      .eq('conversation_id', conversationId)
      .not('ciphertext', 'is', null)
      .neq('ciphertext', '')
      .limit(1);
  return withCiphertext.isNotEmpty;
}
/// Whether a fresh conversation key may be created: normally never
/// when encrypted messages already exist (a competing key would orphan
/// them); after an explicit user reset ([afterReset] — the old wrapped
/// rows were deleted by `reset_conversation_keys`) creation is allowed.
/// Pure (no Supabase): unit-tested.
bool shouldCreateKey({
  required bool hasEncryptedMessages,
  required bool afterReset,
}) =>
    afterReset || !hasEncryptedMessages;

/// Loads this conversation's key, creating it when nobody has one yet.
///
/// Returns a record: [key] is the conversation key (null when it
/// cannot be obtained); [blocked] is true ONLY when my wrapped row
/// exists but cannot be unwrapped with either KEK — a DEFINITIVE
/// failure (corrupt row / wrapped for a key this device no longer
/// holds), as opposed to a transient failure (no row yet, network
/// error) where [blocked] is false and the caller must keep retrying;
/// [fromLegacy] is true when the key came from a pre-binding (legacy)
/// wrapped row, so the caller can heal it by re-wrapping.
///
/// Returns null key when the key cannot be obtained: no signed-in user,
/// a network/Supabase error (pre-migration 012 included), or — the
/// important guard — when the conversation already has encrypted
/// messages but I have no wrapped row (someone else created the key
/// and nobody wrapped it for me yet). In that last case creating a
/// fresh key would overwrite everyone's rows and orphan the old
/// messages, so the caller must fall back to plaintext for sending and
/// show the decrypt-failure note for reading instead. A later sender's
/// lazy re-wrap fixes the missing row. The guard is skipped when
/// [afterReset] is true: the caller just deleted every wrapped row via
/// `reset_conversation_keys`, so there is no old key left to orphan
/// and the caller acts as the creator of the fresh key.
Future<({List<int>? key, bool blocked, bool fromLegacy})>
    loadOrCreateConversationKey(
  String conversationId,
  Map<String, String?> memberPublicKeys, {
  bool afterReset = false,
}) async {
  final client = Supabase.instance.client;
  final myId = client.auth.currentUser?.id;
  if (myId == null) {
    return (key: null, blocked: false, fromLegacy: false);
  }

  final pair = await ensureKeyPair();
  final myPrivate = await pair.extractPrivateKeyBytes();
  final myPublic = await myPublicKeyBase64(pair);
  // I always have a key after ensureKeyPair(); my own entry is ALWAYS
  // overwritten with the current local public key (finding #21) — a
  // stale profile key loaded by _loadMembers must never be wrapped for,
  // because I no longer own its private key.
  final members = Map<String, String?>.from(memberPublicKeys);
  members[myId] = myPublic;

  // Creator election (finding #23): smallest member id creates. After
  // an explicit reset the caller IS the creator: the old rows are
  // gone, nobody else knows a reset happened, and waiting for the
  // elected creator would leave the conversation keyless.
  final sortedIds = members.keys.toList()..sort();
  final iAmCreator =
      afterReset || sortedIds.isEmpty || sortedIds.first == myId;

  // Poll loop for non-creators; the creator breaks out immediately.
  // 6 attempts x 500 ms ≈ 2.5 s of waiting for the creator's row.
  const maxPollAttempts = 6;
  for (var attempt = 0; attempt < maxPollAttempts; attempt++) {
    // 1. My wrapped row, if one exists.
    try {
      final mine = await _loadMyWrappedKey(conversationId, myPrivate);
      if (mine.outcome == _MyKeyOutcome.loaded) {
        return (
          key: mine.key,
          blocked: false,
          fromLegacy: mine.fromLegacy,
        );
      }
      if (mine.outcome == _MyKeyOutcome.blocked) {
        return (key: null, blocked: true, fromLegacy: false);
      }
    } catch (_) {
      // conversation_keys missing (pre-migration) or network error: no
      // key, caller falls back to plaintext.
      return (key: null, blocked: false, fromLegacy: false);
    }

    // 2. No row for me. If the conversation already has encrypted
    // messages, a key exists that I do not have — do not create a
    // competing one (unless this load follows an explicit reset, where
    // the old rows were deleted and there is nothing to orphan).
    try {
      final hasEncrypted = await _hasEncryptedMessages(conversationId);
      if (!shouldCreateKey(
        hasEncryptedMessages: hasEncrypted,
        afterReset: afterReset,
      )) {
        return (key: null, blocked: false, fromLegacy: false);
      }
    } catch (_) {
      return (key: null, blocked: false, fromLegacy: false);
    }

    // 3. Fresh conversation (or none encrypted yet): the elected
    // creator creates; everyone else waits for the creator's row.
    if (iAmCreator) break;
    if (attempt == maxPollAttempts - 1) {
      debugPrint(
        'Helba E2E: no conversation key appeared after polling; not '
        'creating one (not the elected creator)',
      );
      return (key: null, blocked: false, fromLegacy: false);
    }
    await Future.delayed(const Duration(milliseconds: 500));
  }

  // 3. Create the key and wrap it for every member who has a public
  // key, including myself.
  final convKey = generateConversationKey();
  await wrapKeyForMembers(conversationId, convKey, members);
  // Re-read my own wrapped row and adopt whatever key is actually
  // stored (finding #23): if another creator overwrote my row in the
  // meantime, the stored key — not my locally generated one — is the
  // key everyone else will use. On a re-read failure, fall back to the
  // local key (the wraps were already attempted).
  try {
    final stored = await _loadMyWrappedKey(conversationId, myPrivate);
    if (stored.outcome == _MyKeyOutcome.loaded && stored.key != null) {
      return (
        key: stored.key,
        blocked: false,
        fromLegacy: stored.fromLegacy,
      );
    }
  } catch (_) {
    // Re-read failed (network blip): keep the locally generated key.
  }
  return (key: convKey, blocked: false, fromLegacy: false);
}
