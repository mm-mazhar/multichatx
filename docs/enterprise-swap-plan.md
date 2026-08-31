# Enterprise-layer swap: analysis and plan

Replacing `apps/builder/src/enterprise/` (the only commercially-licensed path in
this repo) with first-party code, and building our own billing, tenant
management and RBAC layer.

**Baseline:** analysed against `ChatbotXIO/ChatbotX` at `a0b8ab7`, which is the
commit this fork was taken from. Every path, line count and import edge below
was read from source, not inferred.

**Audience:** whoever picks up implementation — human or coding agent. Read this
before touching billing, quota, tenancy or white-label code.

---

## 0. Decisions already made

| Decision | Choice | Why |
|---|---|---|
| Where billing lives | Fold into `apps/builder` | Upstream's billing is a private `apps/portal` micro-frontend we do not have. With white-label gone there is no reason for a second app, an iframe, or cross-origin `postMessage`. |
| `Tenant` table | Keep it, pin everything to `ROOT_TENANT_ID` | `User.tenantId`, `Workspace.tenantId`, email-unique-per-tenant and the better-auth tenant-scoped adapter are load-bearing. Pinning is free and reversible; removal is the riskiest change available. |
| Metering | Hard caps + one-time top-up packs | The MIT tree already ships Redis live counters, `UserQuota.*Used`, and a two-level quota gate. `UserQuota.botMessagesTopUpGranted` exists for exactly this. No Stripe metered billing. |
| Upstream | Keep tracking | New code goes in directories upstream does not have. Queue names, job shapes, Redis keys and `planStatus` values stay byte-identical. |

Plans: a **7-day trial with no card required**, plus two paid tiers, all with
feature and usage limits.

---

## 1. The finding

**The MIT tree ships every *consumer* of billing and no *producer*.**

Everything downstream of an entitlement already works and is MIT: the
`UserQuota` table with per-metric limits and counters, Redis live counters with
write-through to the DB, a two-level pool/user quota gate, a four-state access
machine, trial-expiry schedules, sidebar usage rings, limit-reached banners, and
the full `billing.*` i18n set in English.

What is missing is the thing that decides what a user is entitled to. Three
seams carry that out of the repo:

| Seam | Where it is | What is on the other side |
|---|---|---|
| The `quota` queue | `packages/worker-config/src/queues/quota/index.ts` | A private `quota-worker` consumes `publishEntitlements` and writes the authoritative `UserQuota` row. **`apps/worker/src/` has no `quota/` directory — nothing consumes this queue.** |
| The `/portal/*` proxy | `apps/builder/next.config.ts` | A private Next app on `PORTAL_INTERNAL_URL` (default `:3201`) serving pricing, checkout, Stripe webhooks and Stripe Connect. The upgrade dialog is an `<iframe src="/portal/pricing">`. |
| The Redis snapshot | `packages/business/src/user-quota/service.ts` | The portal publishes plan limits to `entitlements:default-plan`. Sign-up reads it to stamp a new user's trial. **Nothing in the MIT tree ever writes it.** |

A fourth is already dead: `billingService.provisionDefaultPlan()` POSTs to
`/portal/api/users/provision`, but nothing calls it except its own test.

### Where the licence line falls

The root `LICENSE` carves out exactly one path as commercial:
`apps/builder/src/enterprise/`. Everything else is MIT — including paths whose
names suggest otherwise:

- `packages/business/src/enterprise/` (licence, tenant, custom-domain,
  inbox-team services) — **MIT, keep and edit freely**
- `packages/database/src/schema/enterprise/` (`Tenant`, `UserQuota`,
  `CustomDomain`) — **MIT, keep**

The commercial directory is UI and thin server actions. Almost every service
behind it is MIT and stays.

> **Licence hygiene, not legal advice.** MIT requires retaining the existing
> copyright and permission notice when redistributing — add our line, do not
> replace theirs. Remove the commercial carve-out clause and delete
> `apps/builder/src/enterprise/LICENSE` only once that directory holds none of
> their code.

---

## 2. Inventory: the 35 commercial files

`apps/builder/src/enterprise/` — 35 source files, 2,750 lines, plus its LICENSE.

