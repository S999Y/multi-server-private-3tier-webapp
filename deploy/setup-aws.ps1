<#
.SYNOPSIS
    Deploys or tears down the full AWS infrastructure for the BMI 3-tier app.

.DESCRIPTION
    Creates VPC, subnets, IGW, NAT GW, security groups, IAM role (SSM),
    3 private EC2 instances (Frontend / Backend / DB), an internet-facing ALB
    with HTTPS (ACM cert) + HTTP-to-HTTPS redirect, and a Route53 A alias
    record for bmi.ostaddevops.click in the existing hosted zone.

    All resource IDs are saved to aws-deploy-state.json so the -Teardown
    switch can destroy everything cleanly in reverse order.

.PARAMETER Profile
    AWS named profile to use. Default: sarowar-ostad

.PARAMETER Teardown
    If set, reads aws-deploy-state.json and destroys all created resources.

.EXAMPLE
    # Deploy
    .\setup-aws.ps1

.EXAMPLE
    # Teardown
    .\setup-aws.ps1 -Teardown
#>

[CmdletBinding()]
param(
    [string]$Profile  = "sarowar-ostad",
    [switch]$Teardown
)

$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
$Region          = "ap-south-1"
$StateFile       = "$PSScriptRoot\aws-deploy-state.json"

$ProjectName     = "bmi-app"
$VpcCidr         = "10.0.0.0/16"
$PubSubnet1Cidr  = "10.0.1.0/24"   # ap-south-1a  — NAT GW + ALB
$PubSubnet2Cidr  = "10.0.3.0/24"   # ap-south-1b  — ALB only (2nd AZ required)
$PrivSubnetCidr  = "10.0.2.0/24"   # ap-south-1a  — all 3 EC2s
$Az1             = "ap-south-1a"
$Az2             = "ap-south-1b"

$InstanceType    = "t3.medium"
$KeyName         = "sarowar-ostad-mumbai"
$AcmCertArn      = "arn:aws:acm:ap-south-1:388779989543:certificate/c5e5f2a5-c678-4799-b355-765c13584fe0"

$Domain          = "bmi.ostaddevops.click"
$HostedZoneId    = "Z1019653XLWIJ02C53P5"   # existing hosted zone for ostaddevops.click
$IamRoleName     = "bmi-ssm-role"
$IamProfileName  = "bmi-ssm-profile"

# ─────────────────────────────────────────────────────────────────────────────
# HELPER FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────

