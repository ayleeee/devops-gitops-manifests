![EC2 k3s GitOps CI/CD Platform](docs/images/architecture-k3s-gitops-platform.png)

# EC2 k3s GitOps CI/CD Platform

AWS EC2 위에 단일 노드 k3s 클러스터를 구축하고, Jenkins·Helm·ArgoCD·Private Container Registry를 연동하여 애플리케이션 배포 전 과정을 GitOps 방식으로 자동화한 프로젝트입니다. 이 README는 구축 과정에서 정리한 내용을 바탕으로, 동일한 구조를 재현할 수 있도록 명령어와 검증 방법을 함께 기록했습니다.

프로젝트의 목적은 GitOps 흐름을 직접 구성해보며 그 동작 원리를 체득하는 데 있습니다. 
작은 규모로 먼저 구현하고 경험을 쌓아야, 이후 더 큰 규모의 인프라에도 무리 없이 적용할 수 있다고 판단했습니다.

## 구성하면서 알게 된 점

GitOps는 여러 컴포넌트가 유기적으로 연결되어 작동하는 배포 운영 방식입니다.


* Jenkins — 애플리케이션 이미지를 빌드
* Registry — 빌드된 이미지를 저장
* Helm Chart — Kubernetes 리소스를 선언적으로 정의
* GitOps Repository — 배포하고자 하는 상태(desired state)를 기록
* ArgoCD — Git에 기록된 상태를 클러스터에 반영
* Kubernetes Namespace — 컴포넌트별 책임 범위를 분리


EC2 한 대와 k3s를 선택한 것도 이 흐름을 명확하게 관찰하기 위한 선택이었습니다. 관리형 Kubernetes 서비스를 사용하면 편리하지만, 많은 부분이 추상화되어 가려집니다. 반면 작은 클러스터를 직접 구성하면 Docker 권한, kubeconfig, NodePort, Ingress, Namespace, Helm Release 같은 기본 요소들을 하나하나 눈으로 확인할 수 있습니다. 규모는 최소화했지만, 배포 흐름 자체는 실제 프로덕션 GitOps 구조와 동일하게 설계했습니다.

## 구현 범위

- EC2 한 대에서 Kubernetes 기반 CI/CD 환경 구성
- Jenkins Pipeline으로 Docker image build/push 자동화
- Helm chart로 Kubernetes 리소스 선언 관리
- ArgoCD로 GitOps 기반 배포 자동화
- Jenkins는 제한된 외부 접근이 가능하도록 구성
- 애플리케이션은 HTTP Ingress로 접근 가능하도록 구성
- ArgoCD는 port-forward 중심으로 접근
- Registry는 클러스터 내부 사용을 기준으로 구성
- Prometheus 연동을 위해 `/metrics` endpoint 제공
- ServiceMonitor는 Prometheus Operator 설치 후 활성화 가능하도록 준비

## Architecture

```text
Developer
  |
  | push app source
  v
GitHub App Repo
  |
  | Jenkins Pipeline
  v
Jenkins on k3s
  |
  | docker build / push
  v
Private Registry(zot)
  |
  | update image tag in Helm values
  v
GitHub GitOps Repo
  |
  | sync
  v
ArgoCD
  |
  | helm deploy
  v
k3s devops-app namespace
```

## Repository Layout

```text
.
├── apps/
│   └── devops-app/                 # sample app Helm chart
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
├── argocd/
│   └── devops-app-application.yaml # ArgoCD Application
├── docs/
│   └── images/                     # README screenshots and architecture
└── scripts/
    └── bootstrap-ec2-docker-k3s-helm.sh
```

## Tech Stack

| Area | Tool | Why |
|---|---|---|
| Cloud VM | AWS EC2 | 서버, 네트워크, 보안그룹, 스토리지 구성을 직접 통제하기 위해 선택 |
| Kubernetes | k3s | 단일 노드에서도 Kubernetes 핵심 개념을 유지하면서 가볍게 운영 가능 |
| CI | Jenkins | 선언형 Pipeline으로 build, push, GitOps update 단계를 명확하게 표현 가능 |
| Registry | zot | 클러스터 내부 private registry 역할을 단순하게 구성 가능 |
| Packaging | Helm | Deployment, Service, Ingress, ServiceMonitor를 chart 단위로 관리 |
| CD | ArgoCD | Git repository 상태를 기준으로 클러스터를 자동 동기화 |
| Ingress | Traefik | k3s 기본 Ingress Controller를 활용해 외부 HTTP 진입점 구성 |
| Monitoring-ready | Prometheus format metrics | 애플리케이션 metric 수집 구조로 확장할 수 있도록 `/metrics` 제공 |
| Health Check | Kubernetes probes | readiness와 liveness를 분리해 배포 상태 확인 |
| Resource Control | requests / limits | 단일 노드에서 Pod 자원 사용량을 제한 |

