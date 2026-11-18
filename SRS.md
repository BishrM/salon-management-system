# HUDCO Big Boss
## Software Requirements Specification (SRS)

**Project:** Salon Daily Operations & Accounting Management System  
**Initial deployment:** HUDCO Big Boss, Mysuru  
**Document status:** Initial requirements baseline — ready for technical planning  
**Prepared for:** Project development using Claude Code

---

# 1. Project Overview

## 1.1 Purpose

Develop a secure, simple, mobile-friendly web application to digitise the daily sales recording, commission calculation, product sales, cash reconciliation and closing operations of HUDCO Big Boss.

The application will replace the existing paper-based accounting workflow while preserving the salon's current business rules.

The owner should be able to monitor live sales, review daily financial records, inspect changes and approve daily closings remotely.

## 1.2 Initial Scope

The first production deployment will support only HUDCO Big Boss.

The underlying database should retain an `outlet_id` field so additional outlets can be introduced later without redesigning the core data model.

The initial release must not contain unnecessary workflows for Royal Crown or Elite Crown.

## 1.3 Business Address

**HUDCO Big Boss**

2, HUDCO Main Road, Jayalakshmipuram, Bannimantap A Layout, Bannimantap, Mysuru, Karnataka 570015, India.

---

# 2. Business Requirements

## 2.1 Existing Operating Workflow

- A common daily service register is maintained for all employees.
- A designated counter operator records individual service amounts against the employee who performed the service.
- Discounts are already deducted before the final service amount is recorded.
- Employee service totals are calculated throughout the day.
- Product sales are recorded separately.
- Expenses are recorded individually with descriptions and amounts.
- The owner or owner's son normally handles final daily closing.
- An authorised employee can handle closing when management is unavailable.

The application should digitise this workflow without forcing unnecessary operational changes.

## 2.2 Employee Service Sales

Each service sale must contain:

- Employee.
- Amount received after any discount.
- Date and time.
- User who recorded the entry.
- Outlet.
- Unique transaction identifier.

Requirements:

- Multiple entries per employee per day.
- Automatic employee-wise totals.
- Automatic daily service sales total.
- Live updates on the owner dashboard.
- Individual entry history.
- Corrections must preserve the original entry and its change history.

Service names do not need to be recorded in the first release.

## 2.3 Discounts

Preserve the existing process.

Only the final discounted service amount is recorded.

Do not introduce mandatory original-price and discount fields in the first release.

## 2.4 Product Sales

Product sales are independent of employee service sales.

Each product sale should record:

- Product name.
- Quantity.
- Selling price per unit.
- Total selling amount.
- Payment method: cash or Paytm.
- Timestamp.
- Recording user.

Formula:

`Product total = Quantity × Selling price per unit`

Product sales must not generate employee commission.

---

# 3. Accounting Rules

## 3.1 Employee Commission

The commission rate is 10% of total employee service sales.

Commission is rounded down to the nearest ₹10.

Formula:

`Commission = FLOOR((Service Sales × 0.10) / 10) × 10`

Example:

| Description | Amount |
|---|---:|
| Employee service sales | ₹15,550 |
| Commission before rounding | ₹1,555 |
| Commission after rounding | ₹1,550 |
| Remaining service sales | ₹14,000 |

Commission is calculated on the combined service sales total, not separately rounded for each employee.

Product sales are excluded from commission calculations.

Commission is paid in physical cash.

## 3.2 Commission Distribution

The system must generate an employee-wise commission statement.

Example:

| Employee | Service sales | Commission |
|---|---:|---:|
| Employee A | ₹3,000 | ₹300 |
| Employee B | ₹4,000 | ₹400 |
| Employee C | ₹2,500 | ₹250 |
| **Total** | **₹9,500** | **₹950** |

The statement must be printable and suitable for handing to the head employee.

It should contain:

- Outlet and business date.
- Employee names.
- Employee-wise service sales.
- Employee-wise commission.
- Total service sales.
- Total commission.
- Food deduction.
- Remaining commission cash.
- Recipient/head employee.
- Distribution status.

## 3.3 Employee Food Deductions

Breakfast and lunch food deliveries are paid for using the commission cash allocation.

Example:

| Description | Amount |
|---|---:|
| Total commission | ₹1,500 |
| Food cost | -₹700 |
| Remaining commission | ₹800 |

The system must record food costs separately from ordinary shop expenses.

