# Docker Operations Rule

## Use Official Deployment Skills for Builds

Run Docker builds through the official skills for consistency and audit trail.

**Use these skills:**
- `/pm:build-deployment <scope>` — Build and push images
- `/pm:deploy <scope>` — Build, push, deploy to K8s, and configure TLS

**Direct `docker build`/`docker push` is acceptable** when iterating outside the PM system (e.g., debugging a Dockerfile, one-off builds). The skills provide registry config, env vars, and audit trail that direct commands skip.

## Deployment Architecture

- **Service exposure:** NodePort (not ClusterIP or LoadBalancer) for all externally-accessible services
- **TLS termination:** Tailscale Serve on dedicated HTTPS ports, proxying to NodePorts
- **Registry:** Local registry at `localhost:30500` (HTTP/insecure)
- **Do not use sub-path routing** for SPAs — static asset paths break unless the frontend build uses a matching `base` config. Use a dedicated Tailscale Serve port per service instead.

## .dockerignore

Every build context must have a `.dockerignore` excluding `node_modules`, `.git`, `dist`, `__pycache__`, and `.env` files. Missing `.dockerignore` sends hundreds of MB of unnecessary files as build context.
