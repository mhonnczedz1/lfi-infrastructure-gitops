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

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  # Pinned via a variable so there is exactly one place to change it.
  version          = var.argocd_chart_version
  namespace        = "argocd"
  # Helm creates this namespace; the platform namespace above is Terraform's.
  create_namespace = true

  # Block until the release is actually healthy, so the root
  # Application below never races ahead of a half-started ArgoCD.
  wait    = true
  # 600s, because a first run pulls several ArgoCD images.
  timeout = 600

  # file() reads the values file verbatim, no templating. Keeping it as a real
  # YAML file means you can lint it and diff it like any other manifest.
  values = [file("${path.module}/values/argocd.yaml")]
}

# Reach ArgoCD through the Traefik ingress that already fronts the cluster on
# localhost:8080, instead of through `kubectl port-forward`.
#
# Why this exists rather than a port-forward. A port-forward is a single
# process holding one stream, and kubectl tears the whole thing down on the
# first stream error, taking the listener with it. `argocd login` reliably
# triggers exactly that here: the connection is reset before the RPC reaches
# the server, the forward dies, and the CLI then reports the retry's
# "connection refused" rather than the original fault. Routing through Traefik
# removes the tunnel from the picture entirely, and the session survives
# across terminals and reboots.
#
# Host-based routing, not a path prefix, so ArgoCD is served from "/" and
# needs no server.rootpath setting.
resource "kubernetes_ingress_v1" "argocd_server" {
  metadata {
    name      = "argocd-server"
    namespace = "argocd"
  }

  spec {
    ingress_class_name = "traefik"

    rule {
      host = var.argocd_host

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "argocd-server"

              # Port 80, plain HTTP, because values/argocd.yaml sets
              # server.insecure. Pointing this at 443 would have Traefik
              # speak TLS to a plaintext backend, which resets the connection.
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  # Both the namespace and the argocd-server Service come from the chart.
  depends_on = [helm_release.argocd]
}

# Rendered to disk rather than piped inline, so the manifest is easy to
# inspect and 'kubectl apply -f' stays a plain, debuggable command.
#
# .generated/ is gitignored: it is Terraform output, not source.
resource "local_file" "root_app" {
  filename = "${path.module}/.generated/root-app.yaml"
  # templatefile() substitutes ${gitops_repo_url} in the .tftpl.
  content = templatefile("${path.module}/bootstrap/root-app.yaml.tftpl", {
    gitops_repo_url = var.gitops_repo_url
  })
  file_permission = "0644"
}

# Applied with kubectl rather than the kubernetes_manifest resource on
# purpose: kubernetes_manifest validates against the API server at PLAN
# time, and the Application CRD does not exist until the Helm release
# above has run. That ordering cannot be expressed with depends_on.
resource "null_resource" "root_application" {
  # Explicit, because Terraform cannot infer a dependency from a provisioner's
  # shell command the way it can from a resource attribute reference.
  depends_on = [helm_release.argocd, local_file.root_app]

  # Re-apply only when the rendered manifest or the target cluster changes.
  # Hashing the content rather than the filename is what makes an edit to the
  # template actually trigger a re-apply.
  triggers = {
    manifest_sha  = sha256(local_file.root_app.content)
    kube_context  = var.kube_context
    manifest_path = local_file.root_app.filename
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      # helm_release returning does not guarantee the CRDs are registered and
      # accepted by the API server. Applying an Application a moment too early
      # fails with "no matches for kind", so wait for the CRD explicitly.
      echo "Waiting for the Application CRD to be established..."
      kubectl --context "${var.kube_context}" wait \
        --for condition=established --timeout=120s \
        crd/applications.argoproj.io

      # The last imperative step in the whole project. From here on, ArgoCD
      # pulls from Git and nothing outside the cluster applies anything.
      kubectl --context "${var.kube_context}" apply \
        -f "${local_file.root_app.filename}"
    EOT
  }
}

# The chart generates a random admin password into a Secret. Printing the
# command rather than the password keeps the secret out of terraform output
# and out of the state file.
output "argocd_admin_password_command" {
  value = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}