## EC2 사용 사양

Jenkins, ArgoCD, registry, 애플리케이션은 한 노드에서 함께 실행됩니다.

| Item | Recommended |
|---|---|
| OS | Ubuntu 22.04 LTS |
| Instance | `t3.medium` 이상 |
| vCPU / Memory | 2 vCPU / 4 GiB 이상 |
| Storage | 30 GiB 이상 |

보안그룹은 필요한 포트만 열었습니다.

| Port | Purpose | Recommended Source |
|---|---|---|
| 22 | SSH | My IP |
| 80 | Application Ingress | 0.0.0.0/0 |
| 30080 | Jenkins NodePort | My IP |
| 30500 | Registry NodePort | My IP or internal only |


## 1. EC2 Bootstrap

EC2 접속 후 bootstrap script를 실행합니다.

```bash
git clone https://github.com/<YOUR_GITHUB_ID>/devops-gitops-manifests.git
cd devops-gitops-manifests

sudo bash scripts/bootstrap-ec2-docker-k3s-helm.sh
```

설치 후 SSH를 다시 접속합니다.
Docker group 권한은 재접속 후 반영됩니다.

```bash
docker ps
kubectl get nodes
helm version
```

이 프로젝트에서 사용한 설치 순서는 아래와 같습니다.

```text
Docker -> k3s -> Helm
```

Docker는 Jenkins Pipeline에서 이미지 빌드와 push에 사용하고, k3s는 Kubernetes 클러스터를 구성하며, Helm은 그 위에서 애플리케이션을 설치·관리하는 역할을 맡습니다. 이 순서로 설치해야 이미지 빌드, 클러스터 구성, 차트 배포로 이어지는 흐름을 순차적으로 확인할 수 있습니다.

## 2. Namespace 구성

역할별로 namespace를 나눴습니다.

```bash
kubectl create namespace cicd
kubectl create namespace gitops
kubectl create namespace registry
kubectl create namespace devops-app
kubectl create namespace monitoring
```

```text
cicd        Jenkins
gitops      ArgoCD
registry    zot private registry
devops-app  sample application
monitoring  Prometheus/Grafana extension area
```

## 3. Private Registry 설치

zot registry를 Helm으로 설치합니다.

```bash
helm repo add project-zot https://zotregistry.dev/helm-charts
helm repo update

helm install zot project-zot/zot \
  --namespace registry \
  --set service.type=NodePort \
  --set service.nodePort=30500
```

설치 확인:

```bash
kubectl get svc -n registry
kubectl get pods -n registry
```

EC2 내부 Docker가 registry에 push할 수 있도록 설정합니다.
이 구성에서는 HTTP registry를 사용했습니다.
클러스터 내부 검증을 빠르게 하기 위한 선택입니다.

```bash
sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'
{
  "insecure-registries": ["localhost:30500"]
}
EOF

sudo systemctl restart docker
docker info | grep -A 5 "Insecure Registries"
```

## 4. ArgoCD 설치

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm install argocd argo/argo-cd \
  --namespace gitops
```

설치 확인:

```bash
kubectl get pods -n gitops
kubectl get applications -n gitops
```

ArgoCD UI는 외부에 바로 열지 않았습니다.
필요할 때만 port-forward로 접근하는 방식을 사용했습니다.

```bash
kubectl port-forward -n gitops svc/argocd-server 8080:443
```

## 5. Jenkins 설치

Jenkins는 외부에서 접속할 수 있도록 NodePort로 구성했습니다.

```bash
helm repo add jenkins https://charts.jenkins.io
helm repo update

helm install jenkins jenkins/jenkins \
  --namespace cicd \
  --set controller.serviceType=NodePort \
  --set controller.nodePort=30080
```

초기 비밀번호 확인:

```bash
kubectl exec --namespace cicd -i svc/jenkins -c jenkins \
  -- cat /run/secrets/additional/chart-admin-password
