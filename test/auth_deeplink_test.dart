import 'dart:async';
import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:helba/src/auth.dart';
import 'package:helba/src/deeplink.dart';

void main() {
  group('isAuthCallback (M5)', () {
    test('accepts the callback path with or without params', () {
      expect(isAuthCallback(Uri.parse('helba://auth/callback')), isTrue);
      expect(
          isAuthCallback(Uri.parse(
              'helba://auth/callback?code=abc&state=xyz')),
          isTrue);
    });

    test('accepts other auth paths only with an auth parameter', () {
      expect(
          isAuthCallback(
              Uri.parse('helba://auth/reset?code=abc')),
          isTrue);
      expect(
          isAuthCallback(Uri.parse(
              'helba://auth/callback?error=access_denied')),
          isTrue);
      // A bare helba://auth/reset with no parameters is not a callback.
      expect(isAuthCallback(Uri.parse('helba://auth/reset')), isFalse);
      expect(isAuthCallback(Uri.parse('helba://auth/')), isFalse);
    });

    test('rejects other hosts and schemes', () {
      expect(isAuthCallback(Uri.parse('helba://other/callback')), isFalse);
      expect(
          isAuthCallback(Uri.parse('https://example.com/auth/callback')),
          isFalse);
    });
  });

  group('isChatDeepLink / chatIdFromDeepLink (B-2)', () {
    const uuid = '123e4567-e89b-12d3-a456-426614174000';

    test('accepts exactly one UUID segment', () {
      final uri = Uri.parse('helba://chat/$uuid');
      expect(isChatDeepLink(uri), isTrue);
      expect(chatIdFromDeepLink(uri), uuid);
    });

    test('rejects non-UUID ids', () {
      expect(isChatDeepLink(Uri.parse('helba://chat/abc-123')), isFalse);
      expect(chatIdFromDeepLink(Uri.parse('helba://chat/abc-123')),
          isNull);
      expect(isChatDeepLink(Uri.parse('helba://chat/not-a-uuid')), isFalse);
    });

    test('rejects empty, missing and extra segments', () {
      expect(isChatDeepLink(Uri.parse('helba://chat/')), isFalse);
      expect(isChatDeepLink(Uri.parse('helba://chat')), isFalse);
      expect(isChatDeepLink(Uri.parse('helba://chat/$uuid/extra')),
          isFalse);
      expect(isChatDeepLink(Uri.parse('helba://auth/callback')), isFalse);
      expect(
          isChatDeepLink(Uri.parse('https://example.com/chat/$uuid')),
          isFalse);
    });
  });

  group('deepLinkErrorMessage (M6, B2)', () {
    test('missing PKCE verifier asks for a new link', () {
      final message = deepLinkErrorMessage(Exception(
          'Code verifier could not be found in local storage'));
      expect(message, contains('رابطاً جديداً'));
      expect(message, contains('هذا الجهاز'));
    });

    test('invalid_grant / already-used link asks for a new link', () {
      expect(
          deepLinkErrorMessage(
              Exception('invalid_grant: code has already been used')),
          contains('رابطاً جديداً'));
    });

    test('expired link asks for a new link', () {
      expect(
          deepLinkErrorMessage(Exception('Token has expired')),
          contains('انتهت صلاحية'));
    });

    test('network failure tells the user to check the connection, not resend',
        () {
      final message = deepLinkErrorMessage(
          const io.SocketException('Failed host lookup'));
      expect(message, contains('الاتصال'));
      expect(message, contains('لا حاجة لطلب رابط جديد'));
      expect(
          deepLinkErrorMessage(
              TimeoutException('getSessionFromUrl', const Duration(seconds: 15))),
          contains('لا حاجة لطلب رابط جديد'));
    });

    test('unknown errors fall back to the generic message', () {
      expect(deepLinkErrorMessage(Exception('something odd')),
          contains('تعذّر إكمال التأكيد'));
    });
  });

  group('authErrorMessage (M8, B16)', () {
    test('timeout maps to the Arabic network message', () {
      final message = authErrorMessage(
          TimeoutException('signUp', const Duration(seconds: 15)),
          operation: 'إنشاء الحساب');
      expect(message, isNotNull);
      expect(message, contains('انتهت مهلة الاتصال'));
      expect(message, contains('إنشاء الحساب'));
    });

    test('TLS handshake failure maps to a secure-connection message', () {
      final message = authErrorMessage(
          const io.HandshakeException('Handshake error'),
          operation: 'تسجيل الدخول');
      expect(message, isNotNull);
      expect(message, contains('اتصال آمن'));
    });

    test('HTTP 429 maps to a rate-limit message', () {
      expect(
          authErrorMessage(Exception('429 Too Many Requests')),
          contains('طلبات كثيرة'));
      expect(authErrorMessage(Exception('rate limit exceeded')),
          contains('طلبات كثيرة'));
    });

    test('common GoTrue messages map to Arabic', () {
      expect(authErrorMessage(Exception('Email not confirmed')),
          contains('أكد بريدك'));
      expect(authErrorMessage(Exception('Invalid login credentials')),
          contains('غير صحيحة'));
      expect(authErrorMessage(Exception('User already registered')),
          contains('مسجل بالفعل'));
    });

    test('decode-error text names the caller operation, not sign-up', () {
      final message = authErrorMessage(
          Exception('Failed to decode error response'),
          operation: 'تسجيل الدخول');
      expect(message, isNotNull);
      expect(message, contains('تسجيل الدخول'));
      expect(message, isNot(contains('إنشاء الحساب')));
    });

    test('unknown errors return null so callers keep the raw message', () {
      expect(authErrorMessage(Exception('something else')), isNull);
    });
  });
}
