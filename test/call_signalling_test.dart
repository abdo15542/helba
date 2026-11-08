// Tests for the database-backed call-signalling fallback:
// the caller stores the offer SDP on the calls row, and the callee
// fetches it with a plain select when the offer never arrived over
// Realtime broadcast. Only the pure helpers are tested here — the
// actual store/fetch round-trip (caller writes the row, callee reads
// it on accept) needs a live Supabase backend and two devices.
import 'package:flutter_test/flutter_test.dart';
import 'package:helba/src/calls.dart';

const _sdp = 'v=0\r\no=- 123456 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n';

void main() {
  group('dbOfferSdp', () {
    test('null row has no offer SDP', () {
      expect(dbOfferSdp(null), isNull);
    });

    test('missing offer_sdp column has no offer SDP', () {
      expect(dbOfferSdp({}), isNull);
      expect(dbOfferSdp({'offer_sdp_type': 'offer'}), isNull);
    });

    test('non-string offer_sdp has no offer SDP', () {
      expect(dbOfferSdp({'offer_sdp': 42}), isNull);
      expect(dbOfferSdp({'offer_sdp': true}), isNull);
    });

    test('empty or blank offer_sdp has no offer SDP', () {
      expect(dbOfferSdp({'offer_sdp': ''}), isNull);
      expect(dbOfferSdp({'offer_sdp': '   '}), isNull);
      expect(dbOfferSdp({'offer_sdp': '\n\t'}), isNull);
    });

    test('valid offer SDP is returned as-is', () {
      expect(dbOfferSdp({'offer_sdp': _sdp}), _sdp);
    });

    test('offer SDP is returned even when the type column is absent', () {
      expect(
          dbOfferSdp({'offer_sdp': _sdp, 'offer_sdp_type': null}), _sdp);
    });
  });

  group('dbOfferSdpType', () {
    test('null row defaults to offer', () {
      expect(dbOfferSdpType(null), 'offer');
    });

    test('missing or blank type defaults to offer', () {
      expect(dbOfferSdpType({}), 'offer');
      expect(dbOfferSdpType({'offer_sdp_type': null}), 'offer');
      expect(dbOfferSdpType({'offer_sdp_type': ''}), 'offer');
      expect(dbOfferSdpType({'offer_sdp_type': '  '}), 'offer');
      expect(dbOfferSdpType({'offer_sdp_type': 7}), 'offer');
    });

    test('stored type is passed through', () {
      expect(dbOfferSdpType({'offer_sdp_type': 'offer'}), 'offer');
      expect(dbOfferSdpType({'offer_sdp_type': 'answer'}), 'answer');
    });
  });

  group('dbAnswerSdp', () {
    test('null row has no answer SDP', () {
      expect(dbAnswerSdp(null), isNull);
    });

    test('missing answer_sdp column has no answer SDP', () {
      expect(dbAnswerSdp({}), isNull);
      expect(dbAnswerSdp({'answer_sdp_type': 'answer'}), isNull);
    });

    test('non-string answer_sdp has no answer SDP', () {
      expect(dbAnswerSdp({'answer_sdp': 42}), isNull);
      expect(dbAnswerSdp({'answer_sdp': true}), isNull);
    });

    test('empty or blank answer_sdp has no answer SDP', () {
      expect(dbAnswerSdp({'answer_sdp': ''}), isNull);
      expect(dbAnswerSdp({'answer_sdp': '   '}), isNull);
      expect(dbAnswerSdp({'answer_sdp': '\n\t'}), isNull);
    });

    test('valid answer SDP is returned as-is', () {
      expect(dbAnswerSdp({'answer_sdp': _sdp}), _sdp);
    });

    test('answer SDP is returned even when the type column is absent', () {
      expect(
          dbAnswerSdp({'answer_sdp': _sdp, 'answer_sdp_type': null}), _sdp);
    });
  });

  group('dbAnswerSdpType', () {
    test('null row defaults to answer', () {
      expect(dbAnswerSdpType(null), 'answer');
    });

    test('missing or blank type defaults to answer', () {
      expect(dbAnswerSdpType({}), 'answer');
      expect(dbAnswerSdpType({'answer_sdp_type': null}), 'answer');
      expect(dbAnswerSdpType({'answer_sdp_type': ''}), 'answer');
      expect(dbAnswerSdpType({'answer_sdp_type': '  '}), 'answer');
      expect(dbAnswerSdpType({'answer_sdp_type': 7}), 'answer');
    });

    test('stored type is passed through', () {
      expect(dbAnswerSdpType({'answer_sdp_type': 'answer'}), 'answer');
      expect(dbAnswerSdpType({'answer_sdp_type': 'offer'}), 'offer');
    });
  });

  group('parseDbIceCandidate', () {
    const candidateMap = {
      'candidate': 'candidate:1 1 udp 123 192.0.2.1 5000 typ host',
      'sdpMid': '0',
      'sdpMLineIndex': 0,
    };

    test('null row has no candidate', () {
      expect(parseDbIceCandidate(null), isNull);
    });

    test('missing or non-map candidate column has no candidate', () {
      expect(parseDbIceCandidate({}), isNull);
      expect(parseDbIceCandidate({'candidate': 'not-a-map'}), isNull);
      expect(parseDbIceCandidate({'candidate': 42}), isNull);
    });

    test('empty or blank candidate string has no candidate', () {
      expect(parseDbIceCandidate({'candidate': {'candidate': ''}}),
          isNull);
      expect(parseDbIceCandidate({'candidate': {'candidate': '  '}}),
          isNull);
    });

    test('valid row parses all fields', () {
      final parsed = parseDbIceCandidate({'candidate': candidateMap});
      expect(parsed, isNotNull);
      expect(parsed!.candidate, candidateMap['candidate']);
      expect(parsed.sdpMid, '0');
      expect(parsed.sdpMLineIndex, 0);
    });

    test('string sdpMLineIndex is parsed to int', () {
      final parsed = parseDbIceCandidate({
        'candidate': {...candidateMap, 'sdpMLineIndex': '1'},
      });
      expect(parsed, isNotNull);
      expect(parsed!.sdpMLineIndex, 1);
    });

    test('non-numeric sdpMLineIndex becomes null, candidate kept', () {
      final parsed = parseDbIceCandidate({
        'candidate': {...candidateMap, 'sdpMLineIndex': 'abc'},
      });
      expect(parsed, isNotNull);
      expect(parsed!.sdpMLineIndex, isNull);
      expect(parsed.candidate, candidateMap['candidate']);
    });

    test('missing sdpMid and index are null, candidate kept', () {
      final parsed = parseDbIceCandidate({
        'candidate': {'candidate': candidateMap['candidate']},
      });
      expect(parsed, isNotNull);
      expect(parsed!.candidate, candidateMap['candidate']);
      expect(parsed.sdpMid, isNull);
      expect(parsed.sdpMLineIndex, isNull);
    });
  });

  group('shouldEndForNoMedia', () {
    test('ends when no remote stream and not connected', () {
      expect(
          shouldEndForNoMedia(
              hasRemoteStream: false, isConnected: false),
          isTrue);
    });

    test('does not end when the remote stream arrived', () {
      expect(
          shouldEndForNoMedia(hasRemoteStream: true, isConnected: false),
          isFalse);
    });

    test('does not end when the connection is Connected', () {
      expect(
          shouldEndForNoMedia(hasRemoteStream: false, isConnected: true),
          isFalse);
    });

    test('does not end when media flows on a connected call', () {
      expect(
          shouldEndForNoMedia(hasRemoteStream: true, isConnected: true),
          isFalse);
    });
  });
}
