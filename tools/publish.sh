#!/bin/bash
# Publishes this game's pack (prod id game-prop-hunt; it was mg-prop-hunt until 2026-11-13, which is not the id prod serves).
# maps/ is a link to mg-prop-hunt-maps, its own pack; art-src, reports and screenshots are not runtime content. Host addons come
# from the server (--host-addons). Works from a ~/wt worktree too: the family repos are found beside the main checkout, and
# publish_pack.sh relinks the worktree's dangling addons/ links.
#   tools/publish.sh [--version V | --bump patch] [--site URL --token-file F --dry-run ...]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAM="$(cd "$HERE/.." && pwd)"
[ -x "$FAM/dot-cloud/tools/publish_pack.sh" ] || FAM="${DOT_FAMILY_DIR:-/home/gamedev/godot}"
[ -x "$FAM/dot-cloud/tools/publish_pack.sh" ] || { echo "publish.sh: dot-cloud not found beside $HERE or in $FAM (set DOT_FAMILY_DIR)" >&2; exit 2; }
export DOT_FAMILY_DIR="$FAM"
exec "$FAM/dot-cloud/tools/publish_pack.sh" publish --source "$HERE" --id game-prop-hunt \
    --host-addons "$FAM/dot-server-deploy/addons.lock" --exclude-dir maps --exclude-dir art-src --exclude-dir reports --exclude-dir screenshots \
    --lock "$HERE/content.lock.json" "$@"
