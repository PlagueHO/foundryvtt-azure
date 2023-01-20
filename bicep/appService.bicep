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

@description('The Azure App Service SKU for running the Foundry VTT server and optionally the DDB-Proxy.')
@allowed([
  'F1'
  'B1'
  'B2'
  'B3'
  'P1V2'
  'P2V2'
  'P3V2'
  'P1V3'
  'P2V3'
  'P3V3'
])
param appServicePlanConfiguration string = 'P1V2'

@description('Deploy a D&D Beyond proxy into the app service plan.')
param deployDdbProxy bool = false

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
    storageConfiguration: storageConfiguration
  }
}

module appServicePlan './modules/appServicePlan.bicep' = {
  name: 'appServicePlan'
  scope: rg
  dependsOn: [
    storageAccount
  ]
  params: {
    location: location
    appServicePlanName: '${baseResourceName}-asp'
    appServicePlanConfiguration: appServicePlanConfiguration
  }
}

module webAppFoundryVtt './modules/webAppFoundryVtt.bicep' = {
  name: 'webAppFoundryVtt'
  scope: rg
  dependsOn: [
    appServicePlan
  ]
  params: {
    location: location
    appServicePlanId: appServicePlan.outputs.appServicePlanId
    storageAccountName: baseResourceName
    webAppName: baseResourceName
    foundryUsername: foundryUsername
    foundryPassword: foundryPassword
    foundryAdminKey: foundryAdminKey
  }
}

module webAppDdbProxy './modules/webAppDdbProxy.bicep' = if (deployDdbProxy) {
  name: 'webAppDdbProxy'
  scope: rg
  dependsOn: [
    appServicePlan
  ]
  params: {
    location: location
    appServicePlanId: appServicePlan.outputs.appServicePlanId
    webAppName: '${baseResourceName}ddbproxy'
  }
}

output url string = webAppFoundryVtt.outputs.url
output ddbproxyurl string = webAppDdbProxy.outputs.url
