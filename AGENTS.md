# AGENT.md — lenticel infrastructure

You are an ops agent maintaining a lenticel server so that the user can tunnel work-in-progress on any development project to the open web in seconds. Read this file fully before doing anything. Update it and PLAN.md whenever you learn something or complete a step.

**Your job is not done when you write code.** For every change:
1. Deploy it (push to remote, or run the relevant script directly on the VPS)
2. Verify it works (check logs, curl an endpoint, run a plan, whatever is appropriate)
3. Report the verified result to the user

Do not hand unverified work back to the user and call it done.

Commit and push cohesive, granular changes often.

---

## What this repo does

Provides stable public HTTPS subdomains (`*.YOUR_DOMAIN`) for dev environments anywhere (local machines, Codespaces, devcontainers). Built on frp (frps server + frpc client). No manual DNS changes needed per project — register an OAuth callback once and it always works.

---

## Current state: FULLY OPERATIONAL

The core infrastructure is live. All of the following are done:

### Infrastructure (Terraform-managed)
- **Vultr VPS** — `<VPS_IP>`, region `ewr`, plan `vc2-1c-1gb` ($5/mo), Ubuntu 24.04
- **Bunny DNS zone** — `YOUR_DOMAIN` zone created; `A` records for `YOUR_DOMAIN` and `*.YOUR_DOMAIN` → `<VPS_IP>`
- **Namecheap** — nameservers for `YOUR_DOMAIN` updated to `kiki.bunny.net` + `coco.bunny.net` ✅

### Server (running on VPS at /opt/lenticel)
- **Caddy** — running, wildcard TLS cert for `*.YOUR_DOMAIN` issued by Let's Encrypt via DNS-01 (Bunny plugin) ✅
- **frps** — running on port 7000, vhost HTTP on 8080, auth token active ✅
- **Verified**: `curl -I https://anything.YOUR_DOMAIN` → HTTP/2 200-range/404, `via: Caddy` ✅

### Client (local)
- **frpc** v0.61.0 installed at `~/.local/bin/frpc`
- **Config** at `~/.config/lenticel/frpc.toml` (token baked in at install time)
- **Wrapper** at `~/.local/bin/lenticel`
- **SSH alias** `lenticel` → `root@<VPS_IP>` using `~/.ssh/id_lenticel`
- **Verified**: frpc connects, `https://test.YOUR_DOMAIN` responds end-to-end ✅

---

## Repository layout

```
terraform/          Terraform for Vultr VPS + Bunny DNS (state gitignored)
server/             Files deployed to /opt/lenticel on VPS
  Dockerfile.caddy  xcaddy build with caddy-dns/bunny plugin
  Caddyfile         Wildcard TLS reverse proxy to frps:8080 + ctl.YOUR_DOMAIN
  frps.toml.tmpl    frps config template — ${FRP_AUTH_TOKEN} placeholder
  frps.toml         GITIGNORED — rendered by deploy.sh from template
  docker-compose.yml
  ctl.rb            Control API server (Ruby/WEBrick) — runs on VPS host via systemd
  lenticel-ctl.service  systemd unit for ctl.rb
  .env.example      Documents BUNNY_API_KEY + FRP_AUTH_TOKEN
  .env              GITIGNORED — actual secrets, lives on VPS + locally
purse/              Client dotfiles (submodule)
  install-frpc.sh   Install frpc + lenticel wrapper; resolve token; bootstrap project config from env vars
  lenticel          Wrapper: multi-port tunneling with env var templating, project configs
  shell-setup.sh    Source from .bashrc/.zshrc: adds ~/.local/bin to PATH, dt alias
script/
  deploy.sh         Renders frps.toml, rsyncs to VPS, docker compose up, deploys ctl service
  update-vps-env.sh Push local server/.env to VPS (for secret rotation)
docs/
  zoho-vault-cli.pdf  Zoho Vault CLI documentation
```

---

## Key secrets (never commit)

