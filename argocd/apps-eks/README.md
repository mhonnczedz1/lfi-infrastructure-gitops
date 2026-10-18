# apps-eks

The EKS cluster's `root` Application watches this directory. It holds the
generated ApplicationSets under `appsets/` (one in `services/` and one in
`data/` for each subscription) and the `teams` project under `projects/`, all
written by `scripts/gen-appsets.sh`. They create every service and datastore
Application from `platform/subscriptions/eks/` and the team-owned config
repositories those name. There are no hand-written service Applications here.
