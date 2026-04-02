#!/bin/bash
# Entrypoint wrapper that injects reverse proxy trust settings into Mautic's
# local.php config. This enables Mautic to work correctly behind a reverse
# proxy like Nginx Proxy Manager.
#
# Runs as a wrapper around the image's default /entrypoint.sh.
# Idempotent — safe to run on every container start.

LOCAL_PHP="/var/www/html/config/local.php"

inject_proxy_settings() {
  if [ -f "$LOCAL_PHP" ] && ! grep -q "'reverse_proxy'" "$LOCAL_PHP"; then
    php -r '
      $f = "/var/www/html/config/local.php";
      include($f);
      $parameters["reverse_proxy"] = true;
      $parameters["reverse_proxy_ips"] = ["127.0.0.1", "192.168.0.0/16", "172.16.0.0/12", "10.0.0.0/8"];
      if (getenv("MAUTIC_SITE_URL")) {
          $parameters["site_url"] = getenv("MAUTIC_SITE_URL");
      }
      file_put_contents($f, "<?php\n\$parameters = " . var_export($parameters, true) . ";\n");
    '
    echo "[mautic-proxy-init] Reverse proxy settings injected into local.php"
  fi
}

# Try to inject immediately (works on restarts when local.php already exists)
inject_proxy_settings

# Also run in background for first-boot scenario where local.php is created
# by the entrypoint during installation. The background process waits for the
# file to appear, patches it, then exits.
if [ ! -f "$LOCAL_PHP" ] || ! grep -q "'reverse_proxy'" "$LOCAL_PHP"; then
  (
    # Wait up to 5 minutes for local.php to be created by the installer
    for i in $(seq 1 60); do
      if [ -f "$LOCAL_PHP" ]; then
        sleep 3  # Let the installer finish writing
        inject_proxy_settings
        break
      fi
      sleep 5
    done
  ) &
fi

# Hand off to the original entrypoint, passing CMD arguments through
exec /entrypoint.sh "$@"
