#!/usr/bin/env bash
# Venv Cleaner for macOS + Linux
# Interactive, structural Python virtual-environment scanner and cleaner.
# Bash 3.2+ compatible (including the Bash shipped with macOS).

set -u

VERSION="1.0.0"
INCLUDE_NETWORK=0
DEEP_SCAN=0
LIST_ONLY=0
NO_COLOR=0
ROOT_ARGS=()

# ----------------------------- CLI -----------------------------

usage() {
    cat <<'USAGE'
Venv Cleaner for macOS + Linux

Usage:
  ./Venv-Cleaner-Unix.sh [options]

Options:
  --root PATH          Scan only PATH. May be specified multiple times.
  --include-network    Include network filesystems/mounts.
  --deep               Do not prune common heavy non-environment directories.
  --list               Scan and print results; do not open the interactive UI.
  --no-color           Disable ANSI colors.
  -h, --help           Show this help.
  --version            Print version.

Interactive controls:
  Up / Down            Move
  PageUp / PageDown    Move one page
  Home / End           First / last
  Space                Select / deselect
  A                    Select / deselect all safe environments
  Enter                Review and delete selected environments
  R                    Rescan
  Q / Ctrl+C           Exit

Notes:
  * Folder names alone are never trusted. Candidates must pass structural checks.
  * Active environments, Conda base, mounted roots, pipx app environments,
    uv tool environments, and environments with a running Python process are protected.
  * Network filesystems are skipped unless --include-network is used.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --root)
            shift
            if [ "$#" -eq 0 ]; then
                echo "Error: --root requires a path." >&2
                exit 2
            fi
            ROOT_ARGS+=("$1")
            ;;
        --include-network) INCLUDE_NETWORK=1 ;;
        --deep) DEEP_SCAN=1 ;;
        --list) LIST_ONLY=1 ;;
        --no-color) NO_COLOR=1 ;;
        --version) echo "$VERSION"; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

OS="$(uname -s 2>/dev/null || echo unknown)"
case "$OS" in
    Darwin|Linux) ;;
    *) echo "Unsupported OS: $OS. This script supports macOS and Linux." >&2; exit 1 ;;
esac

# ----------------------------- Terminal / colors -----------------------------

HAS_TTY=0
TTY_FD=3
if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    if exec 3<>/dev/tty 2>/dev/null; then
        HAS_TTY=1
    fi
fi

if [ -n "${NO_COLOR:-}" ] && [ "${NO_COLOR:-0}" != "0" ]; then
    NO_COLOR=1
fi

if [ "$NO_COLOR" -eq 0 ] && [ "$HAS_TTY" -eq 1 ]; then
    C_RESET=$'\033[0m'
    C_CYAN=$'\033[36m'
    C_DIM=$'\033[2m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'
    C_BLUE=$'\033[34m'
    C_REVERSE=$'\033[7m'
else
    C_RESET=''; C_CYAN=''; C_DIM=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_BLUE=''; C_REVERSE=''
fi

TMP_BASE="${TMPDIR:-/tmp}"
TMP_DIR="$(mktemp -d "$TMP_BASE/venv-cleaner.XXXXXX" 2>/dev/null || mktemp -d 2>/dev/null)"
if [ -z "$TMP_DIR" ] || [ ! -d "$TMP_DIR" ]; then
    echo "Could not create a temporary directory." >&2
    exit 1
fi

