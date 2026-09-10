# frontend

Lightweight single-page console for the crypto-wallet IDP. Static HTML/CSS/JS
served by NGINX, which also reverse-proxies the backend APIs so the browser
stays same-origin (no CORS).

## What it shows

| Panel            | Source                                                              |
|------------------|--------------------------------------------------------------------|
| System Health    | `GET /healthz`, `GET /api/wallet/health` + `/api/wallet/`, `GET /api/order/health` + `/api/order/` |
| Wallet Balances  | `GET /api/wallet/balance/:userId`                                  |
| Place Order      | `POST /api/order/orders`                                           |
| Recent Orders    | orders submitted from this console (kept in `localStorage`; `order-service` has no read API) |

## Proxy routing (NGINX)

```
/api/wallet/<path>  ->  http://$WALLET_SERVICE_HOST:$BACKEND_PORT/<path>
/api/order/<path>   ->  http://$ORDER_SERVICE_HOST:$BACKEND_PORT/<path>
```

Config is rendered from [`nginx/default.conf.template`](nginx/default.conf.template)
at container start via the stock nginx `envsubst` entrypoint. Overridable env
(defaults set in the Dockerfile and the k8s Deployment):

| Var                   | Default                                    |
|-----------------------|--------------------------------------------|
| `WALLET_SERVICE_HOST` | `wallet-service`                           |
| `ORDER_SERVICE_HOST`  | `order-service`                            |
| `BACKEND_PORT`        | `3000`                                     |

The DNS resolver used by the proxy is discovered at container start from
`/etc/resolv.conf` (the nginx image's `15-local-resolvers.envsh` → the kube-dns
ClusterIP in a pod, `127.0.0.11` under Docker), so it needs no configuration.

Container listens on **8080**; the k8s Service exposes **80 → 8080**.

## Run locally

```bash
docker build -t frontend ./services/frontend
docker run --rm -p 8080:8080 \
  -e WALLET_SERVICE_HOST=host.docker.internal \
  -e ORDER_SERVICE_HOST=host.docker.internal \
  frontend
# open http://localhost:8080
```

## Run in-cluster

Built and pushed by `make build` (it is in the `SERVICES` list) and deployed by
ArgoCD via [`k8s/components/frontend.yaml`](../../k8s/components/frontend.yaml)
(already referenced from `k8s/components/kustomization.yaml`, which the
`crypto-wallet-app` ApplicationSet syncs).

```bash
kubectl port-forward -n crypto-wallet-app svc/frontend 8080:80
# open http://localhost:8080
```
