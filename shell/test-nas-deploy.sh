#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root="$tmp/projects"
state="$root/.deploy"
mkdir -p "$root/arrs-compose" "$root/sabnzb-compose" "$tmp/bin"
printf 'name: arrs\nservices: {}\n' > "$root/arrs-compose/compose.yaml"
printf 'name: sabnzb\nservices: {}\n' > "$root/sabnzb-compose/compose.yaml"

cat > "$tmp/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -n ] && shift
exec "$@"
EOF
cat > "$tmp/bin/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
if [[ " $* " == *' up '* ]] && [[ "${FAIL_STACK:-}" != '' && " $* " == *"/$FAIL_STACK/"* ]]; then
  exit 1
fi
EOF
chmod +x "$tmp/bin/sudo" "$tmp/bin/flock" "$tmp/bin/docker"
make_payload() {
  local label="$1" arrs="$2" sabnzb="$3"
  local stage="$tmp/$label"
  mkdir -p "$stage/arrs-compose" "$stage/sabnzb-compose"
  printf '%s\n' "$arrs" > "$stage/arrs-compose/compose.yaml"
  printf '%s\n' "$sabnzb" > "$stage/sabnzb-compose/compose.yaml"
  tar -C "$stage" -czf "$tmp/$label.tgz" arrs-compose/compose.yaml sabnzb-compose/compose.yaml
}
run() {
  DOCKER_LOG="$tmp/docker.log" DEPLOY_ROOT="$root" DEPLOY_STATE="$state" SUDO="$tmp/bin/sudo" FLOCK="$tmp/bin/flock" DOCKER="$tmp/bin/docker" "$repo_root/shell/nas-deploy.sh" "$1" "$2"
}

make_payload first $'name: arrs\nservices: {app: {image: example}}' $'name: sabnzb\nservices: {app: {image: example}}'
run first "$tmp/first.tgz"
grep -qx first "$state/revision"
grep -q ' up ' "$tmp/docker.log"

: > "$tmp/docker.log"
make_payload noop $'name: arrs\nservices: {app: {image: example}}' $'name: sabnzb\nservices: {app: {image: example}}'
run noop "$tmp/noop.tgz"
grep -qx noop "$state/revision"
if grep -q ' up ' "$tmp/docker.log"; then
  echo 'no-op deployment ran docker compose up' >&2
  exit 1
fi

old_arrs="$(cat "$root/arrs-compose/compose.yaml")"
old_sabnzb="$(cat "$root/sabnzb-compose/compose.yaml")"
make_payload failed $'name: arrs\nservices: {app: {image: changed}}' $'name: sabnzb\nservices: {app: {image: changed}}'
if FAIL_STACK=sabnzb-compose DOCKER_LOG="$tmp/docker.log" DEPLOY_ROOT="$root" DEPLOY_STATE="$state" SUDO="$tmp/bin/sudo" FLOCK="$tmp/bin/flock" DOCKER="$tmp/bin/docker" "$repo_root/shell/nas-deploy.sh" failed "$tmp/failed.tgz"; then
  echo 'expected failed deployment to fail' >&2
  exit 1
fi
[ "$(cat "$root/arrs-compose/compose.yaml")" = "$old_arrs" ]
[ "$(cat "$root/sabnzb-compose/compose.yaml")" = "$old_sabnzb" ]
grep -qx noop "$state/revision"
echo 'nas-deploy tests passed'
