param location string
param storageAccountName string

resource storageAccount 'Microsoft.Storage/storageAccounts@2021-04-01' = {
  name: storageAccountName
  location: location
  kind: 'FileStorage'
  sku: {
    name: 'Premium_LRS'
  }
  properties: {
    accessTier: 'Hot'
    allowSharedKeyAccess: true
  }

  resource symbolicname 'fileServices@2021-02-01' = {
    name: 'default'

    resource symbolicname 'shares@2021-02-01' = {
      name: 'foundrydata'
      properties: {
        enabledProtocols: 'SMB'
      }
    }
  }
}
