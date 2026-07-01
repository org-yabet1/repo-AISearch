#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BICEP_FILE="$REPO_ROOT/infra/main.bicep"

# Required inputs
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-8ae098e9-776a-4500-b96c-2b312a7b6bba}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg_basic}"
LOCATION="${LOCATION:-koreacentral}"
SEARCH_SERVICE_NAME="${SEARCH_SERVICE_NAME:-ai-search-ppt}"
STORAGE_ACCOUNT_NAME_RAW="${STORAGE_ACCOUNT_NAME:-blob-ppt}"
CONTAINER_NAME="${CONTAINER_NAME:-container-ppt}"
INDEX_NAME="${INDEX_NAME:-idx-search-ppt}"
INDEXER_NAME="${INDEXER_NAME:-idxer-blob-read}"
DATASOURCE_NAME="${DATASOURCE_NAME:-ds-blob-ppt}"
SKILLSET_NAME="${SKILLSET_NAME:-ss-ppt-ingest}"

# Azure OpenAI / Foundry-linked resource info (required for vectorization)
# OPENAI_RESOURCE_ID: ARM resource ID used for RBAC assignment
# Example: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<account>
: "${OPENAI_RESOURCE_ID:?Set OPENAI_RESOURCE_ID to your Azure OpenAI resource ID}"
# OPENAI_RESOURCE_URI: Foundry project endpoint used by Search skills and vectorizer
OPENAI_RESOURCE_URI="${OPENAI_RESOURCE_URI:-https://foundry-kr.services.ai.azure.com/api/projects/pro-kr}"
EMBEDDING_DEPLOYMENT="${EMBEDDING_DEPLOYMENT:-text-embedding-3-large}"
CHAT_DEPLOYMENT="${CHAT_DEPLOYMENT:-gpt-5.4}"

CognitiveServicesOpenAIUserRole="5e0bd9bd-7b93-4f28-af87-19fc36ad61bd"

# Storage account naming rules: lowercase letters/numbers only, 3-24 chars
STORAGE_ACCOUNT_NAME="$(echo "$STORAGE_ACCOUNT_NAME_RAW" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | cut -c1-24)"
if [[ "$STORAGE_ACCOUNT_NAME" != "$STORAGE_ACCOUNT_NAME_RAW" ]]; then
  echo "[info] storage account name '$STORAGE_ACCOUNT_NAME_RAW' is invalid by Azure naming rules. Using '$STORAGE_ACCOUNT_NAME' instead."
fi

az account set --subscription "$SUBSCRIPTION_ID"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" 1>/dev/null

echo "[1/6] Deploy core resources (Storage + Search + MI + Storage RBAC)..."
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$BICEP_FILE" \
  --parameters \
      location="$LOCATION" \
      searchServiceName="$SEARCH_SERVICE_NAME" \
      storageAccountName="$STORAGE_ACCOUNT_NAME" \
      containerName="$CONTAINER_NAME" 1>/dev/null

SEARCH_MI_PRINCIPAL_ID="$(az resource show --resource-group "$RESOURCE_GROUP" --name "$SEARCH_SERVICE_NAME" --resource-type Microsoft.Search/searchServices --query identity.principalId -o tsv)"
STORAGE_ACCOUNT_ID="$(az storage account show --resource-group "$RESOURCE_GROUP" --name "$STORAGE_ACCOUNT_NAME" --query id -o tsv)"

echo "[2/6] Assign Search MI -> Azure OpenAI role..."
az role assignment create \
  --assignee-object-id "$SEARCH_MI_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "$CognitiveServicesOpenAIUserRole" \
  --scope "$OPENAI_RESOURCE_ID" 1>/dev/null || true

echo "[3/6] Get Search admin key..."
SEARCH_API_KEY="$(az search admin-key show --service-name "$SEARCH_SERVICE_NAME" --resource-group "$RESOURCE_GROUP" --query primaryKey -o tsv)"
SEARCH_ENDPOINT="https://${SEARCH_SERVICE_NAME}.search.windows.net"
API_VERSION="2024-07-01"

