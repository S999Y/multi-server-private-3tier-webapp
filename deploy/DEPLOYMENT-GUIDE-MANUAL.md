# BMI Health Tracker — Full AWS Deployment Guide (Manual CLI)

> **Approach:** Creates all AWS infrastructure using individual `aws` CLI commands — no PowerShell script required.  
> For the automated single-command approach using `setup-aws.ps1`, see [`DEPLOYMENT-GUIDE-AUTO.md`](DEPLOYMENT-GUIDE-AUTO.md).

**Application:** BMI & Health Tracker (React → Node.js/Express → PostgreSQL)  
**Domain:** `bmi.ostaddevops.click`  
**Region:** `ap-south-1` (Mumbai)  
**AWS Profile:** `sarowar-ostad`  
**Repository:** https://github.com/sarowar-alam/multi-server-private-3tier-webapp.git

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Network & Infrastructure Design](#3-network--infrastructure-design)
4. [Security Group Rules](#4-security-group-rules)
5. [Deployment Files Reference](#5-deployment-files-reference)
6. [Phase 1 — Create AWS Infrastructure (Manual CLI)](#6-phase-1--create-aws-infrastructure-manual-cli)
7. [Phase 2 — Database Server Setup (DB-auto.sh)](#7-phase-2--database-server-setup-db-autosh)
8. [Phase 3 — Backend Server Setup (backend-auto.sh)](#8-phase-3--backend-server-setup-backend-autosh)
9. [Phase 4 — Frontend Server Setup (frontend-auto.sh)](#9-phase-4--frontend-server-setup-frontend-autosh)
10. [Phase 5 — Domain & DNS Configuration](#10-phase-5--domain--dns-configuration)
11. [Verification & Testing](#11-verification--testing)
12. [Application Flow Explained](#12-application-flow-explained)
13. [Operational Reference](#13-operational-reference)
14. [Teardown / Cleanup](#14-teardown--cleanup)
15. [Troubleshooting](#15-troubleshooting)

---

## 1. Architecture Overview

```
Internet
    │
    │  HTTPS :443 (TLS terminated at ALB using ACM cert)
    │  HTTP  :80  → 301 redirect to HTTPS
    ▼
┌─────────────────────────────────────────────────────────┐
│  Route53 — bmi.ostaddevops.click (A alias → ALB DNS)    │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│  Application Load Balancer (internet-facing)            │
│  Public Subnet ap-south-1a  +  Public Subnet ap-south-1b│
│                                                         │
│  Listener rules (HTTPS :443):                           │
│    /api/*   priority 10 → Backend Target Group :3000    │
│    /health  priority 20 → Backend Target Group :3000    │
│    /*       default     → Frontend Target Group :80     │
└──────┬─────────────────────────┬───────────────────────-┘
       │                         │
       │ HTTP :80                │ HTTP :3000
       ▼                         ▼
┌─────────────┐        ┌──────────────────────┐
│ Frontend EC2│        │  Backend EC2          │
│ Nginx :80   │        │  Node.js + PM2 :3000  │
│ React SPA   │        │  Express API          │
│ 10.0.2.x    │        │  10.0.2.y             │
│             │        │         │             │
└─────────────┘        └─────────┼─────────────┘
                                 │ TCP :5432
                                 ▼
                       ┌──────────────────────┐
                       │  DB EC2              │
                       │  PostgreSQL 16 :5432 │
                       │  database: bmidb     │
                       │  user:     bmi_user  │
                       │  10.0.2.z            │
                       └──────────────────────┘

All 3 EC2 instances are in the PRIVATE subnet.
They reach the internet (apt, npm, git, SSM) through the NAT Gateway.
```

### Key Design Decisions

| Decision | Reason |
|---|---|
| All EC2s in private subnet | Security — not directly reachable from internet |
| ALB in 2 public subnets | AWS ALB requires at least 2 AZs |
| TLS terminated at ALB | ACM manages cert renewal; EC2s serve plain HTTP internally |
| No `/api` proxy on Nginx | ALB does the routing split — more efficient, one less hop |
| SSM Session Manager | No bastion host, no open port 22; more secure access |
| NAT Gateway | Private EC2s need outbound internet for package installs |
| PostgreSQL 16 | Native in Ubuntu 24.04 repos (no extra PPA needed) |
| PM2 for Node.js | Auto-restart on crash, systemd integration, structured logging |

---

## 2. Prerequisites

### 2.1 Local Machine Requirements

| Tool | Minimum Version | Install |
|---|---|---|
| AWS CLI | v2.x | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| PowerShell | 5.1+ or 7.x | Built into Windows; 7.x recommended |
| Git | any | https://git-scm.com/ |

> **Note:** PowerShell 7 is recommended but not strictly required. All commands in Phase 1 use the `aws` CLI with PowerShell variables and work on both 5.1 and 7.x. No `.ps1` script files are needed.

### 2.2 AWS CLI Named Profile

These manual steps use the named profile `sarowar-ostad`. Verify it exists:

```powershell
aws configure list --profile sarowar-ostad
```

Expected output shows `access_key`, `secret_key`, and `region`. If missing, configure it:

```powershell
aws configure --profile sarowar-ostad
# AWS Access Key ID:     <your-key>
# AWS Secret Access Key: <your-secret>
# Default region name:   ap-south-1
# Default output format: json
```

Verify connectivity:

```powershell
aws sts get-caller-identity --profile sarowar-ostad
```

This should return your AWS account ID and IAM user/role ARN.

### 2.3 EC2 Key Pair

These steps use the key pair `sarowar-ostad-mumbai`. Verify it exists in `ap-south-1`:

```powershell
aws ec2 describe-key-pairs --key-names sarowar-ostad-mumbai `
  --profile sarowar-ostad --region ap-south-1
```

If it doesn't exist, create one:

```powershell
aws ec2 create-key-pair --key-name sarowar-ostad-mumbai `
  --query "KeyMaterial" --output text `
  --profile sarowar-ostad --region ap-south-1 > sarowar-ostad-mumbai.pem
```

> **Note:** The key pair is attached as an emergency fallback. Actual access is via SSM Session Manager — no port 22 is opened.

### 2.4 ACM Certificate

The certificate must already exist in `ap-south-1` (it does — provided in requirements):

```
arn:aws:acm:ap-south-1:388779989543:certificate/c5e5f2a5-c678-4799-b355-765c13584fe0
```

Verify its status:

```powershell
aws acm describe-certificate `
  --certificate-arn "arn:aws:acm:ap-south-1:388779989543:certificate/c5e5f2a5-c678-4799-b355-765c13584fe0" `
  --query "Certificate.Status" --output text `
  --profile sarowar-ostad --region ap-south-1
```

Expected: `ISSUED`

### 2.5 Required IAM Permissions for the Deploying User

Your `sarowar-ostad` IAM user/role needs permissions for:

- `ec2:*` (VPC, subnets, SGs, instances, IGW, NAT, route tables, EIP)
- `elasticloadbalancing:*` (ALB, listeners, target groups)
- `route53:*` (hosted zones, records)
- `iam:CreateRole`, `iam:AttachRolePolicy`, `iam:CreateInstanceProfile`, `iam:AddRoleToInstanceProfile`, `iam:PassRole`
- `ssm:GetParameter` (to fetch Ubuntu AMI ID)

---

## 3. Network & Infrastructure Design

### 3.1 VPC Layout

```
VPC: 10.0.0.0/16  (bmi-app-vpc)
│
├── Public Subnet 1   ap-south-1a   10.0.1.0/24  (bmi-app-pub-1a)
│   ├── NAT Gateway (+ Elastic IP)
│   └── ALB (shared with public-2)
│
├── Public Subnet 2   ap-south-1b   10.0.3.0/24  (bmi-app-pub-1b)
│   └── ALB (2nd AZ — AWS ALB requirement)
│
└── Private Subnet    ap-south-1a   10.0.2.0/24  (bmi-app-priv-1a)
    ├── Frontend EC2  (bmi-app-frontend)
    ├── Backend EC2   (bmi-app-backend)
    └── DB EC2        (bmi-app-db)
```

### 3.2 Route Tables

**Public Route Table** (associated with both public subnets):
| Destination | Target |
|---|---|
| 10.0.0.0/16 | local |
| 0.0.0.0/0 | Internet Gateway |

**Private Route Table** (associated with private subnet):
| Destination | Target |
|---|---|
| 10.0.0.0/16 | local |
| 0.0.0.0/0 | NAT Gateway |

### 3.3 EC2 Instance Specifications

| Instance | Name Tag | Subnet | SG | Storage |
|---|---|---|---|---|
| Frontend | bmi-app-frontend | private | sg-frontend | 20 GB gp3 |
| Backend | bmi-app-backend | private | sg-backend | 20 GB gp3 |
| Database | bmi-app-db | private | sg-db | 30 GB gp3 |

All instances: `t3.medium`, Ubuntu 24.04 LTS, key pair `sarowar-ostad-mumbai`, IAM profile with `AmazonSSMManagedInstanceCore`.

---

## 4. Security Group Rules

### sg-alb (ALB Security Group)

| Direction | Protocol | Port | Source | Purpose |
|---|---|---|---|---|
| Inbound | TCP | 80 | 0.0.0.0/0 | HTTP from internet |
| Inbound | TCP | 443 | 0.0.0.0/0 | HTTPS from internet |
| Outbound | All | All | 0.0.0.0/0 | ALB to targets |

### sg-frontend (Frontend EC2)

| Direction | Protocol | Port | Source | Purpose |
|---|---|---|---|---|
| Inbound | TCP | 80 | sg-alb | HTTP from ALB only |
| Outbound | All | All | 0.0.0.0/0 | Outbound via NAT |

### sg-backend (Backend EC2)

| Direction | Protocol | Port | Source | Purpose |
|---|---|---|---|---|
| Inbound | TCP | 3000 | sg-alb | API from ALB only |
| Outbound | All | All | 0.0.0.0/0 | Outbound via NAT |

### sg-db (DB EC2)

| Direction | Protocol | Port | Source | Purpose |
|---|---|---|---|---|
| Inbound | TCP | 5432 | sg-backend | PostgreSQL from backend only |
| Outbound | All | All | 0.0.0.0/0 | Outbound via NAT |

> **Security note:** The DB server is only reachable from the backend server. There is no path from the internet or the frontend to PostgreSQL directly.

---

## 5. Deployment Files Reference

All files are in the `deploy/` folder of the repository:

```
deploy/
├── DB-auto.sh                 # Bash: PostgreSQL setup on DB EC2            ← used by this guide
├── backend-auto.sh            # Bash: Node.js + PM2 setup on Backend EC2    ← used by this guide
├── frontend-auto.sh           # Bash: React build + Nginx setup on Frontend ← used by this guide
├── DEPLOYMENT-GUIDE-MANUAL.md # This file — manual AWS CLI infra, no PS1 required
└── DEPLOYMENT-GUIDE-AUTO.md   # Alternative guide — automated via setup-aws.ps1
```

> **Note:** `setup-aws.ps1` is not used in this guide. All infrastructure is created with individual `aws` CLI commands in Phase 1.

---

## 6. Phase 1 — Create AWS Infrastructure (Manual CLI)

### 6.1 What Gets Created

This phase creates all AWS infrastructure through 15 sequential steps:

1. Fetch Ubuntu 24.04 LTS AMI ID
2. VPC `10.0.0.0/16`
3. Internet Gateway → attached to VPC
4. 3 subnets (2 public, 1 private)
5. Public route table → `0.0.0.0/0 → IGW` → associated with both public subnets
6. Elastic IP → NAT Gateway in Public Subnet 1 → waits for `available` (~2 min)
7. Private route table → `0.0.0.0/0 → NAT GW` → associated with private subnet
8. 4 security groups with ingress rules
9. IAM role `bmi-ssm-role` + instance profile
10. 3 EC2 instances in private subnet → waits for `running`
11. 2 Target Groups + register EC2s
12. ALB → waits for `active` (~2 min)
13. HTTP:80 listener (301 redirect) + HTTPS:443 listener with path rules
14. Route53 hosted zone + A alias record
15. Resource summary — note all IDs for subsequent phases

**Estimated time:** ~10–15 minutes (most is waiting for NAT GW and ALB).

### 6.2 Important: Keep Your Terminal Open

All Phase 1 commands store resource IDs in PowerShell variables (e.g., `$VPC_ID`, `$NAT_ID`).  
**Run all 15 steps in the same PowerShell terminal session.** If you close the terminal, the variables are lost — you will need to look up IDs manually from the AWS Console or CLI.

At the end of Step 15, record all values in the summary table — you will need them for teardown.

---

### 6.3 Step 1 — Fetch Ubuntu 24.04 LTS AMI

```powershell
$AMI_ID = aws ssm get-parameter `
  --name "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id" `
  --query "Parameter.Value" --output text `
  --profile sarowar-ostad --region ap-south-1

Write-Host "AMI: $AMI_ID"
```

Expected output: `AMI: ami-0xxxxxxxxxxxxxxxx`

---

### 6.4 Step 2 — Create VPC

```powershell
$VPC_ID = aws ec2 create-vpc `
  --cidr-block 10.0.0.0/16 `
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=bmi-app-vpc}]' `
  --query "Vpc.VpcId" --output text `
  --profile sarowar-ostad --region ap-south-1

# Enable DNS hostnames (required for SSM)
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames `
  --profile sarowar-ostad --region ap-south-1
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support `
  --profile sarowar-ostad --region ap-south-1

Write-Host "VPC: $VPC_ID"
```

---

### 6.5 Step 3 — Create Internet Gateway

```powershell
$IGW_ID = aws ec2 create-internet-gateway `
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=bmi-app-igw}]' `
  --query "InternetGateway.InternetGatewayId" --output text `
  --profile sarowar-ostad --region ap-south-1

aws ec2 attach-internet-gateway `
  --internet-gateway-id $IGW_ID --vpc-id $VPC_ID `
  --profile sarowar-ostad --region ap-south-1

Write-Host "IGW: $IGW_ID"
```

---

### 6.6 Step 4 — Create Subnets

```powershell
# Public Subnet 1 — ap-south-1a (NAT GW + ALB)
$PUB1_ID = aws ec2 create-subnet `
  --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 `
  --availability-zone ap-south-1a `
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=bmi-app-pub-1a}]' `
  --query "Subnet.SubnetId" --output text `
  --profile sarowar-ostad --region ap-south-1

# Public Subnet 2 — ap-south-1b (ALB 2nd AZ only)
$PUB2_ID = aws ec2 create-subnet `
  --vpc-id $VPC_ID --cidr-block 10.0.3.0/24 `
  --availability-zone ap-south-1b `
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=bmi-app-pub-1b}]' `
  --query "Subnet.SubnetId" --output text `
  --profile sarowar-ostad --region ap-south-1

# Private Subnet — ap-south-1a (all 3 EC2s)
$PRIV_ID = aws ec2 create-subnet `
  --vpc-id $VPC_ID --cidr-block 10.0.2.0/24 `
  --availability-zone ap-south-1a `
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=bmi-app-priv-1a}]' `
  --query "Subnet.SubnetId" --output text `
  --profile sarowar-ostad --region ap-south-1

Write-Host "Subnets: pub1=$PUB1_ID  pub2=$PUB2_ID  priv=$PRIV_ID"
```

---

### 6.7 Step 5 — Public Route Table

```powershell
$PUB_RT_ID = aws ec2 create-route-table --vpc-id $VPC_ID `
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=bmi-app-pub-rt}]' `
  --query "RouteTable.RouteTableId" --output text `
  --profile sarowar-ostad --region ap-south-1

# Add default route to Internet Gateway
aws ec2 create-route --route-table-id $PUB_RT_ID `
  --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID `
  --profile sarowar-ostad --region ap-south-1 | Out-Null

# Associate with both public subnets
aws ec2 associate-route-table --route-table-id $PUB_RT_ID --subnet-id $PUB1_ID `
  --profile sarowar-ostad --region ap-south-1 | Out-Null
aws ec2 associate-route-table --route-table-id $PUB_RT_ID --subnet-id $PUB2_ID `
  --profile sarowar-ostad --region ap-south-1 | Out-Null

Write-Host "Public RT: $PUB_RT_ID"
```

---

### 6.8 Step 6 — NAT Gateway (waits ~2 min)

```powershell
# Allocate Elastic IP
$EIP_ALLOC = aws ec2 allocate-address --domain vpc `
  --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=bmi-app-eip}]' `
  --query "AllocationId" --output text `
  --profile sarowar-ostad --region ap-south-1

# Create NAT Gateway in public subnet 1
$NAT_ID = aws ec2 create-nat-gateway `
  --subnet-id $PUB1_ID --allocation-id $EIP_ALLOC `
  --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=bmi-app-nat}]' `
  --query "NatGateway.NatGatewayId" --output text `
  --profile sarowar-ostad --region ap-south-1

Write-Host "NAT Gateway $NAT_ID created. Waiting for 'available' state (~2 min)..."
aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_ID `
  --profile sarowar-ostad --region ap-south-1
