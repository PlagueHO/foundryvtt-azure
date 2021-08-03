param location string
param storageAccountName string
param shareName string = 'foundryvttdata'
param containerGroupName string
param containerDnsName string
param containerCpu int = 1
param containerMemoryInGB string = '1.5'

@secure()
param foundryUsername string

@secure()
param foundryPassword string

@secure()
param foundryAdminKey string

resource storageAccount 'Microsoft.Storage/storageAccounts@2021-04-01' existing = {
  name: storageAccountName
}

resource containerGroup 'Microsoft.ContainerInstance/containerGroups@2021-03-01' = {
  name: containerGroupName
  location: location
  properties: {
    containers: [
      {
        name: 'foundryvtt'
        properties: {
          image: 'felddy/foundryvtt:release'
          ports: [
            {
              protocol: 'TCP'
              port: 30000
            }
          ]
          environmentVariables: [
            {
              name: 'FOUNDRY_USERNAME'
              secureValue: foundryUsername
            }
            {
              name: 'FOUNDRY_PASSWORD'
              secureValue: foundryPassword
            }
            {
              name: 'FOUNDRY_ADMIN_KEY'
              secureValue: foundryAdminKey
            }
          ]
          resources: {
            requests: {
              memoryInGB: any(containerMemoryInGB)
              cpu: containerCpu
            }
          }
          volumeMounts: [
            {
              name: 'foundrydata'
              mountPath: '/data'
            }
          ]
        }
      }
    ]
    restartPolicy: 'OnFailure'
    ipAddress: {
      ports: [
        {
          protocol: 'TCP'
          port: 30000
        }
      ]
      type: 'Public'
      dnsNameLabel: containerDnsName
    }
    osType: 'Linux'
    volumes: [
      {
        name: 'foundrydata'
        azureFile: {
          shareName: shareName
          storageAccountName: storageAccountName
          storageAccountKey: storageAccount.listKeys().keys[0].value
        }
      }
    ]
    sku: 'Standard'
  }
}

output url string = 'http://${containerGroup.properties.ipAddress.fqdn}:30000'
