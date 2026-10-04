# ---------------------------------------------------------------------------
# Shell behaviour. All three lines are load-bearing.
# ---------------------------------------------------------------------------
# Use bash, not /bin/sh. The recipes below rely on [[ ]] and ${!var}.
SHELL := /bin/bash

# Run each recipe as ONE shell script instead of one shell per line.
# Without this, `cd terraform/local/01-cluster` would not survive into the next
# line and Terraform would run in the repo root. Needs GNU Make >= 3.82,
# so invoke this file with gmake, not Apple's make. See Task 1.1.1.
.ONESHELL:

# -e           abort the target on the first command that fails
# -u           treat an unset variable as an error, not an empty string
# -o pipefail  a pipeline fails if ANY stage fails, not just the last
# -c           required: this is how make hands the recipe text to the shell
.SHELLFLAGS := -eu -o pipefail -c

# ---------------------------------------------------------------------------
# Variables. := assigns once, immediately, as opposed to = which re-expands
# on every use.
# ---------------------------------------------------------------------------
# The k3d cluster's name. Not CLUSTER: that word is reserved for the question every
# command asks, local or eks, so CLUSTER=eks on the command line cannot clobber it.
K3D_CLUSTER := platform

# Used by resume. Also here because ad-hoc kubectl commands want it.
CONTEXT  := k3d-$(K3D_CLUSTER)

EKS_CLUSTER := lfi-eks
EKS_REGION  := ap-southeast-2
EKS_CONTEXT := $(EKS_CLUSTER)

# ---------------------------------------------------------------------------
# PASS: hands the answers given on the command line to the scripts, which ask
# for whatever is missing. An empty value means "not given, so ask".
#
#   CLUSTER      local, eks or both
#   SVC          service-1, service-2 or both
#   ENVIRONMENT  dev, prod or both
#   ACTION       watch, promote or abort (canary only)
#   TO           the build, release or commit to go back to (rollback only)
#   YES=1        skip the confirmation prompts
# ---------------------------------------------------------------------------
PASS := CLUSTER="$(CLUSTER)" SVC="$(SVC)" ENVIRONMENT="$(ENVIRONMENT)" ACTION="$(ACTION)" TO="$(TO)" ASSUME_YES="$(YES)" MAKE="$(MAKE)"

# CURDIR is the directory make was invoked from, so ENV_FILE is absolute and
# stays correct after a recipe does `cd`.
#
# Do NOT put a trailing comment on this line. Make strips the comment but
# keeps the whitespace before it, so the path would gain trailing spaces and
# the -f test in check-env would fail on a file that exists.
ENV_FILE := $(CURDIR)/.env

# ---------------------------------------------------------------------------
# tf_env: the .env -> Terraform bridge, defined once and used by every target
# that touches stage 2.
#
# `define` makes a multi-line variable. Referencing it in a recipe pastes those
# lines in as recipe lines, which under .ONESHELL means they join the same
# shell script as the rest of the target.
#
# This lives here rather than inline because platform-up and down BOTH need it.
# terraform destroy evaluates the root module exactly like terraform apply
# does, so a missing TF_VAR_ breaks a teardown just as hard as a bring-up.
# Inlining it in one target and not the other is precisely the drift that made
# `down` fail with "No value for required variable".
#
# Terraform reads variables from TF_VAR_<name>, never from .env directly.
# Renaming either side breaks the link to variables.tf, so keep them in step.
# $$ is how you write a literal $ in a Makefile: make eats one.
# ---------------------------------------------------------------------------
define tf_env
set -a; source "$(ENV_FILE)"; set +a
export TF_VAR_postgres_user="$$POSTGRES_USER"
export TF_VAR_postgres_password_dev="$$POSTGRES_PASSWORD_DEV"
export TF_VAR_postgres_password_prod="$$POSTGRES_PASSWORD_PROD"
export TF_VAR_postgres_db="$$POSTGRES_DB"
export TF_VAR_gitops_repo_url="$$GITOPS_REPO_URL"
endef

# Declare targets that are names of actions, not files to be built. Without
# this, a file called `up` appearing in this directory would make `gmake up`
# say "nothing to be done".
.PHONY: help check-env up down destroy pause resume status release rollback canary \
        _local-cluster _local-platform _local-up _local-down _local-destroy \
        _eks-cluster _eks-platform _eks-up _eks-down _eks-destroy

##@ Help

