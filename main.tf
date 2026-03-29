terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

#Authenticate with my cluster to connect via terminal kubectl into eks 
provider "kubernetes" {
  host                   = aws_eks_cluster.my-eks-cluster.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.my-eks-cluster.certificate_authority[0].data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.my-eks-cluster.name]
    command     = "aws"
  }
}


resource "aws_vpc" "main-vpc" {
  cidr_block           = "10.0.0.0/16"
  instance_tenancy     = "default"
  enable_dns_hostnames = true # Without enable_dns_hostnames your pods won't be able to resolve each other by DNS name inside the cluster.
  enable_dns_support   = true # 


  tags = {
    Name = "enterprise-system"
  }
}

#internet gateway
resource "aws_internet_gateway" "my-igw" {
  vpc_id = aws_vpc.main-vpc.id

  tags = {
    Name = "main-igw"
  }
}

#public-subnet-01
resource "aws_subnet" "public-subnet-1" {
  vpc_id                  = aws_vpc.main-vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = var.az_1
  map_public_ip_on_launch = true # instances launched in public subnets get public IPs automatically.

  tags = {
    Name                                   = "public-subnet-1"
    "kubernetes.io/role/elb"               = "1"      #Tells the EKS Kubernetes cloud controller that this subnet is eligible for (Public facing) ELB provisioning
    "kubernetes.io/cluster/my-eks-cluster" = "shared" # tells eks to associate this subnet with my cluster
  }
}


resource "aws_subnet" "public-subnet-2" {
  vpc_id                  = aws_vpc.main-vpc.id
  cidr_block              = "10.0.10.0/24"
  availability_zone       = var.az_2
  map_public_ip_on_launch = true


  tags = {
    Name                                   = "public-subnet-2"
    "kubernetes.io/role/elb"               = "1" #tells eks this subnet is eligible for (public facing) elb
    "kubernetes.io/cluster/my-eks-cluster" = "shared"
  }
}

#route table association subnets
resource "aws_route_table_association" "public-subnet1-assoc" {
  subnet_id      = aws_subnet.public-subnet-1.id
  route_table_id = aws_route_table.public-route-table.id
}

#route table association subnet02
resource "aws_route_table_association" "public-subnet2-assoc" {
  subnet_id      = aws_subnet.public-subnet-2.id
  route_table_id = aws_route_table.public-route-table.id
}

#private subnets 
resource "aws_subnet" "private-subnet-1" {
  vpc_id            = aws_vpc.main-vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = var.az_1

  tags = {
    Name                                   = "private-subnet-1"
    "kubernetes.io/role/internal-elb"      = "1" #tells eks which subnet to associate with internal elb . lets Kubernetes dynamically create LBs on the right subnets
    "kubernetes.io/cluster/my-eks-cluster" = "shared"
  }
}


resource "aws_subnet" "private-subnet-2" {
  vpc_id            = aws_vpc.main-vpc.id
  cidr_block        = "10.0.20.0/24"
  availability_zone = var.az_2

  tags = {
    Name                                   = "private-subnet-2"
    "kubernetes.io/role/internal-elb"      = "1"      #lets Kubernetes dynamically create LBs on the right subnets. 
    "kubernetes.io/cluster/my-eks-cluster" = "shared" #associate this subnet to the cluster 
  }
}

#NAT gateway to give private subnets access to the internet 
#start by assigining elastic ips 

resource "aws_eip" "nat-eip" {
  count  = 2
  domain = "vpc"
}

#NAT gateway 
resource "aws_nat_gateway" "nat-gateway" {
  count         = 2
  subnet_id     = local.public_subnets[count.index]
  allocation_id = aws_eip.nat-eip[count.index].id

  depends_on = [aws_internet_gateway.my-igw]

  tags = {
    Name = "my-nat-gateway"
  }
}


#private route table 
resource "aws_route_table" "private-rt-1" {
  vpc_id = aws_vpc.main-vpc.id

  tags = {
    Name = "private-rt-1"
  }
}

#handle routing seperately for modularity 
resource "aws_route" "private-rt-1-route" {
  route_table_id         = aws_route_table.private-rt-1.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat-gateway[0].id
}

#private-route-table2 
resource "aws_route_table" "private-rt-2" {
  vpc_id = aws_vpc.main-vpc.id

  tags = {
    Name = "private-rt-2"
  }
}

resource "aws_route" "private-rt-2-route" {
  route_table_id         = aws_route_table.private-rt-2.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat-gateway[1].id
}


#private route table association subnet01
resource "aws_route_table_association" "private-subnet1-assoc" {
  subnet_id      = aws_subnet.private-subnet-1.id
  route_table_id = aws_route_table.private-rt-1.id
}

#private route table association subnet02
resource "aws_route_table_association" "private-subnet2-assoc" {
  subnet_id      = aws_subnet.private-subnet-2.id
  route_table_id = aws_route_table.private-rt-2.id
}


#create cluster roles first 
resource "aws_iam_role" "my-eks-cluster" {
  name = "my-eks-cluster"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.my-eks-cluster.name
}


