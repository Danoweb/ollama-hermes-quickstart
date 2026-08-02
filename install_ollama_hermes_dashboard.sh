#!/usr/bin/env bash
#
# Fresh Ubuntu deployment: Ollama + local model + Hermes Agent + Hermes Web Dashboard
#
# This script intentionally does NOT configure UFW, iptables, Nginx, TLS,
# DNS, or Nginx Proxy Manager. It only installs and starts the application stack.
#
# Run as a normal user with sudo access:
#   chmod +x install_ollama_hermes_dashboard.sh
#   ./install_ollama_hermes_dashboard.sh
#
# Optional environment overrides:
#   OLLAMA_MODEL=qwen3.5:9b
#   CONTEXT_LENGTH=65536
#   DASHBOARD_HOST=0.0.0.0        # use 127.0.0.1 when Nginx is on this same VM
#   DASHBOARD_PORT=9119
#   DASHBOARD_USERNAME=admin
#   HERMES_BRANCH=main
#   RECREATE_HERMES_VENV=0        # set to 1 to rebuild the Hermes venv
#   RESET_HERMES_REPO=1           # managed checkout; reset tracked changes on redeploy
#   UPDATE_OLLAMA=1               # set to 0 to keep an existing Ollama install
#   HERMES_DASHBOARD_PASSWORD=... # optional; otherwise securely prompted
#

set -Eeuo pipefail
IFS=$'\n\t'

# Prevent inherited Python settings from interfering with the managed venv.
unset PYTHONPATH 2>/dev/null || true
unset PYTHONHOME 2>/dev/null || true
export UV_NO_CONFIG=1

# -----------------------------------------------------------------------------
# User-configurable defaults
# -----------------------------------------------------------------------------
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen3.5:9b}"
CONTEXT_LENGTH="${CONTEXT_LENGTH:-65536}"
OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:--1}"
DASHBOARD_HOST="${DASHBOARD_HOST:-0.0.0.0}"
DASHBOARD_PORT="${DASHBOARD_PORT:-9119}"
DASHBOARD_USERNAME="${DASHBOARD_USERNAME:-admin}"
HERMES_BRANCH="${HERMES_BRANCH:-main}"
RECREATE_HERMES_VENV="${RECREATE_HERMES_VENV:-0}"
RESET_HERMES_REPO="${RESET_HERMES_REPO:-1}"
UPDATE_OLLAMA="${UPDATE_OLLAMA:-1}"

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
HERMES_DIR="${HERMES_DIR:-$HERMES_HOME/hermes-agent}"
HERMES_VENV="$HERMES_DIR/venv"
HERMES_UV="$HERMES_HOME/bin/uv"
HERMES_NODE_DIR="$HERMES_HOME/node"
HERMES_ENV_FILE="$HERMES_HOME/.env"
HERMES_CONFIG_FILE="$HERMES_HOME/config.yaml"
HERMES_COMMAND="$HOME/.local/bin/hermes"
SYSTEMD_SERVICE="hermes-dashboard.service"

TOTAL_STAGES=13
CURRENT_STAGE=0
TEMP_DIR=""
SUDO_KEEPALIVE_PID=""

# -----------------------------------------------------------------------------
# Terminal output helpers
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_BLUE='\033[0;34m'
  C_GREEN='\033[0;32m'
  C_YELLOW='\033[1;33m'
  C_RED='\033[0;31m'
  C_BOLD='\033[1m'
  C_RESET='\033[0m'
else
  C_BLUE=''
  C_GREEN=''
  C_YELLOW=''
  C_RED=''
  C_BOLD=''
  C_RESET=''
fi

stage() {
  CURRENT_STAGE=$((CURRENT_STAGE + 1))
  printf '\n%b[%02d/%02d] %s%b\n' "$C_BLUE$C_BOLD" "$CURRENT_STAGE" "$TOTAL_STAGES" "$1" "$C_RESET"
}