```

접속:

```text
http://<EC2_PUBLIC_IP>:30080
```

Jenkins에는 GitHub 접근용 credential을 등록하였습니다. 

## 6. Application GitOps 등록

ArgoCD Application manifest를 적용합니다.

```bash
kubectl apply -f argocd/devops-app-application.yaml
kubectl get applications -n gitops
```

argocd/devops-app-application.yaml은 이 Repository의 Helm Chart를 바라보도록 설정되어 있습니다. GitOps 구조에서는 이 Repository가 곧 배포의 기준점이 됩니다. 클러스터에서 리소스를 직접 수정하더라도 Git에 기록된 상태와 어긋나면, ArgoCD가 그 차이를 감지해 원래 상태로 되돌립니다.

```yaml
source:
  repoURL: https://github.com/<YOUR_GITHUB_ID>/devops-gitops-manifests.git
  targetRevision: main
  path: apps/devops-app
destination:
  namespace: devops-app
syncPolicy:
  automated:
    prune: true
    selfHeal: true
```

selfHeal은 클러스터에서 발생한 수동 변경을 되돌리는 데, prune은 Git에서 제거된 리소스를 클러스터에서도 함께 제거하는 데 사용됩니다. 다른 계정에서 재사용할 때는 repoURL을 본인 Repository 주소로 변경하면 됩니다.

## 7. Jenkins Pipeline Flow

애플리케이션 repository의 `Jenkinsfile`은 아래 흐름으로 동작합니다.

```text
1. Validate Parameters
2. Checkout application source
3. Build Docker image
4. Push image to private registry
5. Clone GitOps manifests repository
6. Update apps/devops-app/values.yaml
7. Commit and push GitOps change
8. ArgoCD detects Git change and syncs the application
```

이 Pipeline의 핵심은 Kubernetes API를 직접 호출하지 않는다는 점입니다. Pipeline은 오직 GitOps Repository만 변경하며, 실제 배포 실행은 ArgoCD가 전담합니다. 이 구조 덕분에 배포 이력이 Git commit으로 고스란히 남고, 문제가 발생했을 때 어떤 이미지 태그가 배포되었는지 Git history에서 바로 확인할 수 있습니다. 그런 이유로 latest 태그 대신 명시적인 버전 태그를 사용했습니다.

Pipeline에서 주로 사용하는 파라미터는 다음과 같습니다.

| Parameter | Example | Description |
|---|---|---|
| `IMAGE_TAG` | `0.1.2` | 새로 배포할 이미지 태그 |
| `REGISTRY_ENDPOINT` | `localhost:30500` | k3s node에서 접근할 registry endpoint |
| `GITOPS_REPO_URL` | `https://github.com/<YOUR_ID>/devops-gitops-manifests.git` | Helm values를 업데이트할 GitOps repo |
| `GITOPS_BRANCH` | `main` | GitOps branch |
| `GITOPS_CREDENTIALS_ID` | `github-token` | Jenkins credential ID |


## 8. Helm Chart

애플리케이션은 Helm Chart로 배포되며, Kubernetes manifest를 템플릿 형태로 관리합니다. 이미지 Repository와 태그는 values.yaml에서 관리합니다.

```bash
helm template devops-app ./apps/devops-app -n devops-app
```

주요 values:

```yaml
replicaCount: 2

image:
  repository: localhost:30500/devops-gitops-app
  tag: "0.1.2"

ingress:
  enabled: true
  className: traefik

serviceMonitor:
  enabled: false
```
serviceMonitor.enabled는 기본값을 false로 두었으며, Prometheus Operator CRD를 설치한 뒤 true로 전환할 수 있습니다.

Deployment 템플릿에는 헬스체크가 포함되어 있습니다. readinessProbe와 livenessProbe 모두 /health endpoint를 확인하며, Service는 Pod label selector를 기준으로 트래픽을 전달합니다. Ingress는 Traefik을 통해 외부 HTTP 요청을 Service로 라우팅합니다. Service 자체는 ClusterIP로 구성했고, 외부 접근은 Ingress가 전담합니다.

리소스 설정 역시 values에서 관리합니다. 작은 인스턴스 위에서 Jenkins와 ArgoCD가 함께 실행되기 때문에 resource limit이 특히 중요했습니다. Pod가 메모리를 과도하게 점유하면 노드 전체 성능 저하로 이어질 수 있어서, requests는 스케줄링 기준으로, limits는 컨테이너가 사용할 수 있는 최대 자원을 제한하는 용도로 설정했습니다.

