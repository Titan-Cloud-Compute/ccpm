# Deploy

Deploy project to Kubernetes. Optionally builds images first via `/pm:build-deployment`.

## Usage
```
/pm:deploy <scope-name> [--skip-build]
```

**Options:**
- `--skip-build` - Skip image build, use existing images in registry

## Quick Check

```bash
test -f .claude/scopes/$ARGUMENTS.md || echo "❌ Scope not found: $ARGUMENTS"
```

<instructions>

### 1. Load Configuration

Read from `.claude/scopes/$ARGUMENTS.md`:

```yaml
deploy:
  enabled: true
  work_dir: /path/to/project
  namespace: app-namespace
  registry: ubuntu.desmana-truck.ts.net:30500
  manifests: k8s/           # Directory or list of files
  secrets_from: .env        # Optional: create secrets from .env
  images:
    - name: app-frontend
      dockerfile: frontend/Dockerfile
      context: ./frontend
    - name: app-backend
      dockerfile: backend/Dockerfile
      context: ./backend
```

### 2. Build Images (unless --skip-build)

If `--skip-build` not specified:

```bash
# Call build-deployment to build and push images
/pm:build-deployment {scope-name}
```

If build fails, stop and report error.

### 3. Create Namespace

```bash
kubectl get namespace {namespace} 2>/dev/null || kubectl create namespace {namespace}
```

### 4. Create Secrets from .env (if configured)

If `deploy.secrets_from` is specified:

```bash
cd {work_dir}

# Read .env and create K8s secret
kubectl create secret generic {scope}-secrets \
  --from-env-file={secrets_from} \
  --namespace={namespace} \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 5. Apply Manifests

```bash
cd {work_dir}

# Apply all manifests in directory
kubectl apply -f {manifests} -n {namespace}

# Or if manifests is a list:
for manifest in {manifests}; do
  kubectl apply -f $manifest -n {namespace}
done
```

### 5.5. Patch Services to NodePort

After applying manifests, patch all ClusterIP services to NodePort so they are externally accessible:

```bash
# Get all ClusterIP services (skip kubernetes default)
kubectl get svc -n {namespace} -o json | \
  jq -r '.items[] | select(.spec.type == "ClusterIP") | .metadata.name' | \
  while read svc; do
    echo "Patching $svc to NodePort..."
    kubectl patch svc "$svc" -n {namespace} -p '{"spec": {"type": "NodePort"}}'
  done
```

After patching, retrieve the assigned NodePorts:

```bash
kubectl get svc -n {namespace} -o wide
```

### 6. Restart Deployments (force pull new images)

```bash
# Get all deployments and restart them
kubectl get deployments -n {namespace} -o name | while read deploy; do
  kubectl rollout restart $deploy -n {namespace}
done
```

### 7. Wait for Rollout

```bash
kubectl get deployments -n {namespace} -o name | while read deploy; do
  echo "Waiting for $deploy..."
  kubectl rollout status $deploy -n {namespace} --timeout=180s
done
```

### 8. Verify Pods Ready

```bash
kubectl wait --for=condition=ready pod --all -n {namespace} --timeout=60s
```

### 9. Report Status

```bash
kubectl get pods -n {namespace}
kubectl get services -n {namespace}

# Show NodePort access URLs
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
kubectl get svc -n {namespace} -o json | \
  jq -r --arg ip "$NODE_IP" \
  '.items[] | select(.spec.type == "NodePort") | .spec.ports[] | "\(.name // "default"): http://\($ip):\(.nodePort)"'
```

</instructions>

<output_format>

### Success
```
✅ Deployed {scope} to {namespace}

Build: Completed (or Skipped)
Namespace: {namespace}

Pods:
  - {pod-1}: Running (1/1)
  - {pod-2}: Running (1/1)

Services (NodePort):
  - {svc-1}: http://{node-ip}:{nodeport}
  - {svc-2}: http://{node-ip}:{nodeport}
```

### Failure
```
❌ Deploy failed: {scope}

Phase: {build|secrets|manifests|rollout}
Error: {specific error}

Pod status:
{kubectl get pods output}

Events:
{kubectl get events output}

To retry: /pm:deploy {scope}
To skip build: /pm:deploy {scope} --skip-build
```

</output_format>

## Scope Configuration Reference

```yaml
---
name: myapp
status: active
work_dir: /home/ubuntu/myapp

deploy:
  enabled: true
  namespace: myapp
  registry: ubuntu.desmana-truck.ts.net:30500
  manifests: k8s/
  secrets_from: .env
  images:
    - name: myapp-frontend
      dockerfile: frontend/Dockerfile
      context: ./frontend
    - name: myapp-backend
      dockerfile: backend/Dockerfile
      context: ./backend
---
```

## Relationship with Other Commands

| Command | Purpose |
|---------|---------|
| `/pm:build-deployment` | Build and push images only |
| `/pm:deploy` | Full deploy (build + K8s) |
| `/pm:deploy --skip-build` | K8s only, use existing images |

## Notes

- Calls `/pm:build-deployment` for image builds
- Creates namespace if it doesn't exist
- Creates secrets from .env if configured
- Patches all ClusterIP services to NodePort for external access
- Restarts deployments to force image pull
- Waits for all pods to be ready before reporting success
- Reports NodePort URLs using node IP + assigned port
- Can be called by `/pm:scope-run` when deployment is needed