| Feature | Files | Lines | Disposition |
|---|---:|---:|---|
| `inbox-teams` | 17 | 1,088 | **Rewrite.** The service behind it (`packages/business/src/enterprise/inbox-team/service.ts`, 219 lines) is MIT and stays. Only UI + action wrappers are commercial. |
| `audit-logs` | 6 | 553 | **Rewrite.** Table, columns, toolbar, queries over the MIT `packages/business/src/audit/`. |
| `platform-email-templates` | 5 | 454 | **Delete** — white-label. |
| `platform-branding` | 3 | 385 | **Delete** — white-label. |
| `billing` | 2 | 152 | **Rewrite** — replaced wholesale by the new billing feature. |
| `manage` sidebar | 1 | 104 | **Delete** — goes with `/manage`. |
| `inbox-team-members` | 1 | 14 | **Rewrite** — one schema file. |

### Import edges to repoint

24 import statements across 19 files reach into `@/enterprise`:

| What is imported | Edges | Importers |
|---|---:|---|
| `billing/upgrade-plan-dialog` | 5 | `components/nav-usage.tsx`, `components/nav-user.tsx`, `features/workspaces/components/account-rail.tsx`, `features/workspaces/components/workspaces-list.tsx`, `features/workspace-members/components/invite-workspace-member.tsx` |
| `inbox-teams/*` | 7 | `routers/index.ts` *(dynamic import)*, `routers/public.ts`, `features/users/provider/user-store.ts`, `features/contacts/schemas/query.ts`, `features/conversations/schema/resource.ts`, `app/space/[workspaceId]/(settings)/settings/inbox-teams/page.tsx` ×2 |
| `audit-logs/*` | 3 | `app/space/[workspaceId]/(enterprise)/audit-logs/page.tsx` |
| `platform-branding` + `platform-email-templates` | 8 | `app/admin/(enterprise)/(non-cloud)/…` ×4, `app/manage/(enterprise)/…` ×4 — all deleted with the routes |
| `manage/portal-manage-sidebar` | 1 | `app/manage/layout.tsx` — deleted with the zone |

> **Merge tactic.** Nine of those edges survive the swap. Rather than repointing
> them at `@/features/billing`, keep `apps/builder/src/enterprise/` as a
> directory of **our own** thin re-export shims — our code, our MIT header,
> upstream's import paths. Nine upstream files then never change, and future
> merges on them are conflict-free. Rename the directory later, deliberately,
> not in the middle of this.

---

## 3. Traps

Six findings that change the plan rather than decorate it.

### 3.1 A missing Redis key locks out every new signup

`ensureBootstrapPlan()` reads `entitlements:default-plan` from Redis. When
absent it falls back to `BOOTSTRAP_TRIAL_FALLBACK`: a **one-day** trial with
**every limit set to zero**. That is a deliberate fail-closed stance upstream.
On day one of this fork it means every new user can sign in and create nothing.

**Publishing that snapshot is the first thing the new worker must do at boot.**

### 3.2 The licence gate blocks cloud too — the docs are wrong

`docs/licensing.md` says cloud is "always entitled; licence ignored". The code
disagrees:

```ts
// packages/business/src/user/entitlements.ts
export const hasEnterpriseFeatures = async () => {
  if (!(isCloud() || isEnterprise())) return false
  const license = await getLicenseStatus()
  return license.state === "valid"   // ← cloud needs a valid licence too
}
```

A valid licence is an Ed25519 JWS signed by a private key we will never hold,
and the tier must match the edition. Set `NEXT_PUBLIC_EDITION=cloud` without
replacing this and audit logs, admin branding and platform help items all 404.

### 3.3 `resolveTenantSettings` is not a branding function

It looks like white-label plumbing and is tempting to delete. It is also how
eight unrelated call sites resolve `appUrl`, `wsUrl` and `storageUrl` — dynamic
images, system fields, appointments, realtime broadcast, integration context.

**Keep the function; collapse its body to env defaults.** Delete the tenant
branding merge, not the resolver.

### 3.4 The `/portal` rewrites are dev-only

Every billing rewrite in `next.config.ts` sits inside
`if (process.env.NODE_ENV !== "development") return alwaysRewrites` — an early
return. In production those paths are routed by Caddy, which is not in this
repo. Deleting the rewrites fixes dev; the production reverse-proxy config needs
the same edit, or `/api/billing/webhook` gets proxied into the void.

### 3.5 Billing is per owner-user, not per workspace

`UserQuota` is keyed by `userId`; workspaces count against the owner's pool.
Every plan, limit, subscription and Stripe customer hangs off the owner `User`.
Model a subscription per workspace and you fight the entire quota layer.

