#!/bin/bash
# Publishes this game's pack (id mg-prop-hunt). maps/ is a link to mg-prop-hunt-maps, its own pack; art-src, reports and
# screenshots are not runtime content. Host addons come from the server (--host-addons).
#   tools/publish.sh [--version V | --bump patch] [--site URL --token-file F --dry-run ...]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$HERE/../dot-cloud/tools/publish_pack.sh" publish --source "$HERE" --id mg-prop-hunt \
    --host-addons "$HERE/../dot-server-deploy/addons.lock" --exclude-dir maps --exclude-dir art-src --exclude-dir reports --exclude-dir screenshots \
    --lock "$HERE/content.lock.json" "$@"
