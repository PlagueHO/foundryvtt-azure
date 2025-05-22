param location string
param storageAccountName string
param storageShareName string = 'foundryvttdata'

@allowed([
  'Premium_100GB'
  'Standard_100GB'
])
param storageConfiguration string = 'Premium_100GB'

// New parameter for subnet id from the VNET module
param storageSubnetId string
param dnsZoneId string

var storageConfigurationMap = {
  Premium_100GB: {
    kind: 'FileStorage'
    sku: 'Premium_LRS'
    shareQuota: 100
    largeFileSharesState: null
  }
  Standard_100GB: {
    kind: 'StorageV2'
    sku: 'Standard_LRS'
    shareQuota: 100
    largeFileSharesState: null
  }
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  kind: storageConfigurationMap[storageConfiguration].kind
  sku: {
    name: storageConfigurationMap[storageConfiguration].sku
  }
  properties: {
    accessTier: 'Hot'
    allowSharedKeyAccess: true
    largeFileSharesState: storageConfigurationMap[storageConfiguration].largeFileSharesState
    publicNetworkAccess: 'Disabled'
  }

  resource symbolicname 'fileServices@2023-05-01' = {
    name: 'default'

    resource symbolicname 'shares@2023-05-01' = {
      name: storageShareName
      properties: {
        enabledProtocols: 'SMB'
        shareQuota: storageConfigurationMap[storageConfiguration].shareQuota
      }
    }
  }
}

// Private Endpoint for Storage Account
resource storagePrivateEndpoint 'Microsoft.Network/privateEndpoints@2021-05-01' = {
  name: '${storageAccountName}-pe'
  location: location
  properties: {
    subnet: {
      id: storageSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'storageConnection'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'file'
          ]
        }
      }
    ]
  }
}

// Register the Storage Account private endpoint in the Private DNS Zone
resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2020-11-01' = {
  name: 'default'
  parent: storagePrivateEndpoint
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'config'
        properties: {
          privateDnsZoneId: dnsZoneId
        }
      }
    ]
  }
}
