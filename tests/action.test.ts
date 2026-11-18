import { describe, it, expect } from "vitest";
import { optionalRupeesToPaise } from "@/lib/action";

describe("optionalRupeesToPaise", () => {
  const p = optionalRupeesToPaise("Paytm");
  it("treats a blank field as not entered, not ₹0", () => {
    expect(p.parse("")).toBeNull();
    expect(p.parse(undefined)).toBeNull();
  });
  it("keeps an explicit 0 and converts rupees to paise", () => {
    expect(p.parse("0")).toBe(0);
    expect(p.parse("700")).toBe(70000);
  });
  it("rejects fractions and negatives", () => {
    expect(p.safeParse("12.5").success).toBe(false);
    expect(p.safeParse("-1").success).toBe(false);
  });
});

import { friendlyError, BLOCKERS } from "@/lib/labels";

describe("friendlyError", () => {
  it("turns submit blocker codes into plain-language labels", () => {
    const msg = friendlyError({ message: "closing cannot be submitted: food_excess_unallocated, paytm_missing" });
    expect(msg).toBe(`Cannot submit yet: ${BLOCKERS.food_excess_unallocated} ${BLOCKERS.paytm_missing}`);
    expect(msg).not.toMatch(/_/);
  });
});
