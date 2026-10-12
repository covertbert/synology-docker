#!/usr/bin/env bash
# One-time NAS bootstrap that prepares a dedicated deployment account for
# GitHub Actions. Run as root on the NAS with the CI public key supplied in
# PUBKEY. Idempotent: re-running with the same or a rotated key is safe.
set -Eeuo pipefail

: "${PUBKEY:?PUBKEY is required}"

DEPLOY_USER=synodeploy
PROJECTS=/volume2/docker/projects
DOCKER=/usr/local/bin/docker
SUDOERS=/etc/sudoers.d/synodeploy-docker
SYNOUSER=/usr/syno/sbin/synouser
SYNOGROUP=/usr/syno/sbin/synogroup

if [ "$(id -u)" -ne 0 ]; then
  echo "error: run as root (ssh -t nas 'sudo bash -s' < shell/bootstrap-nas.sh)" >&2
  exit 1
fi

if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
  # Password login is never used: SSH accepts the CI key only. A random
  # password satisfies synouser without creating a usable credential.
  pw="$(head -c 48 /dev/urandom | base64 | tr -d '\n')"
  "$SYNOUSER" --add "$DEPLOY_USER" "$pw" "CI deploy" 0 >/dev/null
  echo "created user $DEPLOY_USER"
else
  echo "user $DEPLOY_USER already exists"
fi

# Membership of `users` lets the account read 0640 .env files that remain
# owned by the primary NAS account.
"$SYNOGROUP" --member users "$DEPLOY_USER" >/dev/null 2>&1 || true

home="$(awk -F: -v u="$DEPLOY_USER" '$1 == u { print $6 }' /etc/passwd)"
[ -n "$home" ] || { echo "error: no home directory recorded for $DEPLOY_USER" >&2; exit 1; }
mkdir -p "$home/.ssh"
chown -R "$DEPLOY_USER:users" "$home"
chmod 700 "$home" "$home/.ssh"

ak="$home/.ssh/authorized_keys"
touch "$ak"
chown "$DEPLOY_USER:users" "$ak"
chmod 600 "$ak"
if ! grep -qF "$PUBKEY" "$ak"; then
  printf '%s\n' "$PUBKEY" >> "$ak"
  echo "authorized CI key"
else
  echo "CI key already authorized"
fi

# Docker Compose needs the full CLI, and the Compose CLI is what performs the
# apply. Restrict to the deploy account and to the docker binary only.
umask 077
cat > "$SUDOERS" <<EOF
Defaults:$DEPLOY_USER !requiretty
$DEPLOY_USER ALL=(root) NOPASSWD: $DOCKER
EOF
chown root:root "$SUDOERS"
chmod 0440 "$SUDOERS"

# visudo is not installed on DSM; a parse failure makes sudo unusable for the
# deploy account, so remove the rule rather than risk a partial install.
if ! sudo -l -U "$DEPLOY_USER" >/dev/null 2>&1; then
  rm -f "$SUDOERS"
  echo "error: sudoers validation failed, rule removed" >&2
  exit 1
fi
echo "installed $SUDOERS"

if ! sudo -u "$DEPLOY_USER" -- "$DOCKER" version >/dev/null 2>&1; then
  echo "error: $DEPLOY_USER cannot run docker through sudo" >&2
  exit 1
fi
echo "verified docker access for $DEPLOY_USER"

# Live Compose trees are world-writable by default. Keep the primary account as
# owner, drop world write, and let the deploy account write via group.
if [ -d "$PROJECTS" ]; then
  chown -R covertbert:users "$PROJECTS"
  find "$PROJECTS" -type d -exec chmod 775 {} +
  find "$PROJECTS" -type f -name 'compose.yaml' -exec chmod 664 {} +
  find "$PROJECTS" -type f -name '.env' -exec chmod 640 {} +
  echo "hardened $PROJECTS"
fi

# Compose reads each stack's .env for interpolation, so the deploy account must
# be able to read it. Fail loudly rather than deploy silently broken config.
while IFS= read -r env_file; do
  if ! sudo -u "$DEPLOY_USER" -- test -r "$env_file"; then
    echo "error: $DEPLOY_USER cannot read $env_file" >&2
    exit 1
  fi
done < <(find "$PROJECTS" -type f -name '.env' 2>/dev/null)

echo "bootstrap complete: $DEPLOY_USER"
