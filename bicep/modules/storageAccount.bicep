param location string
param storageAccountName string
param storageShareName string = 'foundryvttdata'

@allowed([
  'Standard_LRS'
  'Standard_RAGRS'
  'Standard_ZRS'
  'Premium_LRS'
  'Premium_ZRS'
  'Standard_GZRS'
  'Standard_RAGZRS'
])
param storageSku string = 'Standard_LRS'
param storageShareQuota int = 10240

resource storageAccount 'Microsoft.Storage/storageAccounts@2021-04-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: storageSku
  }
  properties: {
    accessTier: 'Hot'
    allowSharedKeyAccess: true
    largeFileSharesState: 'Enabled'
  }

  resource symbolicname 'fileServices@2021-02-01' = {
    name: 'default'

    resource symbolicname 'shares@2021-02-01' = {
      name: storageShareName
      properties: {
        enabledProtocols: 'SMB'
        shareQuota: storageShareQuota
      }
    }
  }
}
