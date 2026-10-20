# ---------------------------------------------------------------------------
# Inputs for the platform module.
#
# Anything WITHOUT a default is required, and the Makefile supplies it as
# TF_VAR_<name>. Anything WITH a default is ordinary config you can override
# but rarely need to. That split is the quickest way to read this file:
# defaults are decisions, no-defaults are secrets or environment.
# ---------------------------------------------------------------------------

variable "kube_context" {
  type        = string
  description = "kubectl context to target. Pinned to the EKS cluster."
  default     = "lfi-eks"

  validation {
    condition     = var.kube_context == "lfi-eks"
    error_message = "This module only targets the lfi-eks context. Refusing to plan against another cluster."
  }
}


# --- Supplied from .env by the Makefile. No defaults on purpose. ------------

variable "postgres_user" {
  type        = string
  description = "Supplied from .env via TF_VAR_postgres_user."
}

variable "postgres_db" {
  type        = string
  description = "Supplied from .env via TF_VAR_postgres_db."
}

variable "environments" {
  type        = list(string)
  description = "Environment names. Each gets a namespace and its own Secret."
  default     = ["dev", "prod"]
}

variable "namespace_prefix" {
  type        = string
  description = "Namespaces are <prefix>-<environment>, so platform-dev and platform-prod."
  default     = "platform"
}

variable "postgres_password_dev" {
  type        = string
  description = "Supplied from .env via TF_VAR_postgres_password_dev."
  sensitive   = true
}

variable "postgres_password_prod" {
  type        = string
  description = "Supplied from .env via TF_VAR_postgres_password_prod. Must differ from dev."
  sensitive   = true
}

variable "argo_rollouts_chart_version" {
  type        = string
  description = "Pinned argo-rollouts chart version. Verified in Task 10.1.3."
  # 2.43.1 deploys controller v1.10.0. Keep close to your kubectl plugin version.
  default     = "2.43.1"
}

variable "gitops_repo_url" {
  type        = string
  # Not a secret, just environment-specific. Required rather than defaulted
  # because guessing a repo URL wrong is a confusing failure in Section 6.
  description = "HTTPS URL of the GitOps repo ArgoCD watches. Used in Section 6."
}

variable "argocd_chart_version" {
  type        = string
  # Pinned, not "latest". An unpinned chart means a reinstall months from now
  # silently upgrades ArgoCD and may rename the keys in values/argocd.yaml.
  #
  # 10.4.2 deploys ArgoCD server v3.5.2. Keep this in step with your argocd
  # CLI version: a large client/server gap breaks the CLI commands used in
  # Section 6. See Task 1.1.3.
  description = "Pinned argo-cd Helm chart version. Verified in Task 1.1.3."
  default     = "10.4.2"
}

variable "traefik_chart_version" {
  type        = string
  description = "Pinned traefik Helm chart version, from Task 2.1.2."
  # The version recorded in Task 2.1.2. A Helm chart has no lock file either.
  default     = "41.6.1"
}