| Secret | Where it lives |
|--------|---------------|
| `FRP_AUTH_TOKEN` | `server/.env` (VPS + local), `~/.config/lenticel/frpc.toml`, frps admin password |
| `BUNNY_API_KEY` | `server/.env` (VPS + local), `terraform/terraform.tfvars` |
| `VULTR_API_KEY` | `.env` (local root), `terraform/terraform.tfvars` |
| Terraform state | `terraform/terraform.tfstate` (gitignored) |
| SSH key | `~/.ssh/id_lenticel` (private), Vultr key ID `<your-vultr-ssh-key-id>` |

---

## Gotchas discovered (do not repeat these mistakes)

1. **frps `command:` override** — `snowdreamtech/frps:latest` uses an `su-exec` entrypoint; passing `command: -c /etc/frp/frps.toml` sends `-c` to su-exec, not frps. **Fix: no `command:` in compose — image defaults to `/etc/frp/frps.toml`.**

2. **Docker on Ubuntu 24.04** — `docker-compose-plugin` is NOT in the Ubuntu universe apt repo. Must add Docker's official apt repo (`download.docker.com/linux/ubuntu`).

3. **apt upgrade in cloud-init** — hangs on interactive PAM dialog. **Fix: always use `DEBIAN_FRONTEND=noninteractive` with `-o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"`.**

4. **Caddy xcaddy build on 1-vCPU VPS** — takes 20+ minutes (Go linker is slow). Doesn't OOM, just slow. **Future fix: build image locally or via GitHub Actions and push to ghcr.io.**

5. **frps.toml is gitignored** — `server/frps.toml.tmpl` is the template (committed); `server/frps.toml` is the rendered file (gitignored). `deploy.sh` renders it via `envsubst` before rsyncing. Don't commit the rendered file.

6. **ufw blocks Docker→host traffic** — Docker containers using `host.docker.internal` (172.17.0.1) to reach host services hit the INPUT chain, which ufw DROPs by default. **Fix: `ufw allow from 172.16.0.0/12 to any port 9191 proto tcp`** so Caddy can reach ctl.rb. Docker's own port mappings (80, 443, 7000) bypass INPUT via PREROUTING/FORWARD, so they're unaffected.

7. **Subdomain-specific eviction** — frps has no API to kick a single client. **Fix: ctl.rb queries the frps admin API to find the clientID for a subdomain, parses container logs to find the client's remote IP:port, then uses `nsenter` into the frps container's network namespace + `ss --kill` to surgically terminate that one TCP connection.** Falls back to restarting frps if anything fails.

---

## Deployment

**Fully automated via GitHub Actions.** Any push to `main` triggers `.github/workflows/deploy.yml`, which:

1. Builds & pushes the Caddy image to `ghcr.io/<owner>/lenticel-caddy`
2. Rsyncs `server/` to the VPS at `/opt/lenticel/` (excluding `.env` and `frps.toml`)
3. On VPS: renders `frps.toml` from template using the VPS's own `.env`
4. Runs `docker compose pull && docker compose up -d`
5. Installs Ruby if needed, deploys `lenticel-ctl` systemd service

**Note:** CI has NO access to `FRP_AUTH_TOKEN` or `BUNNY_API_KEY` — all secrets live only on the VPS in `/opt/lenticel/.env`. Manage them manually via `script/update-vps-env.sh`.

**GHA secrets required:** `DEPLOY_SSH_KEY` (ed25519 private key), `VPS_IP` — that's it.

Manual deploy is still possible as a fallback:
```bash
source server/.env && VPS_IP=<your-vps-ip> bash script/deploy.sh
```

---

## TODO / Next steps

See [PLAN.md](PLAN.md#todo--next-steps) for the full list of completed and remaining TODOs.

---

## Terraform

```bash
cd terraform
# API keys must be in terraform.tfvars (gitignored) or TF_VAR_* env vars
terraform plan
terraform apply
```

State is local (`terraform.tfstate`, gitignored). If reprovisioning, `terraform destroy` first or `terraform import` existing resources.