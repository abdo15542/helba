-- HELBA: call signalling SDP fallback (migration 027).
-- Stores the WebRTC offer/answer SDPs on the calls row so a peer can
-- fetch them with a plain select when Supabase Realtime broadcast is
-- down. The offer previously flowed ONLY via Realtime, so a callee whose
-- Realtime subscription timed out could never answer (acceptCall waited
-- 20s on requestOffer and declined). All columns are nullable; the
-- existing calls RLS policies (caller or callee can SELECT and UPDATE)
-- already cover them, so no policy changes.
alter table if exists public.calls
  add column if not exists offer_sdp text,
  add column if not exists offer_sdp_type text,
  add column if not exists answer_sdp text,
  add column if not exists answer_sdp_type text;

comment on column public.calls.offer_sdp is 'Caller offer SDP (signalling fallback when Realtime is down; callee fetches it on accept).';
comment on column public.calls.answer_sdp is 'Callee answer SDP (stored for a future caller-side fallback).';
