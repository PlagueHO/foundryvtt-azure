param location string
param bastionName string = 'defaultBastion'
param bastionSubnetId string

resource bastionPublicIP 'Microsoft.Network/publicIPAddresses@2020-05-01' = {
  name: '${bastionName}-pip'
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    idleTimeoutInMinutes: 4
  }
}

resource bastionHost 'Microsoft.Network/bastionHosts@2024-05-01' = {
  name: bastionName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    ipConfigurations: [
      {
        name: 'bastionIpConfiguration'
        properties: {
          subnet: {
            id: bastionSubnetId
          }
          publicIPAddress: {
            id: bastionPublicIP.id
          }
        }
      }
    ]
    enableFileCopy: true
  }
}

output bastionHostId string = bastionHost.id
output bastionPublicIPId string = bastionPublicIP.id
