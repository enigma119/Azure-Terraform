locals {
  input_file         = "./config.yml"
  input_file_content = fileexists(local.input_file) ? file(local.input_file) : "NoInputFileFound: true"
  input              = yamldecode(local.input_file_content)
}

# Define the Azure provider and authentication details
provider "azurerm" {
  features {}
  skip_provider_registration = true
  subscription_id = local.input.access.subscription_id
  client_id       = local.input.access.client_id
  client_secret   = local.input.access.client_secret
  tenant_id       = local.input.access.tenant_id
}

# Define the resource group
resource "azurerm_resource_group" "staging" {
  name     = "staging-rg"
  location = "West Europe"
}

# Define the virtual network
resource "azurerm_virtual_network" "staging" {
  name                = "staging-vnet"
  resource_group_name = azurerm_resource_group.staging.name
  address_space       = ["10.0.0.0/16"]
  location = azurerm_resource_group.staging.location
}

# Define the subnet
resource "azurerm_subnet" "staging" {
  name                 = "staging-subnet"
  resource_group_name  = azurerm_resource_group.staging.name
  virtual_network_name = azurerm_virtual_network.staging.name
  address_prefixes      = ["10.0.0.0/24"]
}

# Define the network security group
resource "azurerm_network_security_group" "staging" {
  name                = "staging-nsg"
  resource_group_name = azurerm_resource_group.staging.name
  location = azurerm_resource_group.staging.location

  # Add security rule for default SSH
  security_rule {
    name                       = "SSH1"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # Add security rule for HTTP
  security_rule {
    name                       = "HTTP"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # Add security rule for HTTPS
  security_rule {
    name                       = "HTTPS"
    priority                   = 1003
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}



# Define the public IP address
resource "azurerm_public_ip" "staging" {
  count                = 2
  name                 = "staging-public-ip-${count.index + 1}"
  resource_group_name  = azurerm_resource_group.staging.name
  location             = azurerm_resource_group.staging.location
  allocation_method    = "Static"
  idle_timeout_in_minutes = 30
}

locals {
  public_ip_address_ids = [for ip in azurerm_public_ip.staging : ip.id]
  public_ip_addresses   = [for ip in azurerm_public_ip.staging : ip.ip_address]
}


# Define the network interface
resource "azurerm_network_interface" "staging" {
  count               = 2
  name                = "staging-nic-${count.index + 1}"
  location            = azurerm_resource_group.staging.location
  resource_group_name = azurerm_resource_group.staging.name

  ip_configuration {
    name                          = "staging-nic-config-${count.index + 1}"
    subnet_id                     = azurerm_subnet.staging.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = local.public_ip_address_ids[count.index]
  }

}

resource "azurerm_network_interface_security_group_association" "nsg_association" {
  count = 2
  network_interface_id      = "${azurerm_network_interface.staging[count.index].id}"
  network_security_group_id = azurerm_network_security_group.staging.id
}

# Define the virtual machine
resource "azurerm_virtual_machine" "staging" {
  count               = 2
  name                = "staging-vm-${count.index + 1}"
  location            = azurerm_resource_group.staging.location
  resource_group_name = azurerm_resource_group.staging.name
  vm_size             = "Standard_DS2_v2"
  network_interface_ids = [azurerm_network_interface.staging[count.index].id]

  storage_image_reference {
    publisher = "Debian"
    offer     = "debian-11"
    sku       = "11"
    version   = "latest"
  }

  storage_os_disk {
    name              = "staging-vm-osdisk-${count.index + 1}"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Standard_LRS"
    disk_size_gb      = 30
  }

  os_profile {
    computer_name  = "staging-vm-${count.index + 1}"
    admin_username = local.input.user.admin_username
    admin_password = local.input.user.admin_password
  }

  os_profile_linux_config {
    disable_password_authentication = true
    ssh_keys {
      path     = "/home/adminuser/.ssh/authorized_keys"
      key_data = file("~/.ssh/id_rsa.pub")
    }
  }

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      host        = local.public_ip_addresses[count.index]
      user        = local.input.user.admin_username
      private_key = file("~/.ssh/id_rsa")
    }

    inline = [

      /* Install azure cli */
      "curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash",

      /* Install Docker */
      "sudo apt-get update",
      "sudo curl -fsSL https://get.docker.com -o get-docker.sh",
      "sudo sh get-docker.sh",
      "sudo usermod -aG docker ansible",
      "sudo newgrp docker",

      /* Install ansible */
      "sudo apt-get update",
      "sudo apt install -y python3 python3-pip",
      "python3 -m pip install --user ansible",
      "sudo usermod -aG ansible ansible",
    ]
  }
}
