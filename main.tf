provider "aws" {
  region     = var.region
  access_key = var.access_key
  secret_key = var.secret_key
}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  cluster_name ="sd4650-devops-eks"
}

# VPC
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"

  name = "sd4650-devops-vpc"
  cidr = "10.0.0.0/16"
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)

  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.4.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = false
  enable_dns_hostnames = true



  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = 1
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = 1
  }
}

#Create Security Group to allow port 22, 80, 443, 8080
resource "aws_security_group" "allow_web" {
  name        = "allow_web_traffic"
  description = "Allow web inboundd traffic"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.zero-address]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.zero-address]
  }

  ingress {
    description = "HTTP"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.zero-address]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.zero-address]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.zero-address]
  }

  tags = {
    Name = "allow_tls"
  }
}

# Create a network interface
resource "aws_network_interface" "web-server-nic" {
  subnet_id       = module.vpc.public_subnets[0]
  private_ips     = ["10.0.4.50"]
  security_groups = [aws_security_group.allow_web.id]
}

# Assign an elastic IP
resource "aws_eip" "one" {
  network_interface         = aws_network_interface.web-server-nic.id
  associate_with_private_ip = "10.0.4.50"

}

# Create Ubuntu server
resource "aws_instance" "web-server" {
  ami               = "ami-0df4b2961410d4cff" 
  instance_type     = "t3.small"
  availability_zone = data.aws_availability_zones.available.names[0]
  key_name          = "sd4650_ubuntu_keypair"
  depends_on        = [aws_eip.one, aws_network_interface.web-server-nic]

  network_interface {
    network_interface_id = aws_network_interface.web-server-nic.id
    device_index         = 0
  }

  user_data = <<-EOF
                #!/bin/bash
                sudo apt-get update
                sudo apt-get install ca-certificates curl gnupg
                sudo install -m 0755 -d /etc/apt/keyrings
                curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
                sudo chmod a+r /etc/apt/keyrings/docker.gpg
                echo \
                    "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
                    "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
                    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
                sudo apt-get update
                sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y
                sudo usermod -aG docker ubuntu
                EOF

  tags = {
    Name = "Ubuntu"
  }
}

#ECR
resource "aws_ecr_repository" "frontend_repo" {
  name                 = "frontend"
  image_tag_mutability = var.immutable_ecr_repositories ? "IMMUTABLE" : "MUTABLE"
  force_delete         = true
  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name  = "Frontend repository"
    Group = "Practical DevOps assigment"
  }
}

resource "aws_ecr_lifecycle_policy" "frontend_lifecycle_policy" {
  repository = aws_ecr_repository.frontend_repo.name

  policy = <<EOF
            {
                "rules": [
                    {
                        "rulePriority": 1,
                        "description": "Expire images older than 14 days",
                        "selection": {
                            "tagStatus": "any",
                            "countType": "sinceImagePushed",
                            "countUnit": "days",
                            "countNumber": 14
                        },
                        "action": {
                            "type": "expire"
                        }
                    }
                ]
            }
            EOF
}

resource "aws_ecr_repository_policy" "frontend_repo_policy" {
  repository = aws_ecr_repository.frontend_repo.name
  policy     = <<EOF
  {
    "Version": "2008-10-17",
    "Statement": [
      {
        "Sid": "Set the permission for ECR",
        "Effect": "Allow",
        "Principal": "*",
        "Action": [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:GetDownloadUrlForLayer",
          "ecr:GetLifecyclePolicy",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart"
        ]
      }
    ]
  }
  EOF
}

resource "aws_ecr_repository" "backend_repo" {
  name                 = "backend"
  image_tag_mutability = var.immutable_ecr_repositories ? "IMMUTABLE" : "MUTABLE"
  force_delete         = true
  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name  = "Backend repository"
    Group = "Practical DevOps assigment"
  }
}

resource "aws_ecr_lifecycle_policy" "backend_lifecycle_policy" {
  repository = aws_ecr_repository.backend_repo.name

  policy = <<EOF
            {
                "rules": [
                    {
                        "rulePriority": 1,
                        "description": "Expire images older than 14 days",
                        "selection": {
                            "tagStatus": "any",
                            "countType": "sinceImagePushed",
                            "countUnit": "days",
                            "countNumber": 14
                        },
                        "action": {
                            "type": "expire"
                        }
                    }
                ]
            }
            EOF
}

resource "aws_ecr_repository_policy" "backend_repo_policy" {
  repository = aws_ecr_repository.backend_repo.name
  policy     = <<EOF
  {
    "Version": "2008-10-17",
    "Statement": [
      {
        "Sid": "Set the permission for ECR",
        "Effect": "Allow",
        "Principal": "*",
        "Action": [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:GetDownloadUrlForLayer",
          "ecr:GetLifecyclePolicy",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart"
        ]
      }
    ]
  }
  EOF
}

#EKS
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "19.15.3"

  cluster_name    = local.cluster_name
  cluster_version = "1.27"

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true
  cluster_endpoint_private_access= false

  eks_managed_node_group_defaults = {
    ami_type = "AL2_x86_64"

  }

  eks_managed_node_groups = {
    one = {
      name = "node-group-1"

      instance_types = ["t3.small"]

      min_size     = 1
      max_size     = 3
      desired_size = 1
    }
  }
}

data "aws_iam_policy" "ebs_csi_policy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

module "irsa-ebs-csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "4.7.0"

  create_role                   = true
  role_name                     = "AmazonEKSTFEBSCSIRole-${module.eks.cluster_name}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = [data.aws_iam_policy.ebs_csi_policy.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
}

resource "aws_eks_addon" "ebs-csi" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = "v1.25.0-eksbuild.1"
  service_account_role_arn = module.irsa-ebs-csi.iam_role_arn
  tags = {
    "eks_addon" = "ebs-csi"
    "terraform" = "true"
  }
}