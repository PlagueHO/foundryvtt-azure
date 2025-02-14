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

@description('The configuration of the Azure Storage SKU to use for storing Foundry VTT user data.')
@allowed([
  'Premium_100GB'
  'Standard_100GB'
])
param storageConfiguration string = 'Premium_100GB'

@description('The configuration of the Azure Container Instance for running the Foundry VTT server.')
@allowed([
  'Small'
  'Medium'
  'Large'
])
param containerConfiguration string = 'Small'

resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: resourceGroupName
  location: location
}

// Deploy VNET module to obtain subnet outputs
module vnet './modules/vnet.bicep' = {
  name: 'vnet'
  scope: rg
  params: {
    location: location
    vnetName: '${baseResourceName}-vnet'
  }
}

module storageAccount './modules/storageAccount.bicep' = {
  name: 'storageAccount'
  scope: rg
  params: {
    location: location
    storageAccountName: baseResourceName
    storageConfiguration: storageConfiguration
    storageSubnetId: vnet.outputs.storageSubnetId
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
    containerConfiguration: containerConfiguration
  }
}

output url string = containerGroup.outputs.url
