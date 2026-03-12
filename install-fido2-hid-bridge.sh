#!/bin/bash
# =============================================================================
# fido2-hid-bridge Installer
# Installs fido2-hid-bridge as a systemd service that starts automatically
# on boot. No Python knowledge required.
#
# Usage:
#   chmod +x install-fido2-hid-bridge.sh
#   ./install-fido2-hid-bridge.sh                        # use default pinned commit
#   ./install-fido2-hid-bridge.sh --commit <hash>        # use a specific commit
#
# To uninstall:
#   ./install-fido2-hid-bridge.sh --uninstall
# =============================================================================

set -e

# --- Config ------------------------------------------------------------------
INSTALL_DIR="/opt/fido2-hid-bridge"
SERVICE_NAME="fido2-hid-bridge"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
REPO_URL="https://github.com/BryanJacobs/fido2-hid-bridge"

# Latest verified commit on main branch (as of 2026-03-12).
# Update this value when you want to track a newer commit.
DEFAULT_COMMIT="52d0911054e74f22c4e9e726e8bc24a72cda178d"
# -----------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Argument parsing --------------------------------------------------------
COMMIT_HASH="$DEFAULT_COMMIT"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --uninstall)
            UNINSTALL=true
            shift
            ;;
        --commit)
            if [[ -z "$2" || "$2" == --* ]]; then
                error "--commit requires a commit hash argument (e.g. --commit abc1234)"
            fi
            COMMIT_HASH="$2"
            shift 2
            ;;
        --commit=*)
            COMMIT_HASH="${1#--commit=}"
            if [[ -z "$COMMIT_HASH" ]]; then
                error "--commit= requires a commit hash value"
            fi
            shift
            ;;
        *)
            error "Unknown argument: $1\nUsage: $0 [--commit <hash>] [--uninstall]"
            ;;
    esac
done

