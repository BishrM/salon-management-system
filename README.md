# salon-management-system
an all-in-one digital platform that automates and centralizes the daily operations of hair salons, nail studios, and spas

## SalonOps

The first product in this repository is **SalonOps**: daily sales recording, commission, cash closing
and owner approval for the HUDCO Big Boss salon in Mysuru, built so Royal Crown and Elite Crown can be
added as further outlets. Requirements: [`SRS.md`](SRS.md). Decisions: [`docs/DECISIONS.md`](docs/DECISIONS.md).

- **Register** (tablet, works offline): service sales per employee, product sales (cash/Paytm),
  expenses, zakat, food — with corrections that keep their history.
- **Closing**: commission (10 % rounded down to ₹10, split by largest remainder), food from the
  commission pool, Paytm, denomination count, rolling float, commission handover, submit.
- **Owner / management**: live dashboard, approvals in date order, reject/reopen with immutable
  revisions, late-entry review, float management, reports with Excel export and print/PDF, audit history.

Stack: Next.js 16 (App Router) · TypeScript · Tailwind CSS 4 · Supabase (Postgres, Auth, Realtime) ·
Zod · IndexedDB outbox + service worker · Vercel.

Setup, environment variables, migrations, tests, backup and deployment: [`docs/OPERATIONS.md`](docs/OPERATIONS.md).
Security model and known issues: [`docs/SECURITY.md`](docs/SECURITY.md).

```bash
npm ci && supabase start && cp .env.example .env.local && npm run dev
```
