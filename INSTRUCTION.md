# How to validate the ToDo app Helm chart

This guide explains how to deploy the `todoapp` Helm chart (with its `mysql` sub-chart) to a local `kind` cluster and check that everything works.

## 1. Requirements

Install the following tools:

- Docker
- kind
- kubectl
- Helm 3

## 2. What is in the repository

| Path | Purpose |
| --- | --- |
| `cluster.yml` | `kind` cluster configuration |
| `bootstrap.sh` | Creates the cluster, taints nodes, installs the ingress controller, deploys the chart, writes `output.log` |
| `helm-chart/todoapp/` | The `todoapp` chart: namespace, secret, configmap, pv, pvc, rbac, deployment, hpa, service, ingress |
| `helm-chart/todoapp/charts/mysql/` | The `mysql` sub-chart: namespace, secret, configmap, service, statefulset |
| `output.log` | Output of `kubectl get all,cm,secret,ing -A` after deployment |

## 3. Deploy

From the repository root:

```bash
chmod +x bootstrap.sh
./bootstrap.sh
```

The script does the following:

1. Creates the `kind` cluster from `cluster.yml` (skipped if it already exists).
2. Prints node labels and taints.
3. Taints the nodes labeled `app=mysql` with `app=mysql:NoSchedule`.
4. Installs the ingress-nginx controller and waits until it is ready.
5. Lints the chart and installs the `todoapp` release (the `mysql` sub-chart is installed with it).
6. Saves `kubectl get all,cm,secret,ing -A` to `output.log`.

## 4. Validate

### 4.1 Chart renders correctly

```bash
helm lint helm-chart/todoapp
helm template todoapp helm-chart/todoapp > /dev/null && echo "render OK"
helm dependency list helm-chart/todoapp
```

Expected: lint reports `0 chart(s) failed`, and `mysql` is listed as a dependency.

### 4.2 Release is deployed

```bash
helm list -A
```

Expected: release `todoapp` with status `deployed`.

### 4.3 Nodes are tainted

```bash
kubectl get nodes -l app=mysql -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints'
```

Expected: every node labeled `app=mysql` has the taint `app=mysql:NoSchedule`.

### 4.4 Pods are running

```bash
kubectl get pods -A -o wide
```

Expected:

- The `mysql` StatefulSet pods are `Running` and are scheduled only on the nodes labeled `app=mysql` (they tolerate the taint).
- The `todoapp` pods are `Running` and are not scheduled on the tainted `mysql` nodes.

### 4.5 Other resources

```bash
kubectl get hpa,ingress,pvc,svc,sa -A
kubectl get pv
kubectl get secret,cm -A | grep -Ei 'todoapp|mysql'
```

Expected: the HPA, ingress, PV/PVC (`Bound`), services, service account, secrets and configmaps exist with names prefixed by the chart name (`todoapp-...`, `mysql-...`).

### 4.6 Application responds

```bash
kubectl get ingress -A
curl -i http://localhost/
```

Expected: HTTP `200` and the ToDo landing page. The API is available at `http://localhost/api/`.

### 4.7 Values are configurable

Override values at render time to confirm they are wired up, for example:

```bash
helm template todoapp helm-chart/todoapp \
  --set hpa.minReplicas=3 \
  --set hpa.maxReplicas=7 | grep -E 'minReplicas|maxReplicas'
```

Expected: the rendered HPA contains `minReplicas: 3` and `maxReplicas: 7`. Adjust the key names if your `values.yaml` uses different ones.

### 4.8 Saved output

Check that `output.log` exists in the repository root and contains the resources of both namespaces:

```bash
head -n 20 output.log
```

## 5. Cleanup

```bash
helm uninstall todoapp
kind delete cluster --name kind
```
