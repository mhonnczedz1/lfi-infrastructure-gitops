terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # The EKS module 21.x needs 6.59 or later, the VPC module 6.x needs 6.28.
      version = ">= 6.59, < 7.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# Two AZs because the EKS control plane requires subnets in at least two.
# The node group below will use only the first one, see Task 2.2.2.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  # Pinned exactly, to the version recorded in Task 2.1.2. Modules are not
  # covered by the .terraform.lock.hcl file (only providers are), so this line
  # is the only thing that keeps a later init from fetching a newer release.
  version = "6.7.3"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs            = ["${var.region}a", "${var.region}b"]
  public_subnets = ["10.0.1.0/24", "10.0.2.0/24"]

  # No private subnets and no NAT gateway: see the Why above.
  enable_nat_gateway      = false
  enable_dns_hostnames    = true
  map_public_ip_on_launch = true

  # Tells Kubernetes which subnets may hold internet-facing load balancers.
  # Without it, Traefik's Service sits at <pending> forever.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
}
