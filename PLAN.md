# Lenticel Infrastructure — `*.YOUR_DOMAIN`

Stable public subdomains for dev environments (local, Codespaces, anywhere).
Each subdomain ties to a running `frpc` instance — disconnect and it's gone.
OAuth redirect URIs registered once, never touched again.

> **Status: LIVE.** Steps 1–5 are complete. See AGENTS.md for full operational details.

---

## Step 1: Vultr VPS — ✅ DONE (Terraform-managed)

Provisioned via Terraform (`terraform/`). Running at `<VPS_IP>`.

- Ubuntu 24.04, `vc2-1c-1gb` ($5/mo), region `ewr`
- SSH: `ssh lenticel` (uses `~/.ssh/id_lenticel`, configured in `~/.ssh/config`)
- Docker CE installed from official Docker apt repo (NOT `docker.io` from Ubuntu — that lacks `docker-compose-plugin`)
- **Note:** `DEBIAN_FRONTEND=noninteractive` required in cloud-init to avoid PAM hang during `apt upgrade`

```bash
cd terraform && terraform apply   # to reprovision
```

---

## Step 2: DNS — ✅ DONE (Terraform-managed)

Bunny.net manages DNS for `YOUR_DOMAIN`. Terraform creates the zone and records.
Namecheap nameservers for `YOUR_DOMAIN` set to `kiki.bunny.net` + `coco.bunny.net`.

```
A  YOUR_DOMAIN    →  <VPS_IP>
A  *.YOUR_DOMAIN  →  <VPS_IP>
```

---

## Step 3: TLS — ✅ DONE

Caddy uses `caddy-dns/bunny` plugin for ACME DNS-01 wildcard cert issuance.
Wildcard cert for `*.YOUR_DOMAIN` issued by Let's Encrypt and auto-renewing.
Requires `BUNNY_API_KEY` in `server/.env` on the VPS.

---

## Step 4: Server Files — ✅ DONE

Files are in `server/` and deployed to `/opt/lenticel/` on the VPS via `script/deploy.sh`.

**Important:** `server/frps.toml` is **gitignored**. The committed file is `server/frps.toml.tmpl` with a `${FRP_AUTH_TOKEN}` placeholder. `deploy.sh` renders it via `envsubst` before rsyncing. Never commit the rendered file.

For reference, the actual files:

### `Dockerfile.caddy`

```dockerfile
FROM caddy:2-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/bunny

FROM caddy:2-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
```

### `Caddyfile`

```caddyfile
*.{$LENTICEL_DOMAIN} {
    tls {
        dns bunny {env.BUNNY_API_KEY}
    }

    reverse_proxy frps:8080 {
        header_up Host {host}
    }
}
```

### `frps.toml`

```toml
bindPort = 7000
vhostHTTPPort = 8080

subdomainHost = "${LENTICEL_DOMAIN}"

auth.method = "token"
auth.token = "REPLACE_WITH_OUTPUT_OF: openssl rand -hex 32"
```

### `docker-compose.yml`

```yaml
services:
  caddy:
    build:
      context: .
      dockerfile: Dockerfile.caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    environment:
      BUNNY_API_KEY: ${BUNNY_API_KEY}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - frps

  frps:
    image: snowdreamtech/frps:latest
    restart: unless-stopped
    ports:
      - "7000:7000"
    volumes:
      - ./frps.toml:/etc/frp/frps.toml:ro
    # NOTE: no 'command:' override — snowdreamtech/frps uses su-exec entrypoint;
    # passing -c hits su-exec not frps. Image defaults to /etc/frp/frps.toml.

volumes:
  caddy_data:
  caddy_config:
```

### `.env`

```bash
BUNNY_API_KEY=your-bunny-api-key-here
```

`chmod 600 .env` — don't commit this.

---

## Step 5: Launch — ✅ DONE

```bash
# Deploy (from local machine):
source server/.env && VPS_IP=<your-vps-ip> bash script/deploy.sh

# Or on the VPS directly:
cd /opt/lenticel && docker compose up -d
```