Food costs are deducted from the commission pool. They must not be deducted a second time from the shop's ordinary cash closing calculation.

The system should support recording food deductions by meal and amount.

## 3.4 Payment Methods

The application must distinguish:

1. Physical cash.
2. Paytm collections.

Paytm includes both:
- UPI payments.
- Card payments accepted through Paytm.

Each outlet has its own Paytm QR code and merchant account.

The application should not count Paytm UPI and card transactions twice.

Where available, show the UPI/card breakdown while retaining the combined Paytm total for closing.

## 3.5 Daily Closing Calculation

The closing process should follow this sequence:

**Step 1: Calculate service sales**

Sum all employee service sales, regardless of payment method.

**Step 2: Calculate commission**

Deduct the 10% commission, rounded down to the nearest ₹10.

**Step 3: Add product sales**

Add product sales from cash and Paytm.

**Step 4: Reconcile Paytm**

Subtract Paytm collections to determine the expected physical cash balance.

**Step 5: Deduct ordinary cash expenses and Zakat**

Zakat represents small cash donations made by employees to beggars or charity.

**Step 6: Reconcile rolling cash**

Compare the remaining physical cash against the required next-day float.

**Core formula:**

`Expected Physical Cash = Service Sales - Commission + Product Sales - Paytm - Ordinary Expenses - Zakat`

The commission pool is handled separately. Food payments are deducted from that pool, not again from ordinary expenses.

The final physical cash and rolling cash movements must be recorded independently.

## 3.6 Rolling Cash

Each outlet maintains a fixed cash float for providing change.

Requirements:

- Record the previous day's float.
- Record the next day's required float.
- Allow only the owner or owner's son to change the float.
- Record every float adjustment with user and timestamp.
- Support denomination-wise counting.
- Calculate the difference between expected and counted cash.
- Record cash added to or removed from the float.

The system must distinguish between:
- Cash available before float adjustment.
- Required next-day float.
- Cash surplus or shortfall.
- Final cash taken home.

A shortfall must be recorded explicitly rather than silently hidden by changing the float.

## 3.7 Cash Denomination Counting

Support the following denominations initially:

- ₹10
- ₹20
- ₹50
- ₹100
- ₹200
- ₹500

Each denomination entry should have:

`Denomination × Quantity = Subtotal`

The application automatically calculates the total counted cash.

The denomination list should be configurable by management if required.

---

# 4. Daily Expenses and Zakat

## 4.1 Ordinary Expenses

Each expense must record:

- Description.
- Amount.
- Date and time.
- Recording user.
- Payment source.
- Optional notes.

Examples include supplies, utilities, repairs and other daily shop expenses.

## 4.2 Zakat

Record Zakat separately from ordinary expenses.

Fields:

- Amount.
- Date.
- Recording employee.
- Optional description.

Zakat must be deducted from physical cash during closing.

---

# 5. User Roles and Permissions

The initial application supports these roles.

## 5.1 Owner

Full access to:

- Live dashboard.
- Sales records.
- Daily closing reports.
- Historical records.
- Employee management.
- Financial reports.
- Paytm reconciliation.
- Rolling cash changes.
- Closing approval.
- User management.
- Audit history.

## 5.2 Owner's Son

Management access, including:

- Live sales.
- Closing preparation and review.
- Closing approval.
- Rolling cash adjustments.
- Employee management.
- Historical reports.

## 5.3 Head Employee

Operational access, including:

- Viewing outlet sales.
- Recording authorised sales and expenses.
- Preparing daily closing.
- Viewing employee commission statements.
- Recording commission distribution.

## 5.4 Acting Head Employee

Temporary delegated head access when the regular head employee is unavailable.

The delegation must have a start time, end time and authorising manager.

## 5.5 Counter Operator

Access to:

- Recording employee service sales.
- Recording product sales.
- Recording expenses.
- Viewing relevant daily totals.
- Assisting with daily closing.

No general employee accounts are required in the initial release.

---

# 6. Closing Approval and Audit History

## 6.1 Closing Status

Each daily closing should support:

- Draft.
- Submitted.
- Approved.
- Rejected.
- Reopened or corrected.

## 6.2 Editing Rules

Employees are trusted to correct ordinary mistakes.

The system must allow authorised corrections without silently overwriting previous values.

For each correction, preserve:

- Original value.
- New value.
- User responsible.
- Timestamp.
- Reason where appropriate.

The owner must be able to inspect the change history.

