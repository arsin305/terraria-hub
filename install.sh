#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
#  Terraria Hub — Installer
#  Clones the repo and configures your environment
#  Supports: Ubuntu, Debian, Fedora, Arch
# ══════════════════════════════════════════════════════════════════════════════

set -e

REPO_URL="https://github.com/arsin305/terraria-hub.git"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
prompt()  { echo -e "${YELLOW}[INPUT]${NC} $*"; }
header()  { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}\n"; }

# ── Banner ────────────────────────────────────────────────────────────────────
clear
echo -e "${GREEN}"
cat << 'BANNER'
  ████████╗███████╗██████╗ ██████╗  █████╗ ██████╗ ██╗ █████╗
  ╚══██╔══╝██╔════╝██╔══██╗██╔══██╗██╔══██╗██╔══██╗██║██╔══██╗
     ██║   █████╗  ██████╔╝██████╔╝███████║██████╔╝██║███████║
     ██║   ██╔══╝  ██╔══██╗██╔══██╗██╔══██║██╔══██╗██║██╔══██║
     ██║   ███████╗██║  ██║██║  ██║██║  ██║██║  ██║██║██║  ██║
     ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═╝
BANNER
echo -e "${NC}"
echo -e "${BOLD}${CYAN}              ⚔  tModLoader Server Hub  —  Installer  ⚔${NC}"
echo -e "${DIM}        Multi-user panel · Per-world containers · Steam Workshop mods${NC}"
echo ""
echo -e "${GREEN}  ══════════════════════════════════════════════════════════════════${NC}"
echo ""
sleep 0.5

# ── Preflight checks ──────────────────────────────────────────────────────────
header "Checking Prerequisites"

info "Checking Docker..."
if ! command -v docker &>/dev/null; then
  error "Docker is not installed. Install it from: https://docs.docker.com/engine/install/"
fi
success "Docker found: $(docker --version)"

info "Checking Docker Compose..."
if docker compose version &>/dev/null 2>&1; then
  success "Docker Compose (plugin) found"
elif command -v docker-compose &>/dev/null; then
  success "docker-compose (standalone) found"
  docker() {
    if [ "$1" = "compose" ]; then shift; command docker-compose "$@"
    else command docker "$@"; fi
  }
  export -f docker
else
  error "Docker Compose is not installed. Install it from: https://docs.docker.com/compose/install/"
fi

info "Checking git..."
if ! command -v git &>/dev/null; then
  error "git is not installed. Install it with your package manager (e.g. sudo apt install git)."
fi
success "git found: $(git --version)"

# ── Gather configuration ──────────────────────────────────────────────────────
header "Configuration"

prompt "Linux username (for path construction) [$(whoami)]:"
read -r LINUX_USER
LINUX_USER="${LINUX_USER:-$(whoami)}"

DEFAULT_INSTALL_DIR="/home/${LINUX_USER}/docker/terraria-hub"
prompt "Install directory [${DEFAULT_INSTALL_DIR}]:"
read -r INSTALL_DIR
INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"

prompt "Panel port [3001]:"
read -r PANEL_PORT
PANEL_PORT="${PANEL_PORT:-3001}"

# Auto-detect host IP
DETECTED_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
[ -z "$DETECTED_IP" ] && DETECTED_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

if [ -n "$DETECTED_IP" ]; then
  success "Detected host IP: ${DETECTED_IP}"
  prompt "Host IP or hostname (used in email links) [${DETECTED_IP}]:"
  read -r HOST_IP
  HOST_IP="${HOST_IP:-$DETECTED_IP}"
else
  prompt "Host IP or hostname (e.g. 192.168.1.100):"
  read -r HOST_IP
  while [ -z "$HOST_IP" ]; do
    warn "Host IP is required."
    prompt "Host IP or hostname:"
    read -r HOST_IP
  done
fi

prompt "Admin email address:"
read -r ADMIN_EMAIL
while [ -z "$ADMIN_EMAIL" ]; do
  warn "Admin email is required."
  prompt "Admin email address:"
  read -r ADMIN_EMAIL
done

