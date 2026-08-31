# Local development setup

Getting the multichatx fork running on a Windows machine, from nothing to a
signed-in user and a green test suite.

Written for **Windows 11 + WSL2**. Native Windows is not supported by this
repo: several package scripts set environment variables inline
(`SKIP_ENV_CHECK=true dotenv …` in the builder's `build`,
`NODE_OPTIONS=--max-old-space-size=8192 tsc` in `check-types`), and that syntax
fails in PowerShell and `cmd`. Patching those scripts would create a permanent
merge conflict against upstream, so use WSL instead.

---

## 1. Prerequisites

### WSL2

In **PowerShell as Administrator**:

```powershell
wsl --install -d Ubuntu
```

Reboot when prompted. Ubuntu asks for a username and password on first launch —
that is a Linux account, unrelated to your Windows login.

### Docker Desktop

Install Docker Desktop, then open **Settings → Resources → WSL Integration** and
enable it for **Ubuntu**. Without this, `docker` does not exist inside WSL.

Verify from an Ubuntu terminal:

```bash
docker --version
docker compose version
```

### Node and pnpm

Inside Ubuntu:

```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
exec bash
nvm install 24.11.0
nvm alias default 24.11.0
corepack enable
```

The repo pins **Node 24.11.0** (`.nvmrc`) and **pnpm 10.33.2** (the
`packageManager` field in `package.json`). `corepack enable` makes pnpm resolve
to that exact version automatically — do **not** install pnpm separately, or you
will silently run a different version than CI.

Verify:

```bash
node -v    # v24.11.0
pnpm -v    # 10.33.2
```

---

## 2. Repository and remotes

**Clone into WSL's own filesystem, not `/mnt/c`.** This is not a preference —
see the measurements below.

```bash
mkdir -p ~/dev && cd ~/dev
git clone https://github.com/mm-mazhar/multichatx.git
cd multichatx
git remote add upstream https://github.com/ChatbotXIO/ChatbotX.git
```

Two remotes are required — this fork tracks upstream, so `upstream` is not
optional:

```bash
git remote -v
# origin    https://github.com/mm-mazhar/multichatx.git
# upstream  https://github.com/ChatbotXIO/ChatbotX.git
```

Reach the files from Windows (Explorer, editors) at
`\\wsl.localhost\Ubuntu\home\<you>\dev\multichatx`. VS Code opens the
project properly with the **WSL** extension and `code .` from inside WSL.

### Do not develop from /mnt/c

A `/mnt/c` checkout was tried first. It does not work for this repo at any
usable speed. Measured on the same machine, same commit:

| Operation | `/mnt/c` |
|---|---|
| `next dev` cold ready | 49–98 s |
| Turbopack cache write | 31 s |
| Turbopack cache compaction | 2 min |
| Compiling one route (`/auth/sign-in`) | **30 min +, never completed** |

The cause is the 9p filesystem boundary between WSL and NTFS. Every module
read, cache write and stat call pays a round trip, and a monorepo of this size
makes hundreds of thousands of them. Windows Defender scanning the same
directory compounds it.

Two mitigations were tried and are recorded here so nobody repeats them:

- **Disabling Turbopack's dev cache** (`turbopackFileSystemCacheForDev: false`)
  removed the 2.5 minutes of cache I/O but made cold boot *worse* — 98 s versus
  49 s — because every restart then recompiles from scratch. Reverted.
- **Symlinking `.next` onto ext4** generally fails: WSL refuses symlink creation
  on DrvFs mounts without Developer Mode.

Neither addresses the actual problem, which is that the source and
`node_modules` are on the far side of the boundary. Only moving the checkout
does.

On ext4, leave Turbopack's caches at their defaults — there the cache is an
asset, and `next.config.ts` should match upstream apart from the
`turbopackFileSystemCacheForBuild: false` line upstream already sets.

---

## 3. Environment file

