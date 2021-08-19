param location string
param storageAccountName string
param storageShareName string = 'foundryvttdata'

@allowed([
  'Premium_5GB'
  'Premium_10GB'
  'Premium_20GB'
  'Standard_5GB'
  'Standard_10GB'
  'Standard_20GB'
])
param storageConfiguration string = 'Premium_10GB'

var storageConfigurationMap = {
  Premium_5GB: {
    kind: 'FileStorage'
    sku: 'Premium_LRS'
    shareQuota: 5120
    largeFileSharesState: null
  }
  Premium_10GB: {
    kind: 'FileStorage'
    sku: 'Premium_LRS'
    shareQuota: 10240
    largeFileSharesState: 'Enabled'
  }
  Premium_20GB: {
    kind: 'FileStorage'
    sku: 'Premium_LRS'
    shareQuota: 20480
    largeFileSharesState: 'Enabled'
  }
  Standard_5GB: {
    kind: 'StorageV2'
    sku: 'Standard_LRS'
    shareQuota: 5120
    largeFileSharesState: null
  }
  Standard_10GB: {
    kind: 'StorageV2'
    sku: 'Standard_LRS'
    shareQuota: 10240
    largeFileSharesState: 'Enabled'
  }
  Standard_20GB: {
    kind: 'StorageV2'
    sku: 'Standard_LRS'
    shareQuota: 20480
    largeFileSharesState: 'Enabled'
  }
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2021-04-01' = {
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
  }

  resource symbolicname 'fileServices@2021-02-01' = {
    name: 'default'

    resource symbolicname 'shares@2021-02-01' = {
      name: storageShareName
      properties: {
        enabledProtocols: 'SMB'
        shareQuota: storageConfigurationMap[storageConfiguration].shareQuota
      }
    }
  }
}
