#!/bin/bash
# ==============================================================================
# DB-auto.sh — PostgreSQL 16 database setup for BMI Health Tracker
#
# Run on: DB EC2 (bmi-app-db) via AWS SSM Session Manager
# OS    : Ubuntu 24.04 LTS
#
# REQUIRED environment variables (export before running):
#   DB_PASSWORD   — password for the bmi_user PostgreSQL account
#
# Usage:
#   export DB_PASSWORD='YourStr0ngP@ssword'
#   sudo -E bash DB-auto.sh
#
# What this script does:
#   1. System update
#   2. Install PostgreSQL 16 (native in Ubuntu 24.04 repos)
#   3. Configure listen_addresses = '*'
#   4. Configure pg_hba.conf for private subnet (10.0.2.0/24)
#   5. Create database user bmi_user + database bmidb
#   6. Clone repo and run SQL migrations
#   7. Verify schema and print DATABASE_URL for backend-auto.sh
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
step() { echo -e "\n${CYAN}==> $*${NC}"; }
ok()   { echo -e "${GREEN}    [OK]${NC} $*"; }
warn() { echo -e "${YELLOW}    [WARN]${NC} $*"; }
die()  { echo -e "${RED}    [ERROR]${NC} $*" >&2; exit 1; }

# ── Validate environment ────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Run as root or with sudo: sudo -E bash $0"
[[ -z "${DB_PASSWORD:-}" ]]  && die "DB_PASSWORD is not set. Export it before running."
[[ "${DB_PASSWORD}" == "placeholder" || "${DB_PASSWORD}" == "changeme" ]] && \
    die "DB_PASSWORD is still a placeholder value — set a real password."