# Validate commit hash format (should be hex, 7–40 chars)
if [[ ! "$COMMIT_HASH" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    error "Invalid commit hash: '$COMMIT_HASH'. Expected a hex string (e.g. 6aa6c203 or full 40-char SHA)."
fi

# =============================================================================
# UNINSTALL
# =============================================================================
if [[ "${UNINSTALL:-false}" == "true" ]]; then
    echo ""
    echo "================================================"
    echo "  Uninstalling fido2-hid-bridge"
    echo "================================================"
    echo ""

    if ! command -v sudo &>/dev/null; then
        error "sudo is required for uninstallation."
    fi

    info "Stopping and disabling service..."
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true

    info "Removing service file..."
    sudo rm -f "$SERVICE_FILE"
    sudo systemctl daemon-reload

    info "Removing installation directory..."
    sudo rm -rf "$INSTALL_DIR"

    success "fido2-hid-bridge has been uninstalled."
    exit 0
fi

# =============================================================================
# INSTALL
# =============================================================================
echo ""
echo "================================================"
echo "  fido2-hid-bridge Installer"
echo "================================================"
echo ""
echo "This will:"
echo "  1. Install required system packages"
echo "  2. Download and install fido2-hid-bridge to $INSTALL_DIR"
echo "     Commit: $COMMIT_HASH"
echo "  3. Register it as a systemd service (auto-starts on boot)"
echo ""
read -rp "Continue? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
echo ""

# --- Check root/sudo ---------------------------------------------------------
if ! command -v sudo &>/dev/null; then
    error "sudo is required. Please install it first."
fi

# --- Check OS ----------------------------------------------------------------
if ! grep -qi "ubuntu\|debian" /etc/os-release 2>/dev/null; then
    warn "This script is designed for Ubuntu/Debian. Proceeding anyway..."
fi

# --- Step 1: System dependencies ---------------------------------------------
info "Installing system dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    git \
    gcc \
    libffi-dev \
    libpcsclite-dev \
    pcscd \
    build-essential \
    > /dev/null 2>&1
success "System dependencies installed."

# --- Step 2: Install pipx ----------------------------------------------------
info "Installing pipx..."
sudo apt-get install -y -qq pipx > /dev/null 2>&1 || \
    python3 -m pip install --user pipx --quiet
python3 -m pipx ensurepath > /dev/null 2>&1 || true
# Make pipx available in this script's PATH immediately
export PATH="$PATH:$HOME/.local/bin:/usr/bin"
success "pipx ready."

# --- Step 3: Download source -------------------------------------------------
info "Downloading fido2-hid-bridge source..."
sudo rm -rf "$INSTALL_DIR"
sudo mkdir -p "$INSTALL_DIR"
sudo chown "$USER":"$USER" "$INSTALL_DIR"
git clone --quiet "$REPO_URL" "$INSTALL_DIR"

info "Checking out commit $COMMIT_HASH..."
git -C "$INSTALL_DIR" checkout --quiet "$COMMIT_HASH" || \
    error "Commit '$COMMIT_HASH' not found in repository. Check the hash and try again."

ACTUAL_COMMIT=$(git -C "$INSTALL_DIR" rev-parse HEAD)
success "Source ready at $INSTALL_DIR (commit: $ACTUAL_COMMIT)."

# --- Step 4: Create virtualenv and install -----------------------------------
info "Creating Python virtual environment..."
python3 -m venv "$INSTALL_DIR/.venv"
success "Virtual environment created."

info "Installing Python dependencies (this may take a minute)..."
"$INSTALL_DIR/.venv/bin/pip" install --quiet --upgrade pip
"$INSTALL_DIR/.venv/bin/pip" install --quiet \
    uhid \
    "fido2[pcsc]>=2.0.0" \
    pyscard
# Install the package itself in editable mode
"$INSTALL_DIR/.venv/bin/pip" install --quiet -e "$INSTALL_DIR"
success "Python dependencies installed."

# Verify the binary exists
if [[ ! -f "$INSTALL_DIR/.venv/bin/fido2-hid-bridge" ]]; then
    error "Installation failed: binary not found at $INSTALL_DIR/.venv/bin/fido2-hid-bridge"
fi

# --- Step 5: Install systemd service -----------------------------------------
info "Installing systemd service..."
sudo tee "$SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=FIDO2 HID Bridge (PC/SC to USB-HID)
After=auditd.service syslog.target network.target local-fs.target pcscd.service
Requires=pcscd.service

[Service]
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/.venv/bin/fido2-hid-bridge
Type=simple
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
success "Service installed and enabled."

# --- Step 6: Start the service -----------------------------------------------
info "Starting service..."
sudo systemctl start "$SERVICE_NAME"
sleep 2  # give it a moment to start

# Check status
if systemctl is-active --quiet "$SERVICE_NAME"; then
    success "Service is running!"
else
    warn "Service may have failed to start. Check status with:"
    warn "  sudo systemctl status $SERVICE_NAME"
    warn "  sudo journalctl -u $SERVICE_NAME -n 50"
fi

# =============================================================================
# Done
# =============================================================================
echo ""
echo "================================================"
echo -e "  ${GREEN}Installation complete!${NC}"
echo "================================================"
echo ""
echo "  The bridge is now running and will start automatically on boot."
echo "  Installed commit: $ACTUAL_COMMIT"
echo ""
echo "  Useful commands:"
echo "    Check status:   sudo systemctl status $SERVICE_NAME"
echo "    Stop:           sudo systemctl stop $SERVICE_NAME"
echo "    Start:          sudo systemctl start $SERVICE_NAME"
echo "    Disable:        sudo systemctl disable $SERVICE_NAME"
echo "    View logs:      sudo journalctl -u $SERVICE_NAME -f"
echo ""
echo "  To uninstall:"
echo "    ./install-fido2-hid-bridge.sh --uninstall"
echo ""