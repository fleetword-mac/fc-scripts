#!/usr/bin/env bash

set -euo pipefail

trap 'echo "Error: setup failed near line $LINENO." >&2' ERR

export PATH="$PATH:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_HOME="$(getent passwd root | cut -d: -f6)"
GENERATED_KEY_DIR=""
GENERATED_PRIVATE_KEY=""
GENERATED_PUBLIC_KEY=""
GENERATED_KEY_ARCHIVE=""
KEY_INSTALL_TARGETS=()
INSTALLED_ITEMS=()

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_PROMPT=$'\033[1;36m'
  C_CHOICE=$'\033[1;33m'
  C_VALUE=$'\033[1;32m'
  C_WARN=$'\033[1;31m'
  C_INFO=$'\033[1;34m'
else
  C_RESET=''
  C_PROMPT=''
  C_CHOICE=''
  C_VALUE=''
  C_WARN=''
  C_INFO=''
fi

info() {
  printf '%s%s%s\n' "$C_INFO" "$1" "$C_RESET"
}

warn() {
  printf '%s%s%s\n' "$C_WARN" "$1" "$C_RESET" >&2
}

selected() {
  printf '%s%s%s\n' "$C_VALUE" "$1" "$C_RESET"
}

prompt_line() {
  local text="$1"
  printf '%s%s%s' "$C_PROMPT" "$text" "$C_RESET"
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-Y}"
  local reply

  while true; do
    prompt_line "${prompt%: } ${C_CHOICE}[Y/n]${C_RESET} ${C_CHOICE}(default: ${default})${C_RESET}: "
    read -r reply
    reply="${reply:-$default}"

    case "$reply" in
      Y|y|N|n)
        if [[ "$reply" =~ ^[Yy]$ ]]; then
          return 0
        fi
        return 1
        ;;
      *)
        warn "Please enter Y or N."
        ;;
    esac
  done
}

prompt_ssh_auth_mode() {
  local mode_choice

  while true; do
    echo "1. Password"
    echo "2. SSH Key"
    echo "3. Both"
    prompt_line "Choose SSH authentication mode ${C_CHOICE}[1/2/3]${C_RESET} ${C_CHOICE}(default: 2)${C_RESET}: "
    read -r mode_choice
    mode_choice="${mode_choice:-2}"

    case "$mode_choice" in
      1)
        echo "password"
        return 0
        ;;
      2)
        echo "key"
        return 0
        ;;
      3)
        echo "both"
        return 0
        ;;
      *)
        warn "Please enter 1, 2, or 3."
        ;;
    esac
  done
}

prompt_key_setup_mode() {
  local key_choice

  while true; do
    echo "1. Use existing public key"
    echo "2. Generate a temporary keypair on this server"
    prompt_line "Choose key setup mode ${C_CHOICE}[1/2]${C_RESET} ${C_CHOICE}(default: 1)${C_RESET}: "
    read -r key_choice
    key_choice="${key_choice:-1}"

    case "$key_choice" in
      1|2)
        echo "$key_choice"
        return 0
        ;;
      *)
        warn "Please choose 1 or 2."
        ;;
    esac
  done
}

prompt_input() {
  local prompt="$1"
  local reply
  prompt_line "$prompt"
  read -r reply
  printf '%s' "$reply"
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
  output_dir="$ROOT_HOME/generated-keys/${server_label}-${timestamp}"
  private_key="$output_dir/id_ed25519"
  public_key="${private_key}.pub"
  archive_file="$ROOT_HOME/generated-keys.tar.gz"
  archive_entry="generated-keys/${server_label}-${timestamp}"

  mkdir -p "$output_dir"
  ssh-keygen -t ed25519 -N "" -C "${target_user}@${server_label}" -f "$private_key" >/dev/null

  GENERATED_KEY_DIR="$output_dir"
  GENERATED_PRIVATE_KEY="$private_key"
  GENERATED_PUBLIC_KEY="$public_key"
  GENERATED_KEY_ARCHIVE="$archive_file"

  rm -f "$archive_file"
  tar -czf "$archive_file" -C "$ROOT_HOME" "$archive_entry"
  rm -rf "$output_dir"

  printf '\n%sTemporary SSH keypair generated on this server:%s\n' "$C_INFO" "$C_RESET" >&2
  printf '%sArchive:%s %s\n' "$C_INFO" "$C_RESET" "$archive_file" >&2
  printf '%sDownload this archive, extract it locally, and remove it from the VPS after verification.%s\n\n' "$C_INFO" "$C_RESET" >&2

  tar -xOf "$archive_file" "${archive_entry}/id_ed25519.pub"
}

echo "=========================================="
printf '%sFINAL CONCEPT VPS BOOTSTRAP%s\n' "$C_INFO" "$C_RESET"
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
  warn "Please run as root."
  exit 1
fi

if ! command -v apt >/dev/null 2>&1; then
  warn "This script currently supports Debian/Ubuntu only."
  exit 1
fi

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  OS="${ID:-}"
else
  warn "Unable to detect operating system."
  exit 1
fi

if [[ "$OS" != "ubuntu" && "$OS" != "debian" ]]; then
  warn "This script currently supports Debian/Ubuntu only."
  exit 1
fi

info "=== Remote Server Setup ==="

if prompt_yes_no "Run apt update && apt upgrade now? [Y/n]: " "Y"; then
  apt update
  DEBIAN_FRONTEND=noninteractive apt upgrade -y
