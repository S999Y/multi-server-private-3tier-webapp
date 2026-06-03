#!/bin/bash
# ==============================================================================
# backend-auto.sh — Node.js 20 + PM2 backend setup for BMI Health Tracker
#
# Run on: Backend EC2 (bmi-app-backend) via AWS SSM Session Manager
# OS    : Ubuntu 24.04 LTS
#
# REQUIRED environment variables (export before running):
#   DB_PASSWORD    — PostgreSQL password for bmi_user (same as DB-auto.sh)
#   DB_PRIVATE_IP  — Private IP of the DB EC2 (printed by DB-auto.sh)
#
# Usage:
#   export DB_PASSWORD='YourStr0ngP@ssword'
#   export DB_PRIVATE_IP='10.0.2.x'
#   sudo -E bash backend-auto.sh
#
# What this script does:
#   1. System update
#   2. Install Node.js 20 LTS via NodeSource
#   3. Install PM2 process manager globally
#   4. Clone repo to /opt/bmi-app
#   5. Install npm production dependencies
#   6. Write .env with DATABASE_URL + FRONTEND_URL
#   7. Start app with PM2 (uses ecosystem.config.js from repo)
#   8. Enable PM2 startup on reboot
#   9. Health check verification
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
step() { echo -e "\n${CYAN}==> $*${NC}"; }
ok()   { echo -e "${GREEN}    [OK]${NC} $*"; }
warn() { echo -e "${YELLOW}    [WARN]${NC} $*"; }
die()  { echo -e "${RED}    [ERROR]${NC} $*" >&2; exit 1; }

# ── Validate environment ────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Run as root or with sudo: sudo -E bash $0"
[[ -z "${DB_PASSWORD:-}" ]]   && die "DB_PASSWORD is not set. Export it before running."
[[ -z "${DB_PRIVATE_IP:-}" ]] && die "DB_PRIVATE_IP is not set. Run DB-auto.sh first and note the DB private IP."
[[ "${DB_PASSWORD}" == "placeholder" || "${DB_PASSWORD}" == "changeme" ]] && \
    die "DB_PASSWORD is still a placeholder value."

# ── Configuration ────────────────────────────────────────────────────────────
DB_USER="bmi_user"
DB_NAME="bmidb"
APP_DIR="/opt/bmi-app"
REPO_URL="https://github.com/sarowar-alam/multi-server-private-3tier-webapp.git"
FRONTEND_URL="https://bmi.ostaddevops.click"
NODE_VERSION="20"

step "Starting backend setup | DB=${DB_PRIVATE_IP}:5432"

# ── [1] System update ────────────────────────────────────────────────────────
step "[1/8] Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -q
apt-get upgrade -y -q -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
ok "System updated"

# ── [2] Install Node.js 20 LTS ───────────────────────────────────────────────
step "[2/8] Installing Node.js ${NODE_VERSION} LTS via NodeSource..."
apt-get install -y -q curl ca-certificates gnupg

# NodeSource setup — fetches and runs the official setup script
curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash -
apt-get install -y -q nodejs

NODE_VER=$(node --version)
NPM_VER=$(npm --version)
ok "Node.js ${NODE_VER} | npm ${NPM_VER}"

# ── [3] Install PM2 ──────────────────────────────────────────────────────────
step "[3/8] Installing PM2 process manager..."
npm install -g pm2
ok "PM2 $(pm2 --version) installed"

# ── [4] Clone / update repository ────────────────────────────────────────────
step "[4/8] Cloning application repository..."
apt-get install -y -q git

if [[ -d "${APP_DIR}/.git" ]]; then
    warn "${APP_DIR} exists — pulling latest..."
    git -C "${APP_DIR}" pull --ff-only
else
    git clone "${REPO_URL}" "${APP_DIR}"
fi
ok "Repository at ${APP_DIR}"

# ── [5] Install npm dependencies ─────────────────────────────────────────────
step "[5/8] Installing backend production dependencies..."
cd "${APP_DIR}/backend"
npm install --omit=dev --silent
ok "npm packages installed (production only)"

