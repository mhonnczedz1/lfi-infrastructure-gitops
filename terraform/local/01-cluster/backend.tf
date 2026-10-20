terraform {
  backend "s3" {
    bucket       = "tfstate-mhonnczedz1-local-platform"
    key          = "local-platform/01-cluster/terraform.tfstate"
    region       = "ap-southeast-2"
    use_lockfile = true
    encrypt      = true
  }
}
