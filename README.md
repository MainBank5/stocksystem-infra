# Production-Grade AWS EKS Infrastructure (Terraform)

This repository contains a **production-ready AWS EKS architecture** built using Terraform.

It is designed with **high availability, security, and scalability** in mind — following real-world infrastructure patterns, not just a demo setup.

---

##  Architecture Overview
              Internet
                    │
            ┌───────────────┐
            │ Internet GW   │
            └──────┬────────┘
                   │
    ┌──────────────┼──────────────┐
    │                              │

🌐  Public Subnet AZ1 🌐 Public Subnet AZ2
(ELB, NAT GW) (ELB, NAT GW)
│ │
└───────┬──────────────┬───────┘
│ │
🔒 Private Subnet AZ1 🔒 Private Subnet AZ2
(EKS Nodes) (EKS Nodes)
│ │
└───────┬──────────────┘
│
☸️ EKS Cluster
│
┌───────────────┼────────────────┐
│ │ │
Pods Services EBS Volumes
│
EBS CSI Driver




---

##  Key Components

###  Networking
- Custom VPC (`10.0.0.0/16`)
- 2 Public Subnets (Multi-AZ)
- 2 Private Subnets (Multi-AZ)
- Internet Gateway for public access
- NAT Gateways (1 per AZ for HA)

---

###  EKS Cluster
- Kubernetes v1.31 (managed control plane)
- Public + Private API endpoint access
- Worker nodes deployed in **private subnets**
- Managed Node Group:
  - Instance type: `t3.large`
  - Auto-scaling enabled

---

### Security (IAM)
- Dedicated IAM roles for:
  - EKS Cluster
  - Worker Nodes
- IRSA (IAM Roles for Service Accounts) via OIDC
  - Enables secure pod-to-AWS communication
  - No hardcoded credentials

---

###  Storage
- AWS EBS CSI Driver (EKS Add-on)
- Supports dynamic provisioning via:
  - Persistent Volume Claims (PVCs)

---

### ⚖️ Load Balancing
- Public subnets tagged for:
  - Internet-facing Load Balancers
- Private subnets tagged for:
  - Internal Load Balancers

---

##  Design Decisions

### High Availability
- Multi-AZ architecture across all layers
- NAT Gateway per AZ (avoids single point of failure)

###  Security First
- Worker nodes in private subnets
- No direct exposure to the internet
- IAM roles + OIDC for fine-grained access control

###  Scalability
- Auto-scaling node group
- Kubernetes-native scaling support

###  Infrastructure as Code
- Fully managed via Terraform
- Reproducible and version-controlled

---

##  Key Learnings

- Proper subnet design is critical for EKS networking
- IRSA (OIDC) is essential for secure cloud-native workloads
- Separating public and private workloads improves security posture
- Terraform enforces consistency across complex infrastructure

---







