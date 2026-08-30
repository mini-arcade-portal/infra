**English** | [Magyar](README.hu.md)

# infra

Infrastructure for the Mini Arcade Portal: local development environment, Helm chart and
GitOps deployment configuration.

The application consists of five components, each in its own repository:
`frontend`, `gateway`, `auth-service`, `score-service` and `postgres`.

## Architecture

```
Internet :80/:443
     |
  Traefik Ingress (built into k3s)
     |
  frontend (nginx + React)
     |  /api/ -> server-side proxy
  gateway (Spring Cloud Gateway)
     |-- auth-service --|
     `-- score-service -+-- postgres
```

The frontend's nginx proxies `/api/` requests to the gateway, so the browser always issues
same-origin requests. No CORS configuration is required.

Service names match the docker-compose container names, so application code such as the
nginx `proxy_pass http://gateway:8080` works unchanged under Kubernetes DNS.

## Local development

```bash
cp .env.example .env
# generate JWT_SECRET: openssl rand -base64 64
docker compose up --build
```

| Component | URL |
|---|---|
| Frontend | http://localhost |
| Gateway (API) | http://localhost:8080 |
| auth-service Swagger | http://localhost:8081/swagger-ui.html |
| score-service Swagger | http://localhost:8082/swagger-ui.html |

The `postgres` container runs `init-db.sql` on startup, creating the `miniarcade_auth` and
`miniarcade_scores` databases.

`JWT_SECRET` is mandatory — `auth-service` and `score-service` fail to start without it, and
the value must be at least 256 bits for HMAC-SHA signing.

Running the test suites requires no local database: the Java services use Testcontainers,
which starts PostgreSQL in Docker.

## Production environment

A single-node **k3s** cluster on an AWS EC2 instance, using the Traefik ingress controller
that ships with k3s.

| Namespace | Contents | ArgoCD Application |
|---|---|---|
| `mini-arcade` | the five application components | `mini-arcade` |
| `monitoring` | Prometheus, Grafana, exporters | `monitoring` |
| `argocd` | ArgoCD itself (public, read-only, at `argocd.urgyanbalintviktor.com`) | installed manually |

## Deployment pipeline

A push to `main` in any service repository runs the full chain without manual steps:

1. GitHub Actions runs the tests, builds the Docker image and pushes it to `ghcr.io`,
   tagged with the git SHA.
2. The same workflow writes the new tag into `helm/mini-arcade/values.yaml` in this
   repository and commits it.
3. ArgoCD detects the change and synchronises the cluster.

Images are tagged with the git SHA rather than `latest`, so the running commit is
unambiguous and a rollback is a matter of restoring an earlier tag in `values.yaml`.

Each service repository needs two secrets: `GHCR_PAT` for pushing images (the built-in
`GITHUB_TOKEN` cannot write to a personal package namespace) and `INFRA_REPO_PAT` for
committing the tag update here.

## Helm chart

`helm/mini-arcade` is an umbrella chart covering all five components.

| Value | Default | Effect |
|---|---|---|
| `ingress.tls.enabled` | `false` | serves the Ingress over TLS from `ingress.tls.secretName` |
| `ingress.rateLimit.enabled` | `true` | adds a Traefik `Middleware` (CRD) that rate-limits all traffic through the Ingress, per source IP (`ingress.rateLimit.average`/`burst`) |
| `autoscaling.enabled` | `false` | HPAs for the Java services; also removes the fixed replica count |
| `grafanaDashboard.enabled` | `true` | ships the Grafana dashboard as a ConfigMap |

`secrets.jwtSecret` and `secrets.postgresPassword` are mandatory and guarded by `required`.
They are never committed — the ArgoCD Application supplies them at sync time.

## GitOps deployment

Two ArgoCD Applications. Both carry secrets, so their manifests exist only on the VM rather
than in this repository:

| Application | Source | Manifest location |
|---|---|---|
| `mini-arcade` | this repository, `helm/mini-arcade` | VM: `~/application.json` |
| `monitoring` | `kube-prometheus-stack` chart | VM: `~/monitoring-application-ssa.json` |