**The file must be named `.env` and live at the repo root.**

This repo does not rely on Next.js's automatic env loading. Every script loads
env explicitly through `dotenv-cli`:

- workers, realtime, database: `dotenv -e ../../.env`
- builder: `dotenv -e .env -e ../../.env`

A root `.env.local` is therefore read by **nothing**. Both `.env` and
`.env.local` are gitignored, so `.env` is safe to use.

Create it from the example:

```bash
cp .env.example .env
```

### Required edits

| Variable | Value |
|---|---|
| `PLATFORM_ADMIN_EMAIL` | Uncomment and set to your email. This is what grants access to `/admin`. |
| `BETTER_AUTH_SECRET` | Regenerate: `openssl rand -base64 32` |
| `ENCRYPTION_KEY` | Regenerate: `openssl rand -hex 32` |
| `REALTIME_BROADCAST_SECRET` | **Must be regenerated.** See below. |

Everything else in `.env.example` already matches `docker-compose.yml` and works
unchanged for local development.

### Known bug: `REALTIME_BROADCAST_SECRET`

`.env.example` ships `REALTIME_BROADCAST_SECRET=secretkey` — nine characters.
The schema in `packages/partysocket-config/src/keys.ts` requires **at least 32**.
The builder therefore fails to start on a fresh copy of the example file:

```
Invalid environment variables: [
  { path: [ 'REALTIME_BROADCAST_SECRET' ],
    message: 'Too small: expected string to have >=32 characters' } ]
⨯ Failed to load next.config.ts
```

This is an upstream bug — the example file fails its own validation. Fix:

```bash
sed -i "s|^REALTIME_BROADCAST_SECRET=.*|REALTIME_BROADCAST_SECRET=$(openssl rand -hex 32)|" .env
```

The same secret is read by the builder, the workers and the realtime app. They
all load the same root `.env`, so one value covers all three.

### Verifying the file

Four variables have minimum-length rules. Check them all at once:

```bash
for v in BETTER_AUTH_SECRET ENCRYPTION_KEY REALTIME_BROADCAST_SECRET JAVASCRIPT_EXECUTOR_TOKEN; do
  val=$(grep -E "^${v}=" .env | head -1 | cut -d= -f2-)
  printf "%-28s len=%-4s %s\n" "$v" "${#val}" "$([ ${#val} -ge 32 ] && echo OK || echo TOO_SHORT)"
done
```

`SKIP_ENV_CHECK=true` exists as an escape hatch. Do not use it in development —
it hides real configuration problems until they surface as runtime errors.

### Leave the edition on `community` for now

`.env` ships `NEXT_PUBLIC_EDITION=community`, and it should stay that way until
the billing work begins.

Setting `NEXT_PUBLIC_EDITION=cloud` today breaks the app in two known ways:

1. `hasEnterpriseFeatures()` requires a valid offline licence token that this
   fork does not have, so admin routes return 404.
2. Nothing publishes the `entitlements:default-plan` Redis key, so every new
   signup gets the fallback: a one-day trial with every limit set to zero.

Both are addressed in Phases 0 and 1 of the enterprise-swap plan. Until then,
`community` gives an unlimited, ungated app — the right baseline to develop
against.

---

## 4. Infrastructure

```bash
docker compose up -d
docker compose ps
```

Wait until `postgres`, `redis` and `filesystem` report healthy. Nothing else
will work until they do.

| Service | Purpose | Port |
|---|---|---|
| `postgres` | TimescaleDB (Postgres 18) | 5432 |
| `redis` | Cache, queues, live counters | 6379 |
| `filesystem` | RustFS, S3-compatible storage | 9000 (console 9001) |
| `mailhog` | Catches all outbound email | 1025 (UI 8025) |
| `adminer` | Database browser | 8080 |
| `redis-ui` | RedisInsight | 5540 |

Credentials are `chatbotx` / `secretkey` throughout, matching `.env.example`.

