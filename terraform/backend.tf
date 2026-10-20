# The S3 endpoint identifies the site, so it is not committed: `make tf-init`
# supplies it as partial backend configuration built from the Keychain.
# Credentials come from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (scripts/env.sh).
terraform {
  backend "s3" {
    bucket         = "tfstate"
    key            = "homelab/terraform.tfstate"
    region         = "us-east-1"
    use_path_style = true
    use_lockfile   = true

    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }
}
