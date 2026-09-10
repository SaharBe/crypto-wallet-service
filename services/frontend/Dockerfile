FROM nginx:1.27-alpine

# Static single-page app
COPY html/ /usr/share/nginx/html/

# NGINX vhost template — the stock entrypoint runs envsubst over this and
# writes the result to /etc/nginx/conf.d/default.conf before starting nginx.
COPY nginx/default.conf.template /etc/nginx/templates/default.conf.template

# In-cluster defaults; override per-environment via the Deployment's env.
# NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1 tells the base image's
# 15-local-resolvers.envsh to derive $NGINX_LOCAL_RESOLVERS from
# /etc/resolv.conf (the kube-dns ClusterIP in a pod) for the proxy `resolver`.
ENV WALLET_SERVICE_HOST=wallet-service \
    ORDER_SERVICE_HOST=order-service \
    BACKEND_PORT=3000 \
    NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1

EXPOSE 8080

# ENTRYPOINT / CMD inherited from the base image (renders templates, then
# execs `nginx -g 'daemon off;'`).
