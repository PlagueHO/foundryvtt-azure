param location string
param appServicePlanId string
param webAppName string

var linuxFxVersion = 'DOCKER|ghcr.io/mrprimate/ddb-proxy:latest'

resource webApp 'Microsoft.Web/sites@2023-12-01' = {
  name: webAppName
  location: location
  kind: 'app,linux,container'
  properties: {
    serverFarmId: appServicePlanId
    httpsOnly: true
    siteConfig: {
      numberOfWorkers: 1
      linuxFxVersion: linuxFxVersion
      appSettings: [
        {
          name: 'VIRTUAL_HOST'
          value: webAppName
        }
        {
          name: 'VIRTUAL_PORT'
          value: '3000'
        }
        {
          name: 'DOCKER_REGISTRY_SERVER_URL'
          value: 'https://ghcr.io'
        }
      ]
      healthCheckPath: '/ping' // Added health check path
    }
  }

  resource config 'config@2023-12-01' = {
    name: 'web'
    properties: {
      linuxFxVersion: linuxFxVersion
    }
  }
}

output url string = 'https://${webAppName}.azurewebsites.net'
