#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
#  Terraria Hub — Uninstaller
#  Removes containers, images, data, cron jobs, and install directory
# ══════════════════════════════════════════════════════════════════════════════

set -e

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
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
prompt()  { echo -e "${YELLOW}[INPUT]${NC} $*"; }
header()  { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}\n"; }

# ── Banner ────────────────────────────────────────────────────────────────────
clear
echo -e "${RED}"
cat << 'BANNER'
  ████████╗███████╗██████╗ ██████╗  █████╗ ██████╗ ██╗ █████╗
  ╚══██╔══╝██╔════╝██╔══██╗██╔══██╗██╔══██╗██╔══██╗██║██╔══██╗
     ██║   █████╗  ██████╔╝██████╔╝███████║██████╔╝██║███████║
     ██║   ██╔══╝  ██╔══██╗██╔══██╗██╔══██║██╔══██╗██║██╔══██║
     ██║   ███████╗██║  ██║██║  ██║██║  ██║██║  ██║██║██║  ██║
     ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═╝
BANNER
echo -e "${NC}"
echo -e "${BOLD}${RED}                   ⚠  Terraria Hub — Uninstaller  ⚠${NC}"
echo -e "${DIM}          Removes all containers, data, images, and config${NC}"
echo ""
echo -e "${RED}  ══════════════════════════════════════════════════════════════════${NC}"
echo ""
sleep 0.5

# ── Detect install directory ──────────────────────────────────────────────────
header "Locate Installation"

DEFAULT_USER=$(whoami)
prompt "Linux username used during install [${DEFAULT_USER}]:"
read -r INPUT_USER
LINUX_USER="${INPUT_USER:-$DEFAULT_USER}"

DEFAULT_INSTALL_DIR="/home/${LINUX_USER}/docker/terraria-hub"
prompt "Install directory [${DEFAULT_INSTALL_DIR}]:"
read -r INPUT_DIR
INSTALL_DIR="${INPUT_DIR:-$DEFAULT_INSTALL_DIR}"

if [ ! -d "$INSTALL_DIR" ]; then
  warn "Directory ${INSTALL_DIR} not found — it may already be removed."
  warn "Continuing to clean up any remaining containers and images..."
fi

# ── What to remove ────────────────────────────────────────────────────────────
header "Uninstall Options"

echo -e "  ${BOLD}What would you like to remove?${NC}"
echo ""
echo -e "  ${BOLD}1)${NC} Everything            — containers, images, ALL world data, install dir"
echo -e "  ${BOLD}2)${NC} Containers & images only  — keep world data and .env (safe reinstall)"
echo -e "  ${BOLD}3)${NC} Containers only       — keep images, data, and config"
echo ""
prompt "Choose [1-3]:"
read -r REMOVE_CHOICE
REMOVE_CHOICE="${REMOVE_CHOICE:-1}"

# ── Confirm ───────────────────────────────────────────────────────────────────
echo ""
case "$REMOVE_CHOICE" in
  1)
    echo -e "  ${RED}${BOLD}This will permanently delete:${NC}"
    echo -e "    • terraria-hub container"
    echo -e "    • terraria-playit-1 container"
    echo -e "    • All th-* world containers"
    echo -e "    • terraria-hub-panel Docker image"
    echo -e "    • ${INSTALL_DIR}  (includes ALL world saves and database)"
    echo -e "    • Cron job (if any)"
    ;;
  2)
    echo -e "  ${YELLOW}${BOLD}This will remove:${NC}"
    echo -e "    • terraria-hub container"
    echo -e "    • terraria-playit-1 container"
    echo -e "    • All th-* world containers"
    echo -e "    • terraria-hub-panel Docker image"
    echo -e "  ${GREEN}This will KEEP:${NC}"
    echo -e "    • ${INSTALL_DIR}/worlds/  (all world saves)"
    echo -e "    • ${INSTALL_DIR}/data/    (database)"
    echo -e "    • ${INSTALL_DIR}/.env     (credentials)"
    ;;
  3)
    echo -e "  ${YELLOW}${BOLD}This will remove:${NC}"
    echo -e "    • terraria-hub container"
    echo -e "    • terraria-playit-1 container"
    echo -e "    • All th-* world containers"
    echo -e "  ${GREEN}This will KEEP:${NC}"
    echo -e "    • Docker images"
    echo -e "    • All data, worlds, and config"
    ;;
  *)
    error "Invalid choice. Exiting."
    exit 1
    ;;
esac

echo ""
echo -e "${RED}${BOLD}This action cannot be undone.${NC}"
prompt "Type 'yes' to confirm:"
read -r CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo -e "${CYAN}Aborted — nothing was changed.${NC}"
  exit 0
fi

# ── Stop and remove world containers (th-*) including per-world playit ──────────
header "Stopping World Containers"

# Stop game servers first, then their playit tunnels
WORLD_CONTAINERS=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep '^th-' | grep -v '^th-playit-' || true)
PLAYIT_CONTAINERS=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep '^th-playit-' || true)

