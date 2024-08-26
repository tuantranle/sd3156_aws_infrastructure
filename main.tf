terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.11.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "2.10.1"
    }
  }
}

provider "aws" {
  region  = "us-east-1"
  profile = "tuantranle"
  default_tags {
    tags = {
      Project = "project"
      Org     = "NT"
    }
  }
}
provider "helm" {
  kubernetes {
    host = aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority.0.data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args = ["eks", "get-token", "--cluster-name", aws_eks_cluster.this.name, "--profile", "tuantranle"]
      command = "aws"
    }
  }
}

# Virtual network
resource "aws_vpc" "msavnet" {
  cidr_block = var.vnet_cidr_block
  enable_dns_hostnames = true
  enable_dns_support = true
  tags       = var.vpc_tags
}

resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidr)

  vpc_id                                      = aws_vpc.msavnet.id
  cidr_block                                  = var.public_subnet_cidr[count.index]
  map_public_ip_on_launch                     = true
  enable_resource_name_dns_a_record_on_launch = true
  availability_zone                           = var.subnet_azs[count.index]
  tags                                        = var.public_subnet_tags
}

resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidr)

  vpc_id     = aws_vpc.msavnet.id
  cidr_block = var.private_subnet_cidr[count.index]
  availability_zone = var.subnet_azs[count.index]
  tags       = var.private_subnet_tags
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.msavnet.id
}

resource "aws_route_table" "this" {
  vpc_id = aws_vpc.msavnet.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
}
resource "aws_route_table_association" "public_internet" {
  count = length(var.public_subnet_cidr)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.this.id
}

resource "aws_network_acl" "internet_acl" {
  vpc_id     = aws_vpc.msavnet.id
  subnet_ids = [for subnet in aws_subnet.public: subnet.id]

  dynamic "ingress" {
    for_each = var.public_acl_ingress
    content {
      from_port  = ingress.value["from_port"]
      to_port    = ingress.value["to_port"]
      rule_no    = ingress.value["rule_no"]
      action     = ingress.value["action"]
      protocol   = ingress.value["protocol"]
      cidr_block = ingress.value["cidr_block"]
    }
  }

  egress {
    from_port  = 0
    to_port    = 0
    rule_no    = 100
    action     = "allow"
    protocol   = -1
    cidr_block = "0.0.0.0/0"
  }
}

# EC2 Instance
resource "aws_security_group" "ec2sg" {
  name        = "Agentsg"
  description = "CI/CD agent admin access"
  vpc_id      = aws_vpc.msavnet.id

  dynamic "ingress" {
    for_each = var.sg_ingress
    content {
      from_port   = ingress.value["from_port"]
      to_port     = ingress.value["to_port"]
      protocol    = ingress.value["protocol"]
      cidr_blocks = [ingress.value["cidr_block"]]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = -1
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_key_pair" "ec2_ssh" {
  key_name   = var.ssh_key_name
  public_key = var.public_key
}
resource "aws_instance" "jenkins" {
  ami                    = var.ami
  instance_type          = "t2.micro"
  key_name               = aws_key_pair.ec2_ssh.key_name
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.ec2sg.id]
  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size
  }

  tags = {
    "Name" = "Jenkins controller"
  }
}

resource "aws_ecr_repository" "msabackend" {
  name = "massamplebackend"
}
resource "aws_ecr_repository" "msafrontend" {
  name = "massamplefrontend"
}

# EKS cluster
# Policy AmazonEKSClusterPolicy, AmazonEKSVPCResourceController
data "aws_iam_role" "eksclusterrole" {
  name = "AmazonEKSClusterRole"
}
resource "aws_eks_cluster" "this" {
  name     = var.eks_cluster_name
  role_arn = data.aws_iam_role.eksclusterrole.arn
  vpc_config {
    subnet_ids          = [for subnet in aws_subnet.public : subnet.id]
    public_access_cidrs = var.eks_public_access_cidrs
  }
}
resource "aws_eks_addon" "this" {
  count = length(local.eks_add_ons)

  cluster_name = aws_eks_cluster.this.name
  addon_name = local.eks_add_ons[count.index]
}

# Policy AmazonEC2ContainerRegistryReadOnly, AmazonEKS_CNI_Policy, AmazonEKSWorkerNodePolicy
data "aws_iam_role" "eksnoderole" {
  name = "AWSEKSNodeGroup"
}
resource "aws_eks_node_group" "this" {
  cluster_name  = aws_eks_cluster.this.name
  node_group_name = "eks-practcaldevops-nodegroup"
  node_role_arn = data.aws_iam_role.eksnoderole.arn
  scaling_config {
    desired_size = 1
    max_size     = 1
    min_size     = 0
  }
  subnet_ids     = [for subnet in aws_subnet.public : subnet.id]
  ami_type       = "AL2_x86_64"
  disk_size      = 8
  capacity_type  = "SPOT"
  instance_types = ["t2.medium"]
}

resource "helm_release" "prometheus" {
  name = "prometheus"
  chart = "prometheus"
  repository = "https://prometheus-community.github.io/helm-charts"
  namespace = "prometheus"
  create_namespace = true
  cleanup_on_fail = true

  dynamic "set" {
    for_each = var.prometheus_chart_values
    
    iterator = chart_value
    content {
      name = chart_value.value["name"]
      value = chart_value.value["value"]
    }
  }

  depends_on = [ aws_eks_node_group.this ]
}

resource "helm_release" "grafana" {
  name = "grafana"
  chart = "grafana"
  repository = "https://grafana.github.io/helm-charts"
  namespace = "grafana"
  create_namespace = true
  cleanup_on_fail = true

  dynamic "set" {
    for_each = var.grafana_chart_values
    iterator = chart_value
    content {
      name = chart_value.value["name"]
      value = chart_value.value["value"]
    }
  }

  depends_on = [ aws_eks_node_group.this ]
}