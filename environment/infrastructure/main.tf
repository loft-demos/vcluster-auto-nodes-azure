module "validation" {
  source = "./validation"

  location        = var.vcluster.properties["location"]
  resource_group  = var.vcluster.properties["resource-group"]
  subscription_id = try(var.vcluster.properties["subscription-id"], null)
}

data "azurerm_resource_group" "current" {
  name = local.resource_group_name
}

resource "null_resource" "validate_existing_network" {
  count = local.use_existing_network ? 1 : 0

  lifecycle {
    precondition {
      condition     = length(local.existing_private_subnet_ids) > 0
      error_message = "Set vcluster.com/private-subnet-ids to one or more Azure subnet IDs when using an existing VNet."
    }

    precondition {
      condition     = local.existing_security_group_id != ""
      error_message = "Set vcluster.com/security-group-id when using an existing VNet."
    }

    precondition {
      condition     = local.existing_subnet_ids_are_valid
      error_message = "vcluster.com/private-subnet-ids must contain Azure subnet resource IDs."
    }

    precondition {
      condition     = local.existing_vnet_id_is_valid
      error_message = "vcluster.com/vnet-id must be an Azure virtual network resource ID."
    }

    precondition {
      condition     = local.existing_security_group_id_is_valid
      error_message = "vcluster.com/security-group-id must be an Azure network security group resource ID."
    }

    precondition {
      condition     = length(local.existing_private_subnet_vnet_ids) == 1
      error_message = "All values in vcluster.com/private-subnet-ids must belong to the same virtual network."
    }

    precondition {
      condition = (
        local.existing_vnet_id == "" ||
        length(local.existing_private_subnet_vnet_ids) != 1 ||
        lower(local.existing_private_subnet_vnet_ids[0]) == lower(local.existing_vnet_id)
      )
      error_message = "vcluster.com/vnet-id must match the virtual network of vcluster.com/private-subnet-ids."
    }

    precondition {
      condition = (
        !local.existing_vnet_id_is_valid ||
        !local.existing_security_group_id_is_valid ||
        (
          lower(local.existing_vnet_subscription_id) == lower(local.subscription_id) &&
          lower(local.existing_security_group_subscription_id) == lower(local.subscription_id)
        )
      )
      error_message = "Existing VNet, private subnets, and security group must be in the same subscription as the configured resource group."
    }

    precondition {
      condition = alltrue([
        for sub_id in local.existing_private_subnet_subscription_ids :
        lower(sub_id) == lower(local.subscription_id)
      ])
      error_message = "All values in vcluster.com/private-subnet-ids must be in the same subscription as the configured resource group."
    }
  }
}

data "azurerm_virtual_network" "existing" {
  count = local.use_existing_network && local.existing_vnet_name != null ? 1 : 0

  name                = local.existing_vnet_name
  resource_group_name = local.existing_vnet_resource_group_name
}

data "azurerm_subnet" "existing_private" {
  for_each = local.use_existing_network && local.existing_subnet_ids_are_valid ? local.existing_private_subnet_id_parts : {}

  name                 = each.value[10]
  virtual_network_name = each.value[8]
  resource_group_name  = each.value[4]
}

data "azurerm_network_security_group" "existing" {
  count = local.use_existing_network && local.existing_security_group_id_is_valid ? 1 : 0

  name                = local.existing_security_group_name
  resource_group_name = local.existing_security_group_resource_group_name
}

resource "null_resource" "validate_existing_network_resources" {
  count = (
    local.use_existing_network &&
    local.existing_vnet_name != null &&
    local.existing_security_group_id_is_valid
  ) ? 1 : 0

  lifecycle {
    precondition {
      condition     = lower(data.azurerm_virtual_network.existing[0].location) == lower(local.location)
      error_message = "The existing VNet must be in the same Azure location as the configured node resource group."
    }

    precondition {
      condition     = lower(data.azurerm_network_security_group.existing[0].location) == lower(local.location)
      error_message = "The existing network security group must be in the same Azure location as the configured node resource group."
    }
  }
}

module "regions" {
  source  = "Azure/avm-utl-regions/azurerm"
  version = "~> 0.7.0"

  region_filter          = [local.location]
  has_availability_zones = true
}

module "nat_gateway" {
  for_each = local.create_network ? { (local.location_rgroup_key) = true } : {}

  source  = "Azure/avm-res-network-natgateway/azurerm"
  version = "~> 0.2.0"

  name                = format("vcluster-nat-gateway-%s", local.random_id)
  location            = local.location
  resource_group_name = local.resource_group_name

  # Configure public IPs for NAT Gateway
  public_ips = {
    pip1 = {
      name = format("vcluster-nat-pip-%s", local.random_id)
    }
  }

  public_ip_configuration = {
    allocation_method = "Static"
    sku               = "Standard"
    zones             = local.azs
  }

  tags = {
    "name"               = format("vcluster-nat-gateway-%s", local.random_id)
    "vcluster:name"      = local.vcluster_name
    "vcluster:namespace" = local.vcluster_namespace
  }
}

module "vnet" {
  for_each = local.create_network ? { (local.location_rgroup_key) = true } : {}

  source  = "Azure/avm-res-network-virtualnetwork/azurerm"
  version = "~> 0.15.0"

  name          = format("vcluster-vnet-%s", local.random_id)
  location      = local.location
  parent_id     = data.azurerm_resource_group.current.id
  address_space = [local.vnet_cidr_block]

  # There is a bug that prevents subnets deletion in case of terraform timeout.
  # That's why subnet management has been moved to separate resources.
  subnets = {}

  tags = {
    "name"               = format("vcluster-vnet-%s", local.random_id)
    "vcluster:name"      = local.vcluster_name
    "vcluster:namespace" = local.vcluster_namespace
  }

  enable_telemetry = false
}

module "subnet_public" {
  source  = "Azure/avm-res-network-virtualnetwork/azurerm//modules/subnet"
  version = "~> 0.15.0"

  for_each = local.create_network ? {
    for idx, az in local.azs :
    format("vcluster-public-%s-%s", local.random_id, az) => {
      prefix = local.public_subnets[idx]
    }
  } : {}

  parent_id        = module.vnet[local.location_rgroup_key].resource_id
  name             = each.key
  address_prefixes = [each.value.prefix]
}

module "subnet_private" {
  source  = "Azure/avm-res-network-virtualnetwork/azurerm//modules/subnet"
  version = "~> 0.15.0"

  for_each = local.create_network ? {
    for idx, az in local.azs :
    format("vcluster-private-%s-%s", local.random_id, az) => {
      prefix = local.private_subnets[idx]
    }
  } : {}

  parent_id        = module.vnet[local.location_rgroup_key].resource_id
  name             = each.key
  address_prefixes = [each.value.prefix]

  network_security_group = {
    id = azurerm_network_security_group.workers[0].id
  }
  nat_gateway = {
    id = module.nat_gateway[local.location_rgroup_key].resource.id
  }
}