cleanup() {
    if [ "$HAS_TTY" -eq 1 ]; then
        printf '\033[?25h%s' "$C_RESET" >&3 2>/dev/null || true
    fi
    rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT HUP TERM
trap 'exit 130' INT

# ----------------------------- Helpers -----------------------------

canonical_dir() {
    # Resolve an existing directory without requiring realpath/readlink -f (missing on stock macOS).
    local p="$1"
    (cd -P -- "$p" 2>/dev/null && pwd -P) || printf '%s\n' "$p"
}

trim_trailing_slash() {
    local p="$1"
    if [ "$p" != "/" ]; then
        while [ "${p%/}" != "$p" ]; do p="${p%/}"; done
    fi
    printf '%s\n' "$p"
}

path_inside() {
    local child parent
    child="$(trim_trailing_slash "$1")"
    parent="$(trim_trailing_slash "$2")"
    [ -n "$child" ] && [ -n "$parent" ] || return 1
    if [ "$parent" = "/" ]; then return 0; fi
    case "$child" in
        "$parent"|"$parent"/*) return 0 ;;
        *) return 1 ;;
    esac
}

array_contains_path() {
    local needle="$1"; shift
    local x
    for x in "$@"; do
        [ "$x" = "$needle" ] && return 0
    done
    return 1
}

human_kb() {
    local kb="${1:-0}"
    awk -v k="$kb" 'BEGIN {
        if (k >= 1073741824) printf "%.1f TB", k/1073741824;
        else if (k >= 1048576) printf "%.1f GB", k/1048576;
        else if (k >= 1024) printf "%.1f MB", k/1024;
        else printf "%d KB", k;
    }'
}

mtime_epoch() {
    local p="$1"
    if [ "$OS" = "Darwin" ]; then
        stat -f '%m' "$p" 2>/dev/null || echo 0
    else
        stat -c '%Y' "$p" 2>/dev/null || echo 0
    fi
}

format_date() {
    local epoch="${1:-0}"
    if [ "$epoch" -le 0 ] 2>/dev/null; then
        printf '%s' '-'
    elif [ "$OS" = "Darwin" ]; then
        date -r "$epoch" '+%Y-%m-%d' 2>/dev/null || printf '%s' '-'
    else
        date -d "@$epoch" '+%Y-%m-%d' 2>/dev/null || printf '%s' '-'
    fi
}

size_kb() {
    local p="$1" out
    out="$(du -sk "$p" 2>/dev/null | awk 'NR==1 {print $1}')"
    case "$out" in ''|*[!0-9]*) echo 0 ;; *) echo "$out" ;; esac
}

truncate_left() {
    local s="$1" max="$2" len start
    len=${#s}
    if [ "$len" -le "$max" ]; then printf '%s' "$s"; return; fi
    if [ "$max" -le 3 ]; then printf '%.*s' "$max" "$s"; return; fi
    start=$((len - max + 3))
    printf '...%s' "${s:$start}"
}

add_unique_path() {
    # Usage: add_unique_path ARRAY_NAME PATH
    # Bash 3.2 has no namerefs; handle the known arrays explicitly at call sites instead.
    return 0
}

# ----------------------------- Environment context -----------------------------

ACTIVE_PATHS=()
POETRY_ROOTS=()
PIPENV_ROOTS=()
UV_TOOL_ROOTS=()
UV_CACHE_ROOTS=()
PIPX_VENV_ROOTS=()
PYENV_ROOTS=()
SCAN_ROOTS=()
CONDA_BASE=''
RUNNING_COMMANDS="$(ps -axo command= 2>/dev/null || true)"
SCRIPT_PATH=''

if [ -n "${BASH_SOURCE[0]:-}" ] && [ -e "${BASH_SOURCE[0]}" ]; then
    case "${BASH_SOURCE[0]}" in
        /*) SCRIPT_PATH="${BASH_SOURCE[0]}" ;;
        *) SCRIPT_PATH="$(pwd -P)/${BASH_SOURCE[0]}" ;;
    esac
fi

add_to_array_unique() {
    # $1 is logical array name, $2 is path. Kept explicit for Bash 3.2 compatibility.
    local arr="$1" p="$2" existing
    [ -n "$p" ] || return 0
    if [ -d "$p" ]; then p="$(canonical_dir "$p")"; else p="$(trim_trailing_slash "$p")"; fi
    case "$arr" in
        ACTIVE_PATHS)
            for existing in "${ACTIVE_PATHS[@]:-}"; do [ "$existing" = "$p" ] && return 0; done
            ACTIVE_PATHS+=("$p") ;;
        POETRY_ROOTS)
            for existing in "${POETRY_ROOTS[@]:-}"; do [ "$existing" = "$p" ] && return 0; done
            POETRY_ROOTS+=("$p") ;;
        PIPENV_ROOTS)
            for existing in "${PIPENV_ROOTS[@]:-}"; do [ "$existing" = "$p" ] && return 0; done
            PIPENV_ROOTS+=("$p") ;;
        UV_TOOL_ROOTS)
            for existing in "${UV_TOOL_ROOTS[@]:-}"; do [ "$existing" = "$p" ] && return 0; done
            UV_TOOL_ROOTS+=("$p") ;;
        UV_CACHE_ROOTS)
            for existing in "${UV_CACHE_ROOTS[@]:-}"; do [ "$existing" = "$p" ] && return 0; done
            UV_CACHE_ROOTS+=("$p") ;;
        PIPX_VENV_ROOTS)
            for existing in "${PIPX_VENV_ROOTS[@]:-}"; do [ "$existing" = "$p" ] && return 0; done
            PIPX_VENV_ROOTS+=("$p") ;;
        PYENV_ROOTS)
            for existing in "${PYENV_ROOTS[@]:-}"; do [ "$existing" = "$p" ] && return 0; done
            PYENV_ROOTS+=("$p") ;;
        SCAN_ROOTS)
            for existing in "${SCAN_ROOTS[@]:-}"; do [ "$existing" = "$p" ] && return 0; done
            SCAN_ROOTS+=("$p") ;;
    esac
}

for active in "${VIRTUAL_ENV:-}" "${CONDA_PREFIX:-}"; do
    [ -n "$active" ] && add_to_array_unique ACTIVE_PATHS "$active"
done

# Homes worth checking. If invoked through sudo, include the invoking user's home as well.
USER_HOMES=()
if [ -n "${HOME:-}" ] && [ -d "$HOME" ]; then USER_HOMES+=("$(canonical_dir "$HOME")"); fi
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER:-}" != "root" ]; then
    sudo_home=''
    if command -v getent >/dev/null 2>&1; then
        sudo_home="$(getent passwd "$SUDO_USER" 2>/dev/null | awk -F: 'NR==1 {print $6}')"
    elif [ "$OS" = "Darwin" ] && command -v dscl >/dev/null 2>&1; then
        sudo_home="$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
    fi
    if [ -n "$sudo_home" ] && [ -d "$sudo_home" ]; then
        found=0
        for h in "${USER_HOMES[@]:-}"; do [ "$h" = "$sudo_home" ] && found=1; done
        [ "$found" -eq 0 ] && USER_HOMES+=("$(canonical_dir "$sudo_home")")
    fi
fi

# Poetry roots.
[ -n "${POETRY_VIRTUALENVS_PATH:-}" ] && add_to_array_unique POETRY_ROOTS "$POETRY_VIRTUALENVS_PATH"
if command -v poetry >/dev/null 2>&1; then
    poetry_root="$(poetry config virtualenvs.path 2>/dev/null | head -n 1)"
    [ -n "$poetry_root" ] && add_to_array_unique POETRY_ROOTS "$poetry_root"
fi
for h in "${USER_HOMES[@]:-}"; do
    if [ "$OS" = "Darwin" ]; then
        add_to_array_unique POETRY_ROOTS "$h/Library/Caches/pypoetry/virtualenvs"
    else
        if [ "$h" = "${HOME:-}" ] && [ -n "${XDG_CACHE_HOME:-}" ]; then
            add_to_array_unique POETRY_ROOTS "$XDG_CACHE_HOME/pypoetry/virtualenvs"
        fi
        add_to_array_unique POETRY_ROOTS "$h/.cache/pypoetry/virtualenvs"
    fi
done

# Pipenv roots.
[ -n "${WORKON_HOME:-}" ] && add_to_array_unique PIPENV_ROOTS "$WORKON_HOME"
for h in "${USER_HOMES[@]:-}"; do
    add_to_array_unique PIPENV_ROOTS "$h/.local/share/virtualenvs"
done

# uv tool / cache roots.
[ -n "${UV_TOOL_DIR:-}" ] && add_to_array_unique UV_TOOL_ROOTS "$UV_TOOL_DIR"
[ -n "${UV_CACHE_DIR:-}" ] && add_to_array_unique UV_CACHE_ROOTS "$UV_CACHE_DIR"
if command -v uv >/dev/null 2>&1; then
    uv_tool_root="$(uv tool dir 2>/dev/null | head -n 1)"
    uv_cache_root="$(uv cache dir 2>/dev/null | head -n 1)"
    [ -n "$uv_tool_root" ] && add_to_array_unique UV_TOOL_ROOTS "$uv_tool_root"
    [ -n "$uv_cache_root" ] && add_to_array_unique UV_CACHE_ROOTS "$uv_cache_root"
fi
for h in "${USER_HOMES[@]:-}"; do
    if [ "$h" = "${HOME:-}" ] && [ -n "${XDG_DATA_HOME:-}" ]; then
        add_to_array_unique UV_TOOL_ROOTS "$XDG_DATA_HOME/uv/tools"
    fi
    add_to_array_unique UV_TOOL_ROOTS "$h/.local/share/uv/tools"
    if [ "$h" = "${HOME:-}" ] && [ -n "${XDG_CACHE_HOME:-}" ]; then
        add_to_array_unique UV_CACHE_ROOTS "$XDG_CACHE_HOME/uv"
    fi
    add_to_array_unique UV_CACHE_ROOTS "$h/.cache/uv"
done

# pipx roots.
[ -n "${PIPX_HOME:-}" ] && add_to_array_unique PIPX_VENV_ROOTS "$PIPX_HOME/venvs"
if command -v pipx >/dev/null 2>&1; then
    pipx_home="$(pipx environment --value PIPX_HOME 2>/dev/null | head -n 1)"
    [ -n "$pipx_home" ] && add_to_array_unique PIPX_VENV_ROOTS "$pipx_home/venvs"
fi
for h in "${USER_HOMES[@]:-}"; do
    if [ "$OS" = "Darwin" ]; then
        add_to_array_unique PIPX_VENV_ROOTS "$h/Library/Application Support/pipx/venvs"
    else
        if [ "$h" = "${HOME:-}" ] && [ -n "${XDG_DATA_HOME:-}" ]; then
            add_to_array_unique PIPX_VENV_ROOTS "$XDG_DATA_HOME/pipx/venvs"
        fi
        add_to_array_unique PIPX_VENV_ROOTS "$h/.local/share/pipx/venvs"
    fi
    # Legacy pipx location.
    add_to_array_unique PIPX_VENV_ROOTS "$h/.local/pipx/venvs"
done
add_to_array_unique PIPX_VENV_ROOTS "/opt/pipx/venvs"

# pyenv / pyenv-virtualenv roots. These are manager-owned and are protected from raw rm -rf.
[ -n "${PYENV_ROOT:-}" ] && add_to_array_unique PYENV_ROOTS "$PYENV_ROOT"
for h in "${USER_HOMES[@]:-}"; do
    add_to_array_unique PYENV_ROOTS "$h/.pyenv"
done

if command -v conda >/dev/null 2>&1; then
    CONDA_BASE="$(conda info --base 2>/dev/null | head -n 1)"
    [ -n "$CONDA_BASE" ] && [ -d "$CONDA_BASE" ] && CONDA_BASE="$(canonical_dir "$CONDA_BASE")"
fi

# ----------------------------- Filesystem roots -----------------------------

is_network_fs() {
    case "${1:-}" in
        nfs|nfs4|cifs|smbfs|smb3|sshfs|fuse.sshfs|afpfs|davfs|davfs2|9p|ceph|glusterfs) return 0 ;;
        *) return 1 ;;
    esac
}

is_pseudo_fs() {
    case "${1:-}" in
        proc|procfs|sysfs|devfs|devtmpfs|tmpfs|ramfs|cgroup|cgroup2|pstore|securityfs|debugfs|tracefs|configfs|mqueue|hugetlbfs|nsfs|autofs) return 0 ;;
        *) return 1 ;;
    esac
}

build_scan_roots() {
    SCAN_ROOTS=()
    local r target fstype decoded

    if [ "${#ROOT_ARGS[@]}" -gt 0 ]; then
        for r in "${ROOT_ARGS[@]}"; do
            if [ -d "$r" ]; then
                add_to_array_unique SCAN_ROOTS "$r"
            else
                echo "Warning: scan root does not exist: $r" >&2
            fi
        done
        return
    fi

    if [ "$OS" = "Linux" ]; then
        if command -v findmnt >/dev/null 2>&1; then
            while IFS=' ' read -r target fstype _rest; do
                [ -n "${target:-}" ] || continue
                decoded="$(printf '%b' "$target" 2>/dev/null || printf '%s' "$target")"
                if is_pseudo_fs "${fstype:-}"; then continue; fi
                if [ "$INCLUDE_NETWORK" -eq 0 ] && is_network_fs "${fstype:-}"; then continue; fi
                [ -d "$decoded" ] && add_to_array_unique SCAN_ROOTS "$decoded"
            done < <(findmnt -rn -o TARGET,FSTYPE 2>/dev/null)
        fi
        # Fallback and safety net if findmnt is unavailable or yielded nothing.
        [ "${#SCAN_ROOTS[@]}" -eq 0 ] && add_to_array_unique SCAN_ROOTS "/"
    else
        # Root volume plus mounted local volumes. Most user-visible macOS volumes live under /Volumes.
        root_fs="$(stat -f '%T' / 2>/dev/null || echo apfs)"
        if [ "$INCLUDE_NETWORK" -eq 1 ] || ! is_network_fs "$root_fs"; then
            add_to_array_unique SCAN_ROOTS "/"
        fi
        if [ -d /Volumes ]; then
            for r in /Volumes/*; do
                [ -d "$r" ] || continue
                fstype="$(stat -f '%T' "$r" 2>/dev/null || echo unknown)"
                if [ "$INCLUDE_NETWORK" -eq 0 ] && is_network_fs "$fstype"; then continue; fi
                add_to_array_unique SCAN_ROOTS "$r"
            done
        fi
    fi
}

# ----------------------------- Verification -----------------------------

VERIFY_PROVIDER=''
VERIFY_EVIDENCE=''
VERIFY_PROTECTED=0
VERIFY_REASON=''

has_python_executable() {
    local p="$1"
    [ -e "$p/bin/python" ] || [ -L "$p/bin/python" ] || [ -e "$p/bin/python3" ] || [ -L "$p/bin/python3" ]
}

has_site_packages() {
    local p="$1" d
    for d in "$p"/lib/python*/site-packages "$p"/lib64/python*/site-packages; do
        [ -d "$d" ] && return 0
    done
    return 1
}

classify_provider() {
    local p="$1" parent cfg root
    VERIFY_PROVIDER='Python venv'

    if [ -f "$p/conda-meta/history" ]; then
        VERIFY_PROVIDER='Conda'
        return
    fi

    for root in "${PIPX_VENV_ROOTS[@]:-}"; do
        if [ -n "$root" ] && path_inside "$p" "$root"; then VERIFY_PROVIDER='pipx tool'; return; fi
    done
    for root in "${UV_TOOL_ROOTS[@]:-}"; do
        if [ -n "$root" ] && path_inside "$p" "$root"; then VERIFY_PROVIDER='uv tool'; return; fi
    done
    for root in "${PYENV_ROOTS[@]:-}"; do
        if [ -n "$root" ] && path_inside "$p" "$root/versions"; then VERIFY_PROVIDER='pyenv'; return; fi
    done
    for root in "${UV_CACHE_ROOTS[@]:-}"; do
        if [ -n "$root" ] && path_inside "$p" "$root"; then VERIFY_PROVIDER='uv cache'; return; fi
    done
    for root in "${POETRY_ROOTS[@]:-}"; do
        if [ -n "$root" ] && path_inside "$p" "$root"; then VERIFY_PROVIDER='Poetry'; return; fi
    done
    for root in "${PIPENV_ROOTS[@]:-}"; do
        if [ -n "$root" ] && path_inside "$p" "$root"; then VERIFY_PROVIDER='Pipenv'; return; fi
    done

    parent="$(dirname "$p")"
    if [ -f "$parent/uv.lock" ]; then VERIFY_PROVIDER='uv'; return; fi
    if [ -f "$parent/Pipfile" ] || [ -f "$parent/Pipfile.lock" ]; then VERIFY_PROVIDER='Pipenv'; return; fi
    if [ -f "$parent/pdm.lock" ]; then VERIFY_PROVIDER='PDM'; return; fi
    if [ -f "$parent/poetry.lock" ]; then VERIFY_PROVIDER='Poetry'; return; fi
    if [ -f "$parent/pyproject.toml" ] && grep -Eq '^\[tool\.poetry\]' "$parent/pyproject.toml" 2>/dev/null; then
        VERIFY_PROVIDER='Poetry'; return
    fi

    cfg="$p/pyvenv.cfg"
    if [ -f "$cfg" ]; then
        if grep -Eiq '^uv[[:space:]]*=' "$cfg" 2>/dev/null; then VERIFY_PROVIDER='uv'; return; fi
        if grep -Eiq 'virtualenv' "$cfg" 2>/dev/null; then VERIFY_PROVIDER='virtualenv'; return; fi
    fi

    if [ ! -f "$p/pyvenv.cfg" ]; then VERIFY_PROVIDER='virtualenv'; fi
}

verify_environment() {
    local p="$1" markers=0 evidence='' conda_python=0 f
    VERIFY_PROVIDER=''; VERIFY_EVIDENCE=''; VERIFY_PROTECTED=0; VERIFY_REASON=''
    [ -d "$p" ] || return 1
    p="$(canonical_dir "$p")"

    if [ -f "$p/conda-meta/history" ]; then
        if has_python_executable "$p"; then conda_python=1; fi
        if [ "$conda_python" -eq 0 ]; then
            for f in "$p"/conda-meta/python-*.json; do
                [ -f "$f" ] && conda_python=1 && break
            done
        fi
        [ "$conda_python" -eq 1 ] || return 1
        VERIFY_EVIDENCE='conda-meta/history + Python package/interpreter'
        classify_provider "$p"
        return 0
    fi

    if [ -f "$p/pyvenv.cfg" ]; then
        evidence='pyvenv.cfg'
        if has_python_executable "$p"; then markers=$((markers+1)); evidence="$evidence, bin/python"; fi
        if [ -f "$p/bin/activate" ]; then markers=$((markers+1)); evidence="$evidence, bin/activate"; fi
        if has_site_packages "$p"; then markers=$((markers+1)); evidence="$evidence, site-packages"; fi
        [ "$markers" -ge 1 ] || return 1
        VERIFY_EVIDENCE="$evidence"
        classify_provider "$p"
        return 0
    fi

    # Legacy/custom virtualenv without pyvenv.cfg: require three independent layout markers.
    if has_python_executable "$p" && [ -f "$p/bin/activate" ] && has_site_packages "$p"; then
        VERIFY_EVIDENCE='legacy layout: bin/python + bin/activate + site-packages'
        classify_provider "$p"
        return 0
    fi

    return 1
}

protection_for() {
    local p="$1" provider="$2" active root base cmd
    VERIFY_PROTECTED=0; VERIFY_REASON=''

    for active in "${ACTIVE_PATHS[@]:-}"; do
        if [ -n "$active" ] && [ "$p" = "$active" ]; then
            VERIFY_PROTECTED=1; VERIFY_REASON='currently active environment'; return
        fi
    done

    if path_inside "$(pwd -P)" "$p"; then
        VERIFY_PROTECTED=1; VERIFY_REASON='current working directory is inside this environment'; return
    fi

    if [ -n "$SCRIPT_PATH" ] && path_inside "$SCRIPT_PATH" "$p"; then
        VERIFY_PROTECTED=1; VERIFY_REASON='cleaner script is located inside this environment'; return
    fi

    for root in "${SCAN_ROOTS[@]:-}"; do
        if [ "$p" = "$root" ]; then
            VERIFY_PROTECTED=1; VERIFY_REASON='environment path is a mounted scan root'; return
        fi
    done

    if [ "$provider" = 'pipx tool' ]; then
        VERIFY_PROTECTED=1; VERIFY_REASON='pipx-managed application; use pipx uninstall'; return
    fi
    if [ "$provider" = 'uv tool' ]; then
        VERIFY_PROTECTED=1; VERIFY_REASON='uv-managed application; use uv tool uninstall'; return
    fi
    if [ "$provider" = 'pyenv' ]; then
        VERIFY_PROTECTED=1; VERIFY_REASON='pyenv-managed environment; use pyenv uninstall / pyenv virtualenv-delete'; return
    fi

    if [ -n "$CONDA_BASE" ] && [ "$p" = "$CONDA_BASE" ]; then
        VERIFY_PROTECTED=1; VERIFY_REASON='Conda base environment'; return
    fi
    if [ "$provider" = 'Conda' ] && [ -x "$p/bin/conda" ]; then
        base="$(basename "$p")"
        case "$base" in
            anaconda|anaconda3|miniconda|miniconda3|miniforge|miniforge3|mambaforge|micromamba)
                VERIFY_PROTECTED=1; VERIFY_REASON='looks like a Conda distribution/base install'; return ;;
        esac
    fi

    # Snapshot was taken before scanning, so the grep process itself cannot create a false match.
    if [ -n "$RUNNING_COMMANDS" ]; then
        if printf '%s\n' "$RUNNING_COMMANDS" | grep -F "$p/bin/python" >/dev/null 2>&1 || \
           printf '%s\n' "$RUNNING_COMMANDS" | grep -F "$p/bin/python3" >/dev/null 2>&1; then
            VERIFY_PROTECTED=1; VERIFY_REASON='a Python process appears to be running from this environment'; return
        fi
    fi
}

