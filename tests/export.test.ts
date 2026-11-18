import { describe, it, expect } from "vitest";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildXlsx } from "@/lib/xlsx";
import { group, weekKey, type DayRow } from "@/lib/reports";
import { parseCsv, amountToPaise, normaliseStatus, toIsoIST } from "@/lib/csv";

const day = (date: string, service: number, variance = 0): DayRow => ({
  date, state: "approved", source: "revision", service, commission: Math.floor(service / 10000) * 1000, products: 0,
  productCash: 0, productPaytm: 0, paytm: 0, expenses: 100, expensesOutside: 0, zakat: 0, food: 0, foodShop: 0,
  opening: 200000, topUps: 0, expected: 0, counted: 0, variance, requiredFloat: 200000, retained: 200000, shortfall: 0,
  takeHome: 0, commissionHandedDrawer: 0,
});

describe("report grouping", () => {
  it("labels ISO weeks by their Monday", () => {
    expect(weekKey("2026-11-18")).toBe("2026-11-16"); // Wednesday
    expect(weekKey("2026-11-16")).toBe("2026-11-16");
    expect(weekKey("2026-11-22")).toBe("2026-11-16"); // Sunday
  });
  it("sums flows exactly and never sums balances", () => {
    const rows = [day("2026-11-16", 155000, -15000), day("2026-11-17", 1006000, 5000), day("2026-11-23", 100)];
    const w = group(rows, "week");
    expect(w).toHaveLength(2);
    expect(w[0]).toMatchObject({ label: "Week of 2026-11-16", days: 2, service: 1161000, commission: 15000 + 100000, variance: -10000, expenses: 200 });
    expect("opening" in w[0]).toBe(false);
    const m = group(rows, "month");
    expect(m[0].service).toBe(rows.reduce((a, r) => a + r.service, 0));
  });
});

describe("xlsx export", () => {
  it("writes a valid workbook whose cells contain the exact values", () => {
    const buf = buildXlsx([
      { name: "Summary", rows: [["Employee", "Sales"], ["Asha <A&B>", 1555.5], ["Bilal", 0], [null, "x"]] },
      { name: "Bad/Name?", rows: [["ok"]] },
    ]);
    const dir = mkdtempSync(join(tmpdir(), "xlsx-"));
    const f = join(dir, "t.xlsx");
    writeFileSync(f, buf);
    expect(execFileSync("unzip", ["-t", f]).toString()).toMatch(/No errors detected/);
    const sheet = execFileSync("unzip", ["-p", f, "xl/worksheets/sheet1.xml"]).toString();
    expect(sheet).toContain("<t xml:space=\"preserve\">Asha &lt;A&amp;B&gt;</t>");
    expect(sheet).toContain('<c r="B2"><v>1555.5</v></c>');
    expect(sheet).toContain('<c r="B3"><v>0</v></c>');
    const wb = execFileSync("unzip", ["-p", f, "xl/workbook.xml"]).toString();
    expect(wb).toContain('name="Bad Name "');
  });
});

describe("Paytm CSV helpers", () => {
  it("parses quoted CSV with commas, quotes and CRLF", () => {
    expect(parseCsv('a,b\r\n"x, y","say ""hi"""\r\n\r\n1,2')).toEqual([["a", "b"], ["x, y", 'say "hi"'], ["1", "2"]]);
  });
  it("converts amounts to paise without floating point", () => {
    expect(amountToPaise("1,234.50")).toBe(123450);
    expect(amountToPaise("₹ 0.1")).toBe(10);
    expect(amountToPaise("Rs.300")).toBe(30000);
    expect(amountToPaise("0")).toBeNull();
    expect(amountToPaise("-5")).toBeNull();
    expect(amountToPaise("12.345")).toBeNull();
  });
  it("normalises statuses and Indian date formats (IST when no offset)", () => {
    expect(normaliseStatus("SUCCESS")).toBe("success");
    expect(normaliseStatus("Refunded")).toBe("refunded");
    expect(normaliseStatus("TXN_FAILURE")).toBe("failed");
    expect(normaliseStatus("weird")).toBeNull();
    expect(toIsoIST("18-11-2026 09:05 pm")).toBe("2026-11-18T21:05:00+05:30");
    expect(toIsoIST("2026-11-18 21:05:07")).toBe("2026-11-18T21:05:07+05:30");
    expect(toIsoIST("2026-11-18T15:35:07Z")).toBe("2026-11-18T15:35:07Z");
    expect(toIsoIST("yesterday")).toBeNull();
  });
});

import { guessPaytmColumns } from "@/lib/csv";

describe("guessPaytmColumns", () => {
  it("does not take a 'Transaction Date' column as the transaction ID", () => {
    const g = guessPaytmColumns(["Transaction Date", "Order ID", "Amount", "Status", "Payment Mode"]);
    expect(g).toEqual({ ref: 1, time: 0, amount: 2, status: 3, method: 4 });
  });
});
