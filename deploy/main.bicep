@description('The name of the application. Used as a prefix for all resources.')
param appName string = 'pwshspcba'

@description('The location for all resources.')
param location string = resourceGroup().location

@description('The Client ID of the Enterprise Application')
param clientId string

@description('The Tenant ID where the Enterprise Application resides')
param tenantId string

@description('The SPO URL to connect to')
param spoUrl string

@description('The Base64 encoded PFX Certificate to store in Key Vault')
@secure()
param certificateBase64 string

@description('The Docker Image to deploy to the Container App')
param containerImage string = 'mcr.microsoft.com/azure-functions/powershell:4-powershell7.4'

// Variables
var logAnalyticsWorkspaceName = '${appName}-law'
var containerAppEnvironmentName = '${appName}-env'
var containerAppName = '${appName}-app'
var keyVaultName = '${appName}-kv-${uniqueString(resourceGroup().id)}'
var certificateSecretName = 'sp-certificate-base64'

// 1. Log Analytics Workspace
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// 2. Container App Environment
resource containerAppEnvironment 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: containerAppEnvironmentName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsWorkspace.properties.customerId
        sharedKey: logAnalyticsWorkspace.listKeys().primarySharedKey
      }
    }
  }
}

// 3. Key Vault
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true // Modern RBAC approach
    enabledForTemplateDeployment: true
  }
}

// 4. Secret (Base64 Certificate)
resource certificateSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: certificateSecretName
  properties: {
    value: certificateBase64
  }
}

// 5. Container App
resource containerApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: containerAppName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: containerAppEnvironment.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 80
        allowInsecure: false
      }
      secrets: [
        {
          name: 'certificate-base64-secret'
          keyVaultUrl: certificateSecret.properties.secretUri
          identity: 'SystemAssigned'
        }
      ]
    }
    template: {
      containers: [
        {
          name: containerAppName
          image: containerImage
          env: [
            {
              name: 'AzureWebJobsScriptRoot'
              value: '/home/site/wwwroot'
            }
            {
              name: 'TENANT_ID'
              value: tenantId
            }
            {
              name: 'CLIENT_ID'
              value: clientId
            }
            {
              name: 'SPO_URL'
              value: spoUrl
            }
            {
              name: 'CERTIFICATE_BASE64'
              secretRef: 'certificate-base64-secret'
            }
          ]
          resources: {
            cpu: json('0.5')
            memory: '1.0Gi'
          }
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 5
      }
    }
  }
}

// 6. Role Assignment: Key Vault Secrets User
var keyVaultSecretsUserRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')

resource keyVaultRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, containerApp.id, keyVaultSecretsUserRoleDefinitionId)
  scope: keyVault
  properties: {
    roleDefinitionId: keyVaultSecretsUserRoleDefinitionId
    principalId: containerApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output containerAppFqdn string = containerApp.properties.configuration.ingress.fqdn
output keyVaultName string = keyVault.name