**Building Caddy** (`xcaddy` compiles Go from source) takes ~20 min on the 1-vCPU VPS — it doesn't OOM, just slow. It's a one-time cost per Dockerfile change. TODO: move build to GitHub Actions → ghcr.io so VPS just pulls.

Verified: `curl -I https://anything.YOUR_DOMAIN` → HTTP/2, `via: Caddy` ✅

---

## Step 6: Dotfiles Setup — ✅ DONE

Client scripts live in the dotfiles repo, included here as a submodule at `purse/`.

**Files in `purse/`:**
- `install-frpc.sh` — installs frpc binary + `lenticel` wrapper + writes base `~/.config/lenticel/frpc.toml` + optional project config
- `lenticel` — wrapper: reads project config, generates multi-port frpc config at runtime, templates env vars, evicts via ctl.YOUR_DOMAIN
- `shell-setup.sh` — sourced from `.bashrc`/`.zshrc`: adds `~/.local/bin` to PATH, `dt` alias
- `install.sh` — bootstrap: installs zv, runs `install-frpc.sh`, hooks shell-setup into rc files

**Token resolution order in `install-frpc.sh`:**
1. `$LENTICEL_TOKEN` env var — injected automatically in GitHub Codespaces via org secret
2. Zoho Vault CLI (`zv`) — prompts for master password if vault is locked and stdin is a tty
3. Interactive prompt — fallback for new machines

`LENTICEL_TOKEN` is set as a Codespaces org secret — injected automatically, no interaction needed.

### Multi-port project configs

Each project gets a TOML config at `~/.config/lenticel/projects/<project>.toml`:

```toml
subdomain = "myapp"

[[ports]]
port = 3000
label = "rails"

[[ports]]
port = 3036
label = "vite"

[env]
MYAPP_HOSTNAME = "{rails}"
VITE_RUBY_ASSET_HOST = "https://{vite}"
VITE_HMR_CLIENT_PORT = "443"
```

**Usage:**
```bash
lenticel myapp                  # start tunnel (frpc foreground)
lenticel myapp -- serve         # start tunnel + exec 'serve' with env vars
lenticel myapp edit             # create/edit config in $EDITOR
lenticel myapp env              # print env vars for sourcing
LENTICEL_NAME=myapp lenticel -- serve   # name from env var
```

**Labels → subdomains:** first port uses the bare subdomain (`myapp.YOUR_DOMAIN`), subsequent ports get `<subdomain>-<label>.YOUR_DOMAIN` (e.g. `myapp-vite.YOUR_DOMAIN`).

**Env var templating:** `{label}` in `[env]` values is replaced with the label's hostname. The wrapped command inherits these as environment variables.

**Codespaces bootstrap:** set these as repo-scoped secrets and `install-frpc.sh` generates the project config automatically:
- `LENTICEL_NAME` — project/subdomain name
- `LENTICEL_PORTS` — `"3000 3036:vite"`
- `LENTICEL_ENV` — newline-delimited `KEY=VALUE` with `{label}` templates

No DNS changes, no cert changes, no server changes needed per project.

---

## Step 7: Usage — ✅ DONE

After `install-frpc.sh` runs:

```bash
lenticel myproject       # tunnel localhost:3000 → https://myproject.YOUR_DOMAIN
lenticel myproject 4000  # tunnel localhost:4000 → https://myproject.YOUR_DOMAIN
lt myproject             # same, short alias (from shell-setup.sh)
```

Ctrl-C disconnects. Subdomain goes dark. Restart anywhere to reconnect.

---

## OAuth Setup

Register once per app, never change:

```
https://myapp.YOUR_DOMAIN/auth/callback
https://myapp-staging.YOUR_DOMAIN/auth/callback
```

---

## TODO / Next steps

### 1. Zoho Vault CLI integration ✅ DONE
- Binary is `zv` (installed locally from `zv_cli.zip` at `https://downloads.zohocdn.com/vault-cli-desktop/linux/zv_cli.zip`)
- PDF docs are at `docs/zoho-vault-cli.pdf`
- Secret **`lenticel-frp-auth-token`** added to vault as a Web Account entry
  - Note: secret names cannot contain `/` in Zoho Vault
  - Set `ZV_SECRET_ID` env var in your environment to the Zoho secret ID