Write-Host "NAT Gateway: $NAT_ID  EIP: $EIP_ALLOC"
```

---

### 6.9 Step 7 — Private Route Table

```powershell
$PRIV_RT_ID = aws ec2 create-route-table --vpc-id $VPC_ID `
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=bmi-app-priv-rt}]' `
  --query "RouteTable.RouteTableId" --output text `
  --profile sarowar-ostad --region ap-south-1

# Add default route to NAT Gateway
aws ec2 create-route --route-table-id $PRIV_RT_ID `
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_ID `
  --profile sarowar-ostad --region ap-south-1 | Out-Null

# Associate with private subnet
aws ec2 associate-route-table --route-table-id $PRIV_RT_ID --subnet-id $PRIV_ID `
  --profile sarowar-ostad --region ap-south-1 | Out-Null

Write-Host "Private RT: $PRIV_RT_ID"
```

---

### 6.10 Step 8 — Security Groups

```powershell
# ── sg-alb ──────────────────────────────────────────────────────────────────
$SG_ALB = aws ec2 create-security-group `
  --group-name bmi-app-sg-alb --description "BMI App ALB" --vpc-id $VPC_ID `
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=sg-alb}]' `
  --query "GroupId" --output text `
  --profile sarowar-ostad --region ap-south-1

aws ec2 authorize-security-group-ingress --group-id $SG_ALB `
  --ip-permissions '[{"IpProtocol":"tcp","FromPort":80,"ToPort":80,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]},{"IpProtocol":"tcp","FromPort":443,"ToPort":443,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' `
  --profile sarowar-ostad --region ap-south-1 | Out-Null

# ── sg-frontend ──────────────────────────────────────────────────────────────
$SG_FE = aws ec2 create-security-group `
  --group-name bmi-app-sg-frontend --description "BMI Frontend EC2" --vpc-id $VPC_ID `
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=sg-frontend}]' `
  --query "GroupId" --output text `
  --profile sarowar-ostad --region ap-south-1

@"
[{"IpProtocol":"tcp","FromPort":80,"ToPort":80,"UserIdGroupPairs":[{"GroupId":"$SG_ALB"}]}]
"@ | Out-File "$env:TEMP\sg-fe.json" -Encoding ascii
aws ec2 authorize-security-group-ingress --group-id $SG_FE `
  --ip-permissions "file://$env:TEMP\sg-fe.json" `
  --profile sarowar-ostad --region ap-south-1 | Out-Null

# ── sg-backend ───────────────────────────────────────────────────────────────
$SG_BE = aws ec2 create-security-group `
  --group-name bmi-app-sg-backend --description "BMI Backend EC2" --vpc-id $VPC_ID `
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=sg-backend}]' `
  --query "GroupId" --output text `
  --profile sarowar-ostad --region ap-south-1

@"
[{"IpProtocol":"tcp","FromPort":3000,"ToPort":3000,"UserIdGroupPairs":[{"GroupId":"$SG_ALB"}]}]
"@ | Out-File "$env:TEMP\sg-be.json" -Encoding ascii
aws ec2 authorize-security-group-ingress --group-id $SG_BE `
  --ip-permissions "file://$env:TEMP\sg-be.json" `
  --profile sarowar-ostad --region ap-south-1 | Out-Null

# ── sg-db ────────────────────────────────────────────────────────────────────
$SG_DB = aws ec2 create-security-group `
  --group-name bmi-app-sg-db --description "BMI DB EC2" --vpc-id $VPC_ID `
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=sg-db}]' `
  --query "GroupId" --output text `
  --profile sarowar-ostad --region ap-south-1

@"
[{"IpProtocol":"tcp","FromPort":5432,"ToPort":5432,"UserIdGroupPairs":[{"GroupId":"$SG_BE"}]}]
"@ | Out-File "$env:TEMP\sg-db.json" -Encoding ascii
aws ec2 authorize-security-group-ingress --group-id $SG_DB `
  --ip-permissions "file://$env:TEMP\sg-db.json" `
  --profile sarowar-ostad --region ap-south-1 | Out-Null

Write-Host "SGs: alb=$SG_ALB  fe=$SG_FE  be=$SG_BE  db=$SG_DB"
```