# ---------------------------------------------------------------------------
# help: every command, grouped by purpose, with how to use it.
#
# Reads lines of the form `target: ## description` and prints them in cyan.
# `##@ Name` header lines split the output into sections. Adding `## something`
# to any target is all it takes to get it listed, and a `##@ Name` line above
# a target starts a new section. A description that ends in a VAR=value hint
# (SVC=service-1) tells you the command needs that variable.
# $$ is how you write a literal $ in a Makefile: make eats one.
# ---------------------------------------------------------------------------
help: ## Show every command, grouped by purpose, with usage
	@awk 'BEGIN {FS = ":.*?## "} \
	  /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next } \
	  /^[a-zA-Z_-]+:.*?## / { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo
	@echo "Every command asks for what it needs: the cluster (local, eks or both), the"
	@echo "service, and so on. Answer up front to skip a question, for example:"
	@echo "  gmake release CLUSTER=eks SVC=service-1"
	@echo "After an interactive run the command prints its own skip-the-questions form."
	@echo "Variables: CLUSTER, SVC, ENVIRONMENT, ACTION, TO. Add YES=1 to skip confirmations."
	@echo "Start here: gmake up, then gmake status."

##@ Setup

# ---------------------------------------------------------------------------
# check-env: the guard. Every apply target depends on this, so a bad .env
# stops you before Terraform touches anything.
#
# Note the comments inside this recipe are NOT tab-indented. That keeps them
# make comments, dropped before the shell ever sees them. Indent one with a
# tab and it becomes part of the script and gets echoed at runtime.
# ---------------------------------------------------------------------------
check-env: ## Fail fast if .env is missing or incomplete
# 1. The file has to exist at all.
	@if [[ ! -f "$(ENV_FILE)" ]]; then
	  echo "ERROR: $(ENV_FILE) not found. Copy .env.example to .env and fill it in." >&2
	  exit 1
	fi
# 2. Load it. `set -a` makes every subsequent assignment an export, so sourcing
#    the file puts its keys in the environment rather than only in shell-local
#    variables. `set +a` turns that back off.
	set -a; source "$(ENV_FILE)"; set +a
# 3. Every required key must be non-empty. ${!var} is bash indirect expansion:
#    it reads the variable *named by* $var. The :- suffix stops `set -u` from
#    aborting before we can print a useful message.
	for var in POSTGRES_USER POSTGRES_DB GITOPS_REPO_URL \
	           POSTGRES_PASSWORD_DEV POSTGRES_PASSWORD_PROD; do
	  if [[ -z "$${!var:-}" ]]; then
	    echo "ERROR: $$var is unset or empty in .env" >&2
	    exit 1
	  fi
	done
# 4. Reject the placeholder from .env.example. Copying the example and
#    forgetting to edit it is the single most likely mistake here.
	for var in POSTGRES_PASSWORD_DEV POSTGRES_PASSWORD_PROD; do
	  if [[ "$${!var}" == "change-me" ]]; then
	    echo "ERROR: $$var is still the placeholder value." >&2
	    exit 1
	  fi
	done
	if [[ "$$POSTGRES_PASSWORD_DEV" == "$$POSTGRES_PASSWORD_PROD" ]]; then
	  echo "ERROR: dev and prod passwords are identical, which defeats the point." >&2
	  exit 1
	fi
	echo "OK: .env looks complete." 


##@ Cluster lifecycle

# ---------------------------------------------------------------------------
# up, down, destroy: ask which cluster (local, eks or both), say what is about to
# happen and what it costs, then run the matching internal targets below in a
# safe order. The scripts hold the questions; the internal targets hold the
# Terraform.
# ---------------------------------------------------------------------------
up: ## Bring a cluster up. Asks: local, eks or both
	$(PASS) ./scripts/cluster.sh up

down: ## Remove a cluster's platform but keep the cluster. Asks which
	$(PASS) ./scripts/cluster.sh down

destroy: ## Destroy a cluster and its data. Asks which, and makes you type it
	$(PASS) ./scripts/cluster.sh destroy

# ---------------------------------------------------------------------------
# pause / resume: the cheapest lifecycle pair, local only (EKS cannot be paused;
# it bills until destroyed). Neither one touches Terraform, because nothing about
# the desired state changes: the node containers are simply stopped and started.
#
# Reach for these when you are stepping away. `down` and `destroy` both throw
# work away and cost minutes to undo; pause costs seconds and keeps images,
# PVCs, and the kube context exactly as they were. Quitting OrbStack has the
# same effect implicitly, so a paused cluster is also what you get after a
# reboot.
# ---------------------------------------------------------------------------
pause: ## Stop the local cluster, keeping all state. Then: gmake resume
	k3d cluster stop $(K3D_CLUSTER)
	@echo "Cluster stopped, state kept. Start it again with: gmake resume"

resume: ## Start the paused local cluster and wait for its nodes
	k3d cluster start $(K3D_CLUSTER)
# k3d returns as soon as the containers are running, which is well before k3s
# inside them is serving. Without this wait the next kubectl in your shell
# tends to fail with a connection refused, which looks like a broken cluster
# and is not. Pods need another moment beyond this to finish restarting.
	kubectl --context $(CONTEXT) wait --for=condition=Ready nodes --all --timeout=120s
	@echo "Nodes are ready. Pods need another moment. Check with: gmake status"

##@ Look

status: ## Show which build runs where, in Git and in the cluster. Asks cluster and environment
	$(PASS) ./scripts/status.sh

