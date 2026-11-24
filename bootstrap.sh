#!/usr/bin/env bash
# Deploys the ToDo app (todoapp chart + mysql sub-chart) to a local kind cluster.
# Usage: ./bootstrap.sh   (run from the repository root)
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-todoapp}"
CLUSTER_CONFIG="cluster.yml"
CHART_PATH="helm-chart/todoapp"
RELEASE_NAME="todoapp"
INGRESS_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml"
METRICS_MANIFEST="https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
OUTPUT_FILE="output.log"

log() { printf '\n==> %s\n' "$*"; }

# --- 0. Check prerequisites -------------------------------------------------
for tool in docker kind kubectl helm; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: '$tool' is not installed" >&2; exit 1; }
done

# --- 1. Create the kind cluster from cluster.yml ----------------------------
log "Creating kind cluster '$CLUSTER_NAME' from $CLUSTER_CONFIG"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "Cluster '$CLUSTER_NAME' already exists, skipping creation"
else
  kind create cluster --name "$CLUSTER_NAME" --config "$CLUSTER_CONFIG"
fi
kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null
kubectl wait --for=condition=Ready nodes --all --timeout=180s

# --- 2. Inspect nodes for labels and taints ---------------------------------
log "Node labels"
kubectl get nodes --show-labels
log "Node taints (before)"
kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints'

# --- 3. Taint the nodes labeled app=mysql -----------------------------------
log "Tainting nodes labeled app=mysql with app=mysql:NoSchedule"
kubectl taint nodes -l app=mysql app=mysql:NoSchedule --overwrite
log "Node taints (after)"
kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints'

# --- 4. Prerequisite: NGINX ingress controller ------------------------------
log "Installing ingress-nginx controller"
kubectl apply -f "$INGRESS_MANIFEST"
kubectl wait --namespace ingress-nginx \
  --for=condition=Ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

# --- 4b. Prerequisite: metrics-server (the HPA needs it for CPU/memory) ------
log "Installing metrics-server"
kubectl apply -f "$METRICS_MANIFEST"
# kind kubelets use self-signed certs, so metrics-server must skip TLS verification
if ! kubectl -n kube-system get deployment metrics-server -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q -- '--kubelet-insecure-tls'; then
  kubectl -n kube-system patch deployment metrics-server --type=json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
fi
kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s

# --- 5. Deploy the todoapp helm chart (mysql is its sub-chart) --------------
log "Linting chart"
helm lint "$CHART_PATH"

log "Deploying release '$RELEASE_NAME'"
helm upgrade --install "$RELEASE_NAME" "$CHART_PATH" \
  --values "$CHART_PATH/values.yaml" \
  --wait --timeout 10m

# --- 6. Save the cluster state ----------------------------------------------
log "Writing cluster state to $OUTPUT_FILE"
kubectl get all,cm,secret,ing -A > "$OUTPUT_FILE"

log "Done"