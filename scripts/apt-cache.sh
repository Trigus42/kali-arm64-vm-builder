#!/usr/bin/env bash
# Manage a persistent apt-cacher-ng container on the Mac host.
# The cache is reachable from the lima builder VM at host.lima.internal:3142.
#
# Usage:
#   ./scripts/apt-cache.sh start   # start (or restart) the cache
#   ./scripts/apt-cache.sh stop    # stop and remove the container
#   ./scripts/apt-cache.sh status  # show cache stats

set -euo pipefail

CONTAINER_NAME=apt-cacher-ng
CACHE_DIR="${HOME}/.cache/apt-cacher-ng"
PORT=3142

engine() {
    if   command -v docker >/dev/null 2>&1; then echo docker
    elif command -v podman >/dev/null 2>&1; then echo podman
    else echo "ERROR: neither docker nor podman found" >&2; exit 1; fi
}

case "${1:-start}" in
    start)
        ENGINE=$(engine)
        mkdir -p "$CACHE_DIR"
        if "$ENGINE" inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
            echo "==> apt-cacher-ng already running"
        else
            echo "==> Starting apt-cacher-ng on port $PORT (cache: $CACHE_DIR)..."
            "$ENGINE" run -d --name "$CONTAINER_NAME" --restart=unless-stopped \
                -p "0.0.0.0:${PORT}:3142" \
                -v "${CACHE_DIR}:/var/cache/apt-cacher-ng" \
                sameersbn/apt-cacher-ng
            echo "==> Cache ready at http://host.lima.internal:${PORT}/"
        fi
        ;;
    stop)
        ENGINE=$(engine)
        "$ENGINE" rm -f "$CONTAINER_NAME" 2>/dev/null || true
        echo "==> apt-cacher-ng stopped"
        ;;
    status)
        ENGINE=$(engine)
        "$ENGINE" exec "$CONTAINER_NAME" cat /var/log/apt-cacher-ng/apt-cacher.log 2>/dev/null | tail -5 || true
        echo ""
        echo "Cache size: $(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1)"
        ;;
    *)
        echo "Usage: $0 start|stop|status" >&2; exit 1 ;;
esac