---

### 6.11 Step 9 — IAM Role + Instance Profile

```powershell
# Trust policy — allows EC2 to assume the role
@'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
'@ | Out-File "$env:TEMP\trust.json" -Encoding ascii

aws iam create-role --role-name bmi-ssm-role `
  --assume-role-policy-document "file://$env:TEMP\trust.json" `
  --profile sarowar-ostad | Out-Null

aws iam attach-role-policy --role-name bmi-ssm-role `
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore `
  --profile sarowar-ostad

aws iam create-instance-profile `
  --instance-profile-name bmi-ssm-profile `
  --profile sarowar-ostad | Out-Null

aws iam add-role-to-instance-profile `
  --instance-profile-name bmi-ssm-profile --role-name bmi-ssm-role `
  --profile sarowar-ostad

# Wait for IAM propagation before launching EC2s
Write-Host "Waiting 15s for IAM profile to propagate..."
Start-Sleep -Seconds 15
Write-Host "IAM: role=bmi-ssm-role  profile=bmi-ssm-profile"
```

---

### 6.12 Step 10 — Launch EC2 Instances

```powershell
# SSM agent bootstrap user data (ensures SSM agent is running on Ubuntu 24.04)
$USER_DATA = @"
#!/bin/bash
snap install amazon-ssm-agent --classic
systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent
systemctl start  snap.amazon-ssm-agent.amazon-ssm-agent
"@
$USER_DATA_B64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($USER_DATA))

# ── Frontend EC2 ─────────────────────────────────────────────────────────────
$FRONTEND_ID = aws ec2 run-instances `
  --image-id $AMI_ID --instance-type t3.medium `
  --subnet-id $PRIV_ID --security-group-ids $SG_FE `
  --iam-instance-profile Name=bmi-ssm-profile `
  --key-name sarowar-ostad-mumbai `
  --user-data $USER_DATA_B64 `
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":20,"VolumeType":"gp3"}}]' `
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=bmi-app-frontend}]' `
  --query "Instances[0].InstanceId" --output text `
  --profile sarowar-ostad --region ap-south-1

# ── Backend EC2 ──────────────────────────────────────────────────────────────
$BACKEND_ID = aws ec2 run-instances `
  --image-id $AMI_ID --instance-type t3.medium `
  --subnet-id $PRIV_ID --security-group-ids $SG_BE `
  --iam-instance-profile Name=bmi-ssm-profile `
  --key-name sarowar-ostad-mumbai `
  --user-data $USER_DATA_B64 `
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":20,"VolumeType":"gp3"}}]' `
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=bmi-app-backend}]' `
  --query "Instances[0].InstanceId" --output text `
  --profile sarowar-ostad --region ap-south-1

# ── Database EC2 ─────────────────────────────────────────────────────────────
$DB_ID = aws ec2 run-instances `
  --image-id $AMI_ID --instance-type t3.medium `
  --subnet-id $PRIV_ID --security-group-ids $SG_DB `
  --iam-instance-profile Name=bmi-ssm-profile `
  --key-name sarowar-ostad-mumbai `
  --user-data $USER_DATA_B64 `
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}}]' `
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=bmi-app-db}]' `
  --query "Instances[0].InstanceId" --output text `
  --profile sarowar-ostad --region ap-south-1

Write-Host "Instances launched: frontend=$FRONTEND_ID  backend=$BACKEND_ID  db=$DB_ID"
Write-Host "Waiting for all instances to reach 'running' state..."

aws ec2 wait instance-running `
  --instance-ids $FRONTEND_ID $BACKEND_ID $DB_ID `
  --profile sarowar-ostad --region ap-south-1

# Retrieve private IPs
$FRONTEND_IP = aws ec2 describe-instances --instance-ids $FRONTEND_ID `
  --query "Reservations[0].Instances[0].PrivateIpAddress" --output text `
  --profile sarowar-ostad --region ap-south-1
$BACKEND_IP = aws ec2 describe-instances --instance-ids $BACKEND_ID `
  --query "Reservations[0].Instances[0].PrivateIpAddress" --output text `
  --profile sarowar-ostad --region ap-south-1
$DB_IP = aws ec2 describe-instances --instance-ids $DB_ID `
  --query "Reservations[0].Instances[0].PrivateIpAddress" --output text `
  --profile sarowar-ostad --region ap-south-1

Write-Host "Running. IPs: frontend=$FRONTEND_IP  backend=$BACKEND_IP  db=$DB_IP"
```

---

### 6.13 Step 11 — Create Target Groups

```powershell
# Frontend Target Group — port 80, health check /
$TG_FE_ARN = aws elbv2 create-target-group `
  --name bmi-app-tg-frontend --protocol HTTP --port 80 `
  --vpc-id $VPC_ID --target-type instance `
  --health-check-path "/" --health-check-interval-seconds 30 `
  --healthy-threshold-count 2 --unhealthy-threshold-count 3 `
  --query "TargetGroups[0].TargetGroupArn" --output text `
  --profile sarowar-ostad --region ap-south-1

# Backend Target Group — port 3000, health check /health
$TG_BE_ARN = aws elbv2 create-target-group `
  --name bmi-app-tg-backend --protocol HTTP --port 3000 `
  --vpc-id $VPC_ID --target-type instance `
  --health-check-path "/health" --health-check-interval-seconds 30 `
  --healthy-threshold-count 2 --unhealthy-threshold-count 3 `
  --query "TargetGroups[0].TargetGroupArn" --output text `
  --profile sarowar-ostad --region ap-south-1

# Register EC2 instances to their target groups
aws elbv2 register-targets --target-group-arn $TG_FE_ARN `
  --targets Id=$FRONTEND_ID `
  --profile sarowar-ostad --region ap-south-1
aws elbv2 register-targets --target-group-arn $TG_BE_ARN `
  --targets Id=$BACKEND_ID `
  --profile sarowar-ostad --region ap-south-1

Write-Host "Target Groups: fe=$TG_FE_ARN"
Write-Host "               be=$TG_BE_ARN"
```

---

### 6.14 Step 12 — Create ALB (waits ~2 min)

```powershell
$ALB_ARN = aws elbv2 create-load-balancer `
  --name bmi-app-alb `
  --subnets $PUB1_ID $PUB2_ID `
  --security-groups $SG_ALB `
  --scheme internet-facing --type application `
  --query "LoadBalancers[0].LoadBalancerArn" --output text `
  --profile sarowar-ostad --region ap-south-1

$ALB_DNS = aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN `
  --query "LoadBalancers[0].DNSName" --output text `
  --profile sarowar-ostad --region ap-south-1

$ALB_HZ = aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN `
  --query "LoadBalancers[0].CanonicalHostedZoneId" --output text `
  --profile sarowar-ostad --region ap-south-1

Write-Host "ALB created. Waiting for 'active' state (~2 min)..."
aws elbv2 wait load-balancer-available --load-balancer-arns $ALB_ARN `
  --profile sarowar-ostad --region ap-south-1

