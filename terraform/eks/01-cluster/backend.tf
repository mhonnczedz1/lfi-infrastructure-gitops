# Same bucket as the local modules, different key. The bucket lives in
# ap-southeast-2, which is NOT the region the cluster runs in. The backend
# region is where the state is stored; the provider region is where
# resources are created. Mixing them up fails with a bucket-not-found error.
terraform {
  backend "s3" {
    bucket       = "tfstate-mhonnczedz1-local-platform"
    # key is supplied by the Makefile from platform/registry.yaml:
    #   terraform init -backend-config="key=<stateKeyPrefix>/<stage>/terraform.tfstate"
    # so this file names no cluster.
    region       = "ap-southeast-2"
    use_lockfile = true
    encrypt      = true
  }
}
