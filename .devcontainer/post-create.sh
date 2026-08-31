#!/usr/bin/env bash
# Codespace / devcontainer bootstrap for multichatx.
#
# Runs once when the container is created. Idempotent — safe to re-run by hand
# with `bash .devcontainer/post-create.sh` if something needs redoing.
set -euo pipefail

cd "$(dirname "$0")/.."
say() { printf '\n\033[1;36m▸ %s\033[0m\n' "$1"; }
warn() { printf '\n\033[1;33m! %s\033[0m\n' "$1"; }

# ── pnpm ─────────────────────────────────────────────────────────────────────
# Corepack reads `packageManager` in package.json, so this pins pnpm to the
# exact version CI uses. Never `npm i -g pnpm` here — that silently diverges.
say "Enabling corepack (pnpm from package.json)"
corepack enable
corepack prepare --activate

# ── .env ─────────────────────────────────────────────────────────────────────
# Must be named .env at the repo root: every script loads it explicitly via
# dotenv-cli (`dotenv -e ../../.env`), so .env.local is read by nothing.
if [ -f .env ]; then
  say ".env already present — leaving it alone"
else
  say "Creating .env from .env.example"
  cp .env.example .env

  # .env.example ships REALTIME_BROADCAST_SECRET=secretkey (9 chars) but the
  # schema in packages/partysocket-config/src/keys.ts demands >= 32. The example
  # file fails its own validation; the builder will not boot without this fix.
  sed -i "s|^BETTER_AUTH_SECRET=.*|BETTER_AUTH_SECRET=$(openssl rand -base64 32)|" .env
  sed -i "s|^ENCRYPTION_KEY=.*|ENCRYPTION_KEY=$(openssl rand -hex 32)|" .env
  sed -i "s|^REALTIME_BROADCAST_SECRET=.*|REALTIME_BROADCAST_SECRET=$(openssl rand -hex 32)|" .env

  # Force IPv4 on every backend connection. Node 17+ resolves `localhost`
  # verbatim, which usually yields ::1 first; inside Docker-in-Docker the IPv6
  # publish goes through Docker's userland proxy and black-holes, so connections
  # hang until they ETIMEDOUT instead of failing fast. That surfaces as
  # better-auth returning 404 (trustedOrigins -> listActiveDomains -> Redis).
  # Only server-side URLs — the NEXT_PUBLIC_* ones are browser-facing.
  sed -i \
    -e 's|^DATABASE_URL=postgresql://\(.*\)@localhost:|DATABASE_URL=postgresql://\1@127.0.0.1:|' \
    -e 's|^REDIS_URL=redis://localhost:|REDIS_URL=redis://127.0.0.1:|' \
    -e 's|^S3_ENDPOINT=http://localhost:|S3_ENDPOINT=http://127.0.0.1:|' \
    -e 's|^JAVASCRIPT_EXECUTOR_URL=http://localhost:|JAVASCRIPT_EXECUTOR_URL=http://127.0.0.1:|' \
    -e 's|@localhost:1025|@127.0.0.1:1025|' \
    .env

  # Codespaces serves the app from a forwarded *.app.github.dev origin. better-auth
  # builds trustedOrigins from NEXT_PUBLIC_BUILDER_URL, so leaving these at
  # localhost makes every auth request a 404 in the browser editor. Harmless when
  # connecting from VS Code Desktop, where localhost forwarding applies.
  if [ -n "${CODESPACE_NAME:-}" ] && [ -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]; then
    APP_URL="https://${CODESPACE_NAME}-3123.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
    sed -i "s|^NEXT_PUBLIC_BUILDER_URL=.*|NEXT_PUBLIC_BUILDER_URL=${APP_URL}|" .env
    sed -i "s|^BETTER_AUTH_URL=.*|BETTER_AUTH_URL=${APP_URL}|" .env
    say "App URL set to ${APP_URL}"
  fi

  # Grants /admin access. Prefer an explicit Codespaces secret; fall back to the
  # git identity Codespaces populates from the GitHub account.
  ADMIN_EMAIL="${PLATFORM_ADMIN_EMAIL:-$(git config --get user.email || true)}"
  if [ -n "$ADMIN_EMAIL" ]; then
    sed -i "s|^# PLATFORM_ADMIN_EMAIL=.*|PLATFORM_ADMIN_EMAIL=${ADMIN_EMAIL}|" .env
    say "Platform admin set to ${ADMIN_EMAIL}"
  else
    warn "PLATFORM_ADMIN_EMAIL not set — /admin will be unreachable."
    warn "Fix: set PLATFORM_ADMIN_EMAIL in .env, or add it as a Codespaces secret."
  fi
fi

# ── dependencies ─────────────────────────────────────────────────────────────
say "Installing dependencies (a few minutes on a cold container)"
pnpm install --frozen-lockfile

# ── infrastructure ───────────────────────────────────────────────────────────
say "Starting Postgres, Redis, RustFS and MailHog"
docker compose up -d

say "Waiting for Postgres"
for i in $(seq 1 60); do
  if docker compose exec -T postgres pg_isready -U chatbotx -d chatbotx >/dev/null 2>&1; then
    echo "  ready after ${i}s"
    break
  fi
  [ "$i" -eq 60 ] && { warn "Postgres did not become ready. Check: docker compose ps"; exit 1; }
  sleep 1
done

# ── database ─────────────────────────────────────────────────────────────────
# AGENTS.md forbids applying migrations automatically as part of other work.
# This is the sanctioned exception: applying upstream's existing migrations to a
# brand-new empty container database. It never generates a migration, and the
# root Tenant row (ROOT_TENANT_ID) comes from the add_tenant_tables migration,
# so the app cannot boot without this step.
say "Applying migrations to the empty container database"
pnpm --filter @chatbotx.io/database db:migrate

cat <<'DONE'

────────────────────────────────────────────────────────────────────────
  Ready.

  Start the builder:   pnpm --filter builder dev        → port 3123
  Start a worker:      pnpm --filter worker worker:schedule
  Optional demo data:  pnpm --filter @chatbotx.io/database db:seed
                       (demo@example.com / Demo@1234)

  MailHog :8025 catches every outbound email — nothing is really sent.
  Adminer :8080 · RedisInsight :5540 · RustFS console :9001

  NOTE ON URLs — .env is configured for the BROWSER editor
  NEXT_PUBLIC_BUILDER_URL and BETTER_AUTH_URL point at this Codespace's
  forwarded *.app.github.dev origin, because better-auth builds its
  trustedOrigins list from them and rejects any request from an origin it
  does not recognise (it answers 404, which looks nothing like an origin
  problem).

  Switching to VS Code Desktop? It forwards ports to your real localhost,
  so set both back or auth breaks the other way:

    sed -i "s|^NEXT_PUBLIC_BUILDER_URL=.*|NEXT_PUBLIC_BUILDER_URL=http://localhost:3123|" .env
    sed -i "s|^BETTER_AUTH_URL=.*|BETTER_AUTH_URL=http://localhost:3123|" .env

  Backend connections use 127.0.0.1, not localhost, on purpose — see the
  comment in this script. Do not "tidy" them back.
────────────────────────────────────────────────────────────────────────

DONE
