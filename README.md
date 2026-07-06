# EC2 k3s GitOps CI/CD Platform

AWS EC2 위에 단일 노드 k3s 클러스터를 구성하고, Jenkins, Helm, ArgoCD, private container registry를 연결해 애플리케이션 배포를 GitOps 방식으로 자동화한 프로젝트입니다.

작은 규모의 서버에서도 DevOps 배포 흐름을 끝까지 구성해보는 것을 목표로 했습니다. 단순히 앱을 띄우는 데서 끝내지 않고, 이미지 빌드, 이미지 저장, Helm values 변경, ArgoCD 동기화, 배포 상태 확인까지 하나의 흐름으로 만들었습니다.

## 목표

- EC2 한 대에서 Kubernetes 기반 CI/CD 환경 구성
- Jenkins Pipeline으로 Docker image build/push 자동화
- Helm chart로 Kubernetes 리소스 선언 관리
- ArgoCD로 GitOps 기반 배포 자동화
- Jenkins와 애플리케이션은 외부 접근 가능하게 구성
- ArgoCD와 registry는 클러스터 내부 중심으로 사용
- Prometheus 연동을 고려해 `/metrics` endpoint와 ServiceMonitor 옵션 준비

## Architecture

![Architecture](docs/images/architecture-k3s-gitops-platform.png)

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
| Cloud VM | AWS EC2 | 직접 서버를 구성하고 네트워크, 보안그룹, 스토리지까지 다루기 위해 사용 |
| Kubernetes | k3s | 단일 EC2에서도 가볍게 Kubernetes 환경을 구성하기 좋음 |
| CI | Jenkins | 선언형 Pipeline으로 build/push/deploy flow를 명확하게 표현 가능 |
| Registry | zot | k3s 내부에 private registry를 가볍게 구성 가능 |
| Packaging | Helm | Deployment, Service, Ingress, ServiceMonitor를 chart로 관리 |
| CD | ArgoCD | Git repository 상태를 기준으로 클러스터를 자동 동기화 |
| Ingress | Traefik | k3s 기본 Ingress Controller를 활용 |
| Monitoring-ready | Prometheus format metrics | `/metrics` endpoint와 ServiceMonitor 옵션으로 확장 가능 |

## EC2 권장 사양

처음에는 작은 인스턴스로 시작했지만 Jenkins, ArgoCD, registry, 애플리케이션을 모두 올리면 메모리 여유가 빠르게 줄어듭니다. 실습과 포트폴리오 목적이라면 아래 정도를 권장합니다.

| Item | Recommended |
|---|---|
| OS | Ubuntu 22.04 LTS |
| Instance | `t3.medium` 이상 |
| vCPU / Memory | 2 vCPU / 4 GiB 이상 |
| Storage | 30 GiB 이상 |

보안그룹은 필요한 포트만 여는 방식으로 구성했습니다.

| Port | Purpose | Recommended Source |
|---|---|---|
| 22 | SSH | My IP |
| 80 | Application Ingress | 0.0.0.0/0 |
| 30080 | Jenkins NodePort | My IP |
| 30500 | Registry NodePort | My IP or internal only |

운영 환경이라면 Jenkins도 VPN, bastion, SSO, reverse proxy, HTTPS 뒤에 두는 것이 좋습니다.

## 1. EC2 Bootstrap

EC2 접속 후 bootstrap script를 실행합니다.

```bash
git clone https://github.com/<YOUR_GITHUB_ID>/devops-gitops-manifests.git
cd devops-gitops-manifests

sudo bash scripts/bootstrap-ec2-docker-k3s-helm.sh
```

설치 후 SSH를 다시 접속해서 Docker group 권한을 반영합니다.

```bash
docker ps
kubectl get nodes
helm version
```

이 프로젝트에서 사용한 설치 순서는 아래와 같습니다.

```text
Docker -> k3s -> Helm
```

Docker는 Jenkins Pipeline에서 이미지 빌드와 push에 사용합니다. k3s는 Kubernetes 클러스터를 구성합니다. Helm은 k3s 위에 Jenkins, ArgoCD, registry, application chart를 설치하고 관리하는 데 사용합니다.

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

EC2 내부 Docker가 registry에 push할 수 있도록 insecure registry를 설정합니다. 이 프로젝트는 실습용으로 HTTP registry를 사용했습니다.

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

