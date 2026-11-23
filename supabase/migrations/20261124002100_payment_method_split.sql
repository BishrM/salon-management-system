-- Split payment (2026-11-24): a service sale paid partly in cash and partly by UPI / Paytm / Card.
-- Own migration: a new enum value cannot be used in the transaction that adds it (…002200 uses it).
alter type public.payment_method add value if not exists 'split';
