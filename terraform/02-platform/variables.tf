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
  # Must match `kube_context` output by 01-cluster. Nothing enforces that
  # automatically, so a mismatch here is silently applying to another cluster.
  description = "kubectl context to target. Must match the 01-cluster output."
  default     = "k3d-platform"
}

variable "namespace" {
  type        = string
  description = "Namespace for application workloads."
  default     = "platform"
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

variable "postgres_password" {
  type        = string
  description = "Supplied from .env via TF_VAR_postgres_password. Never defaulted."
  # Redacts the value from plan and apply output. Note this does NOT encrypt
  # it in terraform.tfstate, which is why the state file is gitignored.
  sensitive   = true
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