### 3.6 Migrations are gated deliberately

`AGENTS.md`: migrations must never be applied automatically. Generate with
`pnpm --filter @chatbotx.io/database make:migration <name>`, read the SQL, apply
only after review. Also: a new table needs **both** an import and a spread in
`packages/database/src/relations/index.ts`, or its relations silently do not
exist.

---

## 4. Target architecture

One new worker, one new feature slice, three new tables.

### The entitlement pipeline

Preserve the existing seam rather than routing around it. Sign-up already
enqueues `publishEntitlements`; Stripe webhooks will enqueue the same job. One
consumer, one write path into `UserQuota`, every downstream gate untouched.

```
sign-up ─┐
         ├─→ quota queue ─→ [ quota worker ] ─→ UserQuota ─→ gates & UI
stripe ──┘   (exists,MIT)     WE BUILD THIS      (exists)     (exists)
 webhook
```

The bracketed box is the entire gap. Fill it and roughly seventy per cent of
"billing" is done, because everything to its right already exists and is already
wired into every create path in the product.

### Plan catalogue — in code, not a table

Three plans do not justify an admin CRUD surface. A TypeScript constant gives
type-safe limit keys, reviewable diffs, and no migration per price change.
Stripe price IDs come from env so test and live differ per deployment.

| Plan | Stripe | `planStatus` | Behaviour |
|---|---|---|---|
| **Trial** — 7 days, no card | None; no customer object created | `trial` | `periodEnd = now + 7d`. Fully self-managed — exactly what upstream's status machine was designed for ("self-managed new-user trial, no Stripe trial"). |
| **Paid tier 1** | Recurring price | `active` / `past_due` | Limits from the catalogue. `past_due` still grants access; the existing banner nudges for payment. |
| **Paid tier 2** | Recurring price | `active` / `past_due` | Higher caps, more feature flags. |
| **Top-up pack** | One-time price | unchanged | Grants bot-message credit via `UserQuota.botMessagesTopUpGranted`, which survives every limit recompute. |

`planStatus` has exactly four legal values and both the access gate and the
banner key off them. **Never write a raw string** — import `planStatuses` from
`@chatbotx.io/database/partials`.

### New tables

| Table | Shape | Why |
|---|---|---|
| `Subscription` | `userId` (unique), `stripeCustomerId`, `stripeSubscriptionId`, `planKey`, `status`, `currentPeriodStart/End`, `cancelAtPeriodEnd` | The Stripe mirror. One per owner. `UserQuota` is derived from it, never hand-edited. |
| `StripeEvent` | `eventId` (unique), `type`, `processedAt` | Webhook idempotency. Stripe retries; without this you double-grant top-ups. |
| `TopUpGrant` | `userId`, `packKey`, `botMessages`, `stripeCheckoutSessionId` (unique), `grantedAt` | The ledger `botMessagesTopUpGranted` mirrors. Summed on every recompute. |

Add `UserQuota.features jsonb` rather than a boolean per feature. Leave the
three existing booleans (`whiteLabel`, `ssoSaml`, `saasMode`) in place and
`false` so upstream code reading them keeps compiling.

---

## 5. Execution

### Phase 0 — Unblock the fork

No new features. Make a cloud-edition deployment stop lying to itself.

1. **Replace the licence gate.** Reduce `hasEnterpriseFeatures()` to an edition
   check. Feature gating belongs on the plan entitlement, not an offline licence
   token. Keep `packages/business/src/enterprise/license/` on disk but dormant —
   generate our own Ed25519 keypair into `public-keys.ts` if we ever sell a
   self-hosted enterprise SKU. Fix `docs/licensing.md`, which is already wrong.
   - `packages/business/src/user/entitlements.ts`, `docs/licensing.md`
2. **Cut the dead portal seams.** Remove the five `/portal`-family rewrites from
   `next.config.ts`; delete `packages/business/src/enterprise/billing/` and its
   test. Mirror the rewrite removal in the production Caddy config.
   - `apps/builder/next.config.ts`, `packages/business/src/enterprise/billing/`,
     `packages/business/__tests__/billing.service.test.ts`
3. **Licence and attribution.** Drop the carve-out from root `LICENSE`, retain
   upstream's MIT copyright line, add ours. Update `AGENTS.md` and `README.md`.
   Delete `apps/builder/src/enterprise/LICENSE` at the end of Phase 3, not now.

### Phase 1 — The entitlement worker

