param location string
param appServicePlanId string
param webAppName string

var linuxFxVersion = 'DOCKER|ghcr.io/mrprimate/ddb-proxy:latest'

resource webApp 'Microsoft.Web/sites@2021-01-15' = {
  name: webAppName
  location: location
  kind: 'app,linux,container'
  properties: {
    serverFarmId: appServicePlanId
    siteConfig: {
      numberOfWorkers: 1
      linuxFxVersion: linuxFxVersion
    }
  }
}

output url string = 'https://${webAppName}.azurewebsites.net'
