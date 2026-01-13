#!/usr/bin/env bash
set -euo pipefail

# Print memorder variant ids only.
cat <<'LIST'
default
sb
sb-bypass
sb-fence-nop
LIST