info()    { printf '%b  -> %s%b\n' "$C_BLUE" "$*" "$C_RESET"; }
success() { printf '%b  OK %s%b\n' "$C_GREEN" "$*" "$C_RESET"; }
warn()    { printf '%b  !! %s%b\n' "$C_YELLOW" "$*" "$C_RESET"; }
die()     { printf '%b  ERROR: %s%b\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }

cleanup() {
  local rc=$?
  if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
  return "$rc"
}

on_error() {
  local rc=$?
  local line=${BASH_LINENO[0]:-unknown}
  printf '\n%bDeployment failed at line %s with exit code %s.%b\n' "$C_RED$C_BOLD" "$line" "$rc" "$C_RESET" >&2
  printf 'Review the output above. For service logs, run:\n' >&2
  printf '  sudo journalctl -u ollama -n 100 --no-pager\n' >&2
  printf '  sudo journalctl -u %s -n 100 --no-pager\n' "$SYSTEMD_SERVICE" >&2
  exit "$rc"
}

trap cleanup EXIT
trap on_error ERR

printf '%b\n' "$C_BOLD"
printf '============================================================\n'
printf ' Ollama + Hermes Agent + Web Dashboard Deployment\n'
printf '============================================================\n'
printf '%b' "$C_RESET"
printf 'Model:             %s\n' "$OLLAMA_MODEL"
printf 'Context length:    %s tokens\n' "$CONTEXT_LENGTH"
printf 'Dashboard bind:    %s:%s\n' "$DASHBOARD_HOST" "$DASHBOARD_PORT"
printf 'Hermes directory:  %s\n' "$HERMES_DIR"
printf 'Linux user:        %s\n' "$(id -un)"

# -----------------------------------------------------------------------------
# Stage 1: Validate host and input
# -----------------------------------------------------------------------------
stage "Validating Ubuntu host and deployment settings"

[[ "$(id -u)" -ne 0 ]] || die "Run this script as a normal user, not as root. It will use sudo when needed."
command -v sudo >/dev/null 2>&1 || die "sudo is required."
[[ -r /etc/os-release ]] || die "Cannot identify the operating system."

# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "This deployment script supports Ubuntu only. Detected: ${PRETTY_NAME:-unknown}."

[[ "$CONTEXT_LENGTH" =~ ^[0-9]+$ ]] || die "CONTEXT_LENGTH must be an integer."
(( CONTEXT_LENGTH >= 64000 )) || die "Hermes Agent requires a context length of at least 64000 tokens."
[[ "$DASHBOARD_PORT" =~ ^[0-9]+$ ]] || die "DASHBOARD_PORT must be an integer."
(( DASHBOARD_PORT >= 1 && DASHBOARD_PORT <= 65535 )) || die "DASHBOARD_PORT must be between 1 and 65535."
[[ -n "$OLLAMA_MODEL" ]] || die "OLLAMA_MODEL cannot be empty."
[[ -n "$DASHBOARD_USERNAME" ]] || die "DASHBOARD_USERNAME cannot be empty."

info "Detected ${PRETTY_NAME}."
info "Requesting sudo authorization..."
sudo -v

# Keep the sudo ticket alive during long model downloads.
(
  while true; do
    sudo -n true 2>/dev/null || exit 0
    sleep 50
  done
) &
SUDO_KEEPALIVE_PID=$!

TEMP_DIR="$(mktemp -d)"
success "Host validation complete."

# -----------------------------------------------------------------------------
# Stage 2: Install Ubuntu prerequisites
# -----------------------------------------------------------------------------
stage "Installing Ubuntu prerequisites"

info "Refreshing APT package indexes..."
sudo env DEBIAN_FRONTEND=noninteractive apt-get update

info "Installing build tools, Git, curl, jq, OpenSSL, zstd, and supporting packages..."
sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y \
  ca-certificates \
  curl \
  git \
  jq \
  openssl \
  zstd \
  xz-utils \
  tar \
  build-essential \
  python3-dev \
  libffi-dev \
  pkg-config \
  ripgrep \
  pciutils

success "Ubuntu prerequisites installed."

# -----------------------------------------------------------------------------
# Stage 3: Install or update Ollama
# -----------------------------------------------------------------------------
stage "Installing Ollama"

if command -v ollama >/dev/null 2>&1 && [[ "$UPDATE_OLLAMA" != "1" ]]; then
  info "Existing Ollama installation found; UPDATE_OLLAMA=0, so the installer will not update it."
else
  info "Downloading the official Ollama Linux installer..."
  curl -fsSL https://ollama.com/install.sh -o "$TEMP_DIR/ollama-install.sh"
  chmod 700 "$TEMP_DIR/ollama-install.sh"

  info "Running the Ollama installer. This may take several minutes..."
  sh "$TEMP_DIR/ollama-install.sh"
fi

command -v ollama >/dev/null 2>&1 || die "Ollama was not installed successfully."
success "Ollama is installed: $(ollama --version 2>&1 | head -n 1)"

# -----------------------------------------------------------------------------
# Stage 4: Configure and start Ollama
# -----------------------------------------------------------------------------
stage "Configuring Ollama for Hermes"

info "Writing the Ollama systemd override..."
sudo install -d -m 0755 /etc/systemd/system/ollama.service.d
cat > "$TEMP_DIR/ollama-override.conf" <<EOF
[Service]
Environment="OLLAMA_HOST=127.0.0.1:11434"
Environment="OLLAMA_CONTEXT_LENGTH=$CONTEXT_LENGTH"
Environment="OLLAMA_KEEP_ALIVE=$OLLAMA_KEEP_ALIVE"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_NUM_PARALLEL=1"
EOF
sudo install -m 0644 "$TEMP_DIR/ollama-override.conf" /etc/systemd/system/ollama.service.d/override.conf

info "Reloading systemd and starting Ollama..."
sudo systemctl daemon-reload
sudo systemctl enable --now ollama
sudo systemctl restart ollama

info "Waiting for the Ollama API to become ready..."
OLLAMA_READY=0
for attempt in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    OLLAMA_READY=1
    break
  fi
  if (( attempt % 5 == 0 )); then
    info "Ollama is still starting... $((attempt * 2)) seconds elapsed."
  fi
  sleep 2
done
[[ "$OLLAMA_READY" == "1" ]] || die "Ollama did not become ready within 120 seconds."

success "Ollama is listening privately on 127.0.0.1:11434."

# -----------------------------------------------------------------------------
# Stage 5: Pull the local model
# -----------------------------------------------------------------------------
stage "Downloading the Ollama model"

info "Pulling model '$OLLAMA_MODEL'. Download time depends on model size and network speed."
ollama pull "$OLLAMA_MODEL"

if ! ollama list | awk 'NR > 1 {print $1}' | grep -Fxq "$OLLAMA_MODEL"; then
  warn "The model name did not exactly match the first column of 'ollama list'; showing installed models for review."
  ollama list
else
  success "Model '$OLLAMA_MODEL' is installed."
fi

# -----------------------------------------------------------------------------
# Stage 6: Install uv and make Hermes tools available on PATH
# -----------------------------------------------------------------------------
stage "Installing uv and configuring the user PATH"

mkdir -p "$HERMES_HOME/bin" "$HOME/.local/bin"

if [[ ! -x "$HERMES_UV" ]]; then
  info "Downloading the official uv installer..."
  curl -LsSf https://astral.sh/uv/install.sh -o "$TEMP_DIR/uv-install.sh"
  chmod 700 "$TEMP_DIR/uv-install.sh"

  info "Installing uv into $HERMES_HOME/bin..."
  UV_UNMANAGED_INSTALL="$HERMES_HOME/bin" sh "$TEMP_DIR/uv-install.sh"
else
  info "Existing Hermes-managed uv installation found."
fi

[[ -x "$HERMES_UV" ]] || die "uv was not installed at $HERMES_UV."

PATH_EXPORT='export PATH="$HOME/.hermes/bin:$HOME/.hermes/node/bin:$HOME/.local/bin:$PATH"'
for shell_file in "$HOME/.bashrc" "$HOME/.profile"; do
  touch "$shell_file"
  if ! grep -Fqx "$PATH_EXPORT" "$shell_file"; then
    {
      printf '\n# Ollama/Hermes local-agent tools\n'
      printf '%s\n' "$PATH_EXPORT"
    } >> "$shell_file"
    info "Added Hermes, uv, Node.js, and local user binaries to $shell_file."
  else
    info "PATH entry already exists in $shell_file."
  fi
done

export PATH="$HERMES_HOME/bin:$HERMES_NODE_DIR/bin:$HOME/.local/bin:$PATH"
success "uv is available: $(uv --version)"

# -----------------------------------------------------------------------------
# Stage 7: Install a user-managed Node.js 22 runtime
# -----------------------------------------------------------------------------
stage "Installing Node.js 22 for the Hermes dashboard frontend"

NODE_OK=0
if [[ -x "$HERMES_NODE_DIR/bin/node" ]]; then
  NODE_MAJOR="$($HERMES_NODE_DIR/bin/node --version | sed -E 's/^v([0-9]+).*/\1/')"
  if [[ "$NODE_MAJOR" == "22" ]]; then
    NODE_OK=1
    info "Existing managed Node.js $($HERMES_NODE_DIR/bin/node --version) found."
  fi
fi

if [[ "$NODE_OK" != "1" ]]; then
  case "$(uname -m)" in
    x86_64) NODE_ARCH="x64" ;;
    aarch64|arm64) NODE_ARCH="arm64" ;;
    *) die "Unsupported architecture for the managed Node.js installation: $(uname -m)" ;;
  esac

  NODE_INDEX_URL="https://nodejs.org/dist/latest-v22.x/"
  info "Resolving the latest Node.js 22 release for linux-$NODE_ARCH..."
  curl -fsSL "$NODE_INDEX_URL" -o "$TEMP_DIR/node-index.html"
  NODE_TARBALL="$(grep -oE "node-v22\.[0-9]+\.[0-9]+-linux-${NODE_ARCH}\.tar\.xz" "$TEMP_DIR/node-index.html" | head -n 1 || true)"
  [[ -n "$NODE_TARBALL" ]] || die "Could not resolve a Node.js 22 Linux tarball."

  info "Downloading $NODE_TARBALL..."
  curl -fL --progress-bar "${NODE_INDEX_URL}${NODE_TARBALL}" -o "$TEMP_DIR/$NODE_TARBALL"

  info "Installing Node.js into $HERMES_NODE_DIR..."
  rm -rf "$TEMP_DIR/node-extract"
  mkdir -p "$TEMP_DIR/node-extract"
  tar -xJf "$TEMP_DIR/$NODE_TARBALL" -C "$TEMP_DIR/node-extract" --strip-components=1
  rm -rf "$HERMES_NODE_DIR"
  mv "$TEMP_DIR/node-extract" "$HERMES_NODE_DIR"
