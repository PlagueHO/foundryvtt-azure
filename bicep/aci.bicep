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

@secure()
param foundryAdminKey string

@allowed([
  'Premium_LRS'
  'Standard_LRS'
])
param storageSku string = 'Standard_LRS'

param containerCpu int = 1
param containerMemoryInGB string = '1.5'

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
  }
}

module containerGroup './modules/containerGroup.bicep' = {
  name: 'containerGroup'
  scope: rg
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
