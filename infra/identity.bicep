targetScope = 'resourceGroup'

@description('Name for the user-assigned managed identity.')
param identityName string

@description('GitHub org/user that owns the repo.')
param githubOrg string

@description('GitHub repository name.')
param githubRepo string

@description('Azure region.')
param location string = resourceGroup().location

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
}

resource fedMain 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: identity
  name: 'github-main'
  properties: {
    issuer: 'https://token.actions.githubusercontent.com'
    subject: 'repo:${githubOrg}/${githubRepo}:ref:refs/heads/main'
    audiences: [ 'api://AzureADTokenExchange' ]
  }
}

resource fedPr 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: identity
  name: 'github-pr'
  properties: {
    issuer: 'https://token.actions.githubusercontent.com'
    subject: 'repo:${githubOrg}/${githubRepo}:pull_request'
    audiences: [ 'api://AzureADTokenExchange' ]
  }
  dependsOn: [ fedMain ]
}

output principalId string = identity.properties.principalId
output clientId string = identity.properties.clientId
