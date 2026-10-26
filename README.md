# Nebula Gateway OCI image

Nix-built x86_64 Linux image combining Nebula 1.11.2 with Caddy and the Cloudflare DNS module for ACME DNS-01 challenges. This is a reverse-proxy sidecar for services reachable over a Nebula mesh; it is not a lighthouse image or a DNS-record updater.

## Build

```sh
nix flake check
nix build .#image
```

The build creates a Podman/Docker-loadable archive in `result`. It does not publish the image.

## Runtime contract

- Nebula reads `/etc/nebula/config.yml`; mount the config and its host certificate/key and CA certificate under `/etc/nebula`.
- Keep the Nebula CA private key out of this image and gateway host.
- Caddy reads `/etc/caddy/Caddyfile`; persist `/data` and `/config` for certificates and Caddy state.
- The image reads `CLOUDFLARE_API_TOKEN_FILE` and passes the token only to Caddy. Scope the token to the required Cloudflare zone(s) and DNS changes. Do not bake credentials into the image or Caddyfile.
- `NEBULA_CONFIG`, `CADDYFILE`, and `CADDY_ADAPTER` can override the defaults shown above.
- Nebula TUN mode requires `/dev/net/tun` and `NET_ADMIN`. The process runs as root inside the container; run the container with rootless Podman for host-side user-namespace isolation.
- OCI port metadata lists Caddy TCP 80/443, HTTP/3 UDP 443, and Nebula UDP 4242. Match Nebula UDP publishing to the `listen.port` in the mounted config; no host port publishing is needed when services are reached through the container's Nebula address.

Example Caddyfile:

```caddyfile
{
  acme_dns cloudflare {env.CLOUDFLARE_API_TOKEN}
}

app.example.net {
  reverse_proxy 10.42.0.20:8080
}
```

Mount the Cloudflare token as a runtime secret:

```sh
podman secret create cloudflare-api-token ./cloudflare-api-token

podman run -d \
  --name nebula-gateway \
  --network app-network \
  --device=/dev/net/tun:/dev/net/tun \
  --cap-add=NET_ADMIN \
  --secret=cloudflare-api-token,type=mount,target=/run/secrets/cloudflare-token \
  --env CLOUDFLARE_API_TOKEN_FILE=/run/secrets/cloudflare-token \
  --volume "$PWD/nebula-config:/etc/nebula:ro" \
  --volume "$PWD/Caddyfile:/etc/caddy/Caddyfile:ro" \
  --volume nebula-gateway-caddy-data:/data \
  --volume nebula-gateway-caddy-config:/config \
  nebula-gateway:1.11.2
```

Nebula's host certificate/key and Caddy's Cloudflare token must be readable by the container process. The image contains no network identity or runtime configuration.