Write-Host "ALB: $ALB_ARN"
Write-Host "ALB DNS: $ALB_DNS"
```

---

### 6.15 Step 13 — ALB Listeners + Path Rules

```powershell
$CERT_ARN = "arn:aws:acm:ap-south-1:388779989543:certificate/c5e5f2a5-c678-4799-b355-765c13584fe0"

# HTTP:80 listener → 301 redirect to HTTPS
$HTTP_LISTENER = aws elbv2 create-listener `
  --load-balancer-arn $ALB_ARN `
  --protocol HTTP --port 80 `
  --default-actions 'Type=redirect,RedirectConfig={Protocol=HTTPS,Port=443,StatusCode=HTTP_301}' `
  --query "Listeners[0].ListenerArn" --output text `
  --profile sarowar-ostad --region ap-south-1

# HTTPS:443 listener → default action: forward to Frontend TG
$HTTPS_LISTENER = aws elbv2 create-listener `
  --load-balancer-arn $ALB_ARN `
  --protocol HTTPS --port 443 `
  --certificates "CertificateArn=$CERT_ARN" `
  --ssl-policy ELBSecurityPolicy-TLS-1-2-Ext-2018-06 `
  --default-actions "Type=forward,TargetGroupArn=$TG_FE_ARN" `
  --query "Listeners[0].ListenerArn" --output text `
  --profile sarowar-ostad --region ap-south-1

# Path rule: /api/* → Backend TG (priority 10)
aws elbv2 create-rule `
  --listener-arn $HTTPS_LISTENER --priority 10 `
  --conditions 'Field=path-pattern,Values=["/api/*"]' `
  --actions "Type=forward,TargetGroupArn=$TG_BE_ARN" `
  --profile sarowar-ostad --region ap-south-1 | Out-Null

# Path rule: /health → Backend TG (priority 20)
aws elbv2 create-rule `
  --listener-arn $HTTPS_LISTENER --priority 20 `
  --conditions 'Field=path-pattern,Values=["/health"]' `
  --actions "Type=forward,TargetGroupArn=$TG_BE_ARN" `
  --profile sarowar-ostad --region ap-south-1 | Out-Null

Write-Host "Listeners: http=$HTTP_LISTENER"
Write-Host "           https=$HTTPS_LISTENER"
```

---

### 6.16 Step 14 — Route53 Hosted Zone + DNS Record

```powershell
# Create hosted zone for ostaddevops.click
$HZ_RESULT = aws route53 create-hosted-zone `
  --name ostaddevops.click `
  --caller-reference "bmi-app-$(Get-Date -Format 'yyyyMMddHHmmss')" `
  --output json --profile sarowar-ostad | ConvertFrom-Json

$HZ_ID    = $HZ_RESULT.HostedZone.Id
$NS_RECS  = $HZ_RESULT.DelegationSet.NameServers

Write-Host "Hosted Zone: $HZ_ID"
Write-Host "NS Records (update at your domain registrar):"
$NS_RECS | ForEach-Object { Write-Host "  $_" }

# Create A alias record: bmi.ostaddevops.click → ALB
@"
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "bmi.ostaddevops.click",
      "Type": "A",
      "AliasTarget": {
        "HostedZoneId": "$ALB_HZ",
        "DNSName": "dualstack.$ALB_DNS",
        "EvaluateTargetHealth": true
      }
    }
  }]
}
"@ | Out-File "$env:TEMP\r53-change.json" -Encoding ascii

aws route53 change-resource-record-sets `
  --hosted-zone-id $HZ_ID `
  --change-batch "file://$env:TEMP\r53-change.json" `
  --profile sarowar-ostad | Out-Null

Write-Host "Route53 A record: bmi.ostaddevops.click → $ALB_DNS"
```

---

### 6.17 Step 15 — Resource Summary

Copy the output of this command and save it somewhere safe — you'll need these IDs for teardown:

```powershell
Write-Host ""
Write-Host "============================================================"
Write-Host "  PHASE 1 COMPLETE — RECORD THESE VALUES"
Write-Host "============================================================"
Write-Host ""
Write-Host "  AMI ID          : $AMI_ID"
Write-Host "  VPC ID          : $VPC_ID"
Write-Host "  IGW ID          : $IGW_ID"
Write-Host "  Public Subnet 1 : $PUB1_ID  (10.0.1.0/24, ap-south-1a)"
Write-Host "  Public Subnet 2 : $PUB2_ID  (10.0.3.0/24, ap-south-1b)"
Write-Host "  Private Subnet  : $PRIV_ID  (10.0.2.0/24, ap-south-1a)"
Write-Host "  Public RT       : $PUB_RT_ID"
Write-Host "  Private RT      : $PRIV_RT_ID"
Write-Host "  EIP Allocation  : $EIP_ALLOC"
Write-Host "  NAT Gateway     : $NAT_ID"
Write-Host "  SG ALB          : $SG_ALB"
Write-Host "  SG Frontend     : $SG_FE"
Write-Host "  SG Backend      : $SG_BE"
Write-Host "  SG DB           : $SG_DB"
Write-Host "  Frontend EC2    : $FRONTEND_ID  (IP: $FRONTEND_IP)"
Write-Host "  Backend EC2     : $BACKEND_ID   (IP: $BACKEND_IP)"
Write-Host "  DB EC2          : $DB_ID        (IP: $DB_IP)"
Write-Host "  TG Frontend     : $TG_FE_ARN"
Write-Host "  TG Backend      : $TG_BE_ARN"
Write-Host "  ALB ARN         : $ALB_ARN"
Write-Host "  ALB DNS         : $ALB_DNS"
Write-Host "  ALB HZ ID       : $ALB_HZ"
Write-Host "  HTTP Listener   : $HTTP_LISTENER"
Write-Host "  HTTPS Listener  : $HTTPS_LISTENER"
Write-Host "  Hosted Zone     : $HZ_ID"
Write-Host ""
Write-Host "  !!! UPDATE YOUR DOMAIN REGISTRAR for ostaddevops.click !!!"
Write-Host "  Set these 4 NS records at your registrar:"
$NS_RECS | ForEach-Object { Write-Host "      $_" }
Write-Host ""
Write-Host "  Next steps: Run Phases 2-4 on each EC2 via SSM Session Manager"
Write-Host "  SSM access command:"
Write-Host "    aws ssm start-session --target <instance-id> --profile sarowar-ostad --region ap-south-1"
Write-Host "============================================================"
```

### 6.18 Note the Critical Values

| Value | Variable | Where Used |
|---|---|---|
| DB Private IP | `$DB_IP` | `backend-auto.sh` (`DB_PRIVATE_IP`) |
| DB Instance ID | `$DB_ID` | SSM start-session |
| Backend Instance ID | `$BACKEND_ID` | SSM start-session |
| Frontend Instance ID | `$FRONTEND_ID` | SSM start-session |
| Route53 NS Records (4) | `$NS_RECS` | Domain registrar |
| ALB DNS | `$ALB_DNS` | Testing before DNS propagates |

---

## 7. Phase 2 — Database Server Setup (DB-auto.sh)

### 7.1 What It Does (in order)

1. Validates `DB_PASSWORD` is set, non-placeholder, and ≥ 8 characters
2. Runs `apt-get update && apt-get upgrade`
3. Installs `postgresql` + `postgresql-contrib` (PostgreSQL 16 from Ubuntu 24.04 repos)
4. Enables and starts the PostgreSQL service
5. Locates `postgresql.conf` and `pg_hba.conf` dynamically (version-independent)
6. Sets `listen_addresses = '*'` so the backend EC2 can connect
7. Adds `pg_hba.conf` entry: `host bmidb bmi_user 10.0.2.0/24 scram-sha-256`
8. Restarts PostgreSQL to apply changes
9. Creates PostgreSQL role `bmi_user` with provided password (idempotent — updates if exists)
10. Creates database `bmidb` owned by `bmi_user` (idempotent — skips if exists)
11. Installs `git` and clones the repository to `/opt/bmi-app`
12. Runs migration `001_create_measurements.sql` — creates the `measurements` table and indexes
13. Runs migration `002_add_measurement_date.sql` — idempotent, adds `measurement_date` column if missing
14. Verifies the `measurements` table exists
15. Prints the `DATABASE_URL` string to use in `backend-auto.sh`

### 7.2 Accessing the DB EC2 via SSM

#### Method A — SSM Session Manager (AWS Console)

1. Open [AWS Console](https://console.aws.amazon.com) → EC2 → Instances
2. Find `bmi-app-db` → click on its instance ID
3. Click **Connect** → **Session Manager** tab → click **Connect**
4. A browser-based terminal opens

> SSM Session Manager requires the instance to be running and the SSM agent to be registered (this takes ~2–3 minutes after first boot).

#### Method B — AWS CLI Session Manager

```powershell
aws ssm start-session --target $DB_ID `
  --profile sarowar-ostad --region ap-south-1
```

Replace `$DB_ID` with the actual DB instance ID from Phase 1.

### 7.3 Uploading the Script to the EC2

The easiest approach is to use SSM `send-command` to download and run the script directly from GitHub:

