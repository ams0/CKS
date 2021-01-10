resource "azurerm_resource_group" "cks" {
  name     = var.resource_group_name
  location = var.location
}

resource "azurerm_virtual_network" "cks" {
  name                = "cks"
  location            = azurerm_resource_group.cks.location
  resource_group_name = azurerm_resource_group.cks.name
  address_space       = var.vnet_address_prefix

}

resource "azurerm_subnet" "cks" {
  name                 = "cks"
  resource_group_name  = azurerm_resource_group.cks.name
  virtual_network_name = azurerm_virtual_network.cks.name
  address_prefixes     = var.subnet_address_prefix
}

resource "azurerm_network_security_group" "allow-kube-api" {
  name                = "allow-kube-api"
  location            = azurerm_resource_group.cks.location
  resource_group_name = azurerm_resource_group.cks.name
  security_rule {
    name                       = "allow-ssh"
    description                = "allow-ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "allow-api"
    description                = "allow-api"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "6443"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "kube-api" {
  subnet_id                 = azurerm_subnet.cks.id
  network_security_group_id = azurerm_network_security_group.allow-kube-api.id
}

resource "azurerm_private_dns_zone" "cluster" {
  name                = "cluster.local"
  resource_group_name = azurerm_resource_group.cks.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "cks" {
  name                  = "cks"
  resource_group_name   = azurerm_resource_group.cks.name
  private_dns_zone_name = azurerm_private_dns_zone.cluster.name
  virtual_network_id    = azurerm_virtual_network.cks.id
  registration_enabled  = true
}


resource "azurerm_public_ip" "controller" {
  name                = "controller"
  location            = var.location
  resource_group_name = azurerm_resource_group.cks.name
  allocation_method   = "Static"
  domain_name_label   = "ckskubeadm"
}

resource "azurerm_network_interface" "controller" {
  name                = "controller"
  location            = azurerm_resource_group.cks.location
  resource_group_name = azurerm_resource_group.cks.name

  ip_configuration {
    name                          = "cks"
    subnet_id                     = azurerm_subnet.cks.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.controller.id
  }
}

resource "tls_private_key" "sshkey" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_file" "sshkey" {
  sensitive_content = tls_private_key.sshkey.private_key_pem
  filename          = "sshkey"
  file_permission   = 0600
}

resource "random_string" "token1" {
  length  = 6
  special = false
  upper   = false
}

resource "random_string" "token2" {
  length  = 16
  special = false
  upper   = false
}

locals {
  # Ids for multiple sets of EC2 instances, merged together
  token = join(".", [random_string.token1.result, random_string.token2.result])
}

data "template_file" "controller_script" {
  template = file("scripts/controller_script.sh")
  vars = {
    token = local.token
    api_endpoint = azurerm_public_ip.controller.fqdn
  }
}

data "template_file" "node_script" {
  template = file("scripts/node_script.sh")
  vars = {
    token = local.token
  }
}

resource "azurerm_linux_virtual_machine" "controller" {
  name                = "controller"
  resource_group_name = azurerm_resource_group.cks.name
  location            = azurerm_resource_group.cks.location
  size                = var.controller_size
  admin_username      = var.admin_username
  network_interface_ids = [
    azurerm_network_interface.controller.id,
  ]

  admin_ssh_key {
    username   = var.admin_username
    public_key = tls_private_key.sshkey.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }

  custom_data = base64encode(data.template_file.controller_script.rendered)

}

#controller script on Azure it's about 2.45 seconds

resource "null_resource" "previous" {}


resource "time_sleep" "wait_3_minutes" {
  depends_on = [null_resource.previous]

  create_duration = "180s"
}

resource "azurerm_linux_virtual_machine_scale_set" "node" {
  depends_on          = [time_sleep.wait_3_minutes, local_file.sshkey]
  name                = "nodes"
  resource_group_name = azurerm_resource_group.cks.name
  location            = azurerm_resource_group.cks.location
  sku                 = var.node_size
  instances           = var.node_count
  admin_username      = var.admin_username

  admin_ssh_key {
    username   = var.admin_username
    public_key = tls_private_key.sshkey.public_key_openssh
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }

  os_disk {
    storage_account_type = "Standard_LRS"
    caching              = "ReadWrite"
  }

  network_interface {
    name    = "node"
    primary = true

    ip_configuration {
      name      = "internal"
      primary   = true
      subnet_id = azurerm_subnet.cks.id
    }
  }

  custom_data = base64encode(data.template_file.node_script.rendered)
# on mac os x, use: `sed -i '' -e`; on linux, use simply `sed -i` 
  provisioner "local-exec" {
    command = "chmod 0600 sshkey ; scp -i sshkey -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no  ${var.admin_username}@${azurerm_public_ip.controller.fqdn}:/.kube/config kube.config >/dev/null 2>&1 && sed -i '' -e 's/${azurerm_linux_virtual_machine.controller.private_ip_address}/${azurerm_public_ip.controller.fqdn}/g' kube.config"
  }
}

