-- Revised account structure (2026-11-23): Owner and one shared Shop/Staff login per outlet.
-- The enum value is added in its own migration: PostgreSQL cannot use a new enum value in the
-- transaction that adds it. 'head' and 'counter' stay in the type so historical memberships keep
-- their meaning; migration 001700 stops granting them anything.
alter type public.app_role add value if not exists 'shop';
comment on type public.app_role is
  'owner = owner; manager = owner''s son (owner side); shop = the outlet''s shared Shop/Staff login. '
  'head and counter are legacy (before 2026-11-23) and grant no permissions.';