```powershell
aws ssm send-command `
  --instance-ids $DB_ID `
  --document-name "AWS-RunShellScript" `
  --parameters "commands=[
    'curl -fsSL https://raw.githubusercontent.com/sarowar-alam/multi-server-private-3tier-webapp/main/deploy/DB-auto.sh -o /tmp/DB-auto.sh',
    'export DB_PASSWORD=''YourStr0ngP@ssword''',
    'sudo -E bash /tmp/DB-auto.sh 2>&1 | tee /tmp/db-setup.log'
  ]" `
  --profile sarowar-ostad --region ap-south-1
```

Then check the output:
```powershell
aws ssm get-command-invocation `
  --command-id "<command-id from above>" `
  --instance-id $DB_ID `
  --query "StandardOutputContent" --output text `
  --profile sarowar-ostad --region ap-south-1
```

#### Alternative — Paste into Session Manager shell

If you prefer the interactive shell (Session Manager terminal):

```bash
# Once in the Session Manager shell:
export DB_PASSWORD='YourStr0ngP@ssword'

curl -fsSL https://raw.githubusercontent.com/sarowar-alam/multi-server-private-3tier-webapp/main/deploy/DB-auto.sh -o /tmp/DB-auto.sh

sudo -E bash /tmp/DB-auto.sh
```

### 7.4 What a Successful Run Looks Like

```
==> [1/7] Updating system packages...
    [OK] System updated

==> [2/7] Installing PostgreSQL 16...
    [OK] PostgreSQL 16 installed and running
    [OK] Config: /etc/postgresql/16/main/postgresql.conf

==> [3/7] Configuring PostgreSQL to listen on all interfaces...
    [OK] listen_addresses = '*' set

==> [4/7] Configuring pg_hba.conf for private subnet access...
    [OK] pg_hba.conf updated: bmi_user@10.0.2.0/24 → scram-sha-256
    [OK] PostgreSQL restarted

==> [5/7] Creating database user 'bmi_user' and database 'bmidb'...
    [OK] Database 'bmidb' ready, owned by 'bmi_user'

==> [6/7] Cloning repository and running migrations...
    [OK] Repository at /opt/bmi-app
    [OK] Migration 001_create_measurements applied
    [OK] Migration 002_add_measurement_date applied

==> [7/7] Verifying database schema...
    [OK] measurements table exists and schema is valid

================================================================
  DATABASE SETUP COMPLETE
================================================================

  Host    : 10.0.2.12
  Database: bmidb
  User    : bmi_user

  DATABASE_URL for backend-auto.sh:
  postgresql://bmi_user:YourStr0ngP@ssword@10.0.2.12:5432/bmidb

  When running backend-auto.sh, export:
    export DB_PRIVATE_IP='10.0.2.12'
    export DB_PASSWORD='YourStr0ngP@ssword'
```

### 7.5 Database Schema Created

The migrations create this table in `bmidb`:

```sql
measurements
├── id              SERIAL PRIMARY KEY
├── weight_kg       NUMERIC(5,2)  NOT NULL  CHECK > 0 and < 1000
├── height_cm       NUMERIC(5,2)  NOT NULL  CHECK > 0 and < 300
├── age             INTEGER       NOT NULL  CHECK > 0 and < 150
├── sex             VARCHAR(10)   NOT NULL  CHECK IN ('male','female')
├── activity_level  VARCHAR(30)             CHECK IN ('sedentary','light','moderate','active','very_active')
├── bmi             NUMERIC(4,1)  NOT NULL
├── bmi_category    VARCHAR(30)
├── bmr             INTEGER
├── daily_calories  INTEGER
├── measurement_date DATE         NOT NULL  DEFAULT CURRENT_DATE
└── created_at      TIMESTAMPTZ  NOT NULL  DEFAULT now()

Indexes:
  idx_measurements_measurement_date ON measurement_date DESC
  idx_measurements_created_at       ON created_at DESC
  idx_measurements_bmi              ON bmi
```

---

## 8. Phase 3 — Backend Server Setup (backend-auto.sh)

### 8.1 What It Does (in order)

1. Validates `DB_PASSWORD` and `DB_PRIVATE_IP` are set
2. Runs `apt-get update && apt-get upgrade`
3. Installs `curl`, `ca-certificates`, `gnupg`
4. Adds NodeSource repository and installs **Node.js 20 LTS**
5. Installs **PM2** globally via npm
6. Clones repository to `/opt/bmi-app` (or pulls if already exists)
7. Runs `npm install --omit=dev` in `/opt/bmi-app/backend`
8. Creates `/opt/bmi-app/backend/.env` with mode `600`:
   ```
   NODE_ENV=production
   PORT=3000
   DATABASE_URL=postgresql://bmi_user:<password>@<db-ip>:5432/bmidb
   FRONTEND_URL=https://bmi.ostaddevops.click
   ```
9. Creates `logs/` directory
10. Starts app with `pm2 start ecosystem.config.js` (uses `ecosystem.config.js` from the repo)
11. Saves PM2 process list with `pm2 save`
12. Configures PM2 to auto-start on reboot via systemd
13. Polls `http://localhost:3000/health` for up to 60 seconds to confirm the app is running

### 8.2 Accessing the Backend EC2 via SSM

Same process as DB EC2, using the backend instance ID:

```powershell
aws ssm start-session --target $BACKEND_ID `
  --profile sarowar-ostad --region ap-south-1
```

### 8.3 Running the Script

```bash
# In the Session Manager shell on the Backend EC2:
export DB_PASSWORD='YourStr0ngP@ssword'
export DB_PRIVATE_IP='10.0.2.12'    # DB private IP from Phase 2 output

curl -fsSL https://raw.githubusercontent.com/sarowar-alam/multi-server-private-3tier-webapp/main/deploy/backend-auto.sh -o /tmp/backend-auto.sh

sudo -E bash /tmp/backend-auto.sh
```

### 8.4 What a Successful Run Looks Like

```
==> [1/8] Updating system packages...
    [OK] System updated

==> [2/8] Installing Node.js 20 LTS via NodeSource...
    [OK] Node.js v20.x.x | npm 10.x.x

==> [3/8] Installing PM2 process manager...
    [OK] PM2 5.x.x installed

==> [4/8] Cloning application repository...
    [OK] Repository at /opt/bmi-app

==> [5/8] Installing backend production dependencies...
    [OK] npm packages installed (production only)

==> [6/8] Writing .env configuration...
    [OK] .env written to /opt/bmi-app/backend/.env (mode 600)

==> [7/8] Starting application with PM2...
[PM2] Starting /opt/bmi-app/backend/ecosystem.config.js
┌────┬───────────────┬─────────────┬─────────┬─────────┐
│ id │ name          │ mode        │ status  │ cpu/mem │
├────┼───────────────┼─────────────┼─────────┼─────────┤
│ 0  │ bmi-backend   │ fork        │ online  │ 0%/50mb │
└────┴───────────────┴─────────────┴─────────┴─────────┘
    [OK] PM2 process 'bmi-backend' started

==> [8/8] Configuring PM2 systemd startup...
    [OK] PM2 startup configured via systemd

==> Running health check (up to 60s)...
    [OK] Health check passed (HTTP 200)

================================================================
  BACKEND SETUP COMPLETE
================================================================

  Node.js API is running on : 10.0.2.11:3000
  Endpoints:
    GET  http://10.0.2.11:3000/health
    POST http://10.0.2.11:3000/api/measurements
    GET  http://10.0.2.11:3000/api/measurements
    GET  http://10.0.2.11:3000/api/measurements/trends
```

### 8.5 PM2 Process Management

After the script runs, you can manage the app directly on the EC2:

```bash
pm2 status                        # show running processes
pm2 logs bmi-backend              # stream live logs
pm2 logs bmi-backend --lines 50   # last 50 log lines
pm2 restart bmi-backend           # restart the process
pm2 stop bmi-backend              # stop the process
pm2 reload bmi-backend            # zero-downtime reload
```

Log files are stored at:
```
/opt/bmi-app/backend/logs/err.log       # stderr
/opt/bmi-app/backend/logs/out.log       # stdout
/opt/bmi-app/backend/logs/combined.log  # both
```

---

## 9. Phase 4 — Frontend Server Setup (frontend-auto.sh)

### 9.1 What It Does (in order)

1. Runs `apt-get update && apt-get upgrade`
2. Installs `curl`, `ca-certificates`, `gnupg`, `git`
3. Adds NodeSource repository and installs **Node.js 20 LTS**
4. Installs **Nginx**
5. Clones repository to `/opt/bmi-app` (or pulls if already exists)
6. Runs `npm install` in `/opt/bmi-app/frontend`
7. Runs `npm run build` (Vite build) — outputs to `/opt/bmi-app/frontend/dist/`
8. Writes Nginx config at `/etc/nginx/sites-available/bmi`:
   - Serves `dist/` directory on port 80
   - `try_files $uri $uri/ /index.html` — React Router SPA support
   - 1-year cache headers for static assets (JS, CSS, images)
   - Security headers (X-Frame-Options, X-Content-Type-Options, etc.)
   - Gzip compression enabled
   - **No `/api` proxy** — ALB handles that routing
9. Removes the default Nginx site, enables the `bmi` site
10. Tests nginx config (`nginx -t`), then restarts Nginx
11. Sets `www-data` ownership on the `dist/` directory
12. Polls `http://localhost/` for a `200` response

### 9.2 Accessing the Frontend EC2 via SSM

```powershell
aws ssm start-session --target $FRONTEND_ID `
  --profile sarowar-ostad --region ap-south-1