# ── [6] Write .env ───────────────────────────────────────────────────────────
step "[6/8] Writing .env configuration..."
mkdir -p "${APP_DIR}/backend/logs"

# Build DATABASE_URL
DATABASE_URL="postgresql://${DB_USER}:${DB_PASSWORD}@${DB_PRIVATE_IP}:5432/${DB_NAME}"

cat > "${APP_DIR}/backend/.env" <<EOF
NODE_ENV=production
PORT=3000
DATABASE_URL=${DATABASE_URL}
FRONTEND_URL=${FRONTEND_URL}
EOF

# Restrict .env permissions — readable by root only
chmod 600 "${APP_DIR}/backend/.env"
ok ".env written to ${APP_DIR}/backend/.env (mode 600)"

# Verify DATABASE_URL is not empty
grep -q "DATABASE_URL=postgresql" "${APP_DIR}/backend/.env" || die ".env DATABASE_URL missing or malformed"

# ── [7] Start with PM2 ───────────────────────────────────────────────────────
step "[7/8] Starting application with PM2..."
cd "${APP_DIR}/backend"

# Stop any existing instance cleanly (idempotent)
pm2 delete bmi-backend 2>/dev/null && warn "Stopped existing bmi-backend process" || true

pm2 start ecosystem.config.js
pm2 save
ok "PM2 process 'bmi-backend' started"

# ── [8] Configure PM2 startup on reboot ──────────────────────────────────────
step "[8/8] Configuring PM2 systemd startup..."

# Generate startup command and evaluate it
PM2_STARTUP_CMD=$(pm2 startup systemd -u root --hp /root 2>&1 | grep "sudo env PATH")
if [[ -n "$PM2_STARTUP_CMD" ]]; then
    eval "$PM2_STARTUP_CMD"
    ok "PM2 startup configured via systemd"
else
    # Fallback: run startup directly as root
    pm2 startup systemd -u root --hp /root --service-name pm2-root 2>&1 || true
    warn "PM2 startup: check 'systemctl status pm2-root' manually if needed"
fi
pm2 save

# ── Health check ─────────────────────────────────────────────────────────────
step "Running health check (up to 60s)..."
MAX_RETRIES=12
for i in $(seq 1 $MAX_RETRIES); do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/health 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" == "200" ]]; then
        ok "Health check passed (HTTP $HTTP_CODE)"
        break
    fi
    if [[ $i -eq $MAX_RETRIES ]]; then
        echo ""
        warn "Last health check response: HTTP $HTTP_CODE"
        echo "--- PM2 logs (last 30 lines) ---"
        pm2 logs bmi-backend --lines 30 --nostream 2>/dev/null || true
        die "Backend health check failed after $((MAX_RETRIES * 5))s. Review logs above."
    fi
    echo "    Attempt $i/$MAX_RETRIES — waiting 5s (HTTP $HTTP_CODE)..."
    sleep 5
done

# ── Summary ──────────────────────────────────────────────────────────────────
PRIVATE_IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}  BACKEND SETUP COMPLETE${NC}"
echo -e "${GREEN}================================================================${NC}"
echo ""
echo "  Node.js API is running on : ${PRIVATE_IP}:3000"
echo "  Process manager           : PM2 (auto-restart + reboot persistent)"
echo "  App directory             : ${APP_DIR}/backend"
echo "  Logs directory            : ${APP_DIR}/backend/logs/"
echo "  .env file                 : ${APP_DIR}/backend/.env"
echo ""
echo "  Endpoints:"
echo "    GET  http://${PRIVATE_IP}:3000/health"
echo "    POST http://${PRIVATE_IP}:3000/api/measurements"
echo "    GET  http://${PRIVATE_IP}:3000/api/measurements"
echo "    GET  http://${PRIVATE_IP}:3000/api/measurements/trends"
echo ""
echo "  PM2 commands:"
echo "    pm2 status"
echo "    pm2 logs bmi-backend"
echo "    pm2 restart bmi-backend"
echo ""
echo "  ALB routes /api/* and /health to this server on port 3000."
echo ""