function Write-Step   { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK     { param([string]$m) Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Warn   { param([string]$m) Write-Host "    [WARN] $m" -ForegroundColor Yellow }

# Call AWS CLI and return parsed JSON. Throws on non-zero exit.
function Invoke-AWS {
    param([string[]]$Cmd)
    $out = & aws @Cmd --profile $Profile --region $Region --output json
    if ($LASTEXITCODE -ne 0) { throw "AWS CLI error (exit $LASTEXITCODE): $Cmd" }
    return $out | ConvertFrom-Json
}

# Call AWS CLI, discard output. Throws on non-zero exit.
function Invoke-AWSVoid {
    param([string[]]$Cmd)
    & aws @Cmd --profile $Profile --region $Region --output json | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "AWS CLI error (exit $LASTEXITCODE): $Cmd" }
}

# Authorize SG ingress from another SG (writes temp JSON file for reliability)
function Add-SgIngressFromSg {
    param([string]$GroupId, [int]$Port, [string]$SourceSgId)
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        "[{`"IpProtocol`":`"tcp`",`"FromPort`":$Port,`"ToPort`":$Port,`"UserIdGroupPairs`":[{`"GroupId`":`"$SourceSgId`"}]}]" |
            Set-Content -Path $tmp -Encoding UTF8
        & aws ec2 authorize-security-group-ingress `
            --group-id $GroupId `
            --ip-permissions "file://$tmp" `
            --profile $Profile --region $Region | Out-Null
    } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

# Authorize SG ingress from a CIDR range
function Add-SgIngressFromCidr {
    param([string]$GroupId, [int]$Port, [string]$Cidr)
    & aws ec2 authorize-security-group-ingress `
        --group-id $GroupId --protocol tcp --port $Port --cidr $Cidr `
        --profile $Profile --region $Region | Out-Null
}

function Save-State {
    param($State)
    $State | ConvertTo-Json -Depth 10 | Set-Content -Path $StateFile -Encoding UTF8
}

# Write JSON to a temp file and return the file:// URI (cross-platform safe)
function New-TempJson {
    param([string]$Json)
    $tmp = [System.IO.Path]::GetTempFileName()
    $Json | Set-Content -Path $tmp -Encoding UTF8
    return "file://$($tmp -replace '\\', '/')"
}


# ─────────────────────────────────────────────────────────────────────────────
# TEARDOWN
# ─────────────────────────────────────────────────────────────────────────────
if ($Teardown) {
    if (-not (Test-Path $StateFile)) {
        Write-Error "State file not found: $StateFile"
        exit 1
    }
    $s = Get-Content $StateFile -Raw | ConvertFrom-Json

    Write-Host "`n!!! TEARDOWN — This will PERMANENTLY DELETE all bmi-app AWS resources !!!" -ForegroundColor Red
    $confirm = Read-Host "Type 'yes' to confirm"
    if ($confirm -ne "yes") { Write-Host "Aborted."; exit 0 }

    # ── Delete Route53 A record ──────────────────────────────────────────────
    if ($s.HostedZoneId -and $s.AlbDns -and $s.AlbHostedZoneId) {
        Write-Step "Deleting Route53 A alias record..."
        try {
            $changeBatchJson = @"
{"Changes":[{"Action":"DELETE","ResourceRecordSet":{"Name":"$Domain","Type":"A","AliasTarget":{"DNSName":"$($s.AlbDns)","EvaluateTargetHealth":true,"HostedZoneId":"$($s.AlbHostedZoneId)"}}}]}
"@
            $uri = New-TempJson $changeBatchJson
            & aws route53 change-resource-record-sets `
                --hosted-zone-id $s.HostedZoneId `
                --change-batch $uri `
                --profile $Profile | Out-Null
            Write-OK "Route53 A record deleted"
        } catch { Write-Warn "Route53 record deletion skipped: $_" }
    }

    # NOTE: The hosted zone (Z1019653XLWIJ02C53P5) is pre-existing and is NOT deleted.

    # ── Delete ALB listeners ─────────────────────────────────────────────────
    foreach ($lArn in @($s.ListenerHttp, $s.ListenerHttps)) {
        if ($lArn) {
            try {
                & aws elbv2 delete-listener --listener-arn $lArn --profile $Profile --region $Region | Out-Null
            } catch { Write-Warn "Listener $lArn deletion skipped" }
        }
    }
    Write-OK "ALB listeners deleted"

    # ── Delete ALB ───────────────────────────────────────────────────────────
    if ($s.AlbArn) {
        Write-Step "Deleting ALB and waiting..."
        try {
            & aws elbv2 delete-load-balancer --load-balancer-arn $s.AlbArn --profile $Profile --region $Region | Out-Null
            & aws elbv2 wait load-balancers-deleted --load-balancer-arns $s.AlbArn --profile $Profile --region $Region
            Write-OK "ALB deleted"
        } catch { Write-Warn "ALB deletion skipped: $_" }
    }

    # ── Delete Target Groups ─────────────────────────────────────────────────
    foreach ($tgArn in @($s.TgFrontendArn, $s.TgBackendArn)) {
        if ($tgArn) {
            try {
                & aws elbv2 delete-target-group --target-group-arn $tgArn --profile $Profile --region $Region | Out-Null
            } catch { Write-Warn "TG $tgArn deletion skipped" }
        }
    }
    Write-OK "Target groups deleted"

    # ── Terminate EC2 instances ──────────────────────────────────────────────
    $instanceIds = @($s.FrontendInstanceId, $s.BackendInstanceId, $s.DbInstanceId) | Where-Object { $_ }
    if ($instanceIds.Count -gt 0) {
        Write-Step "Terminating EC2 instances: $($instanceIds -join ', ')..."
        & aws ec2 terminate-instances --instance-ids @instanceIds --profile $Profile --region $Region | Out-Null
        Write-Host "    Waiting for instances to terminate (~2 min)..."
        & aws ec2 wait instance-terminated --instance-ids @instanceIds --profile $Profile --region $Region
        Write-OK "Instances terminated"
    }

    # ── Delete IAM instance profile + role ───────────────────────────────────
    if ($s.IamProfileName -and $s.IamRoleName) {
        Write-Step "Removing IAM instance profile and role..."
        try { & aws iam remove-role-from-instance-profile --instance-profile-name $s.IamProfileName --role-name $s.IamRoleName --profile $Profile | Out-Null } catch {}
        try { & aws iam delete-instance-profile --instance-profile-name $s.IamProfileName --profile $Profile | Out-Null } catch {}
        try {
            & aws iam detach-role-policy --role-name $s.IamRoleName `
                --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" --profile $Profile | Out-Null
        } catch {}
        try { & aws iam delete-role --role-name $s.IamRoleName --profile $Profile | Out-Null } catch {}
        Write-OK "IAM role and profile deleted"
    }

    # ── Delete NAT Gateway ───────────────────────────────────────────────────
    if ($s.NatGatewayId) {
        Write-Step "Deleting NAT Gateway (this takes ~2 min)..."
        & aws ec2 delete-nat-gateway --nat-gateway-id $s.NatGatewayId --profile $Profile --region $Region | Out-Null
        $maxWait = 240; $elapsed = 0
        do {
            Start-Sleep -Seconds 10; $elapsed += 10
            $ngwResult = & aws ec2 describe-nat-gateways --nat-gateway-ids $s.NatGatewayId --profile $Profile --region $Region --output json | ConvertFrom-Json
            $ngwState  = if ($ngwResult.NatGateways.Count -gt 0) { $ngwResult.NatGateways[0].State } else { "deleted" }
            Write-Host "    State: $ngwState ($elapsed/$maxWait s)"
        } while ($ngwState -notin @("deleted") -and $elapsed -lt $maxWait)
        Write-OK "NAT Gateway deleted"
    }

    # ── Release Elastic IP ───────────────────────────────────────────────────
    if ($s.EipAllocationId) {
        Write-Step "Releasing Elastic IP..."
        try {
            & aws ec2 release-address --allocation-id $s.EipAllocationId --profile $Profile --region $Region | Out-Null
            Write-OK "EIP released"
        } catch { Write-Warn "EIP release skipped: $_" }
    }

    # ── Disassociate and delete route tables ─────────────────────────────────
    Write-Step "Cleaning up route tables..."
    foreach ($assocId in @($s.PubRtAssoc1, $s.PubRtAssoc2, $s.PrivRtAssoc)) {
        if ($assocId) { try { & aws ec2 disassociate-route-table --association-id $assocId --profile $Profile --region $Region | Out-Null } catch {} }
    }
    foreach ($rtId in @($s.PubRouteTableId, $s.PrivRouteTableId)) {
        if ($rtId) { try { & aws ec2 delete-route-table --route-table-id $rtId --profile $Profile --region $Region | Out-Null } catch {} }
    }
    Write-OK "Route tables removed"

    # ── Delete subnets ───────────────────────────────────────────────────────
    Write-Step "Deleting subnets..."
    foreach ($snId in @($s.PubSubnet1Id, $s.PubSubnet2Id, $s.PrivSubnetId)) {
        if ($snId) { try { & aws ec2 delete-subnet --subnet-id $snId --profile $Profile --region $Region | Out-Null } catch { Write-Warn "Subnet ${snId}: $_" } }
    }
    Write-OK "Subnets deleted"

    # ── Delete security groups (app SGs first, then ALB) ────────────────────
    Write-Step "Deleting security groups..."
    foreach ($sgId in @($s.SgDbId, $s.SgBackendId, $s.SgFrontendId, $s.SgAlbId)) {
        if ($sgId) {
            try { & aws ec2 delete-security-group --group-id $sgId --profile $Profile --region $Region | Out-Null }
            catch { Write-Warn "SG $sgId skipped (possible dependency): $_" }
        }
    }
    Write-OK "Security groups deleted"

    # ── Detach and delete IGW ────────────────────────────────────────────────
    if ($s.IgwId -and $s.VpcId) {
        Write-Step "Detaching and deleting Internet Gateway..."
        try {
            & aws ec2 detach-internet-gateway --internet-gateway-id $s.IgwId --vpc-id $s.VpcId --profile $Profile --region $Region | Out-Null
            & aws ec2 delete-internet-gateway --internet-gateway-id $s.IgwId --profile $Profile --region $Region | Out-Null
            Write-OK "IGW deleted"
        } catch { Write-Warn "IGW deletion skipped: $_" }
    }

    # ── Delete VPC ───────────────────────────────────────────────────────────
    if ($s.VpcId) {
        Write-Step "Deleting VPC..."
        & aws ec2 delete-vpc --vpc-id $s.VpcId --profile $Profile --region $Region | Out-Null
        Write-OK "VPC $($s.VpcId) deleted"
    }

    Remove-Item $StateFile -Force
    Write-Host "`n[TEARDOWN COMPLETE] All bmi-app resources have been removed." -ForegroundColor Green
    exit 0
}


# ─────────────────────────────────────────────────────────────────────────────
# DEPLOY
# ─────────────────────────────────────────────────────────────────────────────
$state = [ordered]@{}

Write-Host "`n============================================================" -ForegroundColor Yellow
Write-Host "  BMI 3-Tier App — AWS Infrastructure Deployment" -ForegroundColor Yellow
Write-Host "  Region : $Region   Profile : $Profile" -ForegroundColor Yellow
Write-Host "  Domain : $Domain" -ForegroundColor Yellow
Write-Host "============================================================`n" -ForegroundColor Yellow

# ── [1] Ubuntu 24.04 LTS AMI ─────────────────────────────────────────────────
Write-Step "[1/13] Fetching Ubuntu 24.04 LTS AMI..."
$amiId = (& aws ssm get-parameter `
    --name "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id" `
    --query "Parameter.Value" `
    --output text `
    --profile $Profile --region $Region).Trim()
$state.AmiId = $amiId
Write-OK "AMI: $amiId"

# ── [2] VPC ──────────────────────────────────────────────────────────────────
Write-Step "[2/13] Creating VPC ($VpcCidr)..."
$vpc   = Invoke-AWS @("ec2","create-vpc","--cidr-block",$VpcCidr)
$vpcId = $vpc.Vpc.VpcId
$state.VpcId = $vpcId

& aws ec2 modify-vpc-attribute --vpc-id $vpcId --enable-dns-hostnames --profile $Profile --region $Region | Out-Null
& aws ec2 modify-vpc-attribute --vpc-id $vpcId --enable-dns-support    --profile $Profile --region $Region | Out-Null
& aws ec2 create-tags --resources $vpcId --tags "Key=Name,Value=$ProjectName-vpc" --profile $Profile --region $Region | Out-Null

Save-State $state
Write-OK "VPC: $vpcId"

# ── [3] Internet Gateway ──────────────────────────────────────────────────────
Write-Step "[3/13] Creating Internet Gateway..."
$igw   = Invoke-AWS @("ec2","create-internet-gateway")
$igwId = $igw.InternetGateway.InternetGatewayId
$state.IgwId = $igwId

& aws ec2 attach-internet-gateway --internet-gateway-id $igwId --vpc-id $vpcId --profile $Profile --region $Region | Out-Null
& aws ec2 create-tags --resources $igwId --tags "Key=Name,Value=$ProjectName-igw" --profile $Profile --region $Region | Out-Null

Save-State $state
Write-OK "IGW: $igwId"

# ── [4] Subnets ───────────────────────────────────────────────────────────────
Write-Step "[4/13] Creating subnets..."

$pubSn1       = Invoke-AWS @("ec2","create-subnet","--vpc-id",$vpcId,"--cidr-block",$PubSubnet1Cidr,"--availability-zone",$Az1)
$pubSubnet1Id = $pubSn1.Subnet.SubnetId
$state.PubSubnet1Id = $pubSubnet1Id
& aws ec2 create-tags --resources $pubSubnet1Id --tags "Key=Name,Value=$ProjectName-pub-1a" --profile $Profile --region $Region | Out-Null
Write-OK "  Public Subnet 1 ($Az1): $pubSubnet1Id"

$pubSn2       = Invoke-AWS @("ec2","create-subnet","--vpc-id",$vpcId,"--cidr-block",$PubSubnet2Cidr,"--availability-zone",$Az2)
$pubSubnet2Id = $pubSn2.Subnet.SubnetId
$state.PubSubnet2Id = $pubSubnet2Id
& aws ec2 create-tags --resources $pubSubnet2Id --tags "Key=Name,Value=$ProjectName-pub-1b" --profile $Profile --region $Region | Out-Null
Write-OK "  Public Subnet 2 ($Az2): $pubSubnet2Id"

$privSn      = Invoke-AWS @("ec2","create-subnet","--vpc-id",$vpcId,"--cidr-block",$PrivSubnetCidr,"--availability-zone",$Az1)
$privSubnetId = $privSn.Subnet.SubnetId
$state.PrivSubnetId = $privSubnetId
& aws ec2 create-tags --resources $privSubnetId --tags "Key=Name,Value=$ProjectName-priv-1a" --profile $Profile --region $Region | Out-Null
Write-OK "  Private Subnet ($Az1):  $privSubnetId"

Save-State $state

# ── [5] Public Route Table ────────────────────────────────────────────────────
Write-Step "[5/13] Creating public route table..."
$pubRt   = Invoke-AWS @("ec2","create-route-table","--vpc-id",$vpcId)
$pubRtId = $pubRt.RouteTable.RouteTableId
$state.PubRouteTableId = $pubRtId
& aws ec2 create-tags --resources $pubRtId --tags "Key=Name,Value=$ProjectName-rt-public" --profile $Profile --region $Region | Out-Null

Invoke-AWSVoid @("ec2","create-route","--route-table-id",$pubRtId,"--destination-cidr-block","0.0.0.0/0","--gateway-id",$igwId)

$assoc1 = Invoke-AWS @("ec2","associate-route-table","--route-table-id",$pubRtId,"--subnet-id",$pubSubnet1Id)
$state.PubRtAssoc1 = $assoc1.AssociationId
$assoc2 = Invoke-AWS @("ec2","associate-route-table","--route-table-id",$pubRtId,"--subnet-id",$pubSubnet2Id)
$state.PubRtAssoc2 = $assoc2.AssociationId

Save-State $state
Write-OK "Public RT: $pubRtId"

# ── [6] Elastic IP + NAT Gateway ─────────────────────────────────────────────
Write-Step "[6/13] Allocating EIP and creating NAT Gateway (takes ~2 min)..."
$eip         = Invoke-AWS @("ec2","allocate-address","--domain","vpc")
$eipAllocId  = $eip.AllocationId
$state.EipAllocationId = $eipAllocId
& aws ec2 create-tags --resources $eipAllocId --tags "Key=Name,Value=$ProjectName-natgw-eip" --profile $Profile --region $Region | Out-Null
Write-OK "  EIP allocated: $eipAllocId"

$nat     = Invoke-AWS @("ec2","create-nat-gateway","--subnet-id",$pubSubnet1Id,"--allocation-id",$eipAllocId)
$natGwId = $nat.NatGateway.NatGatewayId
$state.NatGatewayId = $natGwId
& aws ec2 create-tags --resources $natGwId --tags "Key=Name,Value=$ProjectName-natgw" --profile $Profile --region $Region | Out-Null
Save-State $state

Write-Host "    Waiting for NAT Gateway to become available..."
& aws ec2 wait nat-gateway-available --nat-gateway-ids $natGwId --profile $Profile --region $Region
Write-OK "NAT Gateway: $natGwId"

# ── [7] Private Route Table ───────────────────────────────────────────────────
Write-Step "[7/13] Creating private route table..."
$privRt   = Invoke-AWS @("ec2","create-route-table","--vpc-id",$vpcId)
$privRtId = $privRt.RouteTable.RouteTableId
$state.PrivRouteTableId = $privRtId
& aws ec2 create-tags --resources $privRtId --tags "Key=Name,Value=$ProjectName-rt-private" --profile $Profile --region $Region | Out-Null

Invoke-AWSVoid @("ec2","create-route","--route-table-id",$privRtId,"--destination-cidr-block","0.0.0.0/0","--nat-gateway-id",$natGwId)

$privAssoc = Invoke-AWS @("ec2","associate-route-table","--route-table-id",$privRtId,"--subnet-id",$privSubnetId)
$state.PrivRtAssoc = $privAssoc.AssociationId

Save-State $state
Write-OK "Private RT: $privRtId (0.0.0.0/0 → NAT GW)"

# ── [8] Security Groups ───────────────────────────────────────────────────────
Write-Step "[8/13] Creating Security Groups..."

# ALB SG — accepts 80 + 443 from internet
$sgAlb   = Invoke-AWS @("ec2","create-security-group","--group-name","$ProjectName-sg-alb","--description","ALB internet-facing 80+443","--vpc-id",$vpcId)
$sgAlbId = $sgAlb.GroupId
$state.SgAlbId = $sgAlbId
& aws ec2 create-tags --resources $sgAlbId --tags "Key=Name,Value=$ProjectName-sg-alb" --profile $Profile --region $Region | Out-Null
Add-SgIngressFromCidr $sgAlbId 80  "0.0.0.0/0"
Add-SgIngressFromCidr $sgAlbId 443 "0.0.0.0/0"
Write-OK "  SG ALB:      $sgAlbId"

# Frontend SG — port 80 from ALB SG only
$sgFe         = Invoke-AWS @("ec2","create-security-group","--group-name","$ProjectName-sg-frontend","--description","Frontend port 80 from ALB","--vpc-id",$vpcId)
$sgFrontendId = $sgFe.GroupId
$state.SgFrontendId = $sgFrontendId
& aws ec2 create-tags --resources $sgFrontendId --tags "Key=Name,Value=$ProjectName-sg-frontend" --profile $Profile --region $Region | Out-Null
Add-SgIngressFromSg $sgFrontendId 80 $sgAlbId
Write-OK "  SG Frontend: $sgFrontendId"

# Backend SG — port 3000 from ALB SG only
$sgBe        = Invoke-AWS @("ec2","create-security-group","--group-name","$ProjectName-sg-backend","--description","Backend port 3000 from ALB","--vpc-id",$vpcId)
$sgBackendId = $sgBe.GroupId
$state.SgBackendId = $sgBackendId
& aws ec2 create-tags --resources $sgBackendId --tags "Key=Name,Value=$ProjectName-sg-backend" --profile $Profile --region $Region | Out-Null
Add-SgIngressFromSg $sgBackendId 3000 $sgAlbId
Write-OK "  SG Backend:  $sgBackendId"

# DB SG — port 5432 from Backend SG only
$sgDb   = Invoke-AWS @("ec2","create-security-group","--group-name","$ProjectName-sg-db","--description","DB port 5432 from backend only","--vpc-id",$vpcId)
$sgDbId = $sgDb.GroupId
$state.SgDbId = $sgDbId
& aws ec2 create-tags --resources $sgDbId --tags "Key=Name,Value=$ProjectName-sg-db" --profile $Profile --region $Region | Out-Null
Add-SgIngressFromSg $sgDbId 5432 $sgBackendId
Write-OK "  SG DB:       $sgDbId"

Save-State $state

# ── [9] IAM Role + Instance Profile for SSM ───────────────────────────────────
Write-Step "[9/13] Creating IAM role for SSM access..."
$trustDoc = '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
$trustUri = New-TempJson $trustDoc

try {
    & aws iam create-role --role-name $IamRoleName --assume-role-policy-document $trustUri --profile $Profile | Out-Null
} catch { Write-Warn "IAM role may already exist, continuing..." }

& aws iam attach-role-policy --role-name $IamRoleName `
    --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" --profile $Profile | Out-Null

try { & aws iam create-instance-profile --instance-profile-name $IamProfileName --profile $Profile | Out-Null } catch {}
try { & aws iam add-role-to-instance-profile --instance-profile-name $IamProfileName --role-name $IamRoleName --profile $Profile | Out-Null } catch {}

$state.IamRoleName    = $IamRoleName
$state.IamProfileName = $IamProfileName
Save-State $state

# IAM propagation delay
Write-Host "    Waiting 15 s for IAM profile to propagate..."
Start-Sleep -Seconds 15
Write-OK "IAM: role=$IamRoleName  profile=$IamProfileName"

# ── [10] EC2 Instances ────────────────────────────────────────────────────────
Write-Step "[10/13] Launching EC2 instances (t3.medium, Ubuntu 24.04)..."

# User data: ensure SSM agent is active on first boot
$udScript = @"
#!/bin/bash
# Ensure SSM agent starts on Ubuntu 24.04 (snap-based)
systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service 2>/dev/null || true
systemctl start  snap.amazon-ssm-agent.amazon-ssm-agent.service 2>/dev/null || true
# Also handle non-snap installs
systemctl enable amazon-ssm-agent 2>/dev/null || true
systemctl start  amazon-ssm-agent 2>/dev/null || true
"@
$udB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($udScript))

# Frontend
$fei  = Invoke-AWS @("ec2","run-instances",
    "--image-id",$amiId,"--instance-type",$InstanceType,"--key-name",$KeyName,
    "--subnet-id",$privSubnetId,"--security-group-ids",$sgFrontendId,
    "--iam-instance-profile","Name=$IamProfileName",
    "--user-data",$udB64,"--count","1",
    "--block-device-mappings","[{`"DeviceName`":`"/dev/sda1`",`"Ebs`":{`"VolumeSize`":20,`"VolumeType`":`"gp3`"}}]")
$feId = $fei.Instances[0].InstanceId
$state.FrontendInstanceId = $feId
& aws ec2 create-tags --resources $feId --tags "Key=Name,Value=$ProjectName-frontend" --profile $Profile --region $Region | Out-Null
Write-OK "  Frontend: $feId"

# Backend
$bei  = Invoke-AWS @("ec2","run-instances",
    "--image-id",$amiId,"--instance-type",$InstanceType,"--key-name",$KeyName,
    "--subnet-id",$privSubnetId,"--security-group-ids",$sgBackendId,
    "--iam-instance-profile","Name=$IamProfileName",
    "--user-data",$udB64,"--count","1",
    "--block-device-mappings","[{`"DeviceName`":`"/dev/sda1`",`"Ebs`":{`"VolumeSize`":20,`"VolumeType`":`"gp3`"}}]")
$beId = $bei.Instances[0].InstanceId
$state.BackendInstanceId = $beId
& aws ec2 create-tags --resources $beId --tags "Key=Name,Value=$ProjectName-backend" --profile $Profile --region $Region | Out-Null
Write-OK "  Backend:  $beId"

# DB
$dbi  = Invoke-AWS @("ec2","run-instances",
    "--image-id",$amiId,"--instance-type",$InstanceType,"--key-name",$KeyName,
    "--subnet-id",$privSubnetId,"--security-group-ids",$sgDbId,
    "--iam-instance-profile","Name=$IamProfileName",
    "--user-data",$udB64,"--count","1",
    "--block-device-mappings","[{`"DeviceName`":`"/dev/sda1`",`"Ebs`":{`"VolumeSize`":30,`"VolumeType`":`"gp3`"}}]")
$dbId = $dbi.Instances[0].InstanceId
$state.DbInstanceId = $dbId
& aws ec2 create-tags --resources $dbId --tags "Key=Name,Value=$ProjectName-db" --profile $Profile --region $Region | Out-Null
Write-OK "  DB:       $dbId"

Save-State $state
Write-Host "    Waiting for all instances to reach 'running' state..."
& aws ec2 wait instance-running --instance-ids $feId $beId $dbId --profile $Profile --region $Region
Write-OK "All instances running"

# Retrieve private IPs
$instData = Invoke-AWS @("ec2","describe-instances",
    "--instance-ids",$feId,$beId,$dbId,
    "--query","Reservations[].Instances[].[InstanceId,PrivateIpAddress]")
$feIp = $beIp = $dbIp = $null
foreach ($row in $instData) {
    switch ($row[0]) {
        $feId { $feIp = $row[1] }
        $beId { $beIp = $row[1] }
        $dbId { $dbIp = $row[1] }
    }
}
$state.FrontendPrivateIp = $feIp
$state.BackendPrivateIp  = $beIp
$state.DbPrivateIp       = $dbIp
Save-State $state
Write-OK "  Frontend IP: $feIp  |  Backend IP: $beIp  |  DB IP: $dbIp"

# ── [11] Target Groups ────────────────────────────────────────────────────────
Write-Step "[11/13] Creating ALB Target Groups..."

$tgFe = Invoke-AWS @("ec2","describe-vpcs","--vpc-ids",$vpcId,"--query","Vpcs[0].VpcId") # dummy read to keep pattern
$tgFrontend = Invoke-AWS @("elbv2","create-target-group",
    "--name","$ProjectName-tg-frontend",
    "--protocol","HTTP","--port","80","--vpc-id",$vpcId,"--target-type","instance",
    "--health-check-protocol","HTTP","--health-check-path","/",
    "--health-check-interval-seconds","30",
    "--healthy-threshold-count","2","--unhealthy-threshold-count","3",
    "--matcher","HttpCode=200")
$tgFrontendArn = $tgFrontend.TargetGroups[0].TargetGroupArn
$state.TgFrontendArn = $tgFrontendArn
Write-OK "  Frontend TG: $tgFrontendArn"

$tgBackend = Invoke-AWS @("elbv2","create-target-group",
    "--name","$ProjectName-tg-backend",
    "--protocol","HTTP","--port","3000","--vpc-id",$vpcId,"--target-type","instance",
    "--health-check-protocol","HTTP","--health-check-path","/health",
    "--health-check-interval-seconds","30",
    "--healthy-threshold-count","2","--unhealthy-threshold-count","3",
    "--matcher","HttpCode=200")
$tgBackendArn = $tgBackend.TargetGroups[0].TargetGroupArn
$state.TgBackendArn = $tgBackendArn
Write-OK "  Backend TG:  $tgBackendArn"

& aws elbv2 register-targets --target-group-arn $tgFrontendArn --targets "Id=$feId" --profile $Profile --region $Region | Out-Null
& aws elbv2 register-targets --target-group-arn $tgBackendArn  --targets "Id=$beId" --profile $Profile --region $Region | Out-Null
Write-OK "  Targets registered in TGs"
Save-State $state

# ── [12] ALB + Listeners ──────────────────────────────────────────────────────
Write-Step "[12/13] Creating Application Load Balancer..."
$alb      = Invoke-AWS @("elbv2","create-load-balancer",
    "--name","$ProjectName-alb","--type","application","--scheme","internet-facing",
    "--ip-address-type","ipv4","--subnets",$pubSubnet1Id,$pubSubnet2Id,
    "--security-groups",$sgAlbId)
$albArn   = $alb.LoadBalancers[0].LoadBalancerArn
$albDns   = $alb.LoadBalancers[0].DNSName
$albHzId  = $alb.LoadBalancers[0].CanonicalHostedZoneId
$state.AlbArn          = $albArn
$state.AlbDns          = $albDns
$state.AlbHostedZoneId = $albHzId
Save-State $state

Write-Host "    Waiting for ALB to become active (~3 min)..."
& aws elbv2 wait load-balancer-available --load-balancer-arns $albArn --profile $Profile --region $Region
Write-OK "ALB active: $albDns"

# HTTP:80 → HTTPS:443 redirect
$httpL = Invoke-AWS @("elbv2","create-listener",
    "--load-balancer-arn",$albArn,"--protocol","HTTP","--port","80",
    "--default-actions","Type=redirect,RedirectConfig={Protocol=HTTPS,Port=443,StatusCode=HTTP_301}")
$state.ListenerHttp = $httpL.Listeners[0].ListenerArn
Write-OK "  HTTP:80  → redirect HTTPS:443"

# HTTPS:443 — default → frontend TG
$httpsL = Invoke-AWS @("elbv2","create-listener",
    "--load-balancer-arn",$albArn,"--protocol","HTTPS","--port","443",
    "--certificates","CertificateArn=$AcmCertArn",
    "--ssl-policy","ELBSecurityPolicy-TLS-1-2-Ext-2018-06",
    "--default-actions","Type=forward,TargetGroupArn=$tgFrontendArn")
$httpsListenerArn     = $httpsL.Listeners[0].ListenerArn
$state.ListenerHttps  = $httpsListenerArn
Write-OK "  HTTPS:443 → default to Frontend TG"

# Path rule: /api/* → Backend TG  (priority 10)
$condApiUri    = New-TempJson '[{"Field":"path-pattern","PathPatternConfig":{"Values":["/api/*"]}}]'
$actionBackUri = New-TempJson "[{`"Type`":`"forward`",`"TargetGroupArn`":`"$tgBackendArn`"}]"
& aws elbv2 create-rule `
    --listener-arn $httpsListenerArn `
    --priority 10 `
    --conditions $condApiUri `
    --actions $actionBackUri `
    --profile $Profile --region $Region | Out-Null
Write-OK "  Rule priority 10: /api/* → Backend TG"

# Path rule: /health → Backend TG  (priority 20)
$condHealthUri = New-TempJson '[{"Field":"path-pattern","PathPatternConfig":{"Values":["/health"]}}]'
& aws elbv2 create-rule `
    --listener-arn $httpsListenerArn `
    --priority 20 `
    --conditions $condHealthUri `
    --actions $actionBackUri `
    --profile $Profile --region $Region | Out-Null
Write-OK "  Rule priority 20: /health → Backend TG"

Save-State $state

# ── [13] Route53 A Record ───────────────────────────────────────────────────
Write-Step "[13/13] Creating Route53 A alias record..."
$hzId = "/hostedzone/$HostedZoneId"
$state.HostedZoneId = $hzId
Save-State $state

# Create alias A record  bmi.ostaddevops.click → ALB
$changeBatchJson = @"
{
  "Changes": [{
    "Action": "CREATE",
    "ResourceRecordSet": {
      "Name": "$Domain",
      "Type": "A",
      "AliasTarget": {
        "DNSName": "$albDns",
        "EvaluateTargetHealth": true,
        "HostedZoneId": "$albHzId"
      }
    }
  }]
}
"@
$r53Uri    = New-TempJson $changeBatchJson
$r53Change = & aws route53 change-resource-record-sets `
                --hosted-zone-id $hzId `
                --change-batch $r53Uri `
                --profile $Profile --output json | ConvertFrom-Json
$state.Route53RecordChangeId = $r53Change.ChangeInfo.Id
Save-State $state
Write-OK "Route53 alias: $Domain → $albDns"


# ─────────────────────────────────────────────────────────────────────────────
# OUTPUT SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
$divider = "=" * 62
Write-Host "`n$divider" -ForegroundColor Yellow
Write-Host "  DEPLOYMENT COMPLETE" -ForegroundColor Yellow
Write-Host $divider -ForegroundColor Yellow

Write-Host "`n  EC2 Private IPs (use with SSM scripts):" -ForegroundColor Cyan
Write-Host "    Frontend  : $feIp   instance-id: $feId"
Write-Host "    Backend   : $beIp   instance-id: $beId"
Write-Host "    Database  : $dbIp   instance-id: $dbId"

Write-Host "`n  ALB DNS:" -ForegroundColor Cyan
Write-Host "    $albDns"

Write-Host "`n  Route53 Hosted Zone: $hzId (pre-existing)" -ForegroundColor Cyan

Write-Host "`n  Next Steps:" -ForegroundColor Cyan
Write-Host "  1. DNS is live — bmi.ostaddevops.click already points to the ALB" -ForegroundColor Green
Write-Host "  2. On DB EC2 ($dbId) via SSM Session Manager:"
Write-Host "       sudo DB_PASSWORD='<strong-password>' bash /tmp/DB-auto.sh" -ForegroundColor White
Write-Host "  3. On Backend EC2 ($beId) via SSM Session Manager:"
Write-Host "       sudo DB_PASSWORD='<strong-password>' DB_PRIVATE_IP='$dbIp' bash /tmp/backend-auto.sh" -ForegroundColor White
Write-Host "  4. On Frontend EC2 ($feId) via SSM Session Manager:"
Write-Host "       sudo bash /tmp/frontend-auto.sh" -ForegroundColor White
Write-Host "  5. Browse: https://$Domain"
Write-Host "`n  State saved to: $StateFile"
Write-Host ""

# SSM upload hint
Write-Host "  Tip — Upload scripts to EC2 via SSM Send-Command:" -ForegroundColor DarkCyan
Write-Host "    aws ssm send-command --instance-ids <id> --document-name AWS-RunShellScript \\"
Write-Host "      --parameters 'commands=[`"bash /tmp/DB-auto.sh`"]' --profile $Profile --region $Region"
Write-Host ""
