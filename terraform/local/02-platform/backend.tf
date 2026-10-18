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
