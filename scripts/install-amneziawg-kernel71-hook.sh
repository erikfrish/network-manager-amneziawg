#!/bin/bash
#
# Install a self-removing pacman hook for amneziawg-dkms on Linux >= 7.1.
#
# The problem:
#   Linux 7.1 removed the "ipv6_stub" indirection that older out-of-tree
#   modules used to call ipv6_dst_lookup_flow().  amneziawg-dkms 1.0.0
#   still references it in socket.c:
#
#       dst = ipv6_stub->ipv6_dst_lookup_flow(...)
#
#   which makes DKMS fail on CachyOS/Arch kernels >= 7.1 with:
#
#       error: use of undeclared identifier 'ipv6_stub'
#
#   Upstream PR with the proper fix:
#       https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/pull/176
#
# What this script installs:
#   A pacman PostTransaction hook + helper that runs after every
#   install/upgrade of amneziawg-dkms.  It scans
#   /usr/src/amneziawg-*/socket.c and, only if the obsolete code is
#   still there, replaces it with the now-direct ip6_dst_lookup_flow()
#   call, marks the patched line with a unique comment, and rebuilds
#   the DKMS module(s) for the running kernel.
#
# Self-destruction logic:
#   If the obsolete string is gone AND our marker comment is also absent
#   from all amneziawg socket.c files, the packaged sources already
#   contain the upstream fix.  The helper then removes the pacman hook
#   file so it will not run again.  The helper script itself is left in
#   /usr/local/lib and can be deleted manually once the hook is gone.
#
# Usage:
#   sudo ./scripts/install-amneziawg-kernel71-hook.sh
#
# Supported distributions:
#   Arch Linux / CachyOS / any pacman-based distro with hooks enabled.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HELPER_SRC="/usr/local/lib/amneziawg-kernel71-fix.sh"
HOOK_DST="/etc/pacman.d/hooks/amneziawg-kernel71-fix.hook"
MARKER='AWG_KERNEL71_HOOK_MARKER'

ask_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        if command -v pkexec >/dev/null 2>&1; then
            echo "Requesting root privileges via pkexec..." >&2
            exec pkexec "$0" "$@"
        elif command -v sudo >/dev/null 2>&1; then
            echo "Requesting root privileges via sudo..." >&2
            exec sudo "$0" "$@"
        else
            echo "This script must be run as root." >&2
            exit 1
        fi
    fi
}

