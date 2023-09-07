provider "aws" {
  #https://github.com/hashicorp/terraform-provider-aws/issues/19583
  /* default_tags {
    tags = local.tags
  } */
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

data "aws_route53_zone" "this" {
  name         = var.domain_name
  private_zone = local.private_zone
}

data "aws_availability_zones" "available" {}

data "aws_region" "current" {}

locals {
  root                        = basename(abspath(path.module))
  workspace_suffix            = terraform.workspace == "default" ? "" : "_${terraform.workspace}"
  name                        = "${var.preffix}${local.workspace_suffix}"
  vpc_name                    = "${local.name}-vpc"
  efs_name                    = "${local.name}-efs"
  cluster_name                = "${local.name}-eks"
  ec2_bastion_name            = "${local.name}-bastion"
  s3_ci_backup_name           = "${local.name}-ci-backups"
  s3_velero_name              = "${local.name}-velero"
  s3_artifacts_name           = "${local.name}-artifacts"
  s3_bucket_list              = [local.s3_ci_backup_name, local.s3_artifacts_name, local.s3_velero_name]
  route53_zone_id             = data.aws_route53_zone.this.id
  current_region              = data.aws_region.current.name
  azs                         = slice(data.aws_availability_zones.available.names, 0, var.azs_number)
  vpc_id                      = trim(var.vpc_id, " ") == "" ? module.vpc[0].vpc_id : trim(var.vpc_id, " ")
  vpc_cidr                    = "10.0.0.0/16"
  private_subnet_ids          = length(var.private_subnets_ids) == 0 ? module.vpc[0].private_subnets : var.private_subnets_ids
  private_subnets_cidr_blocks = length(var.private_subnets_cidr_blocks) == 0 ? module.vpc[0].private_subnets_cidr_blocks : var.private_subnets_cidr_blocks
  private_zone                = var.hosted_zone_type == "private" ? true : false
  enable_bastion              = alltrue([var.enable_bastion, trim(var.key_name_bastion, " ") != "", length(var.ssh_cidr_blocks_bastion) > 0])
  enable_acm                  = alltrue([var.enable_acm])
  enable_vpc                  = alltrue([length(local.azs) > 0])
  enable_efs                  = alltrue([var.enable_efs, length(local.private_subnet_ids) > 0, length(local.azs) > 0, length(local.private_subnets_cidr_blocks) > 0])

  tags = merge(var.tags, {
    "tf:preffix"        = var.preffix
    "tf:blueprint_root" = local.root
  })

  kubeconfig_file      = "kubeconfig-${module.eks.cluster_name}.yaml"
  kubeconfig_file_path = abspath("${path.root}/${local.kubeconfig_file}")
}

################################################################################
# EC2. Bastion Host
################################################################################

module "bastion" {
  count  = local.enable_bastion ? 1 : 0
  source = "../../../modules/aws-bastion"

  key_name                 = var.key_name_bastion
  resource_prefix          = local.ec2_bastion_name
  source_security_group_id = module.eks.node_security_group_id
  ssh_cidr_blocks          = var.ssh_cidr_blocks_bastion
  subnet_id                = trim(var.public_subnet_id_bastion, " ") == "" ? module.vpc[0].public_subnets[0] : var.public_subnet_id_bastion
  vpc_id                   = local.vpc_id
}

################################################################################
# Supported Resources
################################################################################

module "aws_s3_bucket" {
  source      = "../../../modules/aws-s3-bucket"
  for_each    = toset(local.s3_bucket_list)
  bucket_name = each.key

  force_destroy = true
  #TODO: Fix InsufficientS3BucketPolicyException
  #https://docs.aws.amazon.com/awscloudtrail/latest/userguide/create-s3-bucket-policy-for-cloudtrail.html
  enable_logging = false
  #SECO-3109
  enable_object_lock = false
  tags               = local.tags
}

module "acm" {
  count   = local.enable_acm ? 1 : 0
  source  = "terraform-aws-modules/acm/aws"
  version = "4.3.2"

  domain_name = var.domain_name
  subject_alternative_names = [
    "*.ci.${var.domain_name}",
    "*.cd.${var.domain_name}",
    "*.${var.domain_name}"
  ]

  #https://docs.aws.amazon.com/acm/latest/userguide/dns-validation.html
  zone_id = local.route53_zone_id

  tags = local.tags
}

module "vpc" {
  count   = local.enable_vpc ? 1 : 0
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"

  name = local.vpc_name
  cidr = local.vpc_cidr

  azs = local.azs
  # Ensure HA by creating different subnets in each AZ and connecting to an Autocaling Group
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  # Manage so we can name
  manage_default_network_acl    = true
  default_network_acl_tags      = { Name = "${local.vpc_name}-default" }

  manage_default_route_table    = true
  default_route_table_tags      = { Name = "${local.vpc_name}-default" }

  manage_default_security_group = true
  default_security_group_tags   = { Name = "${local.vpc_name}-default" }

  #https://docs.aws.amazon.com/eks/latest/userguide/network_reqs.html
  #https://docs.aws.amazon.com/eks/latest/userguide/network-load-balancing.html
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = var.tags
}

#https://docs.cloudbees.com/docs/cloudbees-common/latest/supported-platforms/cloudbees-ci-cloud#_amazon_elastic_file_system_amazon_efs
module "efs" {
  count   = local.enable_efs ? 1 : 0
  source  = "terraform-aws-modules/efs/aws"
  version = "1.2.0"

  creation_token = local.efs_name
  name           = local.efs_name

  mount_targets = {
    for k, v in zipmap(local.azs, local.private_subnet_ids) : k => { subnet_id = v }
  }
  security_group_description = "${local.efs_name} EFS security group"
  security_group_vpc_id      = local.vpc_id
  #https://d1.awsstatic.com/events/reinvent/2021/Amazon_EFS_performance_best_practices_STG403.pdf
  performance_mode = "generalPurpose"
  security_group_rules = {
    vpc = {
      # relying on the defaults provdied for EFS/NFS (2049/TCP + ingress)
      description = "NFS ingress from VPC private subnets"
      cidr_blocks = local.private_subnets_cidr_blocks
    }
  }

  tags = local.tags
}

################################################################################
# EKS Cluster
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "19.15.3" #Note for EKS Blueprint v5 "~> 19.13"

  cluster_name    = local.cluster_name
  cluster_version = var.k8s_version

  #https://docs.aws.amazon.com/eks/latest/userguide/cluster-endpoint.html
  cluster_endpoint_public_access       = var.k8s_api_public
  cluster_endpoint_private_access      = var.k8s_api_private
  cluster_endpoint_public_access_cidrs = var.ssh_cidr_blocks_k8s

  # EKS Addons.
  /* cluster_addons = {
    coredns    = {} # Installed by default
    kube-proxy = {} # Installed by default
    vpc-cni    = {}
  } */

  vpc_id     = local.vpc_id
  subnet_ids = local.private_subnet_ids

  eks_managed_node_group_defaults = {
    iam_role_additional_policies = {
      # Not required, but used in the example to access the nodes to inspect mounted volumes
      AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    }
  }

  node_security_group_additional_rules = {
    egress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "egress"
      self        = true
    }

    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }

    egress_ssh_all = {
      description      = "Egress all ssh to internet for github"
      protocol         = "tcp"
      from_port        = 22
      to_port          = 22
      type             = "egress"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    }

    # Allows Control Plane Nodes to talk to Worker nodes on all ports. Added this to simplify the example and further avoid issues with Add-ons communication with Control plane.
    # This can be restricted further to specific port based on the requirement for each Add-on e.g., metrics-server 4443, spark-operator 8080, karpenter 8443 etc.
    # Change this according to your security requirements if needed
    ingress_cluster_to_node_all_traffic = {
      description                   = "Cluster API to Nodegroup all traffic"
      protocol                      = "-1"
      from_port                     = 0
      to_port                       = 0
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  #IMPORTANT: Desired Sized cannot be changed https://github.com/terraform-aws-modules/terraform-aws-eks/issues/835
  #Only Node Groups with Taints can use Autoscaling. Pods requires Selector
  eks_managed_node_groups = {
    #Not scalable for hosting EKS Add-ons. They cannot be tainted
    mg_k8sApps = {
      node_group_name = "managed-k8s-apps"
      instance_types  = var.k8s_instance_types["k8s-apps"]
      capacity_type   = "ON_DEMAND"
      desired_size    = var.k8s_apps_node_size
    },
    #Managed by Autoscaling
    mg_cbApps = {
      node_group_name = "managed-cb-apps"
      instance_types  = var.k8s_instance_types["cb-apps"]
      capacity_type   = "ON_DEMAND"
      create_iam_role = false # Changing `create_iam_role=false` to bring your own IAM Role
      #Alternative using iam_role_additional_policies https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/19.10.2
      iam_role_arn = aws_iam_role.managed_ng.arn
      min_size     = 1
      max_size     = 6
      desired_size = 1
      taints       = [{ key = "dedicated", value = "cb-apps", effect = "NO_SCHEDULE" }]
      labels = {
        ci_type = "cb-apps"
      }
    }
    mg_cbAgents = {
      node_group_name = "managed-agent"
      instance_types  = var.k8s_instance_types["agent"]
      capacity_type   = "ON_DEMAND"
      min_size        = 1
      max_size        = 3
      desired_size    = 1
      taints          = [{ key = "dedicated", value = "build-linux", effect = "NO_SCHEDULE" }]
      labels = {
        ci_type = "build-linux"
      }
    },
    mg_cbAgents_spot = {
      node_group_name = "managed-agent-spot"
      instance_types  = var.k8s_instance_types["agent-spot"]
      capacity_type   = "SPOT"
      min_size        = 1
      max_size        = 3
      desired_size    = 1
      taints          = [{ key = "dedicated", value = "build-linux-spot", effect = "NO_SCHEDULE" }]
      labels = {
        ci_type = "build-linux-spot"
      }
    }
  }

  tags = var.tags
}