# ----------------------------- Scan -----------------------------

ENV_PATHS=()
ENV_TYPES=()
ENV_SIZES=()
ENV_MTIMES=()
ENV_EVIDENCE=()
ENV_PROTECTED=()
ENV_REASONS=()
ENV_SELECTED=()

reset_results() {
    ENV_PATHS=(); ENV_TYPES=(); ENV_SIZES=(); ENV_MTIMES=(); ENV_EVIDENCE=(); ENV_PROTECTED=(); ENV_REASONS=(); ENV_SELECTED=()
}

result_exists() {
    local p="$1" x
    for x in "${ENV_PATHS[@]:-}"; do [ "$x" = "$p" ] && return 0; done
    return 1
}

add_result() {
    local p="$1" sz mt
    p="$(canonical_dir "$p")"
    result_exists "$p" && return 0
    verify_environment "$p" || return 0
    protection_for "$p" "$VERIFY_PROVIDER"

    # Size calculation is intentionally after structural verification.
    sz="$(size_kb "$p")"
    mt="$(mtime_epoch "$p")"

    ENV_PATHS+=("$p")
    ENV_TYPES+=("$VERIFY_PROVIDER")
    ENV_SIZES+=("$sz")
    ENV_MTIMES+=("$mt")
    ENV_EVIDENCE+=("$VERIFY_EVIDENCE")
    ENV_PROTECTED+=("$VERIFY_PROTECTED")
    ENV_REASONS+=("$VERIFY_REASON")
    ENV_SELECTED+=(0)
}