```

### 9.3 Running the Script

```bash
# In the Session Manager shell on the Frontend EC2:
curl -fsSL https://raw.githubusercontent.com/sarowar-alam/multi-server-private-3tier-webapp/main/deploy/frontend-auto.sh -o /tmp/frontend-auto.sh

sudo bash /tmp/frontend-auto.sh
```

> No environment variables needed for this script.

### 9.4 What a Successful Run Looks Like

```
==> [1/9] Updating system packages...
    [OK] System updated

==> [2/9] Installing Node.js 20 LTS via NodeSource...
    [OK] Node.js v20.x.x | npm 10.x.x

==> [3/9] Installing Nginx...
    [OK] Nginx installed (nginx/1.24.0)

==> [4/9] Cloning application repository...
    [OK] Repository at /opt/bmi-app

==> [5/9] Installing frontend npm dependencies...
    [OK] npm packages installed

==> [6/9] Building React application with Vite...
✓ built in 12.34s
    [OK] Build complete: /opt/bmi-app/frontend/dist (2.1M)

==> [7/9] Writing Nginx configuration...
    [OK] Nginx config written to /etc/nginx/sites-available/bmi

==> [8/9] Enabling Nginx site and restarting...
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
    [OK] Nginx restarted with bmi site enabled

==> [9/9] Setting web root file permissions...
    [OK] Permissions set (www-data ownership, 755 dirs, 644 files)

==> Running health check...
    [OK] Nginx health check passed (HTTP 200)

================================================================
  FRONTEND SETUP COMPLETE
================================================================

  React app served by Nginx on : 10.0.2.10:80
  Build directory              : /opt/bmi-app/frontend/dist
  Final URL                    : https://bmi.ostaddevops.click
```

### 9.5 Why There Is No /api Proxy in Nginx

In development, `vite.config.js` proxies `/api` to `localhost:3000`. In production, this proxy is not used because:

1. The built React app (in `dist/`) makes API calls to `/api` (relative URL)
2. The browser sends these requests to `https://bmi.ostaddevops.click/api/...`
3. The ALB intercepts at `/api/*` rule → routes to the **Backend EC2 directly** on port 3000
4. The Frontend EC2 (Nginx) never sees `/api` requests in production

This is cleaner, more efficient, and keeps a clear separation between the frontend and backend tiers.

---

## 10. Phase 5 — Domain & DNS Configuration

### 10.1 Update Domain Registrar NS Records

Phase 1 Step 14 created a Route53 hosted zone for `ostaddevops.click` and printed 4 nameservers. You must point your domain registrar to these nameservers.

**Retrieve NS records** (if you need to look them up again):

```powershell
# $HZ_ID must be set from Phase 1, or look it up:
$HZ_ID = aws route53 list-hosted-zones `
  --query "HostedZones[?Name=='ostaddevops.click.'].Id" `
  --output text --profile sarowar-ostad

aws route53 get-hosted-zone --id $HZ_ID `
  --query "DelegationSet.NameServers" `
  --output table --profile sarowar-ostad
```

**At your domain registrar** (wherever you registered `ostaddevops.click`):

1. Log in to your registrar's DNS management panel
2. Find the NS (Nameserver) records for `ostaddevops.click`
3. Replace existing NS records with the 4 Route53 nameservers, e.g.:
   ```
   ns-1234.awsdns-56.com
   ns-789.awsdns-01.net
   ns-234.awsdns-78.org
   ns-567.awsdns-90.co.uk
   ```
4. Save changes

### 10.2 DNS Propagation

- Changes propagate globally in **5 minutes to 48 hours** depending on the registrar's TTL
- Typical time with most registrars: **15–60 minutes**
- Check propagation status: https://dnschecker.org — search for `bmi.ostaddevops.click`

### 10.3 Verify Route53 Record

```powershell
aws route53 list-resource-record-sets `
  --hosted-zone-id $HZ_ID `
  --query "ResourceRecordSets[?Name=='bmi.ostaddevops.click.']" `
  --profile sarowar-ostad
```

---

## 11. Verification & Testing

Run these checks in order after all 4 phases are complete.

### 11.1 SSM — Confirm Instances Are Registered

```powershell
aws ssm describe-instance-information `
  --filters "Key=tag:Name,Values=bmi-app-frontend,bmi-app-backend,bmi-app-db" `
  --query "InstanceInformationList[].{ID:InstanceId,Ping:PingStatus,Agent:AgentVersion}" `
  --output table `
  --profile sarowar-ostad --region ap-south-1
```

Expected: All 3 show `PingStatus: Online`

### 11.2 ALB Target Group Health

```powershell
# Frontend Target Group health
aws elbv2 describe-target-health `
  --target-group-arn $TG_FE_ARN `
  --query "TargetHealthDescriptions[].{ID:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}" `
  --output table `
  --profile sarowar-ostad --region ap-south-1

# Backend Target Group health
aws elbv2 describe-target-health `
  --target-group-arn $TG_BE_ARN `
  --query "TargetHealthDescriptions[].{ID:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}" `
  --output table `
  --profile sarowar-ostad --region ap-south-1
```

Expected: Both show `State: healthy`

> Target groups will show `unhealthy` or `initial` until the EC2 setup scripts have run. Run this check after completing Phases 2–4.

### 11.3 Health Endpoint Test (via ALB DNS before DNS propagation)

Before DNS is propagated, test using the ALB DNS directly:

```powershell
# Health check — should return {"status":"ok","environment":"production"}
Invoke-RestMethod -Uri "https://$ALB_DNS/health" -SkipCertificateCheck

# Or with curl:
curl -k "https://$ALB_DNS/health"
```

### 11.4 Full Application Test (via domain after DNS propagation)

```powershell
# Health check
Invoke-RestMethod -Uri "https://bmi.ostaddevops.click/health"
# Expected: @{status=ok; environment=production}

# API — create a measurement
Invoke-RestMethod -Uri "https://bmi.ostaddevops.click/api/measurements" -Method POST `
  -ContentType "application/json" `
  -Body '{"weightKg":75,"heightCm":175,"age":30,"sex":"male","activity":"moderate"}'
# Expected: 201 response with measurement data including bmi, bmiCategory, bmr, dailyCalories

# API — retrieve measurements
Invoke-RestMethod -Uri "https://bmi.ostaddevops.click/api/measurements"
# Expected: {"rows":[...]}

# API — BMI trends
Invoke-RestMethod -Uri "https://bmi.ostaddevops.click/api/measurements/trends"
# Expected: {"rows":[...]}
```

### 11.5 HTTP → HTTPS Redirect Test

```powershell
# Should get a 301 redirect, not content
Invoke-WebRequest -Uri "http://bmi.ostaddevops.click" -MaximumRedirection 0 -ErrorAction SilentlyContinue |
  Select-Object StatusCode, Headers
# Expected: StatusCode 301, Location header: https://bmi.ostaddevops.click/
```

### 11.6 Browser Test

1. Open `http://bmi.ostaddevops.click` — should auto-redirect to HTTPS
2. Check for padlock icon (valid TLS certificate)
3. Enter BMI data and click **Save** — record should appear in the list
4. Submit 2–3 measurements on different dates
5. Scroll down to the trend chart — it shows 30-day BMI trend
6. Verify the Certificate details in the browser: issued for `bmi.ostaddevops.click`

---

## 12. Application Flow Explained

### 12.1 What Happens When a User Submits BMI Data

```
1. User fills in the form in the browser
2. React's MeasurementForm.jsx calls:
   POST /api/measurements  { weightKg, heightCm, age, sex, activity, measurementDate }
3. Browser sends request to https://bmi.ostaddevops.click/api/measurements
4. Route53 resolves bmi.ostaddevops.click → ALB
5. ALB receives HTTPS:443, terminates TLS using ACM cert
6. ALB checks listener rules:
   - /api/* matches priority-10 rule → forwards to Backend Target Group (port 3000)
7. Backend EC2 receives HTTP request on port 3000
8. Express routes.js POST /api/measurements handler:
   a. Validates input fields
   b. Calls calculateMetrics() → computes BMI, category, BMR, daily calories
   c. Inserts row into PostgreSQL measurements table via pg connection pool
   d. Returns 201 JSON response with the created record
9. Response flows back: Backend EC2 → ALB → Browser
10. React updates state, displays new record in the list
```

### 12.2 What Happens When a User Loads the App

```
1. Browser requests https://bmi.ostaddevops.click/
2. ALB default rule forwards to Frontend Target Group (port 80)
3. Nginx on Frontend EC2 serves /opt/bmi-app/frontend/dist/index.html
4. Browser loads React JS bundle (served from same Nginx)
5. React App.jsx mounts, calls GET /api/measurements
6. Browser sends request to https://bmi.ostaddevops.click/api/measurements
7. ALB routes /api/* → Backend → PostgreSQL → returns rows
8. React renders the measurement list and stats
9. React TrendChart.jsx calls GET /api/measurements/trends
10. Backend queries 30-day average BMI → chart renders
```

### 12.3 Environment Variables in Backend .env

| Variable | Value | Purpose |
|---|---|---|
| `NODE_ENV` | `production` | Enables production CORS (uses `FRONTEND_URL`) |
| `PORT` | `3000` | Express listen port |
| `DATABASE_URL` | `postgresql://bmi_user:<pw>@<db-ip>:5432/bmidb` | pg connection pool |
| `FRONTEND_URL` | `https://bmi.ostaddevops.click` | CORS allowed origin |

---

## 13. Operational Reference

### 13.1 SSH-Less Access via SSM

