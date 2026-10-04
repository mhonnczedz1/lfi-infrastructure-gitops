# ---------------------------------------------------------------------------
# Shell behaviour. All three lines are load-bearing.
# ---------------------------------------------------------------------------
# Use bash, not /bin/sh. The recipes below rely on [[ ]] and ${!var}.
SHELL := /bin/bash

# Run each recipe as ONE shell script instead of one shell per line.
# Without this, `cd terraform/01-cluster` would not survive into the next
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
CLUSTER  := platform

# Used by resume. Also here because ad-hoc kubectl commands want it.
CONTEXT  := k3d-$(CLUSTER)

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
.PHONY: help check-env cluster-up platform-up up pause resume down destroy \
        release rollback prod-current dev-current urls canary-status canary-promote canary-abort

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
	@echo "Usage: gmake <command> [VAR=value]"
	@echo "A command that needs a value says so above, for example SVC=service-1."
	@echo "Bring the platform up from scratch with: gmake up"

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
# cluster-up: stage 1 of the two-stage split. Creates the k3d cluster using
# only the null provider, so nothing needs a reachable cluster at plan time.
# No TF_VAR_* exports here: this module takes no secrets.
# ---------------------------------------------------------------------------
cluster-up: check-env ## Stage 1: create the k3d cluster
	cd terraform/01-cluster
# -input=false makes Terraform fail rather than prompt, which is what you want
# in a scripted path. A prompt here would mean a variable is missing.
	terraform init -input=false
	terraform apply -auto-approve -input=false
	@if [[ "$(MAKECMDGOALS)" == "cluster-up" ]]; then echo; echo "Cluster is up. Next: gmake platform-up (or gmake up runs both stages)."; fi

# ---------------------------------------------------------------------------
# platform-up: stage 2. Configures resources *inside* the cluster, so its
# kubernetes and helm providers need stage 1 to have already run.
# This is where the .env -> Terraform bridge actually happens.
# ---------------------------------------------------------------------------
platform-up: check-env ## Stage 2: secret, ArgoCD, root application
	$(tf_env)
	cd terraform/02-platform
	terraform init -input=false
	terraform apply -auto-approve -input=false
	@echo
	@echo "ArgoCD is installed and the root Application is applied. Next:"
	@echo "  gmake urls                                                     where each environment answers"
	@echo "  kubectl --context $(CONTEXT) -n argocd get applications        watch them sync, up to 3 minutes"

# ---------------------------------------------------------------------------
# up: the only bring-up command you should need. Prerequisites run left to
# right, which is what enforces cluster-before-platform.
# ---------------------------------------------------------------------------
up: cluster-up platform-up ## Full bring-up, in the required order

# ---------------------------------------------------------------------------
# pause / resume: the cheapest lifecycle pair. Neither one touches Terraform,
# because nothing about the desired state changes: the node containers are
# simply stopped and started again.
#
# Reach for these when you are stepping away. `down` and `destroy` both throw
# work away and cost minutes to undo; pause costs seconds and keeps images,
# PVCs, and the kube context exactly as they were. Quitting OrbStack has the
# same effect implicitly, so a paused cluster is also what you get after a
# reboot.
# ---------------------------------------------------------------------------
pause: ## Stop the cluster containers, keeping all state
	k3d cluster stop $(CLUSTER)
	@echo "Cluster stopped, state kept. Start it again with: gmake resume"

resume: ## Start a paused cluster and wait for its nodes
	k3d cluster start $(CLUSTER)
# k3d returns as soon as the containers are running, which is well before k3s
# inside them is serving. Without this wait the next kubectl in your shell
# tends to fail with a connection refused, which looks like a broken cluster
# and is not. Pods need another moment beyond this to finish restarting.
	kubectl --context $(CONTEXT) wait --for=condition=Ready nodes --all --timeout=120s
	@echo "Nodes are ready. Pods need another moment. Check: kubectl --context $(CONTEXT) -n argocd get applications"

# ---------------------------------------------------------------------------
# down: undo stage 2 only. The cluster survives, so this is the cheap way to
# reset ArgoCD without waiting on a k3s image pull again.
#
# This removes the postgres-credentials Secret. The PVC and its data are
# untouched, because ArgoCD created those, not Terraform.
#
# check-env and $(tf_env) are here for the same reason they are on platform-up:
# destroy has to evaluate the root module, so the no-default variables in
# variables.tf are just as required going down as they were coming up.
# ---------------------------------------------------------------------------
down: check-env ## Remove in-cluster platform resources, keep the cluster
	$(tf_env)
	cd terraform/02-platform
	terraform destroy -auto-approve -input=false
	@echo "Platform removed, cluster kept. Bring it back with: gmake platform-up"

