import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const green = Color(0xFF087A4B);
const secureStore = FlutterSecureStorage();

/// Short commit SHA baked in at build time (the workflow passes
/// HELBA_COMMIT), shown on the login screen so a screenshot proves which
/// build is installed.
/// The 'dev' fallback is deliberate but means "no commit was baked in":
/// [isDevBuild] is true exactly then, so the login screen (and any
/// diagnostics) can show it as an unidentified build instead of a real
/// version. The workflow should fail loudly when HELBA_COMMIT is unset
/// (a CI concern, not a Dart one) so release builds never ship as 'dev'.
const buildCommit = String.fromEnvironment('HELBA_COMMIT', defaultValue: 'dev');

/// True when no build commit was baked in ([buildCommit] is the 'dev'
/// fallback). A release build must never report true here.
bool get isDevBuild => buildCommit == 'dev';

/// The default Supabase project host. This is the ONE place the project
/// host string lives: [supabaseUrlDefault] is built from it, and
/// [supabaseHost] is derived from the effective URL below, so no other
/// file may hardcode the host (see B12).
const supabaseHostDefault = 'mpgnybncdiaaohjaqejq.supabase.co';

/// Default Supabase URL/key, used when the build does not pass
/// SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY dart-defines.
const supabaseUrlDefault = 'https://$supabaseHostDefault';
const supabasePublishableKeyDefault =
    'sb_publishable_IZ-P_b8LjdDfjATffyqqDg_yJOu9-Og';

/// The effective Supabase URL (build-time define, else default).
const supabaseUrl =
    String.fromEnvironment('SUPABASE_URL', defaultValue: supabaseUrlDefault);

/// The Supabase project host, derived ONCE from the effective Supabase
/// URL ([supabaseUrl]). Every other file (network.dart, diagnostics.dart)
/// must use this instead of hardcoding the host, so a different
/// SUPABASE_URL dart-define cannot silently diverge from the host the
/// network layer dials (B12). Falls back to [supabaseHostDefault] when
/// the URL cannot be parsed (defensive: auth.dart validates the URL
/// before Supabase is initialised).
String get supabaseHost {
  final host = Uri.tryParse(supabaseUrl.trim())?.host ?? '';
  return host.isEmpty ? supabaseHostDefault : host;
}

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
///
/// NOTE (M28): the Chrome/126 version below is intentionally frozen:
/// it is the exact agent the current network workaround was verified
/// with, and bumping it is low-value churn that risks breaking that
/// workaround. Only change it deliberately, with an on-device retest
/// of signup on the affected network.
const browserUserAgent =
    'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';
