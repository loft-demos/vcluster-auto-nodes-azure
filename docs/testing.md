# Testing Guide

This document covers how to validate the Azure Auto Nodes module, including both the default (managed network) path and the bring-your-own (BYO) network path.

---

## Prerequisites

- Access to an Azure subscription
- AKS cluster with Workload Identity configured (or Service Principal credentials)
- vCluster Platform running in the AKS cluster
- `vcluster` CLI authenticated: `vcluster platform login $YOUR_PLATFORM_HOST`
- `az` CLI authenticated: `az login`

Export common variables for reuse throughout these steps:

```bash
export AZURE_SUBSCRIPTION_ID="<your-subscription-id>"
export AZURE_RESOURCE_GROUP="<your-resource-group>"
export AZURE_LOCATION="eastus"
export VCLUSTER_PROJECT="default"
```

---

## Scenario 1: Default (Managed Network)

This is the baseline path. The module creates a dedicated VNet, subnets, NAT gateway, and NSG per vCluster.

### Deploy

```yaml
# vcluster-default.yaml
controlPlane:
  service:
    spec:
      type: LoadBalancer
privateNodes:
  enabled: true
  autoNodes:
  - provider: ms-azure
    dynamic:
    - name: az-cpu-nodes
      nodeTypeSelector:
      - property: instance-type
        operator: In
        values: ["Standard_D2s_v5"]
      limits:
        cpu: "8"
        memory: "32Gi"
```

```bash
vcluster platform create vcluster test-managed-net \
  -f vcluster-default.yaml \
  --project $VCLUSTER_PROJECT
```

### Verify

```bash
# Watch nodes come up
kubectl get nodes --context vcluster-test-managed-net -w

# Confirm VNet was created
az network vnet list --resource-group $AZURE_RESOURCE_GROUP \
  --query "[?contains(name, 'vcluster')].[name, location]" -o table

# Confirm NSG exists
az network nsg list --resource-group $AZURE_RESOURCE_GROUP \
  --query "[?contains(name, 'vcluster')].[name]" -o table

# Confirm NAT gateway exists
az network nat gateway list --resource-group $AZURE_RESOURCE_GROUP \
  --query "[?contains(name, 'vcluster')].[name]" -o table

# Trigger a node
kubectl run test-pod --image=nginx --context vcluster-test-managed-net
kubectl get nodes --context vcluster-test-managed-net
```

### Teardown

```bash
vcluster platform delete vcluster test-managed-net --project $VCLUSTER_PROJECT

# Confirm Azure resources were removed
az network vnet list --resource-group $AZURE_RESOURCE_GROUP \
  --query "[?contains(name, 'vcluster')]" -o table
```

---

## Scenario 2: BYO Network (Existing VNet)

Pre-create the network resources, then configure the NodeProvider to reuse them.

### Pre-create network resources

```bash
# Create VNet and subnets
az network vnet create \
  --name shared-vnet \
  --resource-group $AZURE_RESOURCE_GROUP \
  --location $AZURE_LOCATION \
  --address-prefix 10.10.0.0/16

az network vnet subnet create \
  --name private-a \
  --resource-group $AZURE_RESOURCE_GROUP \
  --vnet-name shared-vnet \
  --address-prefix 10.10.1.0/24

az network vnet subnet create \
  --name private-b \
  --resource-group $AZURE_RESOURCE_GROUP \
  --vnet-name shared-vnet \
  --address-prefix 10.10.2.0/24

# Create NSG with required rules
az network nsg create \
  --name shared-workers-nsg \
  --resource-group $AZURE_RESOURCE_GROUP \
  --location $AZURE_LOCATION

az network nsg rule create \
  --nsg-name shared-workers-nsg \
  --resource-group $AZURE_RESOURCE_GROUP \
  --name allow-intra-vnet \
  --priority 1000 --direction Inbound --access Allow \
  --protocol '*' --source-address-prefix 10.10.0.0/16 \
  --destination-port-range '*'

az network nsg rule create \
  --nsg-name shared-workers-nsg \
  --resource-group $AZURE_RESOURCE_GROUP \
  --name allow-kubelet \
  --priority 1001 --direction Inbound --access Allow \
  --protocol Tcp --source-address-prefix 10.10.0.0/16 \
  --destination-port-range 10250

az network nsg rule create \
  --nsg-name shared-workers-nsg \
  --resource-group $AZURE_RESOURCE_GROUP \
  --name allow-nodeport \
  --priority 1002 --direction Inbound --access Allow \
  --protocol Tcp --source-address-prefix 10.10.0.0/16 \
  --destination-port-range 30000-32767

az network nsg rule create \
  --nsg-name shared-workers-nsg \
  --resource-group $AZURE_RESOURCE_GROUP \
  --name allow-all-outbound \
  --priority 1000 --direction Outbound --access Allow \
  --protocol '*' --destination-address-prefix '*' \
  --source-address-prefix '*' --destination-port-range '*'
```

### Collect resource IDs

