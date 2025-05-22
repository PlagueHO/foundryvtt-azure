param location string
param vnetName string
param addressPrefix string = '10.0.0.0/16'
param storageSubnetName string = 'storagePrivateEndpoint'
param storageSubnetPrefix string = '10.0.1.0/24'
param appServiceSubnetName string = 'webAppIntegration'
param appServiceSubnetPrefix string = '10.0.2.0/24'
param containerGroupSubnetName string = 'containerGroupSubnet'
param containerGroupSubnetPrefix string = '10.0.3.0/24'
param bastionSubnetName string = 'AzureBastionSubnet'
param bastionSubnetPrefix string = '10.0.4.0/27'

resource vnet 'Microsoft.Network/virtualNetworks@2021-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressPrefix
      ]
    }
    subnets: [
      {
        name: storageSubnetName
        properties: {
          addressPrefix: storageSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: appServiceSubnetName
        properties: {
          addressPrefix: appServiceSubnetPrefix
          delegations: [
            {
              name: 'delegation'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
      {
        name: containerGroupSubnetName
        properties: {
          addressPrefix: containerGroupSubnetPrefix
        }
      }
      {
        name: bastionSubnetName
        properties: {
          addressPrefix: bastionSubnetPrefix
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output storageSubnetId string = vnet.properties.subnets[0].id
output appServiceSubnetId string = vnet.properties.subnets[1].id
output containerGroupSubnetId string = vnet.properties.subnets[2].id
output bastionSubnetId string = vnet.properties.subnets[3].id