No port 22 is open on any instance. Use SSM Session Manager:

```powershell
# Interactive shell on any instance
aws ssm start-session --target <instance-id> `
  --profile sarowar-ostad --region ap-south-1

# Run a one-off command
aws ssm send-command `
  --instance-ids "<instance-id>" `
  --document-name "AWS-RunShellScript" `
  --parameters "commands=['pm2 status']" `
  --profile sarowar-ostad --region ap-south-1 `
  --query "Command.CommandId" --output text
```

### 13.2 Updating the Application Code

When you push new code to GitHub and want to redeploy:

**Backend update:**
```bash
# On Backend EC2 via SSM
cd /opt/bmi-app
git pull --ff-only
cd backend
npm install --omit=dev
pm2 reload bmi-backend    # zero-downtime reload
```

**Frontend update:**
```bash
# On Frontend EC2 via SSM
cd /opt/bmi-app
git pull --ff-only
cd frontend
npm install
npm run build
sudo chown -R www-data:www-data dist/
# Nginx serves the new build immediately — no restart needed
```

**Database migration (new migration files):**
```bash
# On DB EC2 via SSM
export PGPASSWORD='YourStr0ngP@ssword'
psql -U bmi_user -d bmidb -h 127.0.0.1 -f /opt/bmi-app/backend/migrations/003_new_migration.sql
```

### 13.3 Checking Logs

```bash
# Backend PM2 logs
pm2 logs bmi-backend --lines 100

# Backend app log files
tail -f /opt/bmi-app/backend/logs/combined.log

# Nginx access log
tail -f /var/log/nginx/bmi-access.log

# Nginx error log
tail -f /var/log/nginx/bmi-error.log

# PostgreSQL logs
tail -f /var/log/postgresql/postgresql-16-main.log

# System journal (SSM agent issues)
journalctl -u amazon-ssm-agent -n 50
```

### 13.4 Checking Service Status

```bash
# Backend EC2
pm2 status
pm2 show bmi-backend
systemctl status pm2-root       # PM2 systemd service

# Frontend EC2
systemctl status nginx
nginx -t                        # config syntax check

# DB EC2
systemctl status postgresql
sudo -u postgres psql -c "\l"   # list databases
sudo -u postgres psql -c "\du"  # list users
```

### 13.5 Resource ID Reference

There is no `aws-deploy-state.json` in the manual approach. Maintain a personal record of the resource IDs printed at the end of Phase 1, Step 15. You will need them for teardown.

To look up any ID at any time:

```powershell
# VPC
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=bmi-app-vpc" `
  --query "Vpcs[0].VpcId" --output text --profile sarowar-ostad --region ap-south-1

# EC2 instances
aws ec2 describe-instances `
  --filters "Name=tag:Name,Values=bmi-app-frontend,bmi-app-backend,bmi-app-db" `
  --query "Reservations[].Instances[].{Name:Tags[?Key=='Name']|[0].Value,ID:InstanceId,IP:PrivateIpAddress}" `
  --output table --profile sarowar-ostad --region ap-south-1

# ALB
aws elbv2 describe-load-balancers --names bmi-app-alb `
  --query "LoadBalancers[0].{ARN:LoadBalancerArn,DNS:DNSName}" `
  --output table --profile sarowar-ostad --region ap-south-1

# Target Groups
aws elbv2 describe-target-groups `
  --query "TargetGroups[?contains(TargetGroupName,'bmi-app')].{Name:TargetGroupName,ARN:TargetGroupArn}" `
  --output table --profile sarowar-ostad --region ap-south-1

# Route53 hosted zone
aws route53 list-hosted-zones `
  --query "HostedZones[?Name=='ostaddevops.click.'].{Name:Name,ID:Id}" `
  --output table --profile sarowar-ostad

# NAT Gateway
aws ec2 describe-nat-gateways --filter "Name=tag:Name,Values=bmi-app-nat" `
  --query "NatGateways[0].NatGatewayId" --output text `
  --profile sarowar-ostad --region ap-south-1
```

---

## 14. Teardown / Cleanup

Delete all AWS resources created in Phase 1, in **reverse order of creation**. Substitute your actual resource IDs where shown.

> **Tip:** If you still have the Phase 1 PowerShell terminal session open, the `$VAR` variables are still available. Otherwise, use the lookup commands in Section 13.5 to retrieve IDs first.

### Step 1 — Delete Route53 DNS Records and Hosted Zone

```powershell
# Get ALB details for the alias record
$ALB_DNS = aws elbv2 describe-load-balancers --names bmi-app-alb `
  --query "LoadBalancers[0].DNSName" --output text --profile sarowar-ostad --region ap-south-1
$ALB_HZ = aws elbv2 describe-load-balancers --names bmi-app-alb `
  --query "LoadBalancers[0].CanonicalHostedZoneId" --output text --profile sarowar-ostad --region ap-south-1
$HZ_ID = aws route53 list-hosted-zones `
  --query "HostedZones[?Name=='ostaddevops.click.'].Id" --output text --profile sarowar-ostad

# Delete A alias record
@"
{"Changes":[{"Action":"DELETE","ResourceRecordSet":{"Name":"bmi.ostaddevops.click","Type":"A","AliasTarget":{"HostedZoneId":"$ALB_HZ","DNSName":"dualstack.$ALB_DNS","EvaluateTargetHealth":true}}}]}
"@ | Out-File "$env:TEMP\r53-del.json" -Encoding ascii
aws route53 change-resource-record-sets --hosted-zone-id $HZ_ID `
  --change-batch "file://$env:TEMP\r53-del.json" --profile sarowar-ostad | Out-Null

# Delete hosted zone
aws route53 delete-hosted-zone --id $HZ_ID --profile sarowar-ostad | Out-Null
Write-Host "Route53: deleted"
```

### Step 2 — Delete ALB Listeners and Rules

```powershell
# Get listener ARNs
$LISTENERS = aws elbv2 describe-listeners `
  --load-balancer-arn (aws elbv2 describe-load-balancers --names bmi-app-alb --query "LoadBalancers[0].LoadBalancerArn" --output text --profile sarowar-ostad --region ap-south-1) `
  --query "Listeners[].ListenerArn" --output text `
  --profile sarowar-ostad --region ap-south-1

foreach ($L in $LISTENERS.Split()) {
    if ($L) {
        # Delete non-default rules first
        $RULES = aws elbv2 describe-rules --listener-arn $L `
          --query "Rules[?IsDefault==\`false\`].RuleArn" --output text `
          --profile sarowar-ostad --region ap-south-1
        foreach ($R in $RULES.Split()) {
            if ($R) { aws elbv2 delete-rule --rule-arn $R --profile sarowar-ostad --region ap-south-1 | Out-Null }
        }
        aws elbv2 delete-listener --listener-arn $L --profile sarowar-ostad --region ap-south-1 | Out-Null
    }
}
Write-Host "Listeners: deleted"
```

### Step 3 — Delete ALB

```powershell
$ALB_ARN = aws elbv2 describe-load-balancers --names bmi-app-alb `
  --query "LoadBalancers[0].LoadBalancerArn" --output text `
  --profile sarowar-ostad --region ap-south-1

aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN `
  --profile sarowar-ostad --region ap-south-1

Write-Host "Waiting for ALB deletion..."
aws elbv2 wait load-balancers-deleted --load-balancer-arns $ALB_ARN `
  --profile sarowar-ostad --region ap-south-1
Write-Host "ALB: deleted"
```

### Step 4 — Delete Target Groups

```powershell
$TGS = aws elbv2 describe-target-groups `
  --query "TargetGroups[?contains(TargetGroupName,'bmi-app')].TargetGroupArn" `
  --output text --profile sarowar-ostad --region ap-south-1

foreach ($TG in $TGS.Split()) {
    if ($TG) { aws elbv2 delete-target-group --target-group-arn $TG --profile sarowar-ostad --region ap-south-1 | Out-Null }
}
Write-Host "Target Groups: deleted"
```

### Step 5 — Terminate EC2 Instances

```powershell
$IDS = aws ec2 describe-instances `
  --filters "Name=tag:Name,Values=bmi-app-frontend,bmi-app-backend,bmi-app-db" `
            "Name=instance-state-name,Values=running,stopped" `
  --query "Reservations[].Instances[].InstanceId" --output text `
  --profile sarowar-ostad --region ap-south-1

aws ec2 terminate-instances --instance-ids $IDS.Split() `
  --profile sarowar-ostad --region ap-south-1 | Out-Null

Write-Host "Waiting for instances to terminate..."
aws ec2 wait instance-terminated --instance-ids $IDS.Split() `
  --profile sarowar-ostad --region ap-south-1
Write-Host "EC2 instances: terminated"
```

### Step 6 — Delete IAM Role and Instance Profile

```powershell
aws iam remove-role-from-instance-profile `
  --instance-profile-name bmi-ssm-profile --role-name bmi-ssm-role `
  --profile sarowar-ostad
aws iam delete-instance-profile --instance-profile-name bmi-ssm-profile `
  --profile sarowar-ostad
aws iam detach-role-policy --role-name bmi-ssm-role `
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore `
  --profile sarowar-ostad
aws iam delete-role --role-name bmi-ssm-role --profile sarowar-ostad
Write-Host "IAM: deleted"
```

### Step 7 — Delete NAT Gateway and Release EIP

