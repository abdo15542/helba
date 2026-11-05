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
