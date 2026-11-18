// TypeScript mirror of the database accounting (Rev 6 §5) for live/offline previews on the Register.
// The database (app.cash_model / app.compute_day) is the authority; submit always recomputes there.
// Both are tested against the same worked examples (tests/accounting.test.ts, supabase/tests/07).

/** D1: pool = FLOOR(S × 10% / ₹10) × ₹10, in paise. */
export function commissionPool(servicePaise: number): number {
  return Math.floor(servicePaise / 10000) * 1000;
}

export type Allocation = {
  staffId: string;
  serviceTotal: number;
  exactShare: number;
  allocated: number;
  roundingAdj: number;
};

/** D1: largest remainder in ₹10 units; ties → higher sales, then staff id. Shares sum to the pool. */
export function allocateCommission(sales: Record<string, number>): Allocation[] {
  const rows = Object.entries(sales).map(([staffId, st]) => ({
    staffId,
    st,
    fl: Math.floor(st / 10000),
    rem: st % 10000,
  }));
  const total = rows.reduce((a, r) => a + r.st, 0);
  let leftover = commissionPool(total) / 1000 - rows.reduce((a, r) => a + r.fl, 0);
  const order = [...rows].sort(
    (a, b) => b.rem - a.rem || b.st - a.st || (a.staffId < b.staffId ? -1 : a.staffId > b.staffId ? 1 : 0),
  );
  const extra = new Set<string>();
  for (const r of order) {
    if (leftover-- <= 0) break;
    extra.add(r.staffId);
  }
  return rows.map((r) => {
    const allocated = (r.fl + (extra.has(r.staffId) ? 1 : 0)) * 1000;
    const exactShare = r.st / 10; // exact: amounts are whole rupees
    return { staffId: r.staffId, serviceTotal: r.st, exactShare, allocated, roundingAdj: allocated - exactShare };
  });
}

export type CashInput = {
  R: number; PF: number; I: number; S: number; P: number; paytm: number; E: number; Z: number;
  F: number; f_today: number; f_prior: number; H: number; CC: number; RF: number;
};

/** §5.3 cash model (J1, J2). Mirrors app.cash_model exactly. */
export function cashModel(i: CashInput) {
  const C = commissionPool(i.S);
  const FC = Math.min(i.F, C);
  const FX = i.F - FC;
  const O = i.R + i.PF;
  const CS = i.S + i.P - i.paytm;
  const Fd = i.f_today + i.f_prior;
  const ED = O + i.I + CS - i.E - i.Z - Fd - i.H;
  return {
    C, FC, FX, payable: C - FC, O, CS,
    N: i.S - C + i.P - i.paytm - i.E - i.Z,
    Fd, U: i.F - i.f_today, Rc: C - FC - i.H, ED, V: i.CC - ED,
    AF: Math.min(i.CC, i.RF), FS: Math.max(0, i.RF - i.CC), TH: Math.max(0, i.CC - i.RF),
  };
}

export type FoodPayment = { id: string; amount: number; reverses_payment_id: string | null };

/** Net paid on a food entry and the payments not yet reversed (a reversal row points at its original). */
export function foodPaid(payments: FoodPayment[]): { paid: number; activeIds: string[] } {
  const reversed = new Set(payments.map((p) => p.reverses_payment_id).filter(Boolean));
  const originals = payments.filter((p) => !p.reverses_payment_id);
  const active = originals.filter((p) => !reversed.has(p.id));
  return { paid: active.reduce((a, p) => a + p.amount, 0), activeIds: active.map((p) => p.id) };
}
