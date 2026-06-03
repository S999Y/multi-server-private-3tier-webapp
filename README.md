# BMI & Health Tracker — 3-Tier AWS Private Subnet Deployment

> A production-grade, three-tier web application for tracking Body Mass Index, Basal Metabolic Rate, and daily calorie requirements — deployed on AWS EC2 private instances behind an Application Load Balancer with HTTPS, Route53 DNS, and AWS SSM-based access.

[![AWS](https://img.shields.io/badge/Cloud-AWS-orange?logo=amazon-aws)](https://aws.amazon.com)
[![Node.js](https://img.shields.io/badge/Backend-Node.js%2020-green?logo=node.js)](https://nodejs.org)
[![React](https://img.shields.io/badge/Frontend-React%2018-blue?logo=react)](https://reactjs.org)
[![PostgreSQL](https://img.shields.io/badge/Database-PostgreSQL%2016-blue?logo=postgresql)](https://www.postgresql.org)
[![Nginx](https://img.shields.io/badge/Server-Nginx-green?logo=nginx)](https://nginx.org)

---

## Table of Contents

- [Project Overview](#project-overview)
- [Architecture Overview](#architecture-overview)
- [Tech Stack](#tech-stack)
- [Folder Structure](#folder-structure)
- [Application Workflow](#application-workflow)
- [API Reference](#api-reference)
- [Environment Variables](#environment-variables)
- [Prerequisites](#prerequisites)
- [Local Development Setup](#local-development-setup)
- [Build and Run Instructions](#build-and-run-instructions)
- [Production Deployment](#production-deployment)
- [CI/CD Pipeline](#cicd-pipeline)
- [Monitoring and Logging](#monitoring-and-logging)
- [Security Best Practices Applied](#security-best-practices-applied)
- [Troubleshooting](#troubleshooting)
- [Future Improvements](#future-improvements)
- [Contributing](#contributing)
- [License](#license)

---

## Project Overview

The **BMI & Health Tracker** is a full-stack web application that allows users to:

- Enter body measurements (weight, height, age, sex, activity level)
- Automatically calculate **BMI**, **BMI category**, **Basal Metabolic Rate (BMR)**, and **daily calorie needs** using the Mifflin-St Jeor formula
- Store all measurements persistently in a PostgreSQL database
- View a **30-day BMI trend chart** (Chart.js line graph)
- Review a history of past measurements

The project is purpose-built to demonstrate **multi-server three-tier application deployment** on AWS using industry best practices: private-subnet EC2 instances, a managed load balancer with TLS termination, NAT Gateway for outbound-only internet access, and AWS SSM for zero-bastion host access.

**Live URL:** `https://bmi.ostaddevops.click`  
**Repository:** `https://github.com/sarowar-alam/multi-server-private-3tier-webapp`

---

## Architecture Overview

```
                        ┌──────────────────────────────────────┐
                        │         Internet (Users)              │
                        └──────────────┬───────────────────────┘
                                       │ HTTPS :443 / HTTP :80
                        ┌──────────────▼───────────────────────┐
                        │   Route53 — bmi.ostaddevops.click     │
                        │     (A alias record → ALB DNS)        │
                        └──────────────┬───────────────────────┘
                                       │
                        ┌──────────────▼───────────────────────┐
                        │   Application Load Balancer (ALB)    │
                        │   internet-facing | ACM TLS cert      │
                        │   Public Subnet 1a + Public Subnet 1b│
                        │                                       │
                        │  HTTP :80  → 301 redirect to HTTPS   │
                        │  HTTPS :443 listener rules:           │
                        │    /api/*   → Backend TG  :3000      │
                        │    /health  → Backend TG  :3000      │
                        │    /*       → Frontend TG :80        │
                        └────────┬──────────────┬──────────────┘
                                 │              │
                   HTTP :80      │              │  HTTP :3000
              ┌──────────────────▼─┐  ┌─────────▼──────────────────┐
              │    Frontend EC2    │  │       Backend EC2           │
              │    Nginx :80       │  │   Node.js + PM2 :3000       │
              │    React SPA       │  │   Express REST API           │
              │    10.0.2.x        │  │   10.0.2.y                  │
              │  (Private Subnet)  │  │  (Private Subnet)           │
              └────────────────────┘  └────────────┬────────────────┘
                                                   │ TCP :5432
                                      ┌────────────▼────────────────┐
                                      │        DB EC2               │
                                      │   PostgreSQL 16 :5432       │
                                      │   database: bmidb           │
                                      │   user:     bmi_user        │
                                      │   10.0.2.z                  │
                                      │  (Private Subnet)           │
                                      └─────────────────────────────┘

                    All EC2 instances → NAT Gateway → Internet
                         (for apt, npm, git, SSM agent)
```

### Network Layout

| Resource | CIDR / AZ | Purpose |
|---|---|---|
| VPC | `10.0.0.0/16` | Isolated network |
| Public Subnet 1 | `10.0.1.0/24` — `ap-south-1a` | NAT Gateway + ALB |
| Public Subnet 2 | `10.0.3.0/24` — `ap-south-1b` | ALB (2nd AZ requirement) |
| Private Subnet | `10.0.2.0/24` — `ap-south-1a` | All 3 EC2 instances |

### Why Private Subnets?

All application servers are in a private subnet with **no direct internet inbound access**. Inbound traffic is only accepted from the ALB security group. This means:

- No EC2 public IP is exposed
- No SSH port (22) is open — access is via **AWS SSM Session Manager**
- The database is only reachable from the backend security group — not from the internet or the frontend

---

## Tech Stack

### Frontend

| Technology | Version | Role |
|---|---|---|
| React | 18.2 | UI framework |
| Vite | 5.0 | Build tool + dev server |
| axios | 1.4 | HTTP client for API calls |
| Chart.js | 4.4 | BMI trend line chart |
| react-chartjs-2 | 5.2 | React wrapper for Chart.js |
| Nginx | 1.24 | Static file server (production) |

### Backend

| Technology | Version | Role |
|---|---|---|
| Node.js | 20 LTS | JavaScript runtime |
| Express | 4.18 | HTTP framework / REST API |
| pg (node-postgres) | 8.10 | PostgreSQL driver + connection pool |
| dotenv | 16 | Environment variable loading |
| cors | 2.8 | Cross-Origin Resource Sharing |
| body-parser | 1.20 | JSON request body parsing |
| PM2 | latest | Process manager, auto-restart, systemd |

### Database

| Technology | Version | Role |
|---|---|---|
| PostgreSQL | 16 | Relational database |

### Infrastructure

| Technology | Purpose |
|---|---|
| AWS EC2 (t3.medium) | Compute — 3 private instances |
| AWS ALB | Load balancer, TLS termination, HTTP→HTTPS redirect |
| AWS ACM | Managed TLS certificate |
| AWS Route53 | DNS hosted zone + alias A record |
| AWS NAT Gateway | Outbound internet for private EC2s |
| AWS IAM | SSM instance role (`AmazonSSMManagedInstanceCore`) |
| AWS SSM Session Manager | Secure shell access — no bastion host, no port 22 |
| PowerShell 7 | Infrastructure automation (`setup-aws.ps1`) |
| Bash | Server configuration scripts |

---

## Folder Structure

```
multi-server-private-3tier-webapp/
│
├── backend/                        # Node.js Express API
│   ├── ecosystem.config.js         # PM2 process manager configuration
│   ├── package.json                # Node.js dependencies
│   ├── migrations/
│   │   ├── 001_create_measurements.sql   # Initial schema + indexes
│   │   └── 002_add_measurement_date.sql  # Idempotent column migration
│   └── src/
│       ├── server.js               # Express app entry point, CORS, middleware
│       ├── routes.js               # API route handlers (measurements CRUD)
│       ├── db.js                   # PostgreSQL connection pool
│       └── calculations.js         # BMI, BMR, calorie calculation logic
│
├── frontend/                       # React + Vite application
│   ├── index.html                  # HTML entry point
│   ├── package.json                # Frontend dependencies
│   ├── vite.config.js              # Vite config — dev proxy for /api
│   └── src/
│       ├── main.jsx                # React 18 createRoot entry
│       ├── App.jsx                 # Root component — layout, state, data fetching
│       ├── api.js                  # Axios instance — base URL, interceptors
│       ├── index.css               # Global styles
│       └── components/
│           ├── MeasurementForm.jsx # Input form — weight, height, age, sex, activity
│           └── TrendChart.jsx      # 30-day BMI line chart (Chart.js)
│
├── database/
│   └── setup-database.sh           # Reference DB setup script
│
├── deploy/                         # All deployment automation
│   ├── setup-aws.ps1               # PowerShell: full AWS infra creation + teardown
│   ├── DB-auto.sh                  # Bash: PostgreSQL setup on DB EC2
│   ├── backend-auto.sh             # Bash: Node.js + PM2 setup on Backend EC2
│   ├── frontend-auto.sh            # Bash: React build + Nginx on Frontend EC2
│   ├── DEPLOYMENT-GUIDE-AUTO.md   # Deployment guide (automated via setup-aws.ps1)
│   └── DEPLOYMENT-GUIDE-MANUAL.md # Deployment guide (manual AWS CLI, no PowerShell required)
│
└── README.md                       # This file
```

---

## Application Workflow

### BMI Calculation Logic

The backend uses the **Mifflin-St Jeor formula** for BMR:

```
Male:   BMR = (10 × weight_kg) + (6.25 × height_cm) − (5 × age) + 5
Female: BMR = (10 × weight_kg) + (6.25 × height_cm) − (5 × age) − 161
```

**Daily Calorie Multipliers:**

| Activity Level | Multiplier |
|---|---|
| Sedentary | 1.2 |
| Light | 1.375 |
| Moderate | 1.55 |
| Active | 1.725 |
| Very Active | 1.9 |

**BMI Categories:**

| BMI Range | Category |
|---|---|
| < 18.5 | Underweight |
| 18.5 – 24.9 | Normal |
| 25.0 – 29.9 | Overweight |
| ≥ 30.0 | Obese |

### Request Flow (Production)

```
Browser
  │ POST https://bmi.ostaddevops.click/api/measurements
  ▼
Route53 → ALB (TLS terminates here)
  │ ALB rule: /api/* → Backend Target Group :3000
  ▼
Backend EC2 (Node.js :3000)
  │ calculateMetrics() → INSERT INTO measurements
  ▼
DB EC2 (PostgreSQL :5432)
  │ returns saved row
  ▼
Backend EC2 → ALB → Browser
  ✓ 201 Created with measurement JSON
```

---

## API Reference

**Base URL (production):** `https://bmi.ostaddevops.click`  
**Base URL (development):** `http://localhost:3000`

### Endpoints

| Method | Path | Description | Request Body |
|---|---|---|---|
| `GET` | `/health` | Health check | — |
| `POST` | `/api/measurements` | Create measurement | `weightKg`, `heightCm`, `age`, `sex`, `activity`, `measurementDate` (optional) |
| `GET` | `/api/measurements` | Get all measurements | — |
| `GET` | `/api/measurements/trends` | 30-day BMI trend averages | — |

### `POST /api/measurements` — Request Body

```json
{
  "weightKg": 75,
  "heightCm": 175,
  "age": 30,
  "sex": "male",
  "activity": "moderate",
  "measurementDate": "2026-06-03"
}
```

**Required fields:** `weightKg`, `heightCm`, `age`, `sex`  
**`activity` values:** `sedentary` | `light` | `moderate` | `active` | `very_active`  
**`sex` values:** `male` | `female`

### `POST /api/measurements` — Response (201 Created)

```json
{
  "measurement": {
    "id": 1,
    "weight_kg": "75.00",
    "height_cm": "175.00",
    "age": 30,
    "sex": "male",
    "activity_level": "moderate",
    "bmi": "24.5",
    "bmi_category": "Normal",
    "bmr": 1731,
    "daily_calories": 2683,
    "measurement_date": "2026-06-03",
    "created_at": "2026-06-03T10:30:00.000Z"
  }
}
```

### `GET /api/measurements/trends` — Response

```json
{
  "rows": [
    { "day": "2026-05-15", "avg_bmi": "24.3" },
    { "day": "2026-05-20", "avg_bmi": "24.1" }
  ]
}
```

---

## Environment Variables

### Backend — `/opt/bmi-app/backend/.env` (production)

| Variable | Required | Example Value | Description |
|---|---|---|---|
| `NODE_ENV` | Yes | `production` | Switches CORS mode to production |
| `PORT` | No | `3000` | Express listen port (default: `3000`) |
| `DATABASE_URL` | Yes | `postgresql://bmi_user:pass@10.0.2.z:5432/bmidb` | PostgreSQL connection string |
| `FRONTEND_URL` | Yes (prod) | `https://bmi.ostaddevops.click` | Allowed CORS origin in production |

**File permissions:** `.env` is created with mode `600` (readable by root only).

### Frontend

No `.env` file is needed. The React app uses the relative URL `/api` for all API calls:

- **Development:** Vite dev server proxies `/api` → `http://localhost:3000` (configured in `vite.config.js`)
- **Production:** The ALB routes `/api/*` to the backend EC2 directly — Nginx on the frontend EC2 does **not** proxy API requests

### Database (setup-time variables)

| Variable | Where Used | Description |
|---|---|---|
| `DB_PASSWORD` | `DB-auto.sh`, `backend-auto.sh` | Password for `bmi_user` PostgreSQL account |
| `DB_PRIVATE_IP` | `backend-auto.sh` | Private IP of the DB EC2 (e.g. `10.0.2.z`) |

> **Security:** These are set as shell environment variables (`export`) immediately before running the script. They are never committed to the repository or written to any persistent file (except `DATABASE_URL` in `.env` on the backend EC2).

---

## Prerequisites

### Local Machine

| Tool | Minimum Version | Check |
|---|---|---|
| AWS CLI | v2.x | `aws --version` |
| PowerShell | 7.x | `$PSVersionTable.PSVersion` |
| Git | any | `git --version` |
| Node.js | 20 LTS | `node --version` (local dev only) |

### AWS Account

| Item | Notes |
|---|---|
| IAM user/role | Needs EC2, ELB, Route53, IAM, SSM permissions |
| Named profile `sarowar-ostad` | Configured in `~/.aws/credentials` |
| Key pair `sarowar-ostad-mumbai` | Must exist in `ap-south-1` |
| ACM Certificate | `arn:aws:acm:ap-south-1:388779989543:certificate/c5e5f2a5-c678-4799-b355-765c13584fe0` — status must be `ISSUED` |
| Domain `ostaddevops.click` | Registered at a domain registrar (NS records will be updated to Route53) |

Verify profile and connectivity:

```powershell
aws configure list --profile sarowar-ostad
aws sts get-caller-identity --profile sarowar-ostad
```

Verify certificate:

```powershell
aws acm describe-certificate `
  --certificate-arn "arn:aws:acm:ap-south-1:388779989543:certificate/c5e5f2a5-c678-4799-b355-765c13584fe0" `
  --query "Certificate.Status" --output text `
  --profile sarowar-ostad --region ap-south-1
# Expected: ISSUED
```

---

## Local Development Setup

### 1. Clone the Repository

```bash
git clone https://github.com/sarowar-alam/multi-server-private-3tier-webapp.git
cd multi-server-private-3tier-webapp
```

### 2. Start PostgreSQL Locally

Using an existing local PostgreSQL installation:

```bash
psql -U postgres -c "CREATE USER bmi_user WITH PASSWORD 'localpassword';"
psql -U postgres -c "CREATE DATABASE bmidb OWNER bmi_user;"
psql -U bmi_user -d bmidb -f backend/migrations/001_create_measurements.sql
psql -U bmi_user -d bmidb -f backend/migrations/002_add_measurement_date.sql
```

Or using Docker:

```bash
docker run -d \
  --name bmi-postgres \
  -e POSTGRES_USER=bmi_user \
  -e POSTGRES_PASSWORD=localpassword \
  -e POSTGRES_DB=bmidb \
  -p 5432:5432 \
  postgres:16
```

Then run migrations:

```bash
docker exec -i bmi-postgres psql -U bmi_user -d bmidb \
  < backend/migrations/001_create_measurements.sql
docker exec -i bmi-postgres psql -U bmi_user -d bmidb \
  < backend/migrations/002_add_measurement_date.sql
```

### 3. Configure Backend Environment

```bash
cd backend
cat > .env <<EOF
NODE_ENV=development
PORT=3000
DATABASE_URL=postgresql://bmi_user:localpassword@localhost:5432/bmidb
EOF
```

### 4. Install Dependencies

```bash
# Backend
cd backend
npm install

# Frontend
cd ../frontend
npm install
```

### 5. Start Both Servers

In two separate terminals:

```bash
# Terminal 1 — Backend
cd backend
npm run dev
# Output: Server running on port 3000

# Terminal 2 — Frontend
cd frontend
npm run dev
# Output: Vite dev server at http://localhost:5173
```

Open `http://localhost:5173` in your browser. The Vite dev server proxies `/api` requests to the backend at `localhost:3000`.

---

## Build and Run Instructions

### Backend (Production)

```bash
cd backend
npm install --omit=dev       # production-only packages
pm2 start ecosystem.config.js
pm2 save
pm2 status                   # verify bmi-backend is online
```

### Frontend (Production Build)

```bash
cd frontend
npm install
npm run build                # outputs to frontend/dist/
```

The `dist/` directory contains the optimised static bundle served by Nginx.

### Running in Production Without PM2 (manual)

```bash
cd backend
NODE_ENV=production \
DATABASE_URL=postgresql://bmi_user:pass@<db-ip>:5432/bmidb \
FRONTEND_URL=https://bmi.ostaddevops.click \
node src/server.js
```

---

## Production Deployment

Two step-by-step guides are available in the `deploy/` directory depending on your preference:

| Guide | Approach | Infra creation |
|---|---|---|
| [`deploy/DEPLOYMENT-GUIDE-AUTO.md`](deploy/DEPLOYMENT-GUIDE-AUTO.md) | Automated | Single PowerShell script (`setup-aws.ps1`) creates everything in ~10 min |
| [`deploy/DEPLOYMENT-GUIDE-MANUAL.md`](deploy/DEPLOYMENT-GUIDE-MANUAL.md) | Manual CLI | Step-by-step `aws` CLI commands, no `.ps1` required |

Both guides cover the same 3-tier architecture and result in an identical running deployment. Phases 2–5 (DB, Backend, Frontend, DNS) are identical in both.

### High-Level Steps

#### Step 1 — Create AWS Infrastructure

**Automated (recommended):**
```powershell
cd deploy
.\setup-aws.ps1
# Runs for ~10 minutes
# Note the printed: EC2 private IPs, ALB DNS, Route53 NS records
```

This creates: VPC → Internet Gateway → 3 subnets → route tables → NAT Gateway → 4 security groups → IAM SSM role → 3 EC2 instances → 2 target groups → ALB with listeners → Route53 hosted zone + A record.

All resource IDs are saved to `deploy/aws-deploy-state.json`.

**Manual:** Follow Phase 1 in [`deploy/DEPLOYMENT-GUIDE-MANUAL.md`](deploy/DEPLOYMENT-GUIDE-MANUAL.md) — runs the same 15 infrastructure steps as individual `aws` CLI commands.

#### Step 2 — Configure the Database EC2

Connect via SSM Session Manager:

```powershell
aws ssm start-session --target <db-instance-id> \
  --profile sarowar-ostad --region ap-south-1
```

Inside the session:

```bash
export DB_PASSWORD='YourStr0ngP@ssword'
curl -fsSL https://raw.githubusercontent.com/sarowar-alam/multi-server-private-3tier-webapp/main/deploy/DB-auto.sh -o /tmp/DB-auto.sh
sudo -E bash /tmp/DB-auto.sh
# Note the printed DB private IP and DATABASE_URL at the end
```

**What it does:** Installs PostgreSQL 16, configures `listen_addresses`, `pg_hba.conf`, creates `bmi_user`/`bmidb`, runs both SQL migrations.

#### Step 3 — Configure the Backend EC2

```powershell
aws ssm start-session --target <backend-instance-id> \
  --profile sarowar-ostad --region ap-south-1
```

```bash
export DB_PASSWORD='YourStr0ngP@ssword'
export DB_PRIVATE_IP='10.0.2.z'   # from Step 2 output
curl -fsSL https://raw.githubusercontent.com/sarowar-alam/multi-server-private-3tier-webapp/main/deploy/backend-auto.sh -o /tmp/backend-auto.sh
sudo -E bash /tmp/backend-auto.sh
```

**What it does:** Installs Node.js 20, PM2, clones repo, runs `npm install --omit=dev`, writes `.env`, starts app with PM2, configures PM2 systemd startup, verifies `/health` responds HTTP 200.

#### Step 4 — Configure the Frontend EC2

```powershell
aws ssm start-session --target <frontend-instance-id> \
  --profile sarowar-ostad --region ap-south-1
```

```bash
curl -fsSL https://raw.githubusercontent.com/sarowar-alam/multi-server-private-3tier-webapp/main/deploy/frontend-auto.sh -o /tmp/frontend-auto.sh
sudo bash /tmp/frontend-auto.sh
```

**What it does:** Installs Node.js 20 + Nginx, clones repo, runs Vite build, writes Nginx SPA config (with security headers and gzip), enables site, verifies HTTP 200.

#### Step 5 — Update Domain Registrar NS Records

The PowerShell script prints 4 nameservers. At your domain registrar (where `ostaddevops.click` is registered), replace the existing NS records with these Route53 nameservers. DNS propagation takes 5–60 minutes.

#### Step 6 — Verify

```powershell
# Health check (before DNS propagation — use ALB DNS)
curl -k https://<alb-dns>/health

# After DNS propagation
curl https://bmi.ostaddevops.click/health
# Expected: {"status":"ok","environment":"production"}
```

Then browse `https://bmi.ostaddevops.click` and verify the full application.

### Teardown

**Automated (if infra was created with `setup-aws.ps1`):**
```powershell
.\setup-aws.ps1 -Teardown
# Prompts: "Type 'yes' to confirm"
# Destroys all created AWS resources in reverse order (~8 min)
```

**Manual:** Follow Section 14 in [`deploy/DEPLOYMENT-GUIDE-MANUAL.md`](deploy/DEPLOYMENT-GUIDE-MANUAL.md).

---

## CI/CD Pipeline

### Current State

The deployment pipeline is currently **manual** — all server configuration is done through the bash scripts in `deploy/` executed via AWS SSM Session Manager. The PowerShell script (`setup-aws.ps1`) fully automates infrastructure provisioning.

### Planned: GitHub Actions + Self-Hosted Runner

A GitHub Actions pipeline with a self-hosted runner is the natural next step for this project. The runner would be installed on a dedicated EC2 instance in the private subnet with access to all three application servers via SSM.

#### Recommended Workflow Structure

```
.github/
└── workflows/
    ├── ci.yml              # Run on every push/PR — lint, test, build check
    └── deploy.yml          # Run on push to main — deploy to production EC2s
```

#### `ci.yml` — Continuous Integration (every push)

```yaml
name: CI

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

jobs:
  backend-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '20' }
      - run: cd backend && npm ci
      - run: cd backend && node -e "require('./src/calculations.js')"

  frontend-build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '20' }
      - run: cd frontend && npm ci
      - run: cd frontend && npm run build
```

#### `deploy.yml` — Continuous Deployment (push to main)

```yaml
name: Deploy to Production

on:
  push:
    branches: [main]

jobs:
  deploy-backend:
    runs-on: self-hosted           # runner on private EC2
    steps:
      - uses: actions/checkout@v4
      - name: Deploy backend via SSM
        run: |
          aws ssm send-command \
            --instance-ids "${{ secrets.BACKEND_INSTANCE_ID }}" \
            --document-name "AWS-RunShellScript" \
            --parameters 'commands=["cd /opt/bmi-app && git pull && cd backend && npm install --omit=dev && pm2 reload bmi-backend"]' \
            --region ap-south-1

  deploy-frontend:
    runs-on: self-hosted
    needs: deploy-backend
    steps:
      - uses: actions/checkout@v4
      - name: Deploy frontend via SSM
        run: |
          aws ssm send-command \
            --instance-ids "${{ secrets.FRONTEND_INSTANCE_ID }}" \
            --document-name "AWS-RunShellScript" \
            --parameters 'commands=["cd /opt/bmi-app && git pull && cd frontend && npm install && npm run build && sudo chown -R www-data:www-data dist/"]' \
            --region ap-south-1
```

#### Self-Hosted Runner Setup

The runner EC2 needs:

1. GitHub Actions runner software installed (from your GitHub repo → Settings → Actions → Runners → New self-hosted runner)
2. AWS CLI installed and configured with an IAM role that allows `ssm:SendCommand` on the target instances
3. The runner EC2 placed in the private subnet with SSM access to the other instances

```bash
# On the runner EC2 (one-time setup)
mkdir actions-runner && cd actions-runner
curl -o actions-runner-linux-x64.tar.gz -L \
  https://github.com/actions/runner/releases/download/v2.x.x/actions-runner-linux-x64-2.x.x.tar.gz
tar xzf ./actions-runner-linux-x64.tar.gz
./config.sh --url https://github.com/sarowar-alam/multi-server-private-3tier-webapp \
  --token <TOKEN_FROM_GITHUB>
sudo ./svc.sh install
sudo ./svc.sh start
```

#### Required GitHub Secrets

| Secret Name | Value |
|---|---|
| `BACKEND_INSTANCE_ID` | EC2 instance ID of the backend server |
| `FRONTEND_INSTANCE_ID` | EC2 instance ID of the frontend server |
| `DB_INSTANCE_ID` | EC2 instance ID of the DB server |

---

## Monitoring and Logging

### Application Logs (Backend)

PM2 manages log rotation and structured output. Log files are on the Backend EC2:

| File | Contents |
|---|---|
| `/opt/bmi-app/backend/logs/out.log` | stdout (application output) |
| `/opt/bmi-app/backend/logs/err.log` | stderr (errors) |
| `/opt/bmi-app/backend/logs/combined.log` | Both streams with timestamps |

```bash
# Via SSM on Backend EC2
pm2 logs bmi-backend              # live stream
pm2 logs bmi-backend --lines 100  # last 100 lines
pm2 monit                         # live CPU/memory dashboard
```

PM2 log format includes timestamps (`YYYY-MM-DD HH:mm:ss Z`) for each entry.

### Web Server Logs (Frontend)

Nginx logs are on the Frontend EC2:

```bash
# Via SSM on Frontend EC2
tail -f /var/log/nginx/bmi-access.log   # HTTP access log
tail -f /var/log/nginx/bmi-error.log    # Nginx errors
```

### Database Logs

PostgreSQL logs on the DB EC2:

```bash
# Via SSM on DB EC2
tail -f /var/log/postgresql/postgresql-16-main.log
```

### ALB Access Logs

ALB access logging can be enabled to an S3 bucket via the AWS Console:

1. EC2 → Load Balancers → `bmi-app-alb` → Attributes → Edit
2. Enable Access Logs → specify S3 bucket

### Recommended Monitoring Additions (Future)

- **CloudWatch Agent** on each EC2 — ship system metrics (CPU, memory, disk) and application logs to CloudWatch
- **CloudWatch Alarms** — alert on ALB 5xx error rate, CPU > 80%, unhealthy target count > 0
- **SNS** — send alarm notifications to email or Slack
- **CloudWatch Dashboard** — unified view of all three tiers

---

## Security Best Practices Applied

| Practice | Implementation |
|---|---|
| **No public IP on application servers** | All 3 EC2s are in a private subnet with no internet-inbound access |
| **Principle of least privilege (SGs)** | Each SG allows only the minimum required traffic (ALB → Frontend :80, ALB → Backend :3000, Backend → DB :5432) |
| **No SSH / port 22 open** | Access via AWS SSM Session Manager only — no bastion host required |
| **TLS everywhere** | HTTPS enforced at ALB; HTTP:80 → 301 redirect to HTTPS; ACM-managed certificate |
| **TLS 1.2 minimum** | ALB SSL policy: `ELBSecurityPolicy-TLS-1-2-Ext-2018-06` |
| **DB not reachable from internet** | PostgreSQL SG only accepts connections from `sg-backend` — no internet or frontend path |
| **Parameterised SQL queries** | All database queries use `$1, $2` placeholders — no string concatenation (prevents SQL injection) |
| **Secrets not in code** | All passwords, DB credentials, and connection strings are in environment variables or `.env` files that are never committed |
| **`.env` restricted permissions** | Backend `.env` created with `chmod 600` (owner-read only) |
| **Input validation** | API validates required fields, numeric ranges, and enum values before processing |
| **CORS restricted to known origin** | In production, `CORS` is restricted to `FRONTEND_URL` — not `*` |
| **NAT Gateway for outbound only** | Private EC2s can initiate outbound connections (for apt/npm/git) but cannot receive inbound connections |
| **IAM role — minimum permissions** | EC2 instance profile only has `AmazonSSMManagedInstanceCore` — no other AWS service access |
| **Nginx security headers** | `X-Frame-Options: SAMEORIGIN`, `X-Content-Type-Options: nosniff`, `X-XSS-Protection: 1; mode=block`, `Referrer-Policy: strict-origin-when-cross-origin` |
| **Connection pool limits** | PostgreSQL pool capped at 20 connections; 2-second connection timeout; 30-second idle timeout |
| **Memory limits** | PM2 configured with `max_memory_restart: 500M` to prevent runaway memory consumption |

---

## Troubleshooting

### SSM Session Manager — "Instance not connected"

```powershell
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=<instance-id>" \
  --query "InstanceInformationList[].PingStatus" \
  --output text --profile sarowar-ostad --region ap-south-1
```

- If empty: wait 3–5 minutes after launch — SSM agent bootstrap takes time
- Check the IAM instance profile `bmi-ssm-profile` is attached in EC2 → Instance → Security tab
- Verify outbound internet (NAT Gateway) is working — SSM uses `ssm.ap-south-1.amazonaws.com`

---

### ALB Target Shows "unhealthy"

```powershell
aws elbv2 describe-target-health \
  --target-group-arn "<tg-arn>" \
  --query "TargetHealthDescriptions[].{State:TargetHealth.State,Reason:TargetHealth.Reason,Desc:TargetHealth.Description}" \
  --output table --profile sarowar-ostad --region ap-south-1
```

- `initial` — health checks haven't completed; wait 60 seconds
- `unhealthy` — service not running; run the appropriate setup script
- Manually verify on the EC2: `curl -s http://localhost:3000/health` (backend) or `curl -s http://localhost/` (frontend)

---

### API Returns 500 — Backend Cannot Reach Database

```bash
# On Backend EC2 via SSM
cat /opt/bmi-app/backend/.env         # verify DATABASE_URL
pm2 logs bmi-backend --lines 50       # look for connection refused or auth failed

# Test TCP connectivity to DB
nc -zv <db-private-ip> 5432

# Test psql connection
PGPASSWORD='yourpassword' psql -U bmi_user -d bmidb -h <db-private-ip> -p 5432 -c 'SELECT 1;'
```

Common causes:
- Wrong `DB_PRIVATE_IP` in `.env`
- Wrong `DB_PASSWORD` in `.env`
- PostgreSQL `pg_hba.conf` not updated for `10.0.2.0/24` (re-run `DB-auto.sh`)
- PostgreSQL `listen_addresses` not set to `*` (re-run `DB-auto.sh`)

---

### Frontend Shows Blank Page

```bash
# On Frontend EC2 via SSM
nginx -t                                      # test config syntax
ls -la /opt/bmi-app/frontend/dist/            # verify build exists
cat /etc/nginx/sites-available/bmi | grep try_files
# Must be: try_files $uri $uri/ /index.html;

tail -20 /var/log/nginx/bmi-error.log
```

---

### `https://bmi.ostaddevops.click` Not Resolving

```powershell
# Check DNS resolution
nslookup bmi.ostaddevops.click
Resolve-DnsName bmi.ostaddevops.click

# Check NS delegation
nslookup -type=NS ostaddevops.click

# Test via ALB DNS directly (bypasses DNS propagation)
curl -k -v "https://<alb-dns>/health"
```

DNS propagation can take up to 48 hours. Track progress at https://dnschecker.org

---

### PowerShell Script Fails Mid-Deployment

The script saves state after every step to `deploy/aws-deploy-state.json`. Resources created before the failure are retained. Options:

1. Fix the issue, re-run `.\setup-aws.ps1` (many steps are idempotent)
2. Run `.\setup-aws.ps1 -Teardown` to clean up, then re-run from scratch

---

### PM2 Process Not Starting After Reboot

```bash
# On Backend EC2 via SSM
pm2 status                    # check if bmi-backend is missing
systemctl status pm2-root     # check PM2 systemd service

# If service not active:
pm2 startup systemd -u root --hp /root
# Run the command it outputs, then:
pm2 start /opt/bmi-app/backend/ecosystem.config.js
pm2 save
```

---

## Future Improvements

| Improvement | Priority | Notes |
|---|---|---|
| GitHub Actions CI/CD pipeline | High | Automate deployments on push to `main` using a self-hosted runner in the private subnet |
| AWS Secrets Manager | High | Store `DB_PASSWORD` and `DATABASE_URL` in Secrets Manager — backend fetches at startup instead of `.env` file |
| CloudWatch Agent + Alarms | High | Ship metrics/logs to CloudWatch; alert on 5xx errors, CPU, unhealthy targets |
| Multi-AZ PostgreSQL (RDS) | Medium | Replace self-managed PostgreSQL with Amazon RDS for automatic backups, failover, and patching |
| Auto Scaling Group for frontend/backend | Medium | Add ASGs behind the ALB target groups for horizontal scaling and automatic replacement of failed instances |
| PostgreSQL backup automation | Medium | Schedule `pg_dump` to S3 with lifecycle rules for point-in-time recovery |
| HTTPS between ALB and EC2 | Low | Currently HTTP internally; configure Nginx and Node.js for TLS with self-signed certs for in-VPC encryption |
| VPC Endpoints for SSM | Low | Replace NAT Gateway dependency for SSM with VPC Interface Endpoints — reduces NAT cost and removes SSM from NAT path |
| WAF on ALB | Low | AWS WAF to block OWASP Top 10 threats at the edge |
| Structured logging (JSON) | Low | Update Express to use a structured logger (pino or winston) for easier CloudWatch Insights querying |
| Database connection pooling via PgBouncer | Low | Add PgBouncer on the DB EC2 to pool connections more efficiently for higher concurrency |

---

## Contributing

Contributions are welcome. Please follow these steps:

1. **Fork** the repository and create your branch from `main`:
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes** — ensure you follow the existing code style

3. **Test locally** — start the full stack locally and verify your changes work end-to-end:
   ```bash
   # Backend running on :3000, frontend on :5173
   cd backend && npm run dev &
   cd frontend && npm run dev
   ```

4. **For backend changes** — verify the health check still returns 200 and the API endpoints function correctly

5. **For frontend changes** — verify `npm run build` completes without errors:
   ```bash
   cd frontend && npm run build
   ```

6. **For database changes** — write a new numbered migration file:
   ```
   backend/migrations/003_your_change.sql
   ```
   Make migrations idempotent (`IF NOT EXISTS`, `DO $$ ... $$`) so they can safely re-run.

7. **Submit a pull request** against the `main` branch with:
   - A clear title describing the change
   - A description of what was changed and why
   - Steps to test the change

### Code Style

- Backend: CommonJS (`require`/`module.exports`), no TypeScript — keep consistent with existing files
- Frontend: Functional React components with hooks — no class components
- SQL: Use parameterised queries (`$1`, `$2`) — never string concatenation
- Naming: snake_case for database columns, camelCase for JavaScript variables

---

## License

This project is licensed under the **MIT License**.

```
MIT License

Copyright (c) 2026 Sarowar Alam

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

*Built for the Ostad MasteringDevOps programme — demonstrating production-grade multi-server AWS deployment with private networking, managed TLS, and zero-bastion-host security.*

---

## Project Lead

**MD Sarowar Alam**  
Lead DevOps Engineer, WPP Production  
📧 Email: [sarowar@hotmail.com](mailto:sarowar@hotmail.com)  
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/

---
