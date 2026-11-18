import { describe, it, expect } from "vitest";
import { commissionPool, allocateCommission, cashModel, type CashInput } from "@/lib/accounting";
import { rupees, signedRupees, parseRupees } from "@/lib/money";

const R = (r: number) => r * 100; // rupees → paise

describe("money", () => {
  it("formats Indian grouping in whole rupees", () => {
    expect(rupees(R(123450))).toBe("₹1,23,450");
    expect(rupees(-R(150))).toBe("−₹150");
    expect(signedRupees(R(50))).toBe("+₹50");
    expect(rupees(12345)).toBe("₹123.45");
  });
  it("parses whole-rupee input only", () => {
    expect(parseRupees("1,550")).toBe(155000);
    expect(parseRupees("10.5")).toBeNull();
    expect(parseRupees("0")).toBeNull();
    expect(parseRupees("-5")).toBeNull();
  });
});

describe("commission (D1)", () => {
  it("rounds the pool down to ₹10 (SRS §3.1)", () => {
    expect(commissionPool(R(15550))).toBe(R(1550));
    expect(commissionPool(R(10060))).toBe(R(1000));
    expect(commissionPool(R(99))).toBe(0);
    expect(commissionPool(0)).toBe(0);
  });

  it("allocates by largest remainder with exact/rounding columns (Rev 6 §5.1)", () => {
    const a = allocateCommission({ A: R(3090), B: R(4090), C: R(2880) });
    expect(a.map((x) => [x.staffId, x.exactShare, x.allocated, x.roundingAdj])).toEqual([
      ["A", R(309), R(310), R(1)], ["B", R(409), R(410), R(1)], ["C", R(288), R(280), -R(8)],
    ]);
    expect(a.reduce((s, x) => s + x.roundingAdj, 0)).toBe(-R(6));
  });

  it("breaks remainder ties by higher sales, then staff id", () => {
    const a = allocateCommission({ c: R(1000), b: R(1150), a: R(1150) });
    expect(Object.fromEntries(a.map((x) => [x.staffId, x.allocated]))).toEqual({ a: R(120), b: R(110), c: R(100) });
  });

  it("shares always sum to the pool (randomised)", () => {
    let seed = 42;
    const rnd = () => (seed = (seed * 1103515245 + 12345) % 2 ** 31) / 2 ** 31;
    for (let n = 0; n < 500; n++) {
      const sales: Record<string, number> = {};
      const k = 1 + Math.floor(rnd() * 8);
      for (let i = 0; i < k; i++) sales[`s${i}`] = R(Math.floor(rnd() * 20000));
      const total = Object.values(sales).reduce((x, y) => x + y, 0);
      const a = allocateCommission(sales);
      expect(a.reduce((x, y) => x + y.allocated, 0)).toBe(commissionPool(total));
      a.forEach((x) => expect(Math.abs(x.roundingAdj)).toBeLessThan(R(10)));
    }
  });
});

// Rev 6 §5.3 worked examples — the same cases are asserted against app.cash_model in pgTAP (07).
const base: CashInput = {
  R: R(2000), PF: 0, I: 0, S: R(15550), P: R(1200), paytm: R(6400), E: R(500), Z: R(50),
  F: R(700), f_today: R(700), f_prior: 0, H: R(850), CC: 0, RF: R(2000),
};
const cases: [string, Partial<CashInput>, Record<string, number>][] = [
  ["A normal", { CC: R(10250) }, { N: R(8250), ED: R(10250), V: 0, AF: R(2000), FS: 0, TH: R(8250) }],
  ["B shortage", { CC: R(10100) }, { V: -R(150), TH: R(8100) }],
  ["C surplus", { CC: R(10300) }, { V: R(50), TH: R(8300) }],
  ["D shortfall", { paytm: R(15000), CC: R(1650) }, { N: -R(350), ED: R(1650), AF: R(1650), FS: R(350), TH: 0 }],
  ["E RF raised", { RF: R(3000), CC: R(10250) }, { AF: R(3000), TH: R(7250) }],
  ["F shortage+shortfall", { paytm: R(15000), CC: R(1600) }, { V: -R(50), AF: R(1600), FS: R(400) }],
  ["G intraday", { I: R(500), CC: R(10750) }, { O: R(2000), ED: R(10750), V: 0, TH: R(8750) }],
  ["H pre-opening", { PF: R(1000), RF: R(3000), CC: R(11250) }, { O: R(3000), ED: R(11250), AF: R(3000), TH: R(8250) }],
  ["J partial handover", { H: R(500), CC: R(10600) }, { Rc: R(350), ED: R(10600), V: 0, TH: R(8600) }],
  ["K unpaid food", { f_today: 0, CC: R(10950) }, { U: R(700), ED: R(10950), TH: R(8950) }],
  ["L prior food", { f_prior: R(700), CC: R(9550) }, { Fd: R(1400), ED: R(9550), TH: R(7550) }],
  ["M correction", { S: R(15450), CC: R(10150) }, { C: R(1540), payable: R(840), Rc: -R(10), ED: R(10150), V: 0 }],
];

describe("cash model (§5.3)", () => {
  it.each(cases)("%s", (_name, input, expected) => {
    const out = cashModel({ ...base, ...input });
    for (const [k, v] of Object.entries(expected)) expect(out[k as keyof typeof out], k).toBe(v);
  });

  it.each(cases)("bridge identity holds for %s", (_name, input) => {
    const i = { ...base, ...input };
    const o = cashModel(i);
    expect(o.ED).toBe(o.O + i.I + o.N + o.Rc + o.U - i.f_prior - o.FX);
    expect(o.AF + o.TH).toBe(i.CC);
  });

  it("food above the pool: FC = C, FX = F − C, payable 0 (D2/B6)", () => {
    const o = cashModel({ ...base, S: R(10000), F: R(1500), f_today: 0, H: 0 });
    expect([o.C, o.FC, o.FX, o.payable]).toEqual([R(1000), R(1000), R(500), 0]);
  });

  it("food is never deducted twice: changing food cost alone does not change N (SRS §3.3)", () => {
    expect(cashModel({ ...base, F: R(100) }).N).toBe(cashModel({ ...base, F: R(700) }).N);
  });

  it("product sales are excluded from commission", () => {
    expect(cashModel({ ...base, P: R(50000) }).C).toBe(cashModel(base).C);
  });
});