fi

export PATH="$HERMES_NODE_DIR/bin:$PATH"
command -v node >/dev/null 2>&1 || die "Node.js is not available after installation."
command -v npm >/dev/null 2>&1 || die "npm is not available after installation."
success "Node.js $(node --version) and npm $(npm --version) are available."

# -----------------------------------------------------------------------------
# Stage 8: Download or update Hermes Agent source
# -----------------------------------------------------------------------------
stage "Downloading Hermes Agent"

mkdir -p "$HERMES_HOME"

if [[ -d "$HERMES_DIR/.git" ]]; then
  info "Existing Hermes repository found at $HERMES_DIR."
  info "Fetching branch '$HERMES_BRANCH'..."
  git -C "$HERMES_DIR" fetch --prune origin

  if [[ -n "$(git -C "$HERMES_DIR" status --porcelain --untracked-files=no)" ]]; then
    if [[ "$RESET_HERMES_REPO" == "1" ]]; then
      warn "Tracked changes exist in the managed Hermes checkout; resetting them for a reproducible redeployment."
      git -C "$HERMES_DIR" reset --hard
    else
      die "The Hermes repository has tracked local changes. Set RESET_HERMES_REPO=1 or handle them manually."
    fi
  fi

  git -C "$HERMES_DIR" checkout -B "$HERMES_BRANCH" "origin/$HERMES_BRANCH"
  git -C "$HERMES_DIR" reset --hard "origin/$HERMES_BRANCH"
