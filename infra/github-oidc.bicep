targetScope = 'subscription'

@description('GitHub org/user that owns the repo.')
param githubOrg string

@description('GitHub repository name.')
param githubRepo string

@description('Name for the user-assigned managed identity.')
param identityName string = 'stepup-github-oidc'

@description('Dedicated RG for the identity (survives app teardown).')
param identityRgName string = 'stepup-identity-rg'

@description('Azure region.')
param location string

resource identityRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: identityRgName
  location: location
}

module identity 'identity.bicep' = {
  scope: identityRg
  name: 'oidc-identity'
  params: {
    identityName: identityName
    githubOrg: githubOrg
    githubRepo: githubRepo
    location: location
  }
}

// Control-plane roles so the pipeline can build the app infra from nothing.
// Data-plane AcrPush + AKS-admin come later (github-oidc-roles.bicep).
var contributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
var userAccessAdminRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions', '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9')

resource contributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, identityName, contributorRoleId)
  properties: {
    principalId: identity.outputs.principalId
    roleDefinitionId: contributorRoleId
    principalType: 'ServicePrincipal'
  }
}

resource userAccessAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, identityName, userAccessAdminRoleId)
  properties: {
    principalId: identity.outputs.principalId
    roleDefinitionId: userAccessAdminRoleId
    principalType: 'ServicePrincipal'
  }
  dependsOn: [ contributor ]
}

output clientId string = identity.outputs.clientId
output tenantId string = subscription().tenantId
output subscriptionId string = subscription().subscriptionId
output identityName string = identityName
output identityRgName string = identityRgName
