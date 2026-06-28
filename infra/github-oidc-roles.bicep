targetScope = 'resourceGroup'  // deploy into the app RG (stepup-rg)

@description('Name of the existing OIDC managed identity.')
param identityName string

@description('RG that holds the OIDC managed identity.')
param identityRgName string

@description('Existing ACR to grant push on.')
param acrName string

@description('Existing AKS cluster to grant admin on.')
param aksName string

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
  scope: resourceGroup(identityRgName)
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = { name: acrName }
resource aks 'Microsoft.ContainerService/managedClusters@2024-02-01' existing = { name: aksName }

// AcrPush — data-plane image push (NOT covered by Contributor).
var acrPushRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions', '8311e382-0749-4cb8-b61a-304f252e45ec')
resource acrPush 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, identity.id, acrPushRoleId)
  scope: acr
  properties: {
    principalId: identity.properties.principalId
    roleDefinitionId: acrPushRoleId
    principalType: 'ServicePrincipal'
  }
}

// AKS Cluster Admin — admin kubeconfig for rad/drasi/kubectl.
var aksAdminRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions', '0ab0b1a8-8aac-4efd-b8c2-3ee1fb270be8')
resource aksAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aks.id, identity.id, aksAdminRoleId)
  scope: aks
  properties: {
    principalId: identity.properties.principalId
    roleDefinitionId: aksAdminRoleId
    principalType: 'ServicePrincipal'
  }
}
