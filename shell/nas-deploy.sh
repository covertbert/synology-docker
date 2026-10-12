#!/usr/bin/env bash
# Runs on the NAS as synodeploy. Payload contains tracked stack definitions only.
set -Eeuo pipefail

revision="${1:?revision required}"
payload="${2:?payload required}"
root="${DEPLOY_ROOT:-/volume2/docker/projects}"
state="${DEPLOY_STATE:-$root/.deploy}"
docker="${DOCKER:-/usr/local/bin/docker}"
sudo="${SUDO:-/usr/bin/sudo}"
flock_bin="${FLOCK:-flock}"

mkdir -p "$state"
exec 9>"$state/deploy.lock"
"$flock_bin" -n 9 || { echo 'error: another deployment is running' >&2; exit 1; }

stage="$(mktemp -d "$state/stage.XXXXXX")"
backup="$(mktemp -d "$state/backup.XXXXXX")"
declare -a changed=()

cleanup() {
  rm -rf "$stage" "$backup" "$payload"
}
rollback() {
  local stack
  echo 'apply failed; restoring previous Compose files' >&2
  for ((i=${#changed[@]} - 1; i >= 0; i--)); do
    stack="${changed[i]}"
    cp "$backup/$stack/compose.yaml" "$root/$stack/compose.yaml"
    "$sudo" -n "$docker" compose --project-directory "$root/$stack" -f "$root/$stack/compose.yaml" up -d --remove-orphans --wait --wait-timeout 120 || true
  done
}
trap cleanup EXIT

files=()
while IFS= read -r file; do files+=("$file"); done < <(tar -tzf "$payload")
((${#files[@]})) || { echo 'error: empty deployment payload' >&2; exit 1; }
for file in "${files[@]}"; do
  [[ "$file" =~ ^[a-z0-9][a-z0-9-]*-compose/(compose\.yaml|\.env\.example)$ ]] || {
    echo "error: unexpected payload path: $file" >&2
    exit 1
  }
done

tar -xzf "$payload" -C "$stage" --no-same-owner --no-same-permissions
stacks=()
while IFS= read -r stack; do stacks+=("$stack"); done < <(find "$stage" -mindepth 2 -maxdepth 2 -type f -name compose.yaml -print | sed "s#^$stage/##; s#/compose.yaml##" | sort)
((${#stacks[@]})) || { echo 'error: payload has no Compose files' >&2; exit 1; }

for stack in "${stacks[@]}"; do
  live="$root/$stack"
  candidate="$stage/$stack/compose.yaml"
  [ -d "$live" ] || { echo "error: refusing to create unmanaged stack: $stack" >&2; exit 1; }
  if [ -f "$live/.env" ]; then
    "$sudo" -n "$docker" compose --project-directory "$live" --env-file "$live/.env" -f "$candidate" config -q
  else
    "$sudo" -n "$docker" compose --project-directory "$live" -f "$candidate" config -q
  fi
done

for stack in "${stacks[@]}"; do
  live="$root/$stack"
  candidate="$stage/$stack/compose.yaml"
  cmp -s "$candidate" "$live/compose.yaml" && continue
  mkdir -p "$backup/$stack"
  cp "$live/compose.yaml" "$backup/$stack/compose.yaml"
  cp "$candidate" "$live/compose.yaml"
  changed+=("$stack")
done

if ((${#changed[@]})); then
  trap 'rollback; exit 1' ERR
  for stack in "${changed[@]}"; do
    "$sudo" -n "$docker" compose --project-directory "$root/$stack" -f "$root/$stack/compose.yaml" up -d --remove-orphans --wait --wait-timeout 120
  done
  trap - ERR
  printf 'updated: %s\n' "${changed[*]}"
else
  echo 'no Compose changes'
fi

printf '%s\n' "$revision" > "$state/revision"
echo "deploy OK: $revision"
