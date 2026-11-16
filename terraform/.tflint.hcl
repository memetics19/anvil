# tflint --recursive lints every directory, modules/ubuntu_vm too, on its own. It does not
# evaluate the arguments of module calls: they read files that exist only where Terraform
# runs (the SSH public key at var.ssh_public_key_path), and CI has none.
config {
  call_module_type = "none"
}