#---------------------------------------------------------------
# Custom IAM roles for Node Group Cloudbees Apps
#---------------------------------------------------------------

data "aws_iam_policy_document" "managed_ng_assume_role_policy" {
  statement {
    sid = "EKSWorkerAssumeRole"

    actions = [
      "sts:AssumeRole",
    ]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "managed_ng" {
  name                  = "${local.name}-managed-node-role"
  description           = "EKS Managed Node group IAM Role"
  assume_role_policy    = data.aws_iam_policy_document.managed_ng_assume_role_policy.json
  path                  = "/"
  force_detach_policies = true
  # Mandatory for EKS Managed Node Group
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  ]
  # Additional Permissions for for EKS Managed Node Group per https://docs.aws.amazon.com/eks/latest/userguide/create-node-role.html
  inline_policy {
    name = "CloudBees_CI"
    policy = jsonencode(
      {
        "Version" : "2012-10-17",
        "Statement" : [ #https://docs.cloudbees.com/docs/cloudbees-ci/latest/backup-restore/cloudbees-backup-plugin#_amazon_s3
          {
            "Sid" : "CBCIBackupPolicy1",
            "Effect" : "Allow",
            "Action" : [
              "s3:PutObject",
              "s3:GetObject",
              "s3:DeleteObject"
            ],
            "Resource" : "arn:aws:s3:::${local.s3_ci_backup_name}/cbci/*"
          },
          {
            "Sid" : "CBCIBackupPolicy2",
            "Effect" : "Allow",
            "Action" : "s3:ListBucket",
            "Resource" : "arn:aws:s3:::${local.s3_ci_backup_name}"
          },
        ]
      }
    )
  }
  tags = local.tags
}

resource "aws_iam_instance_profile" "managed_ng" {
  name = "${local.name}-managed-node-instance-profile-ci"
  role = aws_iam_role.managed_ng.name
  path = "/"

  lifecycle {
    create_before_destroy = true
  }

  tags = local.tags
}

#---------------------------------------------------------------
# Generating kubeconfig file
#---------------------------------------------------------------

#https://www.bitslovers.com/terraform-null-resource/
resource "null_resource" "create_kubeconfig" {
  triggers = var.refresh_kubeconfig ? {
    always_run = timestamp() #Force to recreate on every apply
  } : {}

  depends_on = [module.eks]

  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --kubeconfig ${local.kubeconfig_file}"
  }
}