##@ Ship

# ---------------------------------------------------------------------------
# release, rollback: open a PR. Neither applies anything. Prod changes when you
# merge, and ArgoCD picks it up from there. That separation is the gate.
#
# Clusters may drift apart. Releasing to one leaves the other where it was.
# ---------------------------------------------------------------------------
release: ## Open a release PR promoting dev to prod. Asks: cluster, service
	$(PASS) ./scripts/release.sh

rollback: ## Open a PR going back to an earlier prod build. Asks: cluster, service, target
	$(PASS) ./scripts/rollback.sh "$(SVC)" "$(TO)"

# ---------------------------------------------------------------------------
# canary: operate on an in-flight prod rollout: watch it, promote it or abort it.
# These change no desired state, which is why they are commands rather than
# commits. They advance or unwind a convergence toward what Git already says.
# ---------------------------------------------------------------------------
canary: ## Watch, promote or abort a prod canary. Asks: what, cluster, service
	$(PASS) NAMESPACE=platform-prod ./scripts/canary.sh "$(ACTION)" "$(SVC)"

# ---------------------------------------------------------------------------
# Internals, called by the commands above. Not meant to be run directly, and
# deliberately without a `##` description so `gmake help` does not list them.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Local cluster. Stage 1 creates the k3d cluster using only the null provider, so
# nothing needs a reachable cluster at plan time. Stage 2 configures what is
# *inside* it, so its kubernetes and helm providers need stage 1 to have run.
# Stage 2 is where the .env -> Terraform bridge happens.
# ---------------------------------------------------------------------------
_local-cluster: check-env
	cd terraform/local/01-cluster
# -input=false makes Terraform fail rather than prompt, which is what you want
# in a scripted path. A prompt here would mean a variable is missing.
	terraform init -input=false
	terraform apply -auto-approve -input=false

_local-platform: check-env
	$(tf_env)
	cd terraform/local/02-platform
	terraform init -input=false
	terraform apply -auto-approve -input=false

# Prerequisites run left to right, which is what enforces cluster-before-platform.
_local-up: _local-cluster _local-platform

# Undo stage 2 only. The cluster survives, so this is the cheap way to reset
# ArgoCD without waiting on a k3s image pull again. It removes the
# postgres-credentials Secret; the PVC and its data are untouched, because ArgoCD
# created those, not Terraform. check-env and $(tf_env) are needed for the same
# reason as going up: destroy has to evaluate the root module, so the no-default
# variables are just as required going down as they were coming up.
_local-down: check-env
	$(tf_env)
	cd terraform/local/02-platform
	terraform destroy -auto-approve -input=false

_local-destroy:
# `|| echo` keeps the teardown going when stage 2 fails. Deliberate: if the
# cluster is already gone, stage 2's destroy cannot reach it, and that should
# not block deleting the cluster itself.
#
# This CANNOT be a leading `-`. Under .ONESHELL the whole recipe is one shell
# script, and the -e in .SHELLFLAGS aborts that script at the first failure.
# A `-` only stops make from *reporting* the failure, which it does after the
# shell has already skipped the lines below. `|| ...` is how you opt one
# command out of -e.
	$(MAKE) _local-down || echo "WARNING: stage 2 destroy failed. Continuing to delete the cluster." >&2
	cd terraform/local/01-cluster
	terraform destroy -auto-approve -input=false

# ---------------------------------------------------------------------------
# EKS cluster. They never touch the local cluster, and the local targets never
# touch EKS, which is what keeps the two independent.
# ---------------------------------------------------------------------------
_eks-cluster:
	cd terraform/eks/01-cluster
	terraform init -input=false
	terraform apply -auto-approve -input=false
	aws eks update-kubeconfig --region $(EKS_REGION) --name $(EKS_CLUSTER) --alias $(EKS_CONTEXT)

_eks-platform: check-env
	$(tf_env)
	cd terraform/eks/02-platform
	terraform init -input=false
	terraform apply -auto-approve -input=false

_eks-up: _eks-cluster _eks-platform

_eks-down: check-env
# Delete the root Application first so ArgoCD stops recreating things while
# Terraform removes the namespaces. || true because it may already be gone.
	kubectl --context $(EKS_CONTEXT) -n argocd delete application root --wait=true --timeout=180s || true
	$(tf_env)
	cd terraform/eks/02-platform
	terraform destroy -auto-approve -input=false

_eks-destroy:
	$(MAKE) _eks-down || echo "WARNING: platform destroy failed. Continuing." >&2
# Destroying the Traefik release deletes its Service, which asks AWS to delete
# the load balancer asynchronously. The VPC cannot be deleted while that
# load balancer's network interfaces exist, so give AWS a moment.
	sleep 90
	cd terraform/eks/01-cluster
	terraform destroy -auto-approve -input=false
	kubectl config delete-context $(EKS_CONTEXT) || true
