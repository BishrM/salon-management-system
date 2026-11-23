// An employee works on a business date until the date they are inactive from (same rule as
// app.staff_assigned in the database). A deactivated row with no date was deactivated before dated
// deactivation existed and is inactive on every date.
export function worksOn(s: { active: boolean; inactive_from: string | null }, date: string) {
  return s.active || (s.inactive_from !== null && date < s.inactive_from);
}
