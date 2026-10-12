# Synology Docker Compose

Docker Compose definitions for selected services on `SynologyNAS`. GitHub Actions validates every change and deploys validated pushes to `main` over Tailscale and SSH.

## Managed stacks

| Stack | Compose project | Services | Host ports | Persistent paths |
| --- | --- | --- | --- | --- |
| `arrs-compose` | `arrs` | Prowlarr, Sonarr, Lidarr, Radarr, Readarr, Bazarr, Overseerr | 9696, 8989, 8686, 7878, 8787, 6767, 5055 | `/volume2/config/*`, `/volume1/data` |
| `sabnzb-compose` | `sabnzb` | SABnzbd | 8080 | `/volume2/config/sabnzbd`, `/volume1/data` |
| `tmdb-radarr-compose` | `tmdb-radarr` | TMDB/Radarr updater, Ofelia | none | NAS-local `.env`; Docker socket read-only for Ofelia |
| `watchtower-compose` | `watchtower` | Watchtower | none | Docker socket |

`/volume2/docker/whisparr` is not managed by this repository or its deployment workflow.

## Layout

```text
<stack>-compose/
  compose.yaml       tracked service definition
  .env.example       tracked placeholder template when stack needs secrets
  .env               NAS-only secret values; ignored by Git
shell/
  bootstrap-nas.sh   one-time Synology deployment-user setup
  deploy.sh          GitHub Actions upload client
  nas-deploy.sh      NAS-side validate/promote/apply/rollback script
  test-nas-deploy.sh deployment script self-check
```

Each Compose file declares `name:`. Do not change it after deployment: Docker uses it to identify existing containers and the workflow depends on it to avoid creating duplicate projects.

## Secrets

Secrets remain on the NAS. They are never committed, uploaded by Actions, printed by the scripts, or copied into the deployment archive.

For a new secret-bearing stack:

1. Commit `<stack>/.env.example` with harmless placeholder values.
2. Create `/volume2/docker/projects/<stack>/.env` on the NAS from that template.
3. Set `.env` to owner `covertbert:users` and mode `0640`.
4. Push the Compose definition only.

`tmdb-radarr-compose/.env` requires `TMDB_API_KEY` and `RADARR_API_KEY`.

## One-time deployment setup

The NAS is configured with a dedicated `synodeploy` account. DSM requires SSH accounts to be administrators. Docker access is root-equivalent, so this account is reserved for CI, uses a separate SSH key, and has passwordless sudo for `/usr/local/bin/docker` only.

Generate its key locally:

```bash
ssh-keygen -t ed25519 -C synology-deploy-ci -f ~/.ssh/synology-deploy-ci -N ''
```

Bootstrap the NAS. The first command uploads the script without consuming the password prompt; the second allocates a terminal for sudo:

```bash
ssh nas 'cat > /tmp/bootstrap-nas.sh' < shell/bootstrap-nas.sh
ssh -t nas "sudo env PUBKEY='$(cat ~/.ssh/synology-deploy-ci.pub)' /usr/bin/bash /tmp/bootstrap-nas.sh"
ssh nas 'rm -f /tmp/bootstrap-nas.sh'
```

The script is idempotent. It creates or updates `synodeploy`, installs the restricted CI key, configures Docker sudo access, and changes managed stack directories to group-writable and `.env` files to group-readable.

GitHub repository secrets required by the workflow:

| Secret | Value |
| --- | --- |
| `NAS_SSH_PRIVATE_KEY` | contents of `~/.ssh/synology-deploy-ci` |
| `TS_OAUTH_CLIENT_ID` | dedicated Tailscale OAuth client ID |
| `TS_OAUTH_SECRET` | dedicated Tailscale OAuth client secret |