# ── SMTP Configuration ────────────────────────────────────────────────────────
header "SMTP Configuration"
echo -e "  ${CYAN}Terraria Hub needs SMTP to send verification and password reset emails.${NC}"
echo ""
echo -e "  ${BOLD}1)${NC} Zoho Mail       — smtppro.zoho.com:587"
echo -e "  ${BOLD}2)${NC} Gmail           — smtp.gmail.com:587       (requires App Password)"
echo -e "  ${BOLD}3)${NC} Brevo           — smtp-relay.brevo.com:587 (300 emails/day free)"
echo -e "  ${BOLD}4)${NC} Mailjet         — in-v3.mailjet.com:587    (200 emails/day free)"
echo -e "  ${BOLD}5)${NC} SendGrid        — smtp.sendgrid.net:587    (100 emails/day free)"
echo -e "  ${BOLD}6)${NC} Mailtrap (dev)  — sandbox.smtp.mailtrap.io:587"
echo -e "  ${BOLD}7)${NC} Outlook/Hotmail — smtp-mail.outlook.com:587"
echo -e "  ${BOLD}8)${NC} Custom / Other"
echo ""
prompt "Choose a provider [1-8] or Enter to enter manually:"
read -r SMTP_CHOICE

case "$SMTP_CHOICE" in
  1) SMTP_HOST="smtppro.zoho.com";              SMTP_PORT="587" ;;
  2) SMTP_HOST="smtp.gmail.com";                SMTP_PORT="587" ;;
  3) SMTP_HOST="smtp-relay.brevo.com";          SMTP_PORT="587" ;;
  4) SMTP_HOST="in-v3.mailjet.com";             SMTP_PORT="587" ;;
  5) SMTP_HOST="smtp.sendgrid.net";             SMTP_PORT="587" ;;
  6) SMTP_HOST="sandbox.smtp.mailtrap.io";      SMTP_PORT="587" ;;
  7) SMTP_HOST="smtp-mail.outlook.com";         SMTP_PORT="587" ;;
  *) SMTP_HOST=""; SMTP_PORT="" ;;
esac

if [ -n "$SMTP_HOST" ]; then
  success "Pre-filled: ${SMTP_HOST}:${SMTP_PORT}"
  prompt "SMTP host [${SMTP_HOST}]:"
  read -r SMTP_HOST_INPUT
  SMTP_HOST="${SMTP_HOST_INPUT:-$SMTP_HOST}"
  prompt "SMTP port [${SMTP_PORT}]:"
  read -r SMTP_PORT_INPUT
  SMTP_PORT="${SMTP_PORT_INPUT:-$SMTP_PORT}"
else
  prompt "SMTP host:"
  read -r SMTP_HOST
  while [ -z "$SMTP_HOST" ]; do
    warn "SMTP host is required."
    prompt "SMTP host:"
    read -r SMTP_HOST
  done
  prompt "SMTP port [587]:"
  read -r SMTP_PORT
  SMTP_PORT="${SMTP_PORT:-587}"
fi

prompt "SMTP username:"
read -r SMTP_USER
while [ -z "$SMTP_USER" ]; do
  warn "SMTP username is required."
  prompt "SMTP username:"
  read -r SMTP_USER
done

prompt "SMTP password (app-specific password if using 2FA):"
read -rs SMTP_PASS
echo ""
while [ -z "$SMTP_PASS" ]; do
  warn "SMTP password is required."
  prompt "SMTP password:"
  read -rs SMTP_PASS
  echo ""
done

prompt "SMTP From address [${SMTP_USER}]:"
read -r SMTP_FROM
SMTP_FROM="${SMTP_FROM:-$SMTP_USER}"

# ── playit.gg Tunnel ──────────────────────────────────────────────────────────
header "playit.gg Tunnel Setup (Optional)"
echo -e "  ${CYAN}playit.gg provides a free public tunnel so players can connect without"
echo -e "  port-forwarding. Create an account at https://playit.gg and add a Docker"
echo -e "  agent to get your Secret Key.${NC}"
echo ""
prompt "playit.gg Secret Key (leave blank to skip):"
read -r PLAYIT_SECRET

