#!/usr/bin/env bash
# Retain the established entry point; exercise production typed dispatch in Lua mode.
set -euo pipefail
bash "$(dirname "$0")/drag.sh"
bash "$(dirname "$0")/fullscreen.sh"
bash "$(dirname "$0")/peek-probe.sh"
