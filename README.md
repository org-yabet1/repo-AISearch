# repo-AISearch

Azure AI Search 서비스를 생성/배포하기 위한 테스트 저장소입니다.

## 구성

- `/infra/azure-ai-search.json`: Azure AI Search 서비스 ARM 템플릿
- `/.github/workflows/deploy-azure-ai-search.yml`: GitHub Actions 수동 배포 워크플로

## 사전 준비

GitHub Actions에서 Azure에 로그인할 수 있도록 아래 리포지토리 시크릿을 설정합니다.

- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`

OIDC 기반 인증을 사용하므로, Azure Entra 애플리케이션/서비스 프린시펄에 GitHub 리포지토리용 Federated Credential이 연결되어 있어야 합니다.

## 배포 방법

1. GitHub Actions의 **Deploy Azure AI Search** 워크플로를 수동 실행합니다.
2. 아래 입력값을 지정합니다.
   - `resourceGroupName`: 생성 또는 재사용할 리소스 그룹 이름
   - `location`: 배포 지역 (예: `koreacentral`)
   - `searchServiceName`: Azure AI Search 서비스 이름
   - `sku`: `free`, `basic`, `standard`, `standard2`, `standard3`
   - `replicaCount`: 복제본 수
   - `partitionCount`: 파티션 수

워크플로는 리소스 그룹을 먼저 만들거나 업데이트한 뒤, ARM 템플릿으로 Azure AI Search 서비스를 배포합니다.