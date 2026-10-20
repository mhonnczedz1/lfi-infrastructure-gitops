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

variable "argocd_host" {
  type        = string
  # Resolves to 127.0.0.1 on macOS with no /etc/hosts entry, and any *.localhost
  # name behaves the same way. Host-based routing keeps ArgoCD served from "/",
  # so no server.rootpath configuration is needed.
  description = "Hostname Traefik routes to ArgoCD, reachable on port 8080."
  default     = "argocd.localhost"
}
