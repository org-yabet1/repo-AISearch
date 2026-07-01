targetScope = 'resourceGroup'

@description('Location for all resources')
param location string = resourceGroup().location

@description('Azure AI Search service name')
param searchServiceName string = 'ai-search-ppt'

@description('Storage account name. Must be 3-24 lowercase letters/numbers (no hyphen).')
@minLength(3)
@maxLength(24)
param storageAccountName string = 'blobppt'

@description('Blob container name that stores PPT files')
param containerName string = 'container-ppt'

@description('Sku for Azure AI Search service')
@allowed([
  'basic'
  'standard'
  'standard2'
  'standard3'
])
param searchSku string = 'basic'

@description('Optional tags')
param tags object = {}

var storageBlobDataReaderRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource blobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: containerName
  properties: {
    publicAccess: 'None'
  }
}

resource searchService 'Microsoft.Search/searchServices@2025-05-01' = {
  name: searchServiceName
  location: location
  tags: tags
  sku: {
    name: searchSku
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publicNetworkAccess: 'enabled'
    encryptionWithCmk: {
      enforcement: 'Unspecified'
    }
    hostingMode: 'Default'
    partitionCount: 1
    replicaCount: 1
  }
}

resource searchToStorageReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, searchService.id, 'StorageBlobDataReader')
  scope: storageAccount
  properties: {
    roleDefinitionId: storageBlobDataReaderRoleDefinitionId
    principalId: searchService.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output storageAccountId string = storageAccount.id
output storageAccountName string = storageAccount.name
output containerName string = blobContainer.name
output searchServiceId string = searchService.id
output searchServiceName string = searchService.name
output searchServicePrincipalId string = searchService.identity.principalId
