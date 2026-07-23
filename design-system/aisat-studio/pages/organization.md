# Page Override: Organization (Tenancy, Billing, Identity, Policy)

> Overrides `../MASTER.md` for the Organization screen. **Phase 2** — see
> [specs/draft-plan.md](../../../specs/draft-plan.md) "Phase 2 — Tenancy & Delegated
> Administration". No Phase-1 functional requirement maps to this screen.

## Purpose
The administrative and billing container above Workspace: which workspaces exist, one
contract and one credit pool for all of them, one identity connection, and policy
defaults set once. It is deliberately **not** a knowledge surface — no document, chunk,
edge or search result appears here.

## Reachability — deliberately not a nav item
Every workspace belongs to exactly one organization, but for a small customer the org is
auto-created at signup and never surfaced. It appears only when the org has more than one
workspace or an enterprise plan, and is reached from the **workspace switcher** in the
sidebar (which then shows the org name above the workspace name), not from a permanent
nav entry. A ten-person team should never see the word "organization"; adding a
sidebar item for them would be exactly the ceremony this design avoids.

## Layout
- App shell. The sidebar switcher is highlighted instead of a nav item, because this
  screen is org-scoped rather than workspace-scoped.
- Header: org name + `Organization` pill + tabs **Workspaces · Billing · Identity ·
  Policy** + the viewer's org role.
- A standing notice above all tabs (see below).

## The standing notice (required on every tab)
**Organization roles are administrative reach, never content reach.** An org admin can
create workspaces, manage members, connect the IdP and pay the bill — and cannot read a
single document in any workspace without separate membership there. This is the same
no-implicit-read rule that governs workspace admins and group owners, applied one level
up. It must be visible on this screen, because an org-admin surface is precisely where a
reader would otherwise assume the opposite.

## Workspaces tab
- **Workspace table**: name, *why separate* (client isolation / pre-close M&A / data
  residency), members, documents, credit allocation with a usage meter, and Manage.
- **Guidance callout — the most important content on this screen**: *a workspace is a
  knowledge domain, not an org-chart node.* Most organizations should run **one**
  workspace and separate access with clearance and groups. Telling customers to make a
  workspace per department manufactures a fragmentation problem that then demands
  cross-workspace search to undo. The "why separate" column exists to make an
  unjustified workspace look conspicuous.

## Billing tab
- **Organization pool**: purchased credits, amount allocated to workspaces, unallocated
  remainder.
- **Current plan**: plan, price, allotment, renewal, billing email, Change plan, provider
  portal link.
- **Allocation per workspace**: how the pool is divided, with the rule stated — a
  workspace that exhausts its allocation stops spending and **never silently draws down
  another workspace's budget**.
- **Receipts**: organization-level fiat history. This is the *only* place receipts appear;
  the Credits screen links here rather than duplicating them.

## Identity tab
- **SSO** and **SCIM** connection cards — one connection for the whole organization.
- **Mirrored-vs-directory count** ("14 of 412 mirrored") with the reason stated: only
  groups that actually gate content are mirrored, because a group appearing on no document
  cannot change a search result and would only inflate every query filter.
- **Group registry**, organization-scoped: principal, origin, members, and which
  workspaces use it. A group is a set of *people* (org fact); which documents it gates is
  a workspace fact.

## Policy tab
- **Clearance scheme editor**: level count (2–5) plus per-level label and description.
  State that labels are display-only and never reach the index.
- **Destructive-change warning**: renaming a level is safe; *removing* one requires an
  explicit remap of every document at that level before the change commits — otherwise
  those documents become unreachable or fall to a lower level and widen access silently.
- **Retention** and **defaults for new workspaces**.

## States to show
- Multi-workspace org (as mocked) and the single-workspace case where this screen is
  unreachable from the UI.
- Allocation exhausted in one workspace while the org pool still has credits.
- SCIM connected vs. not connected.

## Don'ts
- Don't show documents, chunks, search results, or any workspace content here.
- Don't imply an org role grants read access to workspace knowledge.
- Don't duplicate receipts or plan controls onto the Credits screen — one billing entity,
  one place to manage it.
- Don't surface the organization at all for a single-workspace customer.
- Don't offer cross-workspace search or a "search all workspaces" affordance. Workspace is
  the isolation boundary; that is the promise the rest of the product is built on.