## 9. Verification

### Application Endpoints

![Application endpoints](docs/images/readme-screenshot-app-endpoints.png)

### GitOps Status

![GitOps status](docs/images/readme-screenshot-gitops-status.png)

### Jenkins Pipeline Result

![Jenkins pipeline success](docs/images/readme-screenshot-jenkins-success.png)

직접 확인할 때는 아래 명령어를 사용합니다.

```bash
kubectl get applications -n gitops
kubectl get pods,svc,ingress -n devops-app
kubectl get pods -n cicd
kubectl get pods -n registry
```

애플리케이션 endpoint:

```bash
curl http://<EC2_PUBLIC_IP>/health
curl http://<EC2_PUBLIC_IP>/version
curl http://<EC2_PUBLIC_IP>/metrics
```

정상 예시:

```text
devops-app   Synced   Healthy
pod/devops-app-...   1/1   Running
```

## 10. Troubleshooting Notes

### kubeconfig permission denied

`kubectl`이 `/etc/rancher/k3s/k3s.yaml`을 직접 읽으면 permission denied가 날 수 있습니다.

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown "$USER:$USER" ~/.kube/config
chmod 600 ~/.kube/config
echo 'export KUBECONFIG=$HOME/.kube/config' >> ~/.bashrc
source ~/.bashrc
```

### Docker permission denied

Docker group 변경 후에는 SSH를 다시 접속해야 합니다.

```bash
sudo usermod -aG docker "$USER"
exit
```

다시 접속 후:

```bash
docker ps
```

### ArgoCD가 Missing 상태일 때

Application 이벤트를 먼저 확인한 뒤, Chart 렌더링 결과를 확인합니다.

```bash
kubectl describe application devops-app -n gitops
helm template devops-app ./apps/devops-app -n devops-app
```

ServiceMonitor CRD가 설치되어 있지 않으면 배포가 실패할 수 있습니다. 이 경우 원인은 대부분 serviceMonitor.enabled=true 설정입니다. Prometheus Operator를 설치하기 전까지는 이 값을 false로 유지해야 합니다. CRD가 없는 상태에서 ServiceMonitor가 배포되면 ArgoCD sync 자체가 실패할 수 있습니다.

### EC2가 느려질 때

메모리 사용량을 가장 먼저 확인합니다.

```bash
free -h
kubectl get pods -A
```
여러 솔루션이 하나의 노드에서 동시에 메모리를 점유하기 때문에, 지속적인 리소스 모니터링이 필요합니다.

## 11. How to Reuse This Project

다른 환경으로 이식할 때는 다음 항목을 변경하면 됩니다.

1. 이 repository를 fork하거나 새 repository로 복사합니다.
2. `argocd/devops-app-application.yaml`의 `repoURL`을 본인 GitOps repository 주소로 변경합니다.
3. `apps/devops-app/values.yaml`의 image repository를 본인 registry 주소로 변경합니다.
4. Jenkins credential에 본인 GitHub token을 등록합니다.
5. Jenkins Pipeline parameter의 `GITOPS_REPO_URL`을 본인 repository 주소로 입력합니다.
6. EC2 보안그룹에서 SSH, Jenkins, Application 접근 포트를 확인합니다.
7. Pipeline을 실행하고 ArgoCD가 `Synced / Healthy`가 되는지 확인합니다.

## 12. 확장 방향

현재 구조는 다음 방향으로 확장할 수 있을 것 같습니다. 

- Prometheus Operator와 Grafana 설치
- `serviceMonitor.enabled=true`로 전환해 애플리케이션 metric 수집
- Jenkins 접근을 HTTPS reverse proxy 뒤로 이동
- registry 인증 추가
- ArgoCD AppProject와 RBAC 분리
- Terraform으로 EC2, Security Group, EBS 생성 자동화
- Jenkins agent를 Docker socket 방식에서 Kaniko 또는 BuildKit 방식으로 개선
- Blue/Green 또는 Canary 배포 전략 추가

안정적인 운영을 위해 모니터링 방안을 추가하고, 보안을 강화하는 방향으로 발전시키고자 합니다.
OpenSource 솔루션 중 사용 가능한 내용을 추리고 더해갈 것입니다.

## Related Repository

- Application source: https://github.com/ayleeee/devops-gitops-app
- GitOps manifests: https://github.com/ayleeee/devops-gitops-manifests
