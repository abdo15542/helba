import 'package:flutter_test/flutter_test.dart';
import 'package:helba/src/admin.dart';
import 'package:helba/src/channels.dart';
import 'package:helba/src/stories.dart';

void main() {
  group('story video duration cap (M-9)', () {
    test('videos up to 60s are allowed, longer are rejected', () {
      expect(maxStoryVideoDuration, const Duration(seconds: 60));
      expect(isStoryVideoTooLong(const Duration(seconds: 60)), isFalse);
      expect(isStoryVideoTooLong(const Duration(seconds: 59)), isFalse);
      expect(isStoryVideoTooLong(const Duration(seconds: 61)), isTrue);
      expect(
          isStoryVideoTooLong(const Duration(minutes: 5)), isTrue);
    });
  });

  group('channel member count (B-6)', () {
    test('reads member_count when present', () {
      expect(channelMemberCount({'member_count': 42}), 42);
      expect(channelMemberCount({'member_count': 0}), 0);
      expect(channelMemberCountLabel({'member_count': 42}), '42 عضو');
    });

    test('unknown count shows no label instead of a bogus 0', () {
      expect(channelMemberCount({}), isNull);
      expect(channelMemberCount({'member_count': null}), isNull);
      expect(channelMemberCount({'member_count': 'many'}), isNull);
      expect(channelMemberCountLabel({}), isNull);
      // The RLS-filtered embedded members list is NOT a count.
      expect(
          channelMemberCount({
            'conversation_members': [
              {'user_id': 'a'}
            ],
          }),
          isNull);
    });
  });

  group('mute helpers (B-7)', () {
    final now = DateTime.utc(2026, 11, 6, 1, 0);
    test('muted only while muted_until is in the future', () {
      expect(
          isMutedProfile(
              {'muted_until': '2026-11-07T01:00:00Z'}, now),
          isTrue);
      expect(
          isMutedProfile(
              {'muted_until': '2026-11-05T01:00:00Z'}, now),
          isFalse);
      expect(isMutedProfile({'muted_until': null}, now), isFalse);
      expect(isMutedProfile({}, now), isFalse);
      expect(isMutedProfile(null, now), isFalse);
      expect(
          isMutedProfile({'muted_until': 'not-a-date'}, now), isFalse);
    });

    test('mutedUntilOf parses defensively', () {
      expect(mutedUntilOf({'muted_until': '2026-11-07T01:00:00Z'}),
          DateTime.utc(2026, 11, 7, 1));
      expect(mutedUntilOf({}), isNull);
      expect(mutedUntilOf({'muted_until': 12345}), isNull);
    });
  });

  group('report target validation (M-9 admin)', () {
    test('post is no longer a valid report target', () {
      const uuid = '123e4567-e89b-12d3-a456-426614174000';
      expect(isValidReportTarget('post', uuid), isFalse);
      expect(isValidReportTarget('message', uuid), isTrue);
      expect(isValidReportTarget('user', uuid), isTrue);
    });
  });

  group('user search pattern escaping (M-6)', () {
    test('escapes LIKE wildcards so search text is literal', () {
      expect(escapeLikePattern('a%b_c\\d'), r'a\%b\_c\\d');
      expect(escapeLikePattern('أحمد'), 'أحمد');
    });
  });
}
