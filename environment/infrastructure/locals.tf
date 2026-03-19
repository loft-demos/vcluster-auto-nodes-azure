locals {
  location            = nonsensitive(module.validation.location)
  resource_group_name = nonsensitive(module.validation.resource_group)
  resource_group_id   = data.azurerm_resource_group.current.id
  location_rgroup_key = format("%s-%s", local.location, local.resource_group_name)
  subscription_id     = split("/", data.azurerm_resource_group.current.id)[2]

  vcluster_name      = nonsensitive(var.vcluster.instance.metadata.name)
  vcluster_namespace = nonsensitive(var.vcluster.instance.metadata.namespace)

  # A random_id resource cannot be used here because of how the VNet module applies resources.
  # The module needs resource names to be known in advance.
  random_id = substr(md5(format("%s%s", local.vcluster_namespace, local.vcluster_name)), 0, 8)

  # The name of the property is set to 'vpc-cidr' to keep the same naming accross different quick start templates
  vnet_cidr_block = nonsensitive(try(var.vcluster.properties["vcluster.com/vpc-cidr"], "10.5.0.0/16"))

  existing_vnet_id = trimspace(nonsensitive(try(var.vcluster.properties["vcluster.com/vnet-id"], "")))
  existing_private_subnet_ids = compact([
    for subnet_id in split(",", nonsensitive(try(var.vcluster.properties["vcluster.com/private-subnet-ids"], ""))) :
    trimspace(subnet_id)
  ])
  existing_security_group_id = trimspace(nonsensitive(try(var.vcluster.properties["vcluster.com/security-group-id"], "")))

  subnet_id_pattern = "^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+/subnets/[^/]+$"
  vnet_id_pattern = "^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+$"
  security_group_id_pattern = "^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/networkSecurityGroups/[^/]+$"

  use_existing_network = (
    local.existing_vnet_id != "" ||
    length(local.existing_private_subnet_ids) > 0 ||
    local.existing_security_group_id != ""
  )

  existing_subnet_ids_are_valid = alltrue([
    for subnet_id in local.existing_private_subnet_ids :
    can(regex(local.subnet_id_pattern, subnet_id))
  ])
  existing_vnet_id_is_valid = (
    local.existing_vnet_id == "" ||
    can(regex(local.vnet_id_pattern, local.existing_vnet_id))
  )
  existing_security_group_id_is_valid = (
    local.existing_security_group_id != "" &&
    can(regex(local.security_group_id_pattern, local.existing_security_group_id))
  )

  existing_private_subnet_id_parts = {
    for subnet_id in local.existing_private_subnet_ids :
    subnet_id => split("/", subnet_id)
    if can(regex(local.subnet_id_pattern, subnet_id))
  }
  existing_private_subnet_vnet_ids = distinct([
    for subnet_id in keys(local.existing_private_subnet_id_parts) :
    join("/", slice(local.existing_private_subnet_id_parts[subnet_id], 0, 9))
  ])
  existing_private_subnet_subscription_ids = distinct([
    for subnet_id, parts in local.existing_private_subnet_id_parts :
    parts[2]
  ])
  resolved_vnet_id = local.existing_vnet_id != "" ? local.existing_vnet_id : try(local.existing_private_subnet_vnet_ids[0], null)

  existing_vnet_id_parts = local.resolved_vnet_id != null && can(regex(local.vnet_id_pattern, local.resolved_vnet_id)) ? split("/", local.resolved_vnet_id) : []
  existing_vnet_name     = length(local.existing_vnet_id_parts) > 0 ? local.existing_vnet_id_parts[8] : null
  existing_vnet_resource_group_name = length(local.existing_vnet_id_parts) > 0 ? local.existing_vnet_id_parts[4] : null
  existing_vnet_subscription_id     = length(local.existing_vnet_id_parts) > 0 ? local.existing_vnet_id_parts[2] : null

  existing_security_group_id_parts = local.existing_security_group_id_is_valid ? split("/", local.existing_security_group_id) : []
  existing_security_group_name = local.existing_security_group_id_is_valid ? local.existing_security_group_id_parts[8] : null
  existing_security_group_resource_group_name = (
    local.existing_security_group_id_is_valid ? local.existing_security_group_id_parts[4] : null
  )
  existing_security_group_subscription_id = (
    local.existing_security_group_id_is_valid ? local.existing_security_group_id_parts[2] : null
  )

  create_network = !local.use_existing_network

  # Use 2 AZs if available
  azs = try(
    length(module.regions.regions) > 0 && length(module.regions.regions[0].zones) > 0 ?
    slice(module.regions.regions[0].zones, 0, 2) :
    ["1"],
    ["1"]
  )

  public_subnets  = [for idx, az in local.azs : cidrsubnet(local.vnet_cidr_block, 8, idx)]
  private_subnets = [for idx, az in local.azs : cidrsubnet(local.vnet_cidr_block, 8, idx + length(local.azs))]

  ccm_enabled = nonsensitive(try(tobool(var.vcluster.properties["vcluster.com/ccm-enabled"]), true))
  csi_enabled = nonsensitive(try(tobool(var.vcluster.properties["vcluster.com/csi-enabled"]), true))
}
