# apps-eks

The EKS cluster's `root` Application watches this directory. It holds the
generated ApplicationSets under `appsets/subscriptions/` (one per subscription)
and the `teams` project under `projects/`, all written by
`scripts/gen-appsets.sh` from `platform/subscriptions/eks/` and
`platform/profiles/`, plus the add-ons set (`appsets/addons.yaml`). They create
every service and database Application from the team-owned config repositories
the subscriptions name. There are no hand-written service Applications here.
