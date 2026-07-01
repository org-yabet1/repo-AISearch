# repo-AISearch

Azure AI Search + Blob(PPT) + Azure OpenAI(Foundry 연동 리소스) 배포 스크립트입니다.

## 구성 리소스
- Resource Group: `rg_basic` (koreacentral)
- Azure AI Search: `ai-search-ppt` (Managed Identity ON, Public Network ON)
- Storage Account: `blobppt` *(요청값 `blob-ppt`는 Azure 규칙상 불가하여 자동 보정)*
- Blob Container: `container-ppt`
- Search Index: `idx-search-ppt`
- Search Indexer: `idxer-blob-read`

## 동작 개요
- Blob Storage의 PPT/PPTX를 Indexer가 읽음
- 이미지에서 OCR 텍스트 추출
- 본문 + OCR 텍스트 병합
- `text-embedding-3-large`로 벡터 생성/저장
- `gpt-5.4`로 요약 필드 생성
- 하이브리드 검색(키워드 + 벡터 + 시맨틱) 가능하도록 인덱스 구성

## 사전 준비
아래는 이미 존재해야 합니다.
- Azure 계정 로그인 (`az login`)
- Azure OpenAI 리소스(Foundry 프로젝트에 연결된 배포 포함)
  - `gpt-5.4`
  - `text-embedding-3-large`

## 실행
```bash
cd /home/runner/work/repo-AISearch/repo-AISearch

export SUBSCRIPTION_ID="8ae098e9-776a-4500-b96c-2b312a7b6bba"
export RESOURCE_GROUP="rg_basic"
export LOCATION="koreacentral"

# Foundry에 연결된 Azure OpenAI ARM 리소스 ID (RBAC 부여에 사용)
export OPENAI_RESOURCE_ID="/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<aoai-name>"
# OPENAI_RESOURCE_URI 기본값: https://foundry-kr.services.ai.azure.com/api/projects/pro-kr
# 다른 Foundry 엔드포인트를 사용할 경우에만 아래 줄을 활성화하세요
# export OPENAI_RESOURCE_URI="https://foundry-kr.services.ai.azure.com/api/projects/pro-kr"

# 필요 시 이름 변경 가능 (기본값은 요청값 반영)
export SEARCH_SERVICE_NAME="ai-search-ppt"
export STORAGE_ACCOUNT_NAME="blob-ppt"
export CONTAINER_NAME="container-ppt"
export INDEX_NAME="idx-search-ppt"
export INDEXER_NAME="idxer-blob-read"

/home/runner/work/repo-AISearch/repo-AISearch/scripts/deploy_azure_ai_search.sh
```

## RBAC 자동 부여
스크립트에서 자동으로 수행됩니다.
- Search MI -> Storage Account: `Storage Blob Data Reader`
- Search MI -> Azure OpenAI 리소스: `Cognitive Services OpenAI User`

## 배포 후
1. `container-ppt` 컨테이너에 PPT/PPTX 업로드
2. 인덱서 수동 실행(필요 시):
```bash
az search indexer run \
  --name idxer-blob-read \
  --service-name ai-search-ppt \
  --resource-group rg_basic
```
3. 인덱서 상태 확인:
```bash
az search indexer show \
  --name idxer-blob-read \
  --service-name ai-search-ppt \
  --resource-group rg_basic \
  --query "lastResult"
```
