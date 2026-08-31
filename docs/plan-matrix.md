# Plan matrix — strawman

Proposed numbers for the three plans, with the reasoning behind each. **This is
a draft to edit, not a decision.** Once the numbers settle, this file becomes
`packages/business/src/billing/plans.ts` and the Redis
`entitlements:default-plan` snapshot.

Read alongside [`enterprise-swap-plan.md`](./enterprise-swap-plan.md).

---

## 1. What we are actually pricing

The `UserQuota` table gives us exactly seven numeric levers. Every one is
already enforced by MIT code, so anything we put here takes effect the moment
the quota worker writes the row.

| Metric | What it counts | Enforced where |
|---|---|---|
| `workspaces` | Workspaces owned | `workspaceService.create` |
| `channels` | Connected inboxes | `inboxService.create` |
| `contacts` | Stored contacts | contact create paths |
| `mac` | **Monthly active contacts** | hard gate on new-contact creation, **and** the app-access gate |
| `teamMembers` | Seats | invite + accept-invitation |
| `monthlyBotMessages` | Bot sends per billing period | outbound bot send |
| `botMessages` | Bot sends, lifetime pool | outbound bot send |

Limits are per **owner user**, not per workspace (Trap 3.5). `null` means
unlimited.

### Two things about MAC you need to know before setting its number

**MAC counts per contact-inbox, not per human.** The ledger's primary key is
`(workspaceId, periodStart, contactInboxId)`. One person who messages you on
both WhatsApp and Instagram in the same month counts as **2**. This is
deliberate and documented in `docs/mac-counting.md`, but it means our MAC number
is not directly comparable to a competitor's "active contacts" — ours inflates
for exactly the omnichannel usage we are selling. The proposed numbers below
already pad for this.

**Hitting the MAC cap blocks the whole app, not just new contacts.**
`getAccessState` returns `blocked` with `reason: "mac"`, which stops sending and
receiving. A customer who exhausts MAC on the 12th of the month is dead in the
water until they upgrade. ManyChat instead charges overage and keeps running.
**This is the single most important product decision in this document** — see
Open Question A.

---

## 2. Market anchors

Observed August 2026; these move, so re-check before launch. ManyChat's
published figures are annual-billed rates.

| Product | Entry | Mid | High | Billing unit |
|---|---|---|---|---|
| **ManyChat** | Essential $17 / 250 contacts | Pro $39 / 2,500 | Business $99 / 7,500 · Advanced $199 / 25,000 | Active contacts, with overage ($0.10 → $0.05 → $0.025) |
| **Wati** | Growth ~$29 (5 users) | Pro ~$79 | Business ~$219 | Subscription + per-agent, plus Meta pass-through |

ManyChat is the closest comparable — same category, same billing unit, and it
gates WhatsApp to Pro and above. Wati is WhatsApp-only, which is the thing we
are differentiated against: omnichannel from the entry tier is our story.

The market shape is clear: **~$20–40 entry, ~$80–100 mid, ~$200 high.** With
only two paid tiers we should sit at the $39 and $99 marks and skip the $199
tier until there is demand for it.

---

## 3. Proposed limits

| Metric | Trial (7d, no card) | Growth · $39/mo | Scale · $99/mo |
|---|---:|---:|---:|
| `workspacesLimit` | 1 | 2 | 5 |
| `channelsLimit` | 2 | 5 | 15 |
| `contactsLimit` | 500 | 10,000 | 50,000 |
| `macLimit` | 100 | 3,000 | 10,000 |
| `teamMembersLimit` | 1 | 3 | 10 |
| `monthlyBotMessagesLimit` | `null` | 20,000 | 100,000 |
| `botMessagesLimit` | 500 | `null` | `null` |
| `trialDays` | 7 | 0 | 0 |

### Why these numbers

**Trial — 100 MAC, 2 channels, 7 days.** The trial has one job: get someone to
the moment a real conversation gets automated. That needs a connected channel, a
flow, and enough live contacts to feel real. 100 MAC is a genuine test and not a
free tier. Two channels matter more than they look — being able to connect
WhatsApp *and* Instagram in the trial is how we demonstrate the omnichannel
difference before they ever pay. One workspace, one seat: no collaboration until
there is a card.

`botMessagesLimit: 500` as a lifetime pool, with `monthlyBotMessagesLimit: null`
— over seven days a monthly reset is meaningless, so a single pool is the
simpler gate.

**Growth — $39, 3,000 MAC.** Sits exactly on ManyChat Pro's price, with more
headroom on paper (3,000 vs 2,500). That headroom is doing real work: it offsets
the per-contact-inbox inflation described above, so an omnichannel customer gets
comparable *actual* value rather than appearing cheaper and delivering less.
Five channels covers a realistic small-business setup. Three seats is an owner
plus two agents.

**Scale — $99, 10,000 MAC.** Anchored on ManyChat Business ($99 / 7,500),
deliberately above it. Ten seats and fifteen channels put this in agency and
multi-brand territory, which is what the five workspaces are for.

**Bot messages.** 20,000/month at Growth is roughly 6–7 automated messages per
active contact — comfortable for flows, tight for heavy broadcast use, which is
what makes top-up packs a real product rather than a gimmick.

