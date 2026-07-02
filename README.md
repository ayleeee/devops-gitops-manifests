# DevOps GitOps Manifests

GitOps repository for the k3s-based CI/CD platform portfolio project.

## Structure

```text
apps/devops-app/                 # Helm chart for the sample application
argocd/devops-app-application.yaml # ArgoCD Application manifest
```

## Platform Flow

```text
Jenkins -> zot internal registry -> update Helm values -> ArgoCD -> devops-app namespace
```

## Render Helm Chart

```bash
helm template devops-app ./apps/devops-app -n devops-app
```

## Deploy ArgoCD Application

```bash
kubectl apply -f argocd/devops-app-application.yaml
kubectl get applications -n gitops
```
