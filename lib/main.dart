import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/material.dart';

import 'src/auth.dart';
import 'src/network.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Route Supabase traffic through the DNS-over-HTTPS fallback so the app
  // keeps working on networks whose system DNS cannot resolve Supabase.
  io.HttpOverrides.global = HelbaHttpOverrides();
  // M27: first paint must not wait for the system-proxy lookup, and a
  // failure there must not prevent startup. Run the app immediately and
  // load the proxy concurrently; the proxy logic itself is unchanged,
  // and clients created after it loads pick it up.
  runApp(const HelbaApp());
  WidgetsBinding.instance.addObserver(_AppLifecycleObserver());
  unawaited(_loadProxyInBackground());
}

/// Loads the system proxy off the startup path. Any failure is swallowed
/// here because the app must still start (direct connection) without it.
Future<void> _loadProxyInBackground() async {
  try {
    await loadSystemProxy();
  } catch (_) {
    // No proxy: the app continues with a direct connection.
  }
}

/// Closes the shared DNS-over-HTTPS client when the app process is
/// detached, so it is not left open for the lifetime of the process
/// (network.dart's closeDohClient(); the client is recreated lazily).
class _AppLifecycleObserver extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) closeDohClient();
  }
}
