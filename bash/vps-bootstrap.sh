#!/usr/bin/env bash

set -euo pipefail

trap 'echo "Error: setup failed near line $LINENO." >&2' ERR

export PATH="$PATH:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATED_KEY_DIR=""
GENERATED_PRIVATE_KEY=""
GENERATED_PUBLIC_KEY=""
GENERATED_KEY_ARCHIVE=""
KEY_INSTALL_TARGETS=()

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-Y}"
  local reply

  read -r -p "$prompt" reply
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy]$ ]]
}

prompt_ssh_auth_mode() {
  local mode

  while true; do
    read -r -p "Choose SSH authentication mode [password/key/both] (default: key): " mode
    mode="${mode:-key}"

    case "$mode" in
      password|key|both)
        echo "$mode"
        return 0
        ;;
      *)
        echo "Please enter: password, key, or both."
        ;;
    esac
  done
}

get_user_home() {
  getent passwd "$1" | cut -d: -f6
}

install_public_key() {
  local target_user="$1"
  local pubkey="$2"
  local home_dir

  home_dir="$(get_user_home "$target_user")"

  mkdir -p "$home_dir/.ssh"
  touch "$home_dir/.ssh/authorized_keys"

  grep -qxF "$pubkey" "$home_dir/.ssh/authorized_keys" || printf '%s\n' "$pubkey" >> "$home_dir/.ssh/authorized_keys"

  chmod 700 "$home_dir/.ssh"
  chmod 600 "$home_dir/.ssh/authorized_keys"
  chown -R "$target_user:$target_user" "$home_dir/.ssh"
}

generate_server_keypair() {
  local target_user="$1"
  local server_label="$2"
  local timestamp
  local output_dir
  local private_key
  local public_key
  local archive_file
  local archive_entry

  timestamp="$(date +%Y%m%d-%H%M%S)"
  output_dir="$SCRIPT_DIR/generated-keys/${server_label}-${timestamp}"
  private_key="$output_dir/id_ed25519"
  public_key="${private_key}.pub"
  archive_file="$SCRIPT_DIR/generated-keys.tar.gz"
  archive_entry="generated-keys/${server_label}-${timestamp}"

  mkdir -p "$output_dir"
  ssh-keygen -t ed25519 -N "" -C "${target_user}@${server_label}" -f "$private_key" >/dev/null

  GENERATED_KEY_DIR="$output_dir"
  GENERATED_PRIVATE_KEY="$private_key"
  GENERATED_PUBLIC_KEY="$public_key"
  GENERATED_KEY_ARCHIVE="$archive_file"

  rm -f "$archive_file"
  tar -czf "$archive_file" -C "$SCRIPT_DIR" "$archive_entry"
  rm -rf "$output_dir"

  printf '\nTemporary SSH keypair generated on this server:\n' >&2
  printf 'Archive: %s\n' "$archive_file" >&2
  printf 'Download this archive, extract it locally, and remove it from the VPS after verification.\n\n' >&2

  tar -xOf "$archive_file" "${archive_entry}/id_ed25519.pub"
}

echo "=========================================="
echo "FINAL CONCEPT VPS BOOTSTRAP"
echo ""
echo "This script is intended for first-run setup on a fresh Debian/Ubuntu VPS."
echo "It can optionally:"
echo "- update system packages"
echo "- create a non-root user"
echo "- configure SSH auth mode"
echo "- configure UFW"
echo "- install Docker"
echo ""
echo "Do not close this session until you verify SSH access works."
echo "=========================================="

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root."
  exit 1
fi

if ! command -v apt >/dev/null 2>&1; then
  echo "This script currently supports Debian/Ubuntu only."
  exit 1
fi

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  OS="${ID:-}"
else
  echo "Unable to detect operating system."
  exit 1
fi

if [[ "$OS" != "ubuntu" && "$OS" != "debian" ]]; then
  echo "This script currently supports Debian/Ubuntu only."
  exit 1
fi

echo "=== Remote Server Setup ==="

if prompt_yes_no "Run apt update && apt upgrade now? [Y/n]: " "Y"; then
  apt update
  DEBIAN_FRONTEND=noninteractive apt upgrade -y
fi

if prompt_yes_no "Install common utility packages (git, curl, wget, vim, htop, unzip)? [Y/n]: " "Y"; then
  apt install -y git curl wget vim htop unzip
fi