#Node role 
resource "aws_iam_role" "my-node" {
  name = "my-eks-node"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = ["sts:AssumeRole"]
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}


# allows node to Join the EKS cluster,  Communicate with the control plane, Register themselves properly (Ready state) and Work with kubelet + Kubernetes networking
resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.my-node.name
}



# ECR image pulling permission for node
resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryPullOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
  role       = aws_iam_role.my-node.name
}

# VPC CNI - assigns real VPC IP addresses to each pod. without it pods wont get ip addresses 
resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.my-node.name
}


#create cluster . this is the blueprint for deploying an eks thats fully managed by aws node provisioning, auto scaling, patching, no seperate alb needed,

resource "aws_eks_cluster" "my-eks-cluster" {
  name     = "my-eks-cluster"
  role_arn = aws_iam_role.my-eks-cluster.arn
  version  = "1.31"

  access_config {
    authentication_mode = "API"
  }

  vpc_config {
    endpoint_private_access = true
    endpoint_public_access  = true
    subnet_ids = [
      aws_subnet.public-subnet-1.id,
      aws_subnet.public-subnet-2.id,
      aws_subnet.private-subnet-1.id,
      aws_subnet.private-subnet-2.id
    ]
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy,
  ]
}

#auth for accessing the cluster from kubectl locally 
resource "aws_eks_access_entry" "admin" {
  cluster_name  = aws_eks_cluster.my-eks-cluster.name
  principal_arn = "arn:aws:iam::996549485813:user/Eliuddevops"
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = aws_eks_cluster.my-eks-cluster.name
  principal_arn = "arn:aws:iam::996549485813:user/Eliuddevops"
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}



#node group Manual node group - full control over EC2 instances
resource "aws_eks_node_group" "my-node-group" {
  cluster_name    = aws_eks_cluster.my-eks-cluster.name
  node_group_name = "my-node-group"
  node_role_arn   = aws_iam_role.my-node.arn

  # worker nodes go in private subnets
  subnet_ids = [
    aws_subnet.private-subnet-1.id,
    aws_subnet.private-subnet-2.id
  ]

  instance_types = ["t3.large"]

  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 1
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.node_AmazonEC2ContainerRegistryPullOnly,
    aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy,
  ]
}


# EBS CSI Driver - enables PVC/EBS volume support on EKS
# OIDC Provider.

#This fetches the TLS certificate from the EKS OIDC issuer URL. It's just reading the certificate fingerprint so AWS can verify it's talking to a legitimate EKS endpoint 
data "tls_certificate" "eks" {
  url = aws_eks_cluster.my-eks-cluster.identity[0].oidc[0].issuer
}


#OIDC provider - The OIDC provider is the trust bridge that makes AWS trust the identity token issued by EKS.
#OIDC issuer already exists on the EKS side.
#EKS ships with one built in . with this block youre just registering the OIDC  issuer on the **AWS/IAM side** so that AWS knows to trust tokens issued by that EKS cluster
resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.my-eks-cluster.identity[0].oidc[0].issuer
}

# IAM Role for EBS CSI Driver
# this first defines the trust relationship baked directly into the role itself. 
data "aws_iam_policy_document" "ebs_csi_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn] #The entity allowed to assume this role is this specific OIDC provider. 
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"] #Only the EKS OIDC provider is allowed to assume this role, and only when the request comes from the Kubernete-account
    }
  }
}
#Role creation
resource "aws_iam_role" "ebs_csi_driver" {
  name               = "eks-ebs-csi-driver"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume_role.json
}
# The Permissions Policy Attachment. policy contains the actual EC2/EBS permissions needed — things like ec2:CreateVolume, deleteVolume, attach,describeVolume
resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi_driver.name
}

#This installs the actual EBS CSI driver into the cluster as an EKS managed addon, and **tells it which IAM role to use** via `service_account_role_arn`.
resource "aws_eks_addon" "ebs-csi-driver" {
  cluster_name             = aws_eks_cluster.my-eks-cluster.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi_driver.arn

  depends_on = [
    aws_iam_role_policy_attachment.ebs_csi_driver
  ]
}



resource "kubernetes_namespace" "app_namespaces" {
  for_each = toset(["myapp-dev", "myapp-staging"])

  metadata {
    name = each.value
  }

  depends_on = [aws_eks_node_group.my-node-group]
}



# GitHub Actions OIDC Provider (one-time per AWS account)
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

# Trust policy - only your specific repo can assume this role
data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:MainBank5/*:ref:refs/heads/main"]
    }
  }
}

# The role
resource "aws_iam_role" "github_actions_ecr" {
  name               = "github-actions-ecr-role"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json
}

# ECR permissions - push/pull images
resource "aws_iam_policy" "ecr_push" {
  name = "github-actions-ecr-push"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:GetRepositoryPolicy",
          "ecr:DescribeRepositories",
          "ecr:ListImages",
          "ecr:DescribeImages",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage"
        ]
        Resource = "arn:aws:ecr:us-east-1:996549485813:repository/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_ecr" {
  role       = aws_iam_role.github_actions_ecr.name
  policy_arn = aws_iam_policy.ecr_push.arn
}
