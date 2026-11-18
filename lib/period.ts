import { MAX_DAYS } from "@/lib/reports";

const D = /^\d{4}-\d{2}-\d{2}$/;

/** Validated report period from query params (defaults: this month to date, by day). */
export function parsePeriod(sp: Record<string, string | undefined>, today: string):
  { from: string; to: string; by: "day" | "week" | "month" } | { error: string } {
  const from = sp.from && D.test(sp.from) ? sp.from : today.slice(0, 8) + "01";
  const to = sp.to && D.test(sp.to) ? sp.to : today;
  const by = sp.by === "week" || sp.by === "month" ? sp.by : "day";
  const span = (Date.parse(to) - Date.parse(from)) / 86_400_000;
  if (Number.isNaN(span) || span < 0) return { error: "The start date must be on or before the end date." };
  if (span >= MAX_DAYS) return { error: `Choose a period of at most ${MAX_DAYS} days.` };
  return { from, to, by };
}
