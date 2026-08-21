# Locate the shared toolchain, wherever this checkout happens to sit.
#
# Sourced by the build and run scripts; sets VASM, VLINK, HATARI, TOS and
# friends. Nothing here is F29-specific - the toolchain lives in the sibling
# checkouts (F030Arcade, f030dsp3d) and is shared with them.
#
# Every tool resolves in the same order:
#
#   1. the matching environment variable, if it is already set - always wins
#   2. the sibling checkouts, looked for next to this one and then in the
#      original development machine's /c/Arbeit
#   3. $PATH, by base name
#
# Both the native name and the Windows .exe name are tried at each candidate,
# so the same script works from an MSYS2 shell and from a Mac or Linux box.

# Roots that may hold the sibling checkouts. This checkout's parent comes
# first so a local layout always beats the hard-coded one.
F29_ROOTS=${F29_ROOTS:-"$(dirname -- "$ROOT") /c/Arbeit"}

# f29_find VAR relative-candidate...
# Echoes the first candidate that exists. Honours $VAR if already set.
f29_find() {
    local var=$1; shift
    eval "local cur=\${$var}"
    if [ -n "$cur" ]; then printf '%s\n' "$cur"; return 0; fi

    local root rel cand
    # An absolute candidate is a machine-specific path (a Windows install
    # directory, say) and is tested as given, not joined to a root.
    for rel in "$@"; do
        case $rel in /*)
            for cand in "$rel" "$rel.exe"; do
                if [ -e "$cand" ]; then printf '%s\n' "$cand"; return 0; fi
            done ;;
        esac
    done

    for root in $F29_ROOTS; do
        for rel in "$@"; do
            case $rel in /*) continue ;; esac
            for cand in "$root/$rel" "$root/$rel.exe"; do
                if [ -e "$cand" ]; then printf '%s\n' "$cand"; return 0; fi
            done
        done
    done

    for rel in "$@"; do
        if cand=$(command -v "$(basename "$rel")" 2>/dev/null); then
            printf '%s\n' "$cand"; return 0
        fi
    done
    return 1
}

# f29_require VAR relative-candidate...
# As f29_find, but assigns and exports VAR, and fails loudly with the list of
# places that were tried.
f29_require() {
    local var=$1; shift
    local val
    # An override is honoured as given, but still has to exist - otherwise the
    # failure surfaces much later, as the tool itself failing to execute.
    eval "local cur=\${$var}"
    if [ -n "$cur" ] && [ ! -e "$cur" ]; then
        echo "error: $var is set to '$cur', which does not exist." >&2
        return 1
    fi
    if ! val=$(f29_find "$var" "$@"); then
        {
            echo "error: $var not found."
            echo "  looked under: $F29_ROOTS"
            local rel; for rel in "$@"; do echo "    $rel"; done
            echo "  and on \$PATH. Set $var=... to point at it."
        } >&2
        return 1
    fi
    eval "$var=\$val"
    export "$var"
}

# f29_optional VAR relative-candidate...
# As f29_require, but a miss is not an error - VAR is just left empty.
f29_optional() {
    local var=$1; shift
    local val
    if val=$(f29_find "$var" "$@"); then eval "$var=\$val"; export "$var"; fi
    return 0
}

# Translate a path for a tool that does not understand MSYS2's /c/... form.
# A no-op everywhere except under MSYS2/Cygwin, where cygpath exists.
f29_hostpath() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s\n' "$1"; fi
}