**Contacts vs MAC.** `contactsLimit` is storage, `macLimit` is activity. They
should never both bite at once — that is double jeopardy and it reads as
punitive. The proposed ratio is roughly 3–5× MAC, generous enough that contacts
is effectively an anti-abuse ceiling rather than a pricing lever.

---

## 4. Proposed feature gates

Marked ✎ where the gate does not exist yet and needs new code.

| Capability | Trial | Growth | Scale | Notes |
|---|:--:|:--:|:--:|---|
| Flows, inbox, contacts, tags, custom fields, saved replies | ✓ | ✓ | ✓ | Core product; never gated |
| Channels available | webchat, telegram ✎ | all | all | ✎ Plan-level channel gating is new. `Tenant.hiddenChannels` exists but is tenant-level, not plan-level |
| AI agents | 1 ✎ | 3 ✎ | unlimited | ✎ Needs a count limit; no column exists |
| Broadcasts & sequences | ✗ ✎ | ✓ | ✓ | ✎ New gate |
| Appointments & calendars | ✗ ✎ | ✓ | ✓ | ✎ New gate |
| Public API + webhooks | ✗ ✎ | ✓ | ✓ | ✎ New gate |
| Email-marketing integrations | ✗ ✎ | ✓ | ✓ | Mailchimp, Klaviyo, ActiveCampaign, etc. |
| Ecommerce (products, coupons) | ✗ ✎ | ✗ ✎ | ✓ | Real upsell driver for Scale |
| Meta ads, CAPI, lead-ad automation | ✗ ✎ | ✗ ✎ | ✓ | Highest-value feature in the product |
| Inbox teams | ✗ | ✗ | ✓ | Rewritten in Phase 3 |
| Audit logs | ✗ | ✗ | ✓ | Rewritten in Phase 3 |
| Full RBAC presets | ✗ | Owner/Agent ✎ | all presets ✎ | Phase 5 |
| Priority support | ✗ | ✗ | ✓ | Process, not code |

Every ✎ row reads from the new `UserQuota.features jsonb` column via
`hasPlanFeature(userId, key)`, checked **in services, never in `apps/`**.

---

## 5. Top-up packs

Bot-message packs only to start — the plumbing (`botMessagesTopUpGranted`,
`TopUpGrant`) already exists for exactly this.

| Pack | Price | Grants |
|---|---:|---|
| Small | $12 | 10,000 bot messages |
| Large | $40 | 50,000 bot messages |

Priced at roughly 60% of the marginal per-message rate of the next tier up, so a
top-up is a convenience and never cheaper than upgrading. That keeps top-ups
from cannibalising the Growth → Scale path.

---

## 6. Open questions — these need your answer

**A. What happens when a customer hits the MAC cap?** Today it is a hard wall
that blocks sending and receiving entirely. Three options:

1. **Keep the hard wall.** Simplest, already built, no new code. Also the most
   likely to cause angry churn mid-month, because the product stops working
   during their busiest week.
2. **Sell MAC top-up packs.** Same shape as bot-message packs but needs new
   columns — `botMessagesTopUpGranted` has no MAC equivalent.
3. **Soft grace.** Allow 10–20% over cap with a banner, then block. Kindest,
   needs a new grace field and careful reconcile handling.

My recommendation is **3, then 2** — a grace band prevents the worst churn
moment and costs one column, and MAC packs follow once you see how often people
actually hit the cap.

**B. Bot-message top-ups: lifetime or period-scoped?** Upstream's design has
top-ups inflate the lifetime `botMessagesLimit`, and since I propose `null`
(unlimited) there for paid plans, top-ups would have nothing to inflate. Two
coherent fixes:

1. **Top-ups raise `monthlyBotMessagesLimit` for the current period.** Matches
   how customers think about it, but deviates from upstream's column semantics,
   so `botMessagesTopUpGranted` needs to become period-scoped.
2. **Top-up credit never expires** — give paid plans a large-but-finite
   `botMessagesLimit` that packs raise. Keeps upstream semantics exactly, and
   unexpiring credit is friendlier. Cost: a long-lived subscriber could
   theoretically hit a lifetime wall.

I lean **2** — it keeps our schema aligned with upstream (cheaper merges), and
"your credit never expires" is a better sentence than the alternative.

**C. Annual billing?** ManyChat's headline prices are annual rates, so a
monthly-only $39 looks expensive next to their advertised $39. Offering annual
at ~20% off is two more Stripe prices and no new code, but it changes how you
present the pricing page.

**D. Do the tier names work?** "Growth" and "Scale" are placeholders.

**E. Currency and tax.** Stripe Tax is a checkbox at checkout-session creation
and worth enabling from day one — retrofitting tax onto live subscriptions is
genuinely unpleasant.

---

## 7. What happens once you answer

The numbers land in three places, and they must agree:

1. `packages/business/src/billing/plans.ts` — the catalogue constant
2. The `entitlements:default-plan` Redis snapshot, published at worker boot
   (Trap 3.1) — this is what a brand-new signup reads
3. Stripe products and prices, one price ID per plan and pack, referenced by env
   var

Only the trial's numbers go into the Redis snapshot. The paid tiers are resolved
from the catalogue by `publishEntitlements` when a subscription exists.

---

*Competitor pricing observed August 2026 and subject to change. Sources:
[ManyChat pricing breakdown](https://setsmart.io/blog/manychat-pricing),
[Wati pricing review](https://bossbot.uk/blog/wati-pricing-review-2026).*