The highest-leverage work in the project. Do it before touching Stripe.

1. **Plan catalogue** — plan key, display name, trial days, every `*Limit`,
   feature flags, and the env var holding each Stripe price ID.
   - `packages/business/src/billing/plans.ts`, `.../billing/keys.ts`
2. **`publishEntitlements`** — read the user's `Subscription` (absent → trial or
   expired-trial), resolve the plan, sum their `TopUpGrant` rows into
   `botMessagesLimit`, upsert the `UserQuota` row (limits, `planName`,
   `planStatus`, `periodStart/End`, `syncedAt`), invalidate the quota cache.
   **Recompute from scratch every run; never increment.** Idempotency is what
   makes webhook retries and backfills safe.
   - `packages/business/src/billing/entitlements.service.ts`
3. **The worker process** — follow the house pattern exactly:
   `apps/worker/src/quota/worker.ts`, a `worker:quota` script in
   `package.json`, an entry in `tsdown.config.ts`. The Docker entrypoint
   discovers bundles from the dist directory, so no entrypoint edit is needed.
   Handle all three job types; `backfillTenantDefaultPlan` becomes a no-op —
   log and acknowledge rather than throwing, so a stray job never poisons the
   queue.
4. **Publish the default-plan snapshot at boot** (Trap 3.1) — write the trial
   plan's limits to `entitlements:default-plan` as the worker starts, and again
   whenever the catalogue changes. Add a test asserting the key is populated.

### Phase 2 — Stripe

The `stripe` SDK is already a builder dependency at `^22.1.0`. It is used today
for *merchant* payment credentials in flows — unrelated to SaaS billing. Keep
the two apart.

1. **Schema** — the three tables plus `UserQuota.features jsonb`. Wire each new
   table into `relations/index.ts`. Generate, read the SQL, get sign-off, apply.
2. **Checkout and the Stripe billing portal** — a server action creating a
   Checkout Session with `client_reference_id` and metadata carrying the owner
   `userId`; a second creating a Billing Portal session. **Let Stripe's portal
   own payment methods, invoices, plan changes and cancellation.** Building
   those screens is weeks of work and a PCI conversation we do not need.
3. **The webhook** — a route handler at `/api/billing/webhook`. Read the **raw**
   body with `await req.text()` before any parsing or signature verification
   fails. Insert the event id into `StripeEvent` first; return 200 immediately
   on conflict. Handle `checkout.session.completed`,
   `customer.subscription.created/updated/deleted`, `invoice.paid`,
   `invoice.payment_failed`. Every handler does two things: upsert
   `Subscription`, then enqueue `publishEntitlements`. **Never write `UserQuota`
   from the webhook** — one write path only.

   Status mapping: `active`/`trialing` → `active`; `past_due`/`unpaid` →
   `past_due`; `canceled` → `expired`. Ignore `incomplete*` so an abandoned
   checkout never burns a trial.
4. **Pricing and billing pages** — real routes, not an iframe.
   `packages/ui/src/components/billingsdk/pricing-table-four.tsx` is already in
   the tree with a `Plan` type; use it and replace the sample data.

### Phase 3 — Replace the commercial UI

1. **Upgrade dialog → upgrade link.** The iframe exists only because pricing
   lived in another app. Replace `UpgradePlanButton` / `UpgradePlanDialog` with
   a component linking to `/pricing`, **keeping the same exported names and
   props** so the five call sites are untouched. The `billing:upgrade-success`
   `postMessage` listener and `reconcileTenantEntitlementAction` both disappear.
2. **Inbox teams.** 17 files of UI and action wrappers over an MIT service that
   already does the work. Mirror any existing `features/` slice with dialogs and
   a table. Watch the two schema files — `inboxTeamResource` is imported by the
   contacts and conversations schemas, so its shape is load-bearing beyond this
   feature.
3. **Audit logs.** Table, columns, filter toolbar, two queries over the MIT
   `auditLogModel`. `apps/builder/__tests__/audit-logs-query.test.ts` pins the
   query contract — write the replacement to keep it green rather than rewriting
   the test.
4. **Empty the directory.** With shims in place and white-label gone, delete
   every remaining upstream file under `apps/builder/src/enterprise/` including
   its `LICENSE`. Leave our shims and a short README stating the directory holds
   first-party code retained for import-path stability.

### Phase 4 — Remove white-label

Largest surface, almost entirely deletion. The risk is what gets deleted by
accident.

