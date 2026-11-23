// Shape of app.compute_day / public.day_summary (keys match closing_revisions columns).
export type Allocation = {
  staff_id: string; staff_name: string; service_total: number; exact_share: number; allocated: number; rounding_adj: number;
};

export type Settlement = {
  allowed: number; gross_handed: number; handed_outside_drawer: number; returned: number; drawer_net: number;
  net_transferred: number; excess: number; accepted_overpayment: number; unresolved_excess: number; outstanding: number;
  status: string;
};

export type DaySummary = {
  outlet_id: string; business_date: string; closing_id: string | null; state: string;
  current_revision_id: string | null; current_revision_no: number | null; needs_review: boolean;
  paytm_total: number; paytm_entered: boolean; paytm_upi: number | null; paytm_card: number | null;
  denominations: Record<string, number>; variance_reason: string | null; take_home_by: string | null;
  paytm_imported_success_total: number; paytm_imported_count: number;
  retained_float_carried: number; opening_float_source_revision_id: string | null; initial_float_movement_id: string | null;
  pre_opening_funding: number; opening_float: number; intraday_top_ups: number;
  service_total: number; commission_pool: number; product_total: number; product_cash: number; product_paytm: number;
  service_paytm: number; cash_sales: number; expenses_total: number; expenses_outside_total: number; zakat_total: number;
  food_cost: number; food_commission_funded: number; food_shop_funded: number; remaining_payable: number;
  // …001800: breakfast paid by the salon and lunch/dinner above the commission owed by employees (D-31).
  food_breakfast_salon: number; food_employee_owed: number;
  /** Employee who physically performed the closing (attribution only; D-30). */
  closed_by_staff_id: string | null;
  food_paid_drawer_today: number; food_paid_drawer_prior: number; food_paid_drawer: number; food_not_paid_drawer: number;
  drawer_handover_total: number; commission_retained: number; net_cash: number; expected_drawer: number;
  counted_cash: number; variance: number; required_float: number; retained_float: number; float_shortfall: number;
  take_home: number; paytm_flags: string[];
  // day_summary only (counter-recorded service payment methods, …001500).
  service_cash_recorded: number; service_paytm_recorded: number; service_method_unrecorded: number; paytm_recorded_total: number; blockers: string[]; warnings: string[];
  // day_summary only (…002200): tips (never sales) and Paytm statement total − counter-recorded Paytm (null until entered).
  tips_cash: number; tips_paytm: number; paytm_difference: number | null;
  entries_snapshot: { id: string }[];
  allocations: Allocation[]; settlement: Settlement | null;
};

/** A stored revision has the same numeric fields. */
export type Revision = Omit<DaySummary, "state" | "blockers" | "warnings" | "allocations" | "settlement" | "needs_review" | "closing_id"
  | "current_revision_id" | "current_revision_no" | "paytm_entered" | "paytm_imported_success_total" | "paytm_imported_count"> & {
  id: string; closing_id: string; revision_no: number; submitted_by: string; submitted_at: string; included_late_entry_ids: string[];
};
