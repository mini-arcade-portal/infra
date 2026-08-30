[English](README.md) | **Magyar**

# infra

Infrastruktúra a Mini Arcade Portalhoz: lokális fejlesztői környezet, Helm
chart és GitOps deployment konfiguráció.

Az alkalmazás öt komponensből áll, mindegyik saját repóban:
`frontend`, `gateway`, `auth-service`, `score-service` és `postgres`.

## Architektúra

```
Internet :80/:443
     |
  Traefik Ingress (a k3s része)
     |
  frontend (nginx + React)
     |  /api/ -> szerveroldali proxy
  gateway (Spring Cloud Gateway)
     |-- auth-service --|
     `-- score-service -+-- postgres
```

A frontend nginx-e proxyzza az `/api/` kéréseket a gateway felé, így a
böngésző mindig same-origin kéréseket küld. Nincs szükség CORS
konfigurációra.

A szolgáltatásnevek megegyeznek a docker-compose konténernevekkel, így az
alkalmazáskód (pl. az nginx `proxy_pass http://gateway:8080` sora)
változtatás nélkül működik Kubernetes DNS alatt is.

## Lokális fejlesztés

```bash
cp .env.example .env
# JWT_SECRET generálása: openssl rand -base64 64
docker compose up --build
```

| Komponens | URL |
|---|---|
| Frontend | http://localhost |
| Gateway (API) | http://localhost:8080 |
| auth-service Swagger | http://localhost:8081/swagger-ui.html |
| score-service Swagger | http://localhost:8082/swagger-ui.html |

A `postgres` konténer induláskor lefuttatja az `init-db.sql`-t, létrehozva a
`miniarcade_auth` és `miniarcade_scores` adatbázisokat.

A `JWT_SECRET` kötelező — az `auth-service` és a `score-service` nélküle nem
indul el, az értéknek legalább 256 bitesnek kell lennie a HMAC-SHA
aláíráshoz.

A tesztek futtatásához nincs szükség lokális adatbázisra: a Java
szolgáltatások Testcontainers-t használnak, ami Dockerben indít PostgreSQL-t.

## Production környezet

Egyetlen csomópontos **k3s** klaszter egy AWS EC2 instance-on, a k3s-hez
tartozó Traefik ingress controllerrel.

| Namespace | Tartalom | ArgoCD Application |
|---|---|---|
| `mini-arcade` | az öt alkalmazáskomponens | `mini-arcade` |
| `monitoring` | Prometheus, Grafana, exporterek | `monitoring` |
| `argocd` | maga az ArgoCD (publikus, csak olvasható, itt: `argocd.urgyanbalintviktor.com`) | manuálisan telepítve |

## Deployment pipeline

Egy `main`-be történő push bármelyik service repóban manuális lépések
nélkül lefuttatja a teljes láncot:

1. A GitHub Actions lefuttatja a teszteket, megépíti a Docker image-et és
   feltölti a `ghcr.io`-ra, a git SHA-val megcímkézve.
2. Ugyanaz a workflow beírja az új tag-et a `helm/mini-arcade/values.yaml`
   fájlba ebben a repóban, és commitolja.
3. Az ArgoCD észleli a változást és szinkronizálja a klasztert.

Az image-ek git SHA-val vannak megcímkézve, nem `latest`-tel, így a futó
commit egyértelmű, egy rollback pedig annyi, hogy egy korábbi tag-et
állítunk vissza a `values.yaml`-ban.

Minden service repóhoz két secret kell: `GHCR_PAT` az image-ek
feltöltéséhez (a beépített `GITHUB_TOKEN` nem tud írni egy személyes package
namespace-be), és `INFRA_REPO_PAT` a tag-frissítés commitolásához ide.

## Helm chart

A `helm/mini-arcade` egy umbrella chart, amely mind az öt komponenst lefedi.

| Érték | Alapértelmezett | Hatás |
|---|---|---|
| `ingress.tls.enabled` | `false` | az Ingress-t TLS-en keresztül szolgálja ki, az `ingress.tls.secretName`-ből |
| `ingress.rateLimit.enabled` | `true` | hozzáad egy Traefik `Middleware`-t (CRD), ami az összes, az Ingress-en átmenő forgalmat rate-limiteli forrás IP-nként (`ingress.rateLimit.average`/`burst`) |
| `autoscaling.enabled` | `false` | HPA-kat ad a Java szolgáltatásokhoz; a fix replica számot is eltávolítja |
| `grafanaDashboard.enabled` | `true` | a Grafana dashboardot ConfigMap-ként szállítja |

A `secrets.jwtSecret` és a `secrets.postgresPassword` kötelező, `required`-del
védve. Sosincsenek commitolva — az ArgoCD Application adja őket sync
időben.

## GitOps deployment

Két ArgoCD Application. Mindkettő secreteket hordoz, ezért a manifestjeik
csak a VM-en léteznek, nem ebben a repóban:

| Application | Forrás | Manifest helye |
|---|---|---|
| `mini-arcade` | ez a repó, `helm/mini-arcade` | VM: `~/application.json` |
| `monitoring` | `kube-prometheus-stack` chart | VM: `~/monitoring-application-ssa.json` |

## TLS

A forgalom végpontok között titkosítva van a Cloudflare-en keresztül:

