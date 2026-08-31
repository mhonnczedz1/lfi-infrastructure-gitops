# ---------------------------------------------------------------------------
# Stage 2 of the two-module split.
#
# Unlike 01-cluster, this file DOES declare kubernetes and helm providers, and
# they need a reachable cluster when the plan is built. That is precisely why
# it is a separate root module: applying it before stage 1 fails at plan time.
# ---------------------------------------------------------------------------
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      # ~> 2.17 means >= 2.17.0 and < 3.0.0. The upper bound is deliberate,
      # not lazy: v3 changed the provider block syntax below.
      version = "~> 2.17"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

# Authenticate by reading your existing kubeconfig rather than by embedding
# credentials. config_context pins WHICH cluster, so a stray `kubectl config
# use-context` cannot redirect an apply at your work cluster.
provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = var.kube_context
}

# Same target, separate provider. Helm needs its own connection block.
# Under helm provider v3 this becomes `kubernetes = { ... }` with an equals
# sign; the nested-block form below is v2 syntax.
provider "helm" {
  kubernetes {
    config_path    = "~/.kube/config"
    config_context = var.kube_context
  }
}

# Created by Terraform rather than by ArgoCD, because the Secret below has to
# land in it and Terraform runs first.
resource "kubernetes_namespace" "platform" {
  metadata {
    name = var.namespace
    labels = {
      # Documents ownership for anyone reading `kubectl get ns -o yaml` and
      # wondering why this namespace is not in the GitOps repo.
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# The bridge described in decision 4: values arrive from the gitignored
# .env as TF_VAR_* and land directly in the cluster. Git only ever holds
# a secretKeyRef naming this Secret.
resource "kubernetes_secret" "postgres" {
  metadata {
    name      = "postgres-credentials"
    # Referencing the resource, not var.namespace, creates an explicit
    # dependency so Terraform orders the namespace first. metadata[0] is
    # needed because metadata is a block, which HCL models as a list.
    namespace = kubernetes_namespace.platform.metadata[0].name
  }

  # Keys match what the postgres image and service-1 both expect,
  # so both can consume this Secret with a single envFrom.
  #
  # Terraform base64-encodes these for you. Do not pre-encode them.
  data = {
    POSTGRES_USER     = var.postgres_user
    POSTGRES_PASSWORD = var.postgres_password
    POSTGRES_DB       = var.postgres_db
  }

  # Opaque = arbitrary key/value. The other types (kubernetes.io/tls,
  # dockerconfigjson) enforce specific keys, which is not what is wanted here.
  type = "Opaque"
}
