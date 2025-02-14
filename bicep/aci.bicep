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

@description('Deploy a Bastion host into the VNET.')
param deployBastion bool = false

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

// Add DNS Private Zone module for ACI
module dnsPrivateZone './modules/dnsPrivateZone.bicep' = {
  name: 'dnsPrivateZone'
  scope: rg
  params: {
    location: location
    vnetId: vnet.outputs.vnetId
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

module bastion './modules/bastion.bicep' = if (deployBastion) {
  name: 'bastion'
  scope: rg
  params: {
    location: location
    bastionName: '${baseResourceName}-bastion'
    bastionSubnetId: vnet.outputs.bastionSubnetId
  }
}

output url string = containerGroup.outputs.url
