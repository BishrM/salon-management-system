// Money is integer paise everywhere (₹1 = 100). Never use floating point for amounts.

const fmt = new Intl.NumberFormat("en-IN", { maximumFractionDigits: 0 });

/** "₹1,23,450" from paise (whole rupees; paise shown only if present). */
export function rupees(paise: number | null | undefined): string {
  if (paise == null) return "—";
  const neg = paise < 0;
  const abs = Math.abs(paise);
  const whole = Math.trunc(abs / 100);
  const frac = abs % 100;
  return `${neg ? "−" : ""}₹${fmt.format(whole)}${frac ? "." + String(frac).padStart(2, "0") : ""}`;
}

/** Signed variant for variances: "+₹50", "−₹150", "₹0". */
export function signedRupees(paise: number): string {
  return paise > 0 ? `+${rupees(paise)}` : rupees(paise);
}

/** Parse a whole-rupee input ("1,550" or "1550") into paise; null if not a positive whole number. */
export function parseRupees(input: string): number | null {
  const clean = input.replace(/[,\s₹]/g, "");
  if (!/^\d{1,7}$/.test(clean)) return null;
  const r = Number(clean);
  return r > 0 ? r * 100 : null;
}

/** Same as parseRupees but allows 0 (Paytm totals, counts). */
export function parseRupeesAllowZero(input: string): number | null {
  const clean = input.replace(/[,\s₹]/g, "");
  if (!/^\d{1,9}$/.test(clean)) return null;
  return Number(clean) * 100;
}