- Retrieval command (requires vault to be unlocked and `jq` installed):
  ```bash
  zv get -id "$ZV_SECRET_ID" --not-safe --output json \
    | jq -r '.secret.secretData[] | select(.id == "password") | .value'
  ```
- `zv get` **hangs when vault is locked** — must run `zv unlock [masterpassword]` first
- `zv unlock` accepts the master password as a positional arg (non-interactive)
- `dotfiles/install-frpc.sh` now uses the real `zv get` command with a 5-second timeout; if locked and stdin is a tty it prompts for the master password to unlock

### 2. Per-project subdomain support ✅ DONE

`install-frpc.sh` now reads two optional env vars when writing `~/.config/lenticel/frpc.toml`:

| Env var | Default | Effect |
|---------|---------|--------|
| `LENTICEL_SUBDOMAIN` | `myproject` | Subdomain to tunnel to (e.g. `glorb` → `glorb.YOUR_DOMAIN`) |
| `LENTICEL_PORT` | `3000` | Default local port; still overridable at runtime via `lenticel [PORT]` |

To preconfigure a Codespace for repo **glorb** to always use `glorb.YOUR_DOMAIN:3000`, add a `.devcontainer/devcontainer.json` to that repo:

```jsonc
{
  "name": "glorb",
  "containerEnv": {
    "LENTICEL_SUBDOMAIN": "glorb",
    "LENTICEL_PORT": "3000"
  },
  "postCreateCommand": "curl -fsSL https://raw.githubusercontent.com/YOUR_ORG/lenticel/main/purse/install-frpc.sh | bash"
}
```

`LENTICEL_TOKEN` is already a Codespaces org-level secret and is injected automatically.

### 2b. Latest-wins / subdomain claiming ✅ DONE

frp does **not** natively evict an existing connection when a new one claims the same subdomain — by default the first client wins. We achieve **instant latest-wins** via a control API:

**How it works:**
1. The `lenticel` wrapper calls `POST https://ctl.YOUR_DOMAIN/evict` with the auth token
2. `ctl.YOUR_DOMAIN` routes to a tiny Ruby/WEBrick service (`server/ctl.rb`) running on the VPS host via systemd
3. The service validates the Bearer token (= `FRP_AUTH_TOKEN`) and runs `docker compose restart frps`
4. frps restarts (~1-2s), dropping all active tunnels
5. The new frpc connects immediately and claims the subdomain

**Result:** Running `lenticel` or `lt` always takes over the subdomain instantly, no matter what was connected before.

**Fallback:** frpc is also configured with `loginFailExit = false` + `heartbeatInterval = 10`, and frps has `heartbeatTimeout = 30`. So even if the eviction endpoint is unreachable, frpc will keep retrying and eventually claim the subdomain once the old client dies (~30s).

**Architecture:**
```
lenticel client                           VPS (<VPS_IP>)
──────────────────                        ──────────────────
1. POST https://ctl.YOUR_DOMAIN/evict ──→ Caddy ──→ ctl.rb:9191 (host)

   Authorization: Bearer $TOKEN           validates token
                                          docker compose restart frps
                                          ← {"ok":true}
2. sleep 2
3. exec frpc -c frpc.toml ──────────→ frps:7000
                                       subdomain claimed ✓
```

**Components:**
- `server/ctl.rb` — Ruby/WEBrick HTTP server on port 9191, bound to 127.0.0.1
- `server/lenticel-ctl.service` — systemd unit running ctl.rb, reads `/opt/lenticel/.env`
- `server/Caddyfile` — `ctl.{$LENTICEL_DOMAIN}` block proxies to `host.docker.internal:9191`
- `docker-compose.yml` — Caddy gets `extra_hosts: host.docker.internal:host-gateway`

### 2c. frps admin dashboard ✅ DONE

frps now exposes an admin API/dashboard on port 7500, bound to VPS localhost only (not public internet).
Auth: username `admin`, password = `FRP_AUTH_TOKEN`.

