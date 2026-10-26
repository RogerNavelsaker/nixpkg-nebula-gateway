{
  description = "Nebula gateway OCI image with Caddy and Cloudflare DNS-01";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/02c087f3fe673c9e317f206a627cb6b910336dbe";

  outputs = { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      nebulaVersion = "1.11.2";
      nebula = assert pkgs.nebula.version == nebulaVersion; pkgs.nebula;

      caddyWithCloudflare = pkgs.caddy.withPlugins {
        plugins = [ "github.com/caddy-dns/cloudflare@v0.2.4" ];
        hash = "sha256-5a5cpFl90pEWt0lUC4ZJQ7g+1//ZvsRhee64Dt9vh5o=";
      };

      entrypoint = pkgs.writeShellScriptBin "nebula-gateway-entrypoint" ''
        set -euo pipefail

        NEBULA_CONFIG="''${NEBULA_CONFIG:-/etc/nebula/config.yml}"
        CADDYFILE="''${CADDYFILE:-/etc/caddy/Caddyfile}"
        CADDY_ADAPTER="''${CADDY_ADAPTER:-caddyfile}"
        cloudflare_token=""

        if [[ -n "''${CLOUDFLARE_API_TOKEN_FILE:-}" ]]; then
          if [[ ! -r "$CLOUDFLARE_API_TOKEN_FILE" ]]; then
            echo "[nebula-gateway] Cloudflare token file is not readable" >&2
            exit 1
          fi
          cloudflare_token="$(< "$CLOUDFLARE_API_TOKEN_FILE")"
          if [[ -z "$cloudflare_token" ]]; then
            echo "[nebula-gateway] Cloudflare token file is empty" >&2
            exit 1
          fi
        fi

        echo "[nebula-gateway] Starting Nebula..."
        ${nebula}/bin/nebula -config "$NEBULA_CONFIG" &
        nebula_pid=$!

        echo "[nebula-gateway] Starting Caddy..."
        if [[ -n "$cloudflare_token" ]]; then
          CLOUDFLARE_API_TOKEN="$cloudflare_token" ${caddyWithCloudflare}/bin/caddy \
            run --config "$CADDYFILE" --adapter "$CADDY_ADAPTER" &
        else
          ${caddyWithCloudflare}/bin/caddy \
            run --config "$CADDYFILE" --adapter "$CADDY_ADAPTER" &
        fi
        caddy_pid=$!

        stop_children() {
          trap - TERM INT
          kill -TERM "$nebula_pid" "$caddy_pid" 2>/dev/null || true
          wait "$nebula_pid" 2>/dev/null || true
          wait "$caddy_pid" 2>/dev/null || true
        }

        trap 'stop_children; exit 143' TERM
        trap 'stop_children; exit 130' INT

        set +e
        wait -n "$nebula_pid" "$caddy_pid"
        status=$?
        set -e

        stop_children
        exit "$status"
      '';

      fakeNss = pkgs.dockerTools.fakeNss;

      runtimeContract = pkgs.runCommand "nebula-gateway-runtime-contract" {
        nativeBuildInputs = [ pkgs.coreutils pkgs.gnugrep ];
      } ''
        ${nebula}/bin/nebula -version 2>&1 | grep -F "Version: ${nebulaVersion}"
        ${caddyWithCloudflare}/bin/caddy list-modules | grep -Fx "dns.providers.cloudflare"
        ${pkgs.bash}/bin/bash -n ${entrypoint}/bin/nebula-gateway-entrypoint
        test -x ${entrypoint}/bin/nebula-gateway-entrypoint
        cat > "$TMPDIR/Caddyfile" <<'EOF'
        {
          acme_dns cloudflare {env.CLOUDFLARE_API_TOKEN}
        }
        app.example.net {
          reverse_proxy 10.42.0.20:8080
        }
        EOF
        ${caddyWithCloudflare}/bin/caddy fmt --overwrite "$TMPDIR/Caddyfile"
        HOME="$TMPDIR" XDG_DATA_HOME="$TMPDIR/caddy-data" \
          XDG_CONFIG_HOME="$TMPDIR/caddy-config" \
          CLOUDFLARE_API_TOKEN=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA \
          ${caddyWithCloudflare}/bin/caddy validate \
            --config "$TMPDIR/Caddyfile" --adapter caddyfile
        if CLOUDFLARE_API_TOKEN_FILE="$TMPDIR/missing-token" \
          ${entrypoint}/bin/nebula-gateway-entrypoint > "$TMPDIR/token.log" 2>&1; then
          echo "entrypoint accepted a missing Cloudflare token file" >&2
          exit 1
        fi
        grep -F "Cloudflare token file is not readable" "$TMPDIR/token.log"
        set +e
        timeout 10 env NEBULA_CONFIG="$TMPDIR/missing-nebula.yml" \
          CADDYFILE="$TMPDIR/missing-Caddyfile" \
          ${entrypoint}/bin/nebula-gateway-entrypoint > "$TMPDIR/startup.log" 2>&1
        status=$?
        set -e
        test "$status" -ne 0
        test "$status" -ne 124
        grep -F "Starting Nebula" "$TMPDIR/startup.log"
        grep -F "Starting Caddy" "$TMPDIR/startup.log"
        touch "$out"
      '';

      image = pkgs.dockerTools.buildLayeredImage {
        name = "nebula-gateway";
        tag = nebulaVersion;
        created = "1970-01-01T00:00:01Z";
        maxLayers = 16;

        contents = [
          nebula
          caddyWithCloudflare
          entrypoint
          fakeNss
          pkgs.bash
          pkgs.cacert
          pkgs.tzdata
        ];

        config = {
          User = "0:0";
          WorkingDir = "/data";
          Entrypoint = [ "${entrypoint}/bin/nebula-gateway-entrypoint" ];
          Env = [
            "HOME=/tmp"
            "PATH=${pkgs.lib.makeBinPath [ nebula caddyWithCloudflare ]}"
            "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            "TZDIR=${pkgs.tzdata}/share/zoneinfo"
            "NEBULA_CONFIG=/etc/nebula/config.yml"
            "CADDYFILE=/etc/caddy/Caddyfile"
            "CADDY_ADAPTER=caddyfile"
            "XDG_DATA_HOME=/data"
            "XDG_CONFIG_HOME=/config"
          ];
          ExposedPorts = {
            "80/tcp" = { };
            "443/tcp" = { };
            "443/udp" = { };
            "4242/udp" = { };
          };
          Volumes = {
            "/etc/nebula" = { };
            "/etc/caddy" = { };
            "/data" = { };
            "/config" = { };
          };
          Labels = {
            "org.opencontainers.image.title" = "Nebula Gateway";
            "org.opencontainers.image.version" = nebulaVersion;
            "org.opencontainers.image.description" = "Nebula overlay network sidecar with Caddy reverse proxy and Cloudflare DNS-01 support";
            "org.opencontainers.image.source" = "https://github.com/RogerNavelsaker/nixpkg-nebula-gateway";
            "org.opencontainers.image.vendor" = "Roger Navelsaker";
            "org.opencontainers.image.revision" = if self ? dirtyRev then self.dirtyRev else self.rev or "unknown";
          };
        };

        extraCommands = ''
          mkdir -p etc/nebula etc/caddy data config tmp
          chmod 1777 tmp
        '';
      };
    in {
      packages.${system} = {
        inherit image;
        default = image;
        inherit entrypoint;
        caddy = caddyWithCloudflare;
        inherit nebula;
      };

      checks.${system} = {
        inherit image;
        runtime-contract = runtimeContract;
      };
    };
}