ArgoCD UI는 외부에 바로 열지 않고 필요할 때 port-forward로 접근하는 방향을 권장합니다.

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

Jenkins에는 GitHub 접근용 credential을 등록합니다. 이 README에서는 credential 값이나 token을 노출하지 않습니다.

## 6. Application GitOps 등록

ArgoCD Application manifest를 적용합니다.

```bash
kubectl apply -f argocd/devops-app-application.yaml
kubectl get applications -n gitops
```

`argocd/devops-app-application.yaml`은 이 repository의 Helm chart를 바라봅니다.

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

다른 계정으로 이식할 때는 `repoURL`만 본인 repository 주소로 바꾸면 됩니다.

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

Pipeline에서 주로 사용하는 parameter는 아래와 같습니다.

| Parameter | Example | Description |
|---|---|---|
| `IMAGE_TAG` | `0.1.2` | 새로 배포할 이미지 태그 |
| `REGISTRY_ENDPOINT` | `localhost:30500` | k3s node에서 접근할 registry endpoint |
| `GITOPS_REPO_URL` | `https://github.com/<YOUR_ID>/devops-gitops-manifests.git` | Helm values를 업데이트할 GitOps repo |
| `GITOPS_BRANCH` | `main` | GitOps branch |
| `GITOPS_CREDENTIALS_ID` | `github-token` | Jenkins credential ID |

주의할 점:

- `GITOPS_REPO_URL`에는 token을 직접 넣지 않습니다.
- GitHub token은 Jenkins credential로만 관리합니다.
- README나 commit log에 private IP, token, password가 들어가지 않도록 확인합니다.

## 8. Helm Chart

애플리케이션은 Helm chart로 배포합니다.

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

`serviceMonitor.enabled`는 Prometheus Operator CRD가 설치된 후 `true`로 바꾸는 방식으로 확장할 수 있습니다.

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

`kubectl`이 `/etc/rancher/k3s/k3s.yaml`을 직접 읽으려고 하면 permission denied가 날 수 있습니다.

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

먼저 Application event와 chart rendering을 확인합니다.

```bash
kubectl describe application devops-app -n gitops
helm template devops-app ./apps/devops-app -n devops-app
```

ServiceMonitor CRD가 없는데 `serviceMonitor.enabled=true`이면 배포가 실패할 수 있습니다. Prometheus Operator를 설치하기 전에는 `false`로 둡니다.

### EC2가 너무 느릴 때

메모리를 먼저 확인합니다.

```bash
free -h
kubectl get pods -A
```

Jenkins와 ArgoCD는 메모리를 꽤 사용하므로 4 GiB 이상 인스턴스를 권장합니다.

## 11. How to Reuse This Project

다른 사람이 본인 환경으로 옮길 때는 아래 순서대로 바꾸면 됩니다.

1. 이 repository를 fork하거나 새 repository로 복사합니다.
2. `argocd/devops-app-application.yaml`의 `repoURL`을 본인 GitOps repository 주소로 변경합니다.
3. `apps/devops-app/values.yaml`의 image repository를 본인 registry 주소로 변경합니다.
4. Jenkins credential에 본인 GitHub token을 등록합니다.
5. Jenkins Pipeline parameter의 `GITOPS_REPO_URL`을 본인 repository 주소로 입력합니다.
6. EC2 보안그룹에서 SSH, Jenkins, Application 접근 포트를 확인합니다.
7. Pipeline을 실행하고 ArgoCD가 `Synced / Healthy`가 되는지 확인합니다.

## 12. Next Steps

이 프로젝트를 더 발전시킨다면 아래 작업을 추가하고 싶습니다.

- Prometheus Operator와 Grafana 설치
- `serviceMonitor.enabled=true`로 전환해 애플리케이션 metric 수집
- Jenkins 접근을 HTTPS reverse proxy 뒤로 이동
- registry 인증 추가
- ArgoCD AppProject와 RBAC 분리
- Terraform으로 EC2, Security Group, EBS 생성 자동화
- Jenkins agent를 Docker socket 방식에서 Kaniko 또는 BuildKit 방식으로 개선
- Blue/Green 또는 Canary 배포 전략 추가

## Related Repository

- Application source: https://github.com/ayleeee/devops-gitops-app
- GitOps manifests: https://github.com/ayleeee/devops-gitops-manifests