fi

if prompt_yes_no "Install common utility packages (git, curl, wget, vim, htop, unzip)? [Y/n]: " "Y"; then
  apt install -y git curl wget vim htop unzip
  INSTALLED_ITEMS+=("Common utilities: git curl wget vim htop unzip")
fi

if prompt_yes_no "Change root password? [Y/n]: " "Y"; then
  while true; do
    read -r -s -p "Enter new root password (min 8 chars): " P1
    echo
    read -r -s -p "Confirm password: " P2
    echo

    if [[ "$P1" != "$P2" ]]; then
      warn "Passwords do not match."
    elif [[ ${#P1} -lt 8 ]]; then
      warn "Password must be at least 8 characters."
    else
      echo "root:$P1" | chpasswd
      unset P1 P2
      break
    fi
  done
fi

while true; do
  TZ="$(prompt_input "Set timezone ${C_CHOICE}[Enter for Asia/Manila]${C_RESET}: ")"
  TZ="${TZ:-Asia/Manila}"
  if timedatectl set-timezone "$TZ" >/dev/null 2>&1; then
    selected "Timezone set to $TZ"
    break
  fi
  warn "Invalid timezone. Try values like Asia/Manila or America/Los_Angeles."
done

SSH_AUTH_MODE="$(prompt_ssh_auth_mode)"
selected "SSH authentication mode: $SSH_AUTH_MODE"

CREATE_USER="N"
USERNAME=""
ADD_SUDO="N"

echo "Using a non-root user is strongly recommended for security."
if prompt_yes_no "Create non-root user? [Y/n]: " "Y"; then
  CREATE_USER="Y"

  while true; do
    read -r -p "Username: " USERNAME

    if [[ -z "$USERNAME" ]]; then
      warn "Username cannot be empty."
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
      INSTALLED_ITEMS+=("sudo")
    fi
    usermod -aG sudo "$USERNAME"
  fi
fi

TARGET_USER="root"
if [[ "$CREATE_USER" == "Y" ]]; then
  TARGET_USER="$USERNAME"
fi

DISABLE_ROOT="N"
if [[ "$CREATE_USER" == "Y" ]]; then
  if prompt_yes_no "Disable root SSH login? [Y/n]: " "Y"; then
    DISABLE_ROOT="Y"
  fi
else
  info "No non-root user exists. Root SSH login will remain enabled."
fi

if [[ "$SSH_AUTH_MODE" == "key" || "$SSH_AUTH_MODE" == "both" ]]; then
  if [[ "$CREATE_USER" == "Y" ]]; then
    KEY_INSTALL_TARGETS+=("$USERNAME")
  fi
  if [[ "$CREATE_USER" != "Y" || "$DISABLE_ROOT" != "Y" ]]; then
    KEY_INSTALL_TARGETS+=("root")
  fi

  info "SSH key setup is required for the selected auth mode."

  while true; do
    KEY_MODE="$(prompt_key_setup_mode)"

    if [[ "$KEY_MODE" == "1" ]]; then
      info "Paste SSH public key:"
      read -r PUBKEY
      if [[ -z "$PUBKEY" || ! "$PUBKEY" =~ ^ssh- ]]; then
        warn "Invalid SSH public key."
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
    fi
  done
fi

SSH_PORT=22
if prompt_yes_no "Change SSH port? [y/N]: " "N"; then
  while true; do
    PORT="$(prompt_input "Enter new SSH port ${C_CHOICE}[1024-65535]${C_RESET}: ")"
    if [[ "$PORT" =~ ^[0-9]+$ ]] && [[ "$PORT" -ge 1024 ]] && [[ "$PORT" -le 65535 ]]; then
      SSH_PORT="$PORT"
      break
    fi
    warn "Invalid port. Must be 1024-65535."
  done
fi

DISABLE_IPV6="Y"
if prompt_yes_no "Disable IPv6 for SSH? [Y/n]: " "Y"; then
  DISABLE_IPV6="Y"
else
  DISABLE_IPV6="N"
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
  INSTALLED_ITEMS+=("ufw")
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
selected "UFW configured."

if command -v docker >/dev/null 2>&1; then
  info "Docker already installed."
else
  if prompt_yes_no "Install Docker? [Y/n]: " "Y"; then
    apt install -y ca-certificates curl gnupg
    INSTALLED_ITEMS+=("Docker prerequisites: ca-certificates curl gnupg")
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
    INSTALLED_ITEMS+=("Docker: docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin")

    if [[ "$CREATE_USER" == "Y" ]]; then
      usermod -aG docker "$USERNAME"
    fi
  fi
fi

if command -v docker >/dev/null 2>&1; then
  selected "Docker version: $(docker --version)"
  if docker compose version >/dev/null 2>&1; then
    selected "Docker Compose plugin: $(docker compose version --short)"
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
if [[ "${#INSTALLED_ITEMS[@]}" -gt 0 ]]; then
  echo ""
  echo "INSTALLED DURING THIS RUN:"
  for item in "${INSTALLED_ITEMS[@]}"; do
    echo "- $item"
  done
fi
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
if [[ -n "$GENERATED_KEY_ARCHIVE" ]]; then
  echo "- Download archive: scp -P YOUR_PORT root@YOUR_SERVER_IP:$GENERATED_KEY_ARCHIVE ."
  echo "- Delete archive after verification: rm $GENERATED_KEY_ARCHIVE"
fi
echo "================================="
