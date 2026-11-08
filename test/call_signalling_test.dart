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
}
