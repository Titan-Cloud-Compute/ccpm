# Deploy

Deploy project to Kubernetes with NodePort services and TLS via Tailscale Serve.

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
  registry: localhost:30500
  manifests: k8s/           # Directory or list of files
  secrets_from: .env        # Optional: create secrets from .env
  tailscale_host: ubuntu.desmana-truck.ts.net  # Optional: Tailscale hostname for TLS
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

### 6. Patch Services to NodePort

All services that need external access use NodePort (the cluster does not use LoadBalancer or Ingress for application traffic).

```bash
# Get all ClusterIP services (skip kubernetes default and internal-only services like databases)
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

### 7. Set Up TLS via Tailscale Serve

The cluster uses Tailscale Serve for TLS termination (Tailscale manages Let's Encrypt certs automatically). Each service gets a dedicated HTTPS port that proxies to its NodePort.

```bash
TS_HOST="${tailscale_host:-ubuntu.desmana-truck.ts.net}"

# For each NodePort service, create a Tailscale Serve entry on a unique HTTPS port
kubectl get svc -n {namespace} -o json | \
  jq -r '.items[] | select(.spec.type == "NodePort") | "\(.metadata.name) \(.spec.ports[0].nodePort)"' | \
  while read svc_name node_port; do
    # Pick a TLS port (use convention: NodePort value + offset, or check availability)
    # Find a free port in the 8400-8499 range
    TLS_PORT=$(for p in $(seq 8452 8499); do
      sudo tailscale serve status 2>&1 | grep -q ":$p" || { echo "$p"; break; }
    done)

    if [ -n "$TLS_PORT" ]; then
      sudo tailscale serve --bg --https "$TLS_PORT" "http://localhost:$node_port"
      echo "  $svc_name: https://$TS_HOST:$TLS_PORT -> NodePort $node_port"
    else
      echo "  ⚠️ No free TLS port for $svc_name (NodePort $node_port accessible via HTTP only)"
    fi
  done
```

**Why Tailscale Serve instead of Ingress/cert-manager:**
- The Tailscale hostname resolves to the Tailscale IP (100.x.x.x), not the MetalLB IP
- `tailscaled` owns port 443 on the Tailscale interface and handles TLS termination
- Existing services on this cluster use this pattern (minio, orchestration, whisper)
- Browsers accessing via `https://{ts-hostname}` hit Tailscale, not nginx-ingress

**Do not use sub-path routing** (e.g., `/myapp`) for SPAs — static asset paths break unless the frontend is rebuilt with a matching base path. Use a dedicated port per service instead.

### 8. Restart Deployments (force pull new images)

```bash
# Get all deployments and restart them
kubectl get deployments -n {namespace} -o name | while read deploy; do
  kubectl rollout restart $deploy -n {namespace}
done
```

### 9. Wait for Rollout

```bash
kubectl get deployments -n {namespace} -o name | while read deploy; do
  echo "Waiting for $deploy..."
  kubectl rollout status $deploy -n {namespace} --timeout=180s
done
```

### 10. Verify Pods Ready

```bash
kubectl wait --for=condition=ready pod --all -n {namespace} --timeout=60s
```

### 11. Report Status

```bash
kubectl get pods -n {namespace}
kubectl get services -n {namespace}

# Show access URLs
TS_HOST="${tailscale_host:-ubuntu.desmana-truck.ts.net}"
echo ""
echo "Access URLs:"
tailscale serve status 2>&1 | grep -A1 "$TS_HOST"
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

Services:
  - {svc-1}: https://{ts-host}:{tls-port} (NodePort {nodeport})
  - {svc-2}: https://{ts-host}:{tls-port} (NodePort {nodeport})
```

### Failure
```
❌ Deploy failed: {scope}

Phase: {build|secrets|manifests|rollout|tls}
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
  registry: localhost:30500
  manifests: k8s/
  secrets_from: .env
  tailscale_host: ubuntu.desmana-truck.ts.net
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
| `/pm:deploy` | Full deploy (build + K8s + TLS) |
| `/pm:deploy --skip-build` | K8s + TLS only, use existing images |

## Notes

- Calls `/pm:build-deployment` for image builds
- Creates namespace if it doesn't exist
- Creates secrets from .env if configured
- All externally-accessible services use NodePort (not ClusterIP or LoadBalancer)
- TLS is handled by Tailscale Serve, not by ingress controllers or cert-manager
- Each service gets a dedicated HTTPS port on the Tailscale hostname
- Do not use sub-path routing for SPAs (asset paths break without a matching `base` in the build config)
- Restarts deployments to force image pull
- Waits for all pods to be ready before reporting success
- Can be called by `/pm:scope-run` when deployment is needed
