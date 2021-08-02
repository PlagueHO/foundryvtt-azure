param location string
param storageAccountName string
param storageShareName string = 'foundryvttdata'

@allowed([
  'Premium_LRS'
  'Standard_LRS'
])
param storageSku string = 'Standard_LRS'

resource storageAccount 'Microsoft.Storage/storageAccounts@2021-04-01' = {
  name: storageAccountName
  location: location
  kind: 'FileStorage'
  sku: {
    name: storageSku
  }
  properties: {
    accessTier: 'Hot'
    allowSharedKeyAccess: true
  }

  resource symbolicname 'fileServices@2021-02-01' = {
    name: 'default'

    resource symbolicname 'shares@2021-02-01' = {
      name: storageShareName
      properties: {
        enabledProtocols: 'SMB'
      }
    }
  }
}
