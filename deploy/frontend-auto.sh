#!/bin/bash
# ==============================================================================
# frontend-auto.sh — React (Vite) build + Nginx setup for BMI Health Tracker
#
# Run on: Frontend EC2 (bmi-app-frontend) via AWS SSM Session Manager
# OS    : Ubuntu 24.04 LTS
#
# No environment variables required.
#
# Usage:
#   sudo bash frontend-auto.sh
#
# What this script does:
#   1. System update
#   2. Install Node.js 20 LTS via NodeSource
#   3. Install Nginx
#   4. Clone repo to /opt/bmi-app
#   5. npm install frontend dependencies
#   6. vite build → produces /opt/bmi-app/frontend/dist/
#   7. Write Nginx config (SPA mode, security headers, gzip)
#      NOTE: No /api proxy here — the ALB routes /api/* to the backend server
#   8. Enable + restart Nginx
#   9. Set correct file permissions
#  10. Health check verification
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
step() { echo -e "\n${CYAN}==> $*${NC}"; }
ok()   { echo -e "${GREEN}    [OK]${NC} $*"; }
warn() { echo -e "${YELLOW}    [WARN]${NC} $*"; }
die()  { echo -e "${RED}    [ERROR]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && die "Run as root or with sudo: sudo bash $0"

# ── Configuration ────────────────────────────────────────────────────────────
APP_DIR="/opt/bmi-app"
REPO_URL="https://github.com/sarowar-alam/multi-server-private-3tier-webapp.git"
DIST_DIR="${APP_DIR}/frontend/dist"
NGINX_CONF="/etc/nginx/sites-available/bmi"
NODE_VERSION="20"

step "Starting frontend setup"

# ── [1] System update ────────────────────────────────────────────────────────
step "[1/9] Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -q
apt-get upgrade -y -q -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
ok "System updated"

# ── [2] Install Node.js 20 LTS ───────────────────────────────────────────────
step "[2/9] Installing Node.js ${NODE_VERSION} LTS via NodeSource..."
apt-get install -y -q curl ca-certificates gnupg git

curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash -
apt-get install -y -q nodejs
ok "Node.js $(node --version) | npm $(npm --version)"

# ── [3] Install Nginx ────────────────────────────────────────────────────────
step "[3/9] Installing Nginx..."
apt-get install -y -q nginx
systemctl enable nginx
ok "Nginx installed ($(nginx -v 2>&1 | grep -oP 'nginx/[\d.]+' || echo 'nginx'))"

# ── [4] Clone / update repository ────────────────────────────────────────────
step "[4/9] Cloning application repository..."
if [[ -d "${APP_DIR}/.git" ]]; then
    warn "${APP_DIR} exists — pulling latest..."
    git -C "${APP_DIR}" pull --ff-only
else
    git clone "${REPO_URL}" "${APP_DIR}"
fi
ok "Repository at ${APP_DIR}"

# ── [5] Install frontend npm dependencies ────────────────────────────────────
step "[5/9] Installing frontend npm dependencies..."
cd "${APP_DIR}/frontend"
npm install --silent
ok "npm packages installed"

# ── [6] Build React application ──────────────────────────────────────────────
step "[6/9] Building React application with Vite..."
npm run build

[[ -d "${DIST_DIR}" ]] || die "Build failed — dist directory not found at ${DIST_DIR}"
[[ -f "${DIST_DIR}/index.html" ]] || die "Build failed — index.html not found in ${DIST_DIR}"

DIST_SIZE=$(du -sh "${DIST_DIR}" | cut -f1)
ok "Build complete: ${DIST_DIR} (${DIST_SIZE})"

# ── [7] Configure Nginx ───────────────────────────────────────────────────────
step "[7/9] Writing Nginx configuration..."

cat > "${NGINX_CONF}" <<'NGINXCONF'
##
## Nginx config for BMI Health Tracker frontend
## Serves the React SPA (Vite dist output)
##
## NOTE: /api/* and /health are NOT proxied here.
##       The AWS ALB handles routing those paths to the backend EC2 directly.
##
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root /opt/bmi-app/frontend/dist;
    index index.html;

    server_name _;

    # React SPA — all unknown paths fall back to index.html so React Router works
    location / {
        try_files $uri $uri/ /index.html;
    }

    # Static asset caching (JS, CSS, fonts, images)
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot|map)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        try_files $uri =404;
    }

    # Security headers
    add_header X-Frame-Options          "SAMEORIGIN"                    always;
    add_header X-Content-Type-Options   "nosniff"                       always;
    add_header X-XSS-Protection         "1; mode=block"                 always;
    add_header Referrer-Policy          "strict-origin-when-cross-origin" always;

    # Gzip compression
    gzip            on;
    gzip_vary       on;
    gzip_proxied    any;
    gzip_comp_level 6;
    gzip_types
        text/plain text/css application/json
        application/javascript text/xml application/xml
        text/javascript image/svg+xml;
    gzip_min_length 1024;

    # Logs
    access_log /var/log/nginx/bmi-access.log;
    error_log  /var/log/nginx/bmi-error.log warn;
}
NGINXCONF

