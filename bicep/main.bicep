targetScope = 'subscription'

param location string
param resourceGroupName string
param baseResourceName string

@secure()
param foundryUsername string

@secure()
param foundryPassword string

@secure()
param foundryAdminKey string


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
  }
}