candidate_from_item() {
    local item="$1" base parent
    if [ -d "$item" ]; then
        printf '%s\n' "$item"
        return
    fi
    base="$(basename "$item")"
    case "$base" in
        pyvenv.cfg)
            dirname "$item" ;;
        history)
            parent="$(dirname "$item")"
            if [ "$(basename "$parent")" = 'conda-meta' ]; then dirname "$parent"; fi ;;
        activate)
            parent="$(dirname "$item")"
            if [ "$(basename "$parent")" = 'bin' ]; then dirname "$parent"; fi ;;
    esac
}

scan_one_root() {
    local root="$1" item candidate
    if [ "$HAS_TTY" -eq 1 ]; then
        printf '\r%-90s' "Scanning $root ..." >&3
    else
        echo "Scanning $root ..." >&2
    fi

    if [ "$DEEP_SCAN" -eq 1 ]; then
        while IFS= read -r -d '' item; do
            candidate="$(candidate_from_item "$item")"
            [ -n "$candidate" ] && add_result "$candidate"
        done < <(
            find "$root" -xdev \
                \( -type f -name 'pyvenv.cfg' -print0 \) -o \
                \( -type f -path '*/conda-meta/history' -print0 \) -o \
                \( -type f -path '*/bin/activate' -print0 \) -o \
                \( -type d \( -name '.venv' -o -name 'venv' -o -name '.env' -o -name 'env' -o -name 'virtualenv' -o -name '.virtualenv' -o -name 'python-env' -o -name 'python_venv' \) -print0 \) \
                2>/dev/null
        )
    else
        while IFS= read -r -d '' item; do
            candidate="$(candidate_from_item "$item")"
            [ -n "$candidate" ] && add_result "$candidate"
        done < <(
            find "$root" -xdev \
                \( -type d \( -name '.git' -o -name '.hg' -o -name '.svn' -o -name 'node_modules' -o -name '__pycache__' -o -name 'site-packages' -o -name 'dist-packages' \) -prune \) -o \
                \( -type f -name 'pyvenv.cfg' -print0 \) -o \
                \( -type f -path '*/conda-meta/history' -print0 \) -o \
                \( -type f -path '*/bin/activate' -print0 \) -o \
                \( -type d \( -name '.venv' -o -name 'venv' -o -name '.env' -o -name 'env' -o -name 'virtualenv' -o -name '.virtualenv' -o -name 'python-env' -o -name 'python_venv' \) -print0 \) \
                2>/dev/null
        )
    fi
}