else
  if [[ -e "$HERMES_DIR" && -n "$(ls -A "$HERMES_DIR" 2>/dev/null || true)" ]]; then
    die "$HERMES_DIR exists and is not an empty Git repository. Move or remove it first."
  fi
  rm -rf "$HERMES_DIR"
  info "Cloning Hermes Agent branch '$HERMES_BRANCH'..."
  git clone --branch "$HERMES_BRANCH" --depth 1 \
    https://github.com/NousResearch/hermes-agent.git "$HERMES_DIR"
fi

success "Hermes Agent source is ready at $HERMES_DIR."

# -----------------------------------------------------------------------------
# Stage 9: Create the uv virtual environment
# -----------------------------------------------------------------------------
stage "Creating the Hermes Python environment with uv venv"

info "Ensuring uv-managed Python 3.11 is available..."
"$HERMES_UV" python install 3.11

if [[ "$RECREATE_HERMES_VENV" == "1" && -d "$HERMES_VENV" ]]; then
  info "RECREATE_HERMES_VENV=1; removing the existing Hermes environment."
  rm -rf "$HERMES_VENV"
fi

if [[ ! -x "$HERMES_VENV/bin/python" ]]; then
  info "Executing: uv venv $HERMES_VENV --python 3.11"
  "$HERMES_UV" venv "$HERMES_VENV" --python 3.11
