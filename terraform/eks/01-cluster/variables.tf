# No defaults for region and cluster_name: platform/registry.yaml owns them and
# the Makefile passes them as TF_VAR_region and TF_VAR_cluster_name. A run that
# forgets fails with "No value for required variable" instead of guessing.
variable "region" {
  type        = string
  description = "Region the cluster runs in. From the registry."
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name. The kube context alias is set to the same value. From the registry."
}

variable "kubernetes_version" {
  type        = string
  description = "EKS Kubernetes version, from Task 2.1.2."
  # The version recorded in Task 2.1.2: 1.36, in standard support until 2027-08.
  default     = "1.36"
}
