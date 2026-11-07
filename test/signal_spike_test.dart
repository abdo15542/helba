/// Signal Protocol spike test (libsignal 9.0.0).
///
/// Proves the X3DH + PQXDH session establishment and Double Ratchet
/// round-trip with the persistent stores from
/// `lib/src/signal_stores.dart`, backed here by an in-memory
/// key-value store (the store classes are the same persistent ones
/// the app wires to flutter_secure_storage; only the backend is
/// swapped so the test needs no platform channels).
///
/// Alice builds a session from Bob's pre-key bundle, encrypts a first
/// (pre-key) message, Bob decrypts it, Bob replies, Alice decrypts
/// the reply. A second test rebuilds both services over the SAME
/// backends (simulating an app restart) and exchanges another
/// message, proving the sessions survived through the stores.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:helba/src/signal_service.dart';
import 'package:helba/src/signal_stores.dart';
import 'package:libsignal/libsignal.dart';

/// In-memory [SignalKvStore] backend for tests.
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

SignalService _service(
  SignalKvStore backend, {
  required String name,
}) {
  return SignalService(
    stores: SignalStores.fromKvStore(backend, prefix: 'signal:$name'),
    localAddress: ProtocolAddress(name: name, deviceId: 1),
  );
}

void main() {
  test('Signal 1:1 round-trip: X3DH + PQXDH then Double Ratchet', () async {
    await LibSignal.init();

    final alice = _service(MemoryKvStore(), name: 'alice');
    final bob = _service(MemoryKvStore(), name: 'bob');
    final bobAddress = ProtocolAddress(name: 'bob', deviceId: 1);
    final aliceAddress = ProtocolAddress(name: 'alice', deviceId: 1);

    // Bob publishes a pre-key bundle; Alice builds a session from it.
    final bobBundle = await bob.generateBundle();
    await alice.buildSession(bobAddress, bobBundle);

    // First message: a pre-key message (establishes Bob's session and
    // consumes his one-time pre-keys).
    final first = await alice.encryptText(bobAddress, 'Hello Bob');
    expect(first.isPreKeyMessage, isTrue);
    expect(await bob.decryptText(aliceAddress, first), 'Hello Bob');

    // Reply: a regular Signal message on the established session.
    final reply = await bob.encryptText(aliceAddress, 'Hello Alice');
    expect(reply.isSignalMessage, isTrue);
    expect(await alice.decryptText(bobAddress, reply), 'Hello Alice');

    // A second message each way, proving the ratchet advanced.
    final second = await alice.encryptText(bobAddress, 'second from Alice');
    expect(second.isSignalMessage, isTrue);
    expect(await bob.decryptText(aliceAddress, second), 'second from Alice');
    final secondReply =
        await bob.encryptText(aliceAddress, 'second from Bob');
    expect(await alice.decryptText(bobAddress, secondReply), 'second from Bob');
  });

  test('sessions survive a restart: new services, same backends', () async {
    await LibSignal.init();

    final aliceBackend = MemoryKvStore();
    final bobBackend = MemoryKvStore();
    final alice = _service(aliceBackend, name: 'alice');
    final bob = _service(bobBackend, name: 'bob');
    final bobAddress = ProtocolAddress(name: 'bob', deviceId: 1);
    final aliceAddress = ProtocolAddress(name: 'alice', deviceId: 1);

    final bobBundle = await bob.generateBundle();
    await alice.buildSession(bobAddress, bobBundle);
    final first = await alice.encryptText(bobAddress, 'before restart');
    expect(await bob.decryptText(aliceAddress, first), 'before restart');

    // Bob replies, so the session is confirmed on both sides (a
    // message sent before any reply is legitimately a pre-key
    // message, not a Signal message — the handshake is unconfirmed
    // until the responder answers).
    final firstReply = await bob.encryptText(aliceAddress, 'reply');
    expect(firstReply.isSignalMessage, isTrue);
    expect(await alice.decryptText(bobAddress, firstReply), 'reply');

    // Simulate an app restart: throw the services away and rebuild
    // them over the SAME key-value backends. No in-memory state is
    // carried over; everything must come back from the stores. The
    // next message must be a Signal message (not a pre-key message),
    // proving the established session was loaded, not re-created.
    final alice2 = _service(aliceBackend, name: 'alice');
    final bob2 = _service(bobBackend, name: 'bob');

    final after = await alice2.encryptText(bobAddress, 'after restart');
    expect(after.isSignalMessage, isTrue);
    expect(await bob2.decryptText(aliceAddress, after), 'after restart');
    final afterReply =
        await bob2.encryptText(aliceAddress, 'after restart reply');
    expect(
      await alice2.decryptText(bobAddress, afterReply),
      'after restart reply',
    );
  });

  test('pre-key bundle can be rebuilt from stored keys', () async {
    await LibSignal.init();

    final bobBackend = MemoryKvStore();
    final bob = _service(bobBackend, name: 'bob');
    await bob.generateBundle();

    // Rebuild the service over the same backend (restart) and rebuild
    // the bundle from stored keys: it must carry the same identity
    // and signed pre-key.
    final bob2 = _service(bobBackend, name: 'bob');
    final rebuilt = await bob2.buildBundleFromStoredKeys();
    final alice = _service(MemoryKvStore(), name: 'alice');
    final bobAddress = ProtocolAddress(name: 'bob', deviceId: 1);
    final aliceAddress = ProtocolAddress(name: 'alice', deviceId: 1);

    await alice.buildSession(bobAddress, rebuilt);
    final first = await alice.encryptText(bobAddress, 'via rebuilt bundle');
    expect(await bob2.decryptText(aliceAddress, first), 'via rebuilt bundle');
  });
}
