@description('Azure region.')
param location string

@description('AKS cluster name.')
param aksName string

@description('Node VM size — ~8 GB RAM since Drasi is the heaviest tenant.')
param nodeVmSize string

@description('Node count.')
param nodeCount int

resource aks 'Microsoft.ContainerService/managedClusters@2024-02-01' = {
  name: aksName
  location: location
  sku: {
    name: 'Base'
    tier: 'Free'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: aksName
    agentPoolProfiles: [
      {
        name: 'systempool'
        mode: 'System'
        count: nodeCount
        vmSize: nodeVmSize
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
      }
    ]
  }
}

output name string = aks.name
output kubeletObjectId string = aks.properties.identityProfile.kubeletidentity.objectId
