# Build Deployment

Build container images and push to the local registry.

## Usage
```
/pm:build-deployment <scope-name>
```

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
  registry: localhost:30500
  images:
    - name: app-frontend
      dockerfile: frontend/Dockerfile
      context: ./frontend
    - name: app-backend
      dockerfile: backend/Dockerfile
      context: ./backend
```

**Required fields:**
- `deploy.registry` - Where to push images (default: `localhost:30500`)
- `deploy.images` - List of images to build

**If images not specified**, auto-detect from project structure:
```bash
# Check for common Dockerfile locations
ls {work_dir}/Dockerfile           # Single image, use project name
ls {work_dir}/frontend/Dockerfile  # Frontend image
ls {work_dir}/backend/Dockerfile   # Backend image
```

### 2. Verify .dockerignore Files

Before building, check that each build context has a `.dockerignore` file. Missing `.dockerignore` causes Docker to send the entire directory (including `node_modules`, `.git`, etc.) as build context, inflating build time and image size.

```bash
for image in {images}; do
  context_dir="{work_dir}/{context}"
  if [ ! -f "$context_dir/.dockerignore" ]; then
    echo "⚠️ Creating .dockerignore for $context_dir"
    cat > "$context_dir/.dockerignore" << 'DOCKERIGNORE_EOF'
node_modules
dist
.git
.env*
__pycache__
*.pyc
.pytest_cache
DOCKERIGNORE_EOF
  fi
done

# Also check the project root if any image uses . as context
if [ ! -f "{work_dir}/.dockerignore" ]; then
  cat > "{work_dir}/.dockerignore" << 'DOCKERIGNORE_EOF'
node_modules
frontend/node_modules
frontend/dist
.claude
.git
.env
__pycache__
*.pyc
.pytest_cache
DOCKERIGNORE_EOF
fi
```

### 3. Build Each Image

For each image in the config:

```bash
cd {work_dir}

docker build \
  -t {registry}/{name}:latest \
  -f {dockerfile} \
  {context}

if [ $? -ne 0 ]; then
  echo "❌ Build failed: {name}"
  exit 1
fi

echo "✅ Built: {registry}/{name}:latest"
```

### 4. Push Each Image

```bash
docker push {registry}/{name}:latest

if [ $? -ne 0 ]; then
  echo "❌ Push failed: {name}"
  exit 1
fi

echo "✅ Pushed: {registry}/{name}:latest"
```

### 5. Verify Images in Registry

```bash
# Check registry catalog
curl -s http://{registry}/v2/_catalog | grep {name}
```

</instructions>

<output_format>

### Success
```
✅ Build complete for {scope}

Images pushed to {registry}:
  - {name-1}:latest
  - {name-2}:latest

Registry catalog: {count} images
```

### Failure
```
❌ Build failed: {scope}

Failed image: {name}
Exit code: {code}

Last 20 lines:
{build output}

To retry: /pm:build-deployment {scope}
```

</output_format>

## Auto-Detection Rules

When `deploy.images` is not specified:

| Files Found | Images Created |
|-------------|----------------|
| `Dockerfile` | `{project-name}:latest` |
| `frontend/Dockerfile` | `{project-name}-frontend:latest` |
| `backend/Dockerfile` | `{project-name}-backend:latest` |
| `services/*/Dockerfile` | `{project-name}-{service}:latest` |

## Environment Variables

The command sets these before building:

```bash
export REGISTRY="{registry}"
export TAG="latest"
export BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
```

## Notes

- Uses Docker for builds and pushes
- The local registry at localhost:30500 is HTTP (insecure) — Docker must be configured with `insecure-registries` in `/etc/docker/daemon.json`
- Images are tagged `:latest` (configurable via TAG env var)
- This command only builds/pushes — use `/pm:deploy` for K8s deployment + TLS
- Can be called standalone or by `/pm:deploy`
- Always verify `.dockerignore` exists before building (missing it sends entire directories including `node_modules` as context, causing multi-hundred-MB builds)

## Troubleshooting

### Push fails with "server gave HTTP response to HTTPS client"

Docker needs the registry listed in insecure-registries:

```bash
cat /etc/docker/daemon.json
# Should contain: {"insecure-registries": ["localhost:30500"]}

# After changing daemon.json:
sudo systemctl restart docker
```

### Registry connection refused

Verify the registry is reachable:

```bash
curl -s http://localhost:30500/v2/
# Should return: {}
```

### Build context too large (>50MB)

Missing `.dockerignore`. Create one excluding `node_modules`, `.git`, `dist`, `__pycache__`, and `.env` files.
