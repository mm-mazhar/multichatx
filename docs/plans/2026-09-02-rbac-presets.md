# Workspace role presets — flag sets, plan gating, and the read-only gap

Status: **proposed** — spec only; no code written. Blocks nothing.
Owner: TBD · Created: 2026-09-02 · Drafted against `d61a2066`

## What this is

`docs/enterprise-swap-plan.md` § Phase 5 says to add named role presets over the
eight `WorkspaceMember.permissions` flags, and `docs/plan-matrix.md` gates them
by plan — but neither says which flags each preset sets, and the matrix names
only two of the four presets. This closes that gap.

**When accepted, this doc is applied as:**

1. Replace item **1. Role presets over raw flags** in
   `docs/enterprise-swap-plan.md` § Phase 5 with the section below.
2. Replace the `Full RBAC presets` row in `docs/plan-matrix.md` § 4 with the
   three rows below.
3. Add Open Question F to `docs/plan-matrix.md`.

No migration is involved. Presets derive from the existing
`WorkspaceMember.permissions` jsonb — no new column, and no change to the
`workspaceMemberRole` pg enum — so the gated migration process in `AGENTS.md`
does not apply.

---

## Proposed replacement for Phase 5, item 1

### 1. Role presets over raw flags

Eight independent booleans is expressive and a poor product. Presets are named
flag sets, expanded at write time and derived back for display. **They are not a
new column.** `WorkspaceMember.permissions` stays the single source of truth, so
every existing guard, test and the `superAdmin` bypass keep working untouched,
and raw flags remain the advanced escape hatch.

Leave the `workspaceMemberRole` enum (`owner` | `agent`) alone. It answers a
different question — who is the undeletable billing owner
(`delete-workspace-member.action.ts` refuses `role === "owner"`) — and
`accept-invitation.ts` will keep hardcoding `role: "agent"`.

**The flag sets**

| Flag | Owner | Manager | Agent | Analyst |
|---|:--:|:--:|:--:|:--:|
| `superAdmin` | ✓ | — | — | — |
| `analytics` | ✓ | ✓ | — | ✓ |
| `flows` | ✓ | ✓ | — | — |
| `contacts` | ✓ | ✓ | — | — |
| `onlyAssignedContacts` | ✓ | — | ✓ | — |
| `emailAndPhone` | ✓ | ✓ | — | — |
| `broadcast` | ✓ | ✓ | — | — |
| `ecommerce` | ✓ | ✓ | — | — |

**Why each line falls where it does**

- **Owner** is exactly `getSuperAdminPermissions()` from
  `features/workspace-members/helpers.ts` — reuse that function, do not restate
  the object. It sets `onlyAssignedContacts: true`, which contradicts the
  `normalizeContactsPermissions` invariant but is harmless because `superAdmin`
  bypasses every gate in `hasWorkspacePermission()`. Leave it; tests pin it.
- **Manager** is everything except `superAdmin`. The practical line that creates
  is channels and workspace settings: the dashboard "add channel" card
  (`allowAddNew`), the workspace status toggle, and the channel create/edit
  surfaces are all gated on `superAdmin` directly. That is the right boundary —
  channels are a billed resource, so connecting one should stay with the owner.
- **Agent** is the front-line inbox seat: assigned contacts only, no PII. Note
  `contacts` and `onlyAssignedContacts` are mutually exclusive by
  `normalizeContactsPermissions` — `contacts: true` forces
  `onlyAssignedContacts: false` — so every preset picks exactly one contacts
  mode. Contacts access is compound (`contacts || onlyAssignedContacts`), so
  Agent still reaches the contacts section, scoped.
- **Analyst** is analytics only. It deliberately does **not** get `contacts`,
  because the eight flags have no read/write distinction: `contacts: true` grants
  the full section including edit and delete. A genuinely read-only contacts role
  needs a ninth flag and a pass over every contact mutation path — out of scope
  for Phase 5, tracked as Open Question F.

**`emailAndPhone` is a privacy control, not a tier feature.** It is denied in
both non-owner working presets and stays overridable per member on every plan
that has a second seat. Do not gate the override on plan.

