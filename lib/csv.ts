// Small RFC 4180 CSV parser and Paytm-statement helpers (D-10: the Paytm export layout is not verified,
// so the import screen maps columns explicitly instead of assuming a format).

export function parseCsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let cell = "";
  let quoted = false;
  const s = text.replace(/^﻿/, "");
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (quoted) {
      if (c === '"' && s[i + 1] === '"') { cell += '"'; i++; }
      else if (c === '"') quoted = false;
      else cell += c;
    } else if (c === '"') quoted = true;
    else if (c === ",") { row.push(cell); cell = ""; }
    else if (c === "\n" || c === "\r") {
      if (c === "\r" && s[i + 1] === "\n") i++;
      row.push(cell); cell = "";
      if (row.some((v) => v.trim() !== "")) rows.push(row);
      row = [];
    } else cell += c;
  }
  row.push(cell);
  if (row.some((v) => v.trim() !== "")) rows.push(row);
  return rows;
}

/** "1,234.50" / "₹ 1234.5" / "Rs.300" → paise, exactly (no floating point). null if not a positive amount. */
export function amountToPaise(raw: string): number | null {
  const s = raw.replace(/[₹,\s]|Rs\.?|INR/gi, "");
  const m = /^(\d+)(?:\.(\d{1,2}))?$/.exec(s);
  if (!m) return null;
  const p = Number(m[1]) * 100 + Number((m[2] ?? "").padEnd(2, "0"));
  return p > 0 ? p : null;
}

export function normaliseStatus(raw: string): "success" | "pending" | "failed" | "refunded" | null {
  const s = raw.toLowerCase();
  if (/refund/.test(s)) return "refunded";
  if (/success|completed|paid|settled/.test(s)) return "success";
  if (/pend|process|initiat/.test(s)) return "pending";
  if (/fail|declin|cancel|reject/.test(s)) return "failed";
  return null;
}

export function normaliseMethod(raw: string): "upi" | "card" | "unknown" {
  const s = raw.toLowerCase();
  if (/upi/.test(s)) return "upi";
  if (/card|debit|credit|cc|dc/.test(s)) return "card";
  return "unknown";
}

/**
 * Date/time → ISO with offset. Accepts ISO strings (with or without offset), or day-first
 * "DD-MM-YYYY HH:mm[:ss]" / "DD/MM/YYYY ..." (Indian statements). Times without an offset are IST.
 */
export function toIsoIST(raw: string): string | null {
  const s = raw.trim();
  let m = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?$/.exec(s);
  if (m) {
    const off = m[7] ? (m[7] === "Z" ? "Z" : m[7].replace(/^([+-]\d{2})(\d{2})$/, "$1:$2")) : "+05:30";
    return `${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}:${m[6] ?? "00"}${off}`;
  }
  m = /^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})[ ,T]+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(am|pm)?$/i.exec(s);
  if (m) {
    let h = Number(m[4]);
    if (m[7]) h = (h % 12) + (m[7].toLowerCase() === "pm" ? 12 : 0);
    const pad = (x: string | number) => String(x).padStart(2, "0");
    return `${m[3]}-${pad(m[2])}-${pad(m[1])}T${pad(h)}:${m[5]}:${m[6] ?? "00"}+05:30`;
  }
  return null;
}