## 6.3 Approval

The owner or authorised management user can approve or reject a submitted closing.

A rejected closing should return to an editable state with the rejection reason.

Approved closings should remain historically traceable. Subsequent changes must create an auditable correction record.

---

# 7. Live Dashboard and Reporting

## 7.1 Live Dashboard

The owner should be able to see:

- Today's service sales.
- Employee-wise service sales.
- Product sales.
- Commission calculated.
- Paytm collections.
- Physical cash estimate.
- Expenses.
- Zakat.
- Current closing status.
- Recent recorded entries.

Individual entries must display timestamps.

## 7.2 Historical Records

Provide a date-based history interface.

Management should be able to:

- Select a date.
- View the complete daily closing.
- View employee-wise sales.
- View product sales.
- View expenses and Zakat.
- View denomination counts.
- View commission distribution.
- View corrections and approval history.

## 7.3 Reports

Generate:

- Daily reports.
- Weekly reports.
- Monthly reports.
- Employee sales reports.
- Employee commission reports.
- Product sales reports.
- Expense reports.
- Cash reconciliation reports.

Allow PDF and Excel export.

---

# 8. Employee Break Management

Four short breaks of approximately 20–25 minutes are allowed per employee per day, separate from breakfast and lunch.

The outlets already maintain a paper break sheet.

For the initial release, retain the existing paper process.

Do not make digital break management a launch requirement. It can be introduced later as an optional module.

---

# 9. User Interface Requirements

## 9.1 General

- English only.
- Simple, clean interface.
- Minimal training required.
- Large buttons and readable text.
- Avoid unnecessary financial terminology on employee-facing screens.
- Clear confirmation before important submissions.
- Responsive layouts.

## 9.2 Devices

| User | Primary device |
|---|---|
| Owner | Mobile phone and laptop |
| Owner's son | Mobile phone and laptop |
| Counter operator | Tablet |
| Head employee | Phone or tablet |

The application should be mobile-first and tablet-friendly.

No separate native Android or iOS application is required.

---

# 10. Offline Operation and Synchronisation

Reliable operation during temporary internet outages is required.

## Requirements

- Application shell should load when previously cached.
- Sales, product sales and expenses should be saved locally when offline.
- Use IndexedDB for durable local storage.
- Each record must have a globally unique identifier.
- Preserve the original event timestamp.
- Queue unsynchronised records.
- Synchronise automatically when connectivity returns.
- Show pending, synchronised and failed status.
- Prevent duplicate entries during retries.
- Provide a way to inspect failed synchronisations.

Financial records must never be silently discarded.

Conflicts should be handled explicitly. Do not use last-write-wins for financial entries.

Closing approval and Paytm reconciliation require a successful server connection.

---

# 11. Paytm Integration

Each outlet uses its own Paytm merchant account and QR code.

The integration should:

- Retrieve available payment transaction data using official Paytm merchant APIs.
- Reconcile successful transactions against the relevant business day.
- Distinguish successful, pending, failed and refunded transactions where supported.
- Prevent duplicate transaction imports.
- Display total Paytm collections.
- Provide transaction-level references for audit.
- Support manual reconciliation if the API is unavailable.

The integration must be based on actual merchant API access and verified account capabilities.

Do not assume that the existing Paytm mobile app's transaction history is directly accessible.

API credentials must remain server-side and must never be exposed to browser code.

Paytm integration is a dependency that must be validated before it is treated as complete.

---

# 12. Proposed Technical Architecture

| Layer | Technology |
|---|---|
| Frontend | Next.js |
| Language | TypeScript |
| Styling | Tailwind CSS |
| UI components | shadcn/ui |
| Backend | Next.js server-side route handlers |
| Database | Supabase PostgreSQL |
| Authentication | Supabase Auth |
| Validation | Zod |
| Offline storage | IndexedDB |
| Hosting | Vercel |
| Charts | Recharts |

Use server-side validation and financial calculations.

All currency calculations should use integer paise or an equivalent exact numeric representation. Avoid floating-point arithmetic for money.

Supabase service-role credentials must never be exposed to the client.

---

# 13. Initial Database Design

The following is a proposed logical model. Final tables, keys, constraints and relationships should be refined during Plan Mode.

## Core tables

