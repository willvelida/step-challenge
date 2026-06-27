@description('Azure region.')
param location string

@description('ACR name (globally unique, lowercase alphanumeric).')
param acrName string

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

output name string = acr.name
output loginServer string = acr.properties.loginServer