DATASOURCE_PAYLOAD="$(cat <<JSON
{
  "name": "$DATASOURCE_NAME",
  "type": "azureblob",
  "credentials": {
    "connectionString": "ResourceId=$STORAGE_ACCOUNT_ID;"
  },
  "container": {
    "name": "$CONTAINER_NAME"
  },
  "dataChangeDetectionPolicy": {
    "@odata.type": "#Microsoft.Azure.Search.HighWaterMarkChangeDetectionPolicy",
    "highWaterMarkColumnName": "metadata_storage_last_modified"
  }
}
JSON
)"

INDEX_PAYLOAD="$(cat <<JSON
{
  "name": "$INDEX_NAME",
  "fields": [
    {"name": "id", "type": "Edm.String", "key": true, "searchable": false, "filterable": true, "sortable": true},
    {"name": "content", "type": "Edm.String", "searchable": true},
    {"name": "imageText", "type": "Collection(Edm.String)", "searchable": true},
    {"name": "summary", "type": "Edm.String", "searchable": true},
    {"name": "metadata_storage_name", "type": "Edm.String", "searchable": true, "filterable": true, "sortable": true},
    {"name": "metadata_storage_path", "type": "Edm.String", "searchable": false, "filterable": true},
    {
      "name": "contentVector",
      "type": "Collection(Edm.Single)",
      "searchable": true,
      "dimensions": 3072,
      "vectorSearchProfile": "vs-profile"
    }
  ],
  "vectorSearch": {
    "algorithms": [
      {"name": "hnsw-config", "kind": "hnsw"}
    ],
    "profiles": [
      {"name": "vs-profile", "algorithm": "hnsw-config", "vectorizer": "aoai-vectorizer"}
    ],
    "vectorizers": [
      {
        "name": "aoai-vectorizer",
        "kind": "azureOpenAI",
        "azureOpenAIParameters": {
          "resourceUri": "$OPENAI_RESOURCE_URI",
          "deploymentId": "$EMBEDDING_DEPLOYMENT",
          "modelName": "text-embedding-3-large"
        }
      }
    ]
  },
  "semantic": {
    "configurations": [
      {
        "name": "default",
        "prioritizedFields": {
          "contentFields": [{"fieldName": "content"}],
          "keywordsFields": [{"fieldName": "metadata_storage_name"}]
        }
      }
    ]
  }
}
JSON
)"

SKILLSET_PAYLOAD="$(cat <<JSON
{
  "name": "$SKILLSET_NAME",
  "description": "PPT parsing with OCR + OpenAI summary/embedding",
  "skills": [
    {
      "@odata.type": "#Microsoft.Skills.Vision.OcrSkill",
      "name": "ocr-skill",
      "context": "/document/normalized_images/*",
      "textExtractionAlgorithm": "printed",
      "inputs": [
        {"name": "image", "source": "/document/normalized_images/*"}
      ],
      "outputs": [
        {"name": "text", "targetName": "ocrText"}
      ]
    },
    {
      "@odata.type": "#Microsoft.Skills.Text.MergeSkill",
      "name": "merge-content-and-ocr",
      "context": "/document",
      "insertPreTag": " ",
      "insertPostTag": " ",
      "inputs": [
        {"name": "text", "source": "/document/content"},
        {"name": "itemsToInsert", "source": "/document/normalized_images/*/ocrText"}
      ],
      "outputs": [
        {"name": "mergedText", "targetName": "mergedContent"}
      ]
    },
    {
      "@odata.type": "#Microsoft.Skills.Text.AzureOpenAIEmbeddingSkill",
      "name": "embedding-skill",
      "context": "/document",
      "resourceUri": "$OPENAI_RESOURCE_URI",
      "deploymentId": "$EMBEDDING_DEPLOYMENT",
      "modelName": "text-embedding-3-large",
      "dimensions": 3072,
      "inputs": [
        {"name": "text", "source": "/document/mergedContent"}
      ],
      "outputs": [
        {"name": "embedding", "targetName": "contentVector"}
      ]
    },
    {
      "@odata.type": "#Microsoft.Skills.Text.AzureOpenAIChatCompletionSkill",
      "name": "summary-skill",
      "context": "/document",
      "resourceUri": "$OPENAI_RESOURCE_URI",
      "deploymentId": "$CHAT_DEPLOYMENT",
      "modelName": "gpt-5.4",
      "inputs": [
        {"name": "text", "source": "/document/mergedContent"}
      ],
      "outputs": [
        {"name": "response", "targetName": "summary"}
      ]
    }
  ]
}
JSON
)"

