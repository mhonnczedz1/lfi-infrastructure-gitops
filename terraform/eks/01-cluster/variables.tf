variable "region" {
  type        = string
  description = "Region the cluster runs in."
  default     = "ap-southeast-2"
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name. The kube context alias is set to the same value."
  default     = "lfi-eks"
}

variable "kubernetes_version" {
  type        = string
  description = "EKS Kubernetes version, from Task 2.1.2."
  # The version recorded in Task 2.1.2: 1.36, in standard support until 2027-08.
  default     = "1.36"
}
