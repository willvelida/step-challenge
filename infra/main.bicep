targetScope = 'subscription'

@description('Azure region for the resource group and all resources.')
param location string

@description('Resource group name.')
param resourceGroupName string

@description('AKS cluster name.')
param aksName string

@description('ACR name (globally unique, lowercase alphanumeric).')
param acrName string

@description('Node VM size — ~8 GB RAM since Drasi is the heaviest tenant.')
param nodeVmSize string

@description('Node count.')
param nodeCount int

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
}

module acr 'acr.bicep' = {
  name: 'acr'
  scope: rg
  params: {
    location: location
    acrName: acrName
  }
}

module aks 'aks.bicep' = {
  name: 'aks'
  scope: rg
  params: {
    location: location
    aksName: aksName
    nodeVmSize: nodeVmSize
    nodeCount: nodeCount
  }
}

module acrPull 'acr-pull.bicep' = {
  name: 'acr-pull'
  scope: rg
  params: {
    acrName: acr.outputs.name
    principalId: aks.outputs.kubeletObjectId
  }
}

output resourceGroupName string = rg.name
output aksName string = aks.outputs.name
output acrLoginServer string = acr.outputs.loginServer