```powershell
$NAT_ID = aws ec2 describe-nat-gateways `
  --filter "Name=tag:Name,Values=bmi-app-nat" "Name=state,Values=available" `
  --query "NatGateways[0].NatGatewayId" --output text `
  --profile sarowar-ostad --region ap-south-1

aws ec2 delete-nat-gateway --nat-gateway-id $NAT_ID `
  --profile sarowar-ostad --region ap-south-1 | Out-Null

Write-Host "Waiting for NAT Gateway deletion (~2 min)..."
aws ec2 wait nat-gateway-deleted --nat-gateway-ids $NAT_ID `
  --profile sarowar-ostad --region ap-south-1

# Release Elastic IP
$EIP_ALLOC = aws ec2 describe-addresses `
  --filters "Name=tag:Name,Values=bmi-app-eip" `
  --query "Addresses[0].AllocationId" --output text `
  --profile sarowar-ostad --region ap-south-1
aws ec2 release-address --allocation-id $EIP_ALLOC `
  --profile sarowar-ostad --region ap-south-1 | Out-Null
Write-Host "NAT Gateway + EIP: deleted"
```

### Step 8 — Delete Route Tables

```powershell
$VPC_ID = aws ec2 describe-vpcs `
  --filters "Name=tag:Name,Values=bmi-app-vpc" `
  --query "Vpcs[0].VpcId" --output text --profile sarowar-ostad --region ap-south-1

# Disassociate and delete non-main route tables
$RTS = aws ec2 describe-route-tables `
  --filters "Name=vpc-id,Values=$VPC_ID" `
  --query "RouteTables[?Associations[0].Main!=\`true\`].RouteTableId" --output text `
  --profile sarowar-ostad --region ap-south-1

foreach ($RT in $RTS.Split()) {
    if ($RT) {
        $ASSOCS = aws ec2 describe-route-tables --route-table-ids $RT `
          --query "RouteTables[0].Associations[].RouteTableAssociationId" --output text `
          --profile sarowar-ostad --region ap-south-1
        foreach ($A in $ASSOCS.Split()) {
            if ($A) { aws ec2 disassociate-route-table --association-id $A --profile sarowar-ostad --region ap-south-1 | Out-Null }
        }
        aws ec2 delete-route-table --route-table-id $RT `
          --profile sarowar-ostad --region ap-south-1 | Out-Null
    }
}
Write-Host "Route Tables: deleted"
```

### Step 9 — Delete Subnets

```powershell
$SUBNETS = aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" `
  --query "Subnets[].SubnetId" --output text `
  --profile sarowar-ostad --region ap-south-1

foreach ($SN in $SUBNETS.Split()) {
    if ($SN) { aws ec2 delete-subnet --subnet-id $SN --profile sarowar-ostad --region ap-south-1 | Out-Null }
}
Write-Host "Subnets: deleted"
```

### Step 10 — Delete Security Groups

```powershell
# Delete in dependency order: DB → Backend → Frontend → ALB
foreach ($SGName in @('sg-db','sg-backend','sg-frontend','sg-alb')) {
    $SG = aws ec2 describe-security-groups `
      --filters "Name=group-name,Values=bmi-app-$SGName" "Name=vpc-id,Values=$VPC_ID" `
      --query "SecurityGroups[0].GroupId" --output text `
      --profile sarowar-ostad --region ap-south-1
    if ($SG -and $SG -ne 'None') {
        aws ec2 delete-security-group --group-id $SG `
          --profile sarowar-ostad --region ap-south-1 | Out-Null
        Write-Host "  Deleted SG: $SGName ($SG)"
    }
}
Write-Host "Security Groups: deleted"
```

### Step 11 — Detach and Delete Internet Gateway, then Delete VPC

```powershell
$IGW_ID = aws ec2 describe-internet-gateways `
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" `
  --query "InternetGateways[0].InternetGatewayId" --output text `
  --profile sarowar-ostad --region ap-south-1

aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID `
  --profile sarowar-ostad --region ap-south-1 | Out-Null
aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID `
  --profile sarowar-ostad --region ap-south-1 | Out-Null

aws ec2 delete-vpc --vpc-id $VPC_ID `
  --profile sarowar-ostad --region ap-south-1 | Out-Null

Write-Host "IGW + VPC: deleted"
Write-Host ""
Write-Host "============================================================"
Write-Host "  TEARDOWN COMPLETE — All resources deleted"
Write-Host "============================================================"
```

### What Teardown Does NOT Remove

- The ACM certificate (pre-existing, not created by these steps)
- The `sarowar-ostad-mumbai` key pair
- The AWS CLI named profile
- Any data in S3 or other services
- The domain registration at your registrar (NS records remain until you manually revert them)

> **Estimated teardown time:** ~10 minutes (most is waiting for NAT Gateway deletion)

---

## 15. Troubleshooting

### Problem: SSM Session Manager — "Instance not connected"

**Cause:** SSM agent not yet registered (takes 2–5 min after first boot) or IAM profile not attached correctly.

**Fix:**
```powershell
# Check instance SSM status
aws ssm describe-instance-information `
  --filters "Key=InstanceIds,Values=<instance-id>" `
  --profile sarowar-ostad --region ap-south-1
```

If empty: wait 3 more minutes, then check the EC2 instance is running. Verify the IAM instance profile `bmi-ssm-profile` is attached to the instance.

---

### Problem: ALB target shows "unhealthy"

**Cause:** The setup script hasn't run yet on that EC2, so the service isn't listening.

**Fix:** Run the appropriate setup script (`DB-auto.sh`, `backend-auto.sh`, or `frontend-auto.sh`) on the EC2. Wait ~30 seconds after the script completes for the ALB health check to cycle.

For backend specifically — check the backend can reach the DB:
```bash
nc -zv <db-private-ip> 5432
```

---

### Problem: Backend health check passes but API calls return 500

**Cause:** Backend cannot connect to PostgreSQL. Check `.env` values.

**Fix (on Backend EC2):**
```bash
cat /opt/bmi-app/backend/.env   # verify DATABASE_URL
pm2 logs bmi-backend --lines 50  # look for DB connection errors

# Test DB connectivity manually
node -e "
const {Pool} = require('pg');
const p = new Pool({connectionString: process.env.DATABASE_URL});
p.query('SELECT NOW()', (e,r) => { console.log(e||r.rows[0]); process.exit(0); });
"
# Run with env: DATABASE_URL='...' node -e "..."
```

---

### Problem: Frontend shows blank page or React Router 404

**Cause:** Nginx not configured with `try_files` for SPA fallback.

**Fix (on Frontend EC2):**
```bash
nginx -t
cat /etc/nginx/sites-available/bmi | grep try_files
# Should show: try_files $uri $uri/ /index.html;

# If wrong, re-run frontend-auto.sh or manually edit and restart:
systemctl restart nginx
```

---

### Problem: `https://bmi.ostaddevops.click` shows "This site can't be reached"

**Cause:** DNS not propagated yet, or NS records not updated at registrar.

**Fix:**
```powershell
# Check current NS for the domain
nslookup -type=NS ostaddevops.click

# Check if Route53 A record exists
aws route53 list-resource-record-sets --hosted-zone-id $HZ_ID `
  --query "ResourceRecordSets[?Name=='bmi.ostaddevops.click.']" `
  --profile sarowar-ostad

# Test directly via ALB DNS (bypasses DNS propagation)
curl -k https://$ALB_DNS/health
```

---

### Problem: Certificate warning in browser

**Cause:** ACM cert may not cover `bmi.ostaddevops.click` (check SAN) or DNS is pointing to a different endpoint.

**Fix:**
```powershell
aws acm describe-certificate `
  --certificate-arn "arn:aws:acm:ap-south-1:388779989543:certificate/c5e5f2a5-c678-4799-b355-765c13584fe0" `
  --query "Certificate.{Status:Status,Domains:DomainValidationOptions[].DomainName}" `
  --profile sarowar-ostad --region ap-south-1
```

The cert must show `ISSUED` status and list `bmi.ostaddevops.click` in Domains.

---

### Problem: A Phase 1 CLI step fails mid-way

**Recovery:** The CLI steps are mostly independent — resources created before the failure still exist. Options:

1. Check the error message and fix the specific issue (e.g., a resource name already in use, missing permission)
2. Re-run only the failed step — most steps are safe to retry (VPC, subnets, SGs, TGs are idempotent via their name tags; EC2 and NAT GW launches create new resources so check if one already exists first)
3. For a clean restart: run the teardown steps in Section 14 to delete everything, then repeat Phase 1 from the beginning

To check if a named resource already exists before re-creating it:
```powershell
# Example: check if VPC already exists
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=bmi-app-vpc" `
  --query "Vpcs[0].VpcId" --output text --profile sarowar-ostad --region ap-south-1
# Returns 'None' if not found, or a vpc-id if it exists
```

---

### Problem: `npm run build` fails on Frontend EC2 (out of memory)

**Cause:** Vite build can use ~500MB RAM. `t3.medium` (4GB) should be fine, but if there's memory pressure:

**Fix:**
```bash
node --max-old-space-size=2048 node_modules/.bin/vite build
# Or: set NODE_OPTIONS before build
export NODE_OPTIONS="--max-old-space-size=2048"
npm run build
```

---

*End of Deployment Guide*

---

## Project Lead

**MD Sarowar Alam**  
Lead DevOps Engineer, WPP Production  
📧 Email: [sarowar@hotmail.com](mailto:sarowar@hotmail.com)  
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/

---