if [ -z "$PLAYIT_SECRET" ]; then
  warn "No secret key entered — playit.gg will be skipped."
  SKIP_PLAYIT=true
else
  success "Secret key accepted — playit.gg tunnel will be deployed."
  SKIP_PLAYIT=false
fi

# ── Generate secrets ──────────────────────────────────────────────────────────
header "Generating Secrets"
JWT_SECRET=$(openssl rand -hex 32 2>/dev/null || cat /proc/sys/kernel/random/uuid | tr -d '-' | head -c 64)
success "Generated JWT secret"

ADMIN_TEMP_PASS=$(openssl rand -base64 16 2>/dev/null | tr -dc 'A-Za-z0-9@#!%' | head -c 12)
[ -z "$ADMIN_TEMP_PASS" ] && ADMIN_TEMP_PASS="Hub$(cat /proc/sys/kernel/random/uuid | tr -d '-' | head -c 8)!"
success "Generated admin temp password"

# ── Clone repo ────────────────────────────────────────────────────────────────
header "Cloning Repository"

if [ -d "$INSTALL_DIR" ]; then
  warn "Directory ${INSTALL_DIR} already exists."
  prompt "Pull latest changes instead of fresh clone? [Y/n]:"
  read -r DO_PULL
  if [[ "${DO_PULL,,}" != "n" ]]; then
    git -C "$INSTALL_DIR" pull && success "Repository updated."
  fi
else
  git clone "$REPO_URL" "$INSTALL_DIR"
  success "Cloned to: ${INSTALL_DIR}"
fi

# ── Create runtime directories ────────────────────────────────────────────────
mkdir -p "${INSTALL_DIR}/data"
mkdir -p "${INSTALL_DIR}/worlds"
success "Created runtime directories"

# ── Write .env ────────────────────────────────────────────────────────────────
header "Writing Configuration"
info "Writing .env..."
cat > "${INSTALL_DIR}/.env" <<ENVEOF
PANEL_PORT=${PANEL_PORT}
JWT_SECRET=${JWT_SECRET}
WORLDS_DIR=/worlds
HOST_WORLDS_DIR=${INSTALL_DIR}/worlds
TMOD_IMAGE=jacobsmile/tmodloader1.4:latest
ADMIN_EMAIL=${ADMIN_EMAIL}
HOST_IP=${HOST_IP}
SMTP_HOST=${SMTP_HOST}
SMTP_PORT=${SMTP_PORT}
SMTP_USER=${SMTP_USER}
SMTP_PASS=${SMTP_PASS}
SMTP_FROM=${SMTP_FROM}
ADMIN_TEMP_PASS=${ADMIN_TEMP_PASS}
PORT_BASE=7777
PORT_MAX=7900
ENVEOF
success "Written: .env"

# ── Patch docker-compose.yml for playit ──────────────────────────────────────
if [ "$SKIP_PLAYIT" = "false" ]; then
  info "Enabling playit.gg service in docker-compose.yml..."
  # Append playit service if not already present
  if ! grep -q "playit-cloud" "${INSTALL_DIR}/docker-compose.yml"; then
    cat >> "${INSTALL_DIR}/docker-compose.yml" <<PLAYITEOF

  playit:
    image: ghcr.io/playit-cloud/playit-agent:0.17
    container_name: terraria-playit-1
    network_mode: host
    environment:
      - SECRET_KEY=${PLAYIT_SECRET}
    restart: unless-stopped
PLAYITEOF
    success "playit.gg service added to docker-compose.yml"
  fi
fi

# ── Deploy ────────────────────────────────────────────────────────────────────
header "Deploying Terraria Hub"
cd "${INSTALL_DIR}"

info "Pulling tModLoader image (this may take a few minutes)..."
docker pull jacobsmile/tmodloader1.4:latest || warn "Could not pre-pull tModLoader image — it will pull on first world start."

info "Building and starting terraria-hub container..."
docker compose up -d --build

