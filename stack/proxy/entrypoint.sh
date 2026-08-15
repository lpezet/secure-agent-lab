#!/bin/bash
set -e

# Two addon sources, loaded in this order:
#
#   /opt/agent-proxy/addons   baked into the image — the controls a deployment
#                             does not get to choose (000_policy.py, 001_allowlist.py)
#   /addons                   bind-mounted by the deployment — the providers it does
#
# The baked ones cannot simply live in /addons. A deployment's bind mount
# replaces that directory wholesale, so anything baked there vanishes at
# exactly the moment a deployment supplies providers of its own — which is how
# a stack could end up running with no internal-host block at all.
#
# Load order therefore stops being a convention: policy runs first by
# construction rather than by alphabetical luck. The 000_/001_ prefixes on the
# baked files are now only a hint to the reader.
BAKED_DIR="${BAKED_ADDONS_DIR:-/opt/agent-proxy/addons}"
ADDONS_DIR="${ADDONS_DIR:-/addons}"

args=()
baked=()

while IFS= read -r f; do
    args+=(-s "$f")
    baked+=("$(basename "$f")")
done < <(find "$BAKED_DIR" -maxdepth 1 -name '*.py' 2>/dev/null | sort)

# A deployment that still vendors its own 000_policy.py — every deployment
# written before the image carried one — would otherwise load it a second time.
# Harmless in itself (a second identical block is idempotent) but it hides
# which copy is in force, so say so and skip it. The image's copy wins: that is
# the whole point of baking it.
while IFS= read -r f; do
    name="$(basename "$f")"
    shadowed=
    for b in ${baked[@]+"${baked[@]}"}; do
        if [ "$name" = "$b" ]; then shadowed=1; break; fi
    done
    if [ -n "$shadowed" ]; then
        echo "entrypoint: ignoring $f — the image ships $name and it takes precedence" >&2
        continue
    fi
    args+=(-s "$f")
done < <(find "$ADDONS_DIR" -maxdepth 1 -name '*.py' 2>/dev/null | sort)

exec mitmdump \
    --listen-host 0.0.0.0 \
    --listen-port 8080 \
    --set confdir=/home/mitmproxy/.mitmproxy \
    "${args[@]}"
