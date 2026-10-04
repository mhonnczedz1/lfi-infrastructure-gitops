# ---------------------------------------------------------------------------
# Stage 1 of the two-module split.
#
# The critical property of this file: it declares NO kubernetes or helm
# provider. Those need a reachable cluster when the plan is built, and the
# cluster does not exist yet. Only `null` is used, which needs nothing.
# ---------------------------------------------------------------------------
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

variable "cluster_name" {
  type        = string
  description = "Name of the k3d cluster. Kube context becomes k3d-<name>."
  default     = "platform"
}

# `locals` are computed values, not inputs. path.module is this directory, so
# the reference holds no matter where you invoke terraform from.
locals {
  config_path = "${path.module}/k3d-config.yaml"
}

# null_resource exists purely to hang provisioners off. There is no k3d
# Terraform provider, so the cluster is created by shelling out. That is a
# compromise: Terraform cannot see inside the cluster, only whether the
# triggers below changed.
resource "null_resource" "cluster" {
  # Recreate the cluster if its name or its shape changes.
  #
  # This map is the whole of Terraform's understanding of this resource. If a
  # value here is unchanged, the provisioner does not re-run, which is what
  # makes a second `gmake cluster-up` a genuine no-op (Task 2.1.4).
  # filesha256 hashes the config file, so editing ports or node counts
  # correctly forces a rebuild.
  triggers = {
    cluster_name  = var.cluster_name
    config_sha256 = filesha256(local.config_path)
  }

  provisioner "local-exec" {
    # Explicit bash, because the heredoc below uses pipefail.
    interpreter = ["/bin/bash", "-c"]
    # <<-EOT strips the leading indentation from the heredoc body.
    command     = <<-EOT
      set -euo pipefail

      # Adopt an existing cluster rather than failing on it. Makes the module
      # recoverable if state was lost but the cluster is still running.
      if k3d cluster list "${var.cluster_name}" >/dev/null 2>&1; then
        echo "Cluster '${var.cluster_name}' already exists, reusing it."
      else
        echo "Creating cluster '${var.cluster_name}'..."
        k3d cluster create --config "${local.config_path}"
      fi

      # Do not return until the API server will actually accept work. Without
      # this, stage 2 can start against a cluster whose nodes are NotReady.
      echo "Waiting for nodes to become Ready..."
      kubectl --context "k3d-${var.cluster_name}" \
        wait --for=condition=Ready nodes --all --timeout=180s
    EOT
  }

  # Runs on `terraform destroy` instead of on create.
  #
  # A destroy provisioner may only reference `self`, never `var` or `local`,
  # because the variables may be gone by the time it runs. That is the reason
  # cluster_name is stored in triggers above and read back from there.
  provisioner "local-exec" {
    when    = destroy
    command = "k3d cluster delete ${self.triggers.cluster_name}"
  }
}

# Outputs are this module's public interface. Nothing wires them into stage 2
# automatically here (no remote state data source yet), so they serve as
# documentation and as a check that the two modules agree on names.
output "cluster_name" {
  value       = var.cluster_name
  description = "Pass this to the 02-platform module."
}

output "kube_context" {
  value       = "k3d-${var.cluster_name}"
  description = "kubectl context name for the created cluster."
}
