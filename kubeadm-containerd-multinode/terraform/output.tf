output "token" {
  value = local.token
}

output "ssh" {
  value = tls_private_key.sshkey.private_key_pem

}

output "controller-ip" {
  value = azurerm_public_ip.controller.fqdn
}