# ---------------------------------------------------------------------------
# destroy: full teardown, in reverse order. Deletes the cluster and therefore
# the PVC and every row in the database.
# ---------------------------------------------------------------------------
destroy: ## Tear down everything including the cluster
# `|| echo` keeps the teardown going when stage 2 fails. Deliberate: if the
# cluster is already gone, stage 2's destroy cannot reach it, and that should
# not block deleting the cluster itself.
#
# This CANNOT be a leading `-`. Under .ONESHELL the whole recipe is one shell
# script, and the -e in .SHELLFLAGS aborts that script at the first failure.
# A `-` only stops make from *reporting* the failure, which it does after the
# shell has already skipped the two lines below, so `gmake destroy` exits 0
# having destroyed nothing. `|| ...` is how you opt one command out of -e.
	$(MAKE) down || echo "WARNING: stage 2 destroy failed. Continuing to delete the cluster." >&2
	cd terraform/01-cluster
	terraform destroy -auto-approve -input=false
	@echo "Everything removed, including the database. Rebuild from scratch with: gmake up"

##@ Release and canary

# ---------------------------------------------------------------------------
# release: open the weekly prod promotion PR.
#
# Deliberately does NOT apply anything. It only opens a PR. Prod changes when
# you merge, and ArgoCD picks it up from there. That separation is the gate.
# ---------------------------------------------------------------------------
release: ## Open the weekly prod release PR
	./scripts/release.sh

# ---------------------------------------------------------------------------
# prod-current, dev-current: which build each service is on right now.
#
# Shows what Git says (origin/main) next to what the cluster is serving, plus
# any canary in flight. Read-only. The script does the work so the same logic
# serves both environments.
# ---------------------------------------------------------------------------
prod-current: ## Show the builds running in prod, in Git and in the cluster
	./scripts/current-builds.sh prod

dev-current: ## Show the builds running in dev, in Git and in the cluster
	./scripts/current-builds.sh dev

# ---------------------------------------------------------------------------
# rollback: open a PR that sets one prod service back to an earlier build.
#
# Like release, it only opens a PR. The gate is the merge. All argument
# checking and the hints for a missing SVC or TO live in the script, which
# prints the recent builds and releases you can choose from.
#
# Usage: gmake rollback                                  asks which service, then what to
#                                                        go back to, then confirms
#        gmake rollback SVC=service-1 TO=26W39B2        a build name
#        gmake rollback SVC=service-1 TO=2026-W38       a release name
#        gmake rollback SVC=service-1 TO=7e25e45        a commit hash
#        add YES=1 to skip the confirmation prompt
# ---------------------------------------------------------------------------
rollback: ## Roll a prod service back via PR. Asks if run bare, or SVC=service-1 TO=<build|release|commit>
	ASSUME_YES="$(YES)" ./scripts/rollback.sh "$(SVC)" "$(TO)"

# ---------------------------------------------------------------------------
# urls: print where each environment answers. Trivial, and saves you
# remembering which hostname is which every time.
# ---------------------------------------------------------------------------
urls: ## Print the ingress URLs for both environments
	@echo "dev    http://dev.localhost:8080"
	@echo "prod   http://prod.localhost:8080"
	@echo "argocd http://argocd.localhost:8080"

# ---------------------------------------------------------------------------
# canary-*: operate on an in-flight prod rollout.
#
# These change no desired state, which is why they are commands rather than
# commits. They advance or unwind a convergence toward what Git already says.
#
# Run bare in a terminal and each asks which service, showing every rollout's
# state first. promote and abort then confirm. Name the service and it acts
# straight away, as it always did. The logic lives in scripts/canary.sh.
#
# Usage: gmake canary-promote                  asks which service
#        gmake canary-promote SVC=service-2    no questions
#        add YES=1 to skip the confirmation after a menu choice
# ---------------------------------------------------------------------------
ROLLOUT_NS := platform-prod

canary-status: ## Watch an in-flight prod rollout. Asks if SVC is not given
	CONTEXT=$(CONTEXT) NAMESPACE=$(ROLLOUT_NS) ./scripts/canary.sh status "$(SVC)"

canary-promote: ## Complete a paused prod rollout. Asks if SVC is not given
	CONTEXT=$(CONTEXT) NAMESPACE=$(ROLLOUT_NS) ASSUME_YES="$(YES)" ./scripts/canary.sh promote "$(SVC)"

canary-abort: ## Scale the canary to zero, leaving stable serving. Asks if SVC is not given
	CONTEXT=$(CONTEXT) NAMESPACE=$(ROLLOUT_NS) ASSUME_YES="$(YES)" ./scripts/canary.sh abort "$(SVC)"
