# Page Override: Workspace (Members, Roles, Clearance, Isolation)

> Overrides `../MASTER.md` for the Workspace screen. Covers User Story 3
> (FR-013, FR-014, FR-015) — access-controlled team workspace.

## Purpose
The member-facing view of the shared workspace: who's in it, each member's role and
clearance (L1–L5), how knowledge is split between personal and shared, and the
invite/accept/revoke flow. Reinforces that retrieval/browsing is strictly scoped and
that workspaces are completely isolated from one another.

## Layout
- App shell; active nav = **Workspace**.
- Header strip: workspace identity + an **isolation notice** ("Knowledge here is never
  visible to other workspaces").
- Three zones:
  1. **My clearance card** — the viewer's own role + clearance ladder (L1–L5) with the
     levels they can see highlighted.
  2. **Members panel** — list of members with avatar, role, clearance badge, status.
  3. **Knowledge split** — personal vs shared document counts, and a per-clearance
     breakdown of what the viewer can access.

## Key components
- **Clearance ladder**: a vertical/stepped indicator rendered **from the workspace's
  `clearance_scheme` config**, never from hardcoded rungs. Levels at or below the viewer
  are run-green/active; levels above are locked + muted ("not visible to you"). The
  default scheme is 5 levels (Public / Restricted / Internal / Confidential / Executive),
  but a workspace may define 2–5 with its own labels — a 3-tier customer renders three
  rungs, with no wasted or invented levels. Only the integer is stored and indexed, so
  renaming a level is a display change with no re-embedding.
- **Member row**: name/email, role pill (Owner/Admin/Member), clearance badge, last active.
  Non-admins see this read-only.
- **Invite by email** (FR-015): button → modal with email + role + clearance selector.
  Clearance options are capped at the inviter's own clearance. Pending invites show a
  `pending` pill with **Revoke** (admins only).
- **Isolation banner**: explicit statement that no content crosses workspaces (FR-014).
- **Personal vs shared toggle**: shows counts; shared respects the viewer's clearance.

## States to show
- Viewer as a mid-clearance Member (some levels locked).
- A pending invite awaiting acceptance.

## Don'ts
- Don't let a user assign a role/clearance above their own authority.
- Don't hardcode level names anywhere in this screen. "Internal" and "Executive" are the
  *default* scheme's labels, not the product's vocabulary — a customer running
  Public/Internal/Confidential must never see a name they did not configure.
- Don't render group membership as extra rungs on the ladder. The two axes are
  orthogonal — a stepped indicator implies an ordering that groups do not have, and
  the whole point of the second axis is that rank does not grant it.
- Don't show counts or documents above the viewer's clearance.
- Don't imply any cross-workspace visibility.

---

## Phase 2+ affordances on this screen

The access model is **decided** (see [specs/draft-plan.md](../../../specs/draft-plan.md)
"Access model (decided)"): the L1–L5 ladder is kept and joined by an orthogonal
**group-principal ACL** axis; a document is visible only when *both* pass. This screen
owns the UI for it:

| Affordance | Phase | Shape |
|---|---|---|
| **My groups** block | 2 | A flat set of chips beneath the clearance ladder — never rungs. Mirrored groups (`ext:`) carry their source badge (Confluence/Jira/Git) and are read-only |
| Member row group column | 2 | Which groups a member holds; admins can grant/revoke **native** groups only |
| Break-glass banner | 2 | When the viewer holds a time-boxed emergency grant: what was granted, why, and when it expires |
| Config-driven ladder | 2 | `clearance_scheme` workspace config; mockup carries a preview toggle between the 5-level default and a 3-level customer scheme |

Scope note for the mockup when it is built: the ladder graphic and the invite modal are
**unchanged** by this decision — the group axis is additive, so this screen extends
rather than restructures. Two other screens are affected: the Library sharing selector
gains an optional group multi-select (capped to groups the uploader holds, mirroring the
existing tag-up-to-your-level rule), and Chat's scope footer reads "L1–L3 + security".
