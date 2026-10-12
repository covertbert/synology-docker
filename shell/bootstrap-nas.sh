#!/usr/bin/env bash
# One-time DSM bootstrap. Upload first, then run interactively:
#   ssh nas 'cat > /tmp/bootstrap-nas.sh' < shell/bootstrap-nas.sh
#   ssh -t nas "sudo env PUBKEY='$(cat ~/.ssh/synology-deploy-ci.pub)' /usr/bin/bash /tmp/bootstrap-nas.sh"
set -Eeuo pipefail

: "${PUBKEY:?PUBKEY is required}"

DEPLOY_USER=synodeploy
PROJECTS=/volume2/docker/projects
DOCKER=/usr/local/bin/docker
SUDO=/usr/bin/sudo
SUDOERS=/etc/sudoers.d/synodeploy-docker
SYNOUSER=/usr/syno/sbin/synouser
SYNOGROUP=/usr/syno/sbin/synogroup

[ "$(id -u)" -eq 0 ] || { echo 'error: run as root' >&2; exit 1; }

add_group_member() {
  local group="$1" user="$2" raw member
  local -a members=()
  raw="$(awk -F: -v group="$group" '$1 == group { print $4 }' /etc/group)"
  IFS=',' read -r -a members <<< "$raw"
  for member in "${members[@]}"; do
    [ "$member" = "$user" ] && return
  done
  members+=("$user")
  "$SYNOGROUP" --member "$group" "${members[@]}" >/dev/null
}

if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
  password="$(head -c 48 /dev/urandom | base64 | tr -d '\n')"
  "$SYNOUSER" --add "$DEPLOY_USER" "$password" 'CI deploy' 0 '' 0 >/dev/null
  echo "created user $DEPLOY_USER"
fi

# DSM permits SSH only for administrators. Docker control is root-equivalent,
# so this account remains dedicated to CI and uses an SSH key, not its password.
add_group_member administrators "$DEPLOY_USER"

home="$(awk -F: -v user="$DEPLOY_USER" '$1 == user { print $6 }' /etc/passwd)"
[ -n "$home" ] || { echo "error: no home for $DEPLOY_USER" >&2; exit 1; }
mkdir -p "$home/.ssh"
chown -R "$DEPLOY_USER:users" "$home"
chmod 700 "$home" "$home/.ssh"

case "$PUBKEY" in
  'ssh-ed25519 '*) ;;
  *) echo 'error: PUBKEY must be an Ed25519 public key' >&2; exit 1 ;;
esac

key_file="$home/.ssh/authorized_keys"
key_blob="$(awk '{ print $2 }' <<< "$PUBKEY")"
tmp="$(mktemp)"
touch "$key_file"
grep -vF "$key_blob" "$key_file" > "$tmp" || true
printf 'restrict %s\n' "$PUBKEY" >> "$tmp"
cat "$tmp" > "$key_file"
rm -f "$tmp"
chown "$DEPLOY_USER:users" "$key_file"
chmod 600 "$key_file"

cat > "$SUDOERS" <<EOF
Defaults:$DEPLOY_USER !requiretty
$DEPLOY_USER ALL=(root) NOPASSWD: $DOCKER
EOF
chown root:root "$SUDOERS"
chmod 0440 "$SUDOERS"

if ! "$SUDO" -u "$DEPLOY_USER" -- "$SUDO" -n "$DOCKER" version >/dev/null 2>&1; then
  rm -f "$SUDOERS"
  echo 'error: sudoers validation failed; rule removed' >&2
  exit 1
fi

chown covertbert:users "$PROJECTS"
chmod 775 "$PROJECTS"
for stack in "$PROJECTS"/*-compose; do
  [ -d "$stack" ] || continue
  chown -R covertbert:users "$stack"
  find "$stack" -type d -exec chmod 775 {} +
  find "$stack" -type f ! -name '.env' -exec chmod 664 {} +
  find "$stack" -type f -name '.env' -exec chmod 640 {} +
done

echo "bootstrap complete: $DEPLOY_USER"
