#!/bin/bash
# cluster-bootstrap.sh

# 1. SET VARIABLES (Update these!)
EMAIL="your-email@example.com"
CF_API_TOKEN="your-cloudflare-token"
GITHUB_PAT="your-github-pat"

echo "🚀 Starting Cluster Bootstrap..."

# 2. CREATE NAMESPACES
kubectl create namespace cert-manager
kubectl create namespace external-dns
kubectl create namespace github-actions
kubectl create namespace home-automation

# 3. INSTALL CERT-MANAGER
echo "🛡️ Installing Cert-Manager..."
helm repo add jetstack https://charts.jetstack.io --force-update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --set installCRDs=true

# 4. INSTALL EXTERNAL-DNS
echo "🌍 Installing External-DNS..."
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/
helm upgrade --install external-dns external-dns/external-dns \
  --namespace external-dns \
  --set provider=cloudflare \
  --set cloudflare.apiToken=$CF_API_TOKEN \
  --set policy=sync # This allows it to create AND delete records

# 5. CONFIGURE CLUSTER ISSUER (DNS-01)
# We store the token in a secret first
kubectl create secret generic cloudflare-api-token-secret \
  --namespace cert-manager \
  --from-literal=api-token=$CF_API_TOKEN

cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    email: $EMAIL
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - dns01:
        cloudflare:
          apiTokenSecretRef:
            name: cloudflare-api-token-secret
            key: api-token
EOF

# 6. INSTALL ACTIONS RUNNER CONTROLLER (ARC)
echo "🤖 Installing ARC..."
helm repo add actions-runner-controller https://actions-runner-controller.github.io/actions-runner-controller
helm upgrade --install arc actions-runner-controller/actions-runner-controller \
  --namespace arc-systems \
  --set authSecret.create=true \
  --set authSecret.github_token=$GITHUB_PAT

echo "✅ Bootstrap Complete! Your cluster is ready for GitHub Actions."