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

  NOTE ON URLs
  Connecting from VS Code Desktop? Ports forward to your real localhost,
  so http://localhost:3123 works and .env is correct as shipped.

  Using the browser-based editor instead? The app is served from a
  forwarded *.app.github.dev URL, and sign-in will fail until .env agrees:

    URL="https://${CODESPACE_NAME}-3123.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
    sed -i "s|^NEXT_PUBLIC_BUILDER_URL=.*|NEXT_PUBLIC_BUILDER_URL=$URL|" .env
    sed -i "s|^BETTER_AUTH_URL=.*|BETTER_AUTH_URL=$URL|" .env

  Also set port 3123's visibility to Public in the Ports panel, or the
  browser cannot reach it.
────────────────────────────────────────────────────────────────────────

DONE