Access via SSH port-forward:
```bash
ssh lenticel -L 7500:localhost:7500
# Then open: http://localhost:7500  (user: admin, pass: FRP_AUTH_TOKEN)
```

Useful API endpoints (curl from VPS or via forward):
```bash
# List active HTTP proxies:
curl -su admin:$FRP_AUTH_TOKEN http://localhost:7500/api/proxy/http | jq .
# Server info:
curl -su admin:$FRP_AUTH_TOKEN http://localhost:7500/api/serverinfo | jq .
```

### 3. Add LENTICEL_TOKEN to GitHub Codespaces secrets ✅ DONE
- Name: `LENTICEL_TOKEN`, value: `FRP_AUTH_TOKEN` from `server/.env`
- Injected automatically into all Codespaces; `install-frpc.sh` picks it up without any interaction

### 3b. Client scripts in purse/ submodule ✅ DONE
- `install-frpc.sh`, `lenticel`, and `shell-setup.sh` live in `purse/` (the dotfiles repo) as their canonical home — not in this repo
- `purse/install.sh` runs `bash ~/dotfiles/install-frpc.sh` directly (no cross-repo curl)
- `install-frpc.sh` copies `lenticel` and `shell-setup.sh` from its own directory — no external fetch needed

### 4. GitHub Actions — full CI/CD deploy ✅ DONE + LIVE
- Unified workflow at `.github/workflows/deploy.yml` (replaces old `build-caddy.yml`)
- Triggers on **every** push to `main`, or manually via `workflow_dispatch`
- `build-caddy` job: builds and pushes to `ghcr.io/<owner>/lenticel-caddy:latest` + `sha-<sha>` tags; uses GHA cache
- `deploy` job: rsyncs `server/` to VPS, renders `frps.toml` on VPS from template + VPS `.env`, runs `docker compose up -d`, deploys `lenticel-ctl` systemd service
- `ghcr.io/<owner>/lenticel-caddy` package is **public** — VPS pulls without auth
- GHA secrets: `DEPLOY_SSH_KEY` (ed25519 private key), `VPS_IP` — no application secrets needed in CI
- VPS deploy key in `root@<VPS_IP>:~/.ssh/authorized_keys`
- `server/docker-compose.yml` uses `image: ${CADDY_IMAGE}` from VPS `.env` (build fallback commented in)

### 5. Stop deploying secrets from CI ✅ DONE
- Removed all secret references (`FRP_AUTH_TOKEN`, `BUNNY_API_KEY`) from `.github/workflows/deploy.yml`
- `frps.toml` is now rendered on the VPS itself (sources `/opt/lenticel/.env` + `envsubst`)
- `.env` on the VPS is managed manually via `script/update-vps-env.sh`
- CI only needs `DEPLOY_SSH_KEY` and `VPS_IP` — no application secrets at all

### 6. Terraform state on VPS ✅ DONE

State lives at `/opt/lenticel/terraform.tfstate` on the VPS. Use `script/tf.sh` instead of `terraform` directly — it syncs state down before and up after each run.

```bash
script/tf.sh plan
script/tf.sh apply
```

**Decision rationale:** Vultr Object Storage cheapest tier is $18/mo in ewr — more than 3× the VPS cost for a ~50KB file. Bunny S3 is closed beta. Terraform Cloud requires a new signup. The VPS is stable, already SSH-accessible, and outlives any local machine. No locking needed (solo operator, apply stays manual).

CI runs `terraform plan`/`apply` by hand only. Drift detection via CI is not worth the complexity for mostly-static infra.

---

## Maintenance Notes

- Caddy auto-renews certs. Zero intervention needed.
- frps is stateless — restart is safe anytime.
- Upgrade frpc: bump `FRPC_VERSION` in `dotfiles/install-frpc.sh`, re-run.
- Upgrade frps: `ssh lenticel 'cd /opt/lenticel && docker compose pull && docker compose up -d'`
- Cost: ~$5/mo Vultr + $0 Bunny DNS (free tier).
