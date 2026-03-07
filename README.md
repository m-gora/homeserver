# Homeserver

K3s cluster running on a NUC, managed with ArgoCD.

## Repository Structure

```
install.sh          # One-time bootstrap script
cluster/            # Cluster infrastructure manifests (applied by install.sh)
  cluster-issuer.yml  # Let's Encrypt ClusterIssuer (DNS-01 via Cloudflare)
  dns.yml             # External-DNS deployment + RBAC
apps/               # Raw Kubernetes manifests for workloads
  home-assistant/
  mosquitto/
  zigbee2mqtt/
helm/               # Helm wrapper charts
  camunda/
argocd/             # ArgoCD Application/ApplicationSet manifests
  helm-charts.yml     # Auto-discovers all charts in helm/
  home-assistant.yml
  mosquitto.yml
  zigbee2mqtt.yml
```

## Initial Cluster Setup

Prerequisites: a running K3s cluster and `kubectl`/`helm` configured to talk to it.

```bash
export CF_API_TOKEN="your-cloudflare-api-token"
./install.sh
```

The bootstrap script runs once and sets up all cluster infrastructure in order:

1. **Secrets** — Cloudflare API tokens for cert-manager and external-dns
2. **cert-manager** — Installed via Helm for TLS certificate management
3. **ClusterIssuer** — Let's Encrypt production issuer using DNS-01 challenges
4. **External-DNS** — Automatically manages Cloudflare DNS records from Ingress resources
5. **ArgoCD** — GitOps controller that manages all workloads going forward
6. **ArgoCD Applications** — Registers all apps and charts with ArgoCD

After bootstrap, access the ArgoCD UI:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

## App Management

Everything after the initial bootstrap is managed by ArgoCD via GitOps. Push to `main` and ArgoCD syncs automatically.

### Adding a new raw-manifest app

1. Create a directory under `apps/<app-name>/` with your Kubernetes manifests
2. Create an ArgoCD Application in `argocd/<app-name>.yml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <app-name>
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/m-gora/homeserver.git
    targetRevision: HEAD
    path: apps/<app-name>
  destination:
    server: https://kubernetes.default.svc
    namespace: <target-namespace>
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

3. Push — ArgoCD picks it up

### Adding a new Helm chart

1. Create a directory under `helm/<chart-name>/` with a `Chart.yaml` and `values.yaml`
2. Push — the `helm-charts` ApplicationSet auto-discovers it and creates an ArgoCD Application

No extra manifest needed. The chart will be deployed to a namespace matching the directory name.
