#!/usr/bin/env bash
# Install / inspect / remove the CoT patch for 9Router.
#
#   ./install.sh install     copy apply.mjs into the data volume, print the
#                            entrypoint line you must add to compose
#   ./install.sh status      is the patch live in the running container?
#   ./install.sh restore     undo (removes script + reverts chunk from image)
#
# Set ROUTER_DIR if your compose project is not at ./9router.

set -euo pipefail

ROUTER_DIR="${ROUTER_DIR:-$PWD}"
PATCH_DIR="$ROUTER_DIR/data/patch"
CONTAINER="${CONTAINER:-9router}"
ORIG_MD5="2f02c3c8d1258bf00647fd0abc0ff279"

die() { echo "error: $*" >&2; exit 1; }

need_compose() {
  [ -f "$ROUTER_DIR/docker-compose.yml" ] || [ -f "$ROUTER_DIR/compose.yml" ] \
    || die "no docker-compose.yml in $ROUTER_DIR (set ROUTER_DIR)"
}

case "${1:-}" in
  install)
    need_compose
    [ -d "$ROUTER_DIR/data" ] || die "$ROUTER_DIR/data does not exist - start 9router once first"
    mkdir -p "$PATCH_DIR"
    cp "$(dirname "$0")/patch/apply.mjs" "$PATCH_DIR/apply.mjs"
    echo "installed $PATCH_DIR/apply.mjs"
    echo
    echo "Now set this entrypoint in your compose service, then recreate:"
    echo
    echo '  entrypoint: ["/bin/sh", "-c", "node /app/data/patch/apply.mjs; exec node custom-server.js"]'
    echo
    echo "  docker compose up -d --force-recreate $CONTAINER"
    echo
    echo "NOTE: 'docker compose restart' will NOT revert a patch (the container's"
    echo "writable layer persists). Always use --force-recreate to toggle it."
    ;;

  status)
    docker inspect "$CONTAINER" >/dev/null 2>&1 || die "container $CONTAINER not found"
    echo "image:       $(docker inspect "$CONTAINER" --format '{{.Config.Image}}')"
    echo "app version: $(docker exec "$CONTAINER" node -e 'console.log(require("/app/package.json").version)' 2>/dev/null || echo '?')"
    echo -n "boot log:    "
    docker logs "$CONTAINER" 2>&1 | grep -m1 'cot-patch' || echo '(no cot-patch line - entrypoint not patched)'
    md5="$(docker exec "$CONTAINER" md5sum /app/.next/server/chunks/8895.js 2>/dev/null | cut -d' ' -f1)"
    echo "chunk md5:   ${md5:-?}"
    if [ "$md5" = "$ORIG_MD5" ]; then
      echo "state:       UNPATCHED (chunk matches stock v0.5.116)"
    elif [ -n "$md5" ]; then
      echo "state:       PATCHED or image changed (not the stock md5)"
    fi
    ;;

  restore)
    docker exec "$CONTAINER" rm -f /app/data/patch/apply.mjs 2>/dev/null || true
    rm -f "$PATCH_DIR/apply.mjs" 2>/dev/null || true
    rmdir "$PATCH_DIR" 2>/dev/null || true
    echo "removed patch script."
    echo "Restore the previous entrypoint line in compose, then:"
    echo "  docker compose up -d --force-recreate $CONTAINER"
    echo "(restart alone is not enough - the writable layer keeps the patched chunk)"
    ;;

  *)
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
