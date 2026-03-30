# 🚀 Deploy Application to AWS EKS using Azure DevOps & Terraform

A complete end-to-end CI/CD pipeline that provisions AWS infrastructure using Terraform and deploys a containerized application to Amazon EKS — all automated through Azure DevOps Pipelines.

---

## 📋 Table of Contents

- [Architecture Overview](#architecture-overview)
- [Tech Stack](#tech-stack)
- [Prerequisites](#prerequisites)
- [Project Structure](#project-structure)
- [Setup Guide](#setup-guide)
- [Pipeline Stages](#pipeline-stages)
- [Terraform Configuration](#terraform-configuration)
- [Errors & Lessons Learned](#errors--lessons-learned)
- [Cost Management](#cost-management)

---

## 🏗️ Architecture Overview

```
Azure DevOps Pipeline
        │
        ├── Stage 1: Terraform (Infrastructure)
        │       ├── VPC + Public Subnets
        │       ├── ECR Repository
        │       └── EKS Cluster + Node Group
        │
        ├── Stage 2: Build & Push
        │       ├── Docker Build
        │       └── Push to ECR
        │
        └── Stage 3: Deploy to EKS
                ├── kubectl apply deployment
                └── kubectl apply service (LoadBalancer)
```

---

## 🛠️ Tech Stack

| Tool | Version | Purpose |
|------|---------|---------|
| Terraform | 1.6.6 | Infrastructure as Code |
| terraform-aws-modules/eks | ~> 20.0 | EKS Module |
| terraform-aws-modules/vpc | ~> 5.0 | VPC Module |
| AWS Provider | ~> 5.0 | AWS Resources |
| Kubernetes | 1.33 | Container Orchestration |
| Azure DevOps | - | CI/CD Pipeline |
| Docker | - | Containerization |

---

## ✅ Prerequisites

1. **Azure DevOps** account with a project
2. **AWS Account** (Pay As You Go recommended — EKS not free tier compatible)
3. **AWS OIDC Service Connection** configured in ADO
4. **S3 Bucket** for Terraform state backend
5. **DynamoDB Table** for state locking

---

## 📁 Project Structure

```
├── Terraform/
│   ├── main.tf           # ECR, VPC, EKS resources
│   ├── variables.tf      # Variable declarations
│   ├── terraform.tfvars  # Variable values
│   ├── outputs.tf        # Output values
│   ├── providers.tf      # AWS provider config
│   └── backend.tf        # S3 backend config
├── k8s/
│   ├── deployment.yml    # Kubernetes Deployment
│   └── service.yml       # Kubernetes Service (LoadBalancer)
├── Dockerfile            # Application container
├── azure-pipeline.yml    # Main CI/CD pipeline
└── cleanup-pipeline.yml  # Nightly resource cleanup
```

---

## ⚙️ Setup Guide

### Step 1 — Create S3 Backend + DynamoDB Lock Table

```bash
#!/bin/bash
BUCKET_NAME="your-tf-backend-bucket"
TABLE_NAME="your-tf-lock-table"
REGION="us-east-1"

# Create S3 Bucket (us-east-1 does NOT need LocationConstraint)
aws s3api create-bucket --bucket $BUCKET_NAME --region $REGION

# Enable Versioning
aws s3api put-bucket-versioning \
    --bucket $BUCKET_NAME \
    --versioning-configuration Status=Enabled

# Create DynamoDB Lock Table
aws dynamodb create-table \
    --table-name $TABLE_NAME \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
    --region $REGION
```

> ⚠️ **IMPORTANT:** For `us-east-1`, do NOT add `--create-bucket-configuration LocationConstraint`. It will error. Other regions need it.

---

### Step 2 — AWS OIDC Setup for Azure DevOps

1. **Get ADO Org ID** from: `https://dev.azure.com/YOUR_ORG/_apis/connectiondata`
2. **Create OIDC Provider in AWS IAM:**
   - Provider URL: `https://vstoken.dev.azure.com/<ORG_ID>`
   - Audience: `api://AzureADTokenExchange`
3. **Create IAM Role** with Web Identity trust policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/vstoken.dev.azure.com/<ORG_ID>"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "vstoken.dev.azure.com/<ORG_ID>:aud": "api://AzureADTokenExchange",
        "vstoken.dev.azure.com/<ORG_ID>:sub": "sc://YOUR_ORG/YOUR_PROJECT/YOUR_SERVICE_CONNECTION"
      }
    }
  }]
}
```

4. **Set IAM Role max session duration to 8 hours**
5. **Create ADO Service Connection** (AWS type, OIDC enabled)
6. **Add YAML variable:** `aws.rolecredential.maxduration: '3600'`

---

### Step 3 — Configure Pipeline Variables

```yaml
variables:
  awsRegion: 'us-east-1'
  awsAccountId: 'YOUR_ACCOUNT_ID'
  awsServiceConnection: 'aws_ado_Services'
  ecrName: 'your-ecr-repo'
  backendBucket: 'your-tf-backend-bucket'
  backendKey: 'terraform.tfstate'
  dynamoTable: 'your-tf-lock-table'
  eksClusterName: 'your-eks-cluster'
  aws.rolecredential.maxduration: '3600'
```

---

## 🔄 Pipeline Stages

### Stage 1 — Terraform
- `terraform init` with S3 backend
- `terraform plan`
- `terraform apply` — Creates VPC, ECR, EKS

### Stage 2 — Build & Push
- Login to ECR
- Docker build
- Push image with `$(Build.BuildId)` tag

### Stage 3 — Deploy to EKS
- Install kubectl
- `aws eks update-kubeconfig`
- `kubectl apply` deployment + service
- Wait for rollout

---

## 🏗️ Terraform Configuration

### providers.tf
```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"   # Use v5, NOT v6 with eks module v20
    }
  }
}
```

### main.tf (Final Working Version)
```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = var.vpc_name
  cidr = "10.0.0.0/16"
  azs             = ["${var.aws_region}a", "${var.aws_region}b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  map_public_ip_on_launch = true   # Required for nodes in public subnets
  enable_nat_gateway      = true
  single_nat_gateway      = true
  enable_dns_hostnames    = true
  enable_dns_support      = true
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"   # v20 NOT v21 — see Lessons Learned

  cluster_name    = var.cluster_name
  cluster_version = "1.33"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  enable_cluster_creator_admin_permissions = true

  # CRITICAL: VPC CNI must be installed BEFORE node group
  cluster_addons = {
    vpc-cni = {
      before_compute = true
      most_recent    = true
    }
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
  }

  eks_managed_node_groups = {
    general = {
      min_size       = 1
      max_size       = 2
      desired_size   = 1
      instance_types = ["t3.medium"]   # t3.micro too small for EKS
      capacity_type  = "ON_DEMAND"
      subnet_ids     = module.vpc.public_subnets
    }
  }
}
```

---

## 🔥 Errors & Lessons Learned

This project took **10+ days** of debugging. Every error below is real — documenting so you never face them again.

---

### ❌ Error 1 — Unsupported Arguments `cluster_name` and `cluster_version`

```
Error: Unsupported argument
  on main.tf line 38, in module "eks":
  38:   cluster_name    = "my-eks-cluster"
An argument named "cluster_name" is not expected here.
```

**Root Cause:** Copied code from old blog/tutorial using EKS module v17 syntax, but used version `~> 21.0`. Breaking rename happened in v18+.

**Fix:**
```hcl
# ❌ v17 (old)
cluster_name    = "my-cluster"
cluster_version = "1.31"

# ✅ v21+ (correct)
name               = "my-cluster"
kubernetes_version = "1.31"
```

---

### ❌ Error 2 — Hardcoded Fake VPC Values

```hcl
vpc_id     = "vpc-xxxxxxxxxxxx"      # ❌ placeholder!
subnet_ids = ["subnet-abc12345"]     # ❌ placeholder!
```

**Fix:** Use module outputs:
```hcl
vpc_id     = module.vpc.vpc_id
subnet_ids = module.vpc.private_subnets
```

---

### ❌ Error 3 — Variable Defined but Hardcoded in Module

Defined `cluster_name` in `variables.tf` and `terraform.tfvars`, but used hardcoded string in `main.tf`.

**Fix:** Use `var.cluster_name` instead of `"my-eks-cluster"`.

---

### ❌ Error 4 — ExpiredToken: OIDC Token Expired Mid-Apply

```
ExpiredToken: The security token included in the request is expired
Error: failed to upload state: S3 PutObject ExpiredToken
```

**Root Cause:** ADO OIDC token default lifetime = **15 minutes**. EKS takes 15-20 minutes to create. Token expired mid-way.

**Fix:** Add to pipeline variables:
```yaml
aws.rolecredential.maxduration: '3600'
```
Also set IAM Role max session duration to 8 hours.

---

### ❌ Error 5 — DynamoDB State Lock Stuck

```
Error: Error releasing the state lock
failed to retrieve lock info for lock ID "xxx": ExpiredTokenException
```

**Fix:** Go to DynamoDB → `ado-tf-lock-*` table → Delete the row that has `Info` field containing the stuck lock ID. Keep the row with only `Digest` field.

---

### ❌ Error 6 — NodeCreationFailure: t3.micro Not Eligible

```
InvalidParameterCombination - The specified instance type is not eligible for Free Tier.
```

**Root Cause:** EKS requires minimum `t3.medium` (2 vCPU, 4GB RAM). `t3.micro` is too small — system pods alone use 700MB+.

**Fix:** `instance_types = ["t3.medium"]`

> ⚠️ **EKS is NOT free tier compatible.** EKS control plane costs $0.10/hour regardless.

---

### ❌ Error 7 — Ec2SubnetInvalidConfiguration

```
Ec2SubnetInvalidConfiguration: One or more Amazon EC2 Subnets does not 
automatically assign public IP addresses to instances launched into it.
```

**Root Cause:** `map_public_ip_on_launch` was set in code but old VPC already existed without that setting. Terraform doesn't update existing subnets.

**Fix:** `terraform destroy` first, then `terraform apply` — fresh VPC with correct settings.

---

### ❌ Error 8 — NodeCreationFailure: Unhealthy Nodes (30+ minutes)

```
NodeCreationFailure: Unhealthy nodes in the kubernetes cluster
```

**Root Cause (Final):** EKS module v21 with AWS provider v6 has a known bug — VPC CNI addon is installed AFTER the node group, causing `NetworkPluginNotReady: cni plugin not initialized`. Nodes boot but can't join cluster.

**Fix:** Downgrade to module v20 + AWS provider v5, and add `before_compute = true`:
```hcl
cluster_addons = {
  vpc-cni = {
    before_compute = true   # ← Install CNI BEFORE nodes!
    most_recent    = true
  }
}
```

---

### ❌ Error 9 — Wrong Endpoint Argument Names

```hcl
# ❌ These are silently ignored in v21 (wrong names)
cluster_endpoint_public_access  = true
cluster_endpoint_private_access = true

# ✅ Correct names for v20/v21
cluster_endpoint_public_access  = true   # works in v20
cluster_endpoint_private_access = true   # works in v20
```

> In v21, the argument is `endpoint_public_access` (without `cluster_` prefix). In v20, both work.

---

### ❌ Error 10 — S3 Bucket Creation Fails in us-east-1

```
Error: InvalidLocationConstraint
The specified location-constraint is not valid
```

**Root Cause:** `us-east-1` is AWS default region — it does NOT accept `LocationConstraint`.

**Fix:** Remove `--create-bucket-configuration LocationConstraint=$REGION` when region is `us-east-1`.

---

## 💰 Cost Management

### Resources That Cost Money
| Resource | Cost/Hour |
|----------|-----------|
| EKS Control Plane | $0.10 |
| t3.medium EC2 Node | $0.0416 |
| NAT Gateway | $0.045 |
| **Total** | **~$0.19/hr ≈ ₹16/hr** |

### Nightly Cleanup Pipeline
Set up `cleanup-pipeline.yml` to run at 10 PM IST every night. It:
1. Runs `terraform destroy`
2. Force-deletes any remaining resources (EKS, ECR, VPC, NAT, EIPs)
3. Clears stuck DynamoDB locks

**Cost: ~₹0 when not in use! 🎉**

---

## 📝 Key Takeaways

1. **Always check module version docs** before copying examples — breaking changes happen between major versions
2. **EKS module v20 + AWS provider v5** is the stable combination as of 2026
3. **VPC CNI must be installed before nodes** — use `before_compute = true`
4. **OIDC token expires in 15 min** — always set `aws.rolecredential.maxduration`
5. **EKS needs t3.medium minimum** — never use t3.micro
6. **Public subnets need** `map_public_ip_on_launch = true` for nodes to get IPs
7. **us-east-1 S3 bucket** — no LocationConstraint needed
8. **DynamoDB lock stuck** — only delete the row with `Info` field, not the state record

---

## 🙏 Acknowledgements

Built with persistence, late nights, and a lot of debugging! Special thanks to **me and only me ** who helped troubleshoot the journey from zero to a live application on EKS. 🚀