[[ ${#DB_PASSWORD} -lt 8 ]] && die "DB_PASSWORD must be at least 8 characters."

# ── Configuration ────────────────────────────────────────────────────────────
DB_USER="bmi_user"
DB_NAME="bmidb"
PRIVATE_CIDR="10.0.2.0/24"
REPO_URL="https://github.com/sarowar-alam/multi-server-private-3tier-webapp.git"
APP_DIR="/opt/bmi-app"

step "Starting DB setup | user=$DB_USER db=$DB_NAME subnet=$PRIVATE_CIDR"

# ── [1] System update ────────────────────────────────────────────────────────
step "[1/7] Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -q
apt-get upgrade -y -q -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
ok "System updated"

# ── [2] Install PostgreSQL 16 ────────────────────────────────────────────────
step "[2/7] Installing PostgreSQL 16..."
apt-get install -y -q postgresql postgresql-contrib
systemctl enable postgresql
systemctl start postgresql
PG_VER=$(psql --version | grep -oP '\d+' | head -1)
ok "PostgreSQL $PG_VER installed and running"

# Locate config files dynamically (version-independent)
PG_CONF=$(find /etc/postgresql -name "postgresql.conf" | sort | tail -1)
PG_HBA=$(find /etc/postgresql  -name "pg_hba.conf"    | sort | tail -1)
PG_DATA=$(dirname "$PG_CONF")
[[ -z "$PG_CONF" ]] && die "Could not locate postgresql.conf"
ok "Config: $PG_CONF"

# ── [3] Configure listen_addresses ───────────────────────────────────────────
step "[3/7] Configuring PostgreSQL to listen on all interfaces..."
# Update or add listen_addresses
if grep -qE "^#?listen_addresses" "$PG_CONF"; then
    sed -i "s/^#\?listen_addresses\s*=.*/listen_addresses = '*'/" "$PG_CONF"
else
    echo "listen_addresses = '*'" >> "$PG_CONF"
fi
ok "listen_addresses = '*' set in $PG_CONF"

# ── [4] Configure pg_hba.conf ────────────────────────────────────────────────
step "[4/7] Configuring pg_hba.conf for private subnet access..."

# Remove any previously added bmi_user lines (idempotent re-runs)
sed -i "/# BMI App private subnet/d" "$PG_HBA"
sed -i "/bmi_user/d"                 "$PG_HBA"

cat >> "$PG_HBA" <<EOF

# BMI App private subnet — added by DB-auto.sh
host    ${DB_NAME}    ${DB_USER}    ${PRIVATE_CIDR}    scram-sha-256
EOF
ok "pg_hba.conf updated: ${DB_USER}@${PRIVATE_CIDR} → scram-sha-256"

# Restart to apply both config changes
systemctl restart postgresql
ok "PostgreSQL restarted"

# ── [5] Create DB user and database ──────────────────────────────────────────
step "[5/7] Creating database user '${DB_USER}' and database '${DB_NAME}'..."

# Create or update user password
sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
        CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD}';
        RAISE NOTICE 'Role ${DB_USER} created.';
    ELSE
        ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';
        RAISE NOTICE 'Role ${DB_USER} password updated.';
    END IF;
END
\$\$;
SQL

# Create database if it doesn't exist
sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
SELECT 'CREATE DATABASE ${DB_NAME} OWNER ${DB_USER}'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${DB_NAME}')
\gexec
SQL

ok "Database '${DB_NAME}' ready, owned by '${DB_USER}'"

# ── [6] Clone repo and run migrations ───────────────────────────────────────
step "[6/7] Cloning repository and running migrations..."
apt-get install -y -q git

if [[ -d "${APP_DIR}/.git" ]]; then
    warn "${APP_DIR} already exists — pulling latest..."
    git -C "${APP_DIR}" pull --ff-only
else
    git clone "${REPO_URL}" "${APP_DIR}"
fi
ok "Repository at ${APP_DIR}"

MIGRATION_DIR="${APP_DIR}/backend/migrations"
[[ -f "${MIGRATION_DIR}/001_create_measurements.sql" ]] || die "Migration 001 not found at ${MIGRATION_DIR}"
[[ -f "${MIGRATION_DIR}/002_add_measurement_date.sql" ]] || die "Migration 002 not found at ${MIGRATION_DIR}"

export PGPASSWORD="${DB_PASSWORD}"
psql -U "${DB_USER}" -d "${DB_NAME}" -h 127.0.0.1 -p 5432 \
     -f "${MIGRATION_DIR}/001_create_measurements.sql" -v ON_ERROR_STOP=1
ok "Migration 001_create_measurements applied"

psql -U "${DB_USER}" -d "${DB_NAME}" -h 127.0.0.1 -p 5432 \
     -f "${MIGRATION_DIR}/002_add_measurement_date.sql" -v ON_ERROR_STOP=1
ok "Migration 002_add_measurement_date applied"
unset PGPASSWORD

# ── [7] Verify schema ────────────────────────────────────────────────────────
step "[7/7] Verifying database schema..."
PGPASSWORD="${DB_PASSWORD}" psql -U "${DB_USER}" -d "${DB_NAME}" -h 127.0.0.1 -p 5432 -c "\dt measurements"
TABLE_COUNT=$(PGPASSWORD="${DB_PASSWORD}" psql -U "${DB_USER}" -d "${DB_NAME}" -h 127.0.0.1 -p 5432 \
    -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='measurements';")
[[ "$TABLE_COUNT" == "1" ]] || die "measurements table not found after migration!"
ok "measurements table exists and schema is valid"

# ── Summary ──────────────────────────────────────────────────────────────────
PRIVATE_IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}  DATABASE SETUP COMPLETE${NC}"
echo -e "${GREEN}================================================================${NC}"
echo ""
echo "  Host    : ${PRIVATE_IP}"
echo "  Port    : 5432"
echo "  Database: ${DB_NAME}"
echo "  User    : ${DB_USER}"
echo ""
echo -e "  ${CYAN}DATABASE_URL for backend-auto.sh:${NC}"
echo -e "  ${YELLOW}postgresql://${DB_USER}:${DB_PASSWORD}@${PRIVATE_IP}:5432/${DB_NAME}${NC}"
echo ""
echo -e "  ${CYAN}When running backend-auto.sh, export:${NC}"
echo "    export DB_PRIVATE_IP='${PRIVATE_IP}'"
echo "    export DB_PASSWORD='${DB_PASSWORD}'"
echo ""
echo "  PostgreSQL service status:"
systemctl is-active postgresql && echo "    postgresql: active" || echo "    postgresql: INACTIVE"
echo ""