## TLS

Traffic is encrypted end to end through Cloudflare:

```
browser --HTTPS (Cloudflare certificate)--> Cloudflare --HTTPS (origin certificate)--> Traefik
```

Cloudflare proxies both hostnames with the SSL/TLS mode set to **Full (strict)**, so the leg
between Cloudflare and the cluster is encrypted as well. The origin certificate is a
Cloudflare Origin Certificate covering `*.urgyanbalintviktor.com`, loaded into a TLS secret
in each namespace:

```bash
kubectl create secret tls mini-arcade-tls --cert=origin.crt --key=origin.key -n mini-arcade
kubectl create secret tls grafana-tls     --cert=origin.crt --key=origin.key -n monitoring
kubectl create secret tls argocd-tls      --cert=origin.crt --key=origin.key -n argocd
```

The certificate is valid for 15 years and needs no renewal automation, which is why
cert-manager is not part of this setup. Issuing certificates through ACME was tried first
and did not complete on this cluster: HTTP-01 fails because cert-manager verifies the
challenge from inside the cluster, where the public hostname resolves to the instance's own
Elastic IP and EC2 does not route that traffic back; DNS-01 published the TXT records
correctly but the challenges never left `Processing`.

ArgoCD runs with `selfHeal` enabled, so it reverts manual changes to the cluster. Do not run
`helm install` or `helm upgrade` against the `mini-arcade` release — all changes go through
git.

## Rate limiting

A Traefik `Middleware` (CRD, `templates/middleware.yaml`) rate-limits all traffic through the
Ingress, applied via the `traefik.ingress.kubernetes.io/router.middlewares` annotation on
`templates/ingress.yaml`. Because the Ingress routes everything through a single path rule to
`frontend`, the limit applies to the whole site, not just `/api/`.

Traefik sits behind Cloudflare, so without extra config it would see Cloudflare's edge IP as
the request source rather than the real client IP, bucketing all traffic together instead of
per-client. `k3s/traefik-helmchartconfig.yaml` fixes this by configuring
`forwardedHeaders.trustedIPs` on k3s's built-in Traefik, trusting `X-Forwarded-For` only for
connections coming from Cloudflare's published IP ranges — so the rate limit (and Traefik's
access log) now key on the real client IP. That range list should be refreshed occasionally
from Cloudflare's published IP list, though it rarely changes.

## Monitoring

The Java services expose metrics via Spring Boot Actuator at `/actuator/prometheus`. The
chart's `ServiceMonitor` resources register those endpoints with Prometheus.

The Grafana dashboard is delivered by the chart as a ConfigMap labelled
`grafana_dashboard: "1"` (`files/grafana-dashboard.json`), which the Grafana sidecar loads
automatically. Edit the JSON in git rather than the Grafana UI — provisioned dashboards are
read-only there.

## Operations

```bash
ssh -i ~/.ssh/dev.pem ubuntu@<elastic-ip>

kubectl get pods -A
kubectl get application -n argocd          # both should be Synced and Healthy

# force an immediate sync instead of waiting for the ~3 minute poll
kubectl -n argocd patch application <name> --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# credentials
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
kubectl -n monitoring get secret monitoring-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d
```

ArgoCD is reachable publicly at `https://argocd.urgyanbalintviktor.com` (see
`k3s/argocd-ingress.yaml` and `k3s/argocd-middleware.yaml`), for read-only viewing by people
without VM/cluster access. It has its own account, `advisor`, restricted to ArgoCD's built-in
`readonly` role via `argocd-rbac-cm` — it cannot sync, delete, or edit anything. The
`admin` account and its credentials (see above) are never shared.

To (re)issue the `advisor` account's password:

```bash
argocd login argocd.urgyanbalintviktor.com
argocd account update-password --account advisor
```

Prometheus and Grafana are not exposed publicly. Reach them by port-forwarding on the VM:

```bash
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090 &
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80 &
```

and tunnelling from the local machine:

```bash
ssh -i ~/.ssh/dev.pem -L 9090:localhost:9090 -L 3000:localhost:3000 ubuntu@<elastic-ip>
```
