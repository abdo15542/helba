import 'dart:io' as io;

import 'package:flutter/material.dart';

import 'src/auth.dart';
import 'src/network.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Route Supabase traffic through the DNS-over-HTTPS fallback so the app
  // keeps working on networks whose system DNS cannot resolve Supabase.
  io.HttpOverrides.global = HelbaHttpOverrides();
  // Read the system proxy before any network client is created, so the app
  // routes through it exactly like the phone's browser does.
  await loadSystemProxy();
  runApp(const HelbaApp());
}
