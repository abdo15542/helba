-- HELBA: grant the SDP columns on calls (migration 028).
-- Migration 017 restricted the calls UPDATE grant to (status,
-- ended_at). Migration 027 added offer_sdp / offer_sdp_type /
-- answer_sdp / answer_sdp_type but did not extend the grant, so build
-- 149's _storeOfferSdp / _storeAnswerSdp were rejected by Postgres
-- (42501 insufficient-privilege) and silently swallowed by try/catch
-- — the offer_sdp stayed NULL forever and the callee's accept DB
-- fetch always got null, so the build-149 fix never took effect.
-- This additive grant fixes that. No revoke, no other change.
--
-- REPO RULE: any future column added to calls that the app writes
-- must be added to this grant in the same migration.
grant update (offer_sdp, offer_sdp_type, answer_sdp, answer_sdp_type)
  on public.calls to authenticated;