# ── Wait for panel ────────────────────────────────────────────────────────────
info "Waiting for panel to come online..."
MAX_WAIT=60
ELAPSED=0
until curl -sf "http://localhost:${PANEL_PORT}" >/dev/null 2>&1; do
  sleep 2
  ELAPSED=$((ELAPSED + 2))
  if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
    warn "Panel didn't respond within ${MAX_WAIT}s. Check: docker logs terraria-hub"
    break
  fi
done
curl -sf "http://localhost:${PANEL_PORT}" >/dev/null 2>&1 && success "Panel is online!"

# ── Test SMTP ─────────────────────────────────────────────────────────────────
header "Testing SMTP"
READY=false
for i in $(seq 1 10); do
  if docker exec terraria-hub node -e "require('nodemailer')" >/dev/null 2>&1; then
    READY=true; break
  fi
  sleep 3
done

if [ "$READY" = "true" ]; then
  info "Sending test email to ${ADMIN_EMAIL}..."
  cat > /tmp/th_smtp_test.js << NODESCRIPT
const nodemailer = require('nodemailer');
const t = nodemailer.createTransport({ host:'${SMTP_HOST}', port:${SMTP_PORT}, secure:false, auth:{user:'${SMTP_USER}',pass:'${SMTP_PASS}'} });
t.sendMail({ from:'Terraria Hub <${SMTP_FROM}>', to:'${ADMIN_EMAIL}', subject:'Terraria Hub SMTP Test',
  html:'<h2>SMTP is working!</h2><p>Panel: http://${HOST_IP}:${PANEL_PORT}</p><p>Login: ${ADMIN_EMAIL} / ${ADMIN_TEMP_PASS}</p><p>Change your password immediately after first login.</p>'
}, (err) => { if(err){process.stdout.write('FAIL:'+err.message+'\n');process.exit(0);}else{process.stdout.write('OK\n');process.exit(0);} });
NODESCRIPT
  docker cp /tmp/th_smtp_test.js terraria-hub:/app/smtp_test.js
  SMTP_RESULT=$(docker exec terraria-hub node /app/smtp_test.js 2>&1) || true
  echo "$SMTP_RESULT" | grep -q "^OK" && { success "Test email sent to ${ADMIN_EMAIL}!"; SMTP_OK=true; } || { warn "SMTP test failed — check .env credentials then: docker compose restart"; SMTP_OK=false; }
  rm -f /tmp/th_smtp_test.js
else
  warn "Container not ready — skipping SMTP test. Run: docker logs terraria-hub"
  SMTP_OK=false
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          TERRARIA HUB INSTALLED SUCCESSFULLY         ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}Panel URL:${NC}     http://${HOST_IP}:${PANEL_PORT}"
echo -e "  ${CYAN}Admin email:${NC}   ${ADMIN_EMAIL}"
echo -e "  ${YELLOW}Admin pass:${NC}    ${BOLD}${ADMIN_TEMP_PASS}${NC}  ← CHANGE THIS IMMEDIATELY"
echo ""
echo -e "  ${RED}${BOLD}⚠  Save this password now — it will not be shown again!${NC}"
echo ""
echo -e "  ${CYAN}Install dir:${NC}   ${INSTALL_DIR}"
echo -e "  ${CYAN}Worlds data:${NC}   ${INSTALL_DIR}/worlds/"
echo -e "  ${CYAN}Database:${NC}      ${INSTALL_DIR}/data/hub.db"
echo ""
echo -e "  ${CYAN}Useful commands:${NC}"
echo -e "    Logs:     docker logs -f terraria-hub"
echo -e "    Restart:  cd ${INSTALL_DIR} && docker compose restart"
echo -e "    Stop:     cd ${INSTALL_DIR} && docker compose down"
echo -e "    Rebuild:  cd ${INSTALL_DIR} && docker compose up -d --build"
echo ""
[ "$SMTP_OK" = "true" ] && echo -e "${GREEN}  ✓  SMTP verified — test email delivered${NC}" || echo -e "${YELLOW}  ⚠  SMTP test failed. Edit ${INSTALL_DIR}/.env and restart.${NC}"
echo ""
