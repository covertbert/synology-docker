#!/usr/bin/env bash
# Runs in GitHub Actions. Sends only tracked Compose definitions to the NAS.
set -Eeuo pipefail

: "${GITHUB_SHA:?GITHUB_SHA is required}"
: "${NAS_SSH_KEY_FILE:?NAS_SSH_KEY_FILE is required}"
: "${NAS_KNOWN_HOSTS_FILE:?NAS_KNOWN_HOSTS_FILE is required}"

nas_host="${NAS_HOST:-synologynas.mole-anaconda.ts.net}"
nas_user="${NAS_USER:-synodeploy}"
remote_root="${NAS_PROJECTS_DIR:-/volume2/docker/projects}"
revision="$GITHUB_SHA"
short_revision="${revision:0:12}"
remote_state="$remote_root/.deploy"
ssh_opts=(-i "$NAS_SSH_KEY_FILE" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=15 -o UserKnownHostsFile="$NAS_KNOWN_HOSTS_FILE" -o StrictHostKeyChecking=yes)
ssh_target="$nas_user@$nas_host"

files=()
while IFS= read -r file; do files+=("$file"); done < <(git ls-files -- '*-compose/compose.yaml')
((${#files[@]})) || { echo 'error: no tracked Compose files' >&2; exit 1; }

payload="$(mktemp "${RUNNER_TEMP:-/tmp}/nas-compose.${short_revision}.XXXXXX.tgz")"
cleanup() { rm -f "$payload"; }
trap cleanup EXIT

tar -czf "$payload" "${files[@]}"

remote_payload="$remote_state/payload-$short_revision.tgz"
remote_script="$remote_state/nas-deploy-$short_revision.sh"

# shellcheck disable=SC2029 # Remote commands are deliberately quoted locally.
ssh "${ssh_opts[@]}" "$ssh_target" "$(printf 'mkdir -p %q' "$remote_state")"
# shellcheck disable=SC2029 # Remote commands are deliberately quoted locally.
ssh "${ssh_opts[@]}" "$ssh_target" "$(printf 'cat > %q' "$remote_payload")" < "$payload"
# shellcheck disable=SC2029 # Remote commands are deliberately quoted locally.
ssh "${ssh_opts[@]}" "$ssh_target" "$(printf 'cat > %q' "$remote_script")" < shell/nas-deploy.sh
remote_command="$(printf 'chmod 700 %q && DEPLOY_ROOT=%q %q %q %q' "$remote_script" "$remote_root" "$remote_script" "$revision" "$remote_payload")"
# shellcheck disable=SC2029 # The whole command is intentionally evaluated remotely.
ssh "${ssh_opts[@]}" "$ssh_target" "$remote_command"