else
  info "Existing Hermes virtual environment found at $HERMES_VENV."
fi

[[ -x "$HERMES_VENV/bin/python" ]] || die "Hermes virtual environment creation failed."
success "Hermes environment is ready: $($HERMES_VENV/bin/python --version)"

# -----------------------------------------------------------------------------
# Stage 10: Install Hermes and dashboard dependencies
# -----------------------------------------------------------------------------
stage "Installing Hermes Agent and Web Dashboard dependencies"

info "Installing the Hermes package with the web and PTY extras..."
info "This is one of the longer stages; dependency resolution and compilation may take several minutes."
(
  cd "$HERMES_DIR"
  VIRTUAL_ENV="$HERMES_VENV" \
  UV_PYTHON="$HERMES_VENV/bin/python" \
    "$HERMES_UV" pip install \
      --python "$HERMES_VENV/bin/python" \
      -e ".[web,pty]"
)

info "Creating the user-facing 'hermes' launcher in $HOME/.local/bin..."
cat > "$HERMES_COMMAND" <<EOF
#!/usr/bin/env bash
unset PYTHONPATH
unset PYTHONHOME
exec "$HERMES_VENV/bin/python" "$HERMES_DIR/hermes" "\$@"
EOF
chmod 0755 "$HERMES_COMMAND"

info "Synchronizing bundled Hermes skills..."
mkdir -p "$HERMES_HOME/skills"
if [[ -f "$HERMES_DIR/tools/skills_sync.py" ]]; then
  HERMES_HOME="$HERMES_HOME" "$HERMES_VENV/bin/python" "$HERMES_DIR/tools/skills_sync.py" || \
    warn "The bundled skill synchronization step returned an error; Hermes can still start, but review the output above."
else
  warn "tools/skills_sync.py was not found; skipping explicit skill synchronization."
fi

command -v hermes >/dev/null 2>&1 || die "The hermes command is not available on the current PATH."
success "Hermes Agent is installed: $(hermes --version 2>&1 | head -n 1)"

# -----------------------------------------------------------------------------
# Stage 11: Configure Hermes and dashboard authentication
# -----------------------------------------------------------------------------
stage "Configuring Hermes to use the local Ollama model"

mkdir -p "$HERMES_HOME"

info "Writing the Hermes model configuration without overwriting unrelated settings..."
HERMES_CONFIG_FILE="$HERMES_CONFIG_FILE" \
OLLAMA_MODEL="$OLLAMA_MODEL" \
CONTEXT_LENGTH="$CONTEXT_LENGTH" \
"$HERMES_VENV/bin/python" - <<'PY'
import os
from pathlib import Path

import yaml

path = Path(os.environ["HERMES_CONFIG_FILE"])
if path.exists():
    loaded = yaml.safe_load(path.read_text(encoding="utf-8"))
    config = loaded if isinstance(loaded, dict) else {}
else:
    config = {}

model = config.get("model")
if not isinstance(model, dict):
    model = {}

model.update(
    {
        "default": os.environ["OLLAMA_MODEL"],
        "provider": "custom",
        "base_url": "http://127.0.0.1:11434/v1",
        "context_length": int(os.environ["CONTEXT_LENGTH"]),
    }
)
config["model"] = model

path.parent.mkdir(parents=True, exist_ok=True)
temporary = path.with_suffix(path.suffix + ".tmp")
temporary.write_text(
    yaml.safe_dump(config, sort_keys=False, allow_unicode=True),
    encoding="utf-8",
)
temporary.replace(path)
path.chmod(0o600)
PY