**Delete outright**

| Path | What it was |
|---|---|
| `apps/builder/src/app/manage/**` | The entire reseller zone |
| `apps/builder/src/app/admin/(enterprise)/(non-cloud)/**` | Platform branding + email-template editors |
| `apps/builder/src/features/manage/**` | Manage-zone layout shell |
| `packages/ui/src/components/portal/**` | Portal side-nav, pricing nav item |
| `packages/ui/src/config/portal-nav.ts` | `PortalSaasFlag` nav config |
| `packages/ui/src/lib/portal-pricing-url.ts` | Reseller-domain pricing URL builder |
| `packages/business/src/enterprise/custom-domain/**` | Read-only custom-domain service |
| `apps/worker/src/schedule/handlers/reconcile-tenants.ts` | Reseller tenant reconcile |

**Reduce, do not delete**

| Path | Action |
|---|---|
| `packages/business/src/platform/settings.ts` | **Trap 3.3.** Keep `resolveTenantSettings`; strip the branding merge and custom-domain re-anchoring so it returns env defaults. |
| `packages/business/src/enterprise/tenant/service.ts` | Keep `findById`, `findByOwner`, `resolveVisibleChannels`. Delete `provisionForOwner`, `reconcileOwnerEntitlement`, `suspend`, `reactivate`, `downgrade`, `listActiveOwnerIds`. |
| `packages/business/src/workspace/service.ts` | `resolveTenantForOwner` returns `ROOT_TENANT_ID` unconditionally. Keep the diff to one line. |
| `packages/database/src/schema/enterprise/tenant.ts` | Leave the table alone. Branding columns simply go unwritten. Dropping them buys nothing and costs a rollback path. |
| `apps/builder/src/app/admin/platform-channels/` | **Keep.** The platform tier of channel visibility is how we decide which channels the product offers. Only the reseller tier under `/manage` goes. |

**Leave completely alone**

The tenant-scoped auth adapter (`packages/auth/src/tenant-context.ts`,
`server.ts`), the per-tenant social OAuth instance cache, the OAuth broker and
the callback relay. With every user on the root tenant these become identity
functions and cost nothing. They are also the most intricate code in the repo
and the most actively maintained upstream. The `CustomDomain` table stays too —
with no rows, `listActiveDomains()` returns `[]` and `trustedOrigins` resolves
correctly.

### Phase 5 — Tenancy and RBAC

**What already exists (MIT):** an eight-flag permission model on
`WorkspaceMember.permissions` with a `superAdmin` bypass; server-side route
guards that fail closed; contact PII scoping that survives the builder→worker
boundary into CSV export; seat enforcement via `teamMembersLimit`; workspace
provisioning that already consumes quota in `workspaceService.create`.

**Read `docs/developer/workspace-permission-guards.md` before changing any of
it.** The change checklist there is the contract.

**To build:**

1. **Role presets over raw flags.** Eight independent booleans is expressive and
   a poor product. Add named presets — Owner, Manager, Agent, Analyst — that
   expand to flag sets, keeping raw flags as an advanced escape hatch. Presets
   are also the natural thing to gate on plan.
2. **Feature gating from the plan.** `hasPlanFeature(userId, key)` reading the
   new `UserQuota.features` column, used at read and creation points **in
   services, never in `apps/`**. This replaces `assertEnterpriseFeatures` as the
   real gate.
3. **Onboarding.** `tenantService.provisionForOwner` was never wired to any
   onboarding flow upstream — the docs admit it. With reselling gone, workspace
   provisioning is the whole story: create the first workspace on sign-up,
   inside the trial's `workspacesLimit`.

### Phase 6 — Trial lifecycle

Already built upstream and MIT. Confirm it works against our plans rather than
rebuilding it.

- **Degraded access, not a hard wall.** An expired trial is read/delete-only
  with a persistent banner. Create actions use the trial-gated
  `workspaceActionClient`; delete, disconnect and cancel use
  `workspaceActionClientAllowExpired` so cleanup and export stay possible.
- **The schedules.** `unsubscribeExpiredTrials` tears down channels seven days
  after expiry, guarded by the one-shot `UserQuota.channelsTornDownAt`.
  `purgeWorkspaces` hard-deletes after a 24-hour grace window, **disconnecting
  integrations before deletion** so provider webhooks are deregistered while
  credentials still exist. `syncUserQuota` reconciles counters.
