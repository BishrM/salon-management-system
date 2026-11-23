import { describe, it, expect } from "vitest";
import { isEdited, PAID_BY } from "@/lib/labels";

describe("EDITED tag (client feature 5)", () => {
  it("marks entries corrected at least once, never new or merely removed ones", () => {
    expect(isEdited({ version: 1, status: "active" })).toBe(false); // new
    expect(isEdited({ version: 2, status: "voided" })).toBe(false); // removed, never corrected
    expect(isEdited({ version: 2, status: "active" })).toBe(true); // corrected once
    expect(isEdited({ version: 3, status: "voided" })).toBe(true); // corrected, then removed
  });
});

describe("payment method labels (client feature 4)", () => {
  it("shows the counter options (cash, UPI / Paytm / Card combined, split)", () => {
    expect(PAID_BY).toEqual({ cash: "Cash", paytm: "UPI / Paytm / Card", split: "Split (Cash + UPI / Paytm / Card)" });
  });
});