```
böngésző --HTTPS (Cloudflare tanúsítvány)--> Cloudflare --HTTPS (origin tanúsítvány)--> Traefik
```

A Cloudflare mindkét hostname-et proxyzza, az SSL/TLS mód **Full
(strict)**-re állítva, így a Cloudflare és a klaszter közötti szakasz is
titkosított. Az origin tanúsítvány egy Cloudflare Origin Certificate, amely
lefedi a `*.urgyanbalintviktor.com`-ot, és minden namespace-ben egy TLS
secretbe van betöltve:

```bash
kubectl create secret tls mini-arcade-tls --cert=origin.crt --key=origin.key -n mini-arcade
kubectl create secret tls grafana-tls     --cert=origin.crt --key=origin.key -n monitoring
kubectl create secret tls argocd-tls      --cert=origin.crt --key=origin.key -n argocd
```

A tanúsítvány 15 évig érvényes és nem igényel megújítási automatizálást,
ezért nincs a setupban cert-manager. Az ACME-n keresztüli tanúsítvány-
kiállítást először kipróbáltuk, de nem sikerült ezen a klaszteren: a
HTTP-01 azért bukik, mert a cert-manager a klaszteren belülről ellenőrzi a
challenge-et, ahol a publikus hostname az instance saját Elastic IP-jére
mutat, az EC2 pedig nem routolja vissza azt a forgalmat; a DNS-01 helyesen
publikálta a TXT rekordokat, de a challenge-ek sosem léptek ki a
`Processing` állapotból.

Az ArgoCD `selfHeal`-lel fut, így visszaállítja a klaszteren végzett manuális
változtatásokat. Ne futtass `helm install`-t vagy `helm upgrade`-et a
`mini-arcade` release ellen — minden változtatás git-en keresztül megy.

## Rate limiting

Egy Traefik `Middleware` (CRD, `templates/middleware.yaml`) rate-limiteli az
összes, az Ingress-en átmenő forgalmat, a `templates/ingress.yaml`-on lévő
`traefik.ingress.kubernetes.io/router.middlewares` annotáción keresztül
alkalmazva. Mivel az Ingress mindent egyetlen path szabályon keresztül
routol a `frontend`-hez, a limit az egész oldalra vonatkozik, nem csak az
`/api/`-ra.

A Traefik a Cloudflare mögött van, ezért extra konfiguráció nélkül a Cloudflare edge
IP-jét látná kérésforrásként a valós kliens IP helyett, és az összes forgalmat egy
kosárba tenné kliens szerinti szétválasztás helyett. A `k3s/traefik-helmchartconfig.yaml`
ezt oldja meg: beállítja a `forwardedHeaders.trustedIPs`-t a k3s beépített Traefik-jén,
ami csak a Cloudflare publikált IP-tartományairól érkező kapcsolatok esetén bízik meg az
`X-Forwarded-For` fejlécben — így a rate limit (és a Traefik access log) már a valós
kliens IP alapján dolgozik. Ezt az IP-lista időnként érdemes frissíteni a Cloudflare
hivatalos listája alapján, bár ritkán változik.

## Monitoring

A Java szolgáltatások Spring Boot Actuatoron keresztül exponálják a
metrikáikat a `/actuator/prometheus` végponton. A chart `ServiceMonitor`
resource-jai regisztrálják ezeket a végpontokat a Prometheusnál.

A Grafana dashboardot a chart ConfigMapként szállítja,
`grafana_dashboard: "1"` címkével (`files/grafana-dashboard.json`), amit a
Grafana sidecar automatikusan betölt. A JSON-t git-ben szerkeszd, ne a
Grafana UI-ban — a provisioned dashboardok ott csak olvashatók.

## Üzemeltetés

```bash
ssh -i ~/.ssh/dev.pem ubuntu@<elastic-ip>

kubectl get pods -A
kubectl get application -n argocd          # mindkettő Synced és Healthy legyen

# azonnali sync kikényszerítése a ~3 perces polling megvárása helyett
kubectl -n argocd patch application <name> --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# hitelesítő adatok
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
kubectl -n monitoring get secret monitoring-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d
```

Az ArgoCD publikusan elérhető a `https://argocd.urgyanbalintviktor.com` címen (lásd
`k3s/argocd-ingress.yaml` és `k3s/argocd-middleware.yaml`), csak-olvasás jelleggel azok
számára, akiknek nincs VM/cluster hozzáférésük. Ehhez tartozik egy saját fiók, `advisor`,
ami az ArgoCD beépített `readonly` szerepkörére van korlátozva az `argocd-rbac-cm`-en
keresztül — nem tud sync-elni, törölni vagy szerkeszteni semmit. Az `admin` fiókot és
annak hitelesítő adatait (lásd fent) sosem osztjuk meg.

Az `advisor` fiók jelszavának (újra)kiadása:

```bash
argocd login argocd.urgyanbalintviktor.com
argocd account update-password --account advisor
```

A Prometheus és a Grafana nincsenek publikusan kitéve. Port-forwarddal érhetők el a
VM-en:

```bash
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090 &
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80 &
```

majd alagutazva a helyi gépről:

```bash
ssh -i ~/.ssh/dev.pem -L 9090:localhost:9090 -L 3000:localhost:3000 ubuntu@<elastic-ip>
```