if prompt_yes_no "Change root password? [Y/n]: " "Y"; then
  while true; do
    read -r -s -p "Enter new root password (min 8 chars): " P1
    echo
    read -r -s -p "Confirm password: " P2
    echo

    if [[ "$P1" != "$P2" ]]; then
      echo "Passwords do not match."
    elif [[ ${#P1} -lt 8 ]]; then
      echo "Password must be at least 8 characters."
    else
      echo "root:$P1" | chpasswd
      unset P1 P2
      break
    fi
  done
fi

read -r -p "Set timezone? [Enter to use default Asia/Manila]: " TZ
TZ="${TZ:-Asia/Manila}"
timedatectl set-timezone "$TZ"
echo "Timezone set to $TZ"

SSH_AUTH_MODE="$(prompt_ssh_auth_mode)"
echo "SSH authentication mode: $SSH_AUTH_MODE"

CREATE_USER="N"
USERNAME=""
ADD_SUDO="N"

echo "Using a non-root user is strongly recommended for security."
if prompt_yes_no "Create non-root user? [Y/n]: " "Y"; then
  CREATE_USER="Y"

  while true; do
    read -r -p "Username: " USERNAME

    if [[ -z "$USERNAME" ]]; then
      echo "Username cannot be empty."
    elif id "$USERNAME" >/dev/null 2>&1; then
      if prompt_yes_no "User already exists. Reuse this user? [Y/n]: " "Y"; then
        break
      fi
    else
      adduser "$USERNAME"
      break
    fi
  done

  if prompt_yes_no "Add user to sudo group? [Y/n]: " "Y"; then
    ADD_SUDO="Y"
    if ! command -v sudo >/dev/null 2>&1; then
      apt install -y sudo
    fi
    usermod -aG sudo "$USERNAME"
  fi
fi

TARGET_USER="root"
if [[ "$CREATE_USER" == "Y" ]]; then
  TARGET_USER="$USERNAME"
fi

if [[ "$SSH_AUTH_MODE" == "key" || "$SSH_AUTH_MODE" == "both" ]]; then
  if [[ "$CREATE_USER" == "Y" ]]; then
    KEY_INSTALL_TARGETS+=("$USERNAME")
  fi
  if [[ "$CREATE_USER" != "Y" || "$DISABLE_ROOT" != "Y" ]]; then
    KEY_INSTALL_TARGETS+=("root")
  fi

  echo "SSH key setup is required for the selected auth mode."
  echo "1. Use existing public key"
  echo "2. Generate a temporary keypair on this server"

  while true; do
    read -r -p "Choose key setup mode [1/2] (default: 1): " KEY_MODE
    KEY_MODE="${KEY_MODE:-1}"

    if [[ "$KEY_MODE" == "1" ]]; then
      echo "Paste SSH public key:"
      read -r PUBKEY
      if [[ -z "$PUBKEY" || ! "$PUBKEY" =~ ^ssh- ]]; then
        echo "Invalid SSH public key."
        continue
      fi
      for KEY_TARGET in "${KEY_INSTALL_TARGETS[@]}"; do
        install_public_key "$KEY_TARGET" "$PUBKEY"
      done
      break
    elif [[ "$KEY_MODE" == "2" ]]; then
      SERVER_LABEL="$(hostname -f 2>/dev/null || hostname)"
      PUBKEY="$(generate_server_keypair "$TARGET_USER" "$SERVER_LABEL")"
      for KEY_TARGET in "${KEY_INSTALL_TARGETS[@]}"; do
        install_public_key "$KEY_TARGET" "$PUBKEY"
      done
      break
    else
      echo "Please choose 1 or 2."
    fi
  done
fi

SSH_PORT=22
if prompt_yes_no "Change SSH port? [y/N]: " "N"; then
  while true; do
    read -r -p "Enter new SSH port (1024-65535): " PORT
    if [[ "$PORT" =~ ^[0-9]+$ ]] && [[ "$PORT" -ge 1024 ]] && [[ "$PORT" -le 65535 ]]; then
      SSH_PORT="$PORT"
      break
    fi
    echo "Invalid port. Must be 1024-65535."
  done
fi

DISABLE_IPV6="Y"
if prompt_yes_no "Disable IPv6 for SSH? [Y/n]: " "Y"; then
  DISABLE_IPV6="Y"
else
  DISABLE_IPV6="N"
fi

DISABLE_ROOT="N"
if [[ "$CREATE_USER" == "Y" ]]; then
  if prompt_yes_no "Disable root SSH login? [Y/n]: " "Y"; then
    DISABLE_ROOT="Y"
  fi
else
  echo "No non-root user exists. Root SSH login will remain enabled."
fi

SSHD="/etc/ssh/sshd_config"
SSHD_INCLUDE='Include /etc/ssh/sshd_config.d/*.conf'
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSHD_DROPIN_FILE="${SSHD_DROPIN_DIR}/fc-ssh.conf"

cp "$SSHD" "$SSHD.bak.$(date +%Y%m%d-%H%M%S)"

if ! grep -Fqx "$SSHD_INCLUDE" "$SSHD"; then
  printf '\n%s\n' "$SSHD_INCLUDE" >> "$SSHD"
fi

mkdir -p "$SSHD_DROPIN_DIR"

PASSWORD_AUTH="yes"
PUBKEY_AUTH="yes"
if [[ "$SSH_AUTH_MODE" == "password" ]]; then
  PUBKEY_AUTH="no"
elif [[ "$SSH_AUTH_MODE" == "key" ]]; then
  PASSWORD_AUTH="no"
fi

ADDRESS_FAMILY="any"
if [[ "$DISABLE_IPV6" == "Y" ]]; then
  ADDRESS_FAMILY="inet"
fi

PERMIT_ROOT_LOGIN="yes"
if [[ "$DISABLE_ROOT" == "Y" ]]; then
  PERMIT_ROOT_LOGIN="no"
fi

cat > "$SSHD_DROPIN_FILE" <<EOF
Port $SSH_PORT
PubkeyAuthentication $PUBKEY_AUTH
PasswordAuthentication $PASSWORD_AUTH
PermitEmptyPasswords no
AddressFamily $ADDRESS_FAMILY
PermitRootLogin $PERMIT_ROOT_LOGIN
EOF

if command -v sshd >/dev/null 2>&1; then
  sshd -t
else
  /usr/sbin/sshd -t
fi

if ! command -v ufw >/dev/null 2>&1; then
  apt install -y ufw
fi

ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT"/tcp
if prompt_yes_no "Allow HTTP/HTTPS through UFW? [Y/n]: " "Y"; then
  ufw allow 80/tcp
  ufw allow 443/tcp
fi
if [[ "$SSH_PORT" != "22" ]]; then
  ufw deny 22/tcp
fi
ufw --force enable
echo "UFW configured."

if command -v docker >/dev/null 2>&1; then
  echo "Docker already installed."
else
  if prompt_yes_no "Install Docker? [Y/n]: " "Y"; then
    apt install -y ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings

    if [[ "$OS" == "ubuntu" ]]; then
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
      tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    else
      curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
      tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    fi

    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    if [[ "$CREATE_USER" == "Y" ]]; then
      usermod -aG docker "$USERNAME"
    fi
  fi
fi

if command -v docker >/dev/null 2>&1; then
  echo "Docker version: $(docker --version)"
  if docker compose version >/dev/null 2>&1; then
    echo "Docker Compose plugin: $(docker compose version --short)"
  fi
fi

systemctl restart ssh || systemctl restart sshd

echo "================================="
echo "Setup complete."
echo ""
echo "SSH auth mode: $SSH_AUTH_MODE"
echo "SSH port: $SSH_PORT"
echo "SSH config drop-in: $SSHD_DROPIN_FILE"
echo "Timezone: $TZ"

if [[ "$CREATE_USER" == "Y" ]]; then
  echo "Non-root user created: $USERNAME"
  if [[ "$ADD_SUDO" == "Y" ]]; then
    echo "User has sudo privileges: yes"
  else
    echo "User has sudo privileges: no"
  fi
else
  echo "No non-root user was created."
fi

if [[ "$DISABLE_ROOT" == "Y" ]]; then
  echo "Root SSH login: disabled"
else
  echo "Root SSH login: enabled"
fi

if [[ "$SSH_AUTH_MODE" == "key" || "$SSH_AUTH_MODE" == "both" ]]; then
  echo "SSH key installed for: ${KEY_INSTALL_TARGETS[*]}"
fi

if [[ -n "$GENERATED_KEY_DIR" ]]; then
  echo "Generated key archive: $GENERATED_KEY_ARCHIVE"
fi

echo ""
echo "IMPORTANT:"
echo "- Test SSH access before closing this session."
echo "- If you generated keys on the server, copy the archive off immediately and delete it from the VPS after verification."
echo "- Reboot recommended: run 'reboot'"
echo ""
echo "NEXT STEPS:"
if [[ "$CREATE_USER" == "Y" ]]; then
  echo "- Reconnect using user: $USERNAME"
else
  echo "- Reconnect using root"
fi
echo "- Confirm SSH works on port: $SSH_PORT"
if [[ "$CREATE_USER" == "Y" ]]; then
  echo "- Re-login before using Docker so new group membership applies"
fi
echo "- Inspect SSH drop-in if needed: $SSHD_DROPIN_FILE"
echo "================================="