if [ -n "$WORLD_CONTAINERS" ]; then
  while IFS= read -r cname; do
    info "Stopping world container: ${cname}"
    docker stop "$cname" >/dev/null 2>&1 || true
    docker rm "$cname" >/dev/null 2>&1 && success "Removed: ${cname}" || warn "Could not remove: ${cname}"
  done <<< "$WORLD_CONTAINERS"
else
  info "No world containers (th-*) found."
fi

if [ -n "$PLAYIT_CONTAINERS" ]; then
  while IFS= read -r cname; do
    info "Stopping per-world playit container: ${cname}"
    docker stop "$cname" >/dev/null 2>&1 || true
    docker rm "$cname" >/dev/null 2>&1 && success "Removed: ${cname}" || warn "Could not remove: ${cname}"
  done <<< "$PLAYIT_CONTAINERS"
else
  info "No per-world playit containers found."
fi

# ── Stop and remove panel container ───────────────────────────────────────────
header "Stopping Panel Containers"

for CNAME in terraria-hub terraria-playit-1; do
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CNAME}$"; then
    info "Stopping: ${CNAME}"
    docker stop "$CNAME" >/dev/null 2>&1 || true
    docker rm "$CNAME" >/dev/null 2>&1 && success "Removed container: ${CNAME}" || warn "Could not remove: ${CNAME}"
  else
    info "Container not found (already gone): ${CNAME}"
  fi
done

# ── Remove Docker image ────────────────────────────────────────────────────────
if [ "$REMOVE_CHOICE" = "1" ] || [ "$REMOVE_CHOICE" = "2" ]; then
  header "Removing Docker Images"

  for IMG in terraria-hub-panel terraria-hub_panel; do
    if docker image inspect "$IMG" >/dev/null 2>&1; then
      docker rmi "$IMG" >/dev/null 2>&1 && success "Removed image: ${IMG}" || warn "Could not remove image: ${IMG}"
    fi
  done

  # Remove any dangling images left from the build
  DANGLING=$(docker images -f "dangling=true" -q 2>/dev/null || true)
  if [ -n "$DANGLING" ]; then
    info "Cleaning up dangling images..."
    docker image prune -f >/dev/null 2>&1 && success "Dangling images pruned." || true
  fi
fi

# ── Remove install directory ───────────────────────────────────────────────────
if [ "$REMOVE_CHOICE" = "1" ]; then
  header "Removing Install Directory"

  if [ -d "$INSTALL_DIR" ]; then
    info "Fixing file ownership before removal (world files are created by root inside Docker)..."
    sudo chown -R "${LINUX_USER}:${LINUX_USER}" "$INSTALL_DIR" 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
    success "Removed: ${INSTALL_DIR}"
  else
    info "Directory already gone: ${INSTALL_DIR}"
  fi
elif [ "$REMOVE_CHOICE" = "2" ]; then
  header "Removing Panel Files (Keeping Data)"

  info "Fixing file ownership on world data..."
  sudo chown -R "${LINUX_USER}:${LINUX_USER}" "$INSTALL_DIR" 2>/dev/null || true

  # Remove everything except worlds/, data/, .env, and backup.sh
  for ITEM in panel docker-compose.yml; do
    TARGET="${INSTALL_DIR}/${ITEM}"
    if [ -e "$TARGET" ]; then
      rm -rf "$TARGET"
      success "Removed: ${TARGET}"
    fi
  done
  info "Kept: ${INSTALL_DIR}/worlds/  ${INSTALL_DIR}/data/  ${INSTALL_DIR}/.env"
fi

# ── Remove cron job ───────────────────────────────────────────────────────────
header "Removing Cron Job"

if crontab -l 2>/dev/null | grep -q "terraria-hub"; then
  ( crontab -l 2>/dev/null | grep -v "terraria-hub" ) | crontab -
  success "Cron job removed."
else
  info "No Terraria Hub cron job found."
fi

# ── Remove temp files ─────────────────────────────────────────────────────────
rm -f /tmp/th_smtp_test.js 2>/dev/null || true

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║        TERRARIA HUB UNINSTALLED SUCCESSFULLY         ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

case "$REMOVE_CHOICE" in
  1)
    success "All containers, images, and data have been removed."
    ;;
  2)
    success "Containers and images removed. Your world data is safe at:"
    echo -e "    ${CYAN}${INSTALL_DIR}/worlds/${NC}"
    echo -e "    ${CYAN}${INSTALL_DIR}/data/${NC}"
    echo -e "    ${CYAN}${INSTALL_DIR}/.env${NC}"
    echo ""
    echo -e "  To reinstall and pick up where you left off, run ${BOLD}install.sh${NC}"
    echo -e "  and use the same install directory: ${CYAN}${INSTALL_DIR}${NC}"
    ;;
  3)
    success "Containers stopped and removed. Everything else is intact."
    echo -e "  To restart, run: ${BOLD}cd ${INSTALL_DIR} && docker compose up -d --build${NC}"
    ;;
esac

echo ""
