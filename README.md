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
| `cert-manager` | TLS certificate management | `cert-manager` |
| `argocd` | ArgoCD itself | installed manually |

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
| `ingress.tls.enabled` | `false` | TLS and the cert-manager annotation on the Ingress |
| `certManager.enabled` | `false` | creates the Let's Encrypt `ClusterIssuer` |
| `autoscaling.enabled` | `false` | HPAs for the Java services; also removes the fixed replica count |
| `grafanaDashboard.enabled` | `true` | ships the Grafana dashboard as a ConfigMap |

`secrets.jwtSecret` and `secrets.postgresPassword` are mandatory and guarded by `required`.
They are never committed — the ArgoCD Application supplies them at sync time.

## GitOps deployment

Three ArgoCD Applications. Two of them carry secrets and therefore exist only on the VM:

| Application | Source | Manifest location |
|---|---|---|
| `mini-arcade` | this repository, `helm/mini-arcade` | VM: `~/application.json` |
| `monitoring` | `kube-prometheus-stack` chart | VM: `~/monitoring-application-ssa.json` |
| `cert-manager` | `cert-manager` chart | `argocd/cert-manager-application.yaml` |

```bash
kubectl apply -f argocd/cert-manager-application.yaml
```

Certificates are issued through the ACME DNS-01 challenge, which requires a Cloudflare API
token with `Zone:DNS:Edit` permission on the zone. Create the secret by hand — it is not
committed:

```bash
kubectl create secret generic cloudflare-api-token \
  --from-literal=api-token='<token>' -n cert-manager
```

DNS-01 is used rather than HTTP-01 because cert-manager verifies the challenge from inside
the cluster before submitting it, and an HTTP-01 check resolves the public hostname to the
instance's own Elastic IP, which EC2 does not route back to itself.

ArgoCD runs with `selfHeal` enabled, so it reverts manual changes to the cluster. Do not run
`helm install` or `helm upgrade` against the `mini-arcade` release — all changes go through
git.

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

The ArgoCD, Prometheus and Grafana interfaces are not exposed publicly. Reach them by
port-forwarding on the VM:

```bash
kubectl port-forward -n argocd svc/argocd-server 8081:443 &
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090 &
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80 &
```

and tunnelling from the local machine:

```bash
ssh -i ~/.ssh/dev.pem -L 8081:localhost:8081 -L 9090:localhost:9090 \
    -L 3000:localhost:3000 ubuntu@<elastic-ip>
```