```bash
VNET_ID=$(az network vnet show \
  --name shared-vnet \
  --resource-group $AZURE_RESOURCE_GROUP \
  --query id -o tsv)

SUBNET_A_ID=$(az network vnet subnet show \
  --name private-a \
  --vnet-name shared-vnet \
  --resource-group $AZURE_RESOURCE_GROUP \
  --query id -o tsv)

SUBNET_B_ID=$(az network vnet subnet show \
  --name private-b \
  --vnet-name shared-vnet \
  --resource-group $AZURE_RESOURCE_GROUP \
  --query id -o tsv)

NSG_ID=$(az network nsg show \
  --name shared-workers-nsg \
  --resource-group $AZURE_RESOURCE_GROUP \
  --query id -o tsv)

echo "VNET_ID=$VNET_ID"
echo "SUBNET_IDS=$SUBNET_A_ID,$SUBNET_B_ID"
echo "NSG_ID=$NSG_ID"
```

### Deploy with BYO network

```yaml
# vcluster-byo-vnet.yaml
controlPlane:
  service:
    spec:
      type: LoadBalancer
privateNodes:
  enabled: true
  autoNodes:
  - provider: ms-azure
    properties:
      vcluster.com/vnet-id: "<VNET_ID>"
      vcluster.com/private-subnet-ids: "<SUBNET_A_ID>,<SUBNET_B_ID>"
      vcluster.com/security-group-id: "<NSG_ID>"
    dynamic:
    - name: az-cpu-nodes
      nodeTypeSelector:
      - property: instance-type
        operator: In
        values: ["Standard_D2s_v5"]
      limits:
        cpu: "8"
        memory: "32Gi"
```

```bash
# Substitute values into the YAML, then deploy
vcluster platform create vcluster test-byo-vnet \
  -f vcluster-byo-vnet.yaml \
  --project $VCLUSTER_PROJECT
```

### Verify

```bash
# Confirm no new VNet was created (only shared-vnet should exist)
az network vnet list --resource-group $AZURE_RESOURCE_GROUP \
  --query "[].name" -o tsv

# Confirm VMs attach to the existing subnets
az vm list --resource-group $AZURE_RESOURCE_GROUP \
  --query "[?contains(name, 'test-byo')].{name:name}" -o table

# Check NIC subnet association
az network nic list --resource-group $AZURE_RESOURCE_GROUP \
  --query "[?contains(name, 'test-byo')].{name:name, subnet:ipConfigurations[0].subnet.id}" -o table

# Trigger a node and verify
kubectl run test-pod --image=nginx --context vcluster-test-byo-vnet
kubectl get nodes --context vcluster-test-byo-vnet
```

### Teardown

```bash
vcluster platform delete vcluster test-byo-vnet --project $VCLUSTER_PROJECT

# Manually clean up the pre-created network resources
az network nsg delete --name shared-workers-nsg --resource-group $AZURE_RESOURCE_GROUP
az network vnet delete --name shared-vnet --resource-group $AZURE_RESOURCE_GROUP
```

---

## Scenario 3: Validation Error Cases

These cases confirm that bad inputs are caught early with clear error messages.

### Missing subnets when NSG is set

Set only `vcluster.com/security-group-id` without `private-subnet-ids`. Expect:

```
Error: Set vcluster.com/private-subnet-ids to one or more Azure subnet IDs when using an existing VNet.
```

### Missing NSG when subnets are set

Set only `vcluster.com/private-subnet-ids` without `security-group-id`. Expect:

```
Error: Set vcluster.com/security-group-id when using an existing VNet.
```

### Malformed subnet ID

Provide a subnet ID that doesn't match the Azure resource ID pattern (e.g., just the subnet name). Expect:

```
Error: vcluster.com/private-subnet-ids must contain Azure subnet resource IDs.
```

### Subnets from different VNets

Provide subnet IDs from two different VNets. Expect:

```
Error: All values in vcluster.com/private-subnet-ids must belong to the same virtual network.
```

### VNet ID mismatches subnet VNet

Provide a `vnet-id` that doesn't match the VNet derived from the subnet IDs. Expect:

```
Error: vcluster.com/vnet-id must match the virtual network of vcluster.com/private-subnet-ids.
```

### Cross-subscription resources

Provide subnet IDs, VNet ID, or NSG ID from a different subscription than the configured resource group. Expect:

```
Error: Existing VNet, private subnets, and security group must be in the same subscription as the configured resource group.
Error: All values in vcluster.com/private-subnet-ids must be in the same subscription as the configured resource group.
```

### VNet in wrong location

Provide an existing VNet that is in a different Azure region than the configured `location`. Expect:

```
Error: The existing VNet must be in the same Azure location as the configured node resource group.
```

---

## Scenario 4: Optional CCM/CSI Flags

### Disable LoadBalancer service controller only

```yaml
properties:
  vcluster.com/ccm-lb-enabled: "false"
```

Verify CCM is deployed but the service controller is not managing LoadBalancers:

```bash
kubectl get pods -n kube-system --context vcluster-test-managed-net | grep cloud-controller
```

### Disable CCM and CSI entirely

```yaml
properties:
  vcluster.com/ccm-enabled: "false"
  vcluster.com/csi-enabled: "false"
```

Verify that no CCM, CNM, or CSI pods are deployed and no managed identity role assignments are created for those components:

```bash
kubectl get pods -n kube-system --context vcluster-<name> | grep -E "cloud-controller|csi"
az role assignment list --assignee <identity-principal-id> -o table
```
