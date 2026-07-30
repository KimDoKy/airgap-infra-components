# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Deployment tooling for standing up three services (Gitea Git server, Jenkins, Nexus Repository) as
Docker containers on air-gapped ("폐쇄망") VMs — plus a `Docker/` directory that installs Docker
itself as a prerequisite on each target VM. Everything is shell scripts + docker-compose + nginx for
TLS termination; there is no application source code to build, lint, or unit-test.

Documentation (README.md, MANUAL.md, script comments, commit messages) is written in Korean. Match
that when editing docs/comments in this repo unless told otherwise.

## Repository structure

Four **independent** top-level directories: `Docker/`, `GitServer/`, `Jenkins/`, `Nexus/`. Each is
meant to be copied wholesale to its own VM and operated on its own — there is intentionally no shared
compose file or unified entrypoint (each VM is set up individually by an operator following the
MANUAL.md in that directory). `check/` is the sole exception: a local-only end-to-end verification
harness that is never copied to a VM.

Within `GitServer/`, `Jenkins/`, `Nexus/` the layout is the same:
- `.env` — all configuration (image tags, ports, TLS domain, admin credentials, SSH transfer target).
  Real deployments must change `ADMIN_PASSWORD`/`JENKINS_ADMIN_PASSWORD` and `TLS_DOMAIN` before use.
- `scripts/NN-*.sh` — numbered, run in order. Each script's `[로컬]`/`[VM]` comment marks whether it
  runs on the operator's internet-connected PC or on the air-gapped VM.
- `docker-compose.yml` — the service container + an `nginx` sidecar container for TLS termination.
- `nginx/nginx.conf`, `certs/` — reverse proxy config and self-signed TLS cert (generated on the VM).
- `README.md` — high-level flow (local PC → VM). `MANUAL.md` — operator runbook for once files are
  already on the VM (install/start/init/verify/troubleshoot/backup/upgrade). Prefer MANUAL.md as the
  source of truth for what a script does on the VM.

`Docker/` follows the same `scripts/NN-*.sh` + `.env` pattern but only has 4 steps (download →
transfer → install → verify) since it has no service container of its own.

### Standard workflow every service directory follows

1. **Local PC** (has internet): `01-*.sh` downloads/pulls-and-saves the needed binary or container
   image(s) into `packages/` or `images/`.
2. **Local PC**: `02-transfer-to-vm.sh` ships the whole directory (scripts + `.env` + downloaded
   artifacts) to the air-gapped VM over SSH — via `rsync` if both ends have it, else falls back to
   `tar` + `scp` automatically (checked on **both** local and VM sides, not just local).
3. **VM**: remaining scripts load the image, generate a self-signed TLS cert
   (`04-generate-tls-cert.sh`), start the containers, and initialize the service headlessly — no web
   install wizard, CLI/REST API only:
   - Gitea: `INSTALL_LOCK=true` + `gitea admin user create` CLI (must run as `-u <USER_UID>`, not root)
   - Jenkins: `-Djenkins.install.runSetupWizard=false` + a Groovy script in `config/init.groovy.d/`
   - Nexus: REST API (curl) sets the admin password and disables anonymous access

SSH transfer target for a given directory is set via that directory's `.env`:
`VM_SSH_HOST`/`VM_SSH_USER`/`VM_SSH_PORT`/`VM_REMOTE_DIR`. Key-based SSH auth (`ssh-copy-id`) is
assumed so transfer scripts run non-interactively.

Each service's nginx sidecar is the only thing exposed on 443/80 (HTTPS + redirect); the service
itself only listens in-container over plain HTTP. Non-HTTP ports bypass nginx and are exposed
directly: Gitea's git-SSH port (`SSH_PORT`, default 2222), Jenkins' agent/JNLP port (`AGENT_PORT`,
default 50000).

## Verification (`check/`)

`check/` runs the **actual, unmodified** `GitServer/`/`Jenkins/`/`Nexus/` deploy scripts end-to-end
against a fake VM, using real container images and real REST/CLI calls (no mocks/dummy data) —
this is how real bugs in the deploy scripts get caught.

```bash
cd check
./gitserver-check.sh
./jenkins-check.sh
./nexus-check.sh
```

Run only one at a time — the fake VM uses `--network host`, so concurrent runs collide on the SSH
port (2222). Requires local Docker, `ssh-keygen`/`ssh`/`scp`, `curl`, `openssl`, and internet access
(pulls real images, ~100–600MB each, cached after first run).

How it works (see `check/README.md` and `check/lib/mock-vm.sh` for full detail):
- Copies the target directory into `check/.work/<service>/` and only mutates the copy's `.env`
  (test ports/passwords) — original `.env`, `certs/`, `data/`/`jenkins_home/`/`nexus-data/` are never
  touched. `.work/` is deleted on exit.
- The "fake VM" is a `linuxserver/openssh-server` container sharing the host's `docker.sock`
  (Docker-outside-of-Docker) and running with `--network host`, so `localhost:<port>` health checks
  inside the deploy scripts see the same thing they would on a real VM.
- The fake VM's working directory is bind-mounted at the **same absolute path** as on the host, since
  `docker compose` resolves relative volume paths (e.g. `./data`) to absolute host paths before
  handing them to the shared daemon.
- A `ssh`/`scp` wrapper is placed early in `PATH` inside the fake VM to inject `-i`/`-o` for the
  test SSH key, without modifying the deploy scripts themselves.

When changing any `GitServer/`/`Jenkins/`/`Nexus/scripts/*.sh`, run the corresponding `check/*.sh`
before considering the change done — dummy-data testing has historically missed real bugs here (see
"이 작업으로 실제로 찾아서 고친 버그" in `check/README.md` for examples: wrong exec user for Gitea
CLI, a health-check race condition, missing VM-side rsync fallback).
