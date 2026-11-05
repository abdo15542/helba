import 'dart:io' as io;

import 'package:supabase_flutter/supabase_flutter.dart';

// Keyboards often auto-insert a space after '.' while typing an email
// (e.g. 'name@gmail. com'). trim() only removes the ends, so strip every
// whitespace character inside the address as well.
String normalizeEmail(String value) =>
    value.replaceAll(RegExp(r'\s+'), '').toLowerCase();

/// Friendly Arabic message for network failures; null for anything else.
/// Supabase surfaces network failures as an AuthException whose message
/// contains the underlying 'ClientException with SocketException...' text,
/// so detect by message content rather than by exception type.
String? networkErrorMessage(Object e) {
  if (e is io.SocketException) {
    return 'تعذّر الوصول إلى خادم هلبة. تحقق من اتصالك بالإنترنت وحاول مجدداً.';
  }
  final text = e is AuthException ? e.message : e.toString();
  if (text.contains('SocketException') ||
      text.contains('ClientException') ||
      text.contains('Failed host lookup')) {
    return 'تعذّر الوصول إلى خادم هلبة. تحقق من اتصالك بالإنترنت وحاول مجدداً.';
  }
  return null;
}