info "Preparing dashboard credentials..."
DASHBOARD_PASSWORD="${HERMES_DASHBOARD_PASSWORD:-}"
if [[ -z "$DASHBOARD_PASSWORD" ]]; then
  while true; do
    read -r -s -p "Enter a password for Hermes dashboard user '$DASHBOARD_USERNAME': " DASHBOARD_PASSWORD
    printf '\n'
    if (( ${#DASHBOARD_PASSWORD} < 12 )); then
      warn "Use at least 12 characters."
      continue
    fi
    read -r -s -p "Confirm the dashboard password: " DASHBOARD_PASSWORD_CONFIRM
    printf '\n'
    if [[ "$DASHBOARD_PASSWORD" != "$DASHBOARD_PASSWORD_CONFIRM" ]]; then
      warn "Passwords did not match. Try again."
      continue
    fi
    unset DASHBOARD_PASSWORD_CONFIRM
    break
  done
elif (( ${#DASHBOARD_PASSWORD} < 12 )); then
  die "HERMES_DASHBOARD_PASSWORD must contain at least 12 characters."
fi

info "Hashing the password with Hermes's scrypt password helper..."
export _HERMES_DEPLOY_PASSWORD="$DASHBOARD_PASSWORD"
DASHBOARD_PASSWORD_HASH="$("$HERMES_VENV/bin/python" - <<'PY'
import os
from plugins.dashboard_auth.basic import hash_password

print(hash_password(os.environ["_HERMES_DEPLOY_PASSWORD"]))
PY
)"
unset _HERMES_DEPLOY_PASSWORD DASHBOARD_PASSWORD HERMES_DASHBOARD_PASSWORD || true

SESSION_SECRET=""
if [[ -f "$HERMES_ENV_FILE" ]]; then
  SESSION_SECRET="$(grep '^HERMES_DASHBOARD_BASIC_AUTH_SECRET=' "$HERMES_ENV_FILE" | tail -n 1 | cut -d= -f2- || true)"
fi
if [[ -z "$SESSION_SECRET" ]]; then
  SESSION_SECRET="$(openssl rand -base64 48 | tr -d '\n')"
fi

info "Updating $HERMES_ENV_FILE with hashed dashboard credentials..."
ENV_TEMP="$TEMP_DIR/hermes.env"
if [[ -f "$HERMES_ENV_FILE" ]]; then
  grep -vE '^(HERMES_DASHBOARD_BASIC_AUTH_USERNAME|HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH|HERMES_DASHBOARD_BASIC_AUTH_PASSWORD|HERMES_DASHBOARD_BASIC_AUTH_SECRET|HERMES_DASHBOARD_BASIC_AUTH_TTL_SECONDS|API_SERVER_ENABLED)=' \
    "$HERMES_ENV_FILE" > "$ENV_TEMP" || true
else
  : > "$ENV_TEMP"
fi

{
  printf 'HERMES_DASHBOARD_BASIC_AUTH_USERNAME=%s\n' "$DASHBOARD_USERNAME"
  printf 'HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=%s\n' "$DASHBOARD_PASSWORD_HASH"
  printf 'HERMES_DASHBOARD_BASIC_AUTH_SECRET=%s\n' "$SESSION_SECRET"
  printf 'HERMES_DASHBOARD_BASIC_AUTH_TTL_SECONDS=43200\n'
  printf 'API_SERVER_ENABLED=false\n'
} >> "$ENV_TEMP"

install -m 0600 "$ENV_TEMP" "$HERMES_ENV_FILE"
success "Hermes is configured for $OLLAMA_MODEL with a $CONTEXT_LENGTH-token context window."

# -----------------------------------------------------------------------------
# Stage 12: Install and start the dashboard systemd service
# -----------------------------------------------------------------------------
stage "Installing the Hermes dashboard systemd service"

RUN_USER="$(id -un)"
RUN_GROUP="$(id -gn)"

info "Creating /etc/systemd/system/$SYSTEMD_SERVICE..."
cat > "$TEMP_DIR/$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Hermes Agent Web Dashboard
After=network-online.target ollama.service
Wants=network-online.target
Requires=ollama.service

[Service]
Type=simple
User=$RUN_USER
Group=$RUN_GROUP
WorkingDirectory=$HOME
Environment="HOME=$HOME"
Environment="HERMES_HOME=$HERMES_HOME"
Environment="PATH=$HERMES_HOME/bin:$HERMES_NODE_DIR/bin:$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EnvironmentFile=$HERMES_ENV_FILE
ExecStart=$HERMES_VENV/bin/python -m hermes_cli.main dashboard --host $DASHBOARD_HOST --port $DASHBOARD_PORT --no-open
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
sudo install -m 0644 "$TEMP_DIR/$SYSTEMD_SERVICE" "/etc/systemd/system/$SYSTEMD_SERVICE"

info "Reloading systemd and starting the Hermes dashboard..."
sudo systemctl daemon-reload
sudo systemctl enable --now "$SYSTEMD_SERVICE"
sudo systemctl restart "$SYSTEMD_SERVICE"

success "The Hermes dashboard service has been installed and enabled at boot."

# -----------------------------------------------------------------------------
# Stage 13: Validate the complete deployment
# -----------------------------------------------------------------------------
stage "Validating the complete deployment"

info "The first dashboard launch may build the React frontend; waiting for it to become ready..."
DASHBOARD_READY=0
for attempt in $(seq 1 90); do
  if curl -fsS "http://127.0.0.1:$DASHBOARD_PORT/api/status" > "$TEMP_DIR/dashboard-status.json" 2>/dev/null; then
    DASHBOARD_READY=1
    break
  fi

  if ! sudo systemctl is-active --quiet "$SYSTEMD_SERVICE"; then
    warn "The dashboard service is not active. Recent logs follow:"
    sudo journalctl -u "$SYSTEMD_SERVICE" -n 80 --no-pager || true
    die "Hermes dashboard service stopped before becoming ready."
  fi

  if (( attempt % 5 == 0 )); then
    info "Dashboard is still starting... $((attempt * 2)) seconds elapsed."
  fi
  sleep 2
done

if [[ "$DASHBOARD_READY" != "1" ]]; then
  warn "Recent dashboard logs follow:"
  sudo journalctl -u "$SYSTEMD_SERVICE" -n 100 --no-pager || true
  die "The dashboard did not become ready within 180 seconds."
fi

AUTH_REQUIRED="$(jq -r '.auth_required // "unknown"' "$TEMP_DIR/dashboard-status.json" 2>/dev/null || echo unknown)"
AUTH_PROVIDERS="$(jq -c '.auth_providers // []' "$TEMP_DIR/dashboard-status.json" 2>/dev/null || echo '[]')"

[[ "$AUTH_REQUIRED" == "true" ]] || warn "Dashboard status did not report auth_required=true. Review the dashboard authentication configuration."
if [[ "$DASHBOARD_HOST" != "127.0.0.1" && "$DASHBOARD_HOST" != "localhost" ]]; then
  echo "$AUTH_PROVIDERS" | grep -q 'basic' || warn "The basic authentication provider was not reported by /api/status."
fi

LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

printf '\n%b============================================================%b\n' "$C_GREEN$C_BOLD" "$C_RESET"
printf '%b Deployment completed successfully%b\n' "$C_GREEN$C_BOLD" "$C_RESET"
printf '%b============================================================%b\n' "$C_GREEN$C_BOLD" "$C_RESET"
printf 'Ollama:            %s\n' "$(ollama --version 2>&1 | head -n 1)"
printf 'Model:             %s\n' "$OLLAMA_MODEL"
printf 'Hermes:            %s\n' "$(hermes --version 2>&1 | head -n 1)"
printf 'uv:                %s\n' "$(uv --version)"
printf 'Node.js:           %s\n' "$(node --version)"
printf 'Dashboard service: %s\n' "$(sudo systemctl is-active "$SYSTEMD_SERVICE")"
printf 'Auth required:     %s\n' "$AUTH_REQUIRED"
printf 'Auth providers:    %s\n' "$AUTH_PROVIDERS"
printf '\n'

if [[ "$DASHBOARD_HOST" == "127.0.0.1" || "$DASHBOARD_HOST" == "localhost" ]]; then
  printf 'Dashboard endpoint: http://127.0.0.1:%s\n' "$DASHBOARD_PORT"
  printf 'Configure a same-host Nginx reverse proxy to forward to this endpoint.\n'
else
  printf 'Dashboard endpoint: http://%s:%s\n' "${LAN_IP:-SERVER_IP}" "$DASHBOARD_PORT"
  printf 'Configure Nginx Proxy Manager to forward to this host and port.\n'
fi

printf '\nNginx Proxy Manager reminders:\n'
printf '  - Forward scheme: http\n'
printf '  - Forward port:   %s\n' "$DASHBOARD_PORT"
printf '  - Enable WebSocket support for the Hermes chat terminal\n'
printf '  - Configure TLS and your preferred proxy-level access controls\n'
printf '\nUseful commands:\n'
printf '  sudo systemctl status %s\n' "$SYSTEMD_SERVICE"
printf '  sudo journalctl -u %s -f\n' "$SYSTEMD_SERVICE"
printf '  sudo journalctl -u ollama -f\n'
printf '  ollama ps\n'
printf '  hermes doctor\n'
printf '\nOpen a new shell, or run the following now, to refresh PATH:\n'
printf '  source ~/.bashrc\n'
