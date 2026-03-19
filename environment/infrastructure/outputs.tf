output "private_subnet_ids" {
  description = "A list of private subnet ids"
  value = local.use_existing_network ? [
    for subnet_id in local.existing_private_subnet_ids :
    try(data.azurerm_subnet.existing_private[subnet_id].id, subnet_id)
  ] : [
    for az in local.azs : module.subnet_private[format("vcluster-private-%s-%s", local.random_id, az)].resource_id
  ]
}

output "public_subnet_ids" {
  description = "A list of public subnet ids"
  value = local.create_network ? [
    for az in local.azs : module.subnet_public[format("vcluster-public-%s-%s", local.random_id, az)].resource_id
  ] : []
}

output "security_group_id" {
  description = "Security group id to attach to worker nodes"
  value = local.use_existing_network ?
    local.existing_security_group_id :
    azurerm_network_security_group.workers[0].id
}

output "security_group_name" {
  description = "Security group name for CCM to expose LB"
  value = local.use_existing_network ?
    try(data.azurerm_network_security_group.existing[0].name, local.existing_security_group_name) :
    azurerm_network_security_group.workers[0].name
}

output "security_group_resource_group_name" {
  description = "Security group resource group name for CCM to expose LB"
  value = local.use_existing_network ?
    local.existing_security_group_resource_group_name :
    local.resource_group_name
}

output "vnet_id" {
  description = "Virtual Network ID"
  value = local.use_existing_network ?
    local.resolved_vnet_id :
    module.vnet[local.location_rgroup_key].resource_id
}

output "vnet_name" {
  description = "Virtual Network name"
  value = local.use_existing_network ?
    try(data.azurerm_virtual_network.existing[0].name, local.existing_vnet_name) :
    format("vcluster-vnet-%s", local.random_id)
}

output "vnet_resource_group_name" {
  description = "Virtual Network resource group name"
  value = local.use_existing_network ?
    local.existing_vnet_resource_group_name :
    local.resource_group_name
}

output "resource_group_name" {
  value = local.resource_group_name
}

output "location" {
  value = local.location
}

output "subscription_id" {
  value = local.subscription_id
}

# For IMDS token requests
output "vcluster_node_client_id" {
  value = azurerm_user_assigned_identity.vcluster_node.client_id
}

# For VM
output "vcluster_node_identity_id" {
  value = azurerm_user_assigned_identity.vcluster_node.id
}