ok "Nginx config written to ${NGINX_CONF}"

# ── [8] Enable site + restart Nginx ──────────────────────────────────────────
step "[8/9] Enabling Nginx site and restarting..."

# Disable default site if present
rm -f /etc/nginx/sites-enabled/default

# Enable bmi site
ln -sf "${NGINX_CONF}" /etc/nginx/sites-enabled/bmi

# Test configuration syntax
nginx -t

systemctl restart nginx
ok "Nginx restarted with bmi site enabled"

# ── [9] File permissions ──────────────────────────────────────────────────────
step "[9/9] Setting web root file permissions..."
chown -R www-data:www-data "${DIST_DIR}"
find "${DIST_DIR}" -type d -exec chmod 755 {} \;
find "${DIST_DIR}" -type f -exec chmod 644 {} \;
ok "Permissions set (www-data ownership, 755 dirs, 644 files)"

# ── Health check ─────────────────────────────────────────────────────────────
step "Running health check..."
MAX_RETRIES=6
for i in $(seq 1 $MAX_RETRIES); do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/ 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" == "200" ]]; then
        ok "Nginx health check passed (HTTP $HTTP_CODE)"
        break
    fi
    if [[ $i -eq $MAX_RETRIES ]]; then
        warn "Health check response: HTTP $HTTP_CODE"
        echo "--- Nginx error log (last 20 lines) ---"
        tail -20 /var/log/nginx/bmi-error.log 2>/dev/null || true
        echo "--- Nginx config test ---"
        nginx -T 2>&1 | tail -20 || true
        die "Nginx health check failed. Review output above."
    fi
    echo "    Attempt $i/$MAX_RETRIES — waiting 3s (HTTP $HTTP_CODE)..."
    sleep 3
done

# ── Summary ──────────────────────────────────────────────────────────────────
PRIVATE_IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}  FRONTEND SETUP COMPLETE${NC}"
echo -e "${GREEN}================================================================${NC}"
echo ""
echo "  React app served by Nginx on : ${PRIVATE_IP}:80"
echo "  Build directory              : ${DIST_DIR}"
echo "  Nginx site config            : ${NGINX_CONF}"
echo "  Access log                   : /var/log/nginx/bmi-access.log"
echo "  Error log                    : /var/log/nginx/bmi-error.log"
echo ""
echo "  ALB routing:"
echo "    /* (default rule)  → This server (port 80)"
echo "    /api/*             → Backend server (port 3000) — handled by ALB"
echo "    /health            → Backend server (port 3000) — handled by ALB"
echo ""
echo "  Final URL: https://bmi.ostaddevops.click"
echo ""
echo "  Nginx commands:"
echo "    systemctl status nginx"
echo "    systemctl restart nginx"
echo "    nginx -t               # test config syntax"
echo ""