- **Only change:** `syncUserQuota`'s reseller-pool branch becomes dead code once
  `listActiveOwnerIds` always returns empty. Simplify to the self-count path.

---

## 6. Merge surface

Every upstream file we edit is a future conflict. The honest bill:

| File | Change | Conflict risk |
|---|---|---|
| `packages/business/src/user/entitlements.ts` | Rewrite the gate | Low |
| `apps/builder/next.config.ts` | Remove rewrites | **High** — actively edited upstream |
| `packages/business/src/platform/settings.ts` | Collapse to env defaults | **High** — large, actively edited |
| `packages/business/src/enterprise/tenant/service.ts` | Trim reseller methods | Medium |
| `packages/business/src/workspace/service.ts` | One method returns a constant | Low |
| `apps/worker/src/schedule/worker.ts` | Drop one case branch | Medium |
| `apps/worker/{package.json, tsdown.config.ts}` | Add the quota worker | Low — additive |
| `LICENSE`, `AGENTS.md`, `README.md` | Licence and attribution | Low |
| `apps/builder/src/enterprise/**` | Replaced with our shims | Resolved by always taking ours |

Two rules keep the rest cheap:

1. Put every new module in a directory upstream does not have —
   `features/billing/`, `business/src/billing/`, `worker/src/quota/` — so new
   code never conflicts at all.
2. Keep queue names, job shapes, Redis keys and `planStatus` values
   byte-identical to upstream's, so when they evolve the contract we get a clean
   diff rather than a silent divergence.

Track upstream on a dedicated remote and merge on a schedule, not on demand. A
monthly merge is a bad afternoon; a six-month merge is a rewrite.

---

## 7. Verification

### Existing tests that must stay green

```
apps/builder/__tests__/audit-logs-query.test.ts
apps/builder/__tests__/enterprise-feature-gates.test.ts        (rewrite for the new gate)
apps/worker/__tests__/{register-schedules-edition,send-audit-log,unsubscribe-expired-trials}.test.ts
packages/business/__tests__/{entitlements,quota-enforcement.service,user-quota-default-plan,workspace.service}.test.ts
packages/business/__tests__/{custom-domain-service,tenant-*,license.*}.test.ts   (delete with their features)
```

### New tests, written before the feature

- **Webhook idempotency** — the same Stripe event id delivered twice grants one
  top-up.
- **Status mapping** — every Stripe subscription status lands on a legal
  `planStatus`, and `incomplete*` lands nowhere.
- **Snapshot presence** — `entitlements:default-plan` is populated after worker
  boot. This is Trap 3.1's regression test.
- **Entitlement recompute** — running `publishEntitlements` twice produces an
  identical row.
- **Downgrade** — a user over the new plan's limits keeps their data, is blocked
  from creating, and is not silently deleted.

### Manual passes

1. Fresh sign-up → a 7-day trial row with catalogue limits, **not zeros**; a
   workspace can actually be created.
2. Upgrade in Stripe test mode → webhook received, `Subscription` upserted,
   `UserQuota` republished, usage ring reflects new caps.
3. Force a trial to expire → banner appears, creates blocked, delete and
   disconnect still work.
4. Fail a payment in test mode → `past_due`, access retained, payment banner.
5. Buy a top-up → `botMessagesLimit` rises and survives the next
   `publishEntitlements` run.
6. Grep for `/portal`, `whiteLabel`, `saasMode`, `customDomain` → only dormant,
   deliberate references remain.

### Sequencing

**Ship Phases 0 and 1 to staging and let real sign-ups flow through the new
worker before writing a line of Stripe code.** If the entitlement pipeline is
wrong, every Stripe bug chased afterwards will be misdiagnosed.

---

## 8. Environment notes

Development setup, including the WSL requirement and the `.env.example`
`REALTIME_BROADCAST_SECRET` bug, is in [`local-setup.md`](./local-setup.md).

Relevant to this work specifically:

- `NEXT_PUBLIC_EDITION` stays `community` until Phase 0 lands. Flipping to
  `cloud` before then triggers Traps 3.1 and 3.2 simultaneously.
- New env vars this plan introduces: `STRIPE_SECRET_KEY`,
  `STRIPE_WEBHOOK_SECRET`, and one price-ID var per plan and top-up pack. Add
  them to `.env.example` with commented placeholders, and to the relevant
  `keys.ts` schema — this repo validates env at boot and a missing required var
  fails the whole app, not just the feature.
