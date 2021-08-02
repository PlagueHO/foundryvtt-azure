param location string
param storageAccountName string
param shareName string = 'foundryvttdata'

@allowed([
  'Premium_LRS'
  'Standard_LRS'
])
param sku string = 'Premium_LRS'

resource storageAccount 'Microsoft.Storage/storageAccounts@2021-04-01' = {
  name: storageAccountName
  location: location
  kind: 'FileStorage'
  sku: {
    name: sku
  }
  properties: {
    accessTier: 'Hot'
    allowSharedKeyAccess: true
  }

  resource symbolicname 'fileServices@2021-02-01' = {
    name: 'default'

    resource symbolicname 'shares@2021-02-01' = {
      name: shareName
      properties: {
        enabledProtocols: 'SMB'
      }
    }
  }
}