**No real email leaves your machine.** Every message — signup confirmations,
magic links, password resets — lands in MailHog at <http://localhost:8025>.

---

## 5. Database

```bash
pnpm install                                      # slow on first run
pnpm --filter @chatbotx.io/database db:setup      # migrate + seed
```

`db:setup` runs `db:migrate` then `db:seed`.

> **Migration safety.** Per `AGENTS.md`, migrations must never be applied
> automatically as part of some other task. Generate them with
> `pnpm --filter @chatbotx.io/database make:migration <name>`, read the emitted
> SQL, and apply only after review. The initial `db:setup` above is the one
> exception — it is applying upstream's existing migrations to an empty
> database.

Useful during development:

```bash
pnpm --filter @chatbotx.io/database db:studio        # Drizzle Studio
pnpm --filter @chatbotx.io/database db:check-drift   # schema vs migrations
```

---

## 6. Running the apps

Start the builder on its own first. `pnpm dev` at the root launches every app at
once, and if something is broken you want one log stream rather than six.

```bash
pnpm --filter builder dev      # http://localhost:3123
```

Then, in a second terminal, the workers:

```bash
pnpm --filter worker dev       # all queue consumers via concurrently
```

Other apps, as needed:

```bash
pnpm --filter realtime dev              # PartyKit websockets, :1999
pnpm --filter javascript-executor dev   # sandboxed JS steps, :3210
```

### First sign-in

Open <http://localhost:3123> and create an account using the address in
`PLATFORM_ADMIN_EMAIL`. That match is what makes you the platform admin and
unlocks `/admin`.

The confirmation email arrives in MailHog (<http://localhost:8025>), not your
inbox.

---

## 7. Record a baseline

Do this **before** changing any code. When something breaks later you will want
to know whether you broke it or whether it was already failing.

```bash
pnpm test 2>&1 | tee ~/baseline-test.txt
pnpm --filter builder exec tsc --noEmit
```

Keep `~/baseline-test.txt`. Note that type checking is deliberately excluded
from `next build` (it OOMs a default heap), so `tsc --noEmit` and the CI
workflow are the only real type gates — a green `pnpm build` proves nothing
about types.

---

## 8. Troubleshooting

**`Invalid environment variables … REALTIME_BROADCAST_SECRET`**
The example file's value is too short. See §3.

**`Failed to load next.config.ts`**
Almost always an env validation failure. The real error is in the lines above
it — env schemas are evaluated while the Next config loads.

**Env changes have no effect**
You edited `.env.local`, or `apps/builder/.env`. The builder loads
`apps/builder/.env` *before* the root `.env`, so a stale app-level file shadows
your root values. Check with `ls apps/builder/.env` — there should be none.

**`ECONNREFUSED` on 5432 / 6379 / 9000**
Docker services are not up or not yet healthy. `docker compose ps`.

**`docker: command not found` inside WSL**
Docker Desktop's WSL integration is not enabled for Ubuntu. See §1.

**pnpm version mismatch**
A globally installed pnpm is shadowing corepack. `which pnpm` should resolve
inside the corepack shims, not `/usr/local/bin`.

**Everything is unbearably slow**
The `/mnt/c` filesystem boundary. Move the clone into WSL's own filesystem.

**Ports already in use**
Check for a second Docker stack or a stray `next dev`:
`ss -ltnp | grep -E '3123|5432|6379|9000'`.

---

## 9. Daily loop

```bash
docker compose up -d                    # once per boot
pnpm --filter builder dev               # terminal 1
pnpm --filter worker dev                # terminal 2
pnpm test                               # before every commit
pnpm --filter builder exec tsc --noEmit
```

Keeping up with upstream:

```bash
git fetch upstream
git merge upstream/main
```

Merge on a schedule rather than on demand. A monthly merge is a bad afternoon;
a six-month merge is a rewrite.
