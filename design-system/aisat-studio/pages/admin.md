# Page Override: Admin Usage Dashboard

> Overrides `../MASTER.md` for the Admin screen. Covers User Story 6 (FR-022) plus
> workspace/member management (FR-013, FR-015), the audit trail (FR-023), and admin
> broadcasts (FR-037).

## Purpose
Workspace operators view per-user and per-feature AI usage and cost, manage member
limits, roles, clearance, and invitations, send broadcast announcements, and review the
audit trail.

## Layout
- App shell; active nav = **Admin**. Tabbed sections: **Usage**, **Members**, **Broadcast**, **Audit**.
- Usage tab: KPI cards + per-user table + per-feature breakdown chart.
- Members tab: member table + invite flow.
- Broadcast tab: announcement composer + recent broadcasts.
- Audit tab: filterable event log.

## Usage tab
- **KPI cards**: total credits used, active members, avg cost / query, fallback-provider hits.
- **Per-user table**: member, role, clearance (L1–L5 badge), credits used, daily limit (editable inline), queries, last active. Editing a limit enforces it on subsequent ops (FR-022 scenario 2).
- **Per-feature chart**: stacked bar (ingest / caption / query / rerank) over the period.

## Members tab
- **Member rows**: avatar, name/email, role (Owner/Admin/Member), clearance badge, status.
- **Invite by email** (FR-015): modal with email + role + clearance (clearance ≤ inviter's). Pending invites show a `pending` pill with **Revoke**.
- Sensitive actions (remove member, change role) prompt re-auth (security best practice / AZ6).

## Broadcast tab (FR-037)
- **Composer**: title + body fields for an announcement sent to **all current members** of
  this workspace as a `broadcast`-category notification.
- Note that delivery still respects each member's per-channel preferences (a member who
  disabled the broadcast email channel gets it in-app only, etc.).
- **Send** prompts a confirm ("This notifies every current member"); on send, the broadcast
  is recorded in the audit trail.
- **Recent broadcasts** list: title, sender, timestamp, recipient count — read-only.
- Scope is this workspace only; a broadcast never reaches other workspaces.

## Audit tab (FR-023)
- Table: timestamp, actor, action/tool, role, cost, result fingerprint, trace ref.
- Filters: actor, action type, date range. Monospace for fingerprints/trace refs.
- Note: raw prompt/response bodies retained 30 days, then only metadata/hashes/aggregates (FR-024).

## Don'ts
- Don't allow assigning a clearance/role above the acting admin's own authority.
- Don't surface raw PII in the audit view (scrubbed metadata only).
- Don't let a broadcast cross workspace boundaries or bypass members' per-channel preferences.
