#!/bin/bash
# cluster-bootstrap.sh
# Bootstraps cluster infrastructure (cert-manager, cluster-issuer, external-dns, ArgoCD).
# Workloads (apps) are managed declaratively via ArgoCD Applications.

set -euo pipefail

CF_API_TOKEN="${CF_API_TOKEN:?Set CF_API_TOKEN env var before running}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:?Set DISCORD_WEBHOOK_URL env var before running}"

echo "🚀 Starting Cluster Bootstrap..."

# 1. CREATE SECRETS (pre-requisites for cert-manager and external-dns)
echo "🔑 Creating secrets..."
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic cloudflare-api-token-secret \
  --namespace cert-manager \
  --from-literal=api-token="$CF_API_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic cloudflare-api-token \
  --namespace kube-system \
  --from-literal=token="$CF_API_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic discord-webhook \
  --namespace monitoring \
  --from-literal=url="$DISCORD_WEBHOOK_URL" \
  --dry-run=client -o yaml | kubectl apply -f -

# 2. INSTALL CERT-MANAGER (must exist before ArgoCD for TLS)
echo "🛡️ Installing cert-manager..."
helm repo add jetstack https://charts.jetstack.io --force-update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --set installCRDs=true \
  --wait

# 3. APPLY CLUSTERISSUER (must exist before ArgoCD for TLS)
echo "📜 Creating ClusterIssuer..."
kubectl apply -f cluster/cluster-issuer.yml

echo "⏳ Waiting for ClusterIssuer to be ready..."
kubectl wait --for=condition=Ready clusterissuer/letsencrypt-prod --timeout=120s || true

# 4. INSTALL EXTERNAL-DNS (cluster infra for DNS record management)
echo "🌍 Installing External-DNS..."
kubectl apply -f cluster/dns.yml

# 5. INSTALL ARGOCD
echo "📦 Installing ArgoCD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "⏳ Waiting for ArgoCD to be ready..."
kubectl -n argocd rollout status deployment/argocd-server --timeout=300s

# 5.1 CONFIGURE ARGOCD NOTIFICATIONS
echo "🔔 Configuring ArgoCD Notifications..."
kubectl create secret generic argocd-notifications-secret \
  --namespace argocd \
  --from-literal=discord-webhook-url="$DISCORD_WEBHOOK_URL" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-notifications-cm
  namespace: argocd
data:
  service.webhook.discord: |
    url: $discord-webhook-url
    headers:
    - name: Content-Type
      value: application/json
  template.app-sync-failed: |
    webhook:
      discord:
        method: POST
        body: |
          {"content": "**🔴 ArgoCD Sync Failed**\n**App:** {{.app.metadata.name}}\n**Project:** {{.app.spec.project}}\n**Message:** {{.app.status.operationState.message}}"}
  template.app-health-degraded: |
    webhook:
      discord:
        method: POST
        body: |
          {"content": "**🟡 ArgoCD App Degraded**\n**App:** {{.app.metadata.name}}\n**Project:** {{.app.spec.project}}\n**Health:** {{.app.status.health.status}}"}
  trigger.on-sync-failed: |
    - when: app.status.operationState.phase in ['Error', 'Failed']
      send: [app-sync-failed]
  trigger.on-health-degraded: |
    - when: app.status.health.status == 'Degraded'
      send: [app-health-degraded]
EOF

# 6. APPLY ARGOCD APPLICATIONS (workloads only)
echo "🚢 Deploying ArgoCD Applications..."
kubectl apply -f argocd/

echo "✅ Bootstrap Complete! ArgoCD manages everything from here."
echo "   Access ArgoCD UI: kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "   Initial password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"