// Plain-language labels for codes coming from the database (SRS §9.1: avoid jargon on staff screens).

export const BLOCKERS: Record<string, string> = {
  closing_frozen: "This day is already submitted or approved.",
  paytm_missing: "Enter today's Paytm total (enter 0 if there was none).",
  split_mismatch: "UPI + card do not add up to the Paytm total.",
  count_missing: "Count the cash in the drawer by denomination.",
  variance_reason_missing: "Counted cash differs from expected: write a reason.",
  take_home_by_missing: "Write who takes the extra cash home.",
  food_excess_unallocated: "Food cost is more than the commission. Management must approve the extra (shop pays).",
  previous_day_not_submitted: "Submit the previous day's closing first.",
  initial_float_missing: "The owner must set up the starting cash float first (Admin → Float).",
  late_entries_undecided: "Some late entries need a management decision (include or exclude).",
  closing_employee_missing: "Choose who performed the closing.",
  closing_employee_invalid: "The employee chosen for the closing was not working here on this day. Choose again.",
};

export const WARNINGS: Record<string, string> = {
  unassigned_entries: "Some offline entries could not be dated automatically and may belong to this day.",
  service_paytm_negative: "Paytm total is less than product Paytm sales.",
  service_paytm_exceeds_services: "Paytm for services is more than all service sales.",
  paytm_import_mismatch: "Paytm total differs from the imported Paytm transactions.",
  paytm_recorded_mismatch: "Paytm total differs from the UPI / Paytm / Card sales recorded at the counter.",
};

export const ACKS: Record<string, string> = {
  variance: "Cash difference",
  service_paytm_negative: "Paytm less than product Paytm",
  service_paytm_exceeds_services: "Paytm more than service sales",
  unassigned_entries: "Undated offline entries",
};

export const STATES: Record<string, { label: string; tone: string }> = {
  draft: { label: "Open", tone: "bg-slate-100 text-slate-800" },
  submitted: { label: "Submitted — awaiting approval", tone: "bg-amber-100 text-amber-900" },
  approved: { label: "Approved", tone: "bg-emerald-100 text-emerald-900" },
  rejected: { label: "Rejected — needs changes", tone: "bg-rose-100 text-rose-900" },
  reopened: { label: "Reopened for correction", tone: "bg-sky-100 text-sky-900" },
};

export const SETTLEMENT: Record<string, string> = {
  not_handed: "Not handed over",
  partial: "Partly handed over",
  complete: "Fully handed over",
  over_handed_unresolved: "Over-handed — return or accept needed",
  over_handed_accepted: "Over-handed — accepted by management",
};

export const KIND: Record<string, string> = {
  service: "Service",
  product: "Product",
  expense: "Expense",
  zakat: "Zakat",
  food: "Food",
};

/** How a service or product sale was paid. UPI and card are settled through Paytm (one channel). */
export const PAID_BY: Record<string, string> = { cash: "Cash", paytm: "UPI / Paytm / Card", split: "Split (Cash + UPI / Paytm / Card)" };

/**
 * An entry corrected at least once. Only a correction or a void raises `version` (+1 each, a void at most
 * once and last), so corrections = version − 1 − (voided ? 1 : 0). New and merely voided entries are not edited.
 */
export const isEdited = (e: { version: number; status: string }) => e.version - (e.status === "voided" ? 2 : 1) > 0;

export const FLAGS: Record<string, string> = {
  clock_offset: "device clock off",
  future_time: "time in the future",
  long_gap: "synced very late",
  estimated_date: "date estimated",
  timestamp_suspect: "time not trusted",
  seq_order: "out of order",
};

/** Turn a Postgres/PostgREST error into a message for the screen. */
export function friendlyError(e: { message?: string; code?: string } | null | undefined): string {
  if (!e) return "Something went wrong.";
  if (e.code === "42501") return "You do not have permission to do this.";
  if (e.code === "23505" && !/initial float/.test(e.message ?? "")) return e.message ?? "Already exists.";
  const blocked = e.message?.match(/^closing cannot be submitted: (.*)$/);
  if (blocked) return `Cannot submit yet: ${blocked[1].split(", ").map((b) => BLOCKERS[b] ?? b).join(" ")}`;
  return e.message ?? "Something went wrong.";
}
