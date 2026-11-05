import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const green = Color(0xFF087A4B);
const secureStore = FlutterSecureStorage();

/// Short commit SHA baked in at build time (the workflow passes
/// HELBA_COMMIT), shown on the login screen so a screenshot proves which
/// build is installed.
const buildCommit = String.fromEnvironment('HELBA_COMMIT', defaultValue: 'dev');

/// The Supabase project host (used by the network layer and diagnostics).
const supabaseHost = 'mpgnybncdiaaohjaqejq.supabase.co';

/// Default Supabase URL/key, used when the build does not pass
/// SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY dart-defines.
const supabaseUrlDefault = 'https://mpgnybncdiaaohjaqejq.supabase.co';
const supabasePublishableKeyDefault =
    'sb_publishable_IZ-P_b8LjdDfjATffyqqDg_yJOu9-Og';

/// The effective Supabase publishable key (build-time define, else default).
const supabasePublishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
    defaultValue: supabasePublishableKeyDefault);

/// A normal mobile-browser User-Agent. Some networks (notably the
/// Cloudflare edge in front of Supabase) treat Dart's default
/// 'Dart/3.x (dart:io)' agent as a bot and answer POST /auth/v1/signup
/// with an HTML challenge page instead of JSON — which the Auth client
/// cannot decode ('Failed to decode error response'). A browser agent
/// makes the app's requests look like the legitimate client they are.
const browserUserAgent =
    'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';