sort_results() {
    local i idx
    local sort_file="$TMP_DIR/sort"
    : > "$sort_file"
    for ((i=0; i<${#ENV_PATHS[@]}; i++)); do
        printf '%020d\t%d\n' "${ENV_SIZES[$i]:-0}" "$i" >> "$sort_file"
    done

    NEW_PATHS=(); NEW_TYPES=(); NEW_SIZES=(); NEW_MTIMES=(); NEW_EVIDENCE=(); NEW_PROTECTED=(); NEW_REASONS=(); NEW_SELECTED=()
    while IFS=$'\t' read -r _size idx; do
        [ -n "${idx:-}" ] || continue
        NEW_PATHS+=("${ENV_PATHS[$idx]}")
        NEW_TYPES+=("${ENV_TYPES[$idx]}")
        NEW_SIZES+=("${ENV_SIZES[$idx]}")
        NEW_MTIMES+=("${ENV_MTIMES[$idx]}")
        NEW_EVIDENCE+=("${ENV_EVIDENCE[$idx]}")
        NEW_PROTECTED+=("${ENV_PROTECTED[$idx]}")
        NEW_REASONS+=("${ENV_REASONS[$idx]}")
        NEW_SELECTED+=(0)
    done < <(sort -nr -k1,1 "$sort_file")

    ENV_PATHS=("${NEW_PATHS[@]}")
    ENV_TYPES=("${NEW_TYPES[@]}")
    ENV_SIZES=("${NEW_SIZES[@]}")
    ENV_MTIMES=("${NEW_MTIMES[@]}")
    ENV_EVIDENCE=("${NEW_EVIDENCE[@]}")
    ENV_PROTECTED=("${NEW_PROTECTED[@]}")
    ENV_REASONS=("${NEW_REASONS[@]}")
    ENV_SELECTED=("${NEW_SELECTED[@]}")
}

scan_all() {
    local root
    reset_results
    build_scan_roots
    if [ "${#SCAN_ROOTS[@]}" -eq 0 ]; then
        echo "No scan roots found." >&2
        return 1
    fi
    for root in "${SCAN_ROOTS[@]}"; do scan_one_root "$root"; done
    if [ "$HAS_TTY" -eq 1 ]; then printf '\r%-90s\r' ' ' >&3; fi
    sort_results
}

# ----------------------------- Plain listing -----------------------------

plain_list() {
    local i total=0 protected=0 date
    printf '%-3s %-14s %10s %-10s %s\n' '#' 'PROVIDER' 'SIZE' 'MODIFIED' 'PATH'
    printf '%s\n' '----------------------------------------------------------------------------------------------------'
    for ((i=0; i<${#ENV_PATHS[@]}; i++)); do
        date="$(format_date "${ENV_MTIMES[$i]}")"
        if [ "${ENV_PROTECTED[$i]}" -eq 1 ]; then
            printf '%-3s %-14s %10s %-10s %s  [PROTECTED: %s]\n' "$((i+1))" "${ENV_TYPES[$i]}" "$(human_kb "${ENV_SIZES[$i]}")" "$date" "${ENV_PATHS[$i]}" "${ENV_REASONS[$i]}"
            protected=$((protected+1))
        else
            printf '%-3s %-14s %10s %-10s %s\n' "$((i+1))" "${ENV_TYPES[$i]}" "$(human_kb "${ENV_SIZES[$i]}")" "$date" "${ENV_PATHS[$i]}"
        fi
        total=$((total + ${ENV_SIZES[$i]:-0}))
    done
    printf '\n%d verified environment(s), %s total, %d protected.\n' "${#ENV_PATHS[@]}" "$(human_kb "$total")" "$protected"
}

# ----------------------------- Interactive UI -----------------------------

CURSOR=0
TOP=0
STATUS='Ready.'
STATUS_COLOR='dim'

term_cols() {
    local n
    n="$(tput cols <&3 2>/dev/null || echo 100)"
    case "$n" in ''|*[!0-9]*) n=100 ;; esac
    [ "$n" -lt 70 ] && n=70
    echo "$n"
}

term_lines() {
    local n
    n="$(tput lines <&3 2>/dev/null || echo 30)"
    case "$n" in ''|*[!0-9]*) n=30 ;; esac
    [ "$n" -lt 18 ] && n=18
    echo "$n"
}

selected_stats() {
    local i count=0 kb=0
    for ((i=0; i<${#ENV_PATHS[@]}; i++)); do
        if [ "${ENV_SELECTED[$i]:-0}" -eq 1 ]; then count=$((count+1)); kb=$((kb + ${ENV_SIZES[$i]:-0})); fi
    done
    SELECTED_COUNT=$count
    SELECTED_KB=$kb
}

render() {
    local cols lines viewport count total_kb=0 protected=0 i end idx marker provider size date path max_path current evidence reason
    cols="$(term_cols)"; lines="$(term_lines)"
    viewport=$((lines - 13)); [ "$viewport" -lt 5 ] && viewport=5
    count=${#ENV_PATHS[@]}

    if [ "$count" -gt 0 ]; then
        [ "$CURSOR" -lt 0 ] && CURSOR=0
        [ "$CURSOR" -ge "$count" ] && CURSOR=$((count-1))
        [ "$CURSOR" -lt "$TOP" ] && TOP=$CURSOR
        [ "$CURSOR" -ge $((TOP+viewport)) ] && TOP=$((CURSOR-viewport+1))
    else
        CURSOR=0; TOP=0
    fi

    for ((i=0; i<count; i++)); do
        total_kb=$((total_kb + ${ENV_SIZES[$i]:-0}))
        [ "${ENV_PROTECTED[$i]:-0}" -eq 1 ] && protected=$((protected+1))
    done
    selected_stats

    printf '\033[2J\033[H\033[?25l' >&3
    printf '%s%*s%s\n' "$C_CYAN" $(((cols+34)/2)) 'PYTHON VIRTUAL ENVIRONMENT CLEANER' "$C_RESET" >&3
    printf '%s%*s%s\n' "$C_DIM" $(((cols+57)/2)) 'macOS + Linux | verified venvs only | safe interactive cleanup' "$C_RESET" >&3
    printf '%*s\n' $(((cols+47)/2)) 'Pratik Pathak | github.com/zpratikpathak' >&3
    printf '%*s\n' "$cols" '' | tr ' ' '-' >&3
    printf ' Environments: %d | Total: %s | Selected: %d (%s) | Protected: %d\n' "$count" "$(human_kb "$total_kb")" "$SELECTED_COUNT" "$(human_kb "$SELECTED_KB")" "$protected" >&3
    printf ' [↑/↓] Move  [Space] Select  [A] All  [Enter] Delete  [R] Rescan  [Q] Exit\n' >&3
    printf '%*s\n' "$cols" '' | tr ' ' '-' >&3
    printf '    %-14s %10s %-10s %s\n' 'PROVIDER' 'SIZE' 'MODIFIED' 'PATH' >&3

    if [ "$count" -eq 0 ]; then
        printf '\n  No verified Python virtual environments found.\n' >&3
    else
        end=$((TOP+viewport)); [ "$end" -gt "$count" ] && end=$count
        max_path=$((cols - 45)); [ "$max_path" -lt 20 ] && max_path=20
        for ((idx=TOP; idx<end; idx++)); do
            if [ "${ENV_PROTECTED[$idx]:-0}" -eq 1 ]; then marker='[!]'
            elif [ "${ENV_SELECTED[$idx]:-0}" -eq 1 ]; then marker='[x]'
            else marker='[ ]'; fi
            provider="${ENV_TYPES[$idx]}"
            size="$(human_kb "${ENV_SIZES[$idx]}")"
            date="$(format_date "${ENV_MTIMES[$idx]}")"
            path="$(truncate_left "${ENV_PATHS[$idx]}" "$max_path")"
            if [ "$idx" -eq "$CURSOR" ]; then
                printf '%s> %s %-14.14s %10s %-10s %s%s\n' "$C_REVERSE" "$marker" "$provider" "$size" "$date" "$path" "$C_RESET" >&3
            else
                printf '  %s %-14.14s %10s %-10s %s\n' "$marker" "$provider" "$size" "$date" "$path" >&3
            fi
        done
    fi

    printf '%*s\n' "$cols" '' | tr ' ' '-' >&3
    if [ "$count" -gt 0 ]; then
        current="${ENV_PATHS[$CURSOR]}"; evidence="${ENV_EVIDENCE[$CURSOR]}"; reason="${ENV_REASONS[$CURSOR]}"
        printf '%sVerified:%s %s\n' "$C_GREEN" "$C_RESET" "$(truncate_left "$evidence" $((cols-12)))" >&3
        printf 'Path: %s\n' "$(truncate_left "$current" $((cols-7)))" >&3
        if [ "${ENV_PROTECTED[$CURSOR]:-0}" -eq 1 ]; then
            printf '%sProtected:%s %s\n' "$C_YELLOW" "$C_RESET" "$reason" >&3
        else
            case "$STATUS_COLOR" in
                red) printf '%s%s%s\n' "$C_RED" "$STATUS" "$C_RESET" >&3 ;;
                green) printf '%s%s%s\n' "$C_GREEN" "$STATUS" "$C_RESET" >&3 ;;
                yellow) printf '%s%s%s\n' "$C_YELLOW" "$STATUS" "$C_RESET" >&3 ;;
                *) printf '%s%s%s\n' "$C_DIM" "$STATUS" "$C_RESET" >&3 ;;
            esac
        fi
    else
        printf '%s%s%s\n' "$C_DIM" "$STATUS" "$C_RESET" >&3
    fi
}

read_key() {
    local k='' k2='' k3=''
    IFS= read -rsn1 k <&3 || { KEY='q'; return; }
    if [ "$k" = $'\033' ]; then
        IFS= read -rsn1 -t 0.08 k2 <&3 || true
        if [ "$k2" = '[' ] || [ "$k2" = 'O' ]; then
            IFS= read -rsn1 -t 0.08 k3 <&3 || true
            case "$k3" in
                A) KEY='up' ;;
                B) KEY='down' ;;
                H) KEY='home' ;;
                F) KEY='end' ;;
                5)
                    IFS= read -rsn1 -t 0.08 _tilde <&3 || true
                    KEY='pgup' ;;
                6)
                    IFS= read -rsn1 -t 0.08 _tilde <&3 || true
                    KEY='pgdn' ;;
                1)
                    IFS= read -rsn1 -t 0.08 _tilde <&3 || true
                    KEY='home' ;;
                4)
                    IFS= read -rsn1 -t 0.08 _tilde <&3 || true
                    KEY='end' ;;
                *) KEY='' ;;
            esac
        else KEY=''; fi
    elif [ -z "$k" ]; then KEY='enter'
    elif [ "$k" = ' ' ]; then KEY='space'
    else KEY="$k"
    fi
}

