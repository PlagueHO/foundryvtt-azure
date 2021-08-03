targetScope = 'subscription'

param location string = 'AustraliaEast'
param resourceGroupName string

@description('The base name that will prefixed to all Azure resources deployed to ensure they are unique.')
param baseResourceName string

@description('Your Foundry VTT username.')
@secure()
param foundryUsername string

@description('Your Foundry VTT password.')
@secure()
param foundryPassword string

@description('The admin key to set Foundry VTT up with.')
@secure()
param foundryAdminKey string

@description('The storage account SKU to use to store the Foundry VTT user data.')
@allowed([
  'Standard_LRS'
  'Standard_RAGRS'
  'Standard_ZRS'
  'Premium_LRS'
  'Premium_ZRS'
  'Standard_GZRS'
  'Standard_RAGZRS'
])
param storageSku string = 'Premium_LRS'

@description('The maximum amount of storage that will be allocated to Foundry VTT user data.')
@maxValue(5120)
param storageShareQuota int = 5120

@description('The number of CPU cores to assign to the Foundry VTT container.')
param containerCpu int = 2

@description('The amount of memory in GB to assign to the Foundry VTT container.')
param containerMemoryInGB string = '2'

resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: resourceGroupName
  location: location
}

module storageAccount './modules/storageAccount.bicep' = {
  name: 'storageAccount'
  scope: rg
  params: {
    location: location
    storageAccountName: baseResourceName
    storageSku: storageSku
    storageShareQuota: storageShareQuota
  }
}

module containerGroup './modules/containerGroup.bicep' = {
  name: 'containerGroup'
  scope: rg
  dependsOn: [
    storageAccount
  ]
  params: {
    location: location
    storageAccountName: baseResourceName
    containerGroupName: '${baseResourceName}-aci'
    containerDnsName: baseResourceName
    foundryUsername: foundryUsername
    foundryPassword: foundryPassword
    foundryAdminKey: foundryAdminKey
    containerCpu: containerCpu
    containerMemoryInGB: containerMemoryInGB
  }
}

output url string = containerGroup.outputs.url
