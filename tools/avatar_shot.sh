#!/usr/bin/env bash
# A third-person look at an avatar (stand-in playing an emote), framed in full. Real GPU via gpu.sh.
#   tools/avatar_shot.sh
set -euo pipefail
cd "$(dirname "$0")/.."
exec tools/shot.sh --action emote dance "$@"
