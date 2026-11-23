import { describe, expect, it } from "vitest";
import { worksOn } from "@/lib/staff";

// W1: Register employee list on and around the deactivation business date.
describe("worksOn", () => {
  const esha = { active: false, inactive_from: "2026-11-24" }; // deactivated during business day 23 Nov

  it("active employee works on any date", () => {
    expect(worksOn({ active: true, inactive_from: null }, "2026-11-23")).toBe(true);
  });
  it("deactivated employee still works on earlier dates", () => {
    expect(worksOn(esha, "2026-11-22")).toBe(true);
  });
  it("stays available for the whole deactivation business date", () => {
    expect(worksOn(esha, "2026-11-23")).toBe(true);
  });
  it("is unavailable from the next business date", () => {
    expect(worksOn(esha, "2026-11-24")).toBe(false);
    expect(worksOn(esha, "2026-11-25")).toBe(false);
  });
  it("deactivated before dated deactivation existed: never works", () => {
    expect(worksOn({ active: false, inactive_from: null }, "2026-11-23")).toBe(false);
  });
});