Create the Tailscale client at [Trust credentials](https://console.tailscale.com/admin/settings/trust-credentials): select **Credential**, **OAuth**, enable **Auth keys: Write**, and assign `tag:ci`. The tailnet policy must permit `tag:ci` to SSH to the NAS. Current policy allows this already.

```bash
gh secret set NAS_SSH_PRIVATE_KEY --repo covertbert/synology-docker < ~/.ssh/synology-deploy-ci
gh secret set TS_OAUTH_CLIENT_ID --repo covertbert/synology-docker
gh secret set TS_OAUTH_SECRET --repo covertbert/synology-docker
```

## Deployment lifecycle

1. Pull requests run Compose and shell validation only. They cannot deploy or access deployment secrets.
2. A push to `main` runs the same validation.
3. GitHub Actions joins the tailnet as ephemeral `tag:ci`, verifies NAS connectivity, and uses pinned-host-key SSH as `synodeploy`.
4. Actions archives only tracked `*-compose/compose.yaml` files.
5. NAS validates candidates using its local `.env` files.
6. Changed Compose files are backed up, promoted, then applied with:

   ```bash
   docker compose up -d --remove-orphans --wait --wait-timeout 120
   ```

7. Apply failure restores prior Compose definitions and re-applies them. A revision marker advances only after full success.

Deployments do not pull images. Watchtower owns updates for current image tags.

Run a reconciliation manually from GitHub: **Actions → main → Run workflow**. It uploads current tracked definitions; unchanged stacks are not re-applied.

## Local validation

Docker Compose must be installed locally.

```bash
for file in *-compose/compose.yaml; do
  dir="${file%/compose.yaml}"
  if [ -f "$dir/.env.example" ]; then
    docker compose --project-directory "$dir" --env-file "$dir/.env.example" -f "$file" config -q
  else
    docker compose --project-directory "$dir" -f "$file" config -q
  fi
done

bash -n shell/*.sh
shellcheck shell/*.sh
shell/test-nas-deploy.sh
```

## Routine operations

Inspect deployed projects:

```bash
ssh -i ~/.ssh/synology-deploy-ci synodeploy@synologynas.mole-anaconda.ts.net \
  'sudo -n /usr/local/bin/docker compose ls'
```

Inspect one stack:

```bash
ssh nas 'cd /volume2/docker/projects/arrs-compose && sudo /usr/local/bin/docker compose ps'
```

Deploy normally by committing and pushing to `main`:

```bash
git push
```

## Adding a stack

1. Create `<name>-compose/compose.yaml` with a unique top-level `name: <name>`.
2. Keep runtime data outside the repository.
3. Add `.env.example` if interpolation needs secrets; add NAS `.env` before the first deploy.
4. Create the NAS directory at `/volume2/docker/projects/<name>-compose` before deployment. The deploy script deliberately refuses to create unmanaged stack directories.
5. Validate locally, commit, and push.

## Removing a stack

Deletion is intentionally not automated. Remove it manually after confirming data retention requirements:

```bash
ssh nas 'cd /volume2/docker/projects/<name>-compose && sudo /usr/local/bin/docker compose down'
```

Then remove its NAS directory and `.env` if appropriate, followed by its repository directory. This protects containers, volumes, and secrets from accidental deletion caused by a Git change.

## Rollback

Revert the bad commit and push `main`. The workflow promotes the prior tracked Compose files and applies them.

For an urgent NAS-only rollback:

```bash
ssh nas 'cd /volume2/docker/projects/<stack>-compose && sudo /usr/local/bin/docker compose up -d --remove-orphans --wait --wait-timeout 120'
```

The NAS deployment state is under `/volume2/docker/projects/.deploy`. Do not manually modify it during an active deployment.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Tailscale step cannot reach NAS | Tailscale policy must allow `tag:ci` to NAS port 22. |
| SSH host-key error | NAS SSH host key changed; verify it out of band before changing workflow value. |
| `sudo` password prompt in CI | Re-run bootstrap and verify `sudo -l -U synodeploy` on NAS. |
| Missing variable during deployment | Create or correct NAS-local `.env`; do not add secret to GitHub. |
| Compose apply times out | Review `docker compose ps` and service logs on NAS. Prior Compose file is restored on workflow failure. |
| Existing containers appear as a new project | Restore matching top-level `name:` value. |
| Whisparr changed | It should not: it lives outside managed deployment root. Investigate manually. |

## Security boundaries

- Repository is public. Never commit secrets, private keys, `.env`, or NAS state.
- GitHub Actions has read-only repository permission. Deployment authority comes only from repository secrets.
- Tailscale runners are ephemeral and tagged `tag:ci`.
- SSH uses a dedicated key, a pinned NAS Ed25519 host key, `BatchMode`, and strict host-key checking.
- NAS has no GitHub credential and does not fetch this repository.
- Docker control is root-equivalent. Restrict access to `synodeploy` and rotate its SSH key by replacing `~synodeploy/.ssh/authorized_keys` and `NAS_SSH_PRIVATE_KEY` together.