install_helper() {
    cat > "$HELPER_SRC" <<'HELPER_EOF'
#!/bin/bash
#
# amneziawg-kernel71-fix.sh — Pacman/DKMS post-transaction helper
# -----------------------------------------------------------------
#
# Why this exists:
#   Linux 7.1 (and newer) removed the "ipv6_stub" indirection that
#   older out-of-tree modules used to call ipv6_dst_lookup_flow().
#   amneziawg-dkms 1.0.0 still uses:
#
#       dst = ipv6_stub->ipv6_dst_lookup_flow(sock_net(sock), sock, &fl, NULL);
#
#   which causes DKMS builds on kernels >= 7.1 to fail with:
#
#       error: use of undeclared identifier 'ipv6_stub'
#
#   The proper fix lives upstream in this PR:
#       https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/pull/176
#   Until that change (or an equivalent one) reaches the packaged
#   amneziawg-dkms sources, this helper applies the one-line workaround.
#
# What it does:
#   This script is executed by the pacman PostTransaction hook after
#   every install/upgrade of amneziawg-dkms (or the upstream
#   amneziawg-linux-kernel-module package).  It looks at every
#   /usr/src/amneziawg-*/socket.c file and, only if the obsolete
#   "ipv6_stub->ipv6_dst_lookup_flow" string is still present, replaces
#   it with the direct "ip6_dst_lookup_flow" call.  It also embeds a
#   unique marker comment into the patched source so it can tell the
#   difference between "we patched this" and "upstream already fixed it".
#   After patching, it runs "dkms autoinstall" to rebuild the module.
#
# How it removes itself:
#   If the obsolete string is NOT found AND the marker comment is also
#   NOT found in any amneziawg socket.c, the packaged source tree has
#   already been fixed upstream.  In that case the helper deletes the
#   pacman hook file (/etc/pacman.d/hooks/amneziawg-kernel71-fix.hook)
#   so it will not execute again.  The helper script itself is left
#   behind harmlessly in /usr/local/lib and may be deleted manually.
#
# Exit policy:
#   DKMS rebuild errors are intentionally non-fatal ("|| true") because
#   a pacman PostTransaction hook must never abort a transaction.
#   Build failures can be inspected later in /var/lib/dkms/amneziawg/.
#

set -e

hook_file="/etc/pacman.d/hooks/amneziawg-kernel71-fix.hook"
fixed=0
marker='AWG_KERNEL71_HOOK_MARKER'

# Scan every amneziawg socket.c shipped by the DKMS package.
for f in /usr/src/amneziawg-*/socket.c; do
    # Skip if glob did not expand (e.g. package was removed).
    [[ -e "$f" ]] || continue

    # Only patch if the obsolete kernel 7.1-incompatible code is present.
    if grep -q 'ipv6_stub->ipv6_dst_lookup_flow' "$f"; then
        # Replace the indirect stub call with the direct function call.
        sed -i 's/ipv6_stub->ipv6_dst_lookup_flow/ip6_dst_lookup_flow/g' "$f"

        # Drop a marker so we can distinguish "patched by us" from
        # "already fixed by upstream" on future package updates.
        if ! grep -qF "$marker" "$f"; then
            sed -i "/ip6_dst_lookup_flow/i\\\t\\t/* $marker: compatibility fix for kernels >= 7.1 */" "$f"
        fi

        echo "Patched $f"
        fixed=1
    fi
done

if [[ "$fixed" -eq 1 ]]; then
    echo "Rebuilding amneziawg DKMS modules..."
    dkms autoinstall || true
else
    # No patching was necessary.  If our marker is also missing from all
    # source files, upstream already fixed it -- remove the hook.
    if ! grep -RqF "$marker" /usr/src/amneziawg-*/socket.c 2>/dev/null; then
        echo "amneziawg: upstream already fixed, removing compatibility hook"
        rm -f "$hook_file"
    else
        echo "amneziawg: compatibility patch already present, nothing to do"
    fi
fi
HELPER_EOF

    chmod +x "$HELPER_SRC"
}

install_hook() {
    mkdir -p "$(dirname "$HOOK_DST")"

    cat > "$HOOK_DST" <<'HOOK_EOF'
# Pacman hook: apply amneziawg IPv6-stub compatibility patch on kernel >= 7.1.
#
# See /usr/local/lib/amneziawg-kernel71-fix.sh for the full explanation.
# The hook is removed automatically by the helper once the packaged
# amneziawg-dkms sources no longer need the workaround.

[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
# Catch both the common AUR/Arch package name and the upstream source package name.
Target = amneziawg-dkms
Target = amneziawg-linux-kernel-module

[Action]
Description = Apply amneziawg IPv6-stub compatibility patch for kernel 7.x
When = PostTransaction
Exec = /usr/local/lib/amneziawg-kernel71-fix.sh
NeedsTargets = no
HOOK_EOF

    chmod 644 "$HOOK_DST"
}

main() {
    ask_root "$@"

    echo "Installing amneziawg kernel 7.1 compatibility hook..."
    install_helper
    install_hook

    echo "Installed:"
    echo "  helper : $HELPER_SRC"
    echo "  hook   : $HOOK_DST"
    echo
    echo "The hook will run automatically after future amneziawg-dkms"
    echo "installs/upgrades and will remove itself once upstream fixes"
    echo "the ipv6_stub issue."
}

main "$@"
