-- HELBA: fix E2E key re-wrap (migration 013).
-- Apply after 001-012. Self-contained and safe to re-run.
--
-- The conversation_keys UPDATE policy (migration 012) only allowed a user
-- to update their OWN wrapped row, so re-wrapping a conversation key for
-- ANOTHER member — the normal lazy re-wrap that runs on every send
-- (wrapKeyForMembers upserts a row per member) — failed with
-- 42501 "new row violates row-level security policy" (HTTP 403) whenever
-- the wrapped row already existed. The encrypted message still went out
-- (the re-wrap is best-effort), but the other member never received a
-- wrapped key row, so they could never decrypt it.
--
-- Any member may now update wrapped rows in conversations they belong to:
-- the same trust level as the INSERT policy, which already lets any member
-- insert a wrapped row for anyone. SELECT stays own-row-only, so no member
-- can read another member's wrapped key.

drop policy if exists conversation_keys_update_own
  on public.conversation_keys;
create policy conversation_keys_update_member on public.conversation_keys
for update to authenticated
using (public.is_conversation_member(conversation_id))
with check (public.is_conversation_member(conversation_id));