recheck_before_delete() {
    local p="$1"
    verify_environment "$p" || return 1
    protection_for "$p" "$VERIFY_PROVIDER"
    [ "$VERIFY_PROTECTED" -eq 0 ] || return 1
    return 0
}

delete_selected() {
    local i count=0 kb=0 answer p provider ok deleted=0 failed=0 skipped=0
    selected_stats
    count=$SELECTED_COUNT; kb=$SELECTED_KB
    if [ "$count" -eq 0 ]; then STATUS='Nothing selected.'; STATUS_COLOR='yellow'; return; fi

    printf '\033[2J\033[H\033[?25h' >&3
    printf '%sDELETE REVIEW%s\n\n' "$C_RED" "$C_RESET" >&3
    for ((i=0; i<${#ENV_PATHS[@]}; i++)); do
        [ "${ENV_SELECTED[$i]:-0}" -eq 1 ] || continue
        printf '  - %-12s %10s  %s\n' "${ENV_TYPES[$i]}" "$(human_kb "${ENV_SIZES[$i]}")" "${ENV_PATHS[$i]}" >&3
    done
    printf '\nAbout %s across %d environment(s) will be permanently removed.\n' "$(human_kb "$kb")" "$count" >&3
    printf 'The script will re-verify every directory immediately before deletion.\n' >&3
    printf '\nType %sDELETE%s to continue: ' "$C_RED" "$C_RESET" >&3
    IFS= read -r answer <&3 || answer=''
    if [ "$answer" != 'DELETE' ]; then
        STATUS='Deletion cancelled.'; STATUS_COLOR='yellow'; return
    fi

    printf '\n' >&3
    for ((i=0; i<${#ENV_PATHS[@]}; i++)); do
        [ "${ENV_SELECTED[$i]:-0}" -eq 1 ] || continue
        p="${ENV_PATHS[$i]}"; provider="${ENV_TYPES[$i]}"; ok=0
        printf 'Re-checking %s ... ' "$p" >&3
        if ! recheck_before_delete "$p"; then
            printf '%sSKIPPED%s (no longer verified or now protected)\n' "$C_YELLOW" "$C_RESET" >&3
            skipped=$((skipped+1)); continue
        fi

        printf 'deleting ... ' >&3
        if [ "$provider" = 'Conda' ] && command -v conda >/dev/null 2>&1; then
            if conda env remove --prefix "$p" -y >/dev/null 2>&1; then ok=1; fi
        else
            if rm -rf "$p" 2>/dev/null && [ ! -e "$p" ]; then ok=1; fi
        fi

        if [ "$ok" -eq 1 ]; then
            printf '%sDONE%s\n' "$C_GREEN" "$C_RESET" >&3
            deleted=$((deleted+1))
        else
            printf '%sFAILED%s\n' "$C_RED" "$C_RESET" >&3
            failed=$((failed+1))
        fi
    done

    printf '\nDeleted: %d | Failed: %d | Skipped: %d\n' "$deleted" "$failed" "$skipped" >&3
    printf 'Press any key to rescan...' >&3
    IFS= read -rsn1 _ <&3 || true
    RUNNING_COMMANDS="$(ps -axo command= 2>/dev/null || true)"
    scan_all
    CURSOR=0; TOP=0
    STATUS="Deleted $deleted environment(s); $failed failed; $skipped skipped."
    [ "$failed" -gt 0 ] && STATUS_COLOR='red' || STATUS_COLOR='green'
}

interactive_loop() {
    local count viewport i all_selected=1
    while :; do
        render
        read_key
        count=${#ENV_PATHS[@]}
        viewport=$(($(term_lines)-13)); [ "$viewport" -lt 5 ] && viewport=5
        case "$KEY" in
            up) [ "$CURSOR" -gt 0 ] && CURSOR=$((CURSOR-1)) ;;
            down) [ "$CURSOR" -lt $((count-1)) ] && CURSOR=$((CURSOR+1)) ;;
            pgup) CURSOR=$((CURSOR-viewport)); [ "$CURSOR" -lt 0 ] && CURSOR=0 ;;
            pgdn) CURSOR=$((CURSOR+viewport)); [ "$CURSOR" -ge "$count" ] && CURSOR=$((count-1)); [ "$CURSOR" -lt 0 ] && CURSOR=0 ;;
            home) CURSOR=0 ;;
            end) [ "$count" -gt 0 ] && CURSOR=$((count-1)) ;;
            space)
                if [ "$count" -gt 0 ]; then
                    if [ "${ENV_PROTECTED[$CURSOR]:-0}" -eq 1 ]; then
                        STATUS="Protected: ${ENV_REASONS[$CURSOR]}"; STATUS_COLOR='yellow'
                    elif [ "${ENV_SELECTED[$CURSOR]:-0}" -eq 1 ]; then
                        ENV_SELECTED[$CURSOR]=0; STATUS='Deselected.'; STATUS_COLOR='dim'
                    else
                        ENV_SELECTED[$CURSOR]=1; STATUS='Selected.'; STATUS_COLOR='green'
                    fi
                fi ;;
            a|A)
                all_selected=1
                for ((i=0; i<count; i++)); do
                    if [ "${ENV_PROTECTED[$i]:-0}" -eq 0 ] && [ "${ENV_SELECTED[$i]:-0}" -eq 0 ]; then all_selected=0; break; fi
                done
                for ((i=0; i<count; i++)); do
                    if [ "${ENV_PROTECTED[$i]:-0}" -eq 0 ]; then
                        if [ "$all_selected" -eq 1 ]; then ENV_SELECTED[$i]=0; else ENV_SELECTED[$i]=1; fi
                    fi
                done
                if [ "$all_selected" -eq 1 ]; then STATUS='Deselected all.'; else STATUS='Selected all safe environments.'; fi
                STATUS_COLOR='dim' ;;
            enter) delete_selected ;;
            r|R)
                STATUS='Rescanning...'; STATUS_COLOR='dim'; render
                RUNNING_COMMANDS="$(ps -axo command= 2>/dev/null || true)"
                scan_all
                CURSOR=0; TOP=0; STATUS='Rescan complete.'; STATUS_COLOR='green' ;;
            q|Q) return ;;
        esac
    done
}

# ----------------------------- Main -----------------------------

if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ] && [ "$LIST_ONLY" -eq 0 ] && [ "$HAS_TTY" -eq 1 ]; then
    printf '%sNote:%s running without root privileges; unreadable directories will be skipped.\n' "$C_YELLOW" "$C_RESET" >&3
    printf 'For a system-wide scan, run with sudo only if you understand the additional access.\n\n' >&3
fi

scan_all || exit 1

if [ "$LIST_ONLY" -eq 1 ]; then
    plain_list
    exit 0
fi

if [ "$HAS_TTY" -eq 0 ]; then
    echo "No interactive TTY is available, so deletion mode is disabled." >&2
    echo "Showing a read-only list instead. Use an interactive terminal (or ssh -t)." >&2
    plain_list
    exit 0
fi

interactive_loop
printf '\033[2J\033[H\033[?25h' >&3
printf 'Exited without deleting anything else.\n' >&3
