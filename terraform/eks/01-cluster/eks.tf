module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  # Pinned exactly, for the same reason as the VPC module above.
  version = "21.26.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id = module.vpc.vpc_id
  # Nodes go here, and the control plane's network interfaces too, which need
  # two AZs. The node group below narrows the nodes to one of them.
  subnet_ids = module.vpc.public_subnets

  # kubectl from your Mac has to reach the API server. The module default is
  # private only, which would leave you unable to connect.
  endpoint_public_access = true
  # The identity that creates the cluster becomes an admin of it. The module
  # default is false, and then you create a cluster you cannot log into.
  enable_cluster_creator_admin_permissions = true

  addons = {
    coredns = {}
    # Lets pods receive AWS permissions through the EKS Pod Identity feature.
    # Task 2.3.1 uses it for the EBS driver, so it has to be running first.
    eks-pod-identity-agent = {
      before_compute = true
    }
    aws-ebs-csi-driver = {
      # Binds the role above to the driver's service account in kube-system.
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
    }

    kube-proxy = {}
    # Networking has to exist before a node can become Ready, hence before
    # the node group is created.
    vpc-cni = {
      before_compute = true
    }
  }

  eks_managed_node_groups = {
    main = {
      instance_types = ["t3.large"]
      ami_type       = "AL2023_x86_64_STANDARD"
      min_size       = 1
      max_size       = 1
      # The module ignores changes to this after the first apply.
      desired_size = 1
      # One subnet, so one AZ. See the Why above.
      subnet_ids = [module.vpc.public_subnets[0]]
    }
  }
}
