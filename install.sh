#!/bin/bash
# cluster-bootstrap.sh
# Bootstraps cluster infrastructure (cert-manager, cluster-issuer, external-dns, ArgoCD).
# Workloads (apps) are managed declaratively via ArgoCD Applications.

set -euo pipefail

CF_API_TOKEN="${CF_API_TOKEN:?Set CF_API_TOKEN env var before running}"

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

# 6. APPLY ARGOCD APPLICATIONS (workloads only)
echo "🚢 Deploying ArgoCD Applications..."
kubectl apply -f argocd/

echo "✅ Bootstrap Complete! ArgoCD manages everything from here."
echo "   Access ArgoCD UI: kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "   Initial password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"