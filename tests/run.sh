#!/usr/bin/env bash
# Resolve the Qt6 qmltestrunner. On some distros PATH's `qmltestrunner` is Qt5,
# which silently exits 1 on Qt6 imports, so we do not trust the bare name.
# QMLTESTRUNNER wins when set: CI installs a pinned Qt outside the distro's
# packages (ADR-0004) and names its runner explicitly.
set -euo pipefail
if [ -n "${QMLTESTRUNNER:-}" ]; then
  RUNNER="$QMLTESTRUNNER"                        # pinned install (CI), or a local override
elif command -v qmltestrunner6 >/dev/null 2>&1; then
  RUNNER=qmltestrunner6                          # Debian/Ubuntu (qt6-declarative-dev-tools)
elif [ -x /usr/lib/qt6/bin/qmltestrunner ]; then
  RUNNER=/usr/lib/qt6/bin/qmltestrunner          # Arch (qt6-declarative), upstream layout
else
  echo "No Qt6 qmltestrunner found (tried: \$QMLTESTRUNNER, qmltestrunner6, /usr/lib/qt6/bin/qmltestrunner)." >&2
  echo "Install qt6-declarative (Arch) or qt6-declarative-dev-tools (Debian/Ubuntu), or set QMLTESTRUNNER." >&2
  exit 127
fi
env QT_QPA_PLATFORMTHEME=generic QT_QPA_PLATFORM=offscreen "$RUNNER" -input "$(dirname "$0")"
bash "$(dirname "$0")/ui/run.sh"
bash "$(dirname "$0")/lua-check.sh"
bash "$(dirname "$0")/config-save.sh"
bash "$(dirname "$0")/dev-link.sh"
bash "$(dirname "$0")/split-lore.sh"