1. `outlets`
2. `profiles`
3. `outlet_memberships`
4. `staff`
5. `staff_assignments`
6. `service_sales`
7. `product_catalog`
8. `product_sales`
9. `expenses`
10. `zakat_entries`
11. `paytm_transactions`
12. `daily_closings`
13. `cash_denominations`
14. `rolling_cash_movements`
15. `commission_records`
16. `commission_food_deductions`
17. `commission_distributions`
18. `closing_approvals`
19. `audit_logs`
20. `sync_records`

## Database principles

- Use UUID primary keys.
- Store monetary amounts accurately.
- Include `outlet_id` on outlet-specific records.
- Use foreign keys and database constraints.
- Preserve historical employee assignments.
- Use server-side transactions for financial operations.
- Avoid deleting financial records permanently.
- Maintain timestamps for creation and modification.
- Enforce role permissions on the backend and database.
- Use Row Level Security where appropriate.

---

# 14. Security Requirements

- Authenticated access only.
- Role-based permissions.
- Outlet-level data isolation.
- Server-side authorisation for sensitive operations.
- Audit logging for financial modifications.
- Secure session management.
- Secrets stored in environment variables.
- No Paytm credentials in client-side code.
- Regular database backups.
- Protected production environment.
- No unauthorised modification of approved financial records.

The owner and owner's son must have exclusive control over rolling cash adjustments.

---

# 15. Testing and Acceptance Criteria

The application must not go live until the following are verified.

## Accounting tests

- Commission calculation.
- Commission rounding.
- Employee-wise commission totals.
- Product sales excluded from commission.
- Paytm reconciliation.
- Cash reconciliation.
- Expense deductions.
- Zakat deductions.
- Rolling cash adjustments.
- Food deductions from commission.
- No double deduction of food costs.
- Denomination calculations.

## Functional tests

- Sales entry creation and correction.
- Product sales recording.
- Expense recording.
- Daily closing submission.
- Closing approval and rejection.
- Historical report retrieval.
- Commission statement generation.
- User permission enforcement.
- Employee assignment changes.

## Offline tests

- Creating records without internet.
- Reconnecting and synchronising.
- Retrying failed requests.
- Preventing duplicate financial records.
- Handling edits to unsynchronised entries.
- Preserving timestamps.

## Security tests

- Unauthorised access attempts.
- Role escalation attempts.
- Cross-outlet access protection.
- Audit history integrity.
- API credential protection.

## Live rollout acceptance

The first release should be tested alongside the existing paper process.

Compare actual paper totals and application totals across representative business days before switching to the application as the primary accounting record.

---

# 16. Deployment Strategy

## Phase 1 — Foundation

- Repository setup.
- Environment configuration.
- Database setup.
- Authentication.
- User roles.
- Outlet configuration.

## Phase 2 — Daily Operations

- Employee management.
- Service sales register.
- Product sales.
- Expenses.
- Zakat.
- Live dashboard.

## Phase 3 — Financial Closing

- Commission calculation.
- Commission distribution.
- Food deductions.
- Paytm reconciliation.
- Cash denomination counting.
- Rolling cash.
- Daily closing submission and approval.

## Phase 4 — Reliability and Reporting

- Offline functionality.
- Synchronisation.
- Audit history.
- PDF and Excel exports.
- Historical reports.

## Phase 5 — Testing and Launch

- Accounting verification.
- Permission testing.
- Offline testing.
- Parallel paper-based operation.
- Production deployment.

---

# 17. Explicitly Excluded From Initial Release

The following are future enhancements, not launch requirements:

- Royal Crown and Elite Crown operational configuration.
- Appointment booking.
- Customer CRM.
- Loyalty programmes.
- Full inventory management.
- Payroll processing.
- Automated employee attendance.
- Digital break management.
- Cash drop-safe integrations.
- Cash collection management.
- GPS tracking.
- Marketing automation.
- Native mobile applications.

---

# 18. Development Instructions

Claude Code should first inspect the existing repository and environment.

It must then produce an implementation plan before changing files.

The plan must include:

1. Proposed application architecture.
2. Database schema and relationships.
3. Authentication and authorisation.
4. Accounting calculations and edge cases.
5. Paytm integration feasibility and dependencies.
6. Offline synchronisation strategy.
7. Screen structure and user journeys.
8. Testing strategy.
9. Deployment strategy.
10. Implementation milestones.

Do not begin implementation until the plan has been reviewed and approved.

**Primary development objective:** deliver a reliable, simple accounting and daily operations application for HUDCO Big Boss, preserving its existing financial workflow while providing accurate records, visibility and accountability.