INDEXER_PAYLOAD="$(cat <<JSON
{
  "name": "$INDEXER_NAME",
  "dataSourceName": "$DATASOURCE_NAME",
  "targetIndexName": "$INDEX_NAME",
  "skillsetName": "$SKILLSET_NAME",
  "parameters": {
    "configuration": {
      "dataToExtract": "contentAndMetadata",
      "parsingMode": "default",
      "imageAction": "generateNormalizedImages"
    }
  },
  "fieldMappings": [
    {"sourceFieldName": "metadata_storage_name", "targetFieldName": "metadata_storage_name"},
    {"sourceFieldName": "metadata_storage_path", "targetFieldName": "metadata_storage_path"}
  ],
  "outputFieldMappings": [
    {"sourceFieldName": "/document/mergedContent", "targetFieldName": "content"},
    {"sourceFieldName": "/document/normalized_images/*/ocrText", "targetFieldName": "imageText"},
    {"sourceFieldName": "/document/contentVector", "targetFieldName": "contentVector"},
    {"sourceFieldName": "/document/summary", "targetFieldName": "summary"}
  ]
}
JSON
)"

echo "[4/6] Upsert Search data source..."
curl -sS -X PUT "$SEARCH_ENDPOINT/datasources/$DATASOURCE_NAME?api-version=$API_VERSION" \
  -H "Content-Type: application/json" \
  -H "api-key: $SEARCH_API_KEY" \
  -d "$DATASOURCE_PAYLOAD" > /dev/null

echo "[5/6] Upsert Search index + skillset..."
curl -sS -X PUT "$SEARCH_ENDPOINT/indexes/$INDEX_NAME?api-version=$API_VERSION" \
  -H "Content-Type: application/json" \
  -H "api-key: $SEARCH_API_KEY" \
  -d "$INDEX_PAYLOAD" > /dev/null

curl -sS -X PUT "$SEARCH_ENDPOINT/skillsets/$SKILLSET_NAME?api-version=$API_VERSION" \
  -H "Content-Type: application/json" \
  -H "api-key: $SEARCH_API_KEY" \
  -d "$SKILLSET_PAYLOAD" > /dev/null

echo "[6/6] Upsert indexer + run..."
curl -sS -X PUT "$SEARCH_ENDPOINT/indexers/$INDEXER_NAME?api-version=$API_VERSION" \
  -H "Content-Type: application/json" \
  -H "api-key: $SEARCH_API_KEY" \
  -d "$INDEXER_PAYLOAD" > /dev/null

curl -sS -X POST "$SEARCH_ENDPOINT/indexers/$INDEXER_NAME/run?api-version=$API_VERSION" \
  -H "api-key: $SEARCH_API_KEY" > /dev/null

cat <<MSG
Done.

Resource Group      : $RESOURCE_GROUP
Location            : $LOCATION
Search Service      : $SEARCH_SERVICE_NAME
Storage Account     : $STORAGE_ACCOUNT_NAME
Container           : $CONTAINER_NAME
Index               : $INDEX_NAME
Indexer             : $INDEXER_NAME
OpenAI Deployment   : $CHAT_DEPLOYMENT / $EMBEDDING_DEPLOYMENT

Upload PPT files into container '$CONTAINER_NAME' and re-run indexer as needed.
MSG
