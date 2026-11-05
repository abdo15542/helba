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
//     wrapper and that member (HKDF-SHA256, info 'helba-e2e-kek-v1'), and
//     stored in public.conversation_keys (one row per member, RLS: each
//     user reads only their own row).
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
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';

/// Constant body stored for encrypted messages — never plaintext.
const encryptedMessagePlaceholder = '🔒 رسالة مشفّرة';

const _privateKeyStorageKey = 'helba_e2e_private_key';

/// HKDF info string binding the derived key-encryption key to this app
/// and scheme version. Changing it makes old wrapped keys undecryptable.
const _kekInfo = 'helba-e2e-kek-v1';

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

/// True only when EVERY member (including me) has a non-empty public key.
/// An empty member list can never be encrypted (nothing proves who the
/// members even are).
bool canEncryptFor(Map<String, String?> memberPublicKeys) {
  if (memberPublicKeys.isEmpty) return false;
  return memberPublicKeys.values
      .every((key) => key != null && key.trim().isNotEmpty);
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
/// with HKDF-SHA256 (info 'helba-e2e-kek-v1'). The raw shared secret is
/// never used directly as an encryption key.
Future<List<int>> deriveKeyEncryptionKey(List<int> sharedSecretBytes) async {
  final derived = await _hkdf.deriveKey(
    secretKey: SecretKeyData(sharedSecretBytes),
    nonce: const <int>[],
    info: utf8.encode(_kekInfo),
  );
  return derived.extractBytes();
}

/// X25519 shared secret between my private key and their public key.
/// The two sides compute the same bytes (tested: symmetry).
Future<List<int>> deriveSharedSecret(
  List<int> myPrivateKeyBytes,
  String theirPublicKeyBase64,
) async {
  final keyPair =
      await _x25519.newKeyPairFromSeed(myPrivateKeyBytes);
  final theirPublicKey = SimplePublicKey(
    decodeBase64(theirPublicKeyBase64),
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
Future<String> wrapConversationKey(
  List<int> convKeyBytes,
  List<int> myPrivateKeyBytes,
  String theirPublicKeyBase64,
) async {
  final shared =
      await deriveSharedSecret(myPrivateKeyBytes, theirPublicKeyBase64);
  final kek = await deriveKeyEncryptionKey(shared);
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
Future<List<int>> unwrapConversationKey(
  String wrappedBase64,
  List<int> myPrivateKeyBytes,
  String wrapperPublicKeyBase64,
) async {
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
  final kek = await deriveKeyEncryptionKey(shared);
  return _aesGcm.decrypt(
    SecretBox(cipherText, nonce: nonce, mac: mac),
    secretKey: SecretKeyData(kek),
  );
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
/// FormatException on malformed input) — callers show
/// 'تعذّر فك تشفير هذه الرسالة' instead of the body.
Future<String> decryptText(
  String ciphertextBase64,
  String nonceBase64,
  List<int> convKeyBytes,
) async {
  final cipherAndTag = decodeBase64(ciphertextBase64);
  if (cipherAndTag.length < _gcmTagLength) {
    throw const FormatException('Ciphertext too short');
  }
  final cipherText =
      cipherAndTag.sublist(0, cipherAndTag.length - _gcmTagLength);
  final mac = Mac(cipherAndTag.sublist(cipherAndTag.length - _gcmTagLength));
  final plain = await _aesGcm.decrypt(
    SecretBox(cipherText, nonce: decodeBase64(nonceBase64), mac: mac),
    secretKey: SecretKeyData(convKeyBytes),
  );
  return utf8.decode(plain);
}

// ---------------------------------------------------------------------------
// Keypair management (secure storage + profiles.public_key).
// ---------------------------------------------------------------------------

/// Loads my X25519 keypair from secure storage, generating and storing a
/// fresh one (private key bytes, base64) when absent. The private key
/// never leaves the device. Restoring re-derives the same public key:
/// the stored bytes are the clamped private-key bytes returned by
/// extractPrivateKeyBytes(), which newKeyPairFromSeed() accepts as-is.
Future<SimpleKeyPair> ensureKeyPair() async {
  final stored = await secureStore.read(key: _privateKeyStorageKey);
  if (stored != null && stored.isNotEmpty) {
    try {
      return await _x25519.newKeyPairFromSeed(decodeBase64(stored));
    } catch (_) {
      // A corrupt stored key must not brick messaging: fall through and
      // generate a fresh pair (old wrapped rows become unreadable on this
      // device, which the reader reports honestly).
    }
  }
  final pair = await _x25519.newKeyPair();
  final privateBytes = await pair.extractPrivateKeyBytes();
  await secureStore.write(
    key: _privateKeyStorageKey,
    value: base64Encode(privateBytes),
  );
  return pair;
}

/// Base64 of the public key bytes of [pair].
Future<String> myPublicKeyBase64(SimpleKeyPair pair) async {
  final publicKey = await pair.extractPublicKey();
  return base64Encode(publicKey.bytes);
}

/// Publishes my public key to profiles.public_key when it is not already
/// set. Best-effort by callers: a failure must never block sending.
/// Requires migration 012's extended column-level UPDATE grant.
Future<void> publishPublicKeyIfNeeded({SimpleKeyPair? pair}) async {
  final client = Supabase.instance.client;
  final uid = client.auth.currentUser?.id;
  if (uid == null) return;
  final row = await client
      .from('profiles')
      .select('public_key')
      .eq('id', uid)
      .maybeSingle();
  final existing = row?['public_key']?.toString() ?? '';
  if (existing.trim().isNotEmpty) return;
  final keyPair = pair ?? await ensureKeyPair();
  final publicKey = await myPublicKeyBase64(keyPair);
  await client.from('profiles').update({'public_key': publicKey}).eq('id', uid);
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
    if (publicKey == null || publicKey.trim().isEmpty) continue;
    try {
      final wrapped =
          await wrapConversationKey(convKeyBytes, myPrivate, publicKey);
      await client.from('conversation_keys').upsert(
        {
          'conversation_id': conversationId,
          'user_id': userId,
          'wrapped_key': wrapped,
          'wrapped_by': myId,
        },
        onConflict: 'conversation_id,user_id',
      );
    } catch (_) {
      // One member unwrappable now (bad key, network blip) — the next
      // send retries via the same lazy re-wrap.
    }
  }
}

/// Loads this conversation's key, creating it when nobody has one yet.
///
/// Returns null when the key cannot be obtained: no signed-in user, a
/// network/Supabase error (pre-migration 012 included), or — the important
/// guard — when the conversation already has encrypted messages but I
/// have no wrapped row (someone else created the key and nobody wrapped
/// it for me yet). In that last case creating a fresh key would overwrite
/// everyone's rows and orphan the old messages, so the caller must fall
/// back to plaintext for sending and show the decrypt-failure note for
/// reading instead. A later sender's lazy re-wrap fixes the missing row.
Future<List<int>?> loadOrCreateConversationKey(
  String conversationId,
  Map<String, String?> memberPublicKeys,
) async {
  final client = Supabase.instance.client;
  final myId = client.auth.currentUser?.id;
  if (myId == null) return null;

  final pair = await ensureKeyPair();
  final myPrivate = await pair.extractPrivateKeyBytes();
  final myPublic = await myPublicKeyBase64(pair);
  // I always have a key after ensureKeyPair(); make sure my own entry is
  // present even if _loadMembers has not run (or has not loaded me) yet.
  final members = Map<String, String?>.from(memberPublicKeys);
  members.putIfAbsent(myId, () => myPublic);
  if ((members[myId] ?? '').trim().isEmpty) members[myId] = myPublic;

  // 1. My wrapped row, if one exists.
  try {
    final rows = await client
        .from('conversation_keys')
        .select('wrapped_key, wrapped_by')
        .eq('conversation_id', conversationId)
        .eq('user_id', myId)
        .limit(1);
    if (rows.isNotEmpty) {
      final row = rows.first;
      final wrappedBy = row['wrapped_by']?.toString() ?? '';
      final wrapped = row['wrapped_key']?.toString() ?? '';
      if (wrappedBy.isNotEmpty && wrapped.isNotEmpty) {
        final profile = await client
            .from('profiles')
            .select('public_key')
            .eq('id', wrappedBy)
            .maybeSingle();
        final wrapperPublic = profile?['public_key']?.toString() ?? '';
        if (wrapperPublic.trim().isNotEmpty) {
          try {
            return await unwrapConversationKey(wrapped, myPrivate, wrapperPublic);
          } catch (_) {
            // My row exists but does not unwrap (corrupt / wrong key):
            // do NOT create a fresh key over it — that would orphan the
            // old messages for everyone. Report "no key".
            return null;
          }
        }
      }
      // My row exists but its wrapper has no public key: same guard.
      return null;
    }
  } catch (_) {
    // conversation_keys missing (pre-migration) or network error: no key,
    // caller falls back to plaintext.
    return null;
  }

  // 2. No row for me. If the conversation already has encrypted messages,
  // a key exists that I do not have — do not create a competing one.
  try {
    final encrypted = await client
        .from('messages')
        .select('id')
        .eq('conversation_id', conversationId)
        .eq('is_encrypted', true)
        .limit(1);
    if (encrypted.isNotEmpty) return null;
  } catch (_) {
    return null;
  }

  // 3. Fresh conversation (or none encrypted yet): create the key and wrap
  // it for every member who has a public key, including myself.
  final convKey = generateConversationKey();
  await wrapKeyForMembers(conversationId, convKey, members);
  return convKey;
}
