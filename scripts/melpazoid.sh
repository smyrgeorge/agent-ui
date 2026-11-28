#!/usr/bin/env bash
# melpazoid <https://github.com/riscy/melpazoid>: the checks MELPA's reviewers
# run on a recipe (its build, package-lint, byte-compile, checkdoc, and its
# own), in a container with the newest Emacs, as `make melpazoid` and CI run
# them. A warning fails the run as an error does (WARN_IS_ERROR=false: said
# only).
#
#   scripts/melpazoid.sh
#
# Needs Docker, python3 and git. MELPAZOID (default .deps/melpazoid) is
# melpazoid's clone, cloned if it isn't there; RECIPE the recipe, as it will
# be written for MELPA; EXIST_OK=true once Agent UI is on MELPA.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MELPAZOID=${MELPAZOID:-${DEPS_DIR:-$ROOT/.deps}/melpazoid}
RECIPE=${RECIPE:-'(agent-ui :fetcher github :repo "smyrgeorge/agent-ui" :files (:defaults "bin" "skills" "assets"))'}

case "${1:-}" in
  -h|--help) sed -n '2,/^$/{s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
esac
command -v docker >/dev/null || { echo "melpazoid.sh: needs Docker" >&2; exit 2; }
command -v python3 >/dev/null || { echo "melpazoid.sh: needs python3" >&2; exit 2; }
[ -d "$MELPAZOID" ] || git clone --depth 1 https://github.com/riscy/melpazoid "$MELPAZOID"

LOCAL_REPO="$ROOT" RECIPE="$RECIPE" EXIST_OK=${EXIST_OK:-false} WARN_IS_ERROR=${WARN_IS_ERROR:-true} \
  make -C "$MELPAZOID"