**Where the code goes**

- `packages/business/src/workspace/member-presets.ts` — the table above as a
  frozen record, `expandPreset(name)`, and `resolvePresetName(permissions)`
  which returns the preset whose set matches exactly, else `"custom"`.
- Plan gating goes in the member invite/update **service**, never in
  `apps/builder/src/features/workspace-members/actions/*` — same rule as the
  rest of `hasPlanFeature`.
- `use-permissions-coupling.ts` is unchanged. The preset selector sits above the
  existing checkboxes in `invite-workspace-member.tsx` and
  `update-workspace-member.tsx`; touching any checkbox drops the row to
  `custom`.

**Downgrade rule.** Members already holding a plan-gated preset keep their flags
when the owner downgrades. Only *creating or editing to* a gated preset is
blocked. Silently stripping permissions on a billing event is a security-relevant
state change users cannot see, and it would fire on failed-payment retries.

**Tests**, following the change checklist in
`docs/developer/workspace-permission-guards.md`:

1. Table-driven: each preset expands to exactly the documented flag set.
2. `normalizeContactsPermissions(expandPreset(p))` equals `expandPreset(p)` for
   every preset — the invariant holds by construction.
3. `expandPreset("owner")` deep-equals `getSuperAdminPermissions()`.
4. Assigning a gated preset with `hasPlanFeature` false is rejected in the
   service, and the corresponding action surfaces it.
5. Downgrade leaves an existing Manager's flags intact.
6. Fail closed: an unknown preset name grants nothing rather than defaulting.

---

## B — Replacement rows for `docs/plan-matrix.md` § 4

Delete:

```
| Full RBAC presets | ✗ | Owner/Agent ✎ | all presets ✎ | Phase 5 |
```

Insert:

```
| Role presets: Owner, Agent | n/a | ✓ ✎ | ✓ ✎ | Phase 5. n/a on Trial — 1 seat |
| Role presets: Manager, Analyst | ✗ | ✗ ✎ | ✓ ✎ | Phase 5. Key `rbac.presetsFull` |
| Custom permission flags | ✗ | ✗ ✎ | ✓ ✎ | Phase 5. Key `rbac.customFlags` |
```

Two feature keys on `UserQuota.features`, both read via
`hasPlanFeature(userId, key)`:

| Key | Trial | Growth | Scale |
|---|:--:|:--:|:--:|
| `rbac.presetsFull` | ✗ | ✗ | ✓ |
| `rbac.customFlags` | ✗ | ✗ | ✓ |

Owner and Agent are ungated — they are the minimum viable pair the moment
`teamMembersLimit` exceeds 1, and gating them would make Growth's three seats
useless. Manager and Analyst are the org-shape features that justify Scale, and
holding the raw-flag editor to Scale also keeps the support burden off the
cheaper tier.

`emailAndPhone` per-member override: **available on every plan with seats**, not
listed as a gated row. See the note in Phase 5.

---

## C — New open question for `docs/plan-matrix.md`

**Open Question F — do we need a read-only permission?**

The eight flags are access flags, not read/write flags. `contacts: true` means
view, edit, delete and export. That makes a true "Analyst" or auditor role
impossible today: the proposed Analyst preset is analytics-only, which is
narrower than most buyers expect from the name.

Closing it means a ninth flag (`readOnly`, or per-section write flags) plus a
pass over every contact and flow mutation path, the workspace-token APIs, and the
worker export job — the same surface the PII scoping already crosses.

Decide before the presets UI ships, because renaming or re-scoping a preset after
customers have assigned it means migrating live workspace members.

---

## Notes for whoever implements this

- Read `docs/developer/workspace-permission-guards.md` first. The change
  checklist there is the contract, and presets do not exempt you from it.
- Do not add preset checks to sidebar filtering. Sidebar is visibility, not
  authorization — the server guards remain the boundary.
- `hasWorkspacePermission()` fails closed on a missing jsonb key. Preset
  expansion must therefore write all eight keys explicitly, never a partial
  object.
